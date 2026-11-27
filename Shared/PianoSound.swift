import AVFoundation
import Foundation

enum PianoSound {
    static let sampleRate = 44_100.0
    static let lead = 1_764
    static let noteLength = 25_578
    static let separation = 31_752
    static let tail = 3_528

    static func secondOnset(_ direction: Direction) -> Int { lead + (direction == .harmonic ? 0 : separation) }
    static func frameCount(_ direction: Direction) -> Int { secondOnset(direction) + noteLength + tail }

    static func buffer(_ question: Question) throws -> AVAudioPCMBuffer {
        let frames = frameCount(question.direction)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { throw Failure.unavailable }
        buffer.frameLength = AVAudioFrameCount(frames)
        channel.update(repeating: 0, count: frames)
        let gain = question.direction == .harmonic ? (question.first == question.second ? 0.5 : 0.707) : 1
        synthesize(midi: question.first, at: lead, gain: gain, into: channel)
        synthesize(midi: question.second, at: secondOnset(question.direction), gain: gain, into: channel)
        return buffer
    }

    private static func synthesize(midi: Int, at start: Int, gain: Double, into channel: UnsafeMutablePointer<Float>) {
        let fundamental = Notes.frequency(midi)
        let partials = [1.0, 0.38, 0.20, 0.10, 0.045, 0.02]
        let steps = partials.indices.map { index -> Double in
            let harmonic = Double(index + 1)
            return 2 * .pi * fundamental * harmonic * sqrt((1 + 0.00018 * harmonic * harmonic) / 1.00018) / sampleRate
        }
        for frame in 0..<noteLength {
            let time = Double(frame) / sampleRate
            let attack = min(1, time / 0.008)
            let release = min(1, Double(noteLength - 1 - frame) / (sampleRate * 0.075))
            var value = 0.0
            for index in partials.indices {
                value += partials[index] * exp(-(3.8 + Double(index) * 2.7) * time) * sin(steps[index] * Double(frame))
            }
            channel[start + frame] += Float(value * attack * release * 0.24 * gain)
        }
    }

    enum Failure: Error { case unavailable }
}
