import AVFoundation

/// Writes the Mac microphone to `mic.m4a` so that the file begins at a chosen moment on the Mac's
/// clock: the first picture of the screen recording. Sound that arrives before that moment is known
/// is held for a few seconds, and the buffer straddling it is cut to the sample.
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
        }
        guard let input, let writer else { return }
        guard writer.status == .writing else { return fail(writer.error?.localizedDescription ?? "the writer stopped") }
        if input.isReadyForMoreMediaData, input.append(piece) {
            endPTS = CMSampleBufferGetPresentationTimeStamp(piece) + CMSampleBufferGetDuration(piece)
        } else {
            droppedBuffers += 1
        }
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
