import XCTest
@testable import OpenUsage

/// Covers the macOS WidgetKit snapshot writer: JSON lands at the documented path, provider icons are
/// copied from the packaged resource bundle, the extension-facing reload hook fires exactly once per
/// write, and a provider with no packaged icon degrades to no icon file instead of failing the write.
@MainActor
final class WidgetSnapshotWriterTests: XCTestCase {
    private func makeTempBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetSnapshotWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A directory bundle exposing `ProviderIcons/<id>.svg`, standing in for the packaged resources.
    private func makeIconBundle(iconIDs: [String]) throws -> Bundle {
        let root = try makeTempBase().appendingPathComponent("Icons.bundle", isDirectory: true)
        let icons = root.appendingPathComponent("ProviderIcons", isDirectory: true)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)
        for id in ["claude", "codex", "cursor"] where iconIDs.contains(id) {
            try svg.write(to: icons.appendingPathComponent("\(id).svg"))
        }
        return Bundle(url: root)!
    }

    private func makeWriter(
        base: URL,
        icons: Bundle,
        reload: @escaping @MainActor () -> Void
    ) -> WidgetSnapshotWriter {
        WidgetSnapshotWriter(
            bundleID: "com.robinebers.openusage",
            baseDirectory: base.appendingPathComponent("AppSupport/com.robinebers.openusage", isDirectory: true),
            iconsBundle: icons,
            reloadTimelines: reload
        )
    }

    func testWriteProducesJSONAtDocumentedPathAndCopiesIcons() throws {
        let base = try makeTempBase()
        var reloads = 0
        let writer = makeWriter(base: base, icons: try makeIconBundle(iconIDs: ["claude"])) { reloads += 1 }

        writer.write(WidgetSnapshot(
            version: 1,
            updatedAt: "2026-08-06T00:00:00.000Z",
            displayMode: "remaining",
            items: [
                WidgetSnapshotItem(id: "claude", name: "Claude", fraction: 0.4, percentText: "40%")
            ]
        ))

        XCTAssertEqual(reloads, 1, "every write must end in one WidgetKit reload request")

        let json = try XCTUnwrap(base.appendingPathComponent("AppSupport/com.robinebers.openusage/widget/usage-snapshot.json"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: json.path)[.posixPermissions] as? Int, 0o644)

        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: json))
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertEqual(decoded.items[0].iconFile, "icons/claude.svg")
        let iconURL = json.deletingLastPathComponent().appendingPathComponent("icons/claude.svg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path))
    }

    func testProviderWithoutPackagedIconOmitsIconFileInsteadOfFailing() throws {
        let base = try makeTempBase()
        let writer = makeWriter(base: base, icons: try makeIconBundle(iconIDs: [])) {}

        writer.write(WidgetSnapshot(
            version: 1,
            updatedAt: "",
            displayMode: "remaining",
            items: [WidgetSnapshotItem(id: "devin", name: "Devin", percentText: "—")]
        ))

        let json = base.appendingPathComponent("AppSupport/com.robinebers.openusage/widget/usage-snapshot.json")
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: json))
        XCTAssertNil(decoded.items[0].iconFile)
    }

    func testGroupContainerMirrorIsWrittenWhenReachable() throws {
        let base = try makeTempBase()
        // The Group Container lookup is entitlement-gated, so tests inject a stand-in directory
        // instead of relying on the (cached) NSHomeDirectory environment — and never touch the real
        // user container.
        let containerDir = base.appendingPathComponent("GroupContainers/group.com.robinebers.openusage", isDirectory: true)
        let writer = WidgetSnapshotWriter(
            bundleID: "com.robinebers.openusage",
            baseDirectory: base.appendingPathComponent("AppSupport/com.robinebers.openusage", isDirectory: true),
            iconsBundle: try makeIconBundle(iconIDs: ["claude"]),
            reloadTimelines: {},
            groupContainerOverride: containerDir
        )
        writer.write(WidgetSnapshot(
            version: 1,
            updatedAt: "",
            displayMode: "remaining",
            items: [WidgetSnapshotItem(id: "claude", name: "Claude", percentText: "40%")]
        ))

        let mirrorJSON = containerDir.appendingPathComponent("usage-snapshot.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirrorJSON.path))
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: mirrorJSON)).version, 1)
        // Icons ride along so the extension resolves iconFile under the same base.
        XCTAssertTrue(FileManager.default.fileExists(atPath: containerDir.appendingPathComponent("icons/claude.svg").path))
    }
}
