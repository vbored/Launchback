import AppKit
import SwiftUI

/// A borderless, fully transparent window that sits above the Dock and menu
/// bar, hosting the SwiftUI grid on top of a blurred backdrop matching the
/// desktop wallpaper.
@MainActor
final class LaunchpadOverlayWindow: NSWindow {
    private var escMonitor: Any?
    private let backgroundContainer = NSView()
    private var backgroundImageView: NSImageView?
    private var fallbackBlurView: NSVisualEffectView?
    private var hostingView: NSView?
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

        backgroundContainer.frame = screen.frame
        backgroundContainer.autoresizingMask = [.width, .height]

        // `WallpaperBackgroundCache` renders the blurred wallpaper off the
        // main thread and reuses the result across every toggle-open —
        // computing it fresh (and, worse, letting `NSCIImageRep` rasterize
        // it lazily on first draw) used to freeze the open/close animation
        // for up to a second on every single open. If nothing's cached yet
        // (the very first open of the session), fall back instantly to a
        // live behind-window blur — a plausibly-colored, slightly-wrong
        // backdrop beats blocking the animation — and swap in the accurate
        // image the moment the background render finishes.
        if let wallpaper = WallpaperBackgroundCache.shared.cachedBackground() {
            addBackgroundImage(wallpaper)
        } else {
            addFallbackBlur()
            WallpaperBackgroundCache.shared.prewarm(for: screen) { [weak self] wallpaper in
                self?.addBackgroundImage(wallpaper)
            }
        }

        contentView = backgroundContainer
    }

    private func addBackgroundImage(_ image: NSImage) {
        let imageView = NSImageView(frame: backgroundContainer.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = image
        // `.below` (not `.above`) — this can arrive *after* `show()` has
        // already mounted the SwiftUI grid content on top (the fallback
        // blur render is instant, but the real background can finish while
        // the window's already visible), so it must slot in behind
        // whatever's already there rather than covering it.
        backgroundContainer.addSubview(imageView, positioned: .below, relativeTo: nil)
        backgroundImageView?.removeFromSuperview()
        backgroundImageView = imageView
        fallbackBlurView?.removeFromSuperview()
        fallbackBlurView = nil
    }

    private func addFallbackBlur() {
        let blurView = NSVisualEffectView(frame: backgroundContainer.bounds)
        blurView.autoresizingMask = [.width, .height]
        blurView.material = .fullScreenUI
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        backgroundContainer.addSubview(blurView)
        fallbackBlurView = blurView
    }

    /// Mounts `rootView` into the window and brings it on screen.
    func show(with rootView: some View) {
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = backgroundContainer.bounds
        hosting.autoresizingMask = [.width, .height]
        backgroundContainer.addSubview(hosting)
        hostingView = hosting

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

        // Classic Launchpad hides the Dock outright while active instead of
        // leaving it on screen, so do the same.
        NSApp.presentationOptions.insert(.hideDock)

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

        NSApp.presentationOptions.remove(.hideDock)

        NSAnimationContext.runAnimationGroup({ [zoomedOutFrame] context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(zoomedOutFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.hostingView?.removeFromSuperview()
            self?.hostingView = nil
        })
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
