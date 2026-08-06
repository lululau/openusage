import AppIntents
import WidgetKit

/// Tap the widget → re-read snapshot from disk only (no host probe / remote API).
struct ReloadOpenUsageWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh OpenUsage Widget"
    static var description = IntentDescription(
        "Reload the OpenUsage widget from the on-disk usage snapshot."
    )
    /// Do not launch the main Tauri app.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: "OpenUsageWidget")
        // Also reload all as a safety net if kind string ever drifts.
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
