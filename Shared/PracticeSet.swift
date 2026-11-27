import CryptoKit
import Foundation

struct SetPrompt: Codable, Equatable, Sendable {
    var direction: Direction
    var first: Int
    var second: Int
    var choices: [Int]

    init(_ question: Question) {
        direction = question.direction
        first = question.first
        second = question.second
        choices = question.choices
    }

    var valid: Bool {
        guard Notes.range.contains(first), Notes.range.contains(second) else { return false }
        return (direction == .descending ? first >= second : first <= second) &&
            choices.count == 4 && Set(choices).count == 4 && choices.allSatisfy { (0...12).contains($0) } && choices.contains(abs(second - first))
    }

    func question() -> Question {
        Question(id: UUID(), direction: direction, first: first, second: second, choices: choices, seed: 0)
    }
}

struct PracticeSet: Codable, Identifiable, Sendable {
    enum Origin: String, Codable, Sendable { case created, imported }
    let id: UUID
    let prompts: [SetPrompt]
    let origin: Origin
    let digest: String
}

enum SetCode {
    static let prefix = "IE1:"
    static let limit = 8_192
    static let maxPrompts = 20

    static func encode(_ prompts: [SetPrompt]) throws -> String {
        let bytes = try payload(prompts)
        return prefix + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ input: String) throws -> [SetPrompt] {
        guard input.utf8.count <= limit else { throw Failure.invalid }
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix(prefix) else { throw Failure.invalid }
        let encoded = code.dropFirst(prefix.count)
        guard !encoded.isEmpty, encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw Failure.invalid }
        let base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
              let objects = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
              (1...maxPrompts).contains(objects.count),
              objects.allSatisfy({ Set($0.keys) == ["direction", "first", "second", "choices"] }) else { throw Failure.invalid }
        let prompts = try JSONDecoder().decode([SetPrompt].self, from: bytes)
        guard prompts.allSatisfy(\.valid) else { throw Failure.invalid }
        return prompts
    }

    static func make(_ prompts: [SetPrompt], origin: PracticeSet.Origin) throws -> PracticeSet {
        let digest = SHA256.hash(data: try payload(prompts)).map { String(format: "%02x", $0) }.joined()
        return PracticeSet(id: UUID(), prompts: prompts, origin: origin, digest: digest)
    }

    static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: limit + 1), bytes.count <= limit,
              let text = String(data: bytes, encoding: .utf8) else { throw Failure.invalid }
        return text
    }

    private static func payload(_ prompts: [SetPrompt]) throws -> Data {
        guard (1...maxPrompts).contains(prompts.count), prompts.allSatisfy(\.valid) else { throw Failure.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(prompts)
    }

    enum Failure: Error { case invalid }
}
