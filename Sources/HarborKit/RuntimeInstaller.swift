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

/// Where an update to installed Windows support stands, for Settings and the main window.
public enum RuntimeUpdateState: Equatable, Sendable {
    case idle
    case checking
    case downloading(Double)
    /// Downloaded; installed once no Windows program is running.
    case ready
    /// The published runtime needs a newer Harbor.
    case needsNewerApp
    /// The published runtime didn't start on this Mac before and was rolled back; only a newer list is tried.
    case failedBefore
    case failed(String)

    /// A check or download is under way (so another can't be started).
    public var isBusy: Bool {
        switch self {
        case .checking, .downloading: true
        default: false
        }
    }

    /// The state after the published list couldn't be read. A list from a newer format means a newer Harbor is
    /// needed. Otherwise someone who asked is told why; a check in the background stays quiet and leaves what was
    /// known before (an earlier failure or "needs a newer Harbor" must not turn into "up to date").
    public static func afterFailedCheck(_ error: any Error, previous: RuntimeUpdateState, userAsked: Bool) -> RuntimeUpdateState {
        if case RuntimeInstallError.unsupportedSchema = error { return .needsNewerApp }
        if userAsked { return .failed(RuntimeInstallError.message(for: error)) }
        return previous.isBusy ? .idle : previous
    }

    /// What to say about `program`, which can't start because the installed Windows support is older than this
    /// Harbor needs, when the update that was looked for stands here and the support is still too old. `running`
    /// is a program that keeps a downloaded update from being installed (nil: its name isn't known).
    public func statusWhileTooOld(starting program: String, running: String?) -> String {
        switch self {
        case .checking, .downloading:
            String(localized: "Updating Windows support first. Start \(program) again when that’s done.", bundle: Strings.bundle)
        case .ready:
            if let running {
                String(localized: "Quit \(running) to finish updating Windows support, then start \(program) again.", bundle: Strings.bundle)
            } else {
                String(localized: "Quit your Windows programs to finish updating Windows support, then start \(program) again.", bundle: Strings.bundle)
            }
        case .needsNewerApp:
            String(localized: "\(program) needs newer Windows support, which needs a newer Harbor. Choose Harbor > Check for Updates…", bundle: Strings.bundle)
        case .failedBefore:
            String(localized: "\(program) needs newer Windows support, but the newest didn’t start on this Mac. Harbor tries the next one published.", bundle: Strings.bundle)
        case .failed(let message):
            String(localized: "Windows support couldn’t be updated: \(message)", bundle: Strings.bundle)
        case .idle:
            String(localized: "\(program) needs newer Windows support than is published yet. Try again later.", bundle: Strings.bundle)
        }
    }
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
    /// The update didn't start either, but its previous version was no longer on disk to go back to.
    case unprovenUpdateKept
    case badURL(component: String)

    public var description: String {
        // Versions, builds and exit codes go in as text: a number would be written with grouping (“1,234”).
        switch self {
        case .badSignature: String(localized: "The runtime list isn't signed by Harbor.", bundle: Strings.bundle)
        case .unsupportedSchema(let v): String(localized: "The runtime list needs a newer Harbor (schema \(String(v))).", bundle: Strings.bundle)
        case .checksumMismatch(let c): String(localized: "The \(c) download is damaged (checksum mismatch).", bundle: Strings.bundle)
        case .invalidComponent(let c): String(localized: "Unknown runtime component “\(c)”.", bundle: Strings.bundle)
        case .extractFailed(let c, let s): String(localized: "Couldn't unpack \(c) (tar exit \(String(s))).", bundle: Strings.bundle)
        case .olderThanInstalled: String(localized: "The runtime list is older than the installed Windows support.", bundle: Strings.bundle)
        case .needsNewerApp(let b): String(localized: "This Windows support needs a newer Harbor (build \(String(b))).", bundle: Strings.bundle)
        case .verificationFailed: String(localized: "The updated Windows support didn't start; the previous version was kept.", bundle: Strings.bundle)
        case .unprovenUpdateKept: String(localized: "The updated Windows support didn't start when Harbor tried it, and the previous version is gone, so the update stays installed.", bundle: Strings.bundle)
        case .badURL(let c): String(localized: "The runtime list has no usable address for \(c).", bundle: Strings.bundle)
        }
    }
}

/// Downloads, verifies and installs runtime components into `WineRuntime.installedDirectory`.
///
/// Trust: the manifest must carry a valid Ed25519 signature from the key Harbor ships with; each archive must
/// match the manifest's SHA-256. Archives are `.tar.xz` of a component folder's contents. Files written this way
/// carry no quarantine flag; the Wine binaries are Developer ID-signed and notarized anyway.
extension RuntimeInstallError {
    /// One readable sentence for anything an update can fail with. Harbor's own errors describe themselves; a
    /// network error's `String(describing:)` is a dump of its domain, code and user info.
    public static func message(for error: any Error) -> String {
        switch error {
        case let error as RuntimeInstallError: error.description
        case let error as URLError:
            // The system's sentence where it has one ("The network connection was lost."), not its fallback
            // that names the error domain and code.
            error.localizedDescription.contains("NSURLErrorDomain")
                ? String(localized: "The update server couldn’t be reached.", bundle: Strings.bundle)
                : String(localized: "The update server couldn’t be reached: \(error.localizedDescription)", bundle: Strings.bundle)
        case is DecodingError: String(localized: "The update list couldn’t be read.", bundle: Strings.bundle)
        default: error.localizedDescription
        }
    }
}

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

    /// Fetches and verifies the manifest. A list that doesn't match its signature is fetched once more after
    /// `pause` (a few seconds; injectable for tests): publishing replaces the two files one after the other, and
    /// a check in between sees the new one beside the old other. Each attempt verifies the very bytes it fetched.
    public func fetchManifest(pause: () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) async throws -> RuntimeManifest {
        var data = Data()
        for attempt in 1...2 {
            // The second look must not be answered with the first one's files from the URL cache.
            let policy: URLRequest.CachePolicy = attempt == 1 ? .useProtocolCachePolicy : .reloadIgnoringLocalCacheData
            let (list, response) = try await URLSession.shared.data(for: URLRequest(url: manifestURL, cachePolicy: policy))
            let (sigData, sigResponse) = try await URLSession.shared.data(
                for: URLRequest(url: manifestURL.appendingPathExtension("sig"), cachePolicy: policy))
            // Before the signature: an error page isn't a list that someone else signed.
            try Self.checkStatus(response)
            try Self.checkStatus(sigResponse)
            if let signature = Data(base64Encoded: String(decoding: sigData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)),
               publicKey.isValidSignature(signature, for: list) {
                data = list
                break
            }
            if attempt == 2 { throw RuntimeInstallError.badSignature }
            try await pause()
        }
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        guard manifest.schema <= RuntimeManifest.currentSchema else {
            throw RuntimeInstallError.unsupportedSchema(manifest.schema)
        }
        // A component this build doesn't know isn't an error here: it is left out (`pending`), and the list's
        // `minimumAppBuild` says whether a newer Harbor is needed for it (`decision`).
        return manifest
    }

    /// Throws for an HTTP answer that isn't a success (a missing file, a server error): its body is an error
    /// page, not the list or an archive. Other kinds of URL have no status.
    static func checkStatus(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    public func installedVersion(of id: String) -> String? {
        Self.installedVersion(of: id, in: installedDirectory)
    }

    /// The version of a downloaded component in `directory`; needs no download location, so it also answers in
    /// builds that have none.
    public static func installedVersion(of id: String, in directory: URL = WineRuntime.installedDirectory) -> String? {
        (try? String(contentsOf: directory.appending(path: "\(id)/\(versionFile)"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A component version the way Settings shows it: "26.3.0-7" is "26.3.0 (7)" (the Wine sources' version and
    /// Harbor's revision of it), "4.0b3-2" is "4.0b3 (2)"; anything else stays as it is. Runtimes up to revision 6
    /// carry a "cx" in front ("cx26.3.0-6"), which isn't shown.
    public static func displayVersion(_ version: String) -> String {
        let base = version.hasPrefix("cx") ? String(version.dropFirst(2)) : version
        guard let dash = base.lastIndex(of: "-") else { return base }
        let (name, revision) = (base[..<dash], base[base.index(after: dash)...])
        guard !name.isEmpty, !revision.isEmpty, revision.allSatisfy(\.isNumber) else { return base }
        return "\(name) (\(revision))"
    }

    /// When the installed runtime was put in place: installing and switching to an update both stamp the sequence
    /// record with that moment (installations without one fall back to the Wine component's folder).
    public var installedDate: Date? { Self.installedDate(in: installedDirectory) }

    public static func installedDate(in directory: URL = WineRuntime.installedDirectory) -> Date? {
        for name in [sequenceFile, "wine"] {
            let url = directory.appending(path: name)
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { return date }
        }
        return nil
    }

    /// Components whose installed version differs from the manifest's. Only the ones this build knows: a list may
    /// name others for a newer Harbor.
    public func pending(in manifest: RuntimeManifest) -> [RuntimeManifest.Component] {
        manifest.components.filter { Self.allowedIDs.contains($0.id) && installedVersion(of: $0.id) != $0.version }
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
        // A component this build doesn't know is something new too, but only a newer Harbor can take it.
        let unknown = manifest.components.contains { !Self.allowedIDs.contains($0.id) }
        if todo.isEmpty && !unknown { return .upToDate }
        if !todo.isEmpty, let failed = failedSequence, let sequence = manifest.sequence, sequence == failed { return .failedBefore }
        if let needed = manifest.minimumAppBuild, let appBuild, appBuild < needed { return .needsNewerApp(needed) }
        return todo.isEmpty ? .upToDate : .available(todo)
    }

    /// Throws when the record can't be written: without it the installation has no protection against older
    /// lists and counts as too old for any minimum, which nobody would notice.
    private func recordSequence(of manifest: RuntimeManifest) throws {
        guard let sequence = manifest.sequence else { return }
        try Data("\(sequence)\n".utf8).write(to: installedDirectory.appending(path: Self.sequenceFile))
    }

    /// Records the sequence of a list whose components are all installed already (`decision` said `.upToDate`),
    /// if it is a newer one than the record. Every published list gets a new sequence, also one with unchanged
    /// components; with nothing pending, nothing else would bring it along, and the installation would stay older
    /// than an app's minimum (`meetsMinimum`) for good. Nothing was installed just now, so `installedDate` stays.
    public func recordSequenceOfInstalled(_ manifest: RuntimeManifest) throws {
        guard let sequence = manifest.sequence, sequence > installedSequence ?? Int.min, !hasStagedUpdate else { return }
        let date = installedDate
        try recordSequence(of: manifest)
        if let date {
            try? FileManager.default.setAttributes([.modificationDate: date],
                                                   ofItemAtPath: installedDirectory.appending(path: Self.sequenceFile).path)
        }
    }

    // MARK: Updating an installed runtime

    /// Whether a downloaded update is waiting to be switched to (`activateStaged`): every pending component of its
    /// list was staged. A download that stopped part-way leaves its finished components (`.ready-<id>`) for the
    /// next `stage` to continue from, but isn't an update to switch to: that would install one component without
    /// the others and without the list's sequence. A switch that was interrupted waits to be finished the same way.
    public var hasStagedUpdate: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: installedDirectory.appending(path: Self.stagedMarker).path)
            || fm.fileExists(atPath: installedDirectory.appending(path: Self.switchNote).path)
    }

    /// Written when `stage` has finished, removed when the update is switched to (or turns out not to start).
    static let stagedMarker = readyPrefix + "complete"

    /// Written before a switch moves anything, removed when it has ended either way: one line per component, its
    /// id and (after a tab) the name its previous version is moved aside to. If Harbor quits, crashes or loses
    /// power in between, the next `activateStaged` finds what was being done and finishes it or puts it back.
    static let switchNote = ".harbor-switching"

    /// The components an interrupted switch was moving (empty: none was interrupted).
    private var interruptedSwitch: [(id: String, previous: String?)] {
        guard let note = try? String(contentsOf: installedDirectory.appending(path: Self.switchNote), encoding: .utf8) else { return [] }
        return note.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, Self.allowedIDs.contains(fields[0]) else { return nil }
            return (fields[0], fields[1].hasPrefix(".old-\(fields[0])-") && !fields[1].contains("/") ? fields[1] : nil)
        }
    }

    /// Downloads, verifies and unpacks every pending component next to the installed ones (`.ready-<id>`), without
    /// touching what's in use. Safe while Windows programs run. Throws instead of staging a list that
    /// `decision(for:appBuild:)` doesn't allow. Does nothing while an interrupted switch waits to be finished
    /// (`activateStaged`): its components must stay as they are.
    public func stage(_ manifest: RuntimeManifest, appBuild: Int?,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard interruptedSwitch.isEmpty else { return }
        let decision = decision(for: manifest, appBuild: appBuild)
        var todo: [RuntimeManifest.Component] = []
        if case .available(let components) = decision { todo = components }
        try discardStaged(except: todo)
        switch decision {
        case .upToDate:
            try recordSequenceOfInstalled(manifest)
            return
        case .failedBefore: return
        case .refusedOlder: throw RuntimeInstallError.olderThanInstalled
        case .needsNewerApp(let build): throw RuntimeInstallError.needsNewerApp(build)
        case .available: break
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
        try Data().write(to: installedDirectory.appending(path: Self.stagedMarker))
        progress?(1)
    }

    /// Before a list is staged: what an earlier `stage` left only counts as far as this list wants it. The marker
    /// and the sequence go (they are written again at the end), and so does every staged component that isn't
    /// one of `wanted` in that version. `activateStaged` installs whatever is staged once the marker is there, so
    /// a component of another list would be switched to along with this one's.
    private func discardStaged(except wanted: [RuntimeManifest.Component]) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: installedDirectory.path) else { return }
        try withLock(installedDirectory.appending(path: ".lock")) {
            try? fm.removeItem(at: installedDirectory.appending(path: Self.stagedMarker))
            try? fm.removeItem(at: installedDirectory.appending(path: Self.readyPrefix + "sequence"))
            for id in Self.allowedIDs {
                let ready = installedDirectory.appending(path: Self.readyPrefix + id)
                let version = try? String(contentsOf: ready.appending(path: Self.versionFile), encoding: .utf8)
                if !wanted.contains(where: { $0.id == id && $0.version == version }) { try? fm.removeItem(at: ready) }
            }
        }
    }

    /// Switches to the staged components. Call only when no Windows program is running. `verify` gets the installed
    /// directory after the switch and says whether the new runtime works; if it doesn't, the previous components
    /// are put back and `verificationFailed` is thrown. The previous versions stay as `.old-*` until
    /// `removeOldVersions()`. A switch that was interrupted (Harbor quit before the new runtime was proven and its
    /// sequence recorded) is taken up where it stopped, and ends the same two ways. Only if its previous versions
    /// are gone by then, there is nothing to put back: the new components stay and `unprovenUpdateKept` is thrown.
    public func activateStaged(verify: (URL) -> Bool = { _ in true }) throws {
        let fm = FileManager.default
        try withLock(installedDirectory.appending(path: ".lock")) {
            let note = installedDirectory.appending(path: Self.switchNote)
            var plan = interruptedSwitch
            if plan.isEmpty {
                let ready = ((try? fm.contentsOfDirectory(atPath: installedDirectory.path)) ?? [])
                    .filter { $0.hasPrefix(Self.readyPrefix) && Self.allowedIDs.contains(String($0.dropFirst(Self.readyPrefix.count))) }
                guard !ready.isEmpty, fm.fileExists(atPath: installedDirectory.appending(path: Self.stagedMarker).path) else {
                    try? fm.removeItem(at: note)
                    return
                }
                plan = ready.sorted().map { name in
                    let id = String(name.dropFirst(Self.readyPrefix.count))
                    let installed = fm.fileExists(atPath: installedDirectory.appending(path: id).path)
                    return (id, installed ? ".old-\(id)-\(UUID().uuidString)" : nil)
                }
                // Before anything moves, so that a switch which doesn't get to its end can be finished later.
                try Data(plan.map { "\($0.id)\t\($0.previous ?? "")\n" }.joined().utf8).write(to: note, options: .atomic)
            }
            try? fm.removeItem(at: installedDirectory.appending(path: Self.stagedMarker))
            // A component whose staged folder is gone has been moved into place (now, or before an interruption).
            func rollBack() {
                for (id, previous) in plan.reversed() {
                    let target = installedDirectory.appending(path: id)
                    if !fm.fileExists(atPath: installedDirectory.appending(path: Self.readyPrefix + id).path) {
                        try? fm.removeItem(at: target)
                    }
                    if let previous, !fm.fileExists(atPath: target.path) {
                        try? fm.moveItem(at: installedDirectory.appending(path: previous), to: target)
                    }
                }
                try? fm.removeItem(at: note)
            }
            // Only an interrupted switch can find a previous version gone (something removed it since). Rolling
            // back then would delete the new component, which is in place, and have nothing to put there.
            func canRollBack() -> Bool {
                plan.allSatisfy { id, previous in
                    guard let previous, !fm.fileExists(atPath: installedDirectory.appending(path: Self.readyPrefix + id).path) else { return true }
                    return fm.fileExists(atPath: installedDirectory.appending(path: previous).path)
                }
            }
            do {
                for (id, previous) in plan {
                    let ready = installedDirectory.appending(path: Self.readyPrefix + id)
                    let target = installedDirectory.appending(path: id)
                    guard fm.fileExists(atPath: ready.path) else { continue }
                    if fm.fileExists(atPath: target.path) {
                        // The noted name, unless it is taken (the previous version went there before an
                        // interruption and something was installed since).
                        let aside = previous.flatMap { fm.fileExists(atPath: installedDirectory.appending(path: $0).path) ? nil : $0 }
                            ?? ".old-\(id)-\(UUID().uuidString)"
                        try fm.moveItem(at: target, to: installedDirectory.appending(path: aside))
                    }
                    try fm.moveItem(at: ready, to: target)
                }
            } catch {
                // Without the previous versions the note stays, and the switch is taken up again next time.
                if canRollBack() { rollBack() }
                throw error
            }
            let staged = installedDirectory.appending(path: Self.readyPrefix + "sequence")
            guard verify(installedDirectory) else {
                // With a previous version missing the whole update stays in place, unproven: one runtime that
                // may not start is more than none, and its components belong together.
                let kept = !canRollBack()
                if kept { try? fm.removeItem(at: note) } else { rollBack() }
                // Remember which list this was, so it isn't downloaded and tried again every few hours.
                try? fm.removeItem(at: installedDirectory.appending(path: Self.failedSequenceFile))
                try? fm.moveItem(at: staged, to: installedDirectory.appending(path: Self.failedSequenceFile))
                throw kept ? RuntimeInstallError.unprovenUpdateKept : RuntimeInstallError.verificationFailed
            }
            if fm.fileExists(atPath: staged.path) {
                try? fm.removeItem(at: installedDirectory.appending(path: Self.sequenceFile))
                try? fm.moveItem(at: staged, to: installedDirectory.appending(path: Self.sequenceFile))
            }
            // The switch is the moment of installation (`installedDate`), not the download: the staged files
            // keep their dates when they are moved.
            for name in [Self.sequenceFile, "wine"] {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: installedDirectory.appending(path: name).path)
            }
            try? fm.removeItem(at: note)
        }
    }

    /// `activateStaged(verify:)` and then `removeOldVersions()`, each only while `idle` says that no Windows
    /// program is running; returns whether that was so for the switch. `idle` is asked right before the switch,
    /// not when the download began, and again before the previous versions go: proving the new Wine takes up to
    /// a minute, and something started meanwhile may run from them.
    @discardableResult
    public func activateStagedIfIdle(_ idle: () -> Bool, verify: (URL) -> Bool = { _ in true }) throws -> Bool {
        guard idle() else { return false }
        try activateStaged(verify: verify)
        if idle() { removeOldVersions() }
        return true
    }

    /// Installs every pending component. `progress` gets the fraction of all pending bytes downloaded so far.
    /// Like `stage`, throws instead of installing a list that `decision(for:appBuild:)` doesn't allow.
    public func installPending(_ manifest: RuntimeManifest, appBuild: Int? = nil,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws {
        switch decision(for: manifest, appBuild: appBuild) {
        case .refusedOlder: throw RuntimeInstallError.olderThanInstalled
        case .needsNewerApp(let build): throw RuntimeInstallError.needsNewerApp(build)
        // Someone asked for this install, so a list that didn't start here before is tried again.
        case .upToDate, .available, .failedBefore: break
        }
        let todo = pending(in: manifest)
        let total = Double(max(todo.reduce(0) { $0 + $1.size }, 1))
        var done: Int64 = 0
        for component in todo {
            let base = done
            try await install(component) { bytes in progress?(Double(base + bytes) / total) }
            done += component.size
        }
        try recordSequence(of: manifest)
        progress?(1)
    }

    /// Downloads a component's archive and checks it against the list's SHA-256.
    private func fetch(_ component: RuntimeManifest.Component, progress: (@Sendable (Int64) -> Void)?) async throws -> URL {
        guard Self.allowedIDs.contains(component.id) else { throw RuntimeInstallError.invalidComponent(component.id) }
        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
        // A signed list can still carry an address that is empty or no URL at all.
        guard !component.url.isEmpty, let source = URL(string: component.url, relativeTo: manifestURL)?.absoluteURL else {
            throw RuntimeInstallError.badURL(component: component.id)
        }
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

    /// Removes versions that were moved aside by earlier updates. Call when no Wine process is running. Also
    /// removes what an unpack left that was interrupted (Harbor quit meanwhile): every unpack holds the lock, so a
    /// `.staging-*` folder seen under it belongs to none that is still going. Leaves everything while an
    /// interrupted switch waits to be finished: it may have to put the previous versions back.
    public func removeOldVersions() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: installedDirectory.path) else { return }
        try? withLock(installedDirectory.appending(path: ".lock")) {
            guard interruptedSwitch.isEmpty else { return }
            for name in (try? fm.contentsOfDirectory(atPath: installedDirectory.path)) ?? []
            where name.hasPrefix(".old-") || name.hasPrefix(".staging-") {
                try? fm.removeItem(at: installedDirectory.appending(path: name))
            }
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
        do { try Self.checkStatus(response) } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
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
