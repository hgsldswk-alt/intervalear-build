import Foundation

enum Direction: String, Codable, CaseIterable, Identifiable, Sendable {
    case ascending, descending, harmonic
    var id: String { rawValue }
    var title: String { L.t("mode.\(rawValue)") }
}

enum Notes {
    static let range = 48...84
    static let basic = [2, 4, 5, 7]
    static func frequency(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }
    static func interval(_ semitones: Int) -> String { L.t("interval.\(semitones)") }
    static func name(_ midi: Int) -> String {
        let pitches = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return "\(pitches[midi % 12])\(midi / 12 - 1)"
    }
}

struct Question: Codable, Equatable, Identifiable, Sendable {
    var schema = 1
    let id: UUID
    let direction: Direction
    let first: Int
    let second: Int
    let choices: [Int]
    let seed: UInt64
    var distance: Int { abs(second - first) }
    var reviewKey: String { "\(direction.rawValue):\(first):\(second)" }
}

struct Drill: Codable, Equatable, Sendable {
    var direction = Direction.ascending
    var intervals = Notes.basic
    var low = Notes.range.lowerBound
    var high = Notes.range.upperBound
    static let basic = Drill()

    var valid: Bool {
        Notes.range.contains(low) && Notes.range.contains(high) && low < high &&
        (4...13).contains(intervals.count) && Set(intervals).count == intervals.count &&
        intervals.allSatisfy { (0...12).contains($0) && $0 < high - low }
    }
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58476d1ce4e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d049bb133111eb
        return mixed ^ (mixed >> 31)
    }
}

enum Generator {
    static func questions(seed: UInt64, drill: Drill, previousRoot: Int? = nil) -> [Question] {
        let config = drill.valid ? drill : .basic
        var random = SeededRandom(state: seed)
        var previous = previousRoot
        var previousSlot: Int?
        let intervals = config.intervals.shuffled(using: &random)
        return (0..<5).map { index in
            let distance = index < intervals.count ? intervals[index] : intervals.dropLast().randomElement(using: &random)!
            let roots = config.direction == .descending ? (config.low + distance)...config.high : config.low...(config.high - distance)
            let first = roots.filter { $0 != previous }.randomElement(using: &random)!
            previous = first
            let second = first + (config.direction == .descending ? -distance : distance)
            var choices = Array(intervals.filter { $0 != distance }.shuffled(using: &random).prefix(3))
            let slot = (0..<4).filter { $0 != previousSlot }.randomElement(using: &random)!
            choices.insert(distance, at: slot)
            previousSlot = slot
            return Question(id: identifier(using: &random), direction: config.direction, first: first, second: second, choices: choices, seed: seed)
        }
    }

    private static func identifier(using random: inout SeededRandom) -> UUID {
        let high = withUnsafeBytes(of: random.next().bigEndian) { Array($0) }
        let low = withUnsafeBytes(of: random.next().bigEndian) { Array($0) }
        let bytes = high + low
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], (bytes[6] & 15) | 64, bytes[7],
                           (bytes[8] & 63) | 128, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct Attempt: Codable, Identifiable, Sendable {
    let roundID: UUID
    let index: Int
    let question: Question
    let choice: Int
    let review: Bool
    let day: String
    var id: String { "\(roundID.uuidString):\(index)" }
    var correct: Bool { choice == question.distance }
}

struct Round: Codable, Sendable {
    var id = UUID()
    let questions: [Question]
    var index = 0
    var choice: Int?
    var advancedReview = false
    var question: Question { questions[index] }
    var last: Bool { index == questions.count - 1 }
}

struct ReviewItem: Codable, Identifiable, Sendable {
    let question: Question
    var stage = 0
    var due: String
    var pending = true
    var id: String { question.reviewKey }

    mutating func answer(correct: Bool, advanced: Bool, day: String) {
        if !correct { stage = 0; due = day; pending = true }
        else if !advanced || stage == 3 { pending = false }
        else {
            due = LocalDay.shift(day, by: [1, 3, 7][stage])
            stage += 1
        }
    }
}

enum LocalDay {
    private static func calendar(_ zone: TimeZone) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = zone
        return result
    }

    static func key(_ date: Date = Date(), zone: TimeZone = .autoupdatingCurrent) -> String {
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func shift(_ key: String, by days: Int) -> String {
        let zone = TimeZone(secondsFromGMT: 0)!
        let utc = calendar(zone)
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = utc.date(from: .init(year: parts[0], month: parts[1], day: parts[2])),
              let shifted = utc.date(byAdding: .day, value: days, to: date) else { return key }
        return self.key(shifted, zone: zone)
    }
}

struct ProgressSummary {
    let first: [Attempt]
    let reviews: [Attempt]

    init(_ attempts: [Attempt]) {
        first = attempts.filter { !$0.review }
        reviews = attempts.filter(\.review)
    }

    static func accuracy(_ attempts: [Attempt]) -> String {
        guard !attempts.isEmpty else { return "—" }
        return (Double(attempts.filter(\.correct).count) / Double(attempts.count)).formatted(.percent.precision(.fractionLength(0)))
    }
}

struct Training: Codable, Sendable {
    var practice = Round(questions: Generator.questions(seed: UInt64.random(in: .min ... .max), drill: .basic))
    var review: Round?
    var reviewing = false
    var attempts: [Attempt] = []
    var misses: [ReviewItem] = []
    var sets: [PracticeSet] = []
    var selectedSet: UUID?
    var drill = Drill.basic
    var drills: [SavedDrill] = []
    var dismissedMilestone = 0
    var ratingRequested = false
    var coreReviewProgress: CoreReviewProgress?
    var liveEnabled = false

    var round: Round { reviewing ? (review ?? practice) : practice }
    var firstCount: Int { Set(attempts.lazy.filter { !$0.review }.map { $0.question.id }).count }
    var milestone: Int? { [100, 25].first { firstCount >= $0 && dismissedMilestone < $0 } }
    var canRequestRating: Bool { !ratingRequested && firstCount >= 25 && Set(attempts.lazy.filter { !$0.review }.map(\.day)).count >= 3 }

    mutating func updateRound(_ round: Round) {
        if reviewing { review = round } else { practice = round }
    }

    mutating func settle(_ choice: Int, day: String) -> Bool {
        var current = round
        let attempt = Attempt(roundID: current.id, index: current.index, question: current.question,
                              choice: choice, review: reviewing, day: day)
        guard current.choice == nil, current.question.choices.contains(choice), !attempts.contains(where: { $0.id == attempt.id }) else { return false }
        current.choice = choice
        updateRound(current)
        attempts.append(attempt)
        if let index = misses.firstIndex(where: { $0.id == current.question.reviewKey }) {
            if reviewing || !attempt.correct { misses[index].answer(correct: attempt.correct, advanced: current.advancedReview, day: day) }
        } else if !attempt.correct {
            misses.append(ReviewItem(question: current.question, due: day))
        }
        return true
    }

    func queue(advanced: Bool, day: String, direction: Direction? = nil) -> [ReviewItem] {
        misses.filter { $0.pending && (!advanced || $0.due <= day) && (direction == nil || $0.question.direction == direction) }
            .sorted { $0.due == $1.due ? $0.id < $1.id : $0.due < $1.due }
    }
}

struct SavedDrill: Codable, Identifiable, Sendable {
    var id = UUID()
    let drill: Drill
}
