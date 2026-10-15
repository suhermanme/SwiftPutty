import Foundation

/// A local SSH server for tests: upstream PuTTY's `uppity`, run by
/// `spb_ssh_fixture` behind a loopback TCP port (Core/tests/spb_ssh_fixture.c).
/// Any user name; password "weasel"; keyboard-interactive "stoat" then
/// "weasel"; `/bin/sh` on a pty. Exit statuses can read 127 when
/// uppity's pty reaches EOF before it reaps the shell (a race in uppity).
///
/// The binaries come from `scripts/build-core.sh`
/// (`build/core-<arch>/`), the host keys from `Core/tests/fixtures/`.
/// Starting and stopping are bounded in time, so a misbehaving server
/// fails a test instead of blocking the main thread.
public final class SSHFixture: @unchecked Sendable {
    public let port: UInt16
    private let process: Process
    private let stdin: Pipe
    private let workDirectory: URL

    public enum HostKey: String, Sendable {
        case a = "hostkey-a.ppk"
        case b = "hostkey-b.ppk"
    }

    public struct StartError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The repository root, from this file's location.
    public static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var hostArchitecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public init(hostKey: HostKey = .a, startTimeout: TimeInterval = 20) throws {
        let build = Self.repositoryRoot.appending(path: "build/core-\(Self.hostArchitecture)")
        let fixture = build.appending(path: "spb_ssh_fixture")
        let uppity = build.appending(path: "uppity")
        let key = Self.repositoryRoot.appending(path: "Core/tests/fixtures/\(hostKey.rawValue)")
        guard FileManager.default.isExecutableFile(atPath: fixture.path),
              FileManager.default.isExecutableFile(atPath: uppity.path) else {
            throw StartError(description: "Run scripts/build-core.sh first (\(fixture.path))")
        }
        // Short: macOS limits Unix socket paths to 104 bytes.
        workDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "spb-ssh-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        process = Process()
        process.executableURL = fixture
        process.arguments = [uppity.path, key.path, workDirectory.path]
        stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()

        // "PORT <n>\n", read on another thread so that a fixture that
        // never answers costs `startTimeout`, not the whole test run.
        let reader = stdout.fileHandleForReading
        let received = LockedData()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var line = Data()
            while !line.contains(0x0A) {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                line.append(chunk)
            }
            received.set(line)
            done.signal()
        }
        let answered = done.wait(timeout: .now() + startTimeout) == .success
        let text = String(decoding: received.get(), as: UTF8.self)
        guard answered,
              let value = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines)
                                     .replacingOccurrences(of: "PORT ", with: "")) else {
            let log = (try? String(contentsOf: workDirectory.appending(path: "uppity.log"),
                                   encoding: .utf8)) ?? ""
            Self.terminate(process)
            try? FileManager.default.removeItem(at: workDirectory)
            throw StartError(description: "SSH fixture did not start (answered: \(answered), "
                + "output: \"\(text)\", uppity log: \"\(log)\")")
        }
        port = value
    }

    /// uppity's log so far (for diagnosing failures).
    public var log: String {
        (try? String(contentsOf: workDirectory.appending(path: "uppity.log"), encoding: .utf8)) ?? ""
    }

    /// Stops the server and removes its files. Closing stdin asks the
    /// fixture to stop; if it has not within a few seconds it is
    /// terminated (its handler also stops uppity), then killed.
    public func stop() {
        try? stdin.fileHandleForWriting.close()
        Self.terminate(process)
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private static func terminate(_ process: Process) {
        func exited(within seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while process.isRunning && Date() < deadline {
                usleep(10_000)
            }
            return !process.isRunning
        }
        if exited(within: 5) { return }
        process.terminate()                           // SIGTERM
        if exited(within: 5) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = exited(within: 5)
    }

    deinit {
        if process.isRunning { stop() }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}
