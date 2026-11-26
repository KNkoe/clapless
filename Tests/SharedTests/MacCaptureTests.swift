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
    private func sound(_ hostTime: Double, frames: Int = 1024) throws -> CMSampleBuffer {
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
            presentationTimeStamp: CMTime(seconds: hostTime - 1_000, preferredTimescale: 48_000),
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
