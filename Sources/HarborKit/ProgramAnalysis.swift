import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What Harbor learns from a Windows executable before running it: architecture, imports (DirectX version,
/// controllers, Steam), product details from its version resource, its icon, and whether it is an installer.
///
/// The reader is defensive: every offset is bounds-checked, so a damaged or hostile file yields `nil`/partial
/// results rather than a crash.
public struct ProgramAnalysis: Sendable, Equatable {
    public enum Architecture: String, Sendable { case x86, x64, arm64, unknown }
    public enum Installer: String, Sendable { case msi, innoSetup, nsis, installShield, wixBurn, other }

    public var architecture: Architecture
    public var isGUI: Bool
    /// Lower-cased DLL names from the import and delay-import tables.
    public var imports: Set<String>
    public var productName: String?
    public var fileDescription: String?
    public var companyName: String?
    public var productVersion: String?
    /// Detected installer technology; nil for a program that runs directly.
    public var installer: Installer?
    /// PNG of the largest icon in the executable, if it has one.
    public var iconPNG: Data?

    /// Highest Direct3D generation the program links against (12, 11, 10, 9, 8), if any.
    public var direct3D: Int? {
        if imports.contains("d3d12.dll") { return 12 }
        if imports.contains("d3d11.dll") || imports.contains("dxgi.dll") { return 11 }
        if imports.contains("d3d10.dll") || imports.contains("d3d10_1.dll") { return 10 }
        if imports.contains("d3d9.dll") { return 9 }
        if imports.contains("d3d8.dll") { return 8 }
        return nil
    }

    /// Heuristic: graphics/input/game-platform imports. Launchers that load DirectX dynamically aren't caught;
    /// the user can always change it.
    public var looksLikeGame: Bool {
        let gameLibraries: Set<String> = ["xinput1_3.dll", "xinput1_4.dll", "xinput9_1_0.dll", "dinput8.dll",
                                          "steam_api.dll", "steam_api64.dll", "xaudio2_7.dll", "xaudio2_9.dll",
                                          "vulkan-1.dll", "openal32.dll"]
        return direct3D != nil || !imports.isDisjoint(with: gameLibraries)
    }

    /// A friendly name: product name, else description, else the file name without extension.
    public func displayName(fallback file: URL) -> String {
        for candidate in [productName, fileDescription] {
            if let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        }
        return file.deletingPathExtension().lastPathComponent
    }

    /// Analyses `file`. MSI packages are recognised by their compound-document signature; anything else must be
    /// a PE executable.
    public static func analyze(_ file: URL) throws -> ProgramAnalysis {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            return ProgramAnalysis(architecture: .unknown, isGUI: true, imports: [], installer: .msi)
        }
        guard let pe = PEFile(data) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: file]) }
        var result = ProgramAnalysis(architecture: pe.architecture, isGUI: pe.subsystem == 2, imports: pe.importedDLLs())
        let strings = pe.versionStrings()
        result.productName = strings["ProductName"]
        result.fileDescription = strings["FileDescription"]
        result.companyName = strings["CompanyName"]
        result.productVersion = strings["ProductVersion"]
        result.iconPNG = pe.largestIconPNG()
        result.installer = detectInstaller(data, pe: pe, file: file, description: result.fileDescription)
        return result
    }

    init(architecture: Architecture, isGUI: Bool, imports: Set<String>, installer: Installer? = nil) {
        self.architecture = architecture
        self.isGUI = isGUI
        self.imports = imports
        self.installer = installer
    }

    static func detectInstaller(_ data: Data, pe: PEFile, file: URL, description: String?) -> Installer? {
        if pe.sectionNames.contains(".wixburn") { return .wixBurn }
        // Installer engines leave recognisable markers in the stub or its appended data.
        let markers: [(String, Installer)] = [("Inno Setup Setup Data", .innoSetup), ("Nullsoft.NSIS", .nsis),
                                              ("NullsoftInst", .nsis), ("InstallShield", .installShield)]
        for (marker, kind) in markers where data.range(of: Data(marker.utf8)) != nil { return kind }
        let name = file.deletingPathExtension().lastPathComponent.lowercased()
        let text = (description ?? "").lowercased()
        if ["setup", "install", "installer"].contains(where: { name.contains($0) || text.contains($0) }) { return .other }
        return nil
    }
}

/// Minimal, bounds-checked PE/COFF reader.
struct PEFile {
    let data: Data
    let architecture: ProgramAnalysis.Architecture
    let subsystem: UInt16
    private let dataDirectories: Int   // file offset of the data-directory array
    private let directoryCount: Int
    private let sections: [(name: String, virtualAddress: Int, virtualSize: Int, rawSize: Int, rawOffset: Int)]

    var sectionNames: [String] { sections.map(\.name) }

    init?(_ data: Data) {
        self.data = data
        guard data.u16(0) == 0x5A4D, let peOffset = data.u32(0x3C).map(Int.init),
              data.u32(peOffset) == 0x0000_4550 else { return nil }
        let coff = peOffset + 4
        guard let machine = data.u16(coff), let sectionCount = data.u16(coff + 2).map(Int.init),
              let optionalSize = data.u16(coff + 16).map(Int.init) else { return nil }
        switch machine {
        case 0x014C: architecture = .x86
        case 0x8664: architecture = .x64
        case 0xAA64: architecture = .arm64
        default: architecture = .unknown
        }
        let optional = coff + 20
        guard let magic = data.u16(optional), magic == 0x10B || magic == 0x20B,
              let subsystem = data.u16(optional + 68) else { return nil }
        self.subsystem = subsystem
        let pe32Plus = magic == 0x20B
        guard let count = data.u32(optional + (pe32Plus ? 108 : 92)) else { return nil }
        directoryCount = Int(min(count, 16))
        dataDirectories = optional + (pe32Plus ? 112 : 96)
        var sections: [(String, Int, Int, Int, Int)] = []
        let table = optional + optionalSize
        for i in 0..<min(sectionCount, 96) {
            let s = table + i * 40
            guard let raw = data.slice(s, 8), let vsize = data.u32(s + 8), let va = data.u32(s + 12),
                  let rsize = data.u32(s + 16), let roff = data.u32(s + 20) else { break }
            let name = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            sections.append((name, Int(va), Int(vsize), Int(rsize), Int(roff)))
        }
        self.sections = sections
    }

    /// (RVA, size) of data directory `index`.
    func directory(_ index: Int) -> (rva: Int, size: Int)? {
        guard index < directoryCount, let rva = data.u32(dataDirectories + index * 8),
              let size = data.u32(dataDirectories + index * 8 + 4), rva != 0 else { return nil }
        return (Int(rva), Int(size))
    }

    func offset(ofRVA rva: Int) -> Int? {
        for s in sections where rva >= s.virtualAddress && rva < s.virtualAddress + max(s.virtualSize, s.rawSize) {
            let off = rva - s.virtualAddress + s.rawOffset
            return off < data.count ? off : nil
        }
        return nil
    }

    func cString(atRVA rva: Int, limit: Int = 260) -> String? {
        guard let start = offset(ofRVA: rva) else { return nil }
        let end = min(start + limit, data.count)
        let bytes = data[data.startIndex + start ..< data.startIndex + end].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    func importedDLLs() -> Set<String> {
        var names = Set<String>()
        if let (rva, _) = directory(1), var d = offset(ofRVA: rva) {      // IMAGE_IMPORT_DESCRIPTOR, 20 bytes
            for _ in 0..<4096 {
                guard let nameRVA = data.u32(d + 12), nameRVA != 0 else { break }
                if let n = cString(atRVA: Int(nameRVA)) { names.insert(n.lowercased()) }
                d += 20
            }
        }
        if let (rva, _) = directory(13), var d = offset(ofRVA: rva) {     // delay-load descriptor, 32 bytes
            for _ in 0..<4096 {
                guard let attrs = data.u32(d), let nameField = data.u32(d + 4), nameField != 0 else { break }
                // Old-style descriptors store a VA instead of an RVA; skip those rather than guess the image base.
                if attrs & 1 == 1, let n = cString(atRVA: Int(nameField)) { names.insert(n.lowercased()) }
                d += 32
            }
        }
        return names
    }

    // MARK: Resources

    /// Leaf (RVA, size) entries of resource `type` (3 = RT_ICON, 14 = RT_GROUP_ICON, 16 = RT_VERSION), by id.
    func resources(type: UInt32) -> [(id: UInt32, rva: Int, size: Int)] {
        guard let (rva, _) = directory(2), let root = offset(ofRVA: rva) else { return [] }
        func entries(_ dir: Int) -> [(id: UInt32, isDirectory: Bool, target: Int)] {
            guard let named = data.u16(dir + 12), let ids = data.u16(dir + 14) else { return [] }
            var out: [(UInt32, Bool, Int)] = []
            for i in 0..<min(Int(named) + Int(ids), 2048) {
                guard let name = data.u32(dir + 16 + i * 8), let target = data.u32(dir + 20 + i * 8) else { break }
                out.append((name, target & 0x8000_0000 != 0, root + Int(target & 0x7FFF_FFFF)))
            }
            return out
        }
        var result: [(UInt32, Int, Int)] = []
        for typeEntry in entries(root) where typeEntry.id == type && typeEntry.isDirectory {
            for nameEntry in entries(typeEntry.target) where nameEntry.isDirectory {
                // First language only.
                if let lang = entries(nameEntry.target).first, !lang.isDirectory,
                   let leafRVA = data.u32(lang.target), let size = data.u32(lang.target + 4) {
                    result.append((nameEntry.id, Int(leafRVA), Int(size)))
                }
            }
        }
        return result
    }

    func resourceData(rva: Int, size: Int) -> Data? {
        guard let off = offset(ofRVA: rva) else { return nil }
        return data.slice(off, size)
    }

    /// StringFileInfo key/value pairs from the first VS_VERSIONINFO resource.
    func versionStrings() -> [String: String] {
        guard let res = resources(type: 16).first, let blob = resourceData(rva: res.rva, size: res.size) else { return [:] }
        var out: [String: String] = [:]
        // Walk every VS structure: wLength, wValueLength, wType, UTF-16 key, padding, value (text if wType == 1).
        func walk(_ start: Int, _ end: Int, depth: Int) {
            var p = start
            while p + 6 <= end, depth < 6 {
                guard let length = blob.u16(p).map(Int.init), length >= 6, p + length <= end,
                      let valueLength = blob.u16(p + 2).map(Int.init), let type = blob.u16(p + 4) else { return }
                var k = p + 6
                var key = [UInt16]()
                while k + 1 < p + length, let ch = blob.u16(k), ch != 0 { key.append(ch); k += 2 }
                k += 2
                let valueStart = (k + 3) & ~3
                let keyString = String(decoding: key, as: UTF16.self)
                if type == 1, valueLength > 0, valueStart < p + length {
                    var chars = [UInt16]()
                    var v = valueStart
                    while v + 1 < min(p + length, valueStart + valueLength * 2), let ch = blob.u16(v), ch != 0 {
                        chars.append(ch); v += 2
                    }
                    out[keyString] = String(decoding: chars, as: UTF16.self)
                }
                let childStart = (valueStart + (type == 1 ? valueLength * 2 : valueLength) + 3) & ~3
                if childStart < p + length { walk(childStart, p + length, depth: depth + 1) }
                p = (p + length + 3) & ~3
            }
        }
        walk(0, blob.count, depth: 0)
        return out
    }

    /// Rebuilds a .ico from the first icon group and returns its largest image as PNG.
    func largestIconPNG() -> Data? {
        guard let group = resources(type: 14).first, let dir = resourceData(rva: group.rva, size: group.size),
              let count = dir.u16(4).map(Int.init), count > 0 else { return nil }
        let icons = Dictionary(resources(type: 3).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var images: [(entry: Data, payload: Data)] = []
        for i in 0..<min(count, 64) {
            let e = 6 + i * 14
            guard let entry = dir.slice(e, 12), let id = dir.u16(e + 12),
                  let icon = icons[UInt32(id)], let payload = resourceData(rva: icon.rva, size: icon.size) else { continue }
            images.append((entry, payload))
        }
        guard !images.isEmpty else { return nil }
        var ico = Data([0, 0, 1, 0])
        ico.append(contentsOf: withUnsafeBytes(of: UInt16(images.count).littleEndian, Array.init))
        var offset = 6 + 16 * images.count
        for image in images {
            ico.append(image.entry.prefix(8))                       // width…bitcount
            ico.append(contentsOf: withUnsafeBytes(of: UInt32(image.payload.count).littleEndian, Array.init))
            ico.append(contentsOf: withUnsafeBytes(of: UInt32(offset).littleEndian, Array.init))
            offset += image.payload.count
        }
        for image in images { ico.append(image.payload) }

        guard let source = CGImageSourceCreateWithData(ico as CFData, nil) else { return nil }
        var best: (index: Int, pixels: Int)?
        for i in 0..<CGImageSourceGetCount(source) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            if w * h > (best?.pixels ?? 0) { best = (i, w * h) }
        }
        guard let best, let image = CGImageSourceCreateImageAtIndex(source, best.index, nil) else { return nil }
        let png = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? png as Data : nil
    }
}

extension Data {
    func slice(_ offset: Int, _ count: Int) -> Data? {
        guard offset >= 0, count >= 0, offset <= self.count - count else { return nil }
        return subdata(in: startIndex + offset ..< startIndex + offset + count)
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(self[startIndex + offset + i]) << (8 * UInt32(i)) }
        return v
    }
}
