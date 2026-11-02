// rearm-probe — test-only administrative client for the ISOLATED live lane.
//
// Stand-in for CMM Console's rearm, until Console implements it, and ONLY
// inside scripts/verification/isolated-live.py. It is signed with its own
// identifier, com.cmm.computer-use.test-rearm, and the isolated policy grants
// it exactly `admin: ["breach.rearm"]` with no apps and no scopes.
//
// What it can do (closed list, checked here before any socket is opened):
//   status                                  -> breach.status
//   rearm --breach-id <id> --reason <text>  -> breach.rearm {breach_id, reason}
//   reset-invalid --reason <text>           -> breach.rearm {reset_invalid_state, reason}
//
// What it refuses, by construction:
//   - any other operation (no observe, no control, no policy, no apps);
//   - an empty reason;
//   - a socket that is not inside a directory carrying the isolated-lane
//     marker file `.cmm-isolated-live`, and the production socket path in any
//     case. It is not a tool for the production helper.
//
//   rearm-probe --socket <path> <status|rearm|reset-invalid> [options]
//
// Exit: 0 helper answered ok:true, 1 helper refused (ok:false), 2 usage or
// transport. The helper's frame is printed verbatim on stdout.

import Foundation

let markerName = ".cmm-isolated-live"
let maxReason = 500

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("rearm-probe: " + message + "\n").utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var socketPath = ""
var command = ""
var breachID = ""
var reason: String?
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--socket":
        guard !arguments.isEmpty else { fail("--socket needs a path") }
        socketPath = arguments.removeFirst()
    case "--breach-id":
        guard !arguments.isEmpty else { fail("--breach-id needs a value") }
        breachID = arguments.removeFirst()
    case "--reason":
        guard !arguments.isEmpty else { fail("--reason needs a value") }
        reason = arguments.removeFirst()
    case "status", "rearm", "reset-invalid":
        guard command.isEmpty else { fail("one command only") }
        command = argument
    default:
        // Anything else — including other bridge operations — is refused here,
        // so this binary can never be used to observe or control anything.
        fail("unsupported argument or operation: \(argument)")
    }
}
guard !command.isEmpty else { fail("usage: --socket <path> <status|rearm|reset-invalid>") }
guard !socketPath.isEmpty else { fail("--socket is required") }

// Isolated lane only.
let socketURL = URL(fileURLWithPath: socketPath).standardizedFileURL
let production = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cmm/computer-bridge/bridge.sock").standardizedFileURL
guard socketURL.path != production.path else { fail("refusing the production socket") }
let marker = socketURL.deletingLastPathComponent().appendingPathComponent(markerName)
guard FileManager.default.fileExists(atPath: marker.path) else {
    fail("refusing: \(socketURL.deletingLastPathComponent().path) is not an isolated lane (no \(markerName))")
}

var operation = "breach.status"
var payload: [String: Any] = [:]
switch command {
case "status":
    guard breachID.isEmpty, reason == nil else { fail("status takes no --breach-id/--reason") }
case "rearm", "reset-invalid":
    let text = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { fail("a reason is required") }
    guard text.count <= maxReason else { fail("reason longer than \(maxReason) characters") }
    operation = "breach.rearm"
    payload["reason"] = text
    if command == "rearm" {
        guard !breachID.isEmpty else { fail("rearm needs --breach-id") }
        payload["breach_id"] = breachID
    } else {
        guard breachID.isEmpty else { fail("reset-invalid takes no --breach-id") }
        payload["reset_invalid_state"] = true
    }
default:
    fail("unreachable")
}

// One request, one frame — same transport as bridge-probe.swift.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("socket() failed") }
defer { close(fd) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketURL.path.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("socket path too long") }
withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: pathBytes) }
let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { fail("no bridge is serving \(socketURL.path)") }

let request: [String: Any] = [
    "version": 1, "id": UUID().uuidString, "operation": operation, "arguments": payload,
]
guard var line = try? JSONSerialization.data(withJSONObject: request) else { fail("encode") }
line.append(0x0A)
let sent = line.withUnsafeBytes { raw in send(fd, raw.baseAddress!, raw.count, 0) }
guard sent == line.count else { fail("short write") }

var buffer = [UInt8]()
var byte: UInt8 = 0
while recv(fd, &byte, 1, 0) == 1 {
    if byte == 0x0A { break }
    buffer.append(byte)
}
guard !buffer.isEmpty, let text = String(bytes: buffer, encoding: .utf8) else { fail("empty reply") }
print(text)
guard let data = text.data(using: .utf8),
      let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
else { exit(2) }
exit(frame["ok"] as? Bool == true ? 0 : 1)
