import SwiftUI
import UIKit

struct ExportRequest: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ActivityShare: UIViewControllerRepresentable {
    let items: [Any]
    let completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            Task { @MainActor in completion(completed && error == nil) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum ShareKind {
    case challenge(Question), milestone(Int)
}

private struct ListeningCard: View {
    let kind: ShareKind
    let showCount: Bool
    let answer: Bool
    let qr: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(L.t("app.title")).font(.system(size: 13, weight: .heavy)).tracking(2).foregroundStyle(Theme.accent)
            switch kind {
            case .challenge(let question):
                Text(L.t(answer ? "share.answer" : "share.headline")).font(.system(size: 31, weight: .heavy)).fixedSize(horizontal: false, vertical: true)
                if answer {
                    Text(Notes.interval(question.distance)).font(.system(size: 22, weight: .bold))
                    Text(L.f("answer.distance", Notes.name(question.first), Notes.name(question.second), question.distance)).font(.system(size: 14))
                } else {
                    Text(L.t("share.listen")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    ForEach(Array(question.choices.enumerated()), id: \.offset) { choice in
                        Text(verbatim: "\(choice.offset + 1). \(Notes.interval(choice.element))").font(.system(size: 15, weight: .semibold))
                    }
                }
            case .milestone(let count):
                Text(showCount ? L.f("milestone.count", count) : L.t("milestone.generic"))
                    .font(.system(size: 31, weight: .heavy)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 8) {
                Text(L.t("share.tags")).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
                VStack(spacing: 4) {
                    if let qr {
                        Image(decorative: qr, scale: 1).resizable().interpolation(.none).frame(width: 58, height: 58)
                    } else {
                        Image(systemName: "qrcode").font(.system(size: 26)).frame(width: 58, height: 58)
                            .background(.white, in: .rect(cornerRadius: 8)).foregroundStyle(Theme.accent)
                    }
                    Text(L.t(qr == nil ? "share.qrPending" : "share.download")).font(.system(size: 8)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(23).frame(width: 360, height: 450, alignment: .topLeading)
        .background(Theme.tint).foregroundStyle(Theme.ink)
        .environment(\.dynamicTypeSize, .large)
    }
}

@MainActor
struct SharePreview: View {
    private enum Format { case combo, video, answer, milestone, set }

    let kind: ShareKind
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCount = true
    @State private var qr: CGImage?
    @State private var export: ExportRequest?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Page {
            ScreenHeader(title: L.t(question == nil ? "milestone.title" : "share.challenge"), subtitle: L.t("share.preview"), actionTitle: L.t("common.close")) { dismiss() }
            GeometryReader { geometry in
                let scale = min(1, geometry.size.width / 360)
                card().scaleEffect(scale, anchor: .topLeading).frame(width: geometry.size.width, alignment: .leading)
            }.aspectRatio(360.0 / 450, contentMode: .fit).frame(maxWidth: 310)
            if let question {
                AudioPreview(question: question, id: "share.listen")
                button("share.combo", id: "share.combo", format: .combo, primary: true)
                button("share.video", id: "share.video", format: .video)
                button("share.answer", id: "share.answer", format: .answer)
                button("sets.file", id: "share.set", format: .set)
                ActionButton(title: L.t("sets.copy"), id: "share.copy") {
                    if let code = try? SetCode.encode([SetPrompt(question)]) {
                        if !Launch.testing { UIPasteboard.general.string = code }
                        message = "sets.copied"
                    }
                }
            } else {
                Toggle(L.t("milestone.showCount"), isOn: $showCount).accessibilityIdentifier("milestone.count")
                button("milestone.share", id: "milestone.share", format: .milestone, primary: true)
            }
            if let message { Text(L.t(message)).font(.footnote).accessibilityIdentifier(message) }
        }
        .task {
            if let storeURL { qr = await Task.detached { DownloadCode.image(storeURL) }.value }
        }
        .sheet(item: $export) { request in
            ActivityShare(items: request.items) { success in
                export = nil
                if success { model.markSuccessfulExport() }
            }
        }
    }

    private var storeURL: String? {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? ""
        return DownloadCode.url(storeID: identifier)
    }

    private var question: Question? { if case .challenge(let question) = kind { return question }; return nil }

    private func card(answer: Bool = false) -> ListeningCard { ListeningCard(kind: kind, showCount: showCount, answer: answer, qr: qr) }

    private func button(_ title: String, id: String, format: Format, primary: Bool = false) -> some View {
        ActionButton(title: L.t(title), id: id, primary: primary) { prepare(format) }.disabled(busy)
    }

    private func prepare(_ format: Format) {
        guard !busy else { return }
        model.stop(id: "share.listen")
        busy = true; message = nil
        if format == .set, let question {
            Task {
                defer { busy = false }
                do { finish([try await Task.detached { try ShareFiles.setFile([SetPrompt(question)]) }.value]) }
                catch { message = "share.error" }
            }
            return
        }
        let question = self.question
        Task {
            defer { busy = false }
            if qr == nil, let storeURL {
                qr = await Task.detached { DownloadCode.image(storeURL) }.value
                guard qr != nil else { message = "share.error"; return }
            }
            let renderer = ImageRenderer(content: card(answer: format == .answer))
            renderer.scale = 3
            renderer.isOpaque = true
            guard let cgImage = renderer.cgImage else { message = "share.error"; return }
            do {
                let files = try await Task.detached { () -> [URL] in
                    let directory = try ShareFiles.directory()
                    if format == .video, let question {
                        let audio = try ShareFiles.audio(question, folder: directory)
                        return [try await ShareFiles.video(card: cgImage, audio: audio, folder: directory)]
                    }
                    let png = directory.appendingPathComponent(format == .answer ? "twonote-answer.png" : format == .milestone ? "twonote-milestone.png" : "twonote-challenge.png")
                    try ShareFiles.png(cgImage, to: png)
                    if format == .combo, let question { return [png, try ShareFiles.audio(question, folder: directory)] }
                    return [png]
                }.value
                var items: [Any] = files.map { $0 as Any }
                if format == .combo || format == .video { items.append(L.t("share.caption")) }
                if format == .milestone { items.append(L.t("share.tags")) }
                finish(items)
            } catch { message = "share.error" }
        }
    }

    private func finish(_ items: [Any]) {
        if Launch.testing { message = "share.requested" }
        else { export = ExportRequest(items: items) }
    }
}
