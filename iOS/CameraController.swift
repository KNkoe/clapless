import AVFoundation
import CoreImage
import ImageIO

/// The camera: 4K sensor, upright 2160x3840 frames, ordinary (not HDR, not log) colour. Takes are
/// 30 fps; between takes it runs at half that so the phone stays cooler.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                              AVCaptureAudioDataOutputSampleBufferDelegate {
    static let fps: Int32 = 30              // every take
    static let idleFPS: Int32 = 15          // while only framing
    static let sensor = CMVideoDimensions(width: 3840, height: 2160)
    static let mainsHz = 50                 // Lesotho
    static let bitrate = 45_000_000         // to be judged against the Camera app

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "clapless.camera.session")
    private let dataQueue = DispatchQueue(label: "clapless.camera.data", qos: .userInitiated)
    // Not a background priority: a warm phone slows those down, and the preview would trail behind.
    private let previewQueue = DispatchQueue(label: "clapless.camera.preview", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let picture = CIContext(options: [.cacheIntermediates: false])
    private var device: AVCaptureDevice?
    private var configured = false

    // data queue only
    private var recorder: TakeRecorder?
    private var lastPreview = 0.0
    private var previewBusy = false

    private let flags = NSLock()
    private var previewRate = 0.0

    /// Preview frames per second for the Mac; 0 turns them off.
    var previewFPS: Double {
        get { flags.withLock { previewRate } }
        set { flags.withLock { previewRate = newValue } }
    }
    var onPreview: ((Data, Double) -> Void)?       // the picture, and when it was captured
    var onExposure: ((Double, Double) -> Void)?     // ISO and shutter seconds
    var onLensWiped: (() -> Void)?
    // data queue only
    private var lensFrames = 0
    private var lensWatch = LensWatch()
    private var exposureSentAt = 0.0
    var onLevel: ((Double) -> Void)?
    private var loudest: Float = 0
    private var levelSentAt = 0.0
    var onRecordingFailed: ((String) -> Void)?

    private(set) var lens: Lens = .back

    private var torchSetting = Torch.off     // behind `flags`
    private var torchAsked: Torch {
        get { flags.withLock { torchSetting } }
        set { flags.withLock { torchSetting = newValue } }
    }

    /// What the light is doing now, which is not always what was asked: iOS can put it out when
    /// the phone is hot. Nil when the camera in use has no light.
    var torch: Torch? {
        guard let device, device.hasTorch else { return nil }
        return device.torchMode == .off || !device.isTorchAvailable ? .off : torchAsked
    }

    func setTorch(_ wanted: Torch, completion: @escaping (String?) -> Void) {
        sessionQueue.async { [self] in
            guard let camera = device, camera.hasTorch, session.isRunning else {
                return completion("The light only works with the back camera.")
            }
            completion(light(camera, wanted))
        }
    }

    /// Session queue only. Returns why the light could not be changed.
    private func light(_ camera: AVCaptureDevice, _ wanted: Torch) -> String? {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if wanted == .off {
                camera.torchMode = .off
            } else {
                guard camera.isTorchAvailable else { return "The iPhone has the light off for now. Let it cool." }
                // A warm phone may allow less than full brightness; this constant means "the most allowed".
                try camera.setTorchModeOn(level: wanted == .high ? AVCaptureDevice.maxAvailableTorchLevel
                                                                 : wanted.level)
            }
            torchAsked = wanted
            return nil
        } catch {
            return "The light did not come on: \(error.localizedDescription)"
        }
    }

    /// Session queue only: nothing may be left shining on a camera that is no longer in use.
    private func darken() {
        if let camera = device, camera.hasTorch { _ = light(camera, .off) }
    }

    /// Whether the recorded frames are flipped. They must never be.
    var fileMirrored: Bool? { videoOutput.connection(with: .video)?.isVideoMirrored }

    /// iOS's own view of how stressed the camera system is, with the reasons when it is not at ease.
    var strain: String? {
        guard let state = device?.systemPressureState, session.isRunning else { return nil }
        let level: String
        switch state.level {
        case .nominal: level = "nominal"
        case .fair: level = "fair"
        case .serious: level = "serious"
        case .critical: level = "critical"
        case .shutdown: level = "shutdown"
        default: level = "unknown"
        }
        var reasons: [String] = []
        if state.factors.contains(.systemTemperature) { reasons.append("phone temperature") }
        if state.factors.contains(.cameraTemperature) { reasons.append("camera temperature") }
        if state.factors.contains(.peakPower) { reasons.append("power") }
        return reasons.isEmpty ? level : "\(level) (\(reasons.joined(separator: ", ")))"
    }

    /// Frames a second the camera is set to.
    var framesPerSecond: Int? {
        guard let duration = device?.activeVideoMinFrameDuration, session.isRunning, duration.seconds > 0
        else { return nil }
        return Int((1 / duration.seconds).rounded())
    }

    /// What the camera is using right now.
    var exposure: (iso: Double, seconds: Double)? {
        guard let device, session.isRunning else { return nil }
        return (Double(device.iso), device.exposureDuration.seconds)
    }

    func start(lens: Lens, completion: @escaping (Result<Void, Error>) -> Void) {
        sessionQueue.async { [self] in
            do {
                if !configured { try configureOutputs() }
                try select(lens)
                if !session.isRunning { session.startRunning() }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Stop the sensor altogether. `start` brings it back.
    func stop() {
        sessionQueue.async { [self] in
            darken()
            if session.isRunning { session.stopRunning() }
        }
    }

    /// The camera must already be locked for configuration.
    private static func run(_ camera: AVCaptureDevice, at fps: Int32) {
        let frame = CMTime(value: 1, timescale: fps)
        camera.activeVideoMinFrameDuration = frame
        camera.activeVideoMaxFrameDuration = frame
    }

    private func configureOutputs() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
        guard session.canAddOutput(videoOutput) else { throw RecorderError("The camera output is not available.") }
        session.addOutput(videoOutput)
        // The phone's sound is only for lining the take up with the Mac's microphone.
        if let microphone = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input),
           session.canAddOutput(audioOutput) {
            session.addInput(input)
            session.addOutput(audioOutput)
        }
        configured = true
    }

    private func select(_ lens: Lens) throws {
        let position: AVCaptureDevice.Position = lens == .back ? .back : .front
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw RecorderError("No \(lens.rawValue) camera.")
        }
        let usable = camera.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == Self.sensor.width && size.height == Self.sensor.height
                && CMFormatDescriptionGetMediaSubType(format.formatDescription)
                    == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
                && format.supportedColorSpaces.contains(.sRGB)
        }
        guard let format = usable.first(where: { !$0.isVideoBinned }) ?? usable.first else {
            throw RecorderError("This camera has no 4K 30 ordinary-colour mode.")
        }
        if camera.uniqueID != device?.uniqueID { darken() }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.video) }
            .forEach { session.removeInput($0) }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw RecorderError("The camera is in use.") }
        session.addInput(input)

        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        camera.activeFormat = format
        camera.activeColorSpace = .sRGB
        Self.run(camera, at: Self.idleFPS)
        if format.isVideoHDRSupported {
            camera.automaticallyAdjustsVideoHDREnabled = false
            camera.isVideoHDREnabled = false
        }
        camera.videoZoomFactor = 1
        Self.makeAutomatic(camera)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false   // the file is never mirrored; only the live previews are
            }
        }
        device = camera
        self.lens = lens
    }

    private static func makeAutomatic(_ camera: AVCaptureDevice) {
        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            camera.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    // MARK: - The look is held still for a take

    /// Mains lamps pulse at twice the mains frequency, so the shutter must be a whole number of
    /// pulses: 1/50 s or 1/100 s here. Brightness is kept the same by changing ISO.
    static func flickerFreeExposure(product: Double, minISO: Float, maxISO: Float, mainsHz: Int)
        -> (seconds: Double, iso: Float, note: String?) {
        let pulse = 1 / Double(mainsHz * 2)
        for pulses in [2.0, 1.0] {
            let seconds = pulses * pulse
            let iso = Float(product / seconds)
            if iso >= minISO {
                return iso <= maxISO ? (seconds, iso, nil) : (seconds, maxISO, "Too dark: add light")
            }
        }
        return (pulse, minISO, "Very bright: the take may be over-exposed")
    }

    /// Go to the take's frame rate, then lock focus, exposure and white balance at what the camera
    /// has settled on and report it. Nil when the camera cannot be set up, so no take is made.
    func lockForTake(completion: @escaping (CameraSettings?) -> Void) {
        sessionQueue.async { [self] in
            guard let camera = device, (try? camera.lockForConfiguration()) != nil else { return completion(nil) }
            Self.run(camera, at: Self.fps)
            camera.unlockForConfiguration()
            // The new rate takes a few frames to arrive, and exposure may move with it.
            Thread.sleep(forTimeInterval: 0.35)
            // Give focus and exposure a moment to finish moving before holding them.
            let deadline = Date().addingTimeInterval(1.5)
            while (camera.isAdjustingFocus || camera.isAdjustingExposure) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            do {
                try camera.lockForConfiguration()
            } catch {
                return completion(settings(note: "could not lock the camera", locked: false))
            }
            if camera.isFocusModeSupported(.locked) { camera.focusMode = .locked }
            if camera.isWhiteBalanceModeSupported(.locked) { camera.whiteBalanceMode = .locked }
            let done: (String?) -> Void = { [self] note in
                sessionQueue.async { [self] in completion(settings(note: note, locked: true)) }
            }
            if camera.isExposureModeSupported(.custom) {
                let format = camera.activeFormat
                let choice = Self.flickerFreeExposure(
                    product: camera.exposureDuration.seconds * Double(camera.iso),
                    minISO: format.minISO, maxISO: format.maxISO, mainsHz: Self.mainsHz)
                camera.setExposureModeCustom(duration: CMTime(seconds: choice.seconds, preferredTimescale: 1_000_000),
                                             iso: choice.iso) { _ in done(choice.note) }
                camera.unlockForConfiguration()
            } else {
                if camera.isExposureModeSupported(.locked) { camera.exposureMode = .locked }
                camera.unlockForConfiguration()
                done(nil)
            }
        }
    }

    /// After a take: everything automatic again, at the cooler rate.
    func unlock() {
        sessionQueue.async { [self] in
            guard let camera = device, (try? camera.lockForConfiguration()) != nil else { return }
            Self.run(camera, at: Self.idleFPS)
            Self.makeAutomatic(camera)
            camera.unlockForConfiguration()
        }
    }

    private func settings(note: String?, locked: Bool) -> CameraSettings {
        let camera = device
        var kelvin: Double?
        if let camera {
            var gains = camera.deviceWhiteBalanceGains
            let limit = camera.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), limit)
            gains.greenGain = min(max(gains.greenGain, 1), limit)
            gains.blueGain = min(max(gains.blueGain, 1), limit)
            kelvin = Double(camera.temperatureAndTintValues(for: gains).temperature)
        }
        return CameraSettings(width: Int(Self.sensor.height), height: Int(Self.sensor.width), fps: Int(Self.fps),
                              codec: "hevc", bitrate: Self.bitrate, lens: lens, colour: "sdr bt709",
                              hdr: camera?.isVideoHDREnabled ?? false, locked: locked,
                              shutterSeconds: camera?.exposureDuration.seconds, iso: camera.map { Double($0.iso) },
                              focusPosition: camera.map { Double($0.lensPosition) }, whiteBalanceKelvin: kelvin,
                              mainsHz: Self.mainsHz, note: note)
    }

    // MARK: - Recording

    func begin(_ recorder: TakeRecorder) {
        recorder.hostTime = { [session] time in
            guard let clock = session.synchronizationClock else { return time.seconds }
            return CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()).seconds
        }
        dataQueue.async { self.recorder = recorder }
    }

    func end(reason: String?, completion: @escaping (TakeManifest?) -> Void) {
        dataQueue.async { [self] in
            guard let finishing = recorder else { return completion(nil) }
            recorder = nil
            finishing.finish(reason: reason) { completion($0) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output === videoOutput
        if let recorder, !recorder.append(sample, isVideo: isVideo) {
            let why = "The iPhone could not keep writing the take."
            self.recorder = nil
            recorder.finish(reason: why) { [weak self] _ in self?.onRecordingFailed?(why) }
        }
        if isVideo {
            preview(sample)
            watch(sample)
        } else {
            measure(sample)
        }
    }

    /// Several times a second: report the exposure, and look for the lens being wiped.
    private func watch(_ sample: CMSampleBuffer) {
        lensFrames += 1
        guard lensFrames % 2 == 0 else { return }
        let now = HostClock.now
        if previewFPS > 0, now - exposureSentAt >= 0.25, let current = exposure {
            exposureSentAt = now
            onExposure?(current.iso, current.seconds)
        }
        if recorder == nil, let pixels = CMSampleBufferGetImageBuffer(sample), lensWatch.add(spread: Self.spread(pixels)) {
            onLensWiped?()
        }
    }

    /// How varied the brightness is across a grid of points: near nothing when the lens is covered.
    private static func spread(_ pixels: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.assumingMemoryBound(to: UInt8.self) else {
            return 255
        }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        var sum = 0.0, squares = 0.0
        let side = 40
        for y in 0..<side {
            for x in 0..<side {
                let value = Double(base[(y * height / side + height / side / 2) * row + x * width / side + width / side / 2])
                sum += value
                squares += value * value
            }
        }
        let count = Double(side * side)
        return max(0, squares / count - (sum / count) * (sum / count)).squareRoot()
    }

    private func measure(_ sample: CMSampleBuffer) {
        guard previewFPS > 0, let channel = audioOutput.connection(with: .audio)?.audioChannels.first else { return }
        loudest = max(loudest, pow(10, channel.peakHoldLevel / 20))
        let now = HostClock.now
        guard now - levelSentAt >= 0.1 else { return }
        levelSentAt = now
        onLevel?(MicLevel.decibels(loudest))
        loudest = 0
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput { recorder?.countDrop() }
    }

    /// A small JPEG for the Mac's preview. A frame is skipped whenever the last one is still being made.
    private func preview(_ sample: CMSampleBuffer) {
        let rate = previewFPS
        guard rate > 0, !previewBusy, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let now = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard now - lastPreview >= 1 / rate - 0.005 else { return }
        lastPreview = now
        previewBusy = true
        let stamp = CMSampleBufferGetPresentationTimeStamp(sample)
        let captured = session.synchronizationClock.map {
            CMSyncConvertTime(stamp, from: $0, to: CMClockGetHostTimeClock()).seconds
        } ?? stamp.seconds
        previewQueue.async { [self] in
            let image = CIImage(cvPixelBuffer: pixels)
            let scale = 540 / image.extent.width
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            if let data = picture.jpegRepresentation(of: small, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                     options: [quality: 0.55]) {
                onPreview?(data, captured)
            }
            dataQueue.async { self.previewBusy = false }
        }
    }
}
