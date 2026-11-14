import AppKit
import SwiftUI

/// Reports how much of the window's top edge is covered by the title bar + unified toolbar.
///
/// `NavigationSplitView` sidebars extend under the toolbar but only receive the title-bar height as
/// their top safe area, so fixed sidebar content ends up hidden behind the toolbar. Measuring the
/// window's `contentLayoutRect` gives the exact obscured height on every macOS version and in full screen.
private struct TopChromeReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.onChange = { value in
            if abs(value - inset) > 0.5 { inset = value }
        }
        return view
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.onChange = { value in
            if abs(value - inset) > 0.5 { inset = value }
        }
        nsView.measure()
    }

    final class ChromeView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observers: [any NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measure() }
                }
            }
            measure()
        }

        func measure() {
            guard let window, let content = window.contentView else { return }
            let covered = max(0, content.bounds.height - window.contentLayoutRect.maxY)
            DispatchQueue.main.async { [onChange] in onChange?(covered) }
        }
        // Observers are removed in viewDidMoveToWindow when the view leaves its window.
    }
}

extension View {
    /// Lays the view out starting exactly below the window's title bar and toolbar.
    func placedBelowWindowToolbar() -> some View {
        modifier(BelowToolbarModifier())
    }
}

private struct BelowToolbarModifier: ViewModifier {
    @State private var inset: CGFloat = 52

    func body(content: Content) -> some View {
        content
            .padding(.top, inset)
            .ignoresSafeArea(.container, edges: .top)
            .background(TopChromeReader(inset: $inset).frame(width: 0, height: 0))
    }
}
