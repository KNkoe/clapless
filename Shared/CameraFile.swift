import AVFoundation
import Foundation

/// Turns the phone's verified segments into an ordinary `camera.mov`.
/// Nothing is re-encoded: every compressed picture and sound sample is copied as it is. Only the
/// timestamps move, so the file starts at zero instead of at the phone's uptime clock.
enum CameraFile {
    struct Result: Equatable {
        var seconds: Double
        var videoSamples: Int
        var audioStart: Double?     // seconds after the first picture
    }

    enum Problem: Error, LocalizedError {
        case noPicture
        case export(String)
        case samplesDiffer(Int, Int)

        var errorDescription: String? {
            switch self {
            case .noPicture: return "The take has no picture"
            case .export(let why): return "camera.mov could not be written: \(why)"
            case .samplesDiffer(let a, let b): return "camera.mov has \(b) pictures but the phone's file has \(a)"
            }
        }
    }

    /// `joined` is the checked fragmented MP4. `output` appears only when it has been checked too.
    /// `audioOffset` is the manifest's: AVFoundation reads each segmented track as if it began at
    /// zero, so without it the sound would slide up to a few hundredths of a second early.
    static func make(from joined: URL, to output: URL, audioOffset: Double?) async throws -> Result {
        let source = AVURLAsset(url: joined, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await source.loadTracks(withMediaType: .video).first else { throw Problem.noPicture }
        let videoRange = try await video.load(.timeRange)
        let composition = AVMutableComposition()
        var audioStart: Double?

        func copy(_ track: AVAssetTrack, _ range: CMTimeRange, at: CMTime) throws {
            guard let target = composition.addMutableTrack(withMediaType: track.mediaType,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw Problem.export("no track") }
            try target.insertTimeRange(range, of: track, at: at)
        }
        try copy(video, videoRange, at: .zero)
        if let audio = try await source.loadTracks(withMediaType: .audio).first {
            let range = try await audio.load(.timeRange)
            let stated = CMTime(seconds: audioOffset ?? 0, preferredTimescale: 48_000)
            let at = CMTimeMaximum(stated, range.start - videoRange.start)
            try copy(audio, range, at: CMTimeMaximum(.zero, at))
            audioStart = at.seconds
        }

        let working = output.deletingLastPathComponent().appendingPathComponent(".writing-\(output.lastPathComponent)")
        try? FileManager.default.removeItem(at: working)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw Problem.export("no export session") }
        do {
            try await export.export(to: working, as: .mov)
        } catch {
            throw Problem.export(error.localizedDescription)
        }

        let before = try await sampleCount(joined)
        let after = try await sampleCount(working)
        guard before == after, after > 0 else {
            try? FileManager.default.removeItem(at: working)
            throw Problem.samplesDiffer(before, after)
        }
        let seconds = try await AVURLAsset(url: working).load(.duration).seconds
        if FileManager.default.fileExists(atPath: output.path) {
            throw Problem.export("\(output.lastPathComponent) already exists")
        }
        try FileManager.default.moveItem(at: working, to: output)
        return Result(seconds: seconds, videoSamples: after, audioStart: audioStart)
    }

    /// How many compressed pictures a file holds, counted by reading them.
    static func sampleCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Problem.noPicture }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Problem.noPicture }
        var count = 0
        while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        if reader.status == .failed { throw reader.error ?? Problem.noPicture }
        return count
    }
}
