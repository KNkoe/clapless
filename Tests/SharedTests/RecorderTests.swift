import AVFoundation
import XCTest
@testable import ClaplessKit

/// The phone's real recorder fed with made-up pictures and tones, then taken through the same steps
/// the Mac uses. No camera or microphone is touched.
final class RecorderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clapless-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private static let startOfClock = 345_678.25   // like a phone that has been on for four days
    private static let flashFrame = 90             // 3 s; the beep starts at exactly the same moment

    private func picture(_ index: Int, width: Int, height: Int) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            // One bright frame at three seconds marks a moment to compare the sound with.
            memset(base, Int32(plane == 0 ? (index == Self.flashFrame ? 235 : 40) : 128),
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: Self.startOfClock + Double(index) / 30, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    private func tone(_ index: Int, frames: Int = 1024) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
            mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let values: [Int16] = (0..<frames).map {
            let sample = index * frames + $0
            let time = Double(sample) / 48_000 - 0.05        // relative to the first picture
            let beep = time >= 3.0 && time < 3.2
            return beep ? Int16(12_000 * sin(Double(sample) * 0.4)) : 0
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 2, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: frames * 2, flags: 0,
                                           blockBufferOut: &block)
        _ = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                                          dataLength: frames * 2)
        }
        var sample: CMSampleBuffer?
        // The sound starts a little before the first picture, as it can on the phone.
        let at = CMTime(seconds: Self.startOfClock - 0.05 + Double(index * frames) / 48_000,
                        preferredTimescale: 1_000_000_000)
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: at, packetDescriptions: nil, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    func testSegmentsFromTheRealRecorderJoinIntoACameraFileThatStartsAtZero() async throws {
        let seconds = 7, width = 540, height = 960
        let phone = TakeDirectory(url: root.appendingPathComponent("phone"))
        let settings = CameraSettings(width: width, height: height, fps: 30, codec: "hevc", bitrate: 4_000_000, lens: .back,
                                      colour: "sdr bt709", hdr: false, locked: true, shutterSeconds: 0.02, iso: 100,
                                      focusPosition: 0.5, whiteBalanceKelvin: 5000, mainsHz: 50, note: nil)
        let recorder = try TakeRecorder(directory: phone, takeID: "t1", camera: settings)
        var seen: [Int] = []
        let seenLock = NSLock()
        recorder.onManifest = { manifest in seenLock.withLock { seen.append(manifest.segments.count) } }
        var sound = 0
        for frame in 0..<(seconds * 30) {
            // Paced a little faster than real time, so the encoder is never flooded.
            try await Task.sleep(for: .milliseconds(12))
            XCTAssertTrue(recorder.append(try picture(frame, width: width, height: height), isVideo: true))
            while Double(sound * 1024) / 48_000 - 0.05 < Double(frame + 1) / 30 {
                XCTAssertTrue(recorder.append(try tone(sound), isVideo: false))
                sound += 1
            }
        }
        let manifest: TakeManifest = await withCheckedContinuation { done in
            recorder.finish(reason: nil) { done.resume(returning: $0) }
        }
        XCTAssertTrue(manifest.complete, manifest.endReason ?? "")
        XCTAssertGreaterThanOrEqual(manifest.segments.count, 4, "a header and about one segment every two seconds")
        XCTAssertGreaterThan(seenLock.withLock { seen.count }, 3, "segments are announced while recording")
        XCTAssertEqual(phone.readManifest()?.sha256, manifest.sha256)
        XCTAssertEqual(manifest.frames + manifest.droppedFrames, seconds * 30)
        XCTAssertEqual(try XCTUnwrap(manifest.firstFrameHostTime), Self.startOfClock, accuracy: 0.001)

        let joined = root.appendingPathComponent("joined.mp4")
        try phone.join(manifest, to: joined)
        let movie = root.appendingPathComponent("camera.mov")
        let result = try await CameraFile.make(from: joined, to: movie, audioOffset: manifest.audioStartOffset)
        XCTAssertEqual(result.videoSamples, manifest.frames)
        XCTAssertEqual(result.seconds, Double(seconds), accuracy: 0.15)

        let asset = AVURLAsset(url: movie)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let video = try XCTUnwrap(videoTracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: width, height: height))
        let start = try await video.load(.timeRange).start
        XCTAssertEqual(start.seconds, 0, accuracy: 0.001)

        // Picture and sound must still line up in the finished file.
        let flash = try await firstBrightPicture(movie)
        let beep = try await firstLoudSound(movie)
        XCTAssertEqual(flash, 3.0, accuracy: 0.002)
        XCTAssertEqual(beep - flash, 0, accuracy: 0.008, "picture and sound drifted apart")

        // For checking by eye with ffprobe: CLAPLESS_KEEP=/some/folder swift test
        if let keep = ProcessInfo.processInfo.environment["CLAPLESS_KEEP"] {
            try FileManager.default.copyItem(at: movie, to: URL(fileURLWithPath: keep).appendingPathComponent("camera.mov"))
            try FileManager.default.copyItem(at: joined, to: URL(fileURLWithPath: keep).appendingPathComponent("joined.mp4"))
        }
    }

    private func decoded(_ url: URL, _ type: AVMediaType, _ settings: [String: Any],
                         find: (CMSampleBuffer) -> Double?) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: type)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            if let found = find(sample) {
                reader.cancelReading()
                return found
            }
        }
        XCTFail("nothing found in \(type.rawValue)")
        return -1
    }

    private func firstBrightPicture(_ url: URL) async throws -> Double {
        try await decoded(url, .video, [kCVPixelBufferPixelFormatTypeKey as String:
                                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]) { sample in
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return nil }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.load(fromByteOffset: 100, as: UInt8.self)
            return luma > 150 ? CMSampleBufferGetPresentationTimeStamp(sample).seconds : nil
        }
    }

    private func firstLoudSound(_ url: URL) async throws -> Double {
        try await decoded(url, .audio, [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                        AVSampleRateKey: 48_000]) { sample in
            guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard let index = values.firstIndex(where: { abs($0) > 0.15 }) else { return nil }
            return CMSampleBufferGetPresentationTimeStamp(sample).seconds + Double(index) / 48_000
        }
    }
}
