import AppKit
import SwiftUI

@main
struct LaunchBackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible scene of our own — everything is driven by AppDelegate
        // through LaunchpadOverlayWindow. Settings{} keeps SwiftUI's App
        // lifecycle happy without creating a stray window.
        Settings { EmptyView() }
    }
}

/// Ties together app discovery, the overlay window(s), and the global
/// hotkey, and makes a second launch of the bundle act as a toggle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayWindow: LaunchpadOverlayWindow?
    private var hotkeyManager: HotkeyManager?
    private var isVisible = false
    private let appStore = AppStore()

    // Apple's own (now-vestigial) Launchpad.app shim toggles by posting this
    // exact distributed notification — observed via `strings` on
    // /System/Applications/Launchpad.app/Contents/MacOS/Launchpad. Listening
    // for it too means any leftover system trigger for "toggle Launchpad"
    // (an F4 remap, `tell application "Launchpad" to activate`, etc.) also
    // opens LaunchBack, at no cost if nothing ever posts it.
    private static let legacyLaunchpadToggleName = Notification.Name("com.apple.launchpad.toggle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar-less background utility

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributedToggle),
            name: Self.legacyLaunchpadToggleName,
            object: nil
        )

        hotkeyManager = HotkeyManager { [weak self] in self?.toggle() }

        // Show first, before anything that doesn't actually gate the first
        // frame — profiling a cold launch (via temporary instrumentation)
        // showed `AppQueryEngine.shared.startMonitoring` alone added ~17ms
        // ahead of the window even appearing, for work whose result isn't
        // needed until *after* the grid is already on screen (it renders
        // empty and fills in live regardless of when monitoring starts).
        // Every millisecond ahead of `show()` here is pure, avoidable delay
        // on the one moment users are actually staring at a blank screen.
        show()

        // Starts a persistent Spotlight monitor once; from here on
        // `appStore.apps` stays in sync with installs/removals on its own.
        AppQueryEngine.shared.startMonitoring(store: appStore)

        // Only matters for procedural/animated wallpapers with no backing
        // image file (see `LaunchpadOverlayWindow.liveDesktopSnapshot`).
        // `CGRequestScreenCaptureAccess()` blocks on its system prompt, so
        // it's deferred until just after the very first `show()` instead of
        // sitting ahead of it — the first appearance always uses whatever's
        // already available (falling back to a live blur if needed), and if
        // the user grants access, later toggles pick up the accurate
        // snapshot automatically.
        DispatchQueue.main.async {
            CGRequestScreenCaptureAccess()
        }
    }

    // `LSMultipleInstancesProhibited` in Info.plist is what makes this fire:
    // it tells Launch Services never to spawn a second process for this
    // bundle ID, and instead call this on the already-running instance
    // whenever the user tries to open the app again (double-click, Dock
    // click, `open` from Terminal). Without that key, this delegate method
    // is simply never invoked — which is exactly why re-opening used to do
    // nothing until the app was quit first.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle()
        return true
    }

    @objc private func handleDistributedToggle() {
        toggle()
    }

    private func toggle() {
        isVisible ? hide() : show()
    }

    private func show() {
        guard !isVisible, let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        // The exact same closure goes to both the SwiftUI content (tap to
        // dismiss, onExitCommand) and the window itself (its own Escape-key
        // monitor) — one authoritative dismissal path no matter which of
        // them triggers it, so `isVisible`/`overlayWindow` never drift out
        // of sync with what's actually on screen.
        let dismissAction: () -> Void = { [weak self] in self?.hide() }
        let window = LaunchpadOverlayWindow(screen: screen)
        window.show(with: GridView(store: appStore, onDismiss: dismissAction), onDismiss: dismissAction)
        overlayWindow = window
        isVisible = true
    }

    private func hide() {
        overlayWindow?.dismiss()
        overlayWindow = nil
        isVisible = false
    }
}
