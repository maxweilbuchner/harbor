import CryptoKit
import Foundation

/// Signed list of downloadable runtime components (`runtime.json` + detached `runtime.json.sig`).
public struct RuntimeManifest: Codable, Sendable, Equatable {
    public struct Component: Codable, Sendable, Equatable {
        /// Install folder name under `WineRuntime.installedDirectory`: "wine" or "d3dmetal".
        public var id: String
        public var version: String
        /// Absolute, or relative to the manifest's URL.
        public var url: String
        public var sha256: String
        public var size: Int64

        public init(id: String, version: String, url: String, sha256: String, size: Int64) {
            self.id = id; self.version = version; self.url = url; self.sha256 = sha256; self.size = size
        }
    }

    public static let currentSchema = 1
    public var schema: Int
    public var components: [Component]
    /// Grows with every published list (the packaging time). An installed runtime remembers the one it came from
    /// and refuses lists with a smaller one, so an old signed list served again can't downgrade it.
    public var sequence: Int?
    /// The oldest Harbor build (CFBundleVersion) that can use these components, if they need a newer app.
    public var minimumAppBuild: Int?

    public init(components: [Component], sequence: Int? = nil, minimumAppBuild: Int? = nil) {
        schema = Self.currentSchema
        self.components = components
        self.sequence = sequence
        self.minimumAppBuild = minimumAppBuild
    }
}

/// What a fetched runtime list means for this installation.
public enum RuntimeUpdateDecision: Equatable, Sendable {
    case upToDate
    case available([RuntimeManifest.Component])
    /// The list is older than what's installed (or carries no sequence although the installation has one).
    case refusedOlder
    /// The components need at least this Harbor build.
    case needsNewerApp(Int)
    /// This very list was installed before, its Wine didn't start and the previous runtime was put back. It isn't
    /// tried again; a newer list is.
    case failedBefore
}

public enum RuntimeInstallError: Error, CustomStringConvertible, Equatable {
    case badSignature
    case unsupportedSchema(Int)
    case checksumMismatch(component: String)
    case invalidComponent(String)
    case extractFailed(component: String, status: Int32)
    case olderThanInstalled
    case needsNewerApp(Int)
    case verificationFailed

    public var description: String {
        switch self {
        case .badSignature: "The runtime list isn't signed by Harbor."
        case .unsupportedSchema(let v): "The runtime list needs a newer Harbor (schema \(v))."
        case .checksumMismatch(let c): "The \(c) download is damaged (checksum mismatch)."
        case .invalidComponent(let c): "Unknown runtime component “\(c)”."
        case .extractFailed(let c, let s): "Couldn't unpack \(c) (tar exit \(s))."
        case .olderThanInstalled: "The runtime list is older than the installed Windows support."
        case .needsNewerApp(let b): "This Windows support needs a newer Harbor (build \(b))."
        case .verificationFailed: "The updated Windows support didn't start; the previous version was kept."
        }
    }
}

/// Downloads, verifies and installs runtime components into `WineRuntime.installedDirectory`.
///
/// Trust: the manifest must carry a valid Ed25519 signature from the key Harbor ships with; each archive must
/// match the manifest's SHA-256. Archives are `.tar.xz` of a component folder's contents. Files written this way
/// carry no quarantine flag; the Wine binaries are Developer ID-signed and notarized anyway.
public struct RuntimeInstaller: Sendable {
    public let manifestURL: URL
    public let publicKey: Curve25519.Signing.PublicKey
    public let installedDirectory: URL

    public init(manifestURL: URL, publicKey: Curve25519.Signing.PublicKey,
                installedDirectory: URL = WineRuntime.installedDirectory) {
        self.manifestURL = manifestURL
        self.publicKey = publicKey
        self.installedDirectory = installedDirectory
    }

    static let allowedIDs: Set<String> = ["wine", "d3dmetal"]

    /// Fetches and verifies the manifest.
    public func fetchManifest() async throws -> RuntimeManifest {
        let (data, _) = try await URLSession.shared.data(from: manifestURL)
        let (sigData, _) = try await URLSession.shared.data(from: manifestURL.appendingPathExtension("sig"))
        guard let signature = Data(base64Encoded: String(decoding: sigData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)),
              publicKey.isValidSignature(signature, for: data) else {
            throw RuntimeInstallError.badSignature
        }
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        guard manifest.schema <= RuntimeManifest.currentSchema else {
            throw RuntimeInstallError.unsupportedSchema(manifest.schema)
        }
        for c in manifest.components where !Self.allowedIDs.contains(c.id) {
            throw RuntimeInstallError.invalidComponent(c.id)
        }
        return manifest
    }

    public func installedVersion(of id: String) -> String? {
        (try? String(contentsOf: installedDirectory.appending(path: "\(id)/\(Self.versionFile)"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Components whose installed version differs from the manifest's.
    public func pending(in manifest: RuntimeManifest) -> [RuntimeManifest.Component] {
        manifest.components.filter { installedVersion(of: $0.id) != $0.version }
    }

    static let versionFile = ".harbor-version"
    static let sequenceFile = ".harbor-sequence"
    static let failedSequenceFile = ".harbor-failed-sequence"

    /// The sequence of a list whose runtime didn't start here (see `activateStaged`).
    public var failedSequence: Int? {
        (try? String(contentsOf: installedDirectory.appending(path: Self.failedSequenceFile), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether the installed runtime is at least the one `minimum` names (the app's `HarborMinimumRuntimeSequence`).
    /// An installation without a recorded sequence is older than any minimum.
    public func meetsMinimum(_ minimum: Int?) -> Bool {
        guard let minimum else { return true }
        return (installedSequence ?? Int.min) >= minimum
    }
    static let readyPrefix = ".ready-"

    /// The sequence of the list the installed runtime came from, if it was recorded.
    public var installedSequence: Int? {
        (try? String(contentsOf: installedDirectory.appending(path: Self.sequenceFile), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// What `manifest` means here. `appBuild` is this Harbor's build number (nil: don't check).
    public func decision(for manifest: RuntimeManifest, appBuild: Int?) -> RuntimeUpdateDecision {
        if let installed = installedSequence {
            guard let sequence = manifest.sequence, sequence >= installed else { return .refusedOlder }
        }
        let todo = pending(in: manifest)
        if todo.isEmpty { return .upToDate }
        if let failed = failedSequence, let sequence = manifest.sequence, sequence == failed { return .failedBefore }
        if let needed = manifest.minimumAppBuild, let appBuild, appBuild < needed { return .needsNewerApp(needed) }
        return .available(todo)
    }

    private func recordSequence(of manifest: RuntimeManifest) {
        guard let sequence = manifest.sequence else { return }
        try? Data("\(sequence)\n".utf8).write(to: installedDirectory.appending(path: Self.sequenceFile))
    }

    // MARK: Updating an installed runtime

    /// Whether a downloaded update is waiting to be switched to (`activateStaged`).
    public var hasStagedUpdate: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: installedDirectory.path)) ?? [])
            .contains { $0.hasPrefix(Self.readyPrefix) && $0 != Self.readyPrefix + "sequence" }
    }

    /// Downloads, verifies and unpacks every pending component next to the installed ones (`.ready-<id>`), without
    /// touching what's in use. Safe while Windows programs run. Throws instead of staging a list that
    /// `decision(for:appBuild:)` doesn't allow.
    public func stage(_ manifest: RuntimeManifest, appBuild: Int?,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let todo: [RuntimeManifest.Component]
        switch decision(for: manifest, appBuild: appBuild) {
        case .upToDate, .failedBefore: return
        case .refusedOlder: throw RuntimeInstallError.olderThanInstalled
        case .needsNewerApp(let build): throw RuntimeInstallError.needsNewerApp(build)
        case .available(let components): todo = components
        }
        let fm = FileManager.default
        let total = Double(max(todo.reduce(0) { $0 + $1.size }, 1))
        var done: Int64 = 0
        for component in todo {
            let base = done
            let ready = installedDirectory.appending(path: Self.readyPrefix + component.id)
            // Already downloaded by an earlier run.
            if (try? String(contentsOf: ready.appending(path: Self.versionFile), encoding: .utf8)) == component.version {
                done += component.size
                continue
            }
            let archive = try await fetch(component) { bytes in progress?(Double(base + bytes) / total) }
            defer { try? fm.removeItem(at: archive) }
            try withLock(installedDirectory.appending(path: ".lock")) {
                let staging = try unpack(component, archive: archive)
                try? fm.removeItem(at: ready)
                try fm.moveItem(at: staging, to: ready)
            }
            done += component.size
        }
        if let sequence = manifest.sequence {
            try Data("\(sequence)\n".utf8).write(to: installedDirectory.appending(path: Self.readyPrefix + "sequence"))
        }
        progress?(1)
    }

    /// Switches to the staged components. Call only when no Windows program is running. `verify` gets the installed
    /// directory after the switch and says whether the new runtime works; if it doesn't, the previous components
    /// are put back and `verificationFailed` is thrown. The previous versions stay as `.old-*` until
    /// `removeOldVersions()`.
    public func activateStaged(verify: (URL) -> Bool = { _ in true }) throws {
        let fm = FileManager.default
        try withLock(installedDirectory.appending(path: ".lock")) {
            let ready = ((try? fm.contentsOfDirectory(atPath: installedDirectory.path)) ?? [])
                .filter { $0.hasPrefix(Self.readyPrefix) && Self.allowedIDs.contains(String($0.dropFirst(Self.readyPrefix.count))) }
            guard !ready.isEmpty else { return }
            var swapped: [(target: URL, previous: URL?)] = []
            func rollBack() {
                for (target, previous) in swapped.reversed() {
                    try? fm.removeItem(at: target)
                    if let previous { try? fm.moveItem(at: previous, to: target) }
                }
            }
            do {
                for name in ready.sorted() {
                    let id = String(name.dropFirst(Self.readyPrefix.count))
                    let target = installedDirectory.appending(path: id)
                    var previous: URL?
                    if fm.fileExists(atPath: target.path) {
                        let aside = installedDirectory.appending(path: ".old-\(id)-\(UUID().uuidString)")
                        try fm.moveItem(at: target, to: aside)
                        previous = aside
                    }
                    swapped.append((target, previous))
                    try fm.moveItem(at: installedDirectory.appending(path: name), to: target)
                }
            } catch {
                rollBack()
                throw error
            }
            let staged = installedDirectory.appending(path: Self.readyPrefix + "sequence")
            guard verify(installedDirectory) else {
                rollBack()
                // Remember which list this was, so it isn't downloaded and tried again every few hours.
                try? fm.removeItem(at: installedDirectory.appending(path: Self.failedSequenceFile))
                try? fm.moveItem(at: staged, to: installedDirectory.appending(path: Self.failedSequenceFile))
                throw RuntimeInstallError.verificationFailed
            }
            if fm.fileExists(atPath: staged.path) {
                try? fm.removeItem(at: installedDirectory.appending(path: Self.sequenceFile))
                try? fm.moveItem(at: staged, to: installedDirectory.appending(path: Self.sequenceFile))
            }
        }
    }

    /// Installs every pending component. `progress` gets the fraction of all pending bytes downloaded so far.
    public func installPending(_ manifest: RuntimeManifest,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let todo = pending(in: manifest)
        let total = Double(max(todo.reduce(0) { $0 + $1.size }, 1))
        var done: Int64 = 0
        for component in todo {
            let base = done
            try await install(component) { bytes in progress?(Double(base + bytes) / total) }
            done += component.size
        }
        recordSequence(of: manifest)
        progress?(1)
    }

    /// Downloads a component's archive and checks it against the list's SHA-256.
    private func fetch(_ component: RuntimeManifest.Component, progress: (@Sendable (Int64) -> Void)?) async throws -> URL {
        guard Self.allowedIDs.contains(component.id) else { throw RuntimeInstallError.invalidComponent(component.id) }
        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
        let source = URL(string: component.url, relativeTo: manifestURL)!.absoluteURL
        let archive = try await download(source, progress: progress)
        guard try Self.sha256(of: archive) == component.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: archive)
            throw RuntimeInstallError.checksumMismatch(component: component.id)
        }
        return archive
    }

    /// Unpacks a verified archive into a new staging folder (with its version file) and returns it.
    private func unpack(_ component: RuntimeManifest.Component, archive: URL) throws -> URL {
        let fm = FileManager.default
        let staging = installedDirectory.appending(path: ".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let tar = Process()
            tar.executableURL = URL(filePath: "/usr/bin/tar")
            tar.arguments = ["-xf", archive.path, "-C", staging.path]
            try tar.runAndWait()
            guard tar.terminationStatus == 0 else {
                throw RuntimeInstallError.extractFailed(component: component.id, status: tar.terminationStatus)
            }
            try Data(component.version.utf8).write(to: staging.appending(path: Self.versionFile))
            return staging
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Downloads, verifies and atomically installs one component.
    public func install(_ component: RuntimeManifest.Component,
                        progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let fm = FileManager.default
        let archive = try await fetch(component, progress: progress)
        defer { try? fm.removeItem(at: archive) }

        try withLock(installedDirectory.appending(path: ".lock")) {
            let staging = try unpack(component, archive: archive)
            do {
                let target = installedDirectory.appending(path: component.id)
                if fm.fileExists(atPath: target.path) {
                    // Bottles may be running from the old one; move it aside, never delete it under them.
                    try fm.moveItem(at: target, to: installedDirectory.appending(path: ".old-\(component.id)-\(UUID().uuidString)"))
                }
                try fm.moveItem(at: staging, to: target)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
    }

    /// Removes versions that were moved aside by earlier updates. Call when no Wine process is running.
    public func removeOldVersions() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: installedDirectory.path)) ?? [] where name.hasPrefix(".old-") {
            try? fm.removeItem(at: installedDirectory.appending(path: name))
        }
    }

    private func download(_ url: URL, progress: (@Sendable (Int64) -> Void)?) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appending(path: "harbor-runtime-\(UUID().uuidString)")
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: destination)
            progress?((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
            return destination
        }
        let delegate = DownloadProgress(progress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Forwards a download task's byte progress.
final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: (@Sendable (Int64) -> Void)?
    private var observation: NSKeyValueObservation?

    init(_ onProgress: (@Sendable (Int64) -> Void)?) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard let onProgress else { return }
        observation = task.progress.observe(\.completedUnitCount) { progress, _ in
            onProgress(progress.completedUnitCount)
        }
    }
}

/// Harbor's runtime signing keys: raw 32-byte Curve25519 keys, base64-encoded.
public enum RuntimeSigning {
    public static func newPrivateKey() -> String {
        Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
    }

    public static func publicKey(forPrivate base64: String) throws -> String {
        try privateKey(base64).publicKey.rawRepresentation.base64EncodedString()
    }

    public static func sign(_ data: Data, privateKey base64: String) throws -> String {
        try privateKey(base64).signature(for: data).base64EncodedString()
    }

    public static func publicKey(_ base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: base64) else { throw RuntimeInstallError.badSignature }
        return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    static func privateKey(_ base64: String) throws -> Curve25519.Signing.PrivateKey {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw RuntimeInstallError.badSignature }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }
}
