import Foundation
import Observation
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

    func startCore() {
        guard coreState == .notStarted else { return }
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
