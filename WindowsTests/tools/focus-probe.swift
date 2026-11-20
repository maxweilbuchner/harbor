// Records, twice a second, which app is frontmost and the front-to-back order of the on-screen windows of Wine
// programs (owner, pid, size, level), only when something changed. For focus and window-order bugs that need a
// person at the trackpad (Space swipes can't be synthesised). Usage: focus-probe <seconds> [owner-substring…]
import AppKit
import CoreGraphics

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "120") ?? 120
let filters = CommandLine.arguments.dropFirst(2).map { $0.lowercased() }
let start = Date()
var last = ""
let formatter = DateFormatter()
formatter.dateFormat = "HH:mm:ss.SSS"
setvbuf(stdout, nil, _IOLBF, 0)
while Date().timeIntervalSince(start) < seconds {
    let front = NSWorkspace.shared.frontmostApplication
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var rows: [String] = []
    for w in info {   // front to back
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        guard layer >= 0, layer < 1000 || !filters.isEmpty else { continue }
        if !filters.isEmpty, !filters.contains(where: { owner.lowercased().contains($0) }) { continue }
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        rows.append("\(owner)[\(w[kCGWindowOwnerPID as String] ?? 0)] \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) level=\(layer)")
    }
    let state = "front=\(front?.localizedName ?? "?")[\(front?.processIdentifier ?? 0)] | " + rows.joined(separator: " > ")
    if state != last {
        print("\(formatter.string(from: Date())) \(state)")
        last = state
    }
    Thread.sleep(forTimeInterval: 0.5)
}
