import Foundation
import os
import Testing
@testable import HarborKit

/// Statistics are off until agreed to, hold nothing but counts and versions, and go out at most once a day (#50).
@Suite struct UsageStatisticsTests {
    let suite = "harbor-statistics-\(UUID().uuidString)"
    var statistics: UsageStatistics { UsageStatistics(defaults: UserDefaults(suiteName: suite)!) }
    let versions = UsageStatistics.Record(harbor: "1.2 (34)", windowsSupport: "26.3.0-9 (D3DMetal 4.0b3)", macOS: "27.3", chip: "Apple M3 Pro")

    /// A service that notes each request and answers with `status`.
    func service(_ status: Int = 201, into sent: OSAllocatedUnfairLock<[URLRequest]>) -> HarborService {
        HarborService { request in
            sent.withLock { $0.append(request) }
            return (Data("{}".utf8), status)
        }
    }

    func cleanUp() { UserDefaults().removePersistentDomain(forName: suite) }

    @Test func nothingIsCountedOrSentBeforeTheUserAgreed() async {
        defer { cleanUp() }
        let sent = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
        for answer in [nil, false] as [Bool?] {
            if let answer { statistics.consent = answer }
            statistics.count(.ran)
            statistics.count(.crashed)
            #expect(statistics.counts.isEmpty && statistics.record(versions) == nil)
            await statistics.sendIfDue(versions, service: service(into: sent))
        }
        #expect(sent.withLock { $0.isEmpty })
    }

    @Test func theRecordIsWhatIsSentAndIsSentOnceADay() async throws {
        defer { cleanUp() }
        let sent = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
        statistics.consent = true
        statistics.count(.ran)
        statistics.count(.ran)
        statistics.count(UsageStatistics.Outcome(.missingLibrary("d3dx9_43.dll", recipe: nil)))
        let record = try #require(statistics.record(versions))
        #expect(record.outcomes == ["ran": 2, "missingLibrary": 1])
        // Exactly these fields: no name, no identifier, no time.
        let fields = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(Set(fields.keys) == ["harbor", "windowsSupport", "macOS", "chip", "outcomes"])

        let now = Date()
        await statistics.sendIfDue(versions, now: now, service: service(into: sent))
        let request = try #require(sent.withLock { $0.first })
        #expect(request.url?.absoluteString == HarborService.endpoint.absoluteString + "/statistics")
        #expect(request.httpBody == record.json)
        #expect(statistics.counts.isEmpty)

        // What happens later the same day waits for the next.
        statistics.count(.crashed)
        await statistics.sendIfDue(versions, now: now.addingTimeInterval(3600), service: service(into: sent))
        #expect(sent.withLock { $0.count } == 1 && statistics.counts == ["crashed": 1])
        await statistics.sendIfDue(versions, now: now.addingTimeInterval(86_400), service: service(into: sent))
        #expect(sent.withLock { $0.count } == 2 && statistics.counts.isEmpty)
    }

    @Test func aFailedSendKeepsTheCountsAndTurningOffForgetsThem() async {
        defer { cleanUp() }
        let sent = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
        statistics.consent = true
        statistics.count(.dotNet)
        await statistics.sendIfDue(versions, service: service(500, into: sent))
        #expect(statistics.counts == ["dotNet": 1])
        statistics.consent = false
        #expect(statistics.counts.isEmpty && statistics.record(versions) == nil)
    }

    /// The service refuses anything but short plain text, so that is all a version can be.
    @Test func versionsArePlainText() {
        let record = UsageStatistics.Record(harbor: "(development)", windowsSupport: "this checkout’s own build", macOS: "27.3", chip: "")
        #expect(record.windowsSupport == "this checkouts own build" && record.chip == "unknown" && record.harbor == "(development)")
    }

    @Test func aReportSentToHarborComesBackWithItsReference() async throws {
        let sent = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
        let service = HarborService { request in
            sent.withLock { $0.append(request) }
            return (Data(#"{"reference":"AAAA-BBBB-CCCC-DDDD"}"#.utf8), 201)
        }
        let reference = try await ProblemReport.send(kind: .program, title: "A program crashes", text: "the text", service: service)
        #expect(reference == "AAAA-BBBB-CCCC-DDDD")
        let body = try #require(sent.withLock { $0.first }?.httpBody)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["kind": "program", "title": "A program crashes", "body": "the text"])
        await #expect(throws: HarborService.Refused.self) {
            try await ProblemReport.send(kind: .harbor, title: "", text: "x", service: HarborService { _ in (Data(), 429) })
        }
    }
}
