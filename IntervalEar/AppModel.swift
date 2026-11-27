import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: Training?
    @Published private(set) var saving = false
    @Published private(set) var playing = false
    @Published private(set) var audioID: String?
    @Published private(set) var audioErrorID: String?
    @Published private(set) var heard = false
    @Published private(set) var pendingChoice: Int?
    @Published var error: String?
    @Published var hideFeedback = false
    @Published var trialBanner = true
    @Published private(set) var ratingReady = false
    private var store: TrainingStore?
    private let playback = Playback()
    private let live = LiveProgress()
    private var active = true
    private var audioIntention = 0

    func start() async {
        guard state == nil, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let folder = URL.applicationSupportDirectory.appending(path: "TwoNote", directoryHint: .isDirectory)
            let store = TrainingStore(url: folder.appending(path: Launch.testing ? "ui.sqlite" : "practice.sqlite"))
            self.store = store
            if let restored = try await store.load(reset: Launch.has("-reset")) { state = restored }
            else {
                let initial = Self.initialState()
                try await store.save(initial, adding: initial.attempts)
                state = initial
            }
            if let state { live.sync(state, canStart: false) }
            self.error = nil
        } catch { self.error = "error.storage" }
    }

    private static func initialState() -> Training {
        var initial = Training()
        if Launch.testing {
            initial.practice = fixtureRound()
        }
        if Launch.has("-fixture") {
            let today = LocalDay.key()
            for offset in 1...4 {
                initial.practice = Round(questions: Generator.questions(seed: UInt64(offset), drill: .basic))
                for index in 0..<5 {
                    initial.practice.index = index
                    initial.practice.choice = nil
                    let question = initial.practice.question
                    let chosen = index == 1 ? question.choices.first { $0 != question.distance }! : question.distance
                    _ = initial.settle(chosen, day: LocalDay.shift(today, by: 1 - offset))
                }
            }
            initial.practice = fixtureRound()
        }
        return initial
    }

    private static func fixtureRound() -> Round {
        var questions = Generator.questions(seed: 56, drill: .basic, previousRoot: 64)
        questions[0] = Question(id: questions[0].id, direction: .ascending, first: 64, second: 69, choices: Notes.basic, seed: 56)
        return Round(questions: questions)
    }

    @discardableResult
    func commit(_ next: Training, adding attempt: Attempt? = nil, startLive: Bool = false) async -> Bool {
        guard let store, !saving else { return false }
        saving = true
        defer { saving = false }
        do {
            try await store.save(next, adding: attempt.map { [$0] } ?? [])
            state = next
            self.error = nil
            live.sync(next, canStart: active && startLive)
            return true
        } catch { self.error = "error.storage"; return false }
    }

    func play() {
        guard active, !saving, let question = state?.round.question else { return }
        play(question, id: "practice")
    }

    func play(_ question: Question, id: String) {
        guard active, !saving else { return }
        playing = true
        audioID = id
        audioErrorID = nil
        if id == "practice" { error = nil }
        playback.play(question) { [weak self] success in
            guard let self else { return }
            playing = false
            audioID = nil
            if id == "practice" {
                heard = heard || success
                if !success { self.error = "error.audio" }
            } else if !success { audioErrorID = id }
        }
    }

    func stop(id: String? = nil) {
        if let id, id != audioID { return }
        audioIntention += 1
        playback.cancel()
        playing = false
        audioID = nil
    }

    func foreground(_ active: Bool) {
        self.active = active
        if !active { stop() }
    }

    func answer(_ choice: Int) async {
        guard heard, !playing, !saving, var next = state, next.settle(choice, day: LocalDay.key()) else { return }
        pendingChoice = choice
        if !Launch.testing { next.coreReviewProgress = .recording(next.coreReviewProgress) }
        if await commit(next, adding: next.attempts.last, startLive: true) {
            pendingChoice = nil
            CoreReview.shared.record(next.coreReviewProgress)
        }
    }

    func advance(pro: Bool) async {
        guard let state, state.round.choice != nil else { return }
        if state.round.last {
            if state.reviewing { await leaveReview() }
            else { await newRound(pro: pro) }
        } else {
            var next = state
            var round = next.round
            round.index += 1
            round.choice = nil
            next.updateRound(round)
            await transition(next, autoplay: true)
        }
    }

    func newRound(pro: Bool, drill: Drill? = nil, pack: PracticeSet? = nil, autoplay: Bool = true) async {
        guard var next = state else { return }
        if let drill, pro || drill == .basic { next.drill = drill }
        if let drill, pro, drill != .basic, !next.drills.contains(where: { $0.drill == drill }) { next.drills.append(SavedDrill(drill: drill)) }
        if drill != nil { next.selectedSet = nil }
        if let pack { next.selectedSet = pack.id }
        let selected = next.sets.first { $0.id == next.selectedSet }
        let questions = selected?.prompts.map { $0.question() } ?? Generator.questions(seed: UInt64.random(in: .min ... .max),
                        drill: pro ? next.drill : .basic, previousRoot: next.practice.question.first)
        next.practice = Round(questions: questions)
        next.reviewing = false
        await transition(next, autoplay: autoplay)
    }

    func startReview(pro: Bool, selected: ReviewItem? = nil, currentRound: Bool = false) async {
        guard var next = state else { return }
        if var activeReview = next.review, !activeReview.last || activeReview.choice == nil, selected == nil, !currentRound {
            if activeReview.choice != nil { activeReview.index += 1; activeReview.choice = nil }
            next.review = activeReview
            next.reviewing = true
            await transition(next, autoplay: true)
            return
        }
        let failed = Set(next.attempts.filter { $0.roundID == next.practice.id && !$0.correct }.map { $0.question.reviewKey })
        let queue = selected.map { [$0] } ?? (currentRound ? next.misses.filter { $0.pending && failed.contains($0.id) } :
            next.queue(advanced: pro, day: LocalDay.key(), direction: pro ? next.practice.question.direction : .ascending))
        guard !queue.isEmpty else { error = "review.empty"; return }
        next.review = Round(questions: queue.map(\.question), advancedReview: pro && !currentRound)
        next.reviewing = true
        await transition(next, autoplay: true)
    }

    func leaveReview() async {
        guard var next = state, next.reviewing else { return }
        next.reviewing = false
        await transition(next, autoplay: false)
    }

    private func transition(_ next: Training, autoplay: Bool) async {
        guard !saving, pendingChoice == nil else { return }
        stop()
        let intention = audioIntention
        if await commit(next, startLive: true) {
            heard = false
            hideFeedback = false
            pendingChoice = nil
            if autoplay && intention == audioIntention { play() }
        }
    }

    func markSuccessfulExport() { ratingReady = state?.canRequestRating == true }

    func requestExportReview(_ request: () -> Void) async {
        guard ratingReady, var next = state, next.canRequestRating, !playing, !saving, active,
              CoreReview.shared.attempt(request) else { return }
        ratingReady = false
        next.ratingRequested = true
        _ = await commit(next)
    }
}
