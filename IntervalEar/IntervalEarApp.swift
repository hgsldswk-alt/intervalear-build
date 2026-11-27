import StoreKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct IntervalEarApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var purchases = Purchases()

    var body: some Scene {
        WindowGroup {
            PracticeView()
                .environmentObject(model).environmentObject(purchases)
                .preferredColorScheme(.light)
        }
    }
}

@MainActor
struct PracticeView: View {
    private enum Sheet: String, Identifiable {
        case settings, progress, challenge, milestone, paywall, importSet, review
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var sheet: Sheet?
    @State private var importedText = ""
    @State private var pickingSetFile = false
    @State private var presentedTestPaywall = false
    @State private var ratingTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let state = model.state { screen(state) }
            else {
                Page {
                    ScreenHeader(title: L.t("app.title"), subtitle: L.t("app.subtitle"))
                    if let error = model.error {
                        Text(L.t(error))
                        ActionButton(title: L.t("common.retry"), id: "storage.retry") { Task { await model.start() } }
                    } else { ProgressView(L.t("common.loading")) }
                }
            }
        }
        .task { await model.start() }
        .task { await purchases.start() }
        .reviewAfterCoreAction(when: ratingHome) { requestReview() }
        .onChange(of: phase, initial: true) { _, value in
            model.foreground(value == .active)
            if value == .active { purchases.tick(); evaluateRating() }
        }
        .onChange(of: model.state != nil, initial: true) { _, ready in
            if ready && Launch.hasInAppPurchases && Launch.has("-paywall") && !presentedTestPaywall {
                presentedTestPaywall = true
                open(.paywall)
            }
        }
        .onChange(of: model.ratingReady) { _, _ in evaluateRating() }
        .onChange(of: model.playing) { _, _ in evaluateRating() }
        .onChange(of: model.saving) { _, _ in evaluateRating() }
        .onReceive(NotificationCenter.default.publisher(for: .beginDrill)) { note in
            guard let drill = note.object as? Drill else { return }
            sheet = nil
            Task { await model.newRound(pro: purchases.hasPro, drill: drill, autoplay: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .beginSet)) { note in
            guard let set = note.object as? PracticeSet else { return }
            sheet = nil
            Task { await model.newRound(pro: purchases.hasPro, pack: set, autoplay: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .beginReview)) { note in
            guard let item = note.object as? ReviewItem else { return }
            model.stop()
            sheet = nil
            Task { await model.startReview(pro: purchases.hasPro, selected: item) }
        }
        .onOpenURL { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "intervalset" else { return }
            Task { await openSetFile(url) }
        }
        .fileImporter(isPresented: $pickingSetFile, allowedContentTypes: [ImportSetView.type, .plainText]) { result in
            switch result {
            case .success(let url): Task { await openSetFile(url) }
            case .failure: model.error = "import.invalid"
            }
        }
        .sheet(item: $sheet, onDismiss: evaluateRating) { item in
            switch item {
            case .settings: SettingsView()
            case .progress: ProgressScreen()
            case .challenge:
                if let question = model.state?.round.question { SharePreview(kind: .challenge(question)) }
            case .milestone:
                if let count = model.state?.milestone { SharePreview(kind: .milestone(count)) }
            case .paywall: PaywallView()
            case .importSet: ImportSetView(initialText: importedText)
            case .review: ReviewScheduleView()
            }
        }
    }

    private func chooseSetFile() {
        if Launch.testing, let code = ProcessInfo.processInfo.environment["INTERVALEAR_TEST_SET_FILE"] {
            Task {
                let url = FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString).appendingPathExtension("intervalset")
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    try code.write(to: url, atomically: true, encoding: .utf8)
                    await openSetFile(url)
                } catch { model.error = "import.invalid" }
            }
        } else { pickingSetFile = true }
    }

    private func openSetFile(_ url: URL) async {
        do {
            importedText = try await Task.detached { try SetCode.read(url) }.value
            open(.importSet)
        } catch { model.error = "import.invalid" }
    }

    private func open(_ page: Sheet) {
        model.stop()
        ratingTask?.cancel()
        sheet = page
    }

    private func evaluateRating() {
        guard !Launch.testing, canPromptForRating, model.ratingReady else { return }
        ratingTask?.cancel()
        ratingTask = Task {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard canPromptForRating else { return }
            guard !Task.isCancelled, purchases.hasPro else { return }
            await model.requestExportReview { requestReview() }
        }
    }

    private var canPromptForRating: Bool { ratingHome && purchases.hasPro }

    private var ratingHome: Bool {
        guard phase == .active, sheet == nil, !pickingSetFile, !model.playing, !model.saving,
              model.error == nil, model.audioErrorID == nil else { return false }
        guard let round = model.state?.round, let choice = round.choice, !model.hideFeedback else { return true }
        return choice == round.question.distance
    }

    private func screen(_ state: Training) -> some View {
        let round = state.round
        let feedback = round.choice != nil && !model.hideFeedback
        return GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(state, feedback: feedback)
                    if !state.reviewing && !feedback && purchases.trialActive && model.trialBanner && !Launch.has("-fixture") {
                        trialBanner
                    }
                    if feedback, let choice = round.choice { feedbackBody(state, choice: choice) }
                    else { questionBody(state) }
                    if let error = model.error {
                        Text(L.t(error)).font(.footnote).foregroundStyle(Theme.accent).accessibilityIdentifier("practice.message")
                    }
                    Spacer(minLength: 14)
                    if feedback { nextButton(state) }
                    else if !state.reviewing { shortcuts(state) }
                    else { Text(L.t("review.separate")).font(.caption).foregroundStyle(Theme.muted) }
                }
                .frame(maxWidth: 560)
                .padding(20)
                .frame(minHeight: geometry.size.height, alignment: .top)
                .frame(maxWidth: .infinity)
            }
        }
        .pageStyle()
    }

    private func header(_ state: Training, feedback: Bool) -> some View {
        let count = L.f(state.reviewing ? "review.number" : "practice.number", state.round.index + 1, state.round.questions.count)
        return ScreenHeader(title: L.t(feedback ? "answer.title" : state.reviewing ? "review.title" : "app.title"),
            subtitle: feedback ? count : L.t(state.reviewing ? "review.subtitle" : "app.subtitle"),
            actionTitle: L.t(feedback || state.reviewing ? "common.back" : "settings.title"),
            actionID: feedback || state.reviewing ? "practice.back" : "practice.settings") {
                if state.reviewing { Task { await model.leaveReview() } }
                else if feedback { model.stop(); model.hideFeedback = true }
                else { open(.settings) }
            }
    }

    private var trialBanner: some View {
        HStack(spacing: 4) {
            Button { open(.paywall) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.f("trial.remaining", purchases.daysLeft)).font(.footnote.bold())
                    Text(purchases.pro.map { L.f("trial.price", $0.displayPrice) } ?? L.t("trial.priceUnavailable"))
                        .font(.caption).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 6)
            }
            .buttonStyle(.plain).accessibilityIdentifier("trial.details")
            Button { model.trialBanner = false } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).accessibilityLabel(L.t("common.close")).accessibilityIdentifier("trial.dismiss")
        }
        .padding(.horizontal, 12)
        .background(.white, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func questionBody(_ state: Training) -> some View {
        let round = state.round
        HStack {
            Text(round.question.direction.title)
            Spacer()
            Text(L.f(state.reviewing ? "review.number" : "practice.number", round.index + 1, round.questions.count))
                .foregroundStyle(Theme.accent).accessibilityIdentifier("practice.number")
        }.font(.footnote.bold())
        VStack(alignment: .leading, spacing: 13) {
            Text(L.t(state.reviewing ? "review.eyebrow" : "practice.listen")).font(.caption.bold()).tracking(1).foregroundStyle(Theme.accent)
            Text(L.t(state.reviewing ? "review.prompt" : "practice.prompt")).font(.title2.bold())
            NotePair()
            if round.choice != nil {
                ActionButton(title: L.t("answer.show"), id: "practice.feedback", primary: true) { model.hideFeedback = false }
            } else {
                ActionButton(title: L.t(model.playing ? "practice.playing" : model.heard ? "practice.replay" : "practice.play"),
                             id: "practice.play", icon: "play.fill", primary: true) { model.play() }
                    .disabled(model.saving || model.pendingChoice != nil)
            }
        }.panel(tinted: true)
        HStack {
            Text(L.t("practice.choose")).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            if !model.heard && round.choice == nil { Text(L.t("practice.listenFirst")).font(.caption).foregroundStyle(Theme.muted) }
        }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: textSize.isAccessibilitySize ? 1 : 2), spacing: 9) {
            ForEach(round.question.choices, id: \.self) { option in
                ActionButton(title: Notes.interval(option), id: "answer.\(option)") { Task { await model.answer(option) } }
                    .disabled(model.playing || !model.heard || round.choice != nil || model.saving || model.pendingChoice != nil)
            }
        }
        Button(L.t("share.challenge")) { open(.challenge) }
            .font(.footnote.bold()).foregroundStyle(Theme.accent).frame(minHeight: 44)
            .accessibilityIdentifier("practice.challenge").disabled(model.saving)
        if let pending = model.pendingChoice {
            ActionButton(title: L.f("answer.retry", Notes.interval(pending)), id: "answer.retry") {
                Task { await model.answer(pending) }
            }.disabled(model.saving)
        }
    }

    @ViewBuilder
    private func feedbackBody(_ state: Training, choice: Int) -> some View {
        AnswerDetail(question: state.round.question, choice: choice)
        ActionButton(title: L.t(model.playing ? "practice.playing" : "practice.replay"), id: "feedback.replay", icon: "play.fill") { model.play() }
        ActionButton(title: L.t("share.challenge"), id: "feedback.challenge") { open(.challenge) }
        if state.round.last {
            let results = state.attempts.filter { $0.roundID == state.round.id }
            let failed = Set(results.lazy.filter { !$0.correct }.map { $0.question.reviewKey })
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("summary.title")).font(.headline).accessibilityIdentifier("summary.title")
                Text(L.f("summary.score", results.filter(\.correct).count, results.count))
                if !state.reviewing && state.misses.contains(where: { $0.pending && failed.contains($0.id) }) {
                    ActionButton(title: L.t("review.current"), id: "summary.review") {
                        Task { await model.startReview(pro: purchases.hasPro, currentRound: true) }
                    }
                }
            }.panel()
            if !state.reviewing, let milestone = state.milestone {
                HStack {
                    ActionButton(title: L.t("milestone.title"), id: "summary.milestone") { open(.milestone) }
                    Button {
                        Task { var next = state; next.dismissedMilestone = milestone; await model.commit(next) }
                    } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel(L.t("common.close")).accessibilityIdentifier("milestone.dismiss")
                }
            }
        }
    }

    private func nextButton(_ state: Training) -> some View {
        ActionButton(title: L.t(state.round.last ? (state.reviewing ? "common.done" : "summary.again") : "practice.next"),
                     id: "practice.next", icon: state.round.last && state.reviewing ? nil : "play.fill", primary: true) {
            Task { await model.advance(pro: purchases.hasPro) }
        }.disabled(model.saving)
    }

    @ViewBuilder private var setImportActions: some View {
        Button {
            importedText = ""
            open(.importSet)
        } label: {
            Text(L.t("import.title")).frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("practice.importSet")
        Button(action: chooseSetFile) {
            Text(L.t("import.file")).frame(minHeight: 44).contentShape(Rectangle())
        }
            .accessibilityIdentifier("practice.importSetFile")
    }

    private func shortcuts(_ state: Training) -> some View {
        let queue = state.queue(advanced: purchases.hasPro, day: LocalDay.key(), direction: purchases.hasPro ? state.practice.question.direction : .ascending)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ActionButton(title: L.t("review.play"), id: "practice.review") { Task { await model.startReview(pro: purchases.hasPro) } }
                    .disabled(model.saving || model.pendingChoice != nil)
                ActionButton(title: L.t("progress.title"), id: "practice.progress") { open(.progress) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { setImportActions }
                VStack(alignment: .leading, spacing: 0) { setImportActions }
            }.font(.footnote.bold()).foregroundStyle(Theme.accent)
            Text(L.t(!queue.isEmpty ? "review.hint" : state.misses.contains(where: \.pending) ? "review.later" : "review.empty"))
                .font(.caption).foregroundStyle(Theme.muted)
            if state.misses.contains(where: \.pending) {
                Button(L.t(purchases.hasPro ? "review.schedule" : "review.title")) { open(.review) }.font(.footnote.bold()).frame(minHeight: 44)
                    .accessibilityIdentifier("practice.schedule")
            }
        }
    }
}
