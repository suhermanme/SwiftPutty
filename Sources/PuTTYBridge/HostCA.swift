import Foundation
import PuTTYBridgeC

/// A trusted host certification authority record (PuTTY's `host_ca`).
public struct HostCA: Sendable, Equatable {
    /// Shown in log messages; the record's key in the store.
    public var name: String
    /// A base64 key blob, or a public key file's text (it is stored as a
    /// blob).
    public var publicKey: String
    /// The "valid hosts this key is trusted to certify" expression.
    public var validity: String
    /// Signature types accepted from an RSA CA key.
    public var permitRSASHA1: Bool
    public var permitRSASHA256: Bool
    public var permitRSASHA512: Bool

    init(_ ca: UnsafeMutablePointer<spb_host_ca>) {
        let c = ca.pointee
        name = String(cString: c.name)
        publicKey = String(cString: c.public_key)
        validity = String(cString: c.validity)
        permitRSASHA1 = c.permit_rsa_sha1
        permitRSASHA256 = c.permit_rsa_sha256
        permitRSASHA512 = c.permit_rsa_sha512
    }

    /// A new record with PuTTY's defaults (RSA: SHA-256 and SHA-512).
    public static func newDefault() -> HostCA {
        let ca = spb_host_ca_new_default()!
        defer { spb_host_ca_free(ca) }
        return HostCA(ca)
    }
}

/// An error saving a host CA record: the message and, for an error in
/// the validity expression, where it is (UTF-8 byte offsets).
public struct HostCASaveError: Error, Sendable, Equatable {
    public var message: String
    public var expressionRange: Range<Int>?
}

/// PuTTY's store of trusted host CAs (in the core's state directory),
/// with the rules of upstream's "Configure host CAs" dialog. Each call
/// waits for the core thread; the core must be running.
public enum HostCAStore {
    /// The saved records' names, sorted as PuTTY lists them.
    public static func names() -> [String] {
        var count = 0
        guard let names = spb_host_ca_names(&count) else { return [] }
        defer { spb_strings_free(names, count) }
        return (0..<count).map { String(cString: names[$0]!) }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    public static func load(_ name: String) -> HostCA? {
        guard let ca = spb_host_ca_load(name) else { return nil }
        defer { spb_host_ca_free(ca) }
        return HostCA(ca)
    }

    /// What `text` is as a CA public key: its fingerprint (and the key
    /// as a base64 blob), or why it is not usable ("" for empty text).
    public static func keyInfo(_ text: String) -> (description: String, blob: String?) {
        var blob: UnsafeMutablePointer<CChar>?
        let info = spb_host_ca_key_info(text, &blob)
        defer {
            spb_string_free(info)
            spb_string_free(blob)
        }
        return (info.map { String(cString: $0) } ?? "", blob.map { String(cString: $0) })
    }

    /// Saves (replacing a record of the same name).
    public static func save(_ ca: HostCA) throws(HostCASaveError) {
        var offset = 0, length = 0
        let error: UnsafeMutablePointer<CChar>? = ca.name.withCString { name in
            ca.publicKey.withCString { key in
                ca.validity.withCString { validity in
                    var c = spb_host_ca(name: UnsafeMutablePointer(mutating: name),
                                        public_key: UnsafeMutablePointer(mutating: key),
                                        validity: UnsafeMutablePointer(mutating: validity),
                                        permit_rsa_sha1: ca.permitRSASHA1,
                                        permit_rsa_sha256: ca.permitRSASHA256,
                                        permit_rsa_sha512: ca.permitRSASHA512)
                    return spb_host_ca_save(&c, &offset, &length)
                }
            }
        }
        guard let error else { return }
        defer { spb_string_free(error) }
        throw HostCASaveError(message: String(cString: error),
                              expressionRange: offset == Int.max || UInt(bitPattern: offset) == UInt.max
                                  ? nil : offset..<(offset + length))
    }

    /// Deletes a record; returns the error, if any.
    public static func delete(_ name: String) -> String? {
        guard let error = spb_host_ca_delete(name) else { return nil }
        defer { spb_string_free(error) }
        return String(cString: error)
    }
}
