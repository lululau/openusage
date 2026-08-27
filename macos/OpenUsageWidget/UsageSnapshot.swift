import Darwin
import Foundation

/// Shared schema + locations with the host app (`Sources/OpenUsage/Services/WidgetSnapshotWriter.swift`).
enum AppGroup {
    static let id = "group.com.robinebers.openusage"
    /// Must match the host's Application Support folder (`com.robinebers.openusage`).
    static let appSupportId = "com.robinebers.openusage"
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

/// One concentric ring layer (outer → inner in array order).
struct UsageRingLayer: Codable, Equatable {
    var label: String
    var fraction: Double
    var percentText: String
    var ringColor: String?
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
    /// Concentric multi-rings when length ≥ 2 (e.g. Cursor Total/Cursor Models/Other Models).
    /// For Antigravity this is the default 5h face (Session + Claude).
    var rings: [UsageRingLayer]?
    /// Antigravity weekly alternate (Weekly + Claude Weekly).
    var weeklyRings: [UsageRingLayer]?

    /// Layers to draw for the given period preference.
    func resolvedRings(period: AntigravityWidgetPeriod = .fiveHour) -> [UsageRingLayer] {
        if id == "antigravity",
           period == .weekly,
           let weeklyRings,
           !weeklyRings.isEmpty {
            return weeklyRings
        }
        if let rings, !rings.isEmpty {
            return rings
        }
        let frac = fraction ?? 0
        return [
            UsageRingLayer(
                label: label ?? name,
                fraction: frac,
                percentText: percentText,
                ringColor: ringColor
            ),
        ]
    }

    /// Top-level percent / label for the active period.
    func displayPercentText(period: AntigravityWidgetPeriod = .fiveHour) -> String {
        let layers = resolvedRings(period: period)
        return layers.first?.percentText ?? percentText
    }

    func displayLabel(period: AntigravityWidgetPeriod = .fiveHour) -> String? {
        let layers = resolvedRings(period: period)
        return layers.first?.label ?? label
    }
}

/// Shared preference: widget tap toggles Antigravity between 5h and weekly rings.
enum AntigravityWidgetPeriod: String {
    case fiveHour = "5h"
    case weekly = "weekly"

    static let defaultsKey = "antigravityWidgetPeriod"

    static var current: AntigravityWidgetPeriod {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? fiveHour.rawValue
        return AntigravityWidgetPeriod(rawValue: raw) ?? .fiveHour
    }

    static func toggle() -> AntigravityWidgetPeriod {
        let next: AntigravityWidgetPeriod = current == .fiveHour ? .weekly : .fiveHour
        UserDefaults.standard.set(next.rawValue, forKey: defaultsKey)
        return next
    }
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
        displayMode: "remaining",
        items: []
    )

    static let placeholder = UsageSnapshot(
        version: 1,
        updatedAt: "",
        displayMode: "remaining",
        items: [
            UsageRingItem(
                id: "claude", name: "Claude", iconFile: nil, fraction: 0.42,
                percentText: "42%", detailText: nil, ringColor: "#D97757", label: "Session",
                rings: nil
            ),
            UsageRingItem(
                id: "codex", name: "Codex", iconFile: nil, fraction: 0.61,
                percentText: "61%", detailText: nil, ringColor: nil, label: "Session",
                rings: nil
            ),
            UsageRingItem(
                id: "cursor", name: "Cursor", iconFile: nil, fraction: 0.58,
                percentText: "58%", detailText: nil, ringColor: "#4CD964", label: "Total usage",
                rings: [
                    UsageRingLayer(label: "Total usage", fraction: 0.58, percentText: "58%", ringColor: "#4CD964"),
                    UsageRingLayer(label: "Cursor Models", fraction: 0.30, percentText: "30%", ringColor: "#5AC8FA"),
                    UsageRingLayer(label: "Other Models", fraction: 0.72, percentText: "72%", ringColor: "#FF9F0A"),
                ]
            ),
            UsageRingItem(
                id: "antigravity", name: "Antigravity", iconFile: nil, fraction: 1.0,
                percentText: "100%", detailText: nil, ringColor: "#5AC8FA", label: "Session",
                rings: [
                    UsageRingLayer(label: "Session", fraction: 1.0, percentText: "100%", ringColor: "#5AC8FA"),
                    UsageRingLayer(label: "Claude", fraction: 1.0, percentText: "100%", ringColor: "#FF9F0A"),
                ],
                weeklyRings: [
                    UsageRingLayer(label: "Weekly", fraction: 0.91, percentText: "91%", ringColor: "#5AC8FA"),
                    UsageRingLayer(label: "Claude Weekly", fraction: 1.0, percentText: "100%", ringColor: "#FF9F0A"),
                ]
            ),
        ]
    )
}
