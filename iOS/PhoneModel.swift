import AVFoundation
import SwiftUI
import UIKit

/// Everything the iPhone screen shows, and what happens when the Mac or the person asks for something.
@MainActor
final class PhoneModel: ObservableObject {
    @Published private(set) var state: CaptureState = .starting
    @Published private(set) var problem: String?
    @Published private(set) var lens: Lens = Lens(rawValue: UserDefaults.standard.string(forKey: "lens") ?? "") ?? .back
    @Published private(set) var macName: String?
    @Published private(set) var pairedName: String? = PairStore.load().first?.peerName
    @Published var pairingPhase: PairingSession.Phase?
    @Published private(set) var seconds = 0.0
    @Published private(set) var warnings: [String] = []
    @Published private(set) var sending: Sending?
    @Published private(set) var recordedYet = false
    @Published private(set) var lensNote = LensNote.remind
    @Published private(set) var dark = false       // blacked out while the Mac shows the picture
    @Published private(set) var resting = false    // camera off: disconnected, or a while with no Mac
    @Published private(set) var closingIn: Int?    // seconds until the app closes itself, once it shows
    @Published private(set) var disconnected = false   // Disconnect was pressed on the Mac
    private var closer = CloseTimer()
    private var closing = false
    private var touchedAt = Date()
    private var torchWanted = Torch.off
    private var aloneSince = Date()
    private var space: (bytes: Int64, at: Date)?

    enum LensNote { case remind, wiped, none }
    private var lensWiped = false
    var screenMirrored: Bool?       // reported by the preview on screen

    struct Sending: Equatable {
        var takeID: String
        var fraction: Double
        var arrived: Bool     // the Mac has checked the whole take
    }
    private var sent: [String: Set<Int>] = [:]

    let camera = CameraController()
    private let link: PhoneLink
    private let takes: URL
    private var recorder: TakeRecorder?
    private var timer: Timer?
    private var load = LoadMeter()
    private var observers: [NSObjectProtocol] = []
    private var active = false
    private var background = UIBackgroundTaskIdentifier.invalid

    private static let spaceToStart: Int64 = 1_000_000_000
    private static let spaceToStop: Int64 = 300_000_000
    private static let darkAfter = 20.0       // seconds without a touch, with a Mac connected
    private static let restAfter = 180.0      // seconds with neither a Mac nor a touch

    init() {
        takes = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Takes")
        try? FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
        link = PhoneLink(name: UIDevice.current.name, takes: takes)
        UIDevice.current.isBatteryMonitoringEnabled = true

        link.onMac = { [weak self] name in
            MainActor.assumeIsolated {
                self?.macName = name
                self?.aloneSince = Date()
                if name != nil {
                    self?.stay()
                    self?.wake()
                } else {
                    self?.dark = false
                    // The Mac holds the switch, so the light goes out with it. A running take keeps it.
                    if self?.state != .recording { self?.setTorch(.off) }
                }
                self?.updatePreviewRate()
                self?.tick()
            }
        }
        link.onSent = { [weak self] take, index in MainActor.assumeIsolated { self?.segmentSent(take, index) } }
        link.onCommand = { [weak self] message in MainActor.assumeIsolated { self?.handle(message) } }
        link.onProblem = { [weak self] text in MainActor.assumeIsolated { self?.problem = text } }
        link.onPairing = { [weak self] phase in MainActor.assumeIsolated { self?.pairingChanged(phase) } }
        camera.onPreview = { [link] jpeg, captured in link.sendPreview(jpeg, captured: captured) }
        camera.onExposure = { [link] iso, seconds in link.send(.exposure(iso: iso, shutterSeconds: seconds)) }
        camera.onLensWiped = { [weak self] in Task { @MainActor in self?.lensCleared() } }
        camera.onLevel = { [link] db in link.send(.level(db)) }
        camera.onRecordingFailed = { [weak self] why in
            Task { @MainActor in self?.takeEnded(self?.recorder?.current, note: why) }
        }
        let centre = NotificationCenter.default
        observers.append(centre.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: camera.session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted("Something else took the camera") }
        })
        observers.append(centre.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: camera.session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activate() }
        })
        observers.append(centre.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: camera.session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted("The camera stopped") }
        })
    }

    // MARK: - App life

    /// iOS only lets the camera run while the app is open on an unlocked phone.
    func activate() {
        guard !closing, !active || state == .unavailable else { return }
        let first = !active
        active = true
        resting = false
        stay()
        touched()
        aloneSince = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        state = recorder == nil ? .starting : state
        startCamera()
        if first {
            lensWiped = false
            lensNote = .remind
            if recorder == nil {
                let folders = (try? FileManager.default.contentsOfDirectory(at: takes, includingPropertiesForKeys: nil)) ?? []
                folders.forEach { _ = TakeDirectory(url: $0).salvage() }
            }
            link.restart()
            if pairedName == nil { link.startPairing() }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func startCamera() {
        Task { [self] in
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .unavailable
                problem = "Camera access is off. Turn it on in Settings > Apps > Clapless."
                return
            }
            if await !AVCaptureDevice.requestAccess(for: .audio) {
                problem = "Microphone access is off, so takes cannot be lined up by sound."
            }
            camera.start(lens: lens) { [weak self] result in
                Task { @MainActor in
                    guard let self, !self.resting else { return }
                    switch result {
                    case .success:
                        if self.recorder == nil { self.state = .ready }
                    case .failure(let error):
                        self.state = .unavailable
                        self.problem = error.localizedDescription
                    }
                    self.updatePreviewRate()
                }
            }
        }
    }

    // MARK: - Staying cool

    /// Any tap: light the screen again, bring the camera back if it was resting, and stay open.
    func touched() {
        stay()
        touchedAt = Date()
        dark = false
        wake()
    }

    /// The camera goes off and the screen black. The app stays awake only so that it can close itself.
    private func rest() {
        resting = true
        state = .starting
        torchWanted = .off
        camera.stop()
        updatePreviewRate()
    }

    /// Call off any countdown to closing.
    private func stay() {
        closer.stay(at: Date())
        closingIn = nil
        disconnected = false
    }

    /// Disconnect on the Mac: stop the camera and light now, and close shortly.
    private func goodbye() {
        closer.disconnected(at: Date())
        disconnected = true
        dark = false
        setTorch(.off)
        if state != .recording, state != .finishing, !resting { rest() }
        saveEnergy()
    }

    /// Stop everything and leave. iOS offers an app no polite way to close itself, so the process
    /// ends; takes are already safe on disk. The phone then locks as it usually would.
    private func close() {
        guard recorder == nil, !closing else { return }
        closing = true
        timer?.invalidate()
        timer = nil
        torchWanted = .off
        camera.stop()
        link.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        // A moment for the camera, light and network to let go.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            exit(0)
        }
    }

    private func wake() {
        guard resting, active else { return }
        resting = false
        touchedAt = Date()
        state = .starting
        UIApplication.shared.isIdleTimerDisabled = true
        startCamera()
    }

    private func saveEnergy() {
        if macName != nil || state == .recording { aloneSince = Date() }
        let pairing: Bool
        switch pairingPhase {
        case .exchanging, .compare, .waitingForPeer: pairing = true
        default: pairing = false
        }
        let busy = state == .recording || state == .finishing || pairing
        if let left = closer.secondsLeft(at: Date(), linked: macName != nil, busy: busy) {
            if left <= 0 { return close() }
            // A disconnect shows its countdown at once; otherwise only the resting screen needs it.
            closingIn = Int(left.rounded(.up))
        } else {
            closingIn = nil
        }
        let quietEnough = Date().timeIntervalSince(max(aloneSince, touchedAt)) > Self.restAfter
        if !resting, state == .ready, disconnected || quietEnough { rest() }
        let quiet = macName != nil && !resting && pairingPhase == nil
            && (state == .ready || state == .recording || state == .finishing)
            && Date().timeIntervalSince(touchedAt) > Self.darkAfter
        if quiet != dark { dark = quiet }
    }

    /// The phone was locked or another app came forward: finish the take cleanly before iOS stops us.
    func enterBackground() {
        guard active else { return }
        background = UIApplication.shared.beginBackgroundTask { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        // Locked or put away after a disconnect, or while already resting: nothing left to wait for.
        if recorder == nil, disconnected || resting { return close() }
        active = false
        torchWanted = .off
        UIApplication.shared.isIdleTimerDisabled = false
        timer?.invalidate()
        timer = nil
        let leave = { [weak self] in
            guard let self else { return }
            self.link.stop()
            self.macName = nil
            self.endBackgroundTask()
        }
        if recorder != nil {
            stopTake(reason: "Clapless left the screen (phone locked or another app opened)") { leave() }
        } else {
            leave()
        }
    }

    private func endBackgroundTask() {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        background = .invalid
    }

    private func interrupted(_ why: String) {
        if recorder != nil { stopTake(reason: why) }
        torchWanted = .off
        state = .unavailable
        problem = why
        tick()
    }

    // MARK: - Commands

    private func handle(_ message: MacMessage) {
        switch message {
        case .startTake(let id): startTake(id)
        case .stopTake: stopTake(reason: nil)
        case .setLens(let new): choose(new)
        case .setTorch(let wanted): setTorch(wanted)
        case .listTakes: link.send(.takes(storedTakes()))
        case .takeVerified(let id, let sha): markVerified(id, sha)
        case .deleteTake(let id): deleteTake(id)
        case .disconnect: goodbye()
        default: break
        }
    }

    /// Not during a take: exposure is locked then, so the picture would jump in brightness.
    private func setTorch(_ wanted: Torch) {
        guard state == .ready else { return }
        camera.setTorch(wanted) { [weak self] why in
            Task { @MainActor in
                guard let self else { return }
                if let why {
                    self.link.send(.refused(why))
                } else {
                    self.torchWanted = wanted
                }
                self.tick()
            }
        }
    }

    func choose(_ new: Lens) {
        guard state == .ready, new != lens else { return }
        state = .starting
        torchWanted = .off
        camera.start(lens: new) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .success = result {
                    self.lens = new
                    UserDefaults.standard.set(new.rawValue, forKey: "lens")
                    self.problem = nil
                } else if case .failure(let error) = result {
                    self.problem = error.localizedDescription
                }
                self.state = .ready
                self.tick()
            }
        }
    }

    /// The record button on the phone records the camera alone; the Mac's button records a whole take.
    func toggleFromPhone() {
        if state == .recording {
            stopTake(reason: nil)
        } else {
            startTake("phone-" + Self.stamp.string(from: Date()))
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private func startTake(_ id: String) {
        let folder = takes.appendingPathComponent(id)
        func refuse(_ why: String) { link.send(.refused(why)) }
        guard isSafeTakeID(id), !FileManager.default.fileExists(atPath: folder.path) else {
            return refuse("That take name cannot be used.")
        }
        guard state == .ready, active else { return refuse("The iPhone camera is not ready.") }
        guard freeBytes() > Self.spaceToStart else { return refuse("The iPhone is nearly full.") }
        state = .recording
        recordedYet = true
        sending = nil
        seconds = 0
        problem = nil
        camera.lockForTake { [weak self] settings in
            Task { @MainActor in
                guard let self, self.state == .recording, self.recorder == nil else { return }
                guard let settings else {
                    let why = "The iPhone camera could not be set up for a take."
                    self.state = .ready
                    self.camera.unlock()
                    self.problem = why
                    self.link.send(.refused(why))
                    return
                }
                do {
                    let new = try TakeRecorder(directory: TakeDirectory(url: folder), takeID: id, camera: settings)
                    new.onManifest = { [link = self.link] in link.send(.manifest($0)) }
                    self.recorder = new
                    self.camera.begin(new)
                    self.problem = settings.note
                    self.updatePreviewRate()
                    self.tick()
                } catch {
                    self.state = .ready
                    self.camera.unlock()
                    self.problem = error.localizedDescription
                    self.link.send(.refused(error.localizedDescription))
                }
            }
        }
    }

    func stopTake(reason: String?, then: (() -> Void)? = nil) {
        guard state == .recording else {
            then?()
            return
        }
        if recorder == nil {   // stopped while the camera was still being locked
            state = .ready
            camera.unlock()
            then?()
            return
        }
        state = .finishing
        tick()
        camera.end(reason: reason) { [weak self] manifest in
            Task { @MainActor in
                self?.takeEnded(manifest, note: reason)
                then?()
            }
        }
    }

    private func takeEnded(_ manifest: TakeManifest?, note: String?) {
        recorder = nil
        camera.unlock()
        state = .ready
        if let note { problem = note }
        if let manifest {
            link.send(.manifest(manifest))
            if manifest.complete { showSending(manifest.takeID) }
        }
        updatePreviewRate()
        tick()
    }

    private func storedTakes() -> [TakeManifest] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: takes, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { TakeDirectory(url: $0).readManifest() }
            .filter { $0.complete && !$0.verifiedByMac }
            .sorted { $0.created < $1.created }
    }

    /// Only a note: the phone keeps its copy.
    private func markVerified(_ id: String, _ sha: String) {
        guard isSafeTakeID(id) else { return }
        let directory = TakeDirectory(url: takes.appendingPathComponent(id))
        guard var manifest = directory.readManifest(), manifest.sha256 == sha else { return }
        manifest.verifiedByMac = true
        try? directory.write(manifest)
        sent[id] = nil
        guard sending?.takeID == id else { return }
        sending = Sending(takeID: id, fraction: 1, arrived: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if sending?.takeID == id, sending?.arrived == true { sending = nil }
        }
    }

    /// The only thing that removes a take from the phone, and only when it was deleted on the Mac.
    /// A take still being written is left alone; the Mac asks again once it has stopped.
    private func deleteTake(_ id: String) {
        guard recorder?.current.takeID != id else { return }
        do {
            try TakeRemoval.remove(id, from: takes)
        } catch {
            problem = "Could not delete a take: \(error.localizedDescription)"
            return
        }
        sent[id] = nil
        if sending?.takeID == id { sending = nil }
        space = nil
        link.send(.takeDeleted(takeID: id))
        tick()
    }

    // MARK: - The lens

    private func lensCleared() {
        guard state == .ready, !lensWiped else { return }
        lensWiped = true
        guard lensNote == .remind else { return tick() }
        lensNote = .wiped
        tick()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if lensNote == .wiped { lensNote = .none }
        }
    }

    func dismissLensNote() {
        lensWiped = true
        lensNote = .none
        tick()
    }

    // MARK: - Sending

    private func segmentSent(_ take: String, _ index: Int) {
        guard isSafeTakeID(take) else { return }
        sent[take, default: []].insert(index)
        showSending(take)
    }

    /// Only finished takes: while recording, the red timecode is what matters.
    private func showSending(_ take: String) {
        guard state != .recording,
              let manifest = TakeDirectory(url: takes.appendingPathComponent(take)).readManifest(),
              manifest.complete, !manifest.verifiedByMac, manifest.totalBytes > 0 else { return }
        let gone = manifest.segments.filter { sent[take]?.contains($0.index) == true }.reduce(0) { $0 + $1.bytes }
        sending = Sending(takeID: take, fraction: Double(gone) / Double(manifest.totalBytes), arrived: false)
    }

    // MARK: - Status

    private func updatePreviewRate() {
        // Every second frame between takes and every fourth during one.
        camera.previewFPS = macName == nil || resting ? 0 : 8
    }

    /// Asking iOS for the free space is slow work, so between takes of it the last answer will do.
    private func recentFreeBytes() -> Int64 {
        if let space, Date().timeIntervalSince(space.at) < 10 { return space.bytes }
        let bytes = freeBytes()
        space = (bytes, Date())
        return bytes
    }

    private func freeBytes() -> Int64 {
        let values = try? takes.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private func tick() {
        let device = UIDevice.current
        let heat: Heat
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: heat = .nominal
        case .fair: heat = .fair
        case .serious: heat = .serious
        case .critical: heat = .critical
        @unknown default: heat = .serious
        }
        saveEnergy()
        let free = recentFreeBytes()
        let battery = Double(device.batteryLevel)
        let charging = device.batteryState == .charging || device.batteryState == .full
        let current = recorder?.current
        if state == .recording { seconds = current?.seconds ?? 0 }
        if state == .recording, free < Self.spaceToStop { stopTake(reason: "The iPhone ran out of space") }
        if state == .recording, heat == .critical { stopTake(reason: "The iPhone got too hot") }

        let torch = camera.torch
        // iOS put the light out by itself. Say so, because the picture just got darker.
        if torchWanted != .off, torch == .off, state == .ready || state == .recording {
            torchWanted = .off
            problem = "The iPhone turned its light off to cool down"
        }

        let status = PhoneStatus(
            name: device.name, model: "iPhone", state: state, note: problem, takeID: current?.takeID, seconds: seconds,
            lens: lens, freeBytes: free, bytesPerSecond: (CameraController.bitrate + 96_000) / 8, battery: battery,
            charging: charging, heat: heat, droppedFrames: current?.droppedFrames ?? 0,
            iso: camera.exposure?.iso, shutterSeconds: camera.exposure?.seconds, lensWiped: lensWiped,
            screenMirrored: screenMirrored, fileMirrored: camera.fileMirrored,
            processor: load.wholePhone(), appProcessor: load.thisApp(), cameraStrain: camera.strain,
            cameraFPS: camera.framesPerSecond, torch: torch)
        warnings = status.warnings
        link.send(.status(status))
    }

    // MARK: - Pairing

    func startPairing() { link.startPairing() }
    func confirmPairing() { link.confirmPairing() }
    func cancelPairing() { link.cancelPairing() }

    func forgetMac() {
        guard state != .recording else { return }
        PairStore.save([])
        pairedName = nil
        macName = nil
        link.restart()
        link.startPairing()
    }

    private func pairingChanged(_ phase: PairingSession.Phase?) {
        pairingPhase = phase
        if case .done(let record) = phase {
            pairedName = record.peerName
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                if case .done = pairingPhase { pairingPhase = nil }
            }
        }
    }
}
