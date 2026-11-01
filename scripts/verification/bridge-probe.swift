// bridge-probe.swift — the smallest possible computer-bridge client.
//
// Used only by scripts/verify-client-identity.sh. It exists so that a client's
// identity can be a REAL code signature: the same source is compiled twice and
// signed with two different identifiers, which is what the helper's per-client
// designated requirements are evaluated against.
//
//   bridge-probe <socket> <operation> [json-arguments] [command-line override]
//
// The last optional argument exists to prove that a request carrying a
// self-declared "client_id" changes nothing: the identity comes from the kernel
// and the code signature, never from the request body.

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fail("usage: bridge-probe <socket> <operation> [json-arguments]")
}
let socketPath = arguments[1]
let operation = arguments[2]
var payload: [String: Any] = [:]
if arguments.count >= 4, !arguments[3].isEmpty,
   let data = arguments[3].data(using: .utf8),
   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    payload = parsed
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("socket() failed") }
defer { close(fd) }

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    fail("socket path too long")
}
withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: pathBytes) }

let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { fail("no bridge is serving \(socketPath)") }

let request: [String: Any] = [
    "version": 1,
    "id": UUID().uuidString,
    "operation": operation,
    "arguments": payload,
]
guard let body = try? JSONSerialization.data(withJSONObject: request) else { fail("encode") }
var line = body
line.append(0x0A)
_ = line.withUnsafeBytes { raw in
    send(fd, raw.baseAddress!.advanced(by: 0), raw.count, 0)
}

// Read exactly one frame.
var buffer = [UInt8]()
var one: UInt8 = 0
while true {
    let n = recv(fd, &one, 1, 0)
    if n <= 0 { break }
    if one == 0x0A { break }
    buffer.append(one)
}
guard !buffer.isEmpty, let text = String(bytes: buffer, encoding: .utf8) else {
    fail("empty reply")
}
print(text)
