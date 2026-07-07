import AppKit
import SwiftUI

/// A borderless, fully transparent window that sits above the Dock and menu
/// bar, hosting the SwiftUI grid on top of an `NSVisualEffectView` blur.
@MainActor
final class LaunchpadOverlayWindow: NSWindow {
    private var escMonitor: Any?
    private let blurView = NSVisualEffectView()
    private let targetFrame: NSRect

    /// A slightly inset, centered version of `targetFrame` — the animation
    /// starts (on show) or ends (on dismiss) here, so the whole overlay
    /// gently grows into place / shrinks away instead of just cross-fading,
    /// the same "zoom" feel classic Launchpad opens with.
    private var zoomedOutFrame: NSRect {
        let scale: CGFloat = 0.97
        let dx = targetFrame.width * (1 - scale) / 2
        let dy = targetFrame.height * (1 - scale) / 2
        return targetFrame.insetBy(dx: dx, dy: dy)
    }

    init(screen: NSScreen) {
        targetFrame = screen.frame
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // One level above the menu bar so the overlay covers the Dock too.
        level = .mainMenu + 1
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        animationBehavior = .none

        // `.fullScreenUI` is the "correct" material on paper, but at this
        // window's very high level (`.mainMenu + 1`) it can composite as a
        // flatter, more opaque fill instead of a real see-through blur.
        // `.hudWindow` stays reliably translucent regardless of window
        // level, which is what gives the classic frosted-glass Launchpad
        // look instead of a solid dark rectangle.
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.frame = screen.frame
        blurView.autoresizingMask = [.width, .height]

        contentView = blurView
    }

    /// Mounts `rootView` into the window and brings it on screen.
    func show(with rootView: some View) {
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = blurView.bounds
        hosting.autoresizingMask = [.width, .height]
        blurView.addSubview(hosting)

        alphaValue = 0
        setFrame(zoomedOutFrame, display: false)
        // `activate(ignoringOtherApps:)` is asynchronous, so even calling
        // it before ordering the window doesn't reliably win the race:
        // `makeKeyAndOrderFront` can still run before LaunchBack is
        // actually marked active, and AppKit then places the window
        // *beneath* whichever app is still active (confirmed via
        // `log show`: "ordered front from a non-active application and
        // may order beneath the active application's windows" — the
        // overlay silently existed off-screen from the user's POV).
        // `orderFrontRegardless()` is the documented way to force a
        // window to the front of its level regardless of app activation
        // state, so use that instead of `makeKeyAndOrderFront`.
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        makeKey()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(targetFrame, display: true)
        }

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                self.dismiss()
                return nil
            }
            return event
        }
    }

    /// Fades out, tears down the hosted content, and orders the window out.
    func dismiss() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }

        NSAnimationContext.runAnimationGroup({ [zoomedOutFrame] context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(zoomedOutFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.blurView.subviews.forEach { $0.removeFromSuperview() }
        })
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
