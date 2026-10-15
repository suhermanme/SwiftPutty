import SessionLayer
import SwiftUI

/// SwiftUI host for a ``TerminalView``.
public struct TerminalSessionView: NSViewRepresentable {
    public let controller: SessionController
    /// The window's menu for a right-click that asks for it.
    public var contextMenu: (() -> NSMenu?)?

    public init(controller: SessionController, contextMenu: (() -> NSMenu?)? = nil) {
        self.controller = controller
        self.contextMenu = contextMenu
    }

    public func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(controller: controller)
        view.contextMenu = contextMenu
        return view
    }

    public func updateNSView(_ view: TerminalView, context: Context) {
        view.contextMenu = contextMenu
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TerminalView,
                             context: Context) -> CGSize? {
        // Default to the configured terminal size (TermWidth x TermHeight).
        guard proposal.width == nil || proposal.height == nil else { return nil }
        return TerminalView.defaultSize(for: controller.settings)
    }
}
