// UNIX socket rendezvous path: fits COMPLETELY in `sockaddr_un.sun_path`, or is
// refused. Never truncated.
//
// Bug (2026-11-02, Mac gate run): the helper built its address with
// `path.utf8.prefix(103)`, so a 127-byte harness path under iCloud Drive was
// silently truncated for `bind()` while `unlink()`, the single-instance probe
// and the client used the full path: the helper stayed alive, serving an
// unexpected location, and the client waited on another one. The canonical
// production path (`~/.cmm/computer-bridge/bridge.sock`) is short and was never
// affected.

import Foundation

/// Size of `sockaddr_un.sun_path` on this platform, in bytes, INCLUDING the
/// terminating NUL (Darwin: 104). Derived from the real struct, not hard-coded.
public let bridgeUnixSocketPathCapacity: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

/// Longest usable path, in UTF-8 bytes (capacity minus the NUL; Darwin: 103).
public var bridgeUnixSocketPathMaxBytes: Int { bridgeUnixSocketPathCapacity - 1 }

/// The NUL-terminated `sun_path` bytes for `path`, or nil when the path cannot
/// be represented EXACTLY: empty, containing a NUL (which would end it early),
/// or longer than `capacity - 1` UTF-8 bytes. Measured in bytes, never in
/// characters. When non-nil the result is exactly `Array(path.utf8) + [0]`.
public func bridgeUnixSocketPathBytes(
    _ path: String, capacity: Int = bridgeUnixSocketPathCapacity
) -> [UInt8]? {
    let bytes = Array(path.utf8)
    guard !bytes.isEmpty, !bytes.contains(0), bytes.count + 1 <= capacity else { return nil }
    return bytes + [0]
}
