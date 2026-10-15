import Foundation
import Observation
import Persistence
import PuTTYBridge
import SessionLayer

/// Application-wide state owned by the app delegate.
@MainActor
@Observable
final class AppModel {
    enum CoreState: Equatable {
        case notStarted
        case running(stateDirectory: URL)
        case failed(message: String)
    }

    private(set) var coreState: CoreState = .notStarted

    /// The saved sessions (D-027).
    let sessionStore: SavedSessionStore = {
        let url = (try? SavedSessionStore.defaultFileURL())
            ?? URL.homeDirectory.appending(path: "Library/Application Support/SwiftPutty/Saved Sessions.json")
        return SavedSessionStore(fileURL: url)
    }()

    /// The saved session names for the Saved Sessions menu, without
    /// "Default Settings" (as GTK PuTTY's update_savedsess_menu).
    private(set) var savedSessionNames: [String] = []

    /// The open session windows' sessions, by window (SessionRequest.id):
    /// for their Event Log windows and the quit confirmation.
    private(set) var sessions: [UUID: SessionController] = [:]

    /// A saved session for the configuration dialog to load when it next
    /// shows (Saved Sessions menu, for a session with no destination).
    var configurationToLoad: String?

    @ObservationIgnored private var storeObserver: NSObjectProtocol?

    init() {
        refreshSavedSessions()
        storeObserver = NotificationCenter.default.addObserver(
            forName: SavedSessionStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSavedSessions() }
        }
    }

    func refreshSavedSessions() {
        let names = (try? sessionStore.sessionNames()) ?? []
        savedSessionNames = names.filter { $0 != SavedSessionStore.defaultSettingsName }
    }

    func register(_ controller: SessionController, for window: UUID) {
        sessions[window] = controller
    }

    func unregister(window: UUID) {
        sessions[window] = nil
    }

    /// Sessions that would ask before their window closes.
    var connectedSessionsWithCloseWarning: Int {
        sessions.values.filter(\.mayNeedCloseWarning).count
    }

    func startCore() {
        guard coreState == .notStarted else { return }
        // Apps start in "/"; PuTTY on Unix runs in the user's home
        // directory, which is where relative log file names (the default
        // is "putty.log") end up.
        FileManager.default.changeCurrentDirectoryPath(NSHomeDirectory())
        do {
            let directory = try PuTTYCore.defaultStateDirectory()
            try PuTTYCore.initialize(stateDirectory: directory)
            coreState = .running(stateDirectory: directory)
        } catch {
            coreState = .failed(message: error.localizedDescription)
        }
    }

    func stopCore() {
        PuTTYCore.shutdown()
    }
}
