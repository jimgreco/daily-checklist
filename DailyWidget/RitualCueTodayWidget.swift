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
    @Environment(\.colorScheme) private var colorScheme

    let entry: RitualCueTodayEntry

    @ViewBuilder
    var body: some View {
        if !snapshot.hasChecklist {
            noChecklist
        } else {
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

    private var widgetInk: Color {
        colorScheme == .dark
            ? Color(red: 0.95, green: 0.94, blue: 0.99)
            : Color(red: 0.11, green: 0.10, blue: 0.16)
    }

    private var widgetSecondary: Color {
        colorScheme == .dark
            ? Color(red: 0.72, green: 0.70, blue: 0.80)
            : Color(red: 0.36, green: 0.34, blue: 0.42)
    }

    private var widgetPurple: Color {
        colorScheme == .dark
            ? Color(red: 0.65, green: 0.59, blue: 1.00)
            : Color(red: 0.39, green: 0.30, blue: 0.87)
    }

    private var widgetMint: Color {
        colorScheme == .dark
            ? Color(red: 0.34, green: 0.87, blue: 0.61)
            : Color(red: 0.10, green: 0.53, blue: 0.34)
    }

    private var widgetAmber: Color {
        colorScheme == .dark
            ? Color(red: 1.00, green: 0.73, blue: 0.31)
            : Color(red: 0.72, green: 0.43, blue: 0.05)
    }

    private var progressTint: Color {
        snapshot.remainingCount == 0 ? widgetMint : widgetPurple
    }

    private var systemSmall: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ritual Cue", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(widgetPurple)
                .symbolRenderingMode(.hierarchical)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(countText)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(widgetInk)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(taskLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(widgetSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            progressBar
            if snapshot.carryoverCount > 0 {
                Text(remainingBreakdown)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(widgetAmber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(nextReminderText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(widgetSecondary)
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
                    .foregroundStyle(widgetPurple)
                    .symbolRenderingMode(.hierarchical)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(countText)
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(widgetInk)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(taskLabel)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(widgetSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 9) {
                progressBar
                Text("\(completedTotal.formatted()) of \(snapshot.scheduledCount.formatted()) handled")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(widgetInk)
                    .lineLimit(1)
                if snapshot.carryoverCount > 0 {
                    Text(remainingBreakdown)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(widgetAmber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(nextReminderText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(widgetSecondary)
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
                .tint(progressTint)
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
                .foregroundStyle(widgetSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private var noChecklist: some View {
        switch family {
        case .accessoryInline:
            Text("Open Ritual Cue")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "checklist")
                    .font(.system(size: 20, weight: .semibold))
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Ritual Cue")
                    .font(.caption.weight(.semibold))
                Text("Open the app to begin")
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        case .systemMedium:
            HStack(spacing: 18) {
                Image(systemName: "checklist")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(widgetPurple)
                    .frame(width: 62, height: 62)
                    .background(widgetPurple.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ritual Cue")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(widgetInk)
                    Text("Open the app to add your first routine.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(widgetSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .containerBackground(widgetBackground, for: .widget)
        default:
            VStack(alignment: .leading, spacing: 8) {
                Label("Ritual Cue", systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(widgetPurple)
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(widgetPurple)
                Text("Open the app to begin")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(widgetInk)
                    .lineLimit(2)
            }
            .padding(14)
            .containerBackground(widgetBackground, for: .widget)
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(widgetInk.opacity(0.10))
                Capsule()
                    .fill(progressTint)
                    .frame(width: max(0, proxy.size.width * progress))
                    .widgetAccentable()
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }

    private var widgetBackground: some ShapeStyle {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.10, green: 0.085, blue: 0.15),
                    Color(red: 0.075, green: 0.105, blue: 0.12)
                ]
                : [
                    Color(red: 0.99, green: 0.975, blue: 0.94),
                    Color(red: 0.92, green: 0.89, blue: 0.99)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
