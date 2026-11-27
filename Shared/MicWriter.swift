import AVFoundation

/// Writes the Mac microphone to `mic.m4a` so that the file begins at a chosen moment on the Mac's
/// clock: the first picture of the screen recording. Sound that arrives before that moment is known
/// is held for a few seconds, and the buffer straddling it is cut to the sample.
///
/// The microphone may change part way. The file carries on in the same shape, with silence for the
/// time in between, so sound after the change is still where it happened.
///
/// All calls must come on one queue.
final class MicWriter {
    struct Result: Equatable {
        var firstSampleHostTime: Double
        var seconds: Double
    }

    private static let held = 4.0       // seconds kept while the start is unknown

    private let url: URL
    private var start: Double?
    private var waiting: [(sample: CMSampleBuffer, hostTime: Double)] = []
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var endPTS = CMTime.zero
    private var firstHost = 0.0
    private var shape: CMFormatDescription?
    private var shift = CMTime.zero      // moves a later microphone's clock onto the file's
    private var changed = false
    private(set) var failure: String?
    private(set) var droppedBuffers = 0

    init(url: URL) {
        self.url = url
    }

    var hasWritten: Bool { firstPTS != nil }

    /// The host time the file should begin at. Anything held from then on is written now.
    func begin(at hostTime: Double) {
        guard start == nil else { return }
        start = hostTime
        let backlog = waiting
        waiting = []
        backlog.forEach { write($0.sample, hostTime: $0.hostTime) }
    }

    /// What comes next is from another microphone, with its own clock.
    func sourceChanged() {
        if firstPTS == nil { waiting = [] } else { changed = true }
    }

    /// `hostTime` is the host clock time of the buffer's first sample.
    func append(_ sample: CMSampleBuffer, hostTime: Double) {
        guard start != nil else {
            waiting.append((sample, hostTime))
            waiting.removeAll { hostTime - $0.hostTime > Self.held }
            return
        }
        write(sample, hostTime: hostTime)
    }

    private func write(_ sample: CMSampleBuffer, hostTime: Double) {
        guard failure == nil, let start,
              let format = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
        var piece = sample
        var pieceHost = hostTime
        if firstPTS == nil {
            let count = CMSampleBufferGetNumSamples(sample)
            let skip = max(0, Int(((start - hostTime) * stream.mSampleRate).rounded()))
            if skip >= count { return }
            if skip > 0 {
                var cut: CMSampleBuffer?
                CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: sample,
                                                       sampleRange: CFRange(location: skip, length: count - skip),
                                                       sampleBufferOut: &cut)
                guard let cut else { return fail("the first sound could not be trimmed") }
                piece = cut
                pieceHost += Double(skip) / stream.mSampleRate
            }
            guard open(channels: Int(stream.mChannelsPerFrame), at: CMSampleBufferGetPresentationTimeStamp(piece)) else {
                return
            }
            firstHost = pieceHost
            shape = format
        }
        guard let writer, let firstPTS, let shape else { return }
        guard writer.status == .writing else { return fail(writer.error?.localizedDescription ?? "the writer stopped") }
        let rate = CMAudioFormatDescriptionGetStreamBasicDescription(shape)?.pointee.mSampleRate ?? 48_000
        let scale = CMTimeScale(rate)
        if !CMFormatDescriptionEqual(format, otherFormatDescription: shape) {
            guard let same = Self.reshaped(piece, as: shape) else {
                return fail("the new microphone's sound is in another format")
            }
            piece = same
        }
        if changed {
            let own = CMSampleBufferGetPresentationTimeStamp(piece)
            var due = firstPTS + CMTime(seconds: pieceHost - firstHost, preferredTimescale: scale)
            // Sound already covered is left out.
            let late = Int(((endPTS - due).seconds * rate).rounded())
            if late > 0 {
                let count = CMSampleBufferGetNumSamples(piece)
                if late >= count { return }
                var cut: CMSampleBuffer?
                CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: piece,
                                                       sampleRange: CFRange(location: late, length: count - late),
                                                       sampleBufferOut: &cut)
                guard let cut else { return fail("the sound could not be joined") }
                piece = cut
                shift = endPTS - CMSampleBufferGetPresentationTimeStamp(cut)
            } else {
                let missing = -late
                if missing > 0 {
                    guard let quiet = Self.silence(frames: missing, like: shape, at: endPTS) else {
                        return fail("the gap between microphones could not be filled")
                    }
                    append(quiet)
                    due = endPTS
                }
                shift = due - own
            }
            changed = false
        }
        if shift != .zero {
            guard let moved = Self.moved(piece, by: shift) else { return fail("the sound could not be moved") }
            piece = moved
        }
        append(piece)
    }

    private func append(_ piece: CMSampleBuffer) {
        guard let input else { return }
        if input.isReadyForMoreMediaData, input.append(piece) {
            endPTS = CMSampleBufferGetPresentationTimeStamp(piece) + CMSampleBufferGetDuration(piece)
        } else {
            droppedBuffers += 1
        }
    }

    /// The same sound described the way the file's first sound was. Nil if the samples differ.
    private static func reshaped(_ sample: CMSampleBuffer, as shape: CMFormatDescription) -> CMSampleBuffer? {
        guard let old = CMSampleBufferGetFormatDescription(sample),
              let a = CMAudioFormatDescriptionGetStreamBasicDescription(old)?.pointee,
              let b = CMAudioFormatDescriptionGetStreamBasicDescription(shape)?.pointee,
              a.mSampleRate == b.mSampleRate, a.mFormatID == b.mFormatID, a.mFormatFlags == b.mFormatFlags,
              a.mBytesPerFrame == b.mBytesPerFrame, a.mChannelsPerFrame == b.mChannelsPerFrame,
              let data = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var copy: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: data, formatDescription: shape,
            sampleCount: CMSampleBufferGetNumSamples(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), packetDescriptions: nil,
            sampleBufferOut: &copy)
        return copy
    }

    private static func moved(_ sample: CMSampleBuffer, by shift: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        timing.presentationTimeStamp = timing.presentationTimeStamp + shift
        timing.decodeTimeStamp = .invalid
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
    }

    private static func silence(frames: Int, like format: CMFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        let bytes = frames * Int(stream.mBytesPerFrame)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                                    dataLength: bytes) == noErr else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }

    private func open(channels: Int, at time: CMTime) -> Bool {
        do {
            let new = try AVAssetWriter(outputURL: url, fileType: .m4a)
            // Write the sound in pieces, so a crash leaves a playable file.
            new.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            let used = min(2, max(1, channels))
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: used,
                AVEncoderBitRateKey: 96_000 * used,
            ])
            track.expectsMediaDataInRealTime = true
            guard new.canAdd(track) else { fail("the sound format cannot be written"); return false }
            new.add(track)
            guard new.startWriting() else { fail(new.error?.localizedDescription ?? "could not start"); return false }
            new.startSession(atSourceTime: time)
            writer = new
            input = track
            firstPTS = time
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    private func fail(_ why: String) {
        if failure == nil { failure = why }
    }

    /// Nil when no sound was written. `completion` may arrive on any queue.
    func finish(completion: @escaping (Result?) -> Void) {
        waiting = []
        guard let writer, let input, let firstPTS, writer.status == .writing else { return completion(nil) }
        let result = Result(firstSampleHostTime: firstHost, seconds: (endPTS - firstPTS).seconds)
        self.writer = nil
        self.input = nil
        input.markAsFinished()
        writer.finishWriting {
            completion(writer.status == .completed ? result : nil)
        }
    }
}
