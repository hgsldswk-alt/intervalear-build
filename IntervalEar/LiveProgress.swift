import ActivityKit
import Foundation

@MainActor
final class LiveProgress {
    private var updates: Task<Void, Never>?

    func sync(_ training: Training, canStart: Bool) {
        guard !Launch.testing else { return }
        let round = training.round
        let state = PracticeActivity.ContentState(answered: round.index + (round.choice == nil ? 0 : 1), total: round.questions.count)
        let enabled = training.liveEnabled && state.answered < state.total && ActivityAuthorizationInfo().areActivitiesEnabled
        let previous = updates
        updates = Task {
            await previous?.value
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(1800))
            let activities = Activity<PracticeActivity>.activities
            if !enabled {
                for activity in activities { await activity.end(content, dismissalPolicy: .immediate) }
            } else if let activity = activities.first {
                await activity.update(content)
            } else if canStart {
                _ = try? Activity.request(attributes: PracticeActivity(), content: content, pushType: nil)
            }
        }
    }
}
