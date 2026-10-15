import Foundation
import PuTTYBridge

/// Why the saved-session store could not be read or written.
public enum SavedSessionStoreError: Error, Equatable, LocalizedError {
    /// The file could not be read or written (the system's message).
    case io(path: String, message: String)
    /// The file is not a saved-session store this version understands.
    case unreadable(path: String, message: String)
    /// Written by a newer SwiftPutty; it is never overwritten.
    case newerFormat(path: String, version: Int)
    /// A secret could not be saved in, or removed from, the keychain.
    case secret(message: String)

    public var errorDescription: String? {
        switch self {
        case .io(let path, let message):
            "Unable to access the saved sessions in \"\(path)\": \(message)"
        case .unreadable(let path, let message):
            "The saved sessions in \"\(path)\" cannot be read: \(message). "
                + "SwiftPutty will not change the file; move it away to start afresh."
        case .newerFormat(let path, let version):
            "The saved sessions in \"\(path)\" were written by a newer version "
                + "of SwiftPutty (format \(version)). SwiftPutty will not change the file."
        case .secret(let message):
            "Unable to save the proxy password in the keychain: \(message)"
        }
    }
}

/// PuTTY's saved sessions, kept by SwiftPutty instead of the PuTTY core
/// (docs/DECISIONS.md D-004, D-027).
///
/// The rules are PuTTY's (`settings.c`, `config.c`): "Default Settings"
/// is a session like any other, but always listed first, even when
/// nothing is saved under it; an empty name means "Default Settings";
/// other names sort byte-wise; a session that does not exist loads as
/// PuTTY's built-in defaults; loaded settings have every missing keyword
/// filled with PuTTY's built-in default (not with "Default Settings").
///
/// Everything is in one JSON file, read afresh by every call (as PuTTY
/// reads its storage), replaced atomically on every change, and readable
/// by the user only. A file this version cannot read is reported and never
/// overwritten.
///
/// Unlike PuTTY, the proxy password is never written to the file (D-040):
/// it is kept in `secrets` (the keychain, in the app) under the session's
/// name, and filled in again on load. A password found in the file, from
/// before, is moved to `secrets` when its session is loaded.
public struct SavedSessionStore: Sendable {
    public static let defaultSettingsName = "Default Settings"

    /// The newest file format this version reads and the one it writes.
    public static let currentVersion = 1
    static let formatIdentifier = "org.swiftputty.saved-sessions"

    public let fileURL: URL
    public let secrets: any SecretStore

    /// The keywords kept in `secrets` instead of the file.
    static let secretKeyword = "ProxyPassword"

    /// Posted after this process saves or deletes a session (object: the
    /// store's file URL), so that menus listing the sessions can update.
    public static let didChangeNotification = Notification.Name("SavedSessionStoreDidChange")

    public init(fileURL: URL, secrets: any SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

    /// `~/Library/Application Support/SwiftPutty/Saved Sessions.json`.
    public static func defaultFileURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appending(path: "SwiftPutty", directoryHint: .isDirectory)
            .appending(path: "Saved Sessions.json", directoryHint: .notDirectory)
    }

    /// PuTTY's session list (`get_sesslist`): "Default Settings" first,
    /// then every other saved name in byte-wise order.
    public func sessionNames() throws -> [String] {
        let names = try readDocument().sessions.keys
            .filter { $0 != Self.defaultSettingsName }
        return [Self.defaultSettingsName] + names.sorted(by: Self.precedes)
    }

    /// PuTTY's `load_settings`: the session's settings, normalised;
    /// PuTTY's built-in defaults if there is no such session.
    public func load(_ name: String) throws -> (settings: PuTTYSettings, exists: Bool) {
        let name = Self.storedName(name)
        var document = try readDocument()
        guard var stored = document.sessions[name] else {
            return (PuTTYSettings().normalised(), false)
        }
        if let password = stored[Self.secretKeyword], !password.isEmpty {
            // Saved in the file before D-040: move it to the keychain. If
            // either step fails, the session still loads, and the move is
            // tried again next time.
            if (try? secrets.setSecret(password, for: name)) != nil {
                document.sessions[name]?[Self.secretKeyword] = ""
                try? writeDocument(document)
            }
            stored[Self.secretKeyword] = password
        } else {
            stored[Self.secretKeyword] = secrets.secret(for: name) ?? ""
        }
        return (stored.normalised(), true)
    }

    /// PuTTY's `do_defaults`: what a new configuration starts from.
    public func loadDefaults() throws -> PuTTYSettings {
        try load(Self.defaultSettingsName).settings
    }

    /// PuTTY's `save_settings`: stores the settings as PuTTY saves them
    /// (normalised: every keyword present). An empty name saves
    /// "Default Settings".
    public func save(_ settings: PuTTYSettings, as name: String) throws {
        let name = Self.storedName(name)
        var document = try readDocument()
        var stored = settings.normalised()
        // The keychain first: if it fails, the file still has the old
        // session rather than one that lost its password.
        let password = stored[Self.secretKeyword] ?? ""
        do {
            if password.isEmpty {
                try secrets.removeSecret(for: name)
            } else {
                try secrets.setSecret(password, for: name)
            }
        } catch {
            throw SavedSessionStoreError.secret(message: (error as? SecretStoreError)?.message
                                                ?? error.localizedDescription)
        }
        stored[Self.secretKeyword] = ""
        document.sessions[name] = stored
        try writeDocument(document)
        postChange()
    }

    /// PuTTY's `del_settings`. Deleting a session that does not exist
    /// does nothing.
    public func delete(_ name: String) throws {
        let name = Self.storedName(name)
        var document = try readDocument()
        guard document.sessions.removeValue(forKey: name) != nil else { return }
        try writeDocument(document)
        // After the file: a password left behind is harmless (a session
        // saved later under the name replaces it), a lost session is not.
        try? secrets.removeSecret(for: name)
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: fileURL)
    }

    /// `strcmp` order, as PuTTY's `sessioncmp` after "Default Settings".
    public static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// As upstream storage: no name means "Default Settings".
    static func storedName(_ name: String) -> String {
        name.isEmpty ? defaultSettingsName : name
    }

    // MARK: - File format

    /// Version 1:
    ///
    ///     { "format": "org.swiftputty.saved-sessions", "version": 1,
    ///       "sessions": { "<name>": { "<PuTTY keyword>": "<value>", ... } } }
    ///
    /// Values are encoded as PuTTY's Unix session files encode them.
    struct Document: Codable {
        var format = SavedSessionStore.formatIdentifier
        var version = SavedSessionStore.currentVersion
        var sessions: [String: PuTTYSettings] = [:]
    }

    /// Read first, so that a newer file is recognised before anything
    /// else in it is interpreted.
    private struct Header: Decodable {
        var format: String
        var version: Int
    }

    private func readDocument() throws -> Document {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return Document()
        } catch {
            throw SavedSessionStoreError.io(path: fileURL.path, message: Self.message(error))
        }

        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw SavedSessionStoreError.unreadable(path: fileURL.path,
                                                    message: "not a SwiftPutty saved-sessions file")
        }
        guard header.format == Self.formatIdentifier, header.version >= 1 else {
            throw SavedSessionStoreError.unreadable(path: fileURL.path,
                                                    message: "not a SwiftPutty saved-sessions file")
        }
        guard header.version <= Self.currentVersion else {
            throw SavedSessionStoreError.newerFormat(path: fileURL.path, version: header.version)
        }
        // Older formats are migrated here, version by version, when there
        // are any. Version 1 is the first.
        do {
            return try decoder.decode(Document.self, from: data)
        } catch {
            throw SavedSessionStoreError.unreadable(path: fileURL.path, message: "the file is damaged")
        }
    }

    private func writeDocument(_ document: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw SavedSessionStoreError.io(path: fileURL.path, message: Self.message(error))
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Self.replaceAtomically(fileURL, with: data)
        } catch {
            throw SavedSessionStoreError.io(path: fileURL.path, message: Self.message(error))
        }
    }

    /// Writes a new file, readable by the user only from the moment it
    /// exists, then renames it over the old one: a crash leaves either
    /// the old file or the new one.
    private static func replaceAtomically(_ url: URL, with data: Data) throws {
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    private static func message(_ error: any Error) -> String {
        (error as NSError).localizedFailureReason ?? error.localizedDescription
    }
}
