// Lists on-screen windows as "id owner pid WxH name" (name is often empty: macOS hides other apps' titles
// unless Screen Recording is granted). Usage: swift windows.swift [owner-substring]
import CoreGraphics
import Foundation
let filter = CommandLine.arguments.dropFirst().first?.lowercased()
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in info {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    if let filter, !owner.lowercased().contains(filter) { continue }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print("\(w[kCGWindowNumber as String] ?? 0) \(owner) \(w[kCGWindowOwnerPID as String] ?? 0) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) layer=\(w[kCGWindowLayer as String] ?? 0) \(w[kCGWindowName as String] as? String ?? "")")
}
