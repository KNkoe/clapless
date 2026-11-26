import AppKit
@preconcurrency import ScreenCaptureKit

struct ScreenDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
}

/// Records one display, with the cursor, into `screen.mp4`. Clapless's own windows are left out.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Recording {
        var result: ScreenWriter.Result?
        var warnings: [String]
    }

    private static let widest = 3024        // a 14-inch MacBook's own width; enough for close-ups

    private let queue = DispatchQueue(label: "clapless.screen", qos: .userInitiated)
    // screen queue only
    private var stream: SCStream?
    private var writer: ScreenWriter?
    private var timer: DispatchSourceTimer?
    private var warnings: [String] = []
    private var first: CheckedContinuation<Double, Error>?

    /// Called on the main queue if the recording stops by itself.
    var onFailure: ((String) -> Void)?

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    static func displays() -> [ScreenDisplay] {
        NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                .map { ScreenDisplay(id: $0, name: screen.localizedName) }
        }
    }

    /// Returns the host clock time of the first picture, once it has arrived.
    func start(display id: CGDirectDisplayID, to url: URL) async throws -> Double {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw RecorderError("The chosen screen is not connected.")
        }
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        guard !own.isEmpty else { throw RecorderError("Clapless could not leave its own window out of the recording.") }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

        let pixels = filter.contentRect.size.applying(.init(scaleX: CGFloat(filter.pointPixelScale),
                                                            y: CGFloat(filter.pointPixelScale)))
        let shrink = min(1, CGFloat(Self.widest) / pixels.width)
        let width = Int(pixels.width * shrink) / 2 * 2, height = Int(pixels.height * shrink) / 2 * 2

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ScreenWriter.fps))
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.queueDepth = 8
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.stream = stream
            writer = ScreenWriter(url: url, width: width, height: height)
            warnings = []
        }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { self.first = continuation }
                stream.startCapture { error in
                    if let error {
                        self.queue.async { if self.stream === stream { self.firstFailed(error.localizedDescription) } }
                    }
                }
                queue.asyncAfter(deadline: .now() + 5) {
                    if self.stream === stream { self.firstFailed("The screen sent no picture.") }
                }
            }
        } catch {
            _ = await stop()
            throw error
        }
    }

    private func firstFailed(_ why: String) {
        first?.resume(throwing: RecorderError(why))
        first = nil
    }

    func stop() async -> Recording {
        let stopped = HostClock.now
        let current: SCStream? = queue.sync { stream }
        try? await current?.stopCapture()
        return await withCheckedContinuation { done in
            queue.async { [self] in
                firstFailed("Stopped before the screen's first picture.")
                stream = nil
                timer?.cancel()
                timer = nil
                guard let writer else { return done.resume(returning: Recording(result: nil, warnings: warnings)) }
                self.writer = nil
                var notes = warnings
                writer.finish(at: stopped) { result in
                    if result == nil {
                        notes.append("screen.mp4 did not finish cleanly: \(writer.failure ?? "no pictures")")
                    } else if let skipped = result?.skippedFrames, skipped > 3 {
                        notes.append("\(skipped) screen frames were skipped")
                    }
                    done.resume(returning: Recording(result: result, warnings: notes))
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === self.stream, let writer,
              let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds    // already on the host clock
        writer.show(buffer, at: time)
        if let waiting = first, writer.firstHost != nil {
            first = nil
            let ticking = DispatchSource.makeTimerSource(queue: queue)
            ticking.schedule(deadline: .now(), repeating: 1.0 / Double(ScreenWriter.fps), leeway: .milliseconds(4))
            ticking.setEventHandler { [weak self] in self?.writer?.advance(to: HostClock.now) }
            ticking.resume()
            timer = ticking
            waiting.resume(returning: time)
        } else if let failure = writer.failure {
            firstFailed(failure)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            guard stream === self.stream else { return }
            let why = "The screen recording stopped: \(error.localizedDescription)"
            warnings.append(why)
            firstFailed(why)
            DispatchQueue.main.async { self.onFailure?(why) }
        }
    }
}
