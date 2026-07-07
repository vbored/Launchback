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
/// populate as soon as a scan completes, instead of blocking the overlay's
/// first appearance on a full filesystem walk.
@MainActor
final class AppStore: ObservableObject {
    @Published var apps: [AppInfo] = []
}

/// Scans the standard application directories and produces de-duplicated,
/// icon-loaded `AppInfo` values. All filesystem walking and icon fetching
/// happens off the main actor; only the final `NSImage` handoff touches it.
actor AppQueryEngine {
    static let shared = AppQueryEngine()

    private let searchPaths: [URL] = {
        var paths: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser
        paths.append(home.appendingPathComponent("Applications"))
        return paths
    }()

    func scanApplications() async -> [AppInfo] {
        let bundleURLs = discoverBundleURLs()

        var seenIdentifiers = Set<String>()
        var results: [AppInfo] = []

        await withTaskGroup(of: AppInfo?.self) { group in
            for url in bundleURLs {
                group.addTask { Self.loadAppInfo(at: url) }
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

    /// Synchronous directory walk kept off the main actor by virtue of running
    /// inside the `AppQueryEngine` actor's executor.
    private nonisolated func discoverBundleURLs() -> Set<URL> {
        let fm = FileManager.default
        var bundleURLs: Set<URL> = []

        for directory in searchPaths {
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "app" {
                bundleURLs.insert(url.standardizedFileURL)
            }
        }

        return bundleURLs
    }

    private static func loadAppInfo(at url: URL) -> AppInfo? {
        // A raw plist read is much cheaper per-app than `Bundle(url:)`,
        // which also loads localization tables and other machinery we
        // don't need just to read a handful of keys — noticeable when
        // scanning 100+ apps concurrently.
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        // Skip helper/background-only bundles — they aren't user-facing apps.
        if let uiElement = info["LSUIElement"] as? Bool, uiElement {
            return nil
        }
        if let backgroundOnly = info["LSBackgroundOnly"] as? Bool, backgroundOnly {
            return nil
        }

        let identifier = (info["CFBundleIdentifier"] as? String) ?? url.path
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        // NSWorkspace.icon(forFile:) is safe to call off the main thread —
        // forcing it onto MainActor here would serialize every icon fetch
        // one at a time despite the surrounding TaskGroup, throwing away
        // most of the concurrency and making a big Applications folder
        // noticeably slow to scan.
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 128, height: 128)

        return AppInfo(id: identifier, name: displayName, bundleURL: url, icon: image)
    }
}
