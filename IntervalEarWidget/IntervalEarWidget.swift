import ActivityKit
import SwiftUI
import WidgetKit

@main
struct IntervalEarWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PracticeActivity.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label(L.t("live.title"), systemImage: "music.note")
                    .font(.headline)
                ProgressView(value: Double(context.state.answered), total: Double(context.state.total)).tint(.indigo)
                Text(L.f("live.count", context.state.answered, context.state.total)).font(.caption)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "music.note") }
                DynamicIslandExpandedRegion(.bottom) { Text(L.f("live.count", context.state.answered, context.state.total)) }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Text(L.f("live.short", context.state.answered, context.state.total)).monospacedDigit()
            } minimal: {
                Image(systemName: "music.note")
            }
        }
    }
}
