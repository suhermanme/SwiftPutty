import Foundation
import Observation
import Persistence
import PuTTYBridge

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
