import AppKit
import PuTTYBridge

/// What a key press means for the terminal.
public enum TerminalKeyAction: Equatable, Sendable {
    /// A key PuTTY translates (arrows, function keys, keypad, ...).
    case key(TerminalKey, TerminalModifiers)
    /// Text to type as-is (control characters, Meta combinations).
    case text(String, TerminalModifiers)
    /// Ordinary text: let the input method interpret the event.
    case interpret
    /// Not for the terminal (a Command shortcut for the menus).
    case ignore
}

/// Maps macOS key events to terminal input. Keys are recognised by key
/// code, which does not depend on the keyboard layout; text comes from
/// the layout.
public enum TerminalKeyMapper {
    /// Key codes of the keys PuTTY translates (Carbon `kVK_*` values).
    static let keys: [UInt16: TerminalKey] = [
        126: .up, 125: .down, 124: .right, 123: .left,
        115: .home, 119: .end, 114: .insert, 117: .delete,
        116: .pageUp, 121: .pageDown,
        36: .returnKey, 51: .backspace, 48: .tab, 53: .escape,
        122: .function(1), 120: .function(2), 99: .function(3), 118: .function(4),
        96: .function(5), 97: .function(6), 98: .function(7), 100: .function(8),
        101: .function(9), 109: .function(10), 103: .function(11), 111: .function(12),
        105: .function(13), 107: .function(14), 113: .function(15), 106: .function(16),
        64: .function(17), 79: .function(18), 80: .function(19), 90: .function(20),
        82: .keypadDigit(0), 83: .keypadDigit(1), 84: .keypadDigit(2), 85: .keypadDigit(3),
        86: .keypadDigit(4), 87: .keypadDigit(5), 88: .keypadDigit(6), 89: .keypadDigit(7),
        91: .keypadDigit(8), 92: .keypadDigit(9),
        65: .keypadDecimal, 76: .keypadEnter, 69: .keypadPlus, 78: .keypadMinus,
        67: .keypadMultiply, 75: .keypadDivide, 71: .keypadNumLock,
    ]

    /// - Parameters:
    ///   - characters: the event's characters (all modifiers applied).
    ///   - charactersIgnoringModifiers: the characters with no modifiers
    ///     (used for Control combinations).
    ///   - charactersWithoutOption: the characters with every modifier
    ///     except Option (used when Option is Meta).
    public static func action(keyCode: UInt16, characters: String?,
                              charactersIgnoringModifiers: String?,
                              charactersWithoutOption: String?,
                              modifierFlags flags: NSEvent.ModifierFlags,
                              optionIsMeta: Bool, commandIsMeta: Bool) -> TerminalKeyAction {
        let command = flags.contains(.command)
        if command && !commandIsMeta {
            return .ignore
        }
        var modifiers: TerminalModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let optionMeta = flags.contains(.option) && optionIsMeta
        if optionMeta || (command && commandIsMeta) { modifiers.insert(.meta) }

        if let key = keys[keyCode] {
            return .key(key, modifiers)
        }
        // Ctrl+Shift+C/V: PuTTY decides between the clipboard and Ctrl-C/V.
        if flags.contains(.control), flags.contains(.shift),
           let base = (charactersIgnoringModifiers ?? characters)?.lowercased(),
           base == "c" || base == "v" {
            return .key(base == "c" ? .letterC : .letterV, modifiers)
        }
        if flags.contains(.control),
           let base = charactersIgnoringModifiers ?? characters,
           let code = controlCode(for: base) {
            return .text(String(UnicodeScalar(code)), modifiers.subtracting([.shift, .control]))
        }
        if modifiers.contains(.meta) {
            let text = optionMeta ? (charactersWithoutOption ?? characters) : characters
            guard let text, !text.isEmpty else { return .ignore }
            return .text(text, modifiers.subtracting([.shift, .control]))
        }
        return .interpret
    }

    /// The control character for Control + `base`, as on a PC keyboard
    /// (Ctrl-A = 0x01, Ctrl-Space and Ctrl-2 = NUL, Ctrl-[ = ESC, ...).
    static func controlCode(for base: String) -> UInt8? {
        guard base.unicodeScalars.count == 1,
              let scalar = base.unicodeScalars.first, scalar.isASCII else { return nil }
        let c = UInt8(scalar.value)
        switch c {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return c - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return c - UInt8(ascii: "A") + 1
        case UInt8(ascii: " "), UInt8(ascii: "@"), UInt8(ascii: "2"): return 0
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1B
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1C
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1D
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "7"): return 0x1F
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7F
        default: return c < 0x20 ? c : nil
        }
    }

    /// Convenience for a real event.
    public static func action(for event: NSEvent, optionIsMeta: Bool,
                              commandIsMeta: Bool) -> TerminalKeyAction {
        let withoutOption = event.characters(
            byApplyingModifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.option, .control, .command]))
        return action(keyCode: event.keyCode, characters: event.characters,
                      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                      charactersWithoutOption: withoutOption,
                      modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                      optionIsMeta: optionIsMeta, commandIsMeta: commandIsMeta)
    }
}
