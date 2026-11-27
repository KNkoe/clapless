import AVFoundation
import XCTest
@testable import ClaplessKit

/// The Mac's microphone and screen writers, fed with made-up sound and pictures on one clock.
/// Nothing on this Mac is recorded.
final class MacCaptureTests: XCTestCase {
    private var root: URL!
    private static let start = 50_000.0       // the moment, on the host clock, the take begins
    private static let event = 50_003.0       // a flash on screen and a beep, at the same moment

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clapless-mac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    /// 1024 samples of float sound starting at `hostTime`, stamped on a session clock offset from it.
    private func sound(_ hostTime: Double, frames: Int = 1024, clockBehind: Double = 1_000) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32,
            mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let values: [Float] = (0..<frames).map {
            let time = hostTime + Double($0) / 48_000
            return time >= Self.event && time < Self.event + 0.2 ? Float(0.4 * sin(Double($0) * 0.4)) : 0
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 4, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: frames * 4, flags: 0,
                                           blockBufferOut: &block)
        _ = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                                          dataLength: frames * 4)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: hostTime - clockBehind, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    private func picture(bright: Bool) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 400, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, Int32(plane == 0 ? (bright ? 235 : 40) : 128),
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func ffmpeg(_ arguments: [String]) throws -> Data {
        let tool = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path), "ffmpeg is not installed")
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-v", "error"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    func testTheMicrophoneFileBeginsAtTheChosenMomentToTheMillisecond() async throws {
        let url = root.appendingPathComponent("mic.m4a")
        let writer = MicWriter(url: url)
        var time = Self.start - 1.3137        // the microphone has been listening for a while
        var announced = false
        while time < Self.start + 6 {
            writer.append(try sound(time), hostTime: time)
            time += 1024.0 / 48_000
            // The start becomes known a little after it happened, as with the screen's first picture.
            if !announced, time > Self.start + 0.4 {
                writer.begin(at: Self.start)
                announced = true
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        let result: MicWriter.Result? = await withCheckedContinuation { done in writer.finish { done.resume(returning: $0) } }
        let saved = try XCTUnwrap(result, writer.failure ?? "nothing written")
        XCTAssertEqual(saved.firstSampleHostTime, Self.start, accuracy: 0.0001)
        XCTAssertEqual(saved.seconds, 6, accuracy: 0.05)
        XCTAssertEqual(writer.droppedBuffers, 0)

        // Read it the way the editing skill does.
        let raw = try ffmpeg(["-i", url.path, "-af", "aresample=48000:async=1:first_pts=0", "-ac", "1", "-f", "f32le", "-"])
        let values = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let beep = try XCTUnwrap(values.firstIndex { abs($0) > 0.15 })
        XCTAssertEqual(Double(beep) / 48_000, Self.event - Self.start, accuracy: 0.003, "the voice is shifted in mic.m4a")
    }

    func testSoundStaysInPlaceWhenAnotherMicrophoneTakesOverAfterAGap() async throws {
        try await checkJoin(secondMicStarts: Self.start + 2.6)
    }

    func testSoundStaysInPlaceWhenTheNextMicrophoneOverlapsTheLast() async throws {
        try await checkJoin(secondMicStarts: Self.start + 1.7)
    }

    /// Two seconds from one microphone, then another with its own clock, which hears the beep.
    private func checkJoin(secondMicStarts: Double) async throws {
        let url = root.appendingPathComponent("mic.m4a")
        let writer = MicWriter(url: url)
        writer.begin(at: Self.start)
        let step = 1024.0 / 48_000
        for time in stride(from: Self.start, to: Self.start + 2, by: step) {
            writer.append(try sound(time), hostTime: time)
            try await Task.sleep(for: .milliseconds(2))
        }
        writer.sourceChanged()
        for time in stride(from: secondMicStarts, to: Self.start + 6, by: step) {
            writer.append(try sound(time, clockBehind: 31_000), hostTime: time)
            try await Task.sleep(for: .milliseconds(2))
        }
        let result: MicWriter.Result? = await withCheckedContinuation { done in writer.finish { done.resume(returning: $0) } }
        let saved = try XCTUnwrap(result, writer.failure ?? "nothing written")
        XCTAssertNil(writer.failure)
        XCTAssertEqual(saved.seconds, 6, accuracy: 0.05)
        XCTAssertEqual(writer.droppedBuffers, 0)
        let raw = try ffmpeg(["-i", url.path, "-af", "aresample=48000:async=1:first_pts=0", "-ac", "1", "-f", "f32le", "-"])
        let values = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(Double(values.count) / 48_000, 6, accuracy: 0.08)
        let beep = try XCTUnwrap(values.firstIndex { abs($0) > 0.15 })
        XCTAssertEqual(Double(beep) / 48_000, Self.event - Self.start, accuracy: 0.003, "the join shifted the sound")
    }

    func testTheChosenMicrophoneIsUsedAndTheMacDefaultStandsIn() {
        let builtIn = MicChoice.Candidate(id: "mac", builtIn: true)
        let wireless = MicChoice.Candidate(id: "wireless", builtIn: false)
        let usb = MicChoice.Candidate(id: "usb", builtIn: false)
        let all = [usb, builtIn, wireless]
        XCTAssertEqual(MicChoice.pick(chosen: "wireless", systemDefault: "usb", among: all), "wireless")
        XCTAssertEqual(MicChoice.pick(chosen: "wireless", systemDefault: "usb", among: [usb, builtIn]), "usb")
        XCTAssertEqual(MicChoice.pick(chosen: nil, systemDefault: "usb", among: all), "usb")
        // The default is something never offered, such as an iPhone.
        XCTAssertEqual(MicChoice.pick(chosen: "wireless", systemDefault: "iphone", among: [usb, builtIn]), "mac")
        XCTAssertEqual(MicChoice.pick(chosen: nil, systemDefault: nil, among: [usb]), "usb")
        XCTAssertNil(MicChoice.pick(chosen: "wireless", systemDefault: nil, among: []))
    }

    func testATakeDoesNotMoveBackToAMicrophoneThatReturns() {
        let builtIn = MicChoice.Candidate(id: "mac", builtIn: true)
        let wireless = MicChoice.Candidate(id: "wireless", builtIn: false)
        XCTAssertEqual(MicChoice.pickDuringTake(current: "mac", chosen: "wireless", systemDefault: "wireless",
                                                among: [builtIn, wireless]), "mac")
        XCTAssertEqual(MicChoice.pickDuringTake(current: "wireless", chosen: "wireless", systemDefault: "mac",
                                                among: [builtIn]), "mac")
    }

    func testTheWorstHeatOfATakeIsKept() {
        func status(_ heat: Heat, _ strain: String, _ processor: Double) -> PhoneStatus {
            PhoneStatus(name: "p", model: "iPhone", state: .recording, seconds: 0, lens: .back, freeBytes: 1,
                        bytesPerSecond: 1, battery: 1, charging: false, heat: heat, droppedFrames: 0,
                        processor: processor, cameraStrain: strain)
        }
        var log = TakeRecord.PhoneHeat(status(.fair, "nominal", 10))
        log.add(status(.serious, "serious (phone temperature)", 20))
        log.add(status(.fair, "fair (power)", 30))
        XCTAssertEqual(log.atStart, .fair)
        XCTAssertEqual(log.worst, .serious)
        XCTAssertEqual(log.worstCameraStrain, "serious (phone temperature)")
        XCTAssertEqual(try XCTUnwrap(log.averageProcessorPercent), 20, accuracy: 0.001)
    }

    func testTheScreenFileIsSteadyAndChangesAtTheRightFrame() async throws {
        let url = root.appendingPathComponent("screen.mp4")
        let writer = ScreenWriter(url: url, width: 640, height: 400)
        writer.show(try picture(bright: false), at: Self.start)
        var shown = false
        var now = Self.start
        while now < Self.start + 5 {
            // Nothing changes on screen until the flash; it is delivered a little late.
            if !shown, now > Self.event + 0.05 {
                writer.show(try picture(bright: true), at: Self.event)
                shown = true
            }
            writer.advance(to: now)
            now += 1.0 / 30
            try await Task.sleep(for: .milliseconds(8))
        }
        let result: ScreenWriter.Result? = await withCheckedContinuation { done in
            writer.finish(at: Self.start + 5) { done.resume(returning: $0) }
        }
        let saved = try XCTUnwrap(result, writer.failure ?? "nothing written")
        XCTAssertEqual(saved.firstFrameHostTime, Self.start)
        XCTAssertEqual(saved.seconds, 5, accuracy: 0.05)
        XCTAssertEqual(saved.skippedFrames, 0)

        let luma = try ffmpeg(["-i", url.path, "-vf", "scale=1:1,format=gray", "-f", "rawvideo", "-"])
        XCTAssertEqual(luma.count, saved.frames)
        XCTAssertEqual(saved.frames, 151, accuracy: 1)
        let flash = try XCTUnwrap(luma.firstIndex { $0 > 150 })
        XCTAssertEqual(flash, 90, "the picture changed on the wrong frame")
        let length = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(length, 5, accuracy: 0.07)
    }

    private func talk(_ voice: inout VoiceLevel, amplitude: Double, seconds: Int) {
        for half in 0..<(seconds * 2) {
            let now = half % 4 < 2 ? amplitude : 0.0002           // a second of talk, a second of room
            voice.add(sumOfSquares: now * now / 2 * 24_000, samples: 24_000, rate: 48_000)
        }
    }

    func testAQuietVoiceIsNoticedAndSilenceIsNot() {
        var quiet = VoiceLevel(), loud = VoiceLevel(), silent = VoiceLevel()
        talk(&quiet, amplitude: 0.008, seconds: 16)       // about -45 dB
        talk(&loud, amplitude: 0.12, seconds: 16)         // about -21 dB
        talk(&silent, amplitude: 0.0002, seconds: 16)
        XCTAssertTrue(quiet.isQuiet)
        XCTAssertFalse(loud.isQuiet)
        XCTAssertNil(silent.speechDB, "a silent room is not a quiet voice")
    }

    func testTheQuietVoiceWarningClearsAsSoonAsTheVoiceIsRaisedOrStops() {
        var raised = VoiceLevel()
        talk(&raised, amplitude: 0.008, seconds: 16)
        talk(&raised, amplitude: 0.12, seconds: 1)
        XCTAssertFalse(raised.isQuiet, "one second of speaking up is enough")
        var stopped = VoiceLevel()
        talk(&stopped, amplitude: 0.008, seconds: 16)
        talk(&stopped, amplitude: 0.0002, seconds: 7)
        XCTAssertFalse(stopped.isQuiet, "an old quiet sentence is forgotten")
    }

    func testCoveringAndUncoveringTheLensCountsAsAWipeOnce() {
        var lens = LensWatch()
        XCTAssertFalse([40, 45, 38].contains { lens.add(spread: $0) })      // an ordinary room
        XCTAssertFalse([3, 2, 4, 9, 12].contains { lens.add(spread: $0) })  // cloth on, coming away
        XCTAssertTrue(lens.add(spread: 35))
        XCTAssertFalse(lens.add(spread: 35))
        XCTAssertFalse([2, 40].contains { lens.add(spread: $0) }, "a single flat reading is not a wipe")
    }

    func testDarkRoomsAreNoticedWhateverShutterTheCameraIsUsing() {
        XCTAssertNotNil(LightAdvice.warning(iso: 1810, shutterSeconds: 0.02))
        XCTAssertNotNil(LightAdvice.warning(iso: 1100, shutterSeconds: 1.0 / 30))
        XCTAssertNil(LightAdvice.warning(iso: 400, shutterSeconds: 0.02))
        XCTAssertNil(LightAdvice.warning(iso: 1200, shutterSeconds: 0.02))
        XCTAssertEqual(LightAdvice.reading(iso: 1200, shutterSeconds: 0.02)?.level, .dim)
        XCTAssertEqual(LightAdvice.reading(iso: 700, shutterSeconds: 0.02)?.level, .good)
        XCTAssertNil(LightAdvice.warning(iso: 900, shutterSeconds: 0.01))
        XCTAssertNil(LightAdvice.warning(iso: nil, shutterSeconds: 0.02))
    }
}

/// The sums behind recording a single app, with made-up window positions.
final class AppCropTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testASmallPanelInFrontDoesNotTakeOverThePicture() {
        let panel = CGRect(x: 500, y: 300, width: 420, height: 260)
        let window = CGRect(x: 100, y: 80, width: 1100, height: 800)
        let helper = CGRect(x: 0, y: 0, width: 40, height: 20)
        XCTAssertEqual(AppCrop.main([helper, panel, window]), window)
        XCTAssertNil(AppCrop.main([helper]))
    }

    func testTheFrontOneOfTwoSimilarWindowsIsFollowed() {
        let front = CGRect(x: 600, y: 100, width: 800, height: 700)
        let behind = CGRect(x: 0, y: 40, width: 1200, height: 900)
        XCTAssertEqual(AppCrop.main([front, behind]), front)
    }

    func testTheCropIsMeasuredFromItsOwnScreen() throws {
        let second = CGRect(x: 1512, y: -100, width: 1920, height: 1080)
        let window = CGRect(x: 1612, y: 0, width: 900, height: 600)
        XCTAssertEqual(AppCrop.display(for: window, among: [screen, second]), 1)
        XCTAssertEqual(AppCrop.source(window: window, display: second),
                       CGRect(x: 100, y: 100, width: 900, height: 600))
        // Hanging off the edge: only the part that can be seen.
        let hanging = CGRect(x: 1200, y: 100, width: 600, height: 500)
        XCTAssertEqual(AppCrop.source(window: hanging, display: screen), CGRect(x: 1200, y: 100, width: 312, height: 500))
        XCTAssertNil(AppCrop.display(for: CGRect(x: -900, y: 0, width: 500, height: 400), among: [screen]))
    }

    func testTheFileSizeIsSharpEvenAndNotTooWide() {
        let full = AppCrop.pixels(of: screen.size, scale: 2, widest: 3024)
        XCTAssertEqual([full.width, full.height], [3024, 1964])
        let window = AppCrop.pixels(of: CGSize(width: 801.5, height: 600.5), scale: 2, widest: 3024)
        XCTAssertEqual([window.width, window.height], [1602, 1200])
        let huge = AppCrop.pixels(of: CGSize(width: 2560, height: 1440), scale: 2, widest: 3024)
        XCTAssertEqual([huge.width, huge.height], [3024, 1700])
    }
}
