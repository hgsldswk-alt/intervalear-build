import Foundation
import AVFoundation
import CoreImage
import XCTest

final class TrainingTests: XCTestCase {
    func testFrequencyAndEveryLocalizedInterval() {
        XCTAssertEqual(Notes.frequency(69), 440, accuracy: 0.0001)
        XCTAssertEqual(Notes.frequency(81), 880, accuracy: 0.0001)
        XCTAssertEqual(Notes.name(60), "C4")
        for distance in 0...12 {
            XCTAssertNotEqual(Notes.interval(distance), "interval.\(distance)")
            XCTAssertEqual(Notes.frequency(60 + distance) / Notes.frequency(60), pow(2, Double(distance) / 12), accuracy: 0.0001)
        }
    }

    func testReproducibleRoundsWithSpreadAndBounds() {
        for direction in Direction.allCases {
            let drill = Drill(direction: direction, intervals: Array(0...12), low: 52, high: 74)
            var distances: Set<Int> = []
            var slots: Set<Int> = []
            var roots: Set<Int> = []
            for seed in 0..<100 {
                let values = Generator.questions(seed: UInt64(seed), drill: drill, previousRoot: 60)
                XCTAssertEqual(values, Generator.questions(seed: UInt64(seed), drill: drill, previousRoot: 60))
                XCTAssertEqual(Set(values.map(\.id)).count, 5)
                for (index, question) in values.enumerated() {
                    XCTAssertTrue((52...74).contains(question.first) && (52...74).contains(question.second))
                    XCTAssertEqual(question.direction, direction)
                    XCTAssertTrue(direction == .descending ? question.first >= question.second : question.first <= question.second)
                    XCTAssertNotEqual(question.first, index == 0 ? 60 : values[index - 1].first)
                    XCTAssertEqual(Set(question.choices).count, 4)
                    let slot = question.choices.firstIndex(of: question.distance)!
                    if index > 0 { XCTAssertNotEqual(slot, values[index - 1].choices.firstIndex(of: values[index - 1].distance)) }
                    roots.insert(question.first); distances.insert(question.distance); slots.insert(slot)
                }
            }
            XCTAssertEqual(distances.count, 13)
            XCTAssertEqual(slots.count, 4)
            XCTAssertGreaterThan(roots.count, 15)
        }
        let base = Generator.questions(seed: 4, drill: .basic)
        XCTAssertEqual(Set(base.map(\.distance)), Set(Notes.basic))
    }

    func testPCMReplaySameFramesAndOnset() throws {
        let first = Question(id: UUID(), direction: .ascending, first: 60, second: 67, choices: Notes.basic, seed: 1)
        let harmonic = Question(id: UUID(), direction: .harmonic, first: 60, second: 67, choices: Notes.basic, seed: 1)
        let original = try PianoSound.buffer(first)
        let replay = try PianoSound.buffer(first)
        let chord = try PianoSound.buffer(harmonic)
        let samples = UnsafeBufferPointer(start: original.floatChannelData![0], count: Int(original.frameLength))
        XCTAssertTrue(samples.elementsEqual(UnsafeBufferPointer(start: replay.floatChannelData![0], count: Int(replay.frameLength))))
        XCTAssertTrue(samples[0..<PianoSound.lead].allSatisfy { $0 == 0 })
        XCTAssertTrue(samples[(PianoSound.lead + PianoSound.noteLength)..<PianoSound.secondOnset(.ascending)].allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(abs(samples[PianoSound.secondOnset(.ascending) + 31]), 0.001)
        XCTAssertEqual(PianoSound.secondOnset(.harmonic), PianoSound.lead)
        XCTAssertNotEqual(chord.floatChannelData![0][PianoSound.lead + 31], samples[PianoSound.lead + 31])
        XCTAssertLessThan(samples.map { abs($0) }.max()!, 1)
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testSettlementDoesNotDuplicateAndReviewIsSeparate() {
        var state = Training()
        let question = state.round.question
        let wrong = question.choices.first { $0 != question.distance }!
        XCTAssertFalse(state.settle(99, day: "2026-11-21"))
        XCTAssertTrue(state.settle(wrong, day: "2026-11-21"))
        XCTAssertFalse(state.settle(wrong, day: "2026-11-21"))
        XCTAssertEqual(state.misses.count, 1)
        state.reviewing = true
        state.review = Round(questions: [question])
        XCTAssertTrue(state.settle(question.distance, day: "2026-11-22"))
        XCTAssertFalse(state.misses[0].pending)
        let stats = ProgressSummary(state.attempts)
        XCTAssertEqual(stats.first.count, 1)
        XCTAssertFalse(stats.first[0].correct)
        XCTAssertEqual(stats.reviews.count, 1)
        XCTAssertTrue(stats.reviews[0].correct)
        XCTAssertEqual(state.firstCount, 1)
    }

    func testCalendarSchedulingAndTimeZones() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(LocalDay.key(date, zone: TimeZone(secondsFromGMT: 9 * 3600)!), "1970-01-01")
        XCTAssertEqual(LocalDay.key(date, zone: TimeZone(secondsFromGMT: -8 * 3600)!), "1969-12-31")
        XCTAssertEqual(LocalDay.shift("2024-02-28", by: 1), "2024-02-29")
        XCTAssertEqual(LocalDay.shift("2026-12-31", by: 1), "2027-01-01")
        var item = ReviewItem(question: Training().round.question, due: "2026-11-21")
        item.answer(correct: true, advanced: true, day: "2026-11-21")
        XCTAssertEqual(item.due, "2026-11-22")
        item.answer(correct: true, advanced: true, day: "2026-11-22")
        XCTAssertEqual(item.due, "2026-11-25")
        item.answer(correct: true, advanced: true, day: "2026-11-25")
        XCTAssertEqual(item.due, "2026-12-02")
        item.answer(correct: true, advanced: true, day: "2026-12-02")
        XCTAssertFalse(item.pending)
        item.answer(correct: false, advanced: true, day: "2026-12-03")
        XCTAssertEqual(item.stage, 0)
        XCTAssertEqual(item.due, "2026-12-03")
        XCTAssertTrue(item.pending)
    }

    func testTrialAndPurchaseRestoration() {
        let first = Date(timeIntervalSince1970: 1_760_000_000)
        var state = Entitlement(firstOpen: first)
        XCTAssertTrue(state.hasPro(at: first, free: false))
        let end = first.addingTimeInterval(30 * 86_400)
        XCTAssertTrue(state.hasPro(at: end.addingTimeInterval(-1), free: false))
        XCTAssertFalse(state.hasPro(at: end, free: false))
        state.reconcile(pro: false, trial: first.addingTimeInterval(86_400))
        XCTAssertEqual(state.trialEnd, end)
        state.reconcile(pro: true, trial: first.addingTimeInterval(-86_400))
        XCTAssertTrue(state.hasPro(at: end, free: false))
        XCTAssertEqual(state.trialEnd, end.addingTimeInterval(-86_400))
        state.reconcile(pro: false, trial: nil)
        XCTAssertFalse(state.hasPro(at: end, free: false))
        XCTAssertEqual(state.trialEnd, end.addingTimeInterval(-86_400))
        let migrated = Entitlement(firstOpen: first, proStartedAt: first.addingTimeInterval(3600))
        XCTAssertEqual(migrated.trialStart, first.addingTimeInterval(3600))
    }

    func testOnlyTrialDistributionOffersInAppPurchases() {
        XCTAssertFalse(Launch.Distribution.freeDownload.hasInAppPurchases)
        XCTAssertFalse(Launch.Distribution.paidDownload.hasInAppPurchases)
        XCTAssertTrue(Launch.Distribution.trialWithInAppPurchase.hasInAppPurchases)
    }

    func testCodeAllowListAndStableDigest() throws {
        let prompts = Generator.questions(seed: 81, drill: .basic).map(SetPrompt.init)
        let code = try SetCode.encode(prompts)
        XCTAssertTrue(code.hasPrefix("IE1:"))
        XCTAssertEqual(try SetCode.decode("\n\(code)\n"), prompts)
        XCTAssertEqual(try SetCode.make(prompts, origin: .created).digest, try SetCode.make(prompts, origin: .imported).digest)
        XCTAssertThrowsError(try SetCode.decode(String(repeating: "A", count: 9_000)))
        for invalid in [
            "[{\"direction\":\"sideways\",\"first\":60,\"second\":62,\"choices\":[2,4,5,7]}]",
            "[{\"direction\":\"ascending\",\"first\":-7,\"second\":62,\"choices\":[2,4,5,7]}]",
            "[{\"direction\":\"ascending\",\"first\":60,\"second\":62,\"choices\":[3,4,5,7]}]",
            "[{\"direction\":\"ascending\",\"first\":60,\"second\":62,\"choices\":[2,4,5,7],\"name\":\"private\"}]"
        ] {
            let encoded = Data(invalid.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            XCTAssertThrowsError(try SetCode.decode("IE1:" + encoded))
        }
    }

    func testDatabaseReloadAndDuplicateRollback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("db.sqlite")
        let store = TrainingStore(url: url)
        var state = Training()
        let question = state.round.question
        XCTAssertTrue(state.settle(question.choices.first { $0 != question.distance }!, day: "2026-11-21"))
        try await store.save(state, adding: state.attempts)
        var mutated = state
        mutated.practice.choice = nil
        do { try await store.save(mutated, adding: mutated.attempts); XCTFail("Duplicate settlement must roll back") }
        catch TrainingStore.Failure.database {}
        let result = try await TrainingStore(url: url).load()
        let restored = try XCTUnwrap(result)
        XCTAssertEqual(restored.round.question, question)
        XCTAssertEqual(restored.round.choice, state.round.choice)
        XCTAssertEqual(restored.attempts.count, 1)
        XCTAssertEqual(restored.misses.count, 1)
    }

    func testMilestoneAndRatingCountDistinctFirstAnswers() {
        var state = Training()
        for round in 0..<5 {
            state.practice = Round(questions: Generator.questions(seed: UInt64(round), drill: .basic))
            for index in 0..<5 {
                state.practice.index = index
                state.practice.choice = nil
                XCTAssertTrue(state.settle(state.round.question.distance, day: LocalDay.shift("2026-11-21", by: -round % 3)))
            }
        }
        XCTAssertEqual(state.milestone, 25)
        XCTAssertTrue(state.canRequestRating)
        state.dismissedMilestone = 25
        state.ratingRequested = true
        XCTAssertNil(state.milestone)
        XCTAssertFalse(state.canRequestRating)
    }

    func testDownloadQRRoundTripWithCIDetector() throws {
        XCTAssertNil(DownloadCode.url(storeID: ""))
        let url = try XCTUnwrap(DownloadCode.url(storeID: "1234567890"))
        let image = try XCTUnwrap(DownloadCode.image(url))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let result = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertTrue(result.contains(url))
    }

    func testSharedAudioIsLocalAndHasQuestionDuration() throws {
        let folder = try ShareFiles.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let question = Question(id: UUID(), direction: .ascending, first: 60, second: 67, choices: Notes.basic, seed: 1)
        let url = try ShareFiles.audio(question, folder: folder)
        XCTAssertEqual(url.lastPathComponent, "twonote-listen.m4a")
        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.processingFormat.channelCount, 1)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        XCTAssertEqual(duration, Double(PianoSound.frameCount(.ascending)) / PianoSound.sampleRate, accuracy: 0.1)
    }
}
