import Foundation
import PuTTYBridgeC

/// One entry of PuTTY's "Special Commands" menu, as the connection lists
/// it (upstream `backend_get_specials`): for SSH-2, Break and the
/// signals, "Repeat key exchange", "IGNORE message" and so on.
public enum SessionSpecial: Sendable, Hashable {
    /// A menu item: run it with ``PuTTYSession/special(_:)``. `code` and
    /// `argument` are PuTTY's own values, passed back unchanged.
    case command(SessionSpecialCommand)
    case separator
    /// A submenu (for example "More signals") and its entries.
    case submenu(String, [SessionSpecial])

    /// Builds the menu tree from the bridge's flat list (a submenu is
    /// its title, its entries, then an end marker).
    static func tree(from list: UnsafePointer<spb_special>?, count: Int) -> [SessionSpecial] {
        guard let list, count > 0 else { return [] }
        var stack: [(title: String, entries: [SessionSpecial])] = [("", [])]
        for index in 0..<count {
            let item = list[index]
            let name = item.name.map { String(cString: $0) } ?? ""
            switch item.kind {
            case SPB_SPECIAL_SEPARATOR:
                stack[stack.count - 1].entries.append(.separator)
            case SPB_SPECIAL_SUBMENU:
                stack.append((name, []))
            case SPB_SPECIAL_END_SUBMENU:
                guard stack.count > 1 else { continue }
                let done = stack.removeLast()
                stack[stack.count - 1].entries.append(.submenu(done.title, done.entries))
            default:
                stack[stack.count - 1].entries.append(
                    .command(SessionSpecialCommand(name: name, code: item.code, argument: item.arg)))
            }
        }
        // Close anything left open (the bridge never does that).
        while stack.count > 1 {
            let done = stack.removeLast()
            stack[stack.count - 1].entries.append(.submenu(done.title, done.entries))
        }
        return stack[0].entries
    }
}

/// A runnable Special Commands entry.
public struct SessionSpecialCommand: Sendable, Hashable {
    public var name: String
    public var code: Int32
    public var argument: Int32

    public init(name: String, code: Int32, argument: Int32) {
        self.name = name
        self.code = code
        self.argument = argument
    }
}

extension Array where Element == SessionSpecial {
    /// Every command, submenus included, in menu order.
    public var allCommands: [SessionSpecialCommand] {
        flatMap { special -> [SessionSpecialCommand] in
            switch special {
            case .command(let command): [command]
            case .separator: []
            case .submenu(_, let entries): entries.allCommands
            }
        }
    }
}
