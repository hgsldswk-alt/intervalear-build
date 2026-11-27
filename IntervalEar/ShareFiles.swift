import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ShareFiles {
    static func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "TwoNoteExports", directoryHint: .isDirectory)
        if let old = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for item in old {
                if let date = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date.timeIntervalSinceNow < -86_400 { try? FileManager.default.removeItem(at: item) }
            }
        }
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func setFile(_ prompts: [SetPrompt]) throws -> URL {
        let url = try directory().appendingPathComponent("twonote-set.intervalset")
        try SetCode.encode(prompts).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func png(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.encoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
    }

    static func audio(_ question: Question, folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("twonote-listen.m4a")
        let buffer = try PianoSound.buffer(question)
        let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: PianoSound.sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try output.write(from: buffer)
        return url
    }

    static func video(card: CGImage, audio: URL, folder: URL) async throws -> URL {
        let inputAudio = AVURLAsset(url: audio)
        let duration = try await inputAudio.load(.duration)
        let silent = folder.appendingPathComponent("visual.mp4")
        let final = folder.appendingPathComponent("twonote-challenge.mp4")
        try await stillVideo(card, duration: duration, to: silent)
        let video = AVURLAsset(url: silent)
        let composition = AVMutableComposition()
        guard let sourceVideo = try await video.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await inputAudio.loadTracks(withMediaType: .audio).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Failure.encoding }
        let videoRange = try await sourceVideo.load(.timeRange)
        let audioRange = try await sourceAudio.load(.timeRange)
        try videoTrack.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw Failure.encoding }
        export.outputURL = final
        export.outputFileType = .mp4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else { throw Failure.encoding }
        try? FileManager.default.removeItem(at: silent)
        return final
    }

    private static func stillVideo(_ card: CGImage, duration: CMTime, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: card.width, AVVideoHeightKey: card.height])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: card.width, kCVPixelBufferHeightKey as String: card.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw Failure.encoding }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.encoding }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        guard let pool = adapter.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
              let pixel else { writer.cancelWriting(); throw Failure.encoding }
        CVPixelBufferLockBaseAddress(pixel, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: card.width, height: card.height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        context?.draw(card, in: CGRect(x: 0, y: 0, width: CGFloat(card.width), height: CGFloat(card.height)))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard context != nil, duration.seconds.isFinite, duration.seconds > 0 else { writer.cancelWriting(); throw Failure.encoding }
        let frames = Int(ceil(duration.seconds * 24))
        var frame = 0
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while frame < frames {
            guard writer.status == .writing, !Task.isCancelled, clock.now < deadline else { writer.cancelWriting(); throw Failure.encoding }
            if !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(8)); continue }
            guard adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else {
                writer.cancelWriting(); throw Failure.encoding
            }
            frame += 1
        }
        writer.endSession(atSourceTime: duration)
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw Failure.encoding }
    }

    enum Failure: Error { case encoding }
}
