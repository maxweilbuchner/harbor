import Foundation

/// What Steam itself knows about installed titles, from its cache `appcache/appinfo.vdf`: the kind of title
/// ("Game", "Application", "Tool", "Demo"…) and the Windows program it starts. Used to tell software from games
/// (Apple's D3DMetal is for games only) and to start software without going through Steam's runtime.
///
/// The file is Steam's binary KeyValues format (versions 0x07564428 and 0x07564429, the latter with a string
/// table for keys). Everything read is bounds-checked and budgeted; anything unexpected yields no information
/// rather than an error, since the cache is only a hint.
public enum SteamAppInfo {
    public struct App: Equatable, Sendable {
        /// `common/type`, as Steam writes it ("Game", "Application", "Tool", "Demo", "Music"…).
        public var type: String?
        /// `config/launch/*/executable` of the first entry for Windows (or without an OS list), relative to the
        /// title's install folder, with its arguments.
        public var executable: String?
        public var arguments: String?

        /// Steam calls it software rather than a game.
        public var isSoftware: Bool { ["application", "tool"].contains(type?.lowercased() ?? "") }
    }

    /// Entries for `ids` found in the cache file's contents.
    public static func apps(in data: Data, ids: Set<Int>) -> [Int: App] {
        var reader = Reader(data: data)
        guard let magic = reader.u32(), magic == 0x0756_4428 || magic == 0x0756_4429, reader.u32() != nil else { return [:] }
        var strings: [String]?
        if magic == 0x0756_4429 {
            guard let offset = reader.u64(), offset < UInt64(data.count) else { return [:] }
            var table = Reader(data: data, at: Int(offset))
            guard let count = table.u32(), count <= 1_000_000 else { return [:] }
            var list: [String] = []
            list.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let s = table.cstring() else { return [:] }
                list.append(s)
            }
            strings = list
        }
        var found: [Int: App] = [:]
        // appid, size, then `size` bytes: state, last update, token (8), SHA-1 (20), change number, SHA-1 of the
        // data (20), and the data itself.
        while found.count < ids.count, let id = reader.u32(), id != 0, let size = reader.u32() {
            let start = reader.position
            guard size >= 60, start + Int(size) <= data.count else { break }
            if ids.contains(Int(id)) {
                var body = Reader(data: data, at: start + 60, end: start + Int(size), strings: strings)
                var budget = 20_000
                if let root = body.map(depth: 0, budget: &budget) { found[Int(id)] = app(from: root) }
            }
            reader.position = start + Int(size)
        }
        return found
    }

    indirect enum Value { case map([(String, Value)]), string(String), other }

    static func app(from root: [(String, Value)]) -> App {
        func child(_ map: [(String, Value)], _ key: String) -> [(String, Value)]? {
            for (k, v) in map where k.caseInsensitiveCompare(key) == .orderedSame { if case .map(let m) = v { return m } }
            return nil
        }
        func text(_ map: [(String, Value)], _ key: String) -> String? {
            for (k, v) in map where k.caseInsensitiveCompare(key) == .orderedSame { if case .string(let s) = v { return s } }
            return nil
        }
        let info = child(root, "appinfo") ?? root
        var app = App(type: child(info, "common").flatMap { text($0, "type") })
        for (_, entry) in child(info, "config").flatMap({ child($0, "launch") }) ?? [] {
            guard case .map(let launch) = entry, let exe = text(launch, "executable"), !exe.isEmpty else { continue }
            let os = child(launch, "config").flatMap { text($0, "oslist") }?.lowercased()
            guard os == nil || os!.isEmpty || os!.contains("windows") else { continue }
            app.executable = exe
            app.arguments = text(launch, "arguments").flatMap { $0.isEmpty ? nil : $0 }
            break
        }
        return app
    }

    struct Reader {
        let data: Data
        var position: Int
        let end: Int
        var strings: [String]?

        init(data: Data, at position: Int = 0, end: Int? = nil, strings: [String]? = nil) {
            self.data = data; self.position = position; self.end = min(end ?? data.count, data.count); self.strings = strings
        }

        mutating func byte() -> UInt8? {
            guard position < end else { return nil }
            defer { position += 1 }
            return data[data.startIndex + position]
        }
        mutating func u32() -> UInt32? {
            guard end - position >= 4 else { return nil }
            defer { position += 4 }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + position + $1]) << (8 * UInt32($1)) }
        }
        mutating func u64() -> UInt64? {
            guard let low = u32(), let high = u32() else { return nil }
            return UInt64(low) | UInt64(high) << 32
        }
        mutating func cstring() -> String? {
            let from = data.startIndex + position
            guard position < end, let nul = data[from..<(data.startIndex + end)].firstIndex(of: 0) else { return nil }
            defer { position = nul - data.startIndex + 1 }
            return String(decoding: data[from..<nul], as: UTF8.self)
        }
        mutating func key() -> String? {
            guard let strings else { return cstring() }
            guard let index = u32(), Int(index) < strings.count else { return nil }
            return strings[Int(index)]
        }
        /// A map up to its end marker. Nil on anything malformed, too deep or too large.
        mutating func map(depth: Int, budget: inout Int) -> [(String, Value)]? {
            guard depth < 32 else { return nil }
            var entries: [(String, Value)] = []
            while true {
                guard let type = byte() else { return nil }
                if type == 0x08 || type == 0x0B { return entries }
                budget -= 1
                guard budget > 0, let key = key() else { return nil }
                switch type {
                case 0x00:
                    guard let nested = map(depth: depth + 1, budget: &budget) else { return nil }
                    entries.append((key, .map(nested)))
                case 0x01:
                    guard let s = cstring() else { return nil }
                    entries.append((key, .string(s)))
                case 0x02, 0x03, 0x04, 0x06:
                    guard u32() != nil else { return nil }
                    entries.append((key, .other))
                case 0x07, 0x0A:
                    guard u64() != nil else { return nil }
                    entries.append((key, .other))
                case 0x05:                                   // UTF-16 string
                    while true {
                        guard let low = byte(), let high = byte() else { return nil }
                        if low == 0 && high == 0 { break }
                    }
                    entries.append((key, .other))
                default:
                    return nil
                }
            }
        }
    }
}
