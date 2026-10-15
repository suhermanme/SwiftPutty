import Foundation
import PuTTYBridgeC
import os

/// An error reported by the PuTTY bridge.
public struct PuTTYBridgeError: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }

    /// Takes ownership of a bridge-allocated error string.
    static func consuming(_ cString: UnsafeMutablePointer<CChar>?,
                          fallback: String) -> PuTTYBridgeError {
        guard let cString else { return PuTTYBridgeError(fallback) }
        defer { spb_string_free(cString) }
        return PuTTYBridgeError(String(cString: cString))
    }
}

/// Process-wide information about, and lifecycle of, the PuTTY core.
public enum PuTTYCore {
    /// Version of the C bridge API this module was built against.
    public static let expectedBridgeAPIVersion = Int32(SPB_API_VERSION)

    /// Version of the C bridge API in the linked core library.
    public static var bridgeAPIVersion: Int32 { spb_api_version() }

    /// PuTTY release string, e.g. "Release 0.85".
    public static var version: String { String(cString: spb_putty_version()) }

    /// Suffix PuTTY uses in its SSH version banner, e.g. "-Release-0.85".
    public static var sshVersionSuffix: String {
        String(cString: spb_putty_ssh_version())
    }

    /// PuTTY's licence text, taken from upstream's LICENCE at build time.
    public static var licenceText: String {
        String(cString: spb_putty_licence_text())
    }

    /// PuTTY's short copyright line, e.g. "1997-2026 Simon Tatham".
    public static var copyright: String {
        String(cString: spb_putty_copyright())
    }

    public static var isInitialized: Bool { spb_core_is_initialised() }

    /// Whether the calling thread is the PuTTY core thread (true inside
    /// bridge callbacks only).
    public static var isCoreThread: Bool { spb_core_is_core_thread() }

    /// Initialises process-wide PuTTY state and starts the PuTTY core
    /// thread that runs every session.
    ///
    /// `stateDirectory` holds PuTTY's trusted host keys, host CA records
    /// and random seed; it is created with mode 0700 if missing. Calling
    /// again with the same directory is a no-op. The core cannot be
    /// re-initialised after `shutdown()`.
    public static func initialize(stateDirectory: URL) throws(PuTTYBridgeError) {
        guard stateDirectory.isFileURL else {
            throw PuTTYBridgeError("State directory must be a file URL")
        }
        var error: UnsafeMutablePointer<CChar>?
        let ok = stateDirectory.path.withCString { path in
            var options = spb_core_options(state_dir: path)
            return spb_core_init(&options, &error)
        }
        if !ok {
            throw .consuming(error, fallback: "PuTTY core initialisation failed")
        }
    }

    /// Stops the core thread and tears down process-wide state at
    /// application exit. Returns false (and does nothing) while any
    /// ``PuTTYSession`` is still alive. Teardown still queued for
    /// sessions that have been deinitialised runs first.
    @discardableResult
    public static func shutdown() -> Bool {
        spb_core_shutdown()
    }

    /// Lets PuTTY open saved sessions by name where it does so itself: an
    /// SSH proxy whose host name names a saved session, and "Default
    /// Settings", which such a proxy otherwise starts from. `lookup` runs
    /// on the core thread with the session name and returns the session's
    /// settings, or nil if there is none; it must return promptly. Pass
    /// nil to remove it (then no saved session exists for PuTTY).
    public static func setSavedSessionLookup(_ lookup: (@Sendable (String) -> PuTTYSettings?)?) {
        guard let lookup else {
            spb_core_set_saved_session_lookup(nil, nil)
            return
        }
        let box = SavedSessionLookup(lookup)
        // The core may still be in a replaced lookup, so none is ever
        // freed (they are set once per launch).
        SavedSessionLookup.all.withLock { $0.append(box) }
        spb_core_set_saved_session_lookup({ ctx, name in
            guard let ctx, let name else { return nil }
            let box = Unmanaged<SavedSessionLookup>.fromOpaque(ctx).takeUnretainedValue()
            return box.lookup(String(cString: name))?.makeBridgeHandle()
        }, Unmanaged.passUnretained(box).toOpaque())
    }

    /// A manually configured host key as PuTTY stores it: the SHA256 or
    /// MD5 fingerprint, or public key blob, found in `text` (for example
    /// a pasted known_hosts line), canonicalised; nil if there is none.
    public static func canonicalManualHostKey(_ text: String) -> String? {
        guard let key = spb_canonical_manual_host_key(text) else { return nil }
        defer { spb_string_free(key) }
        return String(cString: key)
    }

    /// The default location of PuTTY state for SwiftPutty:
    /// `~/Library/Application Support/SwiftPutty/PuTTY`.
    public static func defaultStateDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appending(path: "SwiftPutty", directoryHint: .isDirectory)
            .appending(path: "PuTTY", directoryHint: .isDirectory)
    }

    /// Blocks until every operation queued for the core thread before
    /// this call has run, including the teardown of deinitialised
    /// sessions. For tests and diagnostics; returns false if the core is
    /// not running.
    @discardableResult
    public static func waitForPendingWork() -> Bool {
        spb_core_barrier()
    }

    /// Diagnostics: sessions whose memory has not been freed yet (alive,
    /// or deinitialised with teardown still queued).
    public static var liveSessionCount: Int { Int(spb_debug_live_sessions()) }

    /// Diagnostics: sockets and listeners PuTTY is watching once all
    /// queued work has run (waits for the core thread).
    public static var watchedDescriptorCount: Int { Int(spb_debug_uxsel_fds()) }

    /// Diagnostics: completed core loop iterations.
    public static var coreLoopIterations: UInt64 { spb_debug_loop_iterations() }

    /// Diagnostics: bridge settings objects allocated and not yet freed.
    public static var liveSettingsObjectCount: Int {
        Int(spb_debug_live_settings())
    }
}

/// A frontend saved-session lookup handed to the core.
private final class SavedSessionLookup: Sendable {
    let lookup: @Sendable (String) -> PuTTYSettings?

    init(_ lookup: @escaping @Sendable (String) -> PuTTYSettings?) {
        self.lookup = lookup
    }

    /// Every lookup ever set, kept alive for the core.
    static let all = OSAllocatedUnfairLock<[SavedSessionLookup]>(initialState: [])
}
