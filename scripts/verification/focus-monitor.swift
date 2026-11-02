// focus-monitor.swift — INDEPENDENT witness for the live background check.
//
// Operator tooling only, run by scripts/verification/live-background-e2e.sh.
// It is NOT a runtime route and the agent must never run it (the DSH guard
// refuses it: it names CGEvent). It is strictly read-only: it posts no event,
// activates nothing, reads no window title or pixel, and needs no TCC grant.
//
// It runs in its OWN process with its OWN AppKit run loop, so its NSWorkspace
// view refreshes independently of the helper's — the point of a second
// channel. Every 10 ms it writes one JSON line:
//   {"t":<uptime>,"front":"<bundle>","top":"<bundle of front-most layer-0 window>","x":..,"y":..}
//
//   focus-monitor <output.jsonl> <seconds>

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, let seconds = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: focus-monitor <output.jsonl> <seconds>\n".utf8))
    exit(2)
}
FileManager.default.createFile(atPath: arguments[1], contents: nil)
guard let out = FileHandle(forWritingAtPath: arguments[1]) else { exit(2) }

func topWindowBundle() -> String {
    guard let infos = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return "" }
    for info in infos {
        guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
        if let bounds = info[kCGWindowBounds as String] as? [String: Any],
           let w = bounds["Width"] as? CGFloat, let h = bounds["Height"] as? CGFloat,
           w < 40 || h < 40 { continue }
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    }
    return ""
}

let start = ProcessInfo.processInfo.systemUptime
let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
    let now = ProcessInfo.processInfo.systemUptime
    if now - start > seconds { exit(0) }
    let location = CGEvent(source: nil)?.location ?? .zero
    let row: [String: Any] = [
        "t": now,
        "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
        "top": topWindowBundle(),
        "x": Double(location.x),
        "y": Double(location.y),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: row) {
        out.write(data)
        out.write(Data("\n".utf8))
    }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
