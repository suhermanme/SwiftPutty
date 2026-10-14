import Foundation

/// A minimal TCP server on 127.0.0.1 for tests, using blocking POSIX
/// sockets on its own threads so that it is independent of the PuTTY
/// core thread under test.
public final class LoopbackServer: @unchecked Sendable {
    public enum Behaviour: Sendable {
        /// Echo everything back until the client closes.
        case echo
        /// Send `greeting`, then close the connection.
        case greetAndClose(String)
    }

    public let port: UInt16
    private let listenFD: Int32
    private let behaviour: Behaviour
    private let acceptThread: Thread
    private let done = DispatchSemaphore(value: 0)

    public init(_ behaviour: Behaviour) throws {
        self.behaviour = behaviour
        (listenFD, port) = try Self.listen()
        let fd = listenFD
        let done = done
        acceptThread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                Self.serve(client, behaviour)
            }
            done.signal()
        }
        acceptThread.start()
    }

    /// Stops accepting; connections already open run to completion.
    public func stop() {
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        done.wait()
    }

    /// A loopback port with nothing listening on it.
    public static func unusedPort() throws -> UInt16 {
        let (fd, port) = try listen()
        close(fd)
        return port
    }

    private static func listen() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && Darwin.listen(fd, 256) == 0
                    && getsockname(fd, $0, &length) == 0
            }
        }
        guard ok else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    private static func serve(_ client: Int32, _ behaviour: Behaviour) {
        switch behaviour {
        case .greetAndClose(let greeting):
            _ = Array(greeting.utf8).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            close(client)
        case .echo:
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 65536)
                loop: while true {
                    let count = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
                    if count <= 0 { break }
                    var offset = 0
                    while offset < count {
                        let written = buffer.withUnsafeBytes {
                            write(client, $0.baseAddress! + offset, count - offset)
                        }
                        if written <= 0 { break loop }
                        offset += written
                    }
                }
                close(client)
            }
        }
    }
}
