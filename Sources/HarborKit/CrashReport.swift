import Foundation

/// The reports macOS writes when Harbor itself crashes (`~/Library/Logs/DiagnosticReports/Harbor-….ips`), cut
/// down to what a problem report may carry (#50): what stopped it and where, with nothing that names the Mac.
public enum CrashReport {
    public static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs/DiagnosticReports")
    }

    /// The newest report about `process` written after `since`.
    public static func latest(of process: String = "Harbor", in directory: URL = Self.directory, after since: Date) -> URL? {
        let reports = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(process + "-") && $0.pathExtension == "ips" }
            .compactMap { url in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) } }
            .filter { $0.1 > since }
        return reports.max { $0.1 < $1.1 }?.0
    }

    /// The report in a few lines: versions, the exception, and the crashed thread's frames (library, function,
    /// offset). A report is one line of JSON and then a JSON document; of the second only these parts are read.
    /// Left out on purpose: the report's and the Mac's identifiers (incident, crash reporter key, boot and sleep
    /// UUIDs, user ID), every other thread and the list of loaded libraries with their paths.
    public static func summary(of report: URL, frames limit: Int = 30) -> String? {
        guard let text = try? String(contentsOf: report, encoding: .utf8), let split = text.firstIndex(of: "\n"),
              let head = (try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8))) as? [String: Any],
              let body = (try? JSONSerialization.jsonObject(with: Data(text[split...].utf8))) as? [String: Any] else { return nil }
        var lines: [String] = []
        let version = [head["app_version"] as? String, head["build_version"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
        if !version.isEmpty { lines.append("Version: " + version.joined(separator: " (") + (version.count > 1 ? ")" : "")) }
        if let os = head["os_version"] as? String { lines.append("macOS: \(os)") }
        if let exception = body["exception"] as? [String: Any] {
            let parts = [exception["type"], exception["signal"].map { "(\($0))" }, exception["subtype"]].compactMap { $0 as? String }
            lines.append("Exception: " + parts.joined(separator: " "))
        }
        if let indicator = (body["termination"] as? [String: Any])?["indicator"] as? String { lines.append("Ended by: \(indicator)") }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let crashed = threads.first { $0["triggered"] as? Bool == true } ?? (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
        if let crashed {
            lines.append("Crashed thread" + ((crashed["queue"] as? String).map { " (\($0))" } ?? "") + ":")
            let all = (crashed["frames"] as? [[String: Any]]) ?? []
            for (n, frame) in all.prefix(limit).enumerated() {
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "?"
                let place = (frame["symbol"] as? String).map { "\($0) + \(frame["symbolLocation"] as? Int ?? 0)" }
                    ?? "0x" + String(frame["imageOffset"] as? Int ?? 0, radix: 16)
                lines.append("  \(n)  \(image)  \(place)")
            }
            if all.count > limit { lines.append("  … \(all.count - limit) more") }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
