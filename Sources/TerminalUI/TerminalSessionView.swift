import SessionLayer
import SwiftUI

/// SwiftUI host for a ``TerminalView``.
public struct TerminalSessionView: NSViewRepresentable {
    public let controller: SessionController

    public init(controller: SessionController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> TerminalView {
        TerminalView(controller: controller)
    }

    public func updateNSView(_ view: TerminalView, context: Context) {}

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TerminalView,
                             context: Context) -> CGSize? {
        // Default to the configured terminal size (TermWidth x TermHeight).
        guard proposal.width == nil || proposal.height == nil else { return nil }
        return TerminalView.defaultSize(for: controller.settings)
    }
}
