import XCTest
@testable import OpenUsage

/// Covers the macOS WidgetKit snapshot builder (`docs/widgetkit.md`): concentric-ring mapping for
/// Cursor, Antigravity's dual period faces, the pinned-metric single-ring fallback, used/remaining
/// math, formatting through the shared formatter, ordering/caps, and the wire schema the Swift
/// extension decodes.
@MainActor
final class WidgetSnapshotBuilderTests: XCTestCase {
    private func provider(_ id: String) -> Provider {
        Provider(id: id, displayName: id.capitalized, icon: .providerMark("cursor"))
    }

    private func inputs(
        _ orderedIDs: [String],
        snapshots: [String: ProviderSnapshot],
        preferred: [String: [String]] = [:],
        meterStyle: WidgetDisplayMode = .remaining,
        maxItems: Int = WidgetSnapshotBuilder.maxItems
    ) -> WidgetSnapshotBuilder.Inputs {
        var providersByID: [String: Provider] = [:]
        for id in Set(orderedIDs) { providersByID[id] = provider(id) }
        return WidgetSnapshotBuilder.Inputs(
            orderedEnabledProviderIDs: orderedIDs,
            providersByID: providersByID,
            snapshotsByProviderID: snapshots,
            preferredMetricLabelsByProviderID: preferred,
            meterStyle: meterStyle,
            maxItems: maxItems,
            now: Date(timeIntervalSince1970: 0)
        )
    }

    private func snapshot(providerID: String, _ lines: [MetricLine]) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: providerID,
            displayName: providerID.capitalized,
            lines: lines,
            refreshedAt: Date()
        )
    }

    private func percentLine(_ label: String, used: Double, limit: Double = 100, color: String? = nil) -> MetricLine {
        .progress(label: label, used: used, limit: limit, format: .percent, colorHex: color)
    }

    func testCursorMapsConfiguredRingsFromExistingLinesOnly() {
        let result = WidgetSnapshotBuilder.build(inputs(
            ["cursor"],
            snapshots: [
                "cursor": snapshot(
                    providerID: "cursor",
                    [percentLine("Total usage", used: 58, color: "#123456"), percentLine("Other Models", used: 72)]
                )
            ]
        ))

        let item = try! XCTUnwrap(result.items.first)
        let rings = try! XCTUnwrap(item.rings)
        // Cursor Models has no live line this period, so only Total and Other Models layers exist — order stays
        // configured (outer → inner), and the card's headline mirrors the outermost layer. Values follow
        // the global default meter style (.remaining): 58% used leaves 42% left.
        XCTAssertEqual(rings.map(\.label), ["Total usage", "Other Models"])
        XCTAssertEqual(item.label, "Total usage")
        XCTAssertEqual(item.percentText, "42%")
        XCTAssertEqual(try! XCTUnwrap(item.fraction), 0.42, accuracy: 0.0001)
        XCTAssertEqual(item.ringColor, "#123456")
        XCTAssertEqual(rings[1].ringColor, "#FF9F0A", "a colorless layer falls back to the shared palette")
        XCTAssertNil(item.weeklyRings)
    }

    func testCursorMapsAllThreeRingsWithSwiftLabels() {
        let result = WidgetSnapshotBuilder.build(inputs(
            ["cursor"],
            snapshots: [
                "cursor": snapshot(
                    providerID: "cursor",
                    [
                        percentLine("Total usage", used: 10, color: "#4CD964"),
                        percentLine("Cursor Models", used: 30, color: "#5AC8FA"),
                        percentLine("Other Models", used: 70, color: "#FF9F0A"),
                    ]
                )
            ]
        ))

        let item = try! XCTUnwrap(result.items.first)
        let rings = try! XCTUnwrap(item.rings)
        XCTAssertEqual(rings.count, 3)
        XCTAssertEqual(rings.map(\.label), ["Total usage", "Cursor Models", "Other Models"])
        XCTAssertEqual(rings.map(\.percentText), ["90%", "70%", "30%"])
    }

    func testCursorAcceptsLegacyMetricAliases() {
        let result = WidgetSnapshotBuilder.build(inputs(
            ["cursor"],
            snapshots: [
                "cursor": snapshot(
                    providerID: "cursor",
                    [
                        percentLine("Total usage", used: 15),
                        percentLine("Auto usage", used: 40),
                        percentLine("API usage", used: 60),
                    ]
                )
            ]
        ))

        let item = try! XCTUnwrap(result.items.first)
        let rings = try! XCTUnwrap(item.rings)
        XCTAssertEqual(rings.count, 3)
        XCTAssertEqual(rings.map(\.label), ["Total usage", "Auto usage", "API usage"])
    }

    func testAntigravityWritesBothPeriodFacesWhenWeeklyExists() {
        let lines = [
            percentLine("Session", used: 25),
            percentLine("Weekly", used: 91),
            percentLine("Claude", used: 10),
            percentLine("Claude Weekly", used: 100),
        ]
        let result = WidgetSnapshotBuilder.build(inputs(["antigravity"], snapshots: ["antigravity": snapshot(providerID: "antigravity", lines)]))

        let item = try! XCTUnwrap(result.items.first)
        XCTAssertEqual(try! XCTUnwrap(item.rings).map(\.label), ["Session", "Claude"])
        XCTAssertEqual(try! XCTUnwrap(item.weeklyRings).map(\.label), ["Weekly", "Claude Weekly"])
    }

    func testAntigravityOmitsWeeklyFaceWhenWeeklyLinesAreMissing() {
        let result = WidgetSnapshotBuilder.build(inputs(
            ["antigravity"],
            snapshots: ["antigravity": snapshot(providerID: "antigravity", [
                percentLine("Session", used: 25), percentLine("Claude", used: 10),
            ])]
        ))

        let item = try! XCTUnwrap(result.items.first)
        XCTAssertEqual(try! XCTUnwrap(item.rings).map(\.label), ["Session", "Claude"])
        XCTAssertNil(item.weeklyRings)
    }

    func testSingleRingPrefersPinnedMetricThenFirstBounded() {
        let lines = [percentLine("Weekly", used: 20), percentLine("Session", used: 40)]

        let unpinned = WidgetSnapshotBuilder.build(inputs(
            ["claude"], snapshots: ["claude": snapshot(providerID: "claude", lines)]
        ))
        XCTAssertEqual(unpinned.items.first?.label, "Weekly", "without pin info the first bounded line wins")

        let pinned = WidgetSnapshotBuilder.build(inputs(
            ["claude"],
            snapshots: ["claude": snapshot(providerID: "claude", lines)],
            preferred: ["claude": ["Session"]]
        ))
        XCTAssertEqual(pinned.items.first?.label, "Session")
        XCTAssertEqual(pinned.items.first?.percentText, "60%", "remaining mode: 40 of 100 used leaves 60%")
    }

    func testCountAndDollarMetricsFormatRemainingAmounts() {
        let result = WidgetSnapshotBuilder.build(inputs(
            ["codex", "grok"],
            snapshots: [
                "codex": snapshot(providerID: "codex", [
                    .progress(label: "Tokens", used: 499, limit: 1000, format: .count(suffix: ""))
                ]),
                "grok": snapshot(providerID: "grok", [
                    .progress(label: "Pay-as-you-go", used: 3, limit: 10, format: .dollars)
                ]),
            ]
        ))

        XCTAssertEqual(result.items[0].percentText, "501", "count metrics show the remaining amount")
        XCTAssertEqual(result.items[1].percentText, "$7.00", "dollar metrics show the remaining balance")
    }

    func testUsedVsRemainingFractionMathClampsOverage() {
        let used = WidgetSnapshotBuilder.build(inputs(
            ["claude"],
            snapshots: ["claude": snapshot(providerID: "claude", [
                .progress(label: "Session", used: 130, limit: 100, format: .percent)
            ])],
            meterStyle: .used
        ))
        XCTAssertEqual(try! XCTUnwrap(used.items.first?.fraction), 1.0, accuracy: 0.0001, "over-limit used still fills exactly one ring")

        let remaining = WidgetSnapshotBuilder.build(inputs(
            ["claude"],
            snapshots: ["claude": snapshot(providerID: "claude", [
                .progress(label: "Session", used: 130, limit: 100, format: .percent)
            ])],
            meterStyle: .remaining
        ))
        XCTAssertEqual(try! XCTUnwrap(remaining.items.first?.fraction), 0.0, accuracy: 0.0001, "remaining can never go negative")
        XCTAssertEqual(remaining.items.first?.percentText, "0%")
    }

    func testUnknownProvidersSkipAndCardsCapAtMaxItems() {
        let many = (0..<12).map { "prov\($0)" }
        var snapshots: [String: ProviderSnapshot] = [:]
        for id in many {
            snapshots[id] = snapshot(providerID: id, [percentLine("Quota", used: 10)])
        }
        let result = WidgetSnapshotBuilder.build(inputs(many + ["ghost"], snapshots: snapshots))
        XCTAssertEqual(result.items.count, WidgetSnapshotBuilder.maxItems)
        XCTAssertEqual(result.items.map(\.id), Array(many.prefix(WidgetSnapshotBuilder.maxItems)))
    }

    func testProviderWithoutBoundedDataKeepsPlaceholderCard() {
        let result = WidgetSnapshotBuilder.build(inputs(
            ["devin"],
            snapshots: ["devin": snapshot(providerID: "devin", [
                .badge(label: MetricLine.errorBadgeLabel, text: "Not logged in")
            ])]
        ))

        let item = try! XCTUnwrap(result.items.first)
        XCTAssertEqual(item.percentText, "—")
        XCTAssertNil(item.fraction)
        XCTAssertNil(item.rings)
    }

    func testErrorSnapshotsStillProducePlaceholderCardsInsteadOfVanishing() {
        let result = WidgetSnapshotBuilder.build(inputs(
            ["grok"],
            snapshots: ["grok": snapshot(providerID: "grok", [.progress(label: "Weekly", used: 50, limit: 0, format: .percent)])]
        ))
        XCTAssertEqual(result.items.count, 1, "a zero-limit line yields a placeholder, not a dropped provider")
        XCTAssertEqual(result.items.first?.percentText, "—")
    }

    func testJSONWireSchemaMatchesExtensionDecoderKeys() throws {
        let result = WidgetSnapshotBuilder.build(inputs(
            ["cursor"],
            snapshots: ["cursor": snapshot(providerID: "cursor", [
                .progress(label: "Total usage", used: 58, limit: 100, format: .percent, colorHex: "#4CD964")
            ])],
            maxItems: WidgetSnapshotBuilder.maxItems
        ))
        let data = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["version"] as? Int, WidgetSnapshotBuilder.version)
        XCTAssertEqual(object["displayMode"] as? String, "remaining")
        XCTAssertNotNil(object["updatedAt"] as? String)

        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first["id"] as? String, "cursor")
        XCTAssertEqual(first["percentText"] as? String, "42%")
        let rings = try XCTUnwrap(first["rings"] as? [[String: Any]])
        XCTAssertEqual(rings.first?["percentText"] as? String, "42%")
        XCTAssertNil(first["detailText"], "the retired field must never reappear on the wire")
    }
}
