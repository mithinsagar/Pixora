// Captures the main window of a named app (even if it is in another Space): swift window_shot.swift <AppName> <out.png>
import AppKit
let name = CommandLine.arguments[1], out = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
let candidates = list.filter { ($0[kCGWindowOwnerName as String] as? String) == name && ($0[kCGWindowLayer as String] as? Int) == 0 }
func area(_ w: [String: Any]) -> CGFloat {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
guard let w = candidates.max(by: { area($0) < area($1) }), let id = w[kCGWindowNumber as String] as? Int else { print("window not found"); exit(1) }
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", "-o", "-l", "\(id)", out]
try! p.run(); p.waitUntilExit(); print("captured window \(id)")
