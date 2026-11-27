import SwiftUI

enum Theme {
    static let paper = Color(red: 243/255, green: 243/255, blue: 249/255)
    static let ink = Color(red: 34/255, green: 32/255, blue: 50/255)
    static let muted = Color(red: 94/255, green: 88/255, blue: 113/255)
    static let accent = Color(red: 79/255, green: 66/255, blue: 158/255)
    static let tint = Color(red: 237/255, green: 233/255, blue: 251/255)
    static let line = Color(red: 225/255, green: 222/255, blue: 235/255)
}

struct ActionButton: View {
    let title: String
    let id: String
    var icon: String? = nil
    var primary = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).accessibilityHidden(true) }
                Text(title).multilineTextAlignment(.center)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: primary ? 52 : 46)
            .foregroundStyle(primary ? .white : (enabled ? Theme.ink : Theme.muted))
            .background(primary ? Theme.accent.opacity(enabled ? 1 : 0.65) : .white, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line.opacity(primary ? 0 : 1)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct ScreenHeader: View {
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var actionID = "screen.back"
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.bold()).tracking(-1.2).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.bold()).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5).frame(minHeight: 44)
                    .accessibilityIdentifier(actionID)
            }
        }
    }
}

extension View {
    func panel(tinted: Bool = false) -> some View {
        self.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(tinted ? Theme.tint : .white, in: .rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.line))
    }

    func pageStyle() -> some View {
        self.background(Theme.paper.ignoresSafeArea()).foregroundStyle(Theme.ink).tint(Theme.accent)
    }
}

struct Page<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: 560)
                .padding(20).frame(maxWidth: .infinity)
        }
        .pageStyle()
    }
}

struct NotePair: View {
    var body: some View {
        HStack(spacing: 10) {
            chip(L.t("notes.first")); chip(L.t("notes.second"))
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func chip(_ text: String) -> some View {
        Label(text, systemImage: "minus").font(.caption.bold()).foregroundStyle(Theme.accent)
            .frame(maxWidth: 115, minHeight: 36)
            .background(.white, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

struct AnswerDetail: View {
    let question: Question
    var choice: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let choice {
                Label(L.t(choice == question.distance ? "answer.correct" : "answer.incorrect"),
                      systemImage: choice == question.distance ? "checkmark.circle" : "xmark.circle")
                    .font(.caption.weight(.heavy)).foregroundStyle(Theme.accent)
            }
            Text(Notes.interval(question.distance)).font(.title.bold()).accessibilityIdentifier("feedback.answer")
            Text(L.f("answer.distance", Notes.name(question.first), Notes.name(question.second), question.distance))
                .font(.subheadline).foregroundStyle(Theme.muted)
            HStack(spacing: 3) {
                ForEach(0...max(1, question.distance), id: \.self) { index in
                    let last = index == max(1, question.distance)
                    let endpoint = index == 0 || last
                    RoundedRectangle(cornerRadius: 5).fill(endpoint ? Theme.accent : .white)
                        .frame(height: 34)
                        .overlay {
                            if endpoint || question.distance <= 7 {
                                Text(endpoint ? Notes.name(last ? question.second : question.first) : String(index))
                                    .font(.caption2.bold()).foregroundStyle(endpoint ? .white : Theme.muted)
                                    .lineLimit(1).minimumScaleFactor(0.55)
                            }
                        }
                }
            }
            .accessibilityHidden(true)
            if let choice, choice != question.distance {
                Text(L.f("answer.chosen", Notes.interval(choice), choice)).font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .panel(tinted: true)
    }
}
