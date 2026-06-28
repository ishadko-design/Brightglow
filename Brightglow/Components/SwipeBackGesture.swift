import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Swipe-back gesture
//
// SwiftUI disables the standard left-edge "swipe to go back" interactive pop
// gesture whenever a screen hides the navigation bar / back button (which our
// custom-header screens do). This re-enables it by re-installing a delegate on
// the enclosing UINavigationController's `interactivePopGestureRecognizer`.
//
// The installer's own view controller re-asserts the delegate in `viewWillAppear`
// — so it's re-applied every time the screen appears, including when it's the
// first pushed screen and when it reappears after a deeper screen is popped
// (a one-shot setter missed those cases). The delegate only lets the gesture
// begin when there's a screen to pop back to (`viewControllers.count > 1`).
//
// Usage: `.enableSwipeBack()` on a pushed screen's root view.
// ─────────────────────────────────────────────────────────────────────────────

extension View {
    /// For navigation-pushed screens that hide the nav bar. Re-enables the
    /// system left-edge interactive pop gesture.
    func enableSwipeBack() -> some View {
        background(SwipeBackInstaller().frame(width: 0, height: 0))
    }

    /// For screens that aren't navigation pushes (modals / full-screen covers /
    /// in-place steps) and dismiss via a closure rather than `dismiss()`. Adds a
    /// left-edge rightward swipe that runs `action`, mirroring the iOS back swipe.
    func edgeSwipeBack(perform action: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(action: action))
    }
}

private struct EdgeSwipeBack: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            // A narrow transparent strip down the left edge that captures a
            // rightward drag — the same gutter the system back-swipe uses.
            Color.clear
                .frame(width: 24)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { v in
                            // Mostly-horizontal rightward swipe → go back.
                            if v.translation.width > 60,
                               abs(v.translation.height) < abs(v.translation.width) {
                                action()
                            }
                        }
                )
                .ignoresSafeArea()
        }
    }
}

private struct SwipeBackInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SwipeBackController { SwipeBackController() }
    func updateUIViewController(_ uiViewController: SwipeBackController, context: Context) {}
}

final class SwipeBackController: UIViewController, UIGestureRecognizerDelegate {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The screen (and this child controller) is on screen now, so the nav
        // controller resolves. Take ownership of the edge-pop gesture.
        guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
        gesture.delegate = self
        gesture.isEnabled = true
    }

    // Allow the edge-pop to start only when there's a screen to return to.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
    }

    // Don't let the pop gesture get starved by other gestures on the screen
    // (e.g. the photo-paging swipe / sheet drag); the edge recognizer is
    // screen-edge-scoped, so this is safe.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
