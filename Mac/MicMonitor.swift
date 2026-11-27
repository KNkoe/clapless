import AVFoundation
import Combine
import CoreAudio

struct MicDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

/// The Mac microphone: its live level, and the take's mic.m4a. The chosen one is used while it is
/// there; otherwise the Mac's default stands in, and the window says so.
final class MicMonitor: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Recording {
        var name: String          // the microphone the take began on
        var id: String
        var firstSampleHostTime: Double?
        var seconds: Double
        var warnings: [String]
    }

    @Published private(set) var devices: [MicDevice] = []
    /// The microphone picked by the person, remembered. Nil means the Mac's default.
    @Published private(set) var selectedID = UserDefaults.standard.string(forKey: "mic.id")
    @Published private(set) var selectedName = UserDefaults.standard.string(forKey: "mic.name")
    @Published private(set) var activeID: String?       // the one being listened to
    @Published private(set) var defaultName: String?
    @Published private(set) var state: MicState = .notConnected
    @Published private(set) var bar = MicLevel.floorDB
    @Published private(set) var peak = MicLevel.floorDB
    @Published private(set) var history: [Double] = []     // for the track drawing
    @Published private(set) var accessDenied = false
    @Published private(set) var takeWarning: String?
    @Published private(set) var voiceQuiet = false

    private let queue = DispatchQueue(label: "clapless.mic", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var runningID: String?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var allowed = false

    private let lock = NSLock()
    private var level = MicLevel()
    private var lastBufferAt = 0.0
    private var voice = VoiceLevel()
    private var inTake = false

    // mic queue only
    private var currentOutput: AVCaptureAudioDataOutput?
    private var activeNameOnQueue = "The microphone"
    private var takeMic = (name: "Microphone", id: "")
    private var clockSource: AVCaptureSession?     // its clock is what sound buffers are stamped with
    private var writer: MicWriter?
    private var warnings: [String] = []

    func start() {
        let centre = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        observers.append(centre.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let self, note.object as? AVCaptureSession === self.session else { return }
            self.stopSession()
            self.refresh()
        })
        var address = Self.defaultInput
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) {
            [weak self] _, _ in self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        Task { @MainActor in
            allowed = await AVCaptureDevice.requestAccess(for: .audio)
            accessDenied = !allowed
            refresh()
        }
        refresh()
    }

    private static func found() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified).devices
            // The iPhone used as a Mac microphone can interrupt the camera, so it is never offered.
            .filter { !$0.localizedName.localizedCaseInsensitiveContains("iPhone") }
    }

    private static var defaultInput: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// The input chosen in System Settings, by the same identifier the capture devices use.
    private static func systemDefaultID() -> String? {
        var address = defaultInput
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
                                         &device) == noErr, device != 0 else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    var activeName: String? { devices.first { $0.id == activeID }?.name }

    /// Said whenever the microphone in use is not the one that was picked.
    var standInNote: String? {
        guard let selectedID, let activeID, activeID != selectedID, let activeName else { return nil }
        let wanted = selectedName ?? "Your microphone"
        let back = devices.contains { $0.id == selectedID }
        return back ? "\(wanted) is back. Using \(activeName) until the take ends."
            : "\(wanted) is off. Using \(activeName)."
    }

    func refresh() {
        let before = activeName
        let found = Self.found()
        let now = found.map { MicDevice(id: $0.uniqueID, name: $0.localizedName) }
        if now != devices { devices = now }
        let candidates = found.map {
            MicChoice.Candidate(id: $0.uniqueID,
                                builtIn: UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn)
        }
        let systemDefault = Self.systemDefaultID()
        // What "Mac default" would use: the same stand-in applies when the default is an iPhone.
        let standard = MicChoice.pick(chosen: nil, systemDefault: systemDefault, among: candidates)
        let standardName = now.first { $0.id == standard }?.name
        if standardName != defaultName { defaultName = standardName }
        let recording = lock.withLock { inTake }
        let next = recording
            ? MicChoice.pickDuringTake(current: activeID, chosen: selectedID, systemDefault: systemDefault,
                                       among: candidates)
            : MicChoice.pick(chosen: selectedID, systemDefault: systemDefault, among: candidates)
        let moved = next != activeID
        if moved { activeID = next }
        guard let next, let name = now.first(where: { $0.id == next })?.name else {
            if session != nil { stopSession() }
            return
        }
        if recording, moved {
            let note = "\(before ?? "The microphone") disconnected during the take; sound continued on \(name)"
            takeWarning = note
            queue.async { [self] in
                if !warnings.contains(note) { warnings.append(note) }
            }
        }
        queue.async { self.activeNameOnQueue = name }
        if allowed, session == nil || runningID != next { startSession(next) }
    }

    /// Nil picks the Mac's default.
    func select(_ device: MicDevice?) {
        guard !queue.sync(execute: { writer != nil }) else { return }
        selectedID = device?.id
        selectedName = device?.name
        UserDefaults.standard.set(device?.id, forKey: "mic.id")
        UserDefaults.standard.set(device?.name, forKey: "mic.name")
        stopSession()
        refresh()
    }

    private func startSession(_ id: String) {
        stopSession()
        guard let device = Self.found().first(where: { $0.uniqueID == id }),
              let source = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000,
            // Every microphone in one shape, so a take can move from one to another.
            AVNumberOfChannelsKey: 1,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(source), session.canAddOutput(output) else { return }
        session.addInput(source)
        session.addOutput(output)
        self.session = session
        runningID = id
        lock.withLock {
            level.reset(at: HostClock.now)
            voice = VoiceLevel()
        }
        queue.async { [self] in
            clockSource = session
            currentOutput = output
            writer?.sourceChanged()
            session.startRunning()
        }
    }

    private func stopSession() {
        guard let old = session else { return }
        session = nil
        runningID = nil
        queue.async { old.stopRunning() }
    }

    private func tick() {
        let now = HostClock.now
        let present = activeID != nil && devices.contains { $0.id == activeID } && !accessDenied
        let (newState, newBar, newPeak): (MicState, Double, Double) = lock.withLock {
            level.decay(to: now)
            return (present ? level.state(at: now) : .notConnected, level.bar, level.peak)
        }
        if newState != state { state = newState }
        bar = present ? newBar : MicLevel.floorDB
        peak = present ? newPeak : MicLevel.floorDB
        history.append(bar)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        let quiet = present && lock.withLock { voice.isQuiet }
        if quiet != voiceQuiet { voiceQuiet = quiet }
        queue.async { [self] in
            guard let writer else { return }
            var warning: String?
            if !present { warning = "\(activeNameOnQueue) disconnected during the take and no other microphone was found" }
            else if writer.hasWritten, now - lock.withLock({ lastBufferAt }) > 2 {
                warning = "\(activeNameOnQueue) stopped sending sound during the take"
            } else if newState == .noSound {
                warning = "\(activeNameOnQueue) went silent during the take"
            }
            if let warning {
                if !warnings.contains(warning) { warnings.append(warning) }
                DispatchQueue.main.async { self.takeWarning = warning }
            }
        }
    }

    // MARK: - Recording

    /// Get ready to write. Sound is held until `begin(at:)` says where the file starts.
    func arm(to url: URL) {
        let using = (name: activeName ?? "Microphone", id: activeID ?? "")
        takeWarning = nil
        queue.sync {
            takeMic = using
            warnings = []
            writer = MicWriter(url: url)
        }
        lock.withLock { inTake = true }
    }

    func begin(at hostTime: Double) {
        queue.async { self.writer?.begin(at: hostTime) }
    }

    func endRecording() async -> Recording? {
        lock.withLock { inTake = false }
        // A chosen microphone that came back during the take is taken up again now.
        defer { DispatchQueue.main.async { self.refresh() } }
        return await withCheckedContinuation { done in
            queue.async { [self] in
                guard let finishing = writer else { return done.resume(returning: nil) }
                writer = nil
                var notes = warnings
                if finishing.droppedBuffers > 0 { notes.append("Some microphone sound was lost while saving") }
                finishing.finish { result in
                    if result == nil {
                        notes.append("mic.m4a was not written: \(finishing.failure ?? "no sound arrived")")
                    }
                    done.resume(returning: Recording(name: self.takeMic.name, id: self.takeMic.id,
                                                     firstSampleHostTime: result?.firstSampleHostTime,
                                                     seconds: result?.seconds ?? 0, warnings: notes))
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === currentOutput else { return }     // a late buffer from the last microphone
        let now = HostClock.now
        let (loudest, squares, count) = Self.measure(sample)
        let rate = CMSampleBufferGetFormatDescription(sample)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48_000
        let channels = CMSampleBufferGetFormatDescription(sample)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        lock.withLock {
            level.add(peakDB: MicLevel.decibels(loudest), at: now)
            lastBufferAt = now
            voice.add(sumOfSquares: squares / Double(max(1, channels)), samples: count / Int(max(1, channels)), rate: rate)
        }
        guard let writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let host = clockSource?.synchronizationClock.map {
            CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()).seconds
        } ?? pts.seconds
        writer.append(sample, hostTime: host)
    }

    /// Loudest sample, sum of squares and number of values in a buffer of 32-bit float sound.
    private static func measure(_ sample: CMSampleBuffer) -> (peak: Float, squares: Double, count: Int) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return (0, 0, 0) }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return (0, 0, 0) }
        return pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { values in
            var top: Float = 0
            var squares = 0.0
            for i in 0..<(length / 4) {
                top = max(top, abs(values[i]))
                squares += Double(values[i]) * Double(values[i])
            }
            return top.isFinite && squares.isFinite ? (top, squares, length / 4) : (0, 0, 0)
        }
    }
}
