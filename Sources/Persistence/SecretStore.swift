import Foundation
import Security

/// Where the saved-session store keeps secrets that must not be written to
/// the sessions file (D-040): one secret per saved session name.
public protocol SecretStore: Sendable {
    /// The secret saved for the session, or nil if there is none or it
    /// cannot be read.
    func secret(for session: String) -> String?
    /// Saves the secret, replacing any earlier one.
    func setSecret(_ secret: String, for session: String) throws
    /// Removes the secret; removing one that does not exist does nothing.
    func removeSecret(for session: String) throws
}

/// Why a secret could not be saved or removed.
public struct SecretStoreError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        "Unable to save the proxy password in the keychain: \(message)"
    }
}

/// Secrets as generic passwords in the user's keychain: service
/// `service`, account the session name.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    /// The proxy passwords of SwiftPutty's saved sessions.
    public static let proxyPasswords = KeychainSecretStore(service: "org.swiftputty.proxy-password")

    public init(service: String) {
        self.service = service
    }

    private func query(_ session: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: session]
    }

    public func secret(for session: String) -> String? {
        var query = query(session)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ secret: String, for session: String) throws {
        let data = Data(secret.utf8)
        var status = SecItemUpdate(query(session) as CFDictionary,
                                   [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(session)
            item[kSecValueData] = data
            item[kSecAttrLabel] = "SwiftPutty proxy password (\(session))"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    public func removeSecret(for session: String) throws {
        let status = SecItemDelete(query(session) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    private static func error(_ status: OSStatus) -> SecretStoreError {
        SecretStoreError(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
    }
}

/// Secrets kept in memory only, for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    public init() {}

    public var all: [String: String] {
        lock.withLock { secrets }
    }

    public func secret(for session: String) -> String? {
        lock.withLock { secrets[session] }
    }

    public func setSecret(_ secret: String, for session: String) throws {
        lock.withLock { secrets[session] = secret }
    }

    public func removeSecret(for session: String) throws {
        lock.withLock { _ = secrets.removeValue(forKey: session) }
    }
}
