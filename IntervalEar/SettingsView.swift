import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @State private var export: ExportRequest?
    @State private var showPaywall = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Page {
                ScreenHeader(title: L.t("settings.title"), subtitle: L.t("settings.subtitle"), actionTitle: L.t("common.done")) { dismiss() }
                link("settings.drills", id: "settings.drills") { DrillLibrary() }
                link("sets.title", id: "settings.sets") { SetLibrary() }
                link("import.title", id: "settings.import") { ImportSetView(embedded: true) }
                if Launch.hasInAppPurchases {
                    ActionButton(title: L.t("purchase.title"), id: "settings.purchase") { showPaywall = true }
                }
                if let state = model.state {
                    Toggle(L.t("live.enable"), isOn: Binding(get: { state.liveEnabled }, set: { value in
                        Task { guard var next = model.state else { return }; next.liveEnabled = value; await model.commit(next, startLive: value) }
                    }))
                    .accessibilityIdentifier("settings.live")
                    .disabled(model.saving).panel()
                }
                ActionButton(title: L.t("settings.export"), id: "settings.export") { exportProgress() }
                if let message { Text(L.t(message)).accessibilityIdentifier("settings.message") }
                if let error = model.error { Text(L.t(error)).font(.footnote) }
                Text(L.t("settings.local")).font(.footnote).foregroundStyle(Theme.muted)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .sheet(item: $export) { request in
                ActivityShare(items: request.items) { successful in
                    export = nil
                    if successful { model.markSuccessfulExport() }
                }
            }
        }
    }

    private func exportProgress() {
        guard let state = model.state else { return }
        Task {
            do {
                let url = try await Task.detached {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let url = try ShareFiles.directory().appendingPathComponent("twonote-progress.json")
                    try encoder.encode(state).write(to: url, options: .atomic)
                    return url
                }.value
                if Launch.testing { message = "share.requested" }
                else { export = ExportRequest(items: [url]) }
            } catch { message = "share.error" }
        }
    }

    private func link<Destination: View>(_ title: String, id: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            HStack { Text(L.t(title)); Spacer(); Image(systemName: "chevron.right").accessibilityHidden(true) }
                .font(.subheadline.bold()).panel()
        }.accessibilityIdentifier(id)
    }
}

@MainActor
struct PaywallView: View {
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Page {
            ScreenHeader(title: L.t("purchase.title"), subtitle: L.t("purchase.subtitle"), actionTitle: L.t("common.close")) { dismiss() }
            VStack(alignment: .leading, spacing: 9) {
                Text(L.t("purchase.features")).font(.headline)
                Text(L.t("purchase.list"))
                Text(L.t("purchase.trialTerms")).font(.footnote).accessibilityIdentifier("paywall.terms")
                Text(L.t("purchase.after")).font(.footnote)
                if let state = purchases.state {
                    Text(state.purchasedPro ? L.t("purchase.owned") : purchases.trialActive ? L.f("trial.remaining", purchases.daysLeft) : L.t("trial.ended"))
                        .font(.subheadline.bold())
                }
            }.panel(tinted: true)
            if let pro = purchases.pro {
                ActionButton(title: L.f("purchase.buy", pro.displayPrice), id: "purchase.buy", primary: true) {
                    Task { await purchases.buy(pro) }
                }.disabled(purchases.busy || purchases.state?.purchasedPro == true)
            } else if Launch.testing {
                ActionButton(title: L.f("purchase.buy", 1.99.formatted(.currency(code: "USD"))), id: "purchase.buy", primary: true) {}.disabled(true)
            } else {
                Text(L.t("trial.priceUnavailable")).font(.footnote)
                ActionButton(title: L.t("purchase.reload"), id: "purchase.reload") { Task { await purchases.loadProducts() } }
            }
            if let trial = purchases.trial {
                ActionButton(title: L.t("purchase.claim"), id: "purchase.claim") { Task { await purchases.buy(trial) } }
                    .disabled(purchases.busy || !purchases.trialActive || purchases.state?.trialClaimedAt != nil)
            } else if Launch.testing {
                ActionButton(title: L.t("purchase.claim"), id: "purchase.claim") {}.disabled(true)
            }
            ActionButton(title: L.t("purchase.restore"), id: "purchase.restore") { Task { await purchases.restore() } }.disabled(purchases.busy)
            if purchases.busy { ProgressView() }
            if let message = purchases.message { Text(L.t(message)).font(.footnote) }
        }
    }
}

@MainActor
struct DrillLibrary: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @State private var showPaywall = false

    var body: some View {
        Page {
            Text(L.t("settings.drills")).font(.largeTitle.bold())
            ActionButton(title: L.t("drill.basic"), id: "drills.basic") {
                NotificationCenter.default.post(name: .beginDrill, object: Drill.basic)
            }.disabled(model.saving)
            if purchases.hasPro {
                NavigationLink(L.t("drill.new")) { DrillEditor(pack: false) }
                    .accessibilityIdentifier("drills.new").padding(.vertical, 10)
                ForEach(model.state?.drills ?? []) { saved in
                    ActionButton(title: drillLabel(saved.drill), id: "drills.saved.\(saved.id)") {
                        NotificationCenter.default.post(name: .beginDrill, object: saved.drill)
                    }.disabled(model.saving)
                }
            } else {
                ActionButton(title: L.t("purchase.features"), id: "drills.unlock") { showPaywall = true }
            }
        }
        .navigationTitle(L.t("settings.drills")).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    private func drillLabel(_ drill: Drill) -> String {
        L.f("drill.saved", drill.direction.title, drill.intervals.count, Notes.name(drill.low), Notes.name(drill.high))
    }
}

@MainActor
struct DrillEditor: View {
    let pack: Bool
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @State private var drill = Drill()
    @State private var count = 5
    @State private var previews: [SetPrompt] = []
    @State private var paywall = false

    var body: some View {
        Page {
            Text(L.t(pack ? "sets.new" : "drill.new")).font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 12) {
                Picker(L.t("drill.mode"), selection: $drill.direction) {
                    ForEach(Direction.allCases) { direction in Text(direction.title).tag(direction) }
                }.accessibilityIdentifier("drill.mode")
                Stepper(L.f("drill.low", Notes.name(drill.low)), value: $drill.low, in: Notes.range).accessibilityIdentifier("drill.low")
                Stepper(L.f("drill.high", Notes.name(drill.high)), value: $drill.high, in: Notes.range).accessibilityIdentifier("drill.high")
                if pack { Stepper(L.f("sets.count", count), value: $count, in: 1...20).accessibilityIdentifier("sets.count") }
                ForEach(0...12, id: \.self) { interval in
                    Toggle(Notes.interval(interval), isOn: Binding(get: { drill.intervals.contains(interval) }, set: { enabled in
                        if enabled { drill.intervals.append(interval); drill.intervals.sort() }
                        else { drill.intervals.removeAll { $0 == interval } }
                    })).accessibilityIdentifier("drill.interval.\(interval)")
                }
            }.panel()
            if !drill.valid { Text(L.t("drill.invalid")).font(.footnote) }
            if pack {
                ActionButton(title: L.t("import.preview"), id: "sets.preview") { previews = makePrompts() }.disabled(!drill.valid)
                if !previews.isEmpty {
                    SetSummary(prompts: previews)
                    ForEach(previews.indices, id: \.self) { index in
                        EditSetPrompt(prompt: $previews[index], index: index)
                    }
                }
            }
            ActionButton(title: L.t("common.save"), id: "drill.save", primary: true) { save() }
                .disabled(!drill.valid || !previews.allSatisfy(\.valid) || model.saving)
            if let error = model.error { Text(L.t(error)).font(.footnote) }
        }
        .onChange(of: drill) { _, _ in previews = [] }
        .onChange(of: count) { _, _ in previews = [] }
        .sheet(isPresented: $paywall) { PaywallView() }
    }

    private func makePrompts() -> [SetPrompt] {
        var questions: [Question] = []
        while questions.count < count {
            questions += Generator.questions(seed: UInt64.random(in: .min ... .max), drill: drill, previousRoot: questions.last?.first)
        }
        return questions.prefix(count).map(SetPrompt.init)
    }

    private func save() {
        guard purchases.hasPro else { paywall = true; return }
        if !pack {
            NotificationCenter.default.post(name: .beginDrill, object: drill)
            return
        }
        let prompts = previews.isEmpty ? makePrompts() : previews
        guard var next = model.state, let set = try? SetCode.make(prompts, origin: .created) else { return }
        next.sets.append(set)
        Task { if await model.commit(next) { dismiss() } }
    }
}

private struct EditSetPrompt: View {
    @Binding var prompt: SetPrompt
    let index: Int

    var body: some View {
        DisclosureGroup(L.f("sets.prompt", index + 1)) {
            Picker(L.t("drill.mode"), selection: $prompt.direction) {
                ForEach(Direction.allCases) { direction in Text(direction.title).tag(direction) }
            }.accessibilityIdentifier("set.prompt.\(index).direction")
            Stepper(L.f("sets.note", L.t("notes.first"), Notes.name(prompt.first)), value: $prompt.first, in: Notes.range)
                .accessibilityIdentifier("set.prompt.\(index).first")
            Stepper(L.f("sets.note", L.t("notes.second"), Notes.name(prompt.second)), value: $prompt.second, in: Notes.range)
                .accessibilityIdentifier("set.prompt.\(index).second")
            ForEach(prompt.choices.indices, id: \.self) { slot in
                Picker(L.f("sets.option", slot + 1), selection: $prompt.choices[slot]) {
                    ForEach(0...12, id: \.self) { interval in Text(Notes.interval(interval)).tag(interval) }
                }.accessibilityIdentifier("set.prompt.\(index).option.\(slot)")
            }
        }
        .panel()
        if !prompt.valid { Text(L.t("sets.invalidPrompt")).font(.footnote) }
    }
}

extension Notification.Name {
    static let beginDrill = Notification.Name("TwoNote.beginDrill")
    static let beginSet = Notification.Name("TwoNote.beginSet")
    static let beginReview = Notification.Name("TwoNote.beginReview")
}

@MainActor
struct SetSummary: View {
    let prompts: [SetPrompt]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L.f("sets.count", prompts.count)).font(.headline)
            Text(Direction.allCases.filter { direction in prompts.contains { $0.direction == direction } }.map(\.title).joined(separator: " · "))
        }.panel(tinted: true)
    }
}

@MainActor
struct SetLibrary: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @State private var paywall = false

    var body: some View {
        Page {
            if purchases.hasPro {
                NavigationLink(L.t("sets.new")) { DrillEditor(pack: true) }.accessibilityIdentifier("sets.new").padding(.vertical, 10)
            } else { ActionButton(title: L.t("sets.new"), id: "sets.new") { paywall = true } }
            NavigationLink(L.t("import.title")) { ImportSetView(initialText: "", embedded: true) }.accessibilityIdentifier("sets.import").padding(.vertical, 10)
            if model.state?.sets.isEmpty != false { Text(L.t("sets.empty")).font(.footnote) }
            ForEach(model.state?.sets ?? []) { set in
                NavigationLink { SetDetail(set: set) } label: {
                    SetSummary(prompts: set.prompts)
                }.buttonStyle(.plain).accessibilityIdentifier("sets.entry")
            }
        }
        .navigationTitle(L.t("sets.title")).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $paywall) { PaywallView() }
    }
}

@MainActor
struct SetDetail: View {
    let set: PracticeSet
    @EnvironmentObject private var model: AppModel
    @State private var share: ExportRequest?
    @State private var message: String?

    var body: some View {
        Page {
            SetSummary(prompts: set.prompts)
            ActionButton(title: L.t("sets.practice"), id: "sets.practice", primary: true) {
                NotificationCenter.default.post(name: .beginSet, object: set)
            }.disabled(model.saving)
            ActionButton(title: L.t("sets.copy"), id: "sets.copy") {
                if let code = try? SetCode.encode(set.prompts) {
                    if !Launch.testing { UIPasteboard.general.string = code }
                    message = "sets.copied"
                }
            }
            ActionButton(title: L.t("sets.file"), id: "sets.file") {
                let prompts = set.prompts
                Task {
                    do {
                        let url = try await Task.detached { try ShareFiles.setFile(prompts) }.value
                        if Launch.testing { message = "share.requested" }
                        else { share = ExportRequest(items: [url]) }
                    } catch { message = "share.error" }
                }
            }
            if let message { Text(L.t(message)).accessibilityIdentifier(message) }
        }
        .navigationTitle(L.t("sets.title")).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { request in
            ActivityShare(items: request.items) { success in share = nil; if success { model.markSuccessfulExport() } }
        }
    }
}

@MainActor
struct ImportSetView: View {
    static let type = UTType(exportedAs: "com.hgsldswk.intervalear.set", conformingTo: .plainText)
    var initialText = ""
    var embedded = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    @State private var text = ""
    @State private var prompts: [SetPrompt] = []
    @State private var previewSource: String?
    @State private var file = false
    @State private var message: String?

    var body: some View {
        Page {
            if !embedded { ScreenHeader(title: L.t("import.title"), subtitle: L.t("import.subtitle"), actionTitle: L.t("common.close")) { dismiss() } }
            else { Text(L.t("import.subtitle")).font(.headline) }
            TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 100).focused($editing)
                .accessibilityLabel(L.t("import.code")).accessibilityIdentifier("import.code")
            if Launch.testing, let preset = ProcessInfo.processInfo.environment["INTERVALEAR_TEST_SET"] {
                Button(L.t("import.paste")) { paste(preset) }.accessibilityIdentifier("import.paste")
            } else {
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first { paste(value) }
                }.accessibilityLabel(Text(L.t("import.paste"))).accessibilityIdentifier("import.paste")
            }
            ActionButton(title: L.t("import.file"), id: "import.file") { editing = false; file = true }
            ActionButton(title: L.t("import.preview"), id: "import.preview") { editing = false; decode(text) }.disabled(text.isEmpty)
            if previewSource == text && !prompts.isEmpty {
                SetSummary(prompts: prompts)
                ActionButton(title: L.t("import.save"), id: "import.save", primary: true) { save() }.disabled(model.saving)
            }
            if let message { Text(L.t(message)).accessibilityIdentifier("import.message") }
            if let error = model.error { Text(L.t(error)).font(.footnote) }
        }
        .navigationTitle(L.t("import.title")).navigationBarTitleDisplayMode(.inline)
        .toolbar(embedded ? .visible : .hidden, for: .navigationBar)
        .onAppear { if text.isEmpty && !initialText.isEmpty { paste(initialText) } }
        .fileImporter(isPresented: $file, allowedContentTypes: [Self.type, .plainText]) { result in
            Task {
                do {
                    let url = try result.get()
                    let source = try await Task.detached { try SetCode.read(url) }.value
                    paste(source)
                } catch { message = "import.invalid" }
            }
        }
    }

    private func paste(_ source: String) {
        editing = false
        text = source
        decode(source)
    }

    private func decode(_ source: String) {
        previewSource = source
        do { prompts = try SetCode.decode(source); message = nil }
        catch { prompts = []; message = "import.invalid" }
    }

    private func save() {
        guard var next = model.state, let set = try? SetCode.make(prompts, origin: .imported) else { return }
        guard !next.sets.contains(where: { $0.digest == set.digest }) else { message = "import.duplicate"; return }
        next.sets.append(set)
        Task { if await model.commit(next) { prompts = []; message = "import.saved" } }
    }
}
