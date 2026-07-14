import SwiftUI
import WidgetKit

struct RitualCueTodayEntry: TimelineEntry {
    let date: Date
    let snapshot: RitualWidgetSnapshot
}

struct RitualCueTodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> RitualCueTodayEntry {
        RitualCueTodayEntry(date: .now, snapshot: RitualWidgetSnapshot.empty())
    }

    func getSnapshot(in context: Context, completion: @escaping (RitualCueTodayEntry) -> Void) {
        completion(RitualCueTodayEntry(date: .now, snapshot: RitualWidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RitualCueTodayEntry>) -> Void) {
        let now = Date()
        let entry = RitualCueTodayEntry(date: now, snapshot: RitualWidgetSnapshotStore.load(now: now))
        let refresh = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 1),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(60 * 60)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

struct RitualCueTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: RitualWidgetSnapshotStore.kind,
            provider: RitualCueTodayProvider()
        ) { entry in
            RitualCueWidgetView(entry: entry)
                .widgetURL(RitualWidgetSnapshotStore.appURL)
        }
        .configurationDisplayName("Ritual Cue")
        .description("See how many tasks are left today.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

private struct RitualCueWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: RitualCueTodayEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            accessoryInline
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        case .systemMedium:
            systemMedium
        default:
            systemSmall
        }
    }

    private var snapshot: RitualWidgetSnapshot {
        entry.snapshot
    }

    private var countText: String {
        snapshot.remainingCount.formatted()
    }

    private var taskLabel: String {
        snapshot.remainingCount == 1 ? "task left" : "tasks left"
    }

    private var nextReminderText: String {
        guard let minutes = snapshot.upcomingReminderMinutes(now: entry.date) else {
            return snapshot.remainingCount == 0 ? "Clear for today" : "No reminder set"
        }
        let hour = minutes / 60
        let minute = minutes % 60
        guard let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) else {
            return "Reminder set"
        }
        return "Next \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var completedTotal: Int {
        snapshot.completedCount + snapshot.skippedCount
    }

    private var todayRemainingCount: Int {
        max(0, snapshot.remainingCount - snapshot.carryoverCount)
    }

    private var remainingBreakdown: String {
        "\(todayRemainingCount) today · \(snapshot.carryoverCount) still open"
    }

    private var progress: Double {
        guard snapshot.scheduledCount > 0 else { return 1 }
        return Double(completedTotal) / Double(snapshot.scheduledCount)
    }

    private var systemSmall: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ritual Cue", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(countText)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(taskLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            progressBar
            if snapshot.carryoverCount > 0 {
                Text(remainingBreakdown)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(nextReminderText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(14)
        .containerBackground(widgetBackground, for: .widget)
    }

    private var systemMedium: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Ritual Cue", systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(countText)
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(taskLabel)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 9) {
                progressBar
                Text("\(completedTotal.formatted()) of \(snapshot.scheduledCount.formatted()) handled")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if snapshot.carryoverCount > 0 {
                    Text(remainingBreakdown)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(nextReminderText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .containerBackground(widgetBackground, for: .widget)
    }

    private var accessoryInline: some View {
        if snapshot.carryoverCount > 0 {
            Text(remainingBreakdown)
        } else {
            Text("\(snapshot.remainingCount) \(taskLabel)")
        }
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(countText)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("left")
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            Gauge(value: progress) { EmptyView() }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(.green)
        }
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ritual Cue")
                .font(.caption.weight(.semibold))
            Text("\(countText) \(taskLabel)")
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(snapshot.carryoverCount > 0 ? remainingBreakdown : nextReminderText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.10))
                Capsule()
                    .fill(Color.green)
                    .frame(width: max(6, proxy.size.width * progress))
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }

    private var widgetBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.98, blue: 0.96),
                Color(red: 0.86, green: 0.93, blue: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
