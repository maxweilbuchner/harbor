import Foundation

/// Harbor's own receiving service (issue #50; its code is `service/collect`). Two things go there, each only
/// after the user said so: the statistics record (`UsageStatistics`) and a problem report sent with "Send to
/// Harbor" instead of through GitHub. The website's privacy page lists every field and how long it is kept.
public struct HarborService: Sendable {
    public static let endpoint = URL(string: "https://liipwgofoskaybprarjz.supabase.co/functions/v1/collect")!
    public static let privacyPage = URL(string: "https://maxweilbuchner.github.io/harbor/privacy/")!

    /// Sends a request and gives back the answer's body and status. Tests answer themselves.
    public var send: @Sendable (URLRequest) async throws -> (Data, Int)

    public init(send: @escaping @Sendable (URLRequest) async throws -> (Data, Int)) {
        self.send = send
    }

    /// Without cookies or a cache: a request carries its body and nothing remembered from an earlier one.
    public static let live = HarborService { request in
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public struct Refused: Error, CustomStringConvertible {
        public let status: Int
        public var description: String {
            status == 429 ? String(localized: "Harbor’s service has taken as much as it accepts today. Try again tomorrow.", bundle: Strings.bundle)
                          : String(localized: "Harbor’s service didn’t accept it (status \(String(status))).", bundle: Strings.bundle)
        }
    }

    /// Posts JSON to `path` below the endpoint; anything but a 2xx answer is an error.
    public func post(_ path: String, _ body: Data) async throws -> Data {
        var request = URLRequest(url: Self.endpoint.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else { throw Refused(status: status) }
        return data
    }
}

/// Opt-in usage statistics (issue #50): how many programs ran and how many didn't, by cause, with the versions
/// involved. Off until the user agrees; while it is off nothing is counted and nothing is sent. No program
/// names, and nothing that tells one Mac from another or one day's record from the same Mac's next: a record
/// holds the counts since the last one and is sent at most once a day.
public struct UsageStatistics: Sendable {
    public enum Outcome: String, CaseIterable, Sendable {
        /// The program ended without anything Harbor would tell the user about.
        case ran
        case missingLibrary, dotNet, shaderCompiler, antiCheat, crashed
        /// It ended right after starting, with an error and no recognised cause.
        case unexplained

        public init(_ cause: Diagnosis.Cause) {
            switch cause {
            case .missingLibrary: self = .missingLibrary
            case .dotNet: self = .dotNet
            case .shaderCompiler: self = .shaderCompiler
            case .antiCheat: self = .antiCheat
            case .crashed: self = .crashed
            }
        }
    }

    /// Everything that is sent. `json` is the request's body, byte for byte, and what Settings shows.
    public struct Record: Codable, Equatable, Sendable {
        /// Harbor's version and build, `1.2 (34)`.
        public var harbor: String
        /// The installed Windows support and its graphics layers.
        public var windowsSupport: String?
        /// `27.3`: no build number.
        public var macOS: String
        /// The chip's name, `Apple M3 Pro`.
        public var chip: String
        /// `Outcome` names with how often each happened since the last record.
        public var outcomes: [String: Int] = [:]

        public init(harbor: String, windowsSupport: String?, macOS: String, chip: String) {
            self.harbor = Self.plain(harbor)
            self.windowsSupport = windowsSupport.map(Self.plain)
            self.macOS = Self.plain(macOS)
            self.chip = Self.plain(chip)
        }

        /// With this Mac's macOS version and chip.
        public static func onThisMac(harbor: String, windowsSupport: String?) -> Record {
            let system = ProcessInfo.processInfo.operatingSystemVersion
            return Record(harbor: harbor, windowsSupport: windowsSupport, macOS: "\(system.majorVersion).\(system.minorVersion)",
                          chip: ProblemReport.Versions.onThisMac(harbor: harbor, windowsSupport: windowsSupport).chip)
        }

        public var json: Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? encoder.encode(self)) ?? Data()
        }

        /// The service takes versions as short plain text (letters, digits and ` .,()+_-`) and refuses the rest.
        private static func plain(_ text: String) -> String {
            let kept = text.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " .,()+_-".unicodeScalars.contains($0)) }
            let short = String(String.UnicodeScalarView(kept).prefix(80))
            return short.isEmpty ? "unknown" : short
        }
    }

    /// Safe from any thread (Foundation says so); the type just isn't marked.
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let consentKey = "HarborShareStatistics"
    private static let countsKey = "HarborStatisticsCounts"
    private static let attemptKey = "HarborStatisticsLastSent"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// nil until the user has answered the question. Turning it off forgets what was counted.
    public var consent: Bool? {
        get { defaults.object(forKey: Self.consentKey) as? Bool }
        nonmutating set {
            defaults.set(newValue, forKey: Self.consentKey)
            if newValue != true {
                defaults.removeObject(forKey: Self.countsKey)
                defaults.removeObject(forKey: Self.attemptKey)
            }
        }
    }

    public var counts: [String: Int] {
        (defaults.dictionary(forKey: Self.countsKey) as? [String: Int]) ?? [:]
    }

    /// One more program that ended this way. Nothing is counted unless the user agreed.
    public func count(_ outcome: Outcome) {
        guard consent == true else { return }
        var counts = counts
        counts[outcome.rawValue, default: 0] += 1
        defaults.set(counts, forKey: Self.countsKey)
    }

    /// What would be sent next: `versions` with the counts so far. nil while off or while there is nothing to say.
    public func record(_ versions: Record) -> Record? {
        guard consent == true, !counts.isEmpty else { return nil }
        var record = versions
        record.outcomes = counts
        return record
    }

    /// Sends the record if there is one and the last try was a day or more ago. What was sent is taken off the
    /// counts; a failed try keeps them for the next day's.
    public func sendIfDue(_ versions: Record, now: Date = Date(), service: HarborService = .live) async {
        guard let record = record(versions) else { return }
        if let last = defaults.object(forKey: Self.attemptKey) as? Date, now.timeIntervalSince(last) < 86_400 { return }
        defaults.set(now, forKey: Self.attemptKey)
        guard (try? await service.post("statistics", record.json)) != nil else { return }
        // Turned off meanwhile: nothing is left to take off, and nothing is put back.
        guard consent == true else { return }
        var left = counts
        for (outcome, sent) in record.outcomes {
            let rest = (left[outcome] ?? 0) - sent
            left[outcome] = rest > 0 ? rest : nil
        }
        defaults.set(left, forKey: Self.countsKey)
    }
}

extension ProblemReport {
    /// Sends a report the user has read to Harbor's own service, for people without a GitHub account. Gives
    /// back the reference the service made for it: whoever has it can have the report deleted (the privacy page).
    public static func send(kind: Kind, title: String, text: String, service: HarborService = .live) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["kind": kind == .program ? "program" : "harbor", "title": String(title.prefix(200)),
                                                               "body": String(text.prefix(20_000))])
        let answer = try await service.post("reports", body)
        guard let reference = (try? JSONSerialization.jsonObject(with: answer) as? [String: String])?["reference"] else {
            throw HarborService.Refused(status: 200)
        }
        return reference
    }
}
