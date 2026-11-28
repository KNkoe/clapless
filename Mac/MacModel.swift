import AppKit
import Combine
import SwiftUI

/// Everything the Mac window shows, and what Start and Stop do.
@MainActor
final class MacModel: ObservableObject {
    enum Phase: String { case idle, starting, recording, stopping }

    @Published private(set) var linked = false
    @Published private(set) var status: PhoneStatus?
    @Published private(set) var preview: NSImage?
    @Published private(set) var quality: PhoneClient.Quality?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var elapsed = 0.0
    @Published private(set) var faceHistory: [Double] = []
    @Published private(set) var phoneLevel = MicLevel.floorDB
    @Published private(set) var pairedName: String?
    @Published private(set) var pairingPhase: PairingSession.Phase?
    @Published private(set) var candidates: [FoundPhone] = []
    @Published private(set) var linkProblem: String?
    @Published private(set) var message: String?          // why the last take did not go as asked
    @Published private(set) var takes: [TakeRecord] = []
    @Published private(set) var progress: [String: Downloader.Progress] = [:]
    @Published private(set) var deletesWaiting = 0        // deleted here, still on the iPhone
    @Published private(set) var deleteProblem: String?
    @Published private(set) var disconnected = false      // on purpose, until Connect is pressed
    @Published private(set) var leaving = false           // disconnecting once the take has arrived
    @Published private(set) var macFreeBytes: Int64?
    @Published private(set) var displays: [ScreenDisplay] = []
    @Published private(set) var screenAllowed = ScreenRecorder.allowed
    @Published private(set) var recordScreen = UserDefaults.standard.object(forKey: "screen.on") as? Bool ?? true
    @Published private(set) var screenID = (UserDefaults.standard.object(forKey: "screen.id") as? Int).map(CGDirectDisplayID.init)
    @Published private(set) var screenApp = AppChoice.saved
    @Published private(set) var apps: [ScreenApp] = []
    @Published private(set) var choosing = false          // asking what to record
    @Published private(set) var screenNote: String?
    @Published var lensReminded = false
    @Published private(set) var lensThanks = false
    private var previewAges: [(at: Date, age: Double)] = []
    private let screen = ScreenRecorder()
    private lazy var sync = SoundSync(library: library)
    private var screenRunning = false
    private var phoneHeat: TakeRecord.PhoneHeat?
    private var recorded: (display: String, app: String?)?     // what this take's screen file shows
    private var appsCheckedAt = Date.distantPast
    private var phoneAsked = false
    private var phoneStopped: Set<String> = []
    private var freeCheckedAt = Date.distantPast

    let mic = MicMonitor()
    private let client = PhoneClient()
    private let library = TakeLibrary()
    private lazy var downloader = Downloader(library: library, client: client)
    private var takeID: String?
    private var startedAt = Date()
    private var askedAt = Date()
    private var stopWanted: String?          // keep telling the phone until it has stopped this take
    private var activity: NSObjectProtocol?
    private var napGuard: NSObjectProtocol?
    private var timer: Timer?
    private var speed: SpeedTest?
    private var lastSpeed: Double?
    private var route: String?
    private var afterStop: (() -> Void)?
    private var previewAt = Date.distantPast

    func start() {
        // A napping app would miss its once-a-second pings and lose the iPhone while in the background.
        napGuard = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Staying linked to the iPhone")
        client.onLink = { [weak self] up in MainActor.assumeIsolated { self?.linkChanged(up) } }
        client.onMessage = { [weak self] message in MainActor.assumeIsolated { self?.handle(message) } }
        client.onPreview = { [weak self] data, age in
            MainActor.assumeIsolated {
                self?.preview = NSImage(data: data)
                self?.previewAt = Date()
                if let age { self?.previewAges.append((Date(), age)) }
                self?.previewAges.removeAll { Date().timeIntervalSince($0.at) > 3 }
            }
        }
        client.onQuality = { [weak self] quality in MainActor.assumeIsolated { self?.quality = quality } }
        client.onPaired = { [weak self] name in MainActor.assumeIsolated { self?.pairedName = name } }
        client.onPairing = { [weak self] phase in MainActor.assumeIsolated { self?.pairingChanged(phase) } }
        client.onPairingCandidates = { [weak self] found in MainActor.assumeIsolated { self?.candidates = found } }
        client.onProblem = { [weak self] text in MainActor.assumeIsolated { self?.linkProblem = text } }
        client.onRoute = { [weak self] name in MainActor.assumeIsolated { self?.route = name } }
        library.onChange = { [weak self] list in
            MainActor.assumeIsolated {
                self?.takes = list
                self?.deletesWaiting = self?.library.awaitingPhoneDelete().count ?? 0
                self?.sync.catchUp(list)
            }
        }
        screen.onFailure = { [weak self] why in MainActor.assumeIsolated { self?.message = why } }
        screen.onNotice = { [weak self] note in MainActor.assumeIsolated { self?.screenNote = note } }
        displays = ScreenRecorder.displays()
        downloader.onProgress = { [weak self] take, value in MainActor.assumeIsolated { self?.progress[take] = value } }
        library.load()
        downloader.start()
        client.start()
        mic.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: - What can happen now

    /// Why Start is off, or nil when a take can begin.
    var blocker: String? { deviceBlocker ?? screenBlocker }

    /// What is wrong with the screen choice; it can be put right where the choice is made.
    var screenBlocker: String? {
        guard recordScreen else { return nil }
        if !screenAllowed { return "Allow screen recording, or record without the screen" }
        if let app = screenApp {
            return NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty
                ? "\(app.name) is not open" : nil
        }
        return chosenDisplay == nil ? "The chosen screen is not connected" : nil
    }

    /// What is wrong with the microphone, the iPhone or the disk.
    var deviceBlocker: String? {
        if mic.accessDenied { return "Allow the microphone in System Settings" }
        if mic.state == .notConnected { return "No microphone found" }
        if pairedName == nil { return "Pair your iPhone first" }
        if disconnected { return "Disconnected from the iPhone" }
        guard linked, let status else { return "Open Clapless on your iPhone" }
        switch status.state {
        case .ready: break
        case .starting: return "The iPhone camera is starting"
        case .recording: return "The iPhone is already recording"
        case .finishing: return "The iPhone is saving the last take"
        case .unavailable: return status.note ?? "The iPhone camera is not available"
        }
        if let free = macFreeBytes, free < 3_000_000_000 { return "This Mac is nearly full" }
        return nil
    }

    /// The remembered screen, or the main one when none was ever picked. Never swapped silently.
    var chosenDisplay: ScreenDisplay? {
        guard let screenID else { return displays.first }
        return displays.first { $0.id == screenID }
    }

    /// What the next take records from the screen, or nil for none or for a screen that has gone.
    var screenTarget: ScreenTarget? {
        guard recordScreen else { return nil }
        if let app = screenApp { return .app(id: app.id, name: app.name) }
        return chosenDisplay.map { .display($0.id) }
    }

    var screenName: String {
        guard recordScreen else { return "Screen off" }
        return screenApp?.name ?? chosenDisplay?.name ?? "Choose a screen"
    }

    /// A whole screen, or nothing from the screen.
    func chooseScreen(_ display: ScreenDisplay?) {
        guard phase == .idle else { return }
        setScreen(on: display != nil)
        if let display {
            screenID = display.id
            UserDefaults.standard.set(Int(display.id), forKey: "screen.id")
            screenApp = nil
            AppChoice.saved = nil
        }
    }

    func chooseApp(_ app: ScreenApp) {
        guard phase == .idle else { return }
        setScreen(on: true)
        screenApp = AppChoice(id: app.id, name: app.name)
        AppChoice.saved = screenApp
    }

    private func setScreen(on: Bool) {
        recordScreen = on
        UserDefaults.standard.set(on, forKey: "screen.on")
    }

    /// The record button asks what to record first, with the last answer already picked.
    func askToRecord() {
        guard phase == .idle else { return }
        refreshSources()
        choosing = true
    }

    func stopAsking() { choosing = false }

    private func refreshSources() {
        appsCheckedAt = Date()
        displays = ScreenRecorder.displays()
        screenAllowed = ScreenRecorder.allowed
        apps = ScreenRecorder.apps()
    }

    /// The first time, macOS shows its own question. After that only System Settings can change it.
    func allowScreen() {
        if !UserDefaults.standard.bool(forKey: "screen.asked") {
            UserDefaults.standard.set(true, forKey: "screen.asked")
            _ = CGRequestScreenCaptureAccess()
        } else if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(pane)
        }
    }

    var warnings: [String] {
        var out: [String] = []
        if let message { out.append(message) }
        if let screenNote, phase == .recording { out.append(screenNote) }
        if let problem = linkProblem { out.append(problem) }
        if phase == .recording, !linked { out.append("Link to the iPhone lost. It keeps recording and sends the rest later.") }
        if mic.state == .noSound { out.append("No sound from \(mic.activeName ?? "the microphone"): check it is on") }
        if let warning = mic.takeWarning { out.append(warning) }
        if mic.voiceQuiet { out.append("Voice is quiet on \(mic.activeName ?? "this mic"): move closer") }
        if linked, let status {
            out += status.warnings
            if let note = status.note { out.append(note) }
            if status.droppedFrames > 0 { out.append("\(status.droppedFrames) frames dropped") }
        }
        if linked, let quality, quality.roundTripMs > 80 { out.append("Weak Wi-Fi (\(Int(quality.roundTripMs)) ms)") }
        if linked, let current = takeID, phase == .recording, let sending = progress[current],
           sending.listed - sending.received > 120_000_000 {
            out.append("Wi-Fi is behind the recording; the take finishes sending after you stop")
        }
        if let free = macFreeBytes, free < 20_000_000_000 { out.append("Mac has \(free / 1_000_000_000) GB free") }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }


    // MARK: - Takes

    func toggle() {
        switch phase {
        case .idle:
            if choosing { startTake() } else { askToRecord() }
        case .starting, .recording: stopTake()
        case .stopping: break
        }
    }

    @discardableResult
    func startTake() -> String? {
        guard phase == .idle else { return "A take is already running." }
        if let blocker { return blocker }
        leaving = false
        let id = Self.newTakeID(existing: library.folder)
        do {
            try library.create(id, created: Date(), status: .recording)
        } catch {
            message = "Could not make the take folder: \(error.localizedDescription)"
            return message
        }
        message = nil
        screenNote = nil
        choosing = false
        takeID = id
        stopWanted = nil
        phoneAsked = false
        phoneHeat = nil
        lensReminded = true
        faceHistory = []
        elapsed = 0
        phase = .starting
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "Recording a take")
        readClock(id)
        let folder = library.folder(id)
        mic.arm(to: folder.appendingPathComponent("mic.m4a"))
        let target = screenTarget
        screenRunning = target != nil
        recorded = nil
        Task { @MainActor in
            // The screen goes first and stops last, so it covers the whole camera clip, and the
            // microphone file begins at its first picture.
            if let target {
                do {
                    let started = try await screen.start(target, to: folder.appendingPathComponent("screen.mp4"))
                    guard takeID == id, phase == .starting else { return }
                    var app: String?
                    if case .app(_, let name) = target { app = name }
                    recorded = (displays.first { $0.id == started.display }?.name ?? "Screen", app)
                    mic.begin(at: started.firstFrameHostTime)
                } catch {
                    screenRunning = false
                    if takeID == id, phase == .starting {
                        stopTake(because: "The screen could not be recorded: \(error.localizedDescription)")
                    }
                    return
                }
            } else {
                mic.begin(at: HostClock.now)
            }
            phoneAsked = true
            askedAt = Date()
            client.send(.startTake(takeID: id))
        }
        return nil
    }

    func stopTake(because problem: String? = nil, then: (() -> Void)? = nil) {
        guard phase == .recording || phase == .starting, let id = takeID else {
            then?()
            return
        }
        let neverBegan = phase == .starting
        phase = .stopping
        afterStop = then
        if let problem { message = problem }
        if phoneAsked {
            stopWanted = id
            client.send(.stopTake)
        }
        readClock(id)
        let wasRunning = screenRunning
        Task { @MainActor in
            // Give the phone a moment to say it has stopped, so the screen outlasts the camera.
            let limit = Date().addingTimeInterval(3)
            while phoneAsked, !neverBegan, linked, !phoneStopped.contains(id), Date() < limit {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let screenDone = wasRunning ? await screen.stop() : nil
            screenRunning = false
            let micDone = await mic.endRecording()
            await save(id, microphone: micDone, screen: screenDone, source: recorded,
                       problem: problem, neverBegan: neverBegan)
            finishedStopping()
        }
    }

    /// Note down the files this Mac made, with their checksums.
    private func save(_ id: String, microphone: MicMonitor.Recording?,
                      screen: ScreenRecorder.Recording?, source: (display: String, app: String?)?, problem: String?,
                      neverBegan: Bool) async {
        let folder = library.folder(id)
        let library = library
        let display = source?.display, app = source?.app
        let heat = phoneHeat
        await Task.detached(priority: .userInitiated) {
            func fileFacts(_ name: String) -> (bytes: Int, sha: String)? {
                let url = folder.appendingPathComponent(name)
                guard let sha = try? Hashing.sha256(file: url),
                      let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
                else { return nil }
                return (bytes, sha)
            }
            var micEntry: TakeRecord.Mic?
            if let microphone, microphone.seconds > 0, let file = fileFacts("mic.m4a") {
                micEntry = TakeRecord.Mic(file: "mic.m4a", name: microphone.name, id: microphone.id, bytes: file.bytes,
                                          sha256: file.sha, seconds: microphone.seconds,
                                          firstSampleHostTime: microphone.firstSampleHostTime)
            }
            var screenEntry: TakeRecord.Screen?
            if let result = screen?.result, let file = fileFacts("screen.mp4") {
                screenEntry = TakeRecord.Screen(
                    file: "screen.mp4", bytes: file.bytes, sha256: file.sha, seconds: result.seconds,
                    frames: result.frames, skippedFrames: result.skippedFrames, width: result.width,
                    height: result.height, fps: ScreenWriter.fps, display: display ?? "Screen", app: app,
                    firstFrameHostTime: result.firstFrameHostTime)
            }
            library.update(id) { record in
                record.mic = micEntry
                record.screen = screenEntry
                record.phoneHeat = heat
                if let heat, heat.worst.rank >= Heat.serious.rank {
                    record.warn("The iPhone got hot during this take (\(heat.worst.rawValue))")
                }
                if !neverBegan { (microphone?.warnings ?? []).forEach { record.warn($0) } }
                screen?.warnings.forEach { record.warn($0) }
                if let problem { record.warn(problem) }
                // If the phone did record after all, its file arriving puts this right.
                if record.status == .recording {
                    record.status = neverBegan && record.camera == nil ? .failed : .transferring
                }
                record.settle()
                record.estimateSync()
            }
        }.value
    }

    private func finishedStopping() {
        phase = .idle
        takeID = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        let then = afterStop
        afterStop = nil
        then?()
    }

    private func readClock(_ id: String) {
        guard let quality else { return }
        let reading = TakeRecord.ClockReading(atMacHostTime: HostClock.now, phoneMinusMac: quality.clockOffset,
                                              roundTripMs: quality.clockRoundTripMs)
        library.update(id) { $0.clock.append(reading) }
    }

    private static func newTakeID(existing: (String) -> URL) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = format.string(from: Date())
        var id = base, n = 2
        while FileManager.default.fileExists(atPath: existing(id).path) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    func reveal(_ record: TakeRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([library.folder(record.take)])
    }

    /// Not while either device is still writing the take, or the Mac is checking it.
    func canDelete(_ record: TakeRecord) -> Bool {
        let onPhone = status?.takeID == record.take && (status?.state == .recording || status?.state == .finishing)
        return takeID != record.take && !onPhone && progress[record.take]?.checking != true
    }

    /// What the take takes up on this Mac.
    func size(of record: TakeRecord) -> Int { TakeRemoval.size(of: library.folder(record.take)) }

    func delete(_ record: TakeRecord, toTrash: Bool) {
        guard canDelete(record) else { return }
        deleteProblem = nil
        downloader.delete(record.take, toTrash: toTrash) { [weak self] why in
            MainActor.assumeIsolated {
                self?.deleteProblem = why
                self?.freeCheckedAt = .distantPast
            }
        }
    }

    func switchLens() {
        guard phase == .idle, let status, status.state == .ready else { return }
        client.send(.setLens(status.lens == .back ? .front : .back))
    }

    // MARK: - Disconnecting

    /// A take still on its way, or being checked.
    var sendingTake: Bool { progress.values.contains { $0.problem == nil && ($0.checking || !$0.recording) } }

    var canDisconnect: Bool {
        linked && !disconnected && phase == .idle && status?.state != .recording && status?.state != .finishing
    }

    /// Stop everything: the iPhone turns its camera off and closes shortly after. A take still being
    /// sent is let through first; pressing again leaves at once, and it carries on next time.
    func disconnect() {
        guard canDisconnect else { return }
        if sendingTake, !leaving {
            leaving = true
        } else {
            leave()
        }
    }

    private func leave() {
        leaving = false
        disconnected = true
        choosing = false
        message = nil
        client.disconnect()
    }

    func connect() {
        leaving = false
        guard disconnected else { return }
        disconnected = false
        client.reconnect()
    }

    // MARK: - The light

    private var lastTorch: Torch {
        get { Torch(rawValue: UserDefaults.standard.string(forKey: "torch.level") ?? "") ?? .low }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "torch.level") }
    }

    func toggleTorch() {
        guard let current = status?.torch else { return }
        setTorch(current.toggled(lastUsed: lastTorch))
    }

    func brightenTorch() {
        guard let current = status?.torch, current != .off else { return }
        setTorch(current.nextBrightness)
    }

    private func setTorch(_ wanted: Torch) {
        guard phase == .idle, status?.state == .ready else { return }
        if wanted != .off { lastTorch = wanted }
        client.send(.setTorch(wanted))
    }

    // MARK: - From the phone

    private func linkChanged(_ up: Bool) {
        linked = up
        if up {
            client.send(.listTakes)
        } else {
            status = nil
            preview = nil
            quality = nil
        }
        downloader.linkChanged(up)
        // Lost while waiting to leave: stay away, and the iPhone closes itself for want of a Mac.
        if !up, leaving { leave() }
    }

    private func handle(_ incoming: PhoneMessage) {
        switch incoming {
        case .status(let new):
            status = new
            if new.lensWiped == true, !lensReminded {
                lensReminded = true
                lensThanks = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    lensThanks = false
                }
            }
            if let wanted = stopWanted {
                if new.state == .recording, new.takeID == wanted { client.send(.stopTake) }
                if new.state == .ready, phase == .idle { stopWanted = nil }
            }
            if let id = takeID {
                if new.state == .recording, new.takeID == id {
                    if phoneHeat == nil { phoneHeat = TakeRecord.PhoneHeat(new) } else { phoneHeat?.add(new) }
                }
                if phase == .starting, new.state == .recording, new.takeID == id { began() }
                // Ready again with no take, well after recording began: the phone ended it while out of touch.
                if phase == .recording, new.state == .ready, Date().timeIntervalSince(startedAt) > 4 {
                    stopTake(because: new.note ?? "The iPhone stopped recording")
                }
            }
        case .manifest(let manifest):
            if manifest.complete || manifest.endReason != nil { phoneStopped.insert(manifest.takeID) }
            downloader.offer(manifest)
            if manifest.takeID == takeID {
                if phase == .starting { began() }
                if phase == .recording, manifest.complete || manifest.endReason != nil {
                    stopTake(because: manifest.endReason ?? "The iPhone stopped recording")
                }
            }
        case .takes(let list):
            list.forEach { downloader.offer($0) }
        case .takeDeleted(let id):
            downloader.phoneDeleted(id)
        case .refused(let why):
            if phase == .starting { stopTake(because: why) } else { message = why }
        case .exposure(let iso, let seconds):
            status?.iso = iso
            status?.shutterSeconds = seconds
        case .level(let db):
            phoneLevel = db
            if phase == .recording {
                faceHistory.append(db)
                if faceHistory.count > 200 { faceHistory.removeFirst(faceHistory.count - 200) }
            }
        default:
            break
        }
    }

    private func began() {
        phase = .recording
        startedAt = Date()
    }

    private func tick() {
        if leaving, canDisconnect, !sendingTake { leave() }
        if phase == .recording { elapsed = Date().timeIntervalSince(startedAt) }
        if choosing, Date().timeIntervalSince(appsCheckedAt) > 1 { refreshSources() }
        if Date().timeIntervalSince(freeCheckedAt) > 5 {
            freeCheckedAt = Date()
            displays = ScreenRecorder.displays()
            screenAllowed = ScreenRecorder.allowed
            let values = try? library.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            macFreeBytes = values?.volumeAvailableCapacityForImportantUsage
        }
        if phase == .starting, phoneAsked, Date().timeIntervalSince(askedAt) > 8 {
            stopTake(because: "The iPhone did not start recording")
        }
        // A frozen picture must not look live.
        if preview != nil, Date().timeIntervalSince(previewAt) > 3 { preview = nil }
        objectWillChange.send()   // free space and the microphone state feed the Start button
    }

    // MARK: - Pairing

    func pair(_ phone: FoundPhone) { client.pair(with: phone) }
    func confirmPairing() { client.confirmPairing() }
    func cancelPairing() { client.cancelPairing() }
    func dismissPairing() { pairingPhase = nil }
    func forgetPhone() { if phase == .idle { client.forget() } }

    private func pairingChanged(_ new: PairingSession.Phase?) {
        pairingPhase = new
        if case .done = new {
            disconnected = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                if case .done = pairingPhase { pairingPhase = nil }
            }
        }
    }

    // MARK: - Command line

    /// Answers `scripts/clapless`. The reply is handed back when the work is done.
    func command(_ name: String, _ argument: String?, reply: @escaping ([String: Any]) -> Void) {
        func ok(_ extra: [String: Any] = [:]) { reply(extra.merging(["ok": true]) { $1 }) }
        func no(_ why: String) { reply(["ok": false, "error": why]) }
        switch name {
        case "status": ok(summary())
        case "start":
            if let why = startTake() { return no(why) }
            let id = takeID ?? ""
            // Report only once the phone has confirmed, or has failed to.
            Task { @MainActor in
                while phase == .starting { try? await Task.sleep(for: .milliseconds(100)) }
                if phase == .recording, takeID == id { ok(["take": id, "folder": library.folder(id).path]) }
                else { no(message ?? "The take did not start.") }
            }
        case "stop":
            guard let id = takeID, phase == .recording || phase == .starting else { return no("No take is running.") }
            stopTake { [self] in ok(["take": id, "folder": library.folder(id).path]) }
        case "takes":
            ok(["takes": takes.prefix(20).map { describe($0) }])
        case "mic":
            guard phase == .idle else { return no("Not during a take.") }
            if argument?.lowercased() == "default" {
                mic.select(nil)
                return ok(["selected": "Mac default", "using": orNull(mic.activeName)])
            }
            guard let argument, let device = mic.devices.first(where: {
                $0.name.localizedCaseInsensitiveContains(argument)
            }) else { return no("No microphone matches. Found: \(mic.devices.map(\.name).joined(separator: ", "))") }
            mic.select(device)
            ok(["selected": device.name])
        case "screen":
            guard phase == .idle else { return no("Not during a take.") }
            switch argument {
            case "off": chooseScreen(nil)
            case "on": setScreen(on: true)
            case "full":
                guard let display = chosenDisplay ?? displays.first else { return no("No screen found.") }
                chooseScreen(display)
            default:
                guard let argument, argument.hasPrefix("app ") else { return no("Use: screen on|off|full|app NAME") }
                let wanted = String(argument.dropFirst(4))
                let open = ScreenRecorder.apps()
                guard let app = open.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
                        ?? open.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) })
                else { return no("No open app matches. Open: \(open.map(\.name).joined(separator: ", "))") }
                chooseApp(app)
            }
            ok(["recording": screenName])
        case "apps":
            ok(["apps": ScreenRecorder.apps().map { ["name": $0.name, "hasWindow": $0.hasWindow] as [String: Any] }])
        case "sync":
            guard let record = argument.flatMap({ id in takes.first { $0.take == id } }) ?? takes.first
            else { return no("No take to match.") }
            sync.run(record.take)
            ok(["take": record.take])
        case "lens":
            guard let lens = argument.flatMap(Lens.init(rawValue:)) else { return no("Use: lens back|front") }
            guard phase == .idle, linked else { return no("Not now.") }
            client.send(.setLens(lens))
            ok()
        case "light":
            guard let wanted = argument.flatMap(Torch.init(rawValue:)) else { return no("Use: light off|low|medium|high") }
            guard phase == .idle, linked, status?.state == .ready else { return no("Not now.") }
            guard status?.torch != nil else { return no("The light only works with the back camera.") }
            setTorch(wanted)
            ok()
        case "disconnect":
            if disconnected { return ok(["disconnected": true]) }
            guard canDisconnect else { return no(linked ? "Stop the take first." : "The iPhone is not linked.") }
            disconnect()
            ok(["disconnected": disconnected, "afterTransfer": leaving])
        case "connect":
            connect()
            ok()
        case "direct":
            guard let argument, ["on", "off"].contains(argument) else { return no("Use: direct on|off") }
            guard phase == .idle else { return no("Not during a take.") }
            client.setDirectLink(argument == "on")
            ok()
        case "speedtest":
            guard linked, phase == .idle else { return no("Link the iPhone and stop any take first.") }
            guard speed == nil else { return no("A speed test is already running.") }
            let test = SpeedTest()
            speed = test
            test.run(client: client, megabytes: min(max(Int(argument ?? "") ?? 60, 5), 400)) { [weak self] result in
                MainActor.assumeIsolated {
                    self?.speed = nil
                    switch result {
                    case .success(let mbps):
                        self?.lastSpeed = mbps
                        ok(["megabitsPerSecond": (mbps * 10).rounded() / 10])
                    case .failure(let error): no(error.localizedDescription)
                    }
                }
            }
        default:
            no("Unknown command.")
        }
    }

    private func orNull(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

    private func summary() -> [String: Any] {
        var phone: [String: Any] = ["paired": orNull(pairedName), "linked": linked,
                                    "disconnected": disconnected, "disconnectingAfterTransfer": leaving]
        if let status {
            phone["state"] = status.state.rawValue
            phone["lens"] = status.lens.rawValue
            phone["torch"] = orNull(status.torch?.rawValue)
            phone["freeGB"] = Double(status.freeBytes / 100_000_000) / 10
            phone["minutesLeft"] = Int(status.minutesLeft)
            phone["battery"] = status.battery
            phone["charging"] = status.charging
            phone["heat"] = status.heat.rawValue
            phone["droppedFrames"] = status.droppedFrames
            phone["processorPercent"] = status.processor.map { Int($0.rounded()) as Any } ?? NSNull()
            phone["appProcessorPercent"] = status.appProcessor.map { Int($0.rounded()) as Any } ?? NSNull()
            phone["cameraStrain"] = orNull(status.cameraStrain)
            phone["cameraFPS"] = status.cameraFPS.map { $0 as Any } ?? NSNull()
        }
        if let quality { phone["roundTripMs"] = Int(quality.roundTripMs) }
        if linked, let route { phone["route"] = route }
        phone["directLink"] = PhoneClient.directLinkWanted
        if let lastSpeed { phone["lastSpeedMbps"] = Int(lastSpeed) }
        phone["previewLive"] = preview != nil
        if let status {
            phone["screenMirrored"] = status.screenMirrored.map { $0 as Any } ?? NSNull()
            phone["fileMirrored"] = status.fileMirrored.map { $0 as Any } ?? NSNull()
        }
        if !previewAges.isEmpty {
            let sorted = previewAges.map(\.age).sorted()
            phone["previewDelayMs"] = Int(sorted[sorted.count / 2] * 1000)
            phone["previewFPS"] = Int((Double(previewAges.count) / 3).rounded())
        }
        if let status, let light = LightAdvice.reading(iso: status.iso, shutterSeconds: status.shutterSeconds) {
            phone["light"] = light.level.rawValue
            phone["iso"] = light.iso
            phone["lensWiped"] = status.lensWiped ?? false
        }
        return [
            "phase": phase.rawValue, "take": orNull(takeID), "seconds": Int(elapsed), "iphone": phone,
            "microphone": [
                "selected": mic.selectedName ?? "Mac default", "using": orNull(mic.activeName),
                "note": orNull(mic.standInNote), "state": "\(mic.state)", "levelDB": Int(mic.bar.rounded()),
                "available": mic.devices.map(\.name),
            ],
            "screen": ["on": recordScreen, "allowed": screenAllowed, "display": orNull(chosenDisplay?.name),
                       "app": orNull(screenApp?.name)],
            "canStart": blocker == nil && phase == .idle, "blocker": orNull(blocker), "warnings": warnings,
        ]
    }

    private func describe(_ record: TakeRecord) -> [String: Any] {
        var out: [String: Any] = ["take": record.take, "status": record.status.rawValue,
                                  "folder": library.folder(record.take).path, "warnings": record.warnings]
        if let sync = record.sync {
            out["sync"] = ["method": sync.method, "matchedBySound": sync.matchedBySound,
                           "offset": sync.videoOffset.map { $0 as Any } ?? NSNull(),
                           "weak": sync.weak ?? false, "note": orNull(sync.note)] as [String: Any]
        }
        if let progress = progress[record.take] {
            out["received"] = progress.received
            out["listed"] = progress.listed
        }
        return out
    }
}

/// The one app to record, remembered between launches. Nil means a whole screen.
struct AppChoice: Equatable {
    var id: String
    var name: String

    static var saved: AppChoice? {
        get {
            guard let id = UserDefaults.standard.string(forKey: "screen.app") else { return nil }
            return AppChoice(id: id, name: UserDefaults.standard.string(forKey: "screen.appName") ?? id)
        }
        set {
            UserDefaults.standard.set(newValue?.id, forKey: "screen.app")
            UserDefaults.standard.set(newValue?.name, forKey: "screen.appName")
        }
    }
}
