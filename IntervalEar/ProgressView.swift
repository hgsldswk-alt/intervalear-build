import SwiftUI

@MainActor
struct ProgressScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @State private var direction: Direction?
    @State private var limit = 20

    var body: some View {
        Page {
            ScreenHeader(title: L.t("progress.title"), subtitle: L.t("progress.seven"), actionTitle: L.t("common.back")) { dismiss() }
            if let state = model.state {
                let today = LocalDay.key()
                let days = (0...6).map { LocalDay.shift(today, by: $0 - 6) }
                let recent = state.attempts.filter { days.contains($0.day) }
                let summary = ProgressSummary(recent)
                VStack(spacing: 8) {
                    stat("progress.first", summary.first.count.formatted(), id: "progress.first")
                    stat("progress.accuracy", ProgressSummary.accuracy(summary.first), id: "progress.accuracy")
                    stat("progress.pending", state.misses.filter(\.pending).count.formatted(), id: "progress.pending")
                }.panel()
                chart(days, attempts: summary.first)
                VStack(spacing: 8) {
                    stat("progress.reviews", summary.reviews.count.formatted(), id: "progress.reviews")
                    stat("progress.reviewAccuracy", ProgressSummary.accuracy(summary.reviews), id: "progress.reviewAccuracy")
                }.panel()
                if purchases.hasPro { advanced(state, today: today) }
                history(state)
            }
        }
    }

    private func stat(_ title: String, _ value: String, id: String) -> some View {
        HStack {
            Text(L.t(title)).font(.subheadline)
            Spacer()
            Text(value).font(.title3.bold()).monospacedDigit().accessibilityIdentifier(id)
        }
    }

    private func chart(_ days: [String], attempts: [Attempt]) -> some View {
        let counts = days.map { day in attempts.filter { $0.day == day }.count }
        let maximum = max(counts.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 12) {
            Text(L.t("progress.byDay")).font(.headline)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(days.indices, id: \.self) { index in
                    VStack(spacing: 5) {
                        Text(counts[index].formatted()).font(.caption.bold()).contentTransition(.numericText())
                        RoundedRectangle(cornerRadius: 5).fill(counts[index] == 0 ? Theme.line : Theme.accent)
                            .frame(height: max(3, 72 * CGFloat(counts[index]) / CGFloat(maximum)))
                        Text(String(days[index].suffix(2))).font(.caption2.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L.f("progress.dayCount", days[index], counts[index]))
                }
            }
        }.panel()
    }

    @ViewBuilder
    private func advanced(_ state: Training, today: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("progress.trends")).font(.headline)
            DirectionFilter(selection: $direction, id: "progress.filter")
            ForEach(0..<4, id: \.self) { index in
                let end = LocalDay.shift(today, by: -7 * index)
                let start = LocalDay.shift(end, by: -6)
                let attempts = state.attempts.filter { !$0.review && $0.day >= start && $0.day <= end && (direction == nil || $0.question.direction == direction) }
                Text(L.f("progress.week", start, end, attempts.count, ProgressSummary.accuracy(attempts))).font(.footnote)
            }
        }.panel()
    }

    @ViewBuilder
    private func history(_ state: Training) -> some View {
        let recent = state.attempts.reversed().filter { !purchases.hasPro || direction == nil || $0.question.direction == direction }
        if !recent.isEmpty {
            Text(L.t("progress.history")).font(.headline)
            ForEach(Array(recent.prefix(limit))) { attempt in HistoryRow(attempt: attempt) }
            if recent.count > limit {
                ActionButton(title: L.t("progress.more"), id: "progress.more") { limit += 20 }
            }
        }
    }
}

@MainActor
private struct HistoryRow: View {
    let attempt: Attempt
    @State private var show = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ActionButton(title: L.f("progress.entry", attempt.day, attempt.question.direction.title,
                                    L.t(attempt.correct ? "answer.correct" : "answer.incorrect")), id: "progress.entry.\(attempt.id)") { show.toggle() }
            if show {
                AnswerDetail(question: attempt.question, choice: attempt.choice)
                AudioPreview(question: attempt.question, id: "history.replay")
            }
        }
    }
}

struct DirectionFilter: View {
    @Binding var selection: Direction?
    let id: String
    var body: some View {
        Picker(L.t("drill.mode"), selection: $selection) {
            Text(L.t("review.all")).tag(nil as Direction?)
            ForEach(Direction.allCases) { direction in Text(direction.title).tag(Optional(direction)) }
        }.accessibilityIdentifier(id)
    }
}

@MainActor
struct ReviewScheduleView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @State private var direction: Direction?
    @State private var dueOnly = true

    var body: some View {
        Page {
            ScreenHeader(title: L.t(purchases.hasPro ? "review.schedule" : "review.title"), subtitle: L.t("review.separate"), actionTitle: L.t("common.back")) { dismiss() }
            if let state = model.state {
                let today = LocalDay.key()
                let queue = state.queue(advanced: purchases.hasPro && dueOnly, day: today, direction: purchases.hasPro ? direction : nil)
                if purchases.hasPro {
                    DirectionFilter(selection: $direction, id: "review.filter")
                    Toggle(L.t("review.dueOnly"), isOn: $dueOnly).accessibilityIdentifier("review.dueOnly")
                }
                if queue.isEmpty { Text(L.t("review.empty")) }
                ForEach(queue) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(purchases.hasPro ? L.f("review.due", item.question.direction.title, item.due) : item.question.direction.title).font(.footnote)
                        AudioPreview(question: item.question, id: "review.preview.\(item.id)")
                        ActionButton(title: L.t("review.play"), id: "review.start.\(item.id)") {
                            NotificationCenter.default.post(name: .beginReview, object: item)
                        }
                    }.panel(tinted: true)
                }
            }
        }
    }
}

@MainActor
struct AudioPreview: View {
    let question: Question
    let id: String
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ActionButton(title: L.t(model.audioID == id ? "practice.playing" : "practice.replay"), id: id, icon: "play.fill") {
                model.play(question, id: id)
            }
            if model.audioErrorID == id { Text(L.t("error.audio")).font(.caption) }
        }
        .onDisappear { model.stop(id: id) }
    }
}
