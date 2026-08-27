import Foundation

/// The JSON payload the macOS WidgetKit extension reads (see `docs/widgetkit.md` and
/// `macos/OpenUsageWidget/UsageSnapshot.swift`, which owns the matching decoder). Kept in one place on
/// the host side so the writer and its tests share a single schema definition.
struct WidgetSnapshot: Codable, Equatable {
    var version: Int
    var updatedAt: String
    /// The global meter style when this snapshot was written ("remaining" / "used").
    var displayMode: String
    var items: [WidgetSnapshotItem]
}

/// One provider card in the widget layout: a ring gauge plus one value line beneath it.
struct WidgetSnapshotItem: Codable, Equatable {
    var id: String
    var name: String
    /// Path relative to the snapshot directory, e.g. "icons/cursor.svg". Set by the writer after it
    /// copies the SVG; absent when no icon resource exists for the provider.
    var iconFile: String?
    /// 0...1 fill of the single-ring card; omitted when unknown.
    var fraction: Double?
    /// The one value under the ring: percent ("74%"), remaining count ("499"), or dollars ("$12.50").
    var percentText: String
    var ringColor: String?
    /// Primary metric label, e.g. "Session".
    var label: String?
    /// Concentric rings (outer → inner) when ≥ 2 configured metrics exist — Cursor Total/Auto/API.
    var rings: [WidgetRingLayer]?
    /// Antigravity's alternate period face (Weekly + Claude Weekly); widget tap toggles both faces.
    var weeklyRings: [WidgetRingLayer]?
}

/// One concentric ring layer, outermost first in array order.
struct WidgetRingLayer: Codable, Equatable {
    var label: String
    /// 0...1 arc fill (honors the global used/remaining meter style).
    var fraction: Double
    /// This layer's value text, usually "NN%".
    var percentText: String
    var ringColor: String?
}

/// Builds the WidgetKit snapshot from the same data every other surface reads. One card per enabled
/// provider, in dashboard order:
///
/// - Providers with a multi-ring configuration draw concentric layers from their bounded progress lines
///   (Cursor: Total usage · Auto usage · API usage). Only lines that actually exist are included.
/// - Antigravity writes two faces: the default 5-hour pair (Session + Claude) and the weekly alternate
///   (Weekly + Claude Weekly), which the widget toggles on tap.
/// - Every other provider falls back to a single ring from its menu-bar pinned metric (matching what the
///   tray shows), then to its first bounded progress line.
enum WidgetSnapshotBuilder {
    static let version = 1

    /// Medium shows 4 cards, large can show 8 — keep the file capped at 8.
    static let maxItems = 8

    /// Per-provider concentric ring labels, outer → inner. Antigravity is period-based instead (see
    /// below), so it is not listed here.
    private static let multiRingLabels: [String: [String]] = [
        // Total pool, then the Auto/Composer and API/$ pools as their meters appear.
        "cursor": ["Total usage", "Auto usage", "API usage"]
    ]

    /// Antigravity's two period faces. Both are written into every snapshot so the extension can
    /// toggle without asking the app for anything.
    private static let antigravityFiveHourLabels = ["Session", "Claude"]
    private static let antigravityWeeklyLabels = ["Weekly", "Claude Weekly"]

    /// Fallback stroke colors when a metric line carries no color (outer → inner).
    private static let fallbackRingColors = ["#4CD964", "#5AC8FA", "#FF9F0A"]

    struct Inputs {
        var orderedEnabledProviderIDs: [String]
        var providersByID: [String: Provider]
        var snapshotsByProviderID: [String: ProviderSnapshot]
        /// Per provider, the labels of that provider's menu-bar pinned metrics in pin order — the
        /// single-ring fallback should match what the tray shows. Optional so tests can omit it.
        var preferredMetricLabelsByProviderID: [String: [String]]
        var meterStyle: WidgetDisplayMode
        var maxItems: Int = WidgetSnapshotBuilder.maxItems
        var now: Date = Date()
    }

    static func build(_ inputs: Inputs) -> WidgetSnapshot {
        var items: [WidgetSnapshotItem] = []
        items.reserveCapacity(min(inputs.maxItems, inputs.orderedEnabledProviderIDs.count))

        for providerID in inputs.orderedEnabledProviderIDs {
            guard let provider = inputs.providersByID[providerID] else { continue }
            if items.count >= inputs.maxItems { break }
            let lines = inputs.snapshotsByProviderID[providerID]?.lines ?? []

            var rings: [WidgetRingLayer]?
            var weeklyRings: [WidgetRingLayer]?
            if providerID == "antigravity" {
                rings = buildRings(labels: antigravityFiveHourLabels, lines: lines, inputs: inputs)
                weeklyRings = buildRings(labels: antigravityWeeklyLabels, lines: lines, inputs: inputs)
                if weeklyRings?.isEmpty != false { weeklyRings = nil }
            } else {
                rings = buildRings(labels: multiRingLabels[providerID], lines: lines, inputs: inputs)
            }

            if let rings, !rings.isEmpty {
                let head = rings[0]
                items.append(WidgetSnapshotItem(
                    id: providerID,
                    name: provider.displayName,
                    iconFile: nil,
                    fraction: head.fraction,
                    percentText: head.percentText,
                    ringColor: head.ringColor,
                    label: head.label,
                    rings: rings,
                    weeklyRings: weeklyRings
                ))
                continue
            }

            guard let primary = pickPrimaryLine(
                preferredLabels: inputs.preferredMetricLabelsByProviderID[providerID],
                lines: lines
            ) else {
                // Nothing bounded to draw yet — a placeholder card keeps the provider visible with "—",
                // matching how a no-data tile renders on the dashboard rather than silently vanishing.
                items.append(WidgetSnapshotItem(
                    id: providerID,
                    name: provider.displayName,
                    iconFile: nil,
                    fraction: nil,
                    percentText: "—",
                    ringColor: nil,
                    label: nil,
                    rings: nil,
                    weeklyRings: nil
                ))
                continue
            }

            let layer = progressLayer(from: primary, colorIndex: nil, inputs: inputs)
            guard let layer else { continue }
            items.append(WidgetSnapshotItem(
                id: providerID,
                name: provider.displayName,
                iconFile: nil,
                fraction: layer.fraction,
                percentText: layer.percentText,
                ringColor: layer.ringColor,
                label: layer.label,
                rings: nil,
                weeklyRings: nil
            ))
        }

        return WidgetSnapshot(
            version: version,
            updatedAt: OpenUsageISO8601.string(from: inputs.now),
            displayMode: inputs.meterStyle.rawValue,
            items: items
        )
    }

    /// Layers for every configured label that has a live bounded line, outer → inner.
    private static func buildRings(
        labels: [String]?,
        lines: [MetricLine],
        inputs: Inputs
    ) -> [WidgetRingLayer] {
        guard let labels, !labels.isEmpty else { return [] }

        var rings: [WidgetRingLayer] = []
        for (index, label) in labels.enumerated() {
            let line = progressLines(lines).first { $0.label == label }
            guard let line else { continue }
            let layer = progressLayer(
                from: line,
                colorIndex: index < fallbackRingColors.count ? index : nil,
                inputs: inputs
            )
            if let layer { rings.append(layer) }
        }
        return rings
    }

    /// The single-ring fallback: the provider's first pinned (tray-visible) bounded line, then its first
    /// bounded line at all — always preferring a line the meter can actually render (limit > 0).
    private static func pickPrimaryLine(preferredLabels: [String]?, lines: [MetricLine]) -> MetricLine? {
        let bounded = progressLines(lines).filter { (boundLimit(of: $0) ?? 0) > 0 }
        if let preferredLabels, !preferredLabels.isEmpty {
            for label in preferredLabels {
                if let line = bounded.first(where: { $0.label == label }) { return line }
            }
        }
        return bounded.first
    }

    /// The `.progress` case's capacity; nil for every other line shape.
    private static func boundLimit(of line: MetricLine) -> Double? {
        if case .progress(_, _, let limit, _, _, _, _) = line { return limit }
        return nil
    }

    private static func progressLines(_ lines: [MetricLine]) -> [MetricLine] {
        lines.filter { line in
            if case .progress = line { return true }
            return false
        }
    }

    /// Maps a bounded `.progress` line onto a ring layer. Fails (nil) only for a degenerate limit ≤ 0,
    /// which no surface can render as a meter.
    private static func progressLayer(
        from line: MetricLine,
        colorIndex: Int?,
        inputs: Inputs
    ) -> WidgetRingLayer? {
        guard case .progress(_, let used, let limit, let format, _, _, let colorHex) = line else {
            return nil
        }
        guard limit > 0 else { return nil }

        let shownAmount = switch inputs.meterStyle {
        case .used: used
        case .remaining: max(0, limit - used)
        }
        let clamped = min(1, max(0, shownAmount / limit))
        return WidgetRingLayer(
            label: line.label,
            fraction: clamped,
            percentText: primaryText(for: format, shownAmount: shownAmount, fraction: clamped),
            ringColor: colorHex ?? (colorIndex.flatMap { fallbackRingColors[$0] })
        )
    }

    /// Battery-widget style: exactly one value per ring. Percent prints "%"; counts print the remaining /
    /// used amount compactly ("499", "56.9K"); dollars print cents ("$12.50") — all through the shared
    /// formatter so the widget can never disagree with the popover row.
    private static func primaryText(for format: ProgressFormat, shownAmount: Double, fraction: Double) -> String {
        switch format {
        case .percent:
            return "\(Int((fraction * 100).rounded()))%"
        case .dollars:
            return MetricFormatter.number(shownAmount, kind: .dollars, style: .row)
        case .count:
            return MetricFormatter.number(shownAmount, kind: .count, style: .row)
        }
    }
}
