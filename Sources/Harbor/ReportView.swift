import AppKit
import HarborKit
import SwiftUI

/// "Report a Problem…": the whole report, to be read and changed before anything leaves the Mac. Harbor sends
/// nothing itself: it opens a new issue on GitHub in the browser with this text, and the user submits it there.
struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: AppModel.ReportDraft

    var body: some View {
        let link = ProblemReport.issueLink(kind: draft.kind, title: draft.title, body: draft.text)
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a Problem").font(.headline)
            Text("This opens a new issue on GitHub in your browser with the text below. Nothing is sent until you submit it there. Your user name and your Mac’s name are left out; the log may still mention the program.")
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
            HStack {
                Button("Copy") { copy() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open in Browser") {
                    if link.shortened { copy() }
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

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft.text, forType: .string)
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
