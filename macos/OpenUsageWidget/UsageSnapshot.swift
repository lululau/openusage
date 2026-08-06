import Darwin
import Foundation

/// Shared data with the Tauri main app (`src-tauri/src/widget_snapshot.rs`).
enum AppGroup {
    static let id = "group.com.sunstory.openusage"
    /// Must match host Application Support folder (`com.sunstory.openusage`).
    static let appSupportId = "com.sunstory.openusage"
    static let snapshotFileName = "usage-snapshot.json"
    static let widgetSubdir = "widget"

    /// Official App Group container (when entitlement + profile allow it).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// Real user home (not the extension sandbox container home).
    static var realUserHomeURL: URL? {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty,
           !home.contains("/Library/Containers/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return nil
    }

    /// Primary sideload path — host writes here; not gated by containermanagerd.
    static var applicationSupportSnapshotURL: URL? {
        realUserHomeURL?
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appSupportId, isDirectory: true)
            .appendingPathComponent(widgetSubdir, isDirectory: true)
            .appendingPathComponent(snapshotFileName)
    }

    static var applicationSupportWidgetDir: URL? {
        realUserHomeURL?
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appSupportId, isDirectory: true)
            .appendingPathComponent(widgetSubdir, isDirectory: true)
    }

    static var groupContainersSnapshotURL: URL? {
        realUserHomeURL?
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(snapshotFileName)
    }

    static var resolvedContainerURLs: [URL] {
        var urls: [URL] = []
        if let u = applicationSupportWidgetDir { urls.append(u) }
        if let u = containerURL { urls.append(u) }
        if let home = realUserHomeURL {
            let g = home
                .appendingPathComponent("Library/Group Containers", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            if !urls.contains(g) { urls.append(g) }
        }
        return urls
    }

    static var snapshotURLs: [URL] {
        var list: [URL] = []
        if let u = applicationSupportSnapshotURL { list.append(u) }
        if let u = groupContainersSnapshotURL { list.append(u) }
        for base in resolvedContainerURLs {
            let u = base.appendingPathComponent(snapshotFileName)
            if !list.contains(u) { list.append(u) }
        }
        return list
    }

    static func resolveFile(relativePath: String) -> URL? {
        for base in resolvedContainerURLs {
            let url = base.appendingPathComponent(relativePath)
            if FileManager.default.isReadableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

struct UsageSnapshot: Codable, Equatable {
    var version: Int
    var updatedAt: String
    var displayMode: String
    var items: [UsageRingItem]
}

struct UsageRingItem: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var iconFile: String?
    var fraction: Double?
    var percentText: String
    var detailText: String?
    var ringColor: String?
    var label: String?
}

enum UsageSnapshotStore {
    static private(set) var lastLoadNote: String = ""

    static func load() -> UsageSnapshot {
        let decoder = JSONDecoder()
        var errors: [String] = []

        let urls = AppGroup.snapshotURLs
        if urls.isEmpty {
            lastLoadNote = "no snapshot paths (home=\(AppGroup.realUserHomeURL?.path ?? "nil"))"
            return .empty
        }

        for url in urls {
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let snap = try decoder.decode(UsageSnapshot.self, from: data)
                if snap.items.isEmpty {
                    errors.append("empty items @ \(url.path)")
                    continue
                }
                lastLoadNote = "ok \(snap.items.count) from \(url.lastPathComponent)"
                return snap
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        lastLoadNote = errors.joined(separator: " | ")
        return .empty
    }
}

extension UsageSnapshot {
    static let empty = UsageSnapshot(
        version: 1,
        updatedAt: "",
        displayMode: "left",
        items: []
    )

    static let placeholder = UsageSnapshot(
        version: 1,
        updatedAt: "",
        displayMode: "left",
        items: [
            UsageRingItem(
                id: "grok", name: "Grok", iconFile: nil, fraction: 0.72,
                percentText: "72%", detailText: nil, ringColor: nil, label: "SuperGrok"
            ),
            UsageRingItem(
                id: "antigravity", name: "Antigravity", iconFile: nil, fraction: 1.0,
                percentText: "100%", detailText: nil, ringColor: nil, label: "Gemini Pro"
            ),
            UsageRingItem(
                id: "cursor", name: "Cursor", iconFile: nil, fraction: 0.5,
                percentText: "500", detailText: nil, ringColor: nil, label: "Requests"
            ),
            UsageRingItem(
                id: "zai", name: "Z.ai", iconFile: nil, fraction: 0.99,
                percentText: "99%", detailText: nil, ringColor: nil, label: "Session"
            ),
        ]
    )
}
