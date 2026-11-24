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
    public enum Installer: String, Sendable { case msi, innoSetup, nsis, installShield, wixBurn, selfExtracting, other }

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
        // dxgi.dll alone doesn't count: Direct3D 12 programs that load d3d12.dll at run time import it too.
        if imports.contains("d3d11.dll") { return 11 }
        if !imports.isDisjoint(with: ["d3d10.dll", "d3d10_1.dll", "d3d10core.dll"]) { return 10 }
        if imports.contains("d3d9.dll") { return 9 }
        if imports.contains("d3d8.dll") { return 8 }
        return nil
    }

    /// Heuristic for "this is a game" (which decides D3DMetal: Apple's license covers games only). Needs a
    /// game-specific signal: a game platform, controller, game audio or Direct3D 12 import. Direct3D 9–11 alone
    /// doesn't count, because browsers, Electron apps and CAD tools import those too; the user can still choose
    /// "Treat as Game". Launchers that load everything dynamically aren't caught either.
    public var looksLikeGame: Bool {
        let gameLibraries: Set<String> = ["xinput1_3.dll", "xinput1_4.dll", "xinput9_1_0.dll", "dinput8.dll",
                                          "steam_api.dll", "steam_api64.dll", "xaudio2_7.dll", "xaudio2_8.dll",
                                          "xaudio2_9.dll", "x3daudio1_7.dll", "openal32.dll", "eossdk-win64-shipping.dll"]
        return direct3D == 12 || !imports.isDisjoint(with: gameLibraries)
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
        let data = try contents(of: file)
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

    /// Whether `folder` holds anything that uses Direct3D 12: a program or library importing d3d12.dll, at any
    /// depth, or a copy of d3d12.dll itself. Launchers start the real program from their own folder.
    public static func usesDirect3D12(in folder: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        // One budget for the whole walk, so a program kept in a huge folder still launches promptly.
        var budget = 4096
        for case let file as URL in walker {
            budget -= 1
            guard budget >= 0 else { break }
            guard ["exe", "dll"].contains(file.pathExtension.lowercased()) else { continue }
            if file.lastPathComponent.lowercased() == "d3d12.dll" { return true }
            if let data = try? contents(of: file),
               PEFile(data)?.importedDLLs().contains("d3d12.dll") == true { return true }
        }
        return false
    }

    /// A file's bytes for the reader. Up to `mapAbove` bytes they are read: a mapped file that another process
    /// cuts short meanwhile (a store updating a game inside a bottle) ends Harbor with SIGBUS at the next byte
    /// touched, and no bounds check helps. Larger files are mapped rather than held in memory. Those are
    /// installers and game executables of hundreds of megabytes; an installer the user dropped isn't being
    /// rewritten while it is looked at, and for a large file in a bottle the window is the few milliseconds of
    /// one analysis, which costs less than reading gigabytes at every launch.
    static func contents(of file: URL, mapAbove: Int = 64 << 20) throws -> Data {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return try Data(contentsOf: file, options: size > mapAbove ? .mappedIfSafe : [])
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
        // Self-extracting archives (WinRAR's own installer is a RAR SFX) count as installers: run them, then
        // find what they installed, instead of keeping the archive as the program.
        let markers: [(String, Installer)] = [("Inno Setup Setup Data", .innoSetup), ("Nullsoft.NSIS", .nsis),
                                              ("NullsoftInst", .nsis), ("InstallShield", .installShield),
                                              ("WinRAR SFX", .selfExtracting), ("sfxrar", .selfExtracting),
                                              ("7-Zip SFX", .selfExtracting), ("7zS.sfx", .selfExtracting)]
        for (marker, kind) in markers where data.range(of: Data(marker.utf8)) != nil { return kind }
        let name = file.deletingPathExtension().lastPathComponent.lowercased()
        let text = (description ?? "").lowercased()
        // The word has to end there: "ChromeSetup", "thing_setup_1.2" and "Install Thing" are installers,
        // `SetupDiag.exe` and "InstallShield Viewer" are programs.
        let word = "(setup|install|installer)(?![a-z])"
        if [name, text].contains(where: { $0.range(of: word, options: .regularExpression) != nil }) { return .other }
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
        // One budget for the whole walk: nested directories of up to 65535 entries each would otherwise let a
        // small crafted file keep the parser busy for minutes.
        var budget = 4096
        func entries(_ dir: Int) -> [(id: UInt32, isDirectory: Bool, target: Int)] {
            guard let named = data.u16(dir + 12), let ids = data.u16(dir + 14) else { return [] }
            let count = min(Int(named) + Int(ids), budget)
            budget -= count
            var out: [(UInt32, Bool, Int)] = []
            for i in 0..<count {
                guard let name = data.u32(dir + 16 + i * 8), let target = data.u32(dir + 20 + i * 8) else { break }
                out.append((name, target & 0x8000_0000 != 0, root + Int(target & 0x7FFF_FFFF)))
            }
            return out
        }
        var result: [(UInt32, Int, Int)] = []
        for typeEntry in entries(root).filter({ $0.id == type && $0.isDirectory }).prefix(1) {
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

    /// A resource's bytes, copied out of the file; nil if it declares more than `limit`. Version and icon-group
    /// resources are a few kilobytes: a megabyte is a crafted file asking for a large copy to be searched.
    func resourceData(rva: Int, size: Int, limit: Int = 1 << 20) -> Data? {
        guard size <= limit, let off = offset(ofRVA: rva) else { return nil }
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
        var used = Set<UInt16>(), total = 0
        for i in 0..<min(count, 64) {
            let e = 6 + i * 14
            // Each icon image once, each at most 2 MB, 8 MB in all: a group could otherwise reference one huge
            // image 64 times.
            guard let entry = dir.slice(e, 12), let id = dir.u16(e + 12), used.insert(id).inserted,
                  let icon = icons[UInt32(id)], icon.size <= 2 << 20, total + icon.size <= 8 << 20,
                  let payload = resourceData(rva: icon.rva, size: icon.size, limit: 2 << 20) else { continue }
            total += payload.count
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
        return Self.pngFromICO(ico)
    }

    /// The largest image of an .ico file, as PNG. Images that declare more than 1024 pixels a side are passed
    /// over before anything is decoded (the properties come from the image's header): no icon is that large,
    /// and 2 MB of PNG can declare dimensions that take gigabytes to decode.
    static func pngFromICO(_ ico: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(ico as CFData, nil) else { return nil }
        var best: (index: Int, pixels: Int)?
        for i in 0..<CGImageSourceGetCount(source) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            if w <= 1024, h <= 1024, w * h > (best?.pixels ?? 0) { best = (i, w * h) }
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
