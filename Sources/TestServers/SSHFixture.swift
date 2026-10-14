import Foundation

/// A local SSH server for tests: upstream PuTTY's `uppity`, run by
/// `spb_ssh_fixture` behind a loopback TCP port (Core/tests/spb_ssh_fixture.c).
/// Any user name; password "weasel"; keyboard-interactive "stoat" then
/// "weasel"; `/bin/sh` on a pty. Exit statuses can read 127 when
/// uppity's pty reaches EOF before it reaps the shell (a race in uppity).
///
/// The binaries come from `scripts/build-core.sh`
/// (`build/core-<arch>/`), the host keys from `Core/tests/fixtures/`.
public final class SSHFixture: @unchecked Sendable {
    public let port: UInt16
    private let process: Process
    private let stdin: Pipe
    private let workDirectory: URL

    public enum HostKey: String, Sendable {
        case a = "hostkey-a.ppk"
        case b = "hostkey-b.ppk"
    }

    /// The repository root, from this file's location.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var hostArchitecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public init(hostKey: HostKey = .a) throws {
        let build = Self.repositoryRoot.appending(path: "build/core-\(Self.hostArchitecture)")
        let fixture = build.appending(path: "spb_ssh_fixture")
        let uppity = build.appending(path: "uppity")
        let key = Self.repositoryRoot.appending(path: "Core/tests/fixtures/\(hostKey.rawValue)")
        guard FileManager.default.isExecutableFile(atPath: fixture.path),
              FileManager.default.isExecutableFile(atPath: uppity.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "Run scripts/build-core.sh first (\(fixture.path))"])
        }
        workDirectory = FileManager.default.temporaryDirectory
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

        // "PORT <n>\n"
        var line = Data()
        while !line.contains(0x0A) {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        guard let text = String(data: line, encoding: .utf8),
              let value = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines)
                                     .replacingOccurrences(of: "PORT ", with: "")) else {
            process.terminate()
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "SSH fixture did not start"])
        }
        port = value
    }

    /// uppity's log so far (for diagnosing failures).
    public var log: String {
        (try? String(contentsOf: workDirectory.appending(path: "uppity.log"), encoding: .utf8)) ?? ""
    }

    /// Stops the server (closing its stdin) and removes its files.
    public func stop() {
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: workDirectory)
    }

    deinit {
        if process.isRunning { stop() }
    }
}
