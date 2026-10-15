import AppKit
import SwiftUI

/// Lets a SwiftUI window refuse to close (the close button, ⌘W, Close
/// in the Window menu): PuTTY's "Warn before closing window". SwiftUI has
/// no such hook, so the window's delegate is wrapped by one that asks
/// `shouldClose` first and forwards everything else to SwiftUI's own.
/// `NSWindow.close()` does not ask, so closing after confirming uses it.
struct WindowCloseGuard: NSViewRepresentable {
    var shouldClose: @MainActor (NSWindow) -> Bool

    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.shouldClose = shouldClose
        view.install()
    }

    final class GuardView: NSView {
        var shouldClose: (@MainActor (NSWindow) -> Bool)?
        private var proxy: DelegateProxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        /// (Re)wraps the window's delegate, should SwiftUI have replaced it.
        func install() {
            guard let window, window.delegate !== proxy else { return }
            let proxy = DelegateProxy(original: window.delegate, owner: self)
            self.proxy = proxy
            window.delegate = proxy
        }
    }

    final class DelegateProxy: NSObject, NSWindowDelegate {
        // Strong: the window's delegate property is weak, and SwiftUI may
        // not otherwise keep its delegate.
        let original: NSWindowDelegate?
        weak var owner: GuardView?

        init(original: NSWindowDelegate?, owner: GuardView) {
            self.original = original
            self.owner = owner
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if let shouldClose = owner?.shouldClose, !shouldClose(sender) {
                return false
            }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
