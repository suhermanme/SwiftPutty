import Foundation
import Testing

extension KitTests {
/// docs/CONFIGURATION_PARITY.md stays exhaustive: every key of the
/// vendored PuTTY's Conf (conf.h's `CONF_OPTION` list, from which
/// `conf_key_info[]` is generated) is named in it. Run after every
/// upstream update, so a new key cannot go unnoticed.
@Suite("Configuration parity document")
struct ParityTests {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The Conf keys, as `CONF_name`.
    static func confKeys() throws -> [String] {
        let header = try String(contentsOf: root.appending(path: "Vendor/putty/conf.h"), encoding: .utf8)
        return header.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("CONF_OPTION(") else { return nil }
            let name = line.dropFirst("CONF_OPTION(".count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return "CONF_" + name
        }
    }

    /// The keys the document names. Besides `CONF_name`, it writes
    /// `CONF_name*` for a family of keys, and a following `_suffix` for
    /// the keys formed from each `CONF_name` on the same line
    /// ("`CONF_bellovl`, `_n`, `_t`").
    static func documentedKeys() throws -> (names: Set<String>, prefixes: [String]) {
        let doc = try String(contentsOf: root.appending(path: "docs/CONFIGURATION_PARITY.md"), encoding: .utf8)
        var names = Set<String>(), prefixes: [String] = []
        for line in doc.split(separator: "\n") {
            let codes = line.split(separator: "`", omittingEmptySubsequences: false)
                .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
            let bases = codes.filter { $0.hasPrefix("CONF_") && !$0.hasSuffix("*") }
            for code in codes {
                if code.hasPrefix("CONF_") {
                    if code.hasSuffix("*") { prefixes.append(String(code.dropLast())) } else { names.insert(code) }
                } else if code.hasPrefix("_") {
                    for base in bases { names.insert(base + code) }
                }
            }
        }
        return (names, prefixes)
    }

    @Test func everyConfKeyIsDocumented() throws {
        let keys = try Self.confKeys()
        #expect(keys.count > 200)          // the parse found conf.h's list
        let (names, prefixes) = try Self.documentedKeys()
        let missing = keys.filter { key in
            !names.contains(key) && !prefixes.contains { key.hasPrefix($0) }
        }
        #expect(missing.isEmpty, "not in docs/CONFIGURATION_PARITY.md: \(missing)")
    }
}
}
