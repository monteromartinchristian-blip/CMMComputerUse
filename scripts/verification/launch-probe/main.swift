// LaunchAgent isolation probe.
//
// A deliberately tiny stand-in for the helper's lifecycle: it binds one Unix
// socket, refuses to start when something already answers there (the helper's
// own single-instance rule), and records what it did. Nothing else — no TCC, no
// AX, no capture, no policy.
//
// `scripts/verify-launchagent-isolation.sh` builds it into a throwaway .app and
// points a throwaway LaunchAgent at the real supervisor script, so the restart
// semantics can be exercised without touching the installed helper, its job,
// its socket or its TCC grants.

import Foundation

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// The product supervisor passes the helper's own flag (`--serve-socket`); the
// short form exists so the probe can also be started by hand.
let socketPath = argument("--serve-socket") ?? argument("--socket") ?? ""
let logPath = argument("--log-file") ?? ""
guard !socketPath.isEmpty, !logPath.isEmpty else {
    FileHandle.standardError.write(Data("probe: --socket and --log-file are required\n".utf8))
    exit(2)
}

let stamp = ISO8601DateFormatter().string(from: Date())
let pid = ProcessInfo.processInfo.processIdentifier

func record(_ message: String) {
    let line = "[\(stamp)] pid=\(pid) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: logPath))
    }
}

func unixAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    memset(&address, 0, MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(103)) + [0]
    let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
    bytes.withUnsafeBytes { source in
        withUnsafeMutableBytes(of: &address) { destination in
            destination.baseAddress!.advanced(by: offset)
                .copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    return address
}

func isServing(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = unixAddress(path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return result == 0
}

if isServing(socketPath) {
    record("already_serving \(socketPath)")
    exit(0)
}

unlink(socketPath)
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    record("socket_failed")
    exit(2)
}
var address = unixAddress(socketPath)
let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bound == 0, listen(fd, 5) == 0 else {
    record("bind_failed \(String(cString: strerror(errno)))")
    exit(2)
}
record("serving \(socketPath)")

while true {
    let client = accept(fd, nil, nil)
    if client >= 0 { close(client) }
}
