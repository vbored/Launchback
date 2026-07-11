import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation

/// Caches the blurred wallpaper background across every toggle-open of the
/// overlay, computed off the main thread.
///
/// Without this, the overlay recomputed its background from scratch on
/// every single open, and — worse — `NSCIImageRep` only actually *runs* the
/// Gaussian blur pipeline the first time the image is drawn, which happens
/// exactly when the overlay's `NSImageView` appears on screen. That meant
/// every toggle synchronously froze the open/close zoom animation on the
/// main thread for over a full second (measured ~1.0s for a 4K wallpaper).
/// Rendering explicitly into a concrete `CGImage` via a `CIContext`, once,
/// on a background queue, and reusing the cached result removes that cost
/// from the interactive path entirely — only the very first open (before
/// the cache has ever been populated) falls back to an instant system blur
/// while the real background renders in the background.
@MainActor
final class WallpaperBackgroundCache {
    static let shared = WallpaperBackgroundCache()

    private var cachedImage: NSImage?
    private var isComputing = false
    private let ciContext = CIContext(options: nil)
    private var lastPrewarmedScreen: NSScreen?
    private var wallpaperChangeSource: DispatchSourceFileSystemObject?

    private static let wallpaperStorePath = NSString(
        string: "~/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
    ).expandingTildeInPath

    private init() {
        // A long-running LaunchBack session should notice when the wallpaper
        // changes instead of keeping a stale cached background until the
        // app is quit and relaunched. There's no *documented* public
        // notification for this — an earlier version of this code guessed
        // at a plausible-sounding distributed notification name
        // ("com.apple.desktopBackgroundChanged"), but that string doesn't
        // actually exist anywhere in the system frameworks (confirmed via
        // `strings` on WallpaperAgent/Dock/CoreServices), so it silently
        // never fired — the cache was never actually invalidating. Watching
        // WallpaperAgent's own on-disk state file instead is verifiable:
        // its `LastSet`/`LastUse` timestamps are confirmed (by direct
        // inspection) to update the moment the wallpaper changes, static or
        // procedural alike, so a filesystem watcher on it is reliable
        // regardless of what notification (if any) WallpaperAgent posts.
        watchWallpaperStore()
    }

    private func watchWallpaperStore() {
        let fd = open(Self.wallpaperStorePath, O_EVTONLY)
        guard fd >= 0 else { return }

        // Plists are typically written via write-to-temp-then-atomic-rename,
        // which orphans whatever file descriptor was watching the original
        // path — `.rename`/`.delete` catch that so watching can be
        // re-established against the new inode, not just `.write` for
        // in-place modifications.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.cachedImage = nil
            self.wallpaperChangeSource?.cancel()
            self.watchWallpaperStore()
            if let screen = self.lastPrewarmedScreen {
                self.prewarm(for: screen)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        wallpaperChangeSource = source
    }

    /// Returns the cached, already-rendered background if one is ready.
    /// `nil` on the very first call (or right after a wallpaper change) —
    /// callers should show an instant fallback in that case while
    /// `prewarm` finishes in the background.
    func cachedBackground() -> NSImage? {
        cachedImage
    }

    /// Kicks off background rendering if nothing is cached yet and no
    /// computation is already in flight. `completion` (if given) fires on
    /// the main actor once a fresh image is ready.
    func prewarm(for screen: NSScreen, completion: (@MainActor (NSImage) -> Void)? = nil) {
        lastPrewarmedScreen = screen
        guard cachedImage == nil, !isComputing else { return }
        isComputing = true

        // Resolve everything that touches AppKit objects here, on the main
        // thread, before hopping off — only the actual Core Image/Core
        // Graphics number-crunching below needs to happen in the background.
        let screenFrame = screen.frame
        let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen)
        let context = ciContext

        Task.detached(priority: .userInitiated) {
            let image = Self.renderBackground(wallpaperURL: wallpaperURL, screenFrame: screenFrame, context: context)
            await MainActor.run {
                self.isComputing = false
                guard let image else { return }
                self.cachedImage = image
                completion?(image)
            }
        }
    }

    // MARK: - Rendering (runs off the main thread)

    private nonisolated static func renderBackground(wallpaperURL: URL?, screenFrame: NSRect, context: CIContext) -> NSImage? {
        if let ciImage = staticWallpaperImage(from: wallpaperURL) {
            return blurredAndTinted(ciImage, context: context)
        }
        if let ciImage = liveDesktopSnapshotImage(screenFrame: screenFrame) {
            return blurredAndTinted(ciImage, context: context)
        }
        return nil
    }

    /// Most desktop pictures are a plain image file, which `NSWorkspace`
    /// hands back directly — reading and blurring that ourselves gives an
    /// exact color match with zero risk of any other real window bleeding
    /// through, since nothing is being live-composited. macOS's newer
    /// procedural wallpapers (e.g. the animated "Sequoia" gradient style,
    /// confirmed via ~/Library/Application Support/com.apple.wallpaper/
    /// Store/Index.plist using a `com.apple.wallpaper.choice.*` provider
    /// instead of a file) have no such backing image — `desktopImageURL`
    /// just returns a generic system fallback file in that case, which
    /// would render the wrong picture entirely, so that's treated the same
    /// as "no file available."
    private nonisolated static func staticWallpaperImage(from url: URL?) -> CIImage? {
        guard let url, url.lastPathComponent != "DefaultDesktop.heic" else { return nil }

        // Video-based dynamic wallpapers (macOS's "Aerial"-style landscapes,
        // e.g. the bundled "Tahoe Day.mov") report a plain file URL too, but
        // it's a movie, not an image — `CIImage(contentsOf:)` can't read it
        // directly. Grabbing a single frame via `AVAssetImageGenerator` is
        // still pure file I/O, so it needs no extra permission either.
        if url.pathExtension.lowercased() == "mov" {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            return CIImage(cgImage: cgImage)
        }

        return CIImage(contentsOf: url)
    }

    /// Grabs a real screenshot of just the desktop-picture layer — the
    /// backmost window on screen, owned by the Dock process, sitting below
    /// every real app window — so procedural/animated wallpapers (which
    /// have no file to read) show their actual live colors instead of a
    /// generic stand-in image, without capturing any other app's window
    /// (nothing else is *below* the desktop picture to accidentally
    /// include). Requires Screen Recording permission; returns `nil`
    /// without one (silently — never prompts here) so the caller can fall
    /// back further.
    private nonisolated static func liveDesktopSnapshotImage(screenFrame: NSRect) -> CIImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }

        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let desktopWindow = windowList.first { info in
            guard info[kCGWindowOwnerName as String] as? String == "Dock",
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer < 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"]
            else { return false }
            return width >= screenFrame.width && height >= screenFrame.height
        }

        guard let windowID = desktopWindow?[kCGWindowNumber as String] as? CGWindowID,
              let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, .bestResolution)
        else { return nil }

        return CIImage(cgImage: cgImage)
    }

    private nonisolated static func blurredAndTinted(_ ciImage: CIImage, context: CIContext) -> NSImage? {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = ciImage.clampedToExtent()
        blur.radius = 90
        guard let blurred = blur.outputImage?.cropped(to: ciImage.extent) else { return nil }

        let tint = CIFilter.colorControls()
        tint.inputImage = blurred
        tint.brightness = -0.06
        tint.saturation = 1.05
        guard let finalImage = tint.outputImage else { return nil }

        // Rendering explicitly into a concrete `CGImage` here — rather than
        // wrapping the still-lazy `finalImage` in an `NSCIImageRep` — is
        // what actually does the expensive work now, off the main thread,
        // instead of leaving it to fire the first time an `NSImageView`
        // draws it later on the main thread.
        guard let cgImage = context.createCGImage(finalImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
