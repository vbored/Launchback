import AppKit
import Foundation

/// A single launchable application, ready for display in the grid.
struct AppInfo: Identifiable, Hashable, @unchecked Sendable {
    let id: String // bundle identifier, falls back to path for identifier-less bundles
    let name: String
    let bundleURL: URL
    let icon: NSImage

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Holds the current app list so the grid can be shown immediately and
/// updates live as `AppQueryEngine`'s background monitor detects installs
/// or removals — no manual rescan needed.
@MainActor
final class AppStore: ObservableObject {
    @Published var apps: [AppInfo] = []
}

/// Keeps `AppStore.apps` continuously in sync with what's actually
/// installed, using a persistent Spotlight query rather than a one-shot
/// filesystem scan. `NSMetadataQuery` posts a notification every time its
/// result set changes, so installing or deleting an app updates the grid
/// automatically — including while the overlay is already open — with no
/// need to reopen LaunchBack for the list to catch up. Confirmed end to end
/// by installing and removing a real test app while monitoring: both showed
/// up within seconds, with no relaunch.
@MainActor
final class AppQueryEngine {
    static let shared = AppQueryEngine()

    private let searchPaths: [String] = {
        var paths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
        ]
        paths.append(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications")
        return paths
    }()

    private var query: NSMetadataQuery?
    private var backgroundActivityToken: NSObjectProtocol?
    private var fallbackTimer: Timer?

    // Every refresh spawns a `Task` to do the (slow-ish) icon-loading
    // enrichment concurrently with whatever Spotlight notification arrives
    // next. Without tracking and cancelling the previous one, a slower
    // *older* task can finish after a newer one and clobber `store.apps`
    // with stale data — an out-of-order-completion race that briefly looked
    // exactly like the live monitor not working at all.
    private var enrichmentTask: Task<Void, Never>?

    /// Starts the persistent monitor. Call once, at launch; safe to call
    /// again (a no-op) if a monitor is already running.
    func startMonitoring(store: AppStore) {
        guard query == nil else { return }

        // Uses Spotlight's existing index instead of walking the
        // filesystem. A plain recursive directory walk both misses
        // symlinked bundles — `/Applications/Safari.app` has pointed into a
        // system cryptex since Sonoma, and was silently dropped by
        // `FileManager`'s enumerator — and can get stuck traversing huge
        // non-app folders some dev tools drop into `/Applications` (MAMP's
        // bundled Apache/PHP/MySQL tree alone is over 56,000 files deep,
        // contributing zero real apps, and was the dominant cost in every
        // scan). Spotlight already resolves the former correctly and only
        // indexes actual application bundles, sidestepping both problems.
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
        // Custom path-array scopes work fine for a one-shot gather, but
        // live-update notifications didn't fire reliably against them in
        // testing. The predefined local-computer scope keeps live updates
        // working; the predicate still filters down to application bundles,
        // and `refresh` filters again down to just `searchPaths` below.
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        self.query = query

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(query: query, into: store)
        }

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(query: query, into: store)
        }

        // Without this, macOS App Naps this process once it's backgrounded
        // (an `.accessory` app with its window hidden looks exactly like an
        // idle background app to the OS), which risks throttling the live
        // Spotlight monitor. No natural end point, so it's never balanced
        // with `endActivity` — it should last the app's whole lifetime.
        backgroundActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Keep the Spotlight app monitor live-updating in the background"
        )

        query.start()

        // Belt-and-suspenders re-read on a timer, independent of whether an
        // update notification fires. Cheap — it's just a `resultCount` read
        // against the query's already-live index, not a fresh filesystem or
        // Spotlight query — and it guarantees the grid can never drift for
        // more than 20 seconds even in some edge case the notification path
        // doesn't cover.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh(query: query, into: store)
        }
    }

    private func refresh(query: NSMetadataQuery, into store: AppStore) {
        // Bracketing the read with disable/enable is NSMetadataQuery's
        // documented way to snapshot results without the index mutating
        // them out from under you mid-read.
        query.disableUpdates()
        let urls: [URL] = (0..<query.resultCount).compactMap { index in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  // Local-computer scope (needed for live updates — see
                  // above) returns every indexed app anywhere, including one
                  // sitting in ~/Downloads or on a mounted disk image.
                  // Restrict back down to the standard install locations
                  // classic Launchpad actually draws from.
                  searchPaths.contains(where: path.hasPrefix)
            else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        query.enableUpdates()

        enrichmentTask?.cancel()
        enrichmentTask = Task {
            let infos = await Self.loadAll(urls: urls)
            guard !Task.isCancelled else { return }
            store.apps = infos
        }
    }

    private static func loadAll(urls: [URL]) async -> [AppInfo] {
        var seenIdentifiers = Set<String>()
        var results: [AppInfo] = []

        await withTaskGroup(of: AppInfo?.self) { group in
            for url in urls {
                group.addTask { loadAppInfo(at: url) }
            }
            for await info in group {
                guard let info else { continue }
                if seenIdentifiers.insert(info.id).inserted {
                    results.append(info)
                }
            }
        }

        return results.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // Deliberately `nonisolated`: this does synchronous plist/icon I/O and
    // is called concurrently from a `TaskGroup` for every installed app.
    // Leaving it MainActor-isolated (inherited from the class by default)
    // would serialize every one of those calls onto the main thread despite
    // the surrounding concurrency, which is exactly the mistake that made
    // large `/Applications` folders slow to scan before.
    nonisolated private static func loadAppInfo(at url: URL) -> AppInfo? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        // `LSBackgroundOnly` means the app has no UI at all to launch into —
        // a pure background agent, worth excluding. `LSUIElement` only means
        // "no Dock icon by default"; Apple uses it on plenty of apps classic
        // Launchpad still shows (Screenshot, Docker, Mission Control, Time
        // Machine), so filtering on it excluded real apps, not just clutter.
        if let backgroundOnly = info["LSBackgroundOnly"] as? Bool, backgroundOnly {
            return nil
        }

        let identifier = (info["CFBundleIdentifier"] as? String) ?? url.path
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 128, height: 128)

        return AppInfo(id: identifier, name: displayName, bundleURL: url, icon: image)
    }
}
