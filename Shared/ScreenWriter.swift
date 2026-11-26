import AVFoundation
import VideoToolbox

/// Writes `screen.mp4` at a steady 30 frames a second. The system only hands over a picture when
/// something on screen changes, so the last picture is repeated until the next one: frame n always
/// shows what was on screen n/30 seconds after the first, which keeps it in step with the sound.
///
/// All calls must come on one queue. Times are on the Mac's host clock.
final class ScreenWriter {
    struct Result: Equatable {
        var firstFrameHostTime: Double
        var seconds: Double
        var frames: Int
        var skippedFrames: Int
        var width: Int
        var height: Int
    }

    static let fps = 30
    /// Frames are written this long after their moment, so a late picture still lands in its place.
    static let delay = 0.15

    let url: URL
    private let width: Int
    private let height: Int
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var latest: CVPixelBuffer?
    private var queued: [(buffer: CVPixelBuffer, hostTime: Double)] = []
    private(set) var firstHost: Double?
    private var next = 0
    private var written = 0
    private var skipped = 0
    private(set) var failure: String?

    init(url: URL, width: Int, height: Int) {
        self.url = url
        self.width = width
        self.height = height
    }

    /// A new picture, and the moment it appeared on screen.
    func show(_ buffer: CVPixelBuffer, at hostTime: Double) {
        guard failure == nil else { return }
        if firstHost == nil {
            guard open() else { return }
            firstHost = hostTime
            latest = buffer
            return
        }
        queued.append((buffer, hostTime))
    }

    /// Write every frame due by `now`.
    func advance(to now: Double) {
        write(upTo: now - Self.delay)
    }

    private func write(upTo time: Double) {
        guard failure == nil, let firstHost, let writer, let input, let adaptor else { return }
        while firstHost + Double(next) / Double(Self.fps) <= time {
            let moment = firstHost + Double(next) / Double(Self.fps)
            while let change = queued.first, change.hostTime <= moment + 0.001 {
                latest = change.buffer
                queued.removeFirst()
            }
            guard writer.status == .writing else {
                failure = writer.error?.localizedDescription ?? "the screen file stopped accepting pictures"
                return
            }
            if let latest, input.isReadyForMoreMediaData,
               adaptor.append(latest, withPresentationTime: CMTime(value: CMTimeValue(next), timescale: CMTimeScale(Self.fps))) {
                written += 1
            } else {
                skipped += 1
            }
            next += 1
        }
    }

    private func open() -> Bool {
        do {
            try? FileManager.default.removeItem(at: url)
            let new = try AVAssetWriter(outputURL: url, fileType: .mp4)
            new.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            let bitrate = max(8_000_000, min(40_000_000, width * height * Self.fps / 10))
            let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: Self.fps,
                    AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                ],
            ])
            track.expectsMediaDataInRealTime = true
            let feeder = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track, sourcePixelBufferAttributes: nil)
            guard new.canAdd(track) else { failure = "this screen size cannot be recorded"; return false }
            new.add(track)
            guard new.startWriting() else {
                failure = new.error?.localizedDescription ?? "the screen file could not be started"
                return false
            }
            new.startSession(atSourceTime: .zero)
            writer = new
            input = track
            adaptor = feeder
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    /// Fill up to the moment recording stopped and close the file. Nil when nothing was written.
    func finish(at stopTime: Double, completion: @escaping (Result?) -> Void) {
        write(upTo: stopTime)
        guard let writer, let input, let firstHost, writer.status == .writing, written > 0 else {
            return completion(nil)
        }
        let result = Result(firstFrameHostTime: firstHost, seconds: Double(next) / Double(Self.fps), frames: written,
                            skippedFrames: skipped, width: width, height: height)
        self.writer = nil
        queued = []
        latest = nil
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(next), timescale: CMTimeScale(Self.fps)))
        writer.finishWriting {
            completion(writer.status == .completed ? result : nil)
        }
    }
}
