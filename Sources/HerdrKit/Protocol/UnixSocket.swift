import Darwin
import Foundation

/// Blocking Unix domain socket.
///
/// Reads happen on a background thread while writes come from the UI thread.
/// That is safe at the kernel level for a stream socket, so this type is
/// `@unchecked Sendable`; only the close flag needs a lock.
public final class UnixSocket: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case pathTooLong(Int)
        case socketCreationFailed(errno: Int32)
        case connectFailed(errno: Int32)
        case readFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case closed
    }

    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    /// Takes ownership of an existing descriptor (used by tests).
    public init(adopting descriptor: Int32) {
        self.descriptor = descriptor
    }

    public init(connectingTo path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw Failure.pathTooLong(pathBytes.count)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Failure.socketCreationFailed(errno: errno)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let outcome = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, size)
            }
        }
        guard outcome == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Failure.connectFailed(errno: code)
        }

        self.descriptor = fd
    }

    deinit {
        close()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }

    public func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            throw written == 0 ? Failure.closed : Failure.writeFailed(errno: errno)
        }
    }

    /// Reads exactly `count` bytes, reassembling partial reads.
    /// Throws `.closed` on EOF before the count is met.
    public func readExactly(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: offset), count - offset)
            }
            if received > 0 {
                offset += received
                continue
            }
            if received == 0 { throw Failure.closed }
            if errno == EINTR { continue }
            throw Failure.readFailed(errno: errno)
        }
        return buffer
    }
}
