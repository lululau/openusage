import AppIntents
import SwiftUI
import WidgetKit

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let snap = UsageSnapshotStore.load()
        completion(UsageEntry(date: Date(), snapshot: snap.items.isEmpty ? .placeholder : snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = UsageSnapshotStore.load()
        let entry = UsageEntry(date: Date(), snapshot: snapshot)
        let minutes = snapshot.items.isEmpty ? 1 : 5
        let next =
            Calendar.current.date(byAdding: .minute, value: minutes, to: Date())
            ?? Date().addingTimeInterval(Double(minutes) * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct OpenUsageWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: Provider.Entry

    var body: some View {
        switch family {
        case .systemSmall:
            RingsRowView(
                items: entry.snapshot.items,
                ringSize: BatteryWidgetMetrics.ringSizeSmall,
                maxVisible: 2
            )
        case .systemMedium:
            RingsRowView(
                items: entry.snapshot.items,
                ringSize: BatteryWidgetMetrics.ringSize,
                maxVisible: 4
            )
        case .systemLarge:
            largeBody
        default:
            RingsRowView(
                items: entry.snapshot.items,
                ringSize: BatteryWidgetMetrics.ringSize,
                maxVisible: 4
            )
        }
    }

    private var largeBody: some View {
        let items = Array(entry.snapshot.items.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            Text("OpenUsage")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            if items.isEmpty {
                Text("Open the app to load usage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible()), GridItem(.flexible()),
                        GridItem(.flexible()), GridItem(.flexible()),
                    ],
                    spacing: 12
                ) {
                    ForEach(items) { item in
                        ProviderRingView(
                            item: item,
                            size: BatteryWidgetMetrics.ringSizeLarge,
                            showName: true
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)
        }
    }
}

struct OpenUsageWidget: Widget {
    let kind: String = "OpenUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            // Whole-card tap: App Intent reloads timeline from disk only (no main-app probe).
            Button(intent: ReloadOpenUsageWidgetIntent()) {
                OpenUsageWidgetEntryView(entry: entry)
                    .containerBackground(for: .widget) {
                        Color(nsColor: .controlBackgroundColor).opacity(0.95)
                    }
            }
            .buttonStyle(.plain)
        }
        .configurationDisplayName("OpenUsage")
        .description("Up to 4 enabled providers as rings. Tap to re-read the latest snapshot.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
