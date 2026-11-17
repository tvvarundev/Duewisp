import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 26, *)
struct AlarmActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<ReminderAlarmMetadata>.self) { context in
            SnoozedAlarmCard(
                title: context.attributes.presentation.alert.title,
                interval: snoozeInterval(context.state),
                alarmID: context.state.alarmID
            )
            .activityBackgroundTint(Color(red: 23.0 / 255, green: 19.0 / 255, blue: 34.0 / 255))
            .activitySystemActionForegroundColor(.white)
            .environment(\.colorScheme, .dark)
        } dynamicIsland: { context in
            let interval = snoozeInterval(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Snoozed", systemImage: "alarm")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(snoozeAccent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SnoozeCountdown(interval: interval, width: 64)
                        .font(.headline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.attributes.presentation.alert.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        if let interval {
                            ringTime(interval.upperBound)
                            SnoozeActions(alarmID: context.state.alarmID)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                alarmSymbol
            } compactTrailing: {
                SnoozeCountdown(interval: interval, width: 46)
                    .font(.caption.weight(.semibold))
            } minimal: {
                alarmSymbol
            }
        }
    }

    private var alarmSymbol: some View {
        Image(systemName: "alarm")
            .accessibilityLabel("Snoozed")
    }

    private func snoozeInterval(_ state: AlarmPresentationState) -> Range<Date>? {
        guard case .countdown(let countdown) = state.mode,
              countdown.startDate < countdown.fireDate else { return nil }
        return countdown.startDate..<countdown.fireDate
    }
}

@available(iOS 26, *)
private struct SnoozedAlarmCard: View {
    let title: LocalizedStringResource
    let interval: Range<Date>?
    let alarmID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let interval {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Snoozed")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(snoozeAccent)
                        ringTime(interval.upperBound)
                    }
                    Spacer(minLength: 0)
                    SnoozeCountdown(interval: interval, width: 80)
                        .font(.title2.weight(.medium))
                } else {
                    Text(verbatim: "Duewisp")
                        .font(.caption.weight(.semibold))
                }
            }

            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            if interval != nil {
                SnoozeActions(alarmID: alarmID)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .foregroundStyle(.white)
    }
}

private func ringTime(_ date: Date) -> some View {
    Text("Rings at \(date, format: .dateTime.hour().minute())")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.75))
}

private var snoozeAccent: Color {
    Color(red: 0.83, green: 0.73, blue: 0.97)
}

@available(iOS 26, *)
private struct SnoozeActions: View {
    let alarmID: UUID

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .trailing, spacing: 4) { buttons }
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Stop Alarm", intent: CompleteReminderAlarm(alarmID: alarmID, stopAlarm: true))
            .tint(.white)
            .accessibilityHint("Silences the alarm and leaves the reminder open")

        Button(intent: CompleteReminderAlarm(alarmID: alarmID)) {
            Label("Done", systemImage: "checkmark")
        }
        .tint(snoozeAccent)
        .accessibilityLabel("Complete reminder")
    }
}

@available(iOS 26, *)
private struct SnoozeCountdown: View {
    let interval: Range<Date>?
    let width: CGFloat

    var body: some View {
        if let interval {
            Text(.currentDate, format: .timer(countingDownIn: interval, showsHours: false))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
                .frame(width: width, alignment: .trailing)
        }
    }
}
