import AVFoundation
import UniformTypeIdentifiers
import VideoToolbox

/// Writes one take as a run of short segments, each saved to disk the moment it is finished.
/// Joined in order they are one ordinary fragmented MP4, so the Mac can copy them while the take
/// is still running and a crash loses at most the last couple of seconds.
///
/// `append` must be called on one queue (the camera's data queue). `onManifest` arrives on any queue.
// Thread safety is by hand: writing happens on the camera data queue, shared state behind `lock`.
final class TakeRecorder: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    static let segmentSeconds = 2.0

    let directory: TakeDirectory
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private var startPTS: CMTime?
    private var lastPTS = CMTime.zero
    private var finishing = false

    private let lock = NSLock()
    private var manifest: TakeManifest
    private var joinedHash = RunningHash()
    private var failure: String?

    var onManifest: ((TakeManifest) -> Void)?
    /// Converts a frame's timestamp to the device's host clock, which is what the Mac can compare with.
    var hostTime: (CMTime) -> Double = { $0.seconds }

    var current: TakeManifest { lock.withLock { manifest } }

    init(directory: TakeDirectory, takeID: String, camera: CameraSettings) throws {
        self.directory = directory
        try directory.create()
        manifest = TakeManifest(takeID: takeID, created: Date(), complete: false, segments: [], sha256: nil, seconds: 0,
                                frames: 0, droppedFrames: 0, firstFrameHostTime: nil, audioStartOffset: nil,
                                endReason: nil, camera: camera,
                                verifiedByMac: false)
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: Self.segmentSeconds, preferredTimescale: 600)

        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: camera.width,
            AVVideoHeightKey: camera.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: camera.bitrate,
                AVVideoExpectedSourceFrameRateKey: camera.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                // Reordered frames shift the picture two frames late against the sound in segmented files.
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw RecorderError("The iPhone cannot encode this format.") }
        writer.add(video)
        writer.add(audio)
        super.init()
        writer.delegate = self
        try directory.write(manifest)
    }

    /// Returns false when the take can no longer be written.
    @discardableResult
    func append(_ sample: CMSampleBuffer, isVideo: Bool) -> Bool {
        guard !finishing else { return true }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if startPTS == nil {
            guard isVideo else { return true }   // the take starts on a picture
            writer.initialSegmentStartTime = pts
            guard writer.startWriting() else { return fail(writer.error?.localizedDescription ?? "could not start") }
            writer.startSession(atSourceTime: pts)
            startPTS = pts
            let host = hostTime(pts)
            lock.withLock { manifest.firstFrameHostTime = host }
        }
        guard writer.status == .writing else { return fail(writer.error?.localizedDescription ?? "the writer stopped") }
        let input = isVideo ? video : audio
        if !isVideo, let startPTS, pts < startPTS { return true }
        guard input.isReadyForMoreMediaData else {
            if isVideo { countDrop() }
            return true
        }
        guard input.append(sample) else { return fail(writer.error?.localizedDescription ?? "a frame was refused") }
        if !isVideo, let startPTS {
            lock.withLock { if manifest.audioStartOffset == nil { manifest.audioStartOffset = (pts - startPTS).seconds } }
        }
        if isVideo {
            lastPTS = pts
            lock.withLock {
                manifest.frames += 1
                manifest.seconds = (pts - startPTS!).seconds + 1 / Double(manifest.camera.fps)
            }
        }
        return true
    }

    func countDrop() {
        lock.withLock { manifest.droppedFrames += 1 }
    }

    func finish(reason: String?, completion: @escaping (TakeManifest) -> Void) {
        guard !finishing else { return }
        finishing = true
        let close = { [self] in
            let final: TakeManifest = lock.withLock {
                manifest.endReason = failure ?? reason
                // A take is complete only when every segment reached the disk.
                if writer.status == .completed, failure == nil, !manifest.segments.isEmpty {
                    manifest.sha256 = joinedHash.hex
                    manifest.complete = true
                }
                try? directory.write(manifest)
                return manifest
            }
            onManifest?(final)
            completion(final)
        }
        guard startPTS != nil, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            close()
            return
        }
        video.markAsFinished()
        audio.markAsFinished()
        writer.finishWriting(completionHandler: close)
    }

    private func fail(_ why: String) -> Bool {
        lock.withLock { if failure == nil { failure = why } }
        return false
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        let updated: TakeManifest = lock.withLock {
            do {
                let info = try directory.store(segment: segmentData, index: manifest.segments.count)
                manifest.segments.append(info)
                joinedHash.add(segmentData)
                try directory.write(manifest)
            } catch {
                // Most likely the phone is full. The take is marked broken; nothing earlier is touched.
                if failure == nil { failure = "Could not save on the iPhone: \(error.localizedDescription)" }
            }
            return manifest
        }
        onManifest?(updated)
    }
}

struct RecorderError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
