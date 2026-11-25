import AppKit
import HarborKit
import SwiftUI

/// "Report a Problem…": the whole report, to be read and changed before anything leaves the Mac. Open in Browser
/// sends nothing itself (a new issue on GitHub opens with this text, and the user submits it there); Send to
/// Harbor is for people without an account there, and sends this text to Harbor's own service.
struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: AppModel.ReportDraft
    /// "Send to Harbor": on its way, or what came of it.
    @State private var sending = false
    @State private var reference: String?
    @State private var problem: String?

    var body: some View {
        if let reference { sent(reference) } else { report }
    }

    private var report: some View {
        let link = ProblemReport.issueLink(kind: draft.kind, title: draft.title, body: draft.text)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Report a Problem").font(.headline)
            Text("Open in Browser starts a new issue on GitHub with the text below; nothing is sent until you submit it there. Without a GitHub account, Send to Harbor sends the text to Harbor’s own service, which keeps it for 90 days. Your user name and your Mac’s name are left out; the log may still mention the program.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("Title", text: $draft.title, prompt: Text("What went wrong, in a few words"))
            TextEditor(text: $draft.text)
                .font(.callout.monospaced())
                .frame(minHeight: 280)
                .border(.separator)
            if link.shortened {
                // A link only holds so much (`ProblemReport.linkLimit`).
                Text("This is too long for a link, so the browser gets a shortened text. Open in Browser also copies all of it: paste it over the text there.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text("Couldn’t send the report. \(problem)")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Copy") { copy(draft.text) }
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send to Harbor") { send() }
                    .disabled(sending || draft.text.allSatisfy(\.isWhitespace))
                Button("Open in Browser") {
                    if link.shortened { copy(draft.text) }
                    NSWorkspace.shared.open(link.url)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.text.allSatisfy(\.isWhitespace))
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    /// The report is with Harbor's service. Its reference is the only way to it: nothing else connects the
    /// report with whoever sent it.
    private func sent(_ reference: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report Sent").font(.headline)
            Text("Harbor keeps it for 90 days. To have it deleted sooner, enter this reference on Harbor’s privacy page. It isn’t shown again.")
                .fixedSize(horizontal: false, vertical: true)
            Text(reference).font(.title3.monospaced()).textSelection(.enabled)
            HStack {
                Button("Copy Reference") { copy(reference) }
                Link("Privacy Page", destination: HarborService.privacyPage)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    private func send() {
        let (draft, service) = (draft, model.service)
        sending = true
        problem = nil
        Task {
            do {
                reference = try await ProblemReport.send(kind: draft.kind, title: draft.title, text: draft.text, service: service)
            } catch {
                problem = ErrorMessage.text(for: error)
            }
            sending = false
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Asked once, before anything is counted: whether to share statistics. Neither answer is the default button,
/// and Harbor works the same with either.
struct StatisticsQuestion: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share Anonymous Statistics?").font(.headline)
            Text("They show which kinds of problems are common, so those get fixed first. At most once a day Harbor would send how many programs ran and how many didn’t, by cause, with the versions of Harbor, Windows support and macOS and the name of this Mac’s chip.")
                .fixedSize(horizontal: false, vertical: true)
            Text("No program names, and nothing that identifies you or this Mac. Settings shows exactly what is sent next, and you can change your mind there at any time.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("What Harbor Sends", destination: HarborService.privacyPage)
                Spacer()
                Button("Don’t Share") { model.shareStatistics(false) }
                Button("Share") { model.shareStatistics(true) }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}

extension Bundle {
    /// Harbor's version and build, `1.2 (34)`, as Settings and a problem report show it.
    var harborVersion: String {
        let info = infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return "(development)" }
        return (info["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }
}
