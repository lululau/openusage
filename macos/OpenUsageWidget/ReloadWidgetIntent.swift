import AppIntents
import WidgetKit

/// Tap the widget → toggle Antigravity 5h/weekly face (when weekly rings exist),
/// then re-read snapshot from disk (no host probe / remote API).
struct ReloadOpenUsageWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh OpenUsage Widget"
    static var description = IntentDescription(
        "Toggle Antigravity 5-hour/weekly rings when available, then reload the OpenUsage widget snapshot."
    )
    /// Do not launch the main Tauri app.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        // Flip period preference so Antigravity rings switch 5h ↔ weekly.
        _ = AntigravityWidgetPeriod.toggle()
        WidgetCenter.shared.reloadTimelines(ofKind: "OpenUsageWidget")
        // Also reload all as a safety net if kind string ever drifts.
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
