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

    private init() {
        // Posted by WallpaperAgent when the desktop picture changes, so a
        // long-running LaunchBack session doesn't keep showing a stale
        // background after the user picks a new wallpaper.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.desktopBackgroundChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cachedImage = nil
        }
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
