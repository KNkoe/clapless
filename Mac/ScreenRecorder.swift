import AppKit
@preconcurrency import ScreenCaptureKit

struct ScreenDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let size: String          // in pixels, for telling two screens apart
}

/// An open app that can be recorded on its own.
struct ScreenApp: Identifiable, Equatable {
    let id: String            // bundle identifier
    let name: String
    let pid: pid_t
    let hasWindow: Bool       // on screen right now
}

/// What goes into `screen.mp4`.
enum ScreenTarget: Equatable {
    case display(CGDirectDisplayID)
    case app(id: String, name: String)
}

/// Records one display, or one app's windows, with the cursor, into `screen.mp4`. Clapless's own
/// windows are left out.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Started {
        var firstFrameHostTime: Double
        var display: CGDirectDisplayID
    }

    /// The app window being kept in the picture.
    private struct Following {
        var pid: pid_t
        var name: String
        var display: CGRect
        var source: CGRect
        var missing = false
    }

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
    private var configuration: SCStreamConfiguration?
    private var following: Following?
    private var ticks = 0
    private var stops = 0         // how often stop() was asked for, to catch one made while still starting

    /// Called on the main queue if the recording stops by itself.
    var onFailure: ((String) -> Void)?
    /// Called on the main queue when something is wrong with the picture, and with nil once it is right again.
    var onNotice: ((String?) -> Void)?

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    static func displays() -> [ScreenDisplay] {
        NSScreen.screens.compactMap { screen in
            let pixels = screen.frame.size.applying(.init(scaleX: screen.backingScaleFactor, y: screen.backingScaleFactor))
            return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map {
                ScreenDisplay(id: $0, name: screen.localizedName, size: "\(Int(pixels.width)) × \(Int(pixels.height))")
            }
        }
    }

    /// Every app in the Dock except this one: those with a window in front first, in that order.
    static func apps() -> [ScreenApp] {
        var front: [pid_t: Int] = [:]
        for (place, window) in onScreen().enumerated()
        where window.frame.width >= AppCrop.smallest.width && window.frame.height >= AppCrop.smallest.height {
            if front[window.pid] == nil { front[window.pid] = place }
        }
        return NSWorkspace.shared.runningApplications.compactMap { app -> ScreenApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier else { return nil }
            return ScreenApp(id: id, name: app.localizedName ?? id, pid: app.processIdentifier,
                             hasWindow: front[app.processIdentifier] != nil)
        }
        .sorted {
            let a = front[$0.pid] ?? Int.max, b = front[$1.pid] ?? Int.max
            return a != b ? a < b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Ordinary windows on screen, front to back. Needs no permission: no titles or pictures are read.
    private static func onScreen() -> [(pid: pid_t, frame: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (pid, frame)
        }
    }

    private static func window(of pid: pid_t) -> CGRect? {
        AppCrop.main(onScreen().filter { $0.pid == pid }.map(\.frame))
    }

    /// Brings the app to the front, so that what is about to be recorded is there to be seen.
    @MainActor private static func bringForward(_ id: String, name: String) async throws -> pid_t {
        guard id != Bundle.main.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        else { throw RecorderError("\(name) is not open.") }
        NSApp.yieldActivation(to: app)
        app.unhide()
        app.activate(from: .current, options: [.activateAllWindows])
        // Long enough for a hidden window, or another desktop, to come into view.
        for attempt in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if attempt >= 5, window(of: app.processIdentifier) != nil { return app.processIdentifier }
        }
        throw RecorderError("Open a window of \(name), then record again.")
    }

    /// Returns once the first picture has arrived.
    func start(_ target: ScreenTarget, to url: URL) async throws -> Started {
        let asked = queue.sync { stops }
        var pid: pid_t?
        if case .app(let id, let name) = target { pid = try await Self.bringForward(id, name: name) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        let configuration = SCStreamConfiguration()
        let filter: SCContentFilter
        let displayID: CGDirectDisplayID
        var follow: Following?
        let width: Int, height: Int
        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecorderError("The chosen screen is not connected.")
            }
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            guard !own.isEmpty else { throw RecorderError("Clapless could not leave its own window out of the recording.") }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            displayID = id
            (width, height) = AppCrop.pixels(of: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale),
                                             widest: CGFloat(Self.widest))
        case .app(_, let name):
            guard let pid, let app = content.applications.first(where: { $0.processID == pid }),
                  let window = Self.window(of: pid),
                  let index = AppCrop.display(for: window, among: content.displays.map { CGDisplayBounds($0.displayID) })
            else { throw RecorderError("Open a window of \(name), then record again.") }
            let display = content.displays[index]
            let bounds = CGDisplayBounds(display.displayID)
            guard let source = AppCrop.source(window: window, display: bounds) else {
                throw RecorderError("Move the \(name) window fully onto the screen, then record again.")
            }
            // Only this app is drawn: other apps' windows and notifications are not in the picture.
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            displayID = display.displayID
            (width, height) = AppCrop.pixels(of: source.size, scale: CGFloat(filter.pointPixelScale),
                                             widest: CGFloat(Self.widest))
            // The file keeps this size. A window resized later is fitted inside it.
            configuration.sourceRect = source
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.backgroundColor = .black
            follow = Following(pid: pid, name: name, display: bounds, source: source)
        }

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
        try queue.sync {
            guard stops == asked else { throw RecorderError("Stopped before the screen's first picture.") }
            self.stream = stream
            self.configuration = configuration
            following = follow
            writer = ScreenWriter(url: url, width: width, height: height)
            warnings = []
        }
        do {
            let time: Double = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.stream === stream else {
                        return continuation.resume(throwing: RecorderError("Stopped before the screen's first picture."))
                    }
                    self.first = continuation
                }
                stream.startCapture { error in
                    if let error {
                        self.queue.async { if self.stream === stream { self.firstFailed(error.localizedDescription) } }
                    }
                }
                queue.asyncAfter(deadline: .now() + 5) {
                    if self.stream === stream { self.firstFailed("The screen sent no picture.") }
                }
            }
            return Started(firstFrameHostTime: time, display: displayID)
        } catch {
            _ = await stop()
            throw error
        }
    }

    /// Keeps the picture on the app's window as it moves, is resized, or another of its windows comes forward.
    private func followWindow() {
        guard var now = following, let stream, let configuration else { return }
        let source = Self.window(of: now.pid).flatMap { AppCrop.source(window: $0, display: now.display) }
        if let source {
            if now.missing {
                now.missing = false
                DispatchQueue.main.async { self.onNotice?(nil) }
            }
            if source != now.source {
                now.source = source
                configuration.sourceRect = source
                stream.updateConfiguration(configuration) { error in
                    if let error { NSLog("Clapless: the picture could not follow the window: \(error)") }
                }
            }
        } else if !now.missing {
            now.missing = true
            let note = "\(now.name) is out of view: bring its window back"
            let kept = "\(now.name) was out of view for part of the take"
            if !warnings.contains(kept) { warnings.append(kept) }
            DispatchQueue.main.async { self.onNotice?(note) }
        }
        following = now
    }

    private func firstFailed(_ why: String) {
        first?.resume(throwing: RecorderError(why))
        first = nil
    }

    func stop() async -> Recording {
        let stopped = HostClock.now
        let current: SCStream? = queue.sync {
            stops += 1
            return stream
        }
        try? await current?.stopCapture()
        return await withCheckedContinuation { done in
            queue.async { [self] in
                firstFailed("Stopped before the screen's first picture.")
                stream = nil
                configuration = nil
                following = nil
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
            ticking.setEventHandler { [weak self] in
                guard let self else { return }
                self.writer?.advance(to: HostClock.now)
                self.ticks += 1
                if self.ticks % 6 == 0 { self.followWindow() }      // five times a second
            }
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
