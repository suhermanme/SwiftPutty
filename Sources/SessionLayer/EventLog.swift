import Foundation

/// A session's Event Log as PuTTY's window keeps it (unix/dialog.c
/// `logevent_dlg`): the first ``initialLimit`` entries, then the most
/// recent ``recentLimit``. Once entries have been dropped from between
/// the two, the first recent one is the line `..`.
public struct EventLog: Sendable, Equatable, RandomAccessCollection {
    public static let initialLimit = 128
    public static let recentLimit = 128

    public struct Entry: Sendable, Equatable, Hashable {
        /// When PuTTY logged it; nil for the `..` marker.
        public var time: Date?
        public var text: String

        public init(time: Date?, text: String) {
            self.time = time
            self.text = text
        }

        /// As PuTTY shows and copies it: `2026-10-15 09:41:00<TAB>text`.
        public var line: String {
            guard let time else { return text }
            return EventLog.timestamp(time) + "\t" + text
        }

        /// The time as PuTTY writes it; empty for the `..` marker.
        public var timeText: String {
            time.map(EventLog.timestamp) ?? ""
        }

        public static let gap = Entry(time: nil, text: "..")
    }

    private var initial: [Entry] = []
    private var recent: [Entry] = []

    public init() {}

    public mutating func append(_ text: String, time: Date = Date()) {
        let entry = Entry(time: time, text: text)
        if initial.count < Self.initialLimit {
            initial.append(entry)
        } else if recent.count < Self.recentLimit {
            recent.append(entry)
        } else {
            // logevent_dlg: the oldest recent entry is overwritten, and
            // the next oldest becomes "..".
            recent.removeFirst()
            recent[0] = .gap
            recent.append(entry)
        }
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { initial.count + recent.count }

    public subscript(position: Int) -> Entry {
        position < initial.count ? initial[position] : recent[position - initial.count]
    }

    /// The text PuTTY puts on the clipboard for the given entries: each
    /// line followed by a newline.
    public static func clipboardText(for entries: some Sequence<Entry>) -> String {
        entries.map { $0.line + "\n" }.joined()
    }

    /// PuTTY's `%Y-%m-%d %H:%M:%S`, in local time.
    static func timestamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0,
                      c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
