import ConfigurationUI
import Persistence
import PuTTYBridge
import SessionLayer
import SwiftUI
import TerminalUI

/// What a session window connects to: the settings from the
/// configuration dialog, as PuTTY will use them (`prepare_session`).
struct SessionRequest: Codable, Hashable {
    var id = UUID()
    /// The launch that opened this window. SwiftUI restores windows with
    /// their values at the next launch; PuTTY never reconnects by itself,
    /// so windows from an earlier launch close instead of connecting.
    var launch = SessionRequest.currentLaunch
    var settings: PuTTYSettings

    init(settings: PuTTYSettings) {
        self.settings = settings.preparedForSession()
    }

    static let currentLaunch = UUID()

    var isFromThisLaunch: Bool { launch == Self.currentLaunch }

    /// PuTTY's `conf_dest`: the host, or the serial line.
    var destination: String {
        settings["Protocol"] == "serial" ? settings["SerialLine"] ?? "" : settings["HostName"] ?? ""
    }
}

/// One terminal window, as each PuTTY session has its own window.
struct SessionWindow: View {
    let request: SessionRequest
    let appModel: AppModel
    private var store: SavedSessionStore { appModel.sessionStore }
    @State private var controller: SessionController
    @State private var showingError = false
    /// The open Change Settings dialog (GTK PuTTY's "Reconfiguration").
    @State private var reconfiguration: ConfigurationModel?
    @State private var reconfigurationError: String?
    /// The open "Exit Confirmation" (GTK PuTTY's warn-on-close box), and
    /// the window it would close.
    @State private var closeConfirmation: SessionController.CloseWarning?
    @State private var closingWindow = WeakWindow()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init(request: SessionRequest, appModel: AppModel) {
        self.request = request
        self.appModel = appModel
        _controller = State(initialValue: SessionController(settings: request.settings))
    }

    var body: some View {
        if request.isFromThisLaunch {
            session
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private var session: some View {
        TerminalSessionView(controller: controller, contextMenu: SessionContextMenu.make)
            .frame(minWidth: 160, minHeight: 80)
            .navigationTitle(windowTitle)
            .task { connect() }
            .onAppear { appModel.register(controller, for: request.id) }
            .onDisappear {
                // As GTK PuTTY, the Event Log goes with its window.
                dismissWindow(id: WindowID.eventLog, value: request.id)
                appModel.unregister(window: request.id)
            }
            .background { WindowCloseGuard(shouldClose: shouldClose) }
            .onChange(of: controller.state) { _, state in stateChanged(state) }
            .sheet(item: Binding(get: { controller.pendingPrompt },
                                 set: { _ in })) { prompt in
                PuTTYPromptView(prompt: prompt) { answer in
                    controller.answer(prompt, with: answer)
                }
                .interactiveDismissDisabled()
            }
            .alert("SwiftPutty Fatal Error", isPresented: $showingError) {
                Button("OK") {}
            } message: {
                Text(controller.stateDetail ?? "The connection failed.")
            }
            .background {
                // A second sheet needs a view of its own.
                Color.clear
                    .sheet(item: $reconfiguration) { model in
                        ConfigurationView(model: model,
                                          onOpen: { settings in apply(settings) },
                                          onCancel: cancelChangeSettings,
                                          onAbout: {})
                            .interactiveDismissDisabled()
                    }
            }
            .alert("SwiftPutty Reconfiguration", isPresented: Binding(
                get: { reconfigurationError != nil }, set: { if !$0 { reconfigurationError = nil } })) {
                Button("OK") {}
            } message: {
                Text(reconfigurationError ?? "")
            }
            .background {
                // GTK PuTTY's nonfatal message box, one at a time.
                Color.clear
                    .alert("SwiftPutty Error", isPresented: Binding(
                        get: { !controller.errorMessages.isEmpty },
                        set: { if !$0 { controller.dismissErrorMessage() } })) {
                        Button("OK") {}
                    } message: {
                        Text(controller.errorMessages.first ?? "")
                    }
            }
            .background {
                Color.clear
                    .alert("SwiftPutty Exit Confirmation", isPresented: Binding(
                        get: { closeConfirmation != nil },
                        set: { if !$0 { closeConfirmation = nil } })) {
                        Button("Yes") { closingWindow.window?.close() }
                        Button("No", role: .cancel) {}
                    } message: {
                        Text(closeConfirmation?.message ?? "")
                    }
            }
            .focusedSceneValue(\.sessionActions, SessionActions(
                changeSettings: changeSettings,
                canChangeSettings: controller.session != nil && !controller.isChangingSettings,
                restart: { controller.restart() },
                canRestart: controller.canRestart,
                duplicate: duplicate,
                showEventLog: { openWindow(id: WindowID.eventLog, value: request.id) },
                specials: controller.specials,
                runSpecial: { controller.runSpecial($0) },
                clearScrollback: { controller.clearScrollback() },
                resetTerminal: { controller.resetTerminal() }))
    }

    // MARK: Session operations (M10)

    /// GTK PuTTY's delete_window: a connected session asks first, if
    /// "Warn before closing window" is on.
    private func shouldClose(_ window: NSWindow) -> Bool {
        guard controller.mayNeedCloseWarning else { return true }
        // Already asking: as GTK, just bring the question back.
        guard closeConfirmation == nil else { return false }
        Task {
            if let warning = await controller.closeWarning() {
                closingWindow.window = window
                closeConfirmation = warning
            } else {
                window.close()             // ended meanwhile
            }
        }
        return false
    }

    /// Duplicate Session: a new window with the running settings
    /// (launch_duplicate_session(inst->conf)).
    private func duplicate() {
        openWindow(id: WindowID.session, value: SessionRequest(settings: controller.settings))
    }

    // MARK: Change Settings (GTK PuTTY change_settings_menuitem)

    private func changeSettings() {
        Task {
            guard let running = await controller.beginChangeSettings() else {
                NSSound.beep()
                return
            }
            let model = ConfigurationModel(changing: running.settings,
                                           protocolInfo: running.protocolInfo,
                                           store: store, beep: { NSSound.beep() })
            model.liveStatus = { [controller] in controller.portForwardStatuses[$0] }
            reconfiguration = model
        }
    }

    private func apply(_ settings: PuTTYSettings) {
        let edits = reconfiguration?.tunnelEdits ?? []
        reconfiguration = nil
        Task {
            if let error = await controller.applyChangeSettings(settings, portForwardingEdits: edits) {
                reconfigurationError = error
            } else if !controller.lastPortForwardingReport.isEmpty {
                reconfigurationError = controller.lastPortForwardingReport.message
            }
        }
    }

    private func cancelChangeSettings() {
        reconfiguration = nil
        controller.cancelChangeSettings()
    }

    /// As GTK PuTTY: the title the terminal set, else the configured
    /// window title, else "host - SwiftPutty"; "(inactive)" once the
    /// session has ended.
    private var windowTitle: String {
        if controller.state.isFinal {
            return "SwiftPutty (inactive)"
        }
        if !controller.title.isEmpty {
            return controller.title
        }
        if let title = controller.settings["WinTitle"], !title.isEmpty {
            return title
        }
        return "\(request.destination) - SwiftPutty"
    }

    private func connect() {
        do {
            try controller.connect()
        } catch {
            showingError = true
        }
    }

    /// PuTTY's "Close window on exit" (CloseOnExit: 0 never, 1 only on
    /// clean exit, 2 always). Failures are reported, and the window kept,
    /// as PuTTY does.
    private func stateChanged(_ state: PuTTYSessionState) {
        switch state {
        case .closed:
            let closeOnExit = controller.settings["CloseOnExit"] ?? "1"
            if closeOnExit == "2" || (closeOnExit == "1" && controller.exitCode == 0) {
                dismiss()
            }
        case .failed:
            showingError = true
        default:
            break
        }
    }
}

/// A window reference that does not keep the window alive.
final class WeakWindow {
    weak var window: NSWindow?
}

/// GTK PuTTY's window menu, shown by a right-click that asks for it:
/// copies of the menu bar's own items (so they act on this window), in
/// GTK's order: New Session, the Session menu, Copy / Paste / Copy All,
/// About.
///
/// SwiftUI sets its menu items' enabled state only when their menu is
/// about to open, so each source menu is brought up to date first and
/// the copies keep the state they were copied with (validating them
/// again would ask a target that does not know this window's session).
enum SessionContextMenu {
    @MainActor
    static func make() -> NSMenu? {
        guard let main = NSApp.mainMenu else { return nil }
        let menu = NSMenu(title: "SwiftPutty")
        menu.autoenablesItems = false
        // No "AutoFill" or Services plug-ins: this is the window menu.
        menu.allowsContextMenuPlugIns = false
        for source in main.items.compactMap(\.submenu) {
            source.delegate?.menuNeedsUpdate?(source)
            source.update()
        }
        func add(_ item: NSMenuItem?) {
            if let copy = item?.copy() as? NSMenuItem { menu.addItem(copy) }
        }
        let file = main.items.first { $0.submenu?.item(withTitle: "New Session…") != nil }?.submenu
        add(file?.item(withTitle: "New Session…"))
        for item in main.item(withTitle: "Session")?.submenu?.items ?? [] {
            add(item)
        }
        menu.addItem(.separator())
        if let edit = main.item(withTitle: "Edit")?.submenu {
            for title in ["Copy", "Paste", "Copy All to Clipboard"] {
                add(edit.item(withTitle: title))
            }
        }
        menu.addItem(.separator())
        add(main.items.first?.submenu?.item(withTitle: "About SwiftPutty"))
        return menu
    }
}
