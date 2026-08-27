import Foundation
import WidgetKit

/// Persists the WidgetKit snapshot the extension reads and asks WidgetKit to refresh. Replaces the old
/// Tauri edition's Rust pipeline (`src-tauri/src/widget_snapshot.rs`): same on-disk schema, now written
/// directly in-process after data changes.
///
/// The primary location is a plain Application Support folder rather than Group Containers — sandboxed
/// widgets with free/development signing get no usable App Group, while an absolute-path temporary
/// exception lets them read this path (see `docs/widgetkit.md` for the entitlement rationale). The
/// Group Containers mirror is best-effort: it only helps when both sides really have the App Group.
@MainActor
final class WidgetSnapshotWriter {
    /// Snapshot layout, one level under Application Support / <bundle id>:
    /// `widget/usage-snapshot.json` plus `widget/icons/<providerID>.svg`.
    enum Layout {
        static let fileName = "usage-snapshot.json"
        static let subdirectory = "widget"
        static let iconsSubdirectory = "icons"

        static func appGroupID(for bundleID: String) -> String { "group.\(bundleID)" }
    }

    /// Where the snapshot lives. Injected so tests write into a temp dir instead of the user's home.
    let baseDirectory: URL
    private let bundleID: String
    private let iconsBundle: Bundle
    private let fileManager: FileManager
    /// Ask WidgetKit to re-fetch timelines from disk. Injectable so tests never touch WidgetKit.
    private let reloadTimelines: @MainActor () -> Void
    /// Test/preview override replacing the Group Container lookup (which only resolves with real App
    /// Group entitlements). Nil in production, where both candidates below are probed per write.
    private let groupContainerOverride: URL?

    init(
        bundleID: String = Bundle.main.bundleIdentifier ?? "com.robinebers.openusage",
        baseDirectory: URL? = nil,
        iconsBundle: Bundle = .openUsageResources,
        fileManager: FileManager = .default,
        reloadTimelines: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        groupContainerOverride: URL? = nil
    ) {
        self.bundleID = bundleID
        self.iconsBundle = iconsBundle
        self.fileManager = fileManager
        self.reloadTimelines = reloadTimelines
        self.groupContainerOverride = groupContainerOverride
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.baseDirectory = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        }
    }

    var snapshotFileURL: URL {
        baseDirectory
            .appendingPathComponent(Layout.subdirectory, isDirectory: true)
            .appendingPathComponent(Layout.fileName)
    }

    private var iconsDirectoryURL: URL {
        baseDirectory
            .appendingPathComponent(Layout.subdirectory, isDirectory: true)
            .appendingPathComponent(Layout.iconsSubdirectory, isDirectory: true)
    }

    /// Writes the snapshot + icons and triggers a timeline reload. Failures log loudly but never throw
    /// into callers: a failed widget refresh must not take the popover UI down with it.
    func write(_ snapshot: WidgetSnapshot) {
        do {
            try fileManager.createDirectory(at: iconsDirectoryURL, withIntermediateDirectories: true)

            var items = snapshot.items
            for index in items.indices {
                items[index].iconFile = copyIcon(providerID: items[index].id)
            }
            let resolved = WidgetSnapshot(
                version: snapshot.version,
                updatedAt: snapshot.updatedAt,
                displayMode: snapshot.displayMode,
                items: items
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(resolved)
            try data.write(to: snapshotFileURL, options: [.atomic])
            // World-readable so the sandboxed extension can read it via its absolute-path exception.
            try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: snapshotFileURL.path)
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: baseDirectory.path)
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshotFileURL.deletingLastPathComponent().path)

            mirror(data, iconProviderIDs: items.map(\.id))

            AppLog.debug(.widget, "wrote \(items.count) item(s) to \(snapshotFileURL.path)")
            reloadTimelines()
        } catch {
            AppLog.error(.widget, "failed to write widget snapshot: \(error.localizedDescription)")
        }
    }

    /// Copies the provider's bundled SVG into the snapshot icons dir; returns the relative path, or nil
    /// when the provider has no packaged icon (the widget falls back to the first letter).
    private func copyIcon(providerID: String) -> String? {
        guard let source = iconsBundle.url(forResource: providerID, withExtension: "svg", subdirectory: "ProviderIcons"),
              let data = try? Data(contentsOf: source)
        else { return nil }
        let destination = iconsDirectoryURL.appendingPathComponent("\(providerID).svg")
        do {
            try data.write(to: destination, options: [.atomic])
            return "\(Layout.iconsSubdirectory)/\(providerID).svg"
        } catch {
            AppLog.warn(.widget, "icon copy failed for \(providerID): \(error.localizedDescription)")
            return nil
        }
    }

    /// Best-effort mirrors into the real Group Container(s) for hosts that DO have a provisioned App
    /// Group. Never fails the write — the Application Support copy above always stands alone.
    private func mirror(_ data: Data, iconProviderIDs: [String]) {
        var containerDirectories: [URL] = []
        if let groupContainerOverride {
            containerDirectories.append(groupContainerOverride)
        } else {
            if let provisioned = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: Layout.appGroupID(for: bundleID)
            ) {
                containerDirectories.append(provisioned)
            }
            // Literal fallback mirrors the extension's own read path (real user home), catching hosts
            // whose profile includes the group before containermanagerd provisions the sandbox view.
            let literal = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Group Containers", isDirectory: true)
                .appendingPathComponent(Layout.appGroupID(for: bundleID), isDirectory: true)
            if !containerDirectories.contains(literal) { containerDirectories.append(literal) }
        }

        for directory in containerDirectories {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(Layout.fileName), options: [.atomic])
                let iconsDir = directory.appendingPathComponent(Layout.iconsSubdirectory, isDirectory: true)
                try fileManager.createDirectory(at: iconsDir, withIntermediateDirectories: true)
                for id in iconProviderIDs {
                    let source = iconsDirectoryURL.appendingPathComponent("\(id).svg")
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    try? fileManager.copyItem(at: source, to: iconsDir.appendingPathComponent("\(id).svg"))
                }
            } catch {
                AppLog.debug(.widget, "group-container mirror skipped at \(directory.path): \(error.localizedDescription)")
            }
        }
    }
}
