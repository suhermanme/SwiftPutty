import Foundation

/// The server end of one TCP connection, driven by the test: it writes
/// what the "remote host" sends and reads what the client sends.
public final class ScriptedPeer: @unchecked Sendable {
    public let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var connectionFD: Int32 = -1
    private let connected = DispatchSemaphore(value: 0)

    public init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard ok else {
            close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        listenFD = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            let client = accept(fd, nil, nil)
            lock.withLock { connectionFD = client }
            connected.signal()
        }
    }

    deinit {
        close(listenFD)
        if connectionFD >= 0 { close(connectionFD) }
    }

    /// Waits for the client to connect.
    public func waitForConnection(timeout: TimeInterval = 10) -> Bool {
        connected.wait(timeout: .now() + timeout) == .success
    }

    public func send(_ text: String) {
        let bytes = Array(text.utf8)
        let fd = lock.withLock { connectionFD }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            offset += n
        }
    }

    /// Reads until `count` bytes arrived or `timeout` passed.
    public func receive(count: Int, timeout: TimeInterval = 5) -> Data {
        let fd = lock.withLock { connectionFD }
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < count {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, Int32(left * 1000) + 1) <= 0 { break }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, min($0.count, count - data.count)) }
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    /// Closes the connection (the "remote host" goes away).
    public func disconnect() {
        lock.withLock {
            if connectionFD >= 0 { close(connectionFD) }
            connectionFD = -1
        }
    }
}
