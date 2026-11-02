import XCTest

/// A UNIX socket path fits COMPLETELY in `sockaddr_un.sun_path` or is refused
/// (Shared/ComputerUseSocketPath.swift). The helper used to truncate it to 103
/// bytes: a 127-byte harness path under iCloud Drive was bound somewhere other
/// than where `unlink`, the probe and the client looked.
final class SocketPathTests: XCTestCase {

    /// A path of exactly `bytes` UTF-8 bytes, all ASCII, starting with `/tmp/`.
    private func asciiPath(bytes: Int) -> String {
        let prefix = "/tmp/"
        return prefix + String(repeating: "a", count: bytes - prefix.utf8.count)
    }

    func testCapacityIsTheRealSunPathSize() {
        XCTAssertEqual(bridgeUnixSocketPathCapacity, MemoryLayout.size(ofValue: sockaddr_un().sun_path))
        XCTAssertEqual(bridgeUnixSocketPathMaxBytes, bridgeUnixSocketPathCapacity - 1, "one byte for the NUL")
        #if os(macOS)
        XCTAssertEqual(bridgeUnixSocketPathCapacity, 104, "Darwin sun_path")
        #endif
    }

    // 1. Short ASCII path.
    func testShortAsciiPathIsValid() {
        let path = "/tmp/cmm-cu/bridge.sock"
        XCTAssertEqual(bridgeUnixSocketPathBytes(path), Array(path.utf8) + [0])
    }

    // 2. Exactly the usable maximum.
    func testPathAtTheUsableMaximumIsValid() {
        let path = asciiPath(bytes: bridgeUnixSocketPathMaxBytes)
        XCTAssertEqual(path.utf8.count, bridgeUnixSocketPathMaxBytes)
        let bytes = bridgeUnixSocketPathBytes(path)
        XCTAssertEqual(bytes?.count, bridgeUnixSocketPathCapacity, "path + NUL fill sun_path exactly")
        XCTAssertEqual(bytes, Array(path.utf8) + [0])
    }

    // 3. Maximum + 1 byte.
    func testOneByteOverTheMaximumIsRefused() {
        XCTAssertNil(bridgeUnixSocketPathBytes(asciiPath(bytes: bridgeUnixSocketPathMaxBytes + 1)))
        XCTAssertNil(bridgeUnixSocketPathBytes(asciiPath(bytes: bridgeUnixSocketPathCapacity)))
    }

    // 4. Measured in UTF-8 bytes, not characters.
    func testMultibytePathIsMeasuredInBytes() {
        // 60 characters, 5 + 2*55 = 115 bytes ("é" is 2 bytes).
        let path = "/tmp/" + String(repeating: "é", count: 55)
        XCTAssertLessThan(path.count, bridgeUnixSocketPathMaxBytes, "short in characters…")
        XCTAssertGreaterThan(path.utf8.count, bridgeUnixSocketPathMaxBytes, "…too long in bytes")
        XCTAssertNil(bridgeUnixSocketPathBytes(path))
        // A multibyte character must not be split at the boundary either.
        let edge = asciiPath(bytes: bridgeUnixSocketPathMaxBytes - 1) + "é"
        XCTAssertEqual(edge.utf8.count, bridgeUnixSocketPathMaxBytes + 1)
        XCTAssertNil(bridgeUnixSocketPathBytes(edge))
    }

    // 5. Never a truncated version: either the exact bytes or nothing.
    func testNeverReturnsATruncatedPath() {
        let real = "/Users/chris/Library/Mobile Documents/com~apple~CloudDocs/Downloads/Temporales/"
            + "CMM-CU-0.3.2-resume.GaiUln/live-lane/bridge.sock"
        XCTAssertEqual(real.utf8.count, 127, "the path from the Mac gate run")
        XCTAssertNil(bridgeUnixSocketPathBytes(real))
        for length in [1, 20, 64, 102, 103, 104, 105, 127, 200, 1_000] {
            let path = String(repeating: "x", count: length)
            if let bytes = bridgeUnixSocketPathBytes(path) {
                XCTAssertEqual(bytes, Array(path.utf8) + [0], "length \(length)")
                XCTAssertLessThanOrEqual(bytes.count, bridgeUnixSocketPathCapacity)
            } else {
                XCTAssertGreaterThan(length, bridgeUnixSocketPathMaxBytes, "length \(length)")
            }
        }
        XCTAssertNil(bridgeUnixSocketPathBytes(""))
        XCTAssertNil(bridgeUnixSocketPathBytes("/tmp/a\u{0}b"), "an embedded NUL would end the path early")
        XCTAssertNil(bridgeUnixSocketPathBytes("/tmp/ok.sock", capacity: 5), "the capacity is honoured")
    }

    // 6. The canonical production path fits with room to spare.
    func testCanonicalProductionPathFits() {
        let suffix = "/.cmm/computer-bridge/bridge.sock"
        // Explicit homes, not NSHomeDirectory(): a sandboxed test host would
        // report its container, which is not where the helper serves.
        for home in ["/Users/chris", "/Users/" + String(repeating: "u", count: 32)] {
            let path = home + suffix
            XCTAssertNotNil(bridgeUnixSocketPathBytes(path), path)
            XCTAssertLessThanOrEqual(path.utf8.count + 20, bridgeUnixSocketPathMaxBytes, "room to spare: \(path)")
        }
    }
}
