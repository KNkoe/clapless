import Network
import XCTest
@testable import ClaplessKit

final class PairingTests: XCTestCase {
    /// Two sessions wired straight to each other, with a chance to tamper with what travels.
    private func pair(tamper: @escaping (PairRole, PairMessage) -> PairMessage = { $1 })
        -> (mac: PairingSession, phone: PairingSession, pump: () -> Void) {
        var queue: [(PairRole, PairMessage)] = []
        let mac = PairingSession(role: .mac, name: "Mac") { queue.append((.mac, $0)) }
        let phone = PairingSession(role: .phone, name: "iPhone") { queue.append((.phone, $0)) }
        let pump = {
            while !queue.isEmpty {
                let (from, message) = queue.removeFirst()
                (from == .mac ? phone : mac).receive(tamper(from, message))
            }
        }
        return (mac, phone, pump)
    }

    private func code(_ session: PairingSession) -> String? {
        if case .compare(let code, _) = session.phase { return code }
        return nil
    }

    func testBothSidesShowTheSameCodeAndEndWithTheSameKey() throws {
        let (mac, phone, pump) = pair()
        mac.start(); pump()
        let shown = try XCTUnwrap(code(mac))
        XCTAssertEqual(shown, code(phone))
        XCTAssertEqual(shown.count, 6)
        mac.confirm(); pump()
        if case .done = phone.phase { XCTFail("the phone must not pair before its own confirmation") }
        if case .done = mac.phase { XCTFail("the Mac must not pair before the phone confirms") }
        phone.confirm(); pump()
        guard case .done(let a) = mac.phase, case .done(let b) = phone.phase else { return XCTFail("not paired") }
        XCTAssertEqual(a.key, b.key)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.key.count, 32)
        XCTAssertEqual(a.peerName, "iPhone")
    }

    func testPhoneRefusesAKeyThatDoesNotMatchTheCommitment() {
        let other = PairingSession.randomBytes(65)
        let (mac, phone, pump) = pair { _, message in
            if case .reveal(_, let nonce) = message { return .reveal(publicKey: other, nonce: nonce) }
            return message
        }
        mac.start(); pump()
        guard case .failed = phone.phase else { return XCTFail("a swapped key was accepted: \(phone.phase)") }
    }

    func testAManInTheMiddleGivesDifferentCodes() {
        // The attacker pairs separately with each side.
        var toAttackerFromMac: [PairMessage] = [], toAttackerFromPhone: [PairMessage] = []
        let mac = PairingSession(role: .mac, name: "Mac") { toAttackerFromMac.append($0) }
        let phone = PairingSession(role: .phone, name: "iPhone") { toAttackerFromPhone.append($0) }
        var attackerToPhone: [PairMessage] = [], attackerToMac: [PairMessage] = []
        let asMac = PairingSession(role: .mac, name: "Mac") { attackerToPhone.append($0) }
        let asPhone = PairingSession(role: .phone, name: "iPhone") { attackerToMac.append($0) }
        mac.start(); asMac.start()
        for _ in 0..<6 {
            while !toAttackerFromMac.isEmpty { asPhone.receive(toAttackerFromMac.removeFirst()) }
            while !attackerToMac.isEmpty { mac.receive(attackerToMac.removeFirst()) }
            while !attackerToPhone.isEmpty { phone.receive(attackerToPhone.removeFirst()) }
            while !toAttackerFromPhone.isEmpty { asMac.receive(toAttackerFromPhone.removeFirst()) }
        }
        XCTAssertNotNil(code(mac))
        XCTAssertNotNil(code(phone))
        XCTAssertNotEqual(code(mac), code(phone))   // fails by chance once in a million runs
    }

    func testAForgedConfirmationIsRefused() {
        let (mac, phone, pump) = pair { _, message in
            if case .confirm = message { return .confirm(proof: PairingSession.randomBytes(32)) }
            return message
        }
        mac.start(); pump()
        mac.confirm(); phone.confirm(); pump()
        if case .done = mac.phase { XCTFail("paired with a forged proof") }
        if case .done = phone.phase { XCTFail("paired with a forged proof") }
    }
}

/// Real sockets on this Mac: the right key gets in, anything else does not.
final class LinkSecurityTests: XCTestCase {
    private let queue = DispatchQueue(label: "link-tests")

    private func record(_ id: String = "pair-a", key: Data = PairingSession.randomBytes(32)) -> PairRecord {
        PairRecord(id: id, key: key, peerName: "test", pairedAt: Date())
    }

    /// Returns what the server received, or nil if nothing got through within the wait.
    private func attempt(server: PairRecord, client: NWParameters, wait: TimeInterval = 4) throws -> String? {
        let listener = try NWListener(using: LinkParameters.secure([server], peerToPeer: false), on: .any)
        var received: String?
        var held: [FramedLink] = []
        let got = expectation(description: "frame")
        got.assertForOverFulfill = false
        let listening = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            let link = FramedLink(connection, queue: self.queue)
            link.onFrame = { _, data in received = String(decoding: data, as: UTF8.self); got.fulfill() }
            held.append(link)
            link.start()
        }
        listener.start(queue: queue)
        wait_(for: [listening], timeout: 3)
        let link = FramedLink(NWConnection(host: "127.0.0.1", port: listener.port!, using: client), queue: queue)
        link.onReady = { link.send(.message, Data("start recording".utf8)) }
        link.start()
        _ = XCTWaiter().wait(for: [got], timeout: wait)
        link.close(); listener.cancel(); held.forEach { $0.close() }
        return queue.sync { received }
    }

    private func wait_(for expectations: [XCTestExpectation], timeout: TimeInterval) {
        wait(for: expectations, timeout: timeout)
    }

    func testThePairedKeyConnects() throws {
        let pair = record()
        XCTAssertEqual(try attempt(server: pair, client: LinkParameters.secure([pair], peerToPeer: false)), "start recording")
    }

    func testAWrongKeyIsRefused() throws {
        let pair = record()
        XCTAssertNil(try attempt(server: pair, client: LinkParameters.secure([record()], peerToPeer: false)))
    }

    func testAnUnencryptedConnectionIsRefused() throws {
        XCTAssertNil(try attempt(server: record(), client: LinkParameters.pairing(peerToPeer: false)))
    }
}

final class TakeFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clapless-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func sampleTake(_ sizes: [Int]) throws -> (TakeDirectory, TakeManifest, [Data]) {
        let phone = TakeDirectory(url: root.appendingPathComponent("phone"))
        try phone.create()
        let pieces = sizes.map { PairingSession.randomBytes($0) }
        let segments = try pieces.enumerated().map { try phone.store(segment: $1, index: $0) }
        let camera = CameraSettings(width: 2160, height: 3840, fps: 30, codec: "hevc", bitrate: 45_000_000, lens: .back,
                                    colour: "bt709", hdr: false, locked: true, shutterSeconds: 0.02, iso: 100,
                                    focusPosition: 0.5, whiteBalanceKelvin: 5000, mainsHz: 50, note: nil)
        let manifest = TakeManifest(takeID: "t1", created: Date(timeIntervalSince1970: 1_800_000_000), complete: true,
                                    segments: segments, sha256: Hashing.sha256(pieces.reduce(Data(), +)), seconds: 4,
                                    frames: 120, droppedFrames: 0, firstFrameHostTime: 12.5, audioStartOffset: 0.01,
                                    endReason: nil, camera: camera, verifiedByMac: false)
        try phone.write(manifest)
        return (phone, manifest, pieces)
    }

    private func download(_ data: Data, _ segment: SegmentInfo, into mac: TakeDirectory, stopAfter: Int = .max) throws -> Bool {
        var offset = 0, sent = 0, finished = false
        while offset < data.count && sent < stopAfter {
            let piece = data.subdata(in: offset..<min(offset + 100, data.count))
            let payload = try Framing.chunk(ChunkHeader(takeID: "t1", index: segment.index, offset: offset,
                                                        total: data.count), piece)
            let (header, bytes) = try XCTUnwrap(Framing.parseChunk(payload))
            finished = try mac.append(header, bytes, expecting: segment)
            offset += piece.count
            sent += 1
        }
        return finished
    }

    func testADownloadThatIsCutOffCarriesOnAndJoinsExactly() throws {
        let (phone, manifest, pieces) = try sampleTake([40, 1000, 730])
        XCTAssertEqual(phone.readManifest(), manifest)
        let mac = TakeDirectory(url: root.appendingPathComponent("mac"))
        try mac.create()
        XCTAssertTrue(try download(pieces[0], manifest.segments[0], into: mac))
        XCTAssertFalse(try download(pieces[1], manifest.segments[1], into: mac, stopAfter: 3))   // the Wi-Fi drops
        XCTAssertEqual(manifest.segments.filter { !mac.holds($0) }.map(\.index), [1, 2])
        for i in 1...2 { XCTAssertTrue(try download(pieces[i], manifest.segments[i], into: mac)) }
        let joined = root.appendingPathComponent("joined.mp4")
        try mac.join(manifest, to: joined)
        XCTAssertEqual(try Data(contentsOf: joined), pieces.reduce(Data(), +))
    }

    func testDamagedSegmentsAreRejected() throws {
        let (_, manifest, pieces) = try sampleTake([40, 500])
        let mac = TakeDirectory(url: root.appendingPathComponent("mac"))
        try mac.create()
        var damaged = pieces[1]
        damaged[7] ^= 0xFF
        XCTAssertThrowsError(try download(damaged, manifest.segments[1], into: mac)) {
            XCTAssertEqual($0 as? TakeFileError, .badSegment(1))
        }
        XCTAssertFalse(mac.holds(manifest.segments[1]))
    }

    func testJoinRefusesAChangedFileAndAnUnfinishedTake() throws {
        var (phone, manifest, _) = try sampleTake([40, 500])
        let joined = root.appendingPathComponent("joined.mp4")
        try Data(repeating: 1, count: 500).write(to: phone.segmentURL(1))
        XCTAssertThrowsError(try phone.join(manifest, to: joined))
        manifest.complete = false
        XCTAssertThrowsError(try phone.join(manifest, to: joined)) { XCTAssertEqual($0 as? TakeFileError, .incomplete) }
    }

    func testAnInterruptedTakeIsSalvagedUpToTheLastWholeSegment() throws {
        var (phone, manifest, pieces) = try sampleTake([40, 500, 600, 700])
        manifest.complete = false
        manifest.sha256 = nil
        try phone.write(manifest)
        try Data(pieces[3].prefix(100)).write(to: phone.segmentURL(3))   // cut off while saving
        let saved = try XCTUnwrap(phone.salvage())
        XCTAssertEqual(saved.segments.map(\.index), [0, 1, 2])
        XCTAssertTrue(saved.complete)
        XCTAssertNotNil(saved.endReason)
        let joined = root.appendingPathComponent("joined.mp4")
        try phone.join(saved, to: joined)
        XCTAssertEqual(try Data(contentsOf: joined), pieces[0] + pieces[1] + pieces[2])
        XCTAssertNil(phone.salvage(), "a closed take is left alone")
    }

    func testAnOlderTakeFileStillReads() throws {
        let old = #"{"app":"Clapless","version":1,"take":"t","created":"2026-11-26T10:47:40Z","status":"ready","clock":[],"warnings":[],"sync":{"method":"clock estimate only","cameraStartMinusMicStart":0.22,"uncertaintySeconds":0.1,"matchedBySound":false}}"#
        let record = try Coding.decoder.decode(TakeRecord.self, from: Data(old.utf8))
        XCTAssertNil(record.screen)
        XCTAssertNil(record.sync?.tried)
    }

    func testAPreviewFrameCarriesWhenItWasCaptured() throws {
        let jpeg = Data([0xFF, 0xD8, 1, 2, 3])
        let frame = try XCTUnwrap(Framing.parsePreview(Framing.preview(jpeg, captured: 345_678.25)))
        XCTAssertEqual(frame.captured, 345_678.25)
        XCTAssertEqual(frame.jpeg, jpeg)
        XCTAssertNil(Framing.parsePreview(Data([1, 2, 3])))
    }

    func testBadFramesAreRejected() {
        XCTAssertNil(Framing.parse(header: Data([0xFF, 0xFF, 0xFF, 0xFF, 1])))
        XCTAssertNil(Framing.parse(header: Data([0, 0, 0, 1, 9])))
        XCTAssertNil(Framing.parseChunk(Data([0, 0, 3, 232, 1])))
        XCTAssertEqual(Framing.parse(header: Framing.header(type: .chunk, length: 70_000))?.length, 70_000)
    }
}

final class MicLevelTests: XCTestCase {
    func testSilenceBecomesNoSoundAfterThreeSecondsAndSoundBringsItBack() {
        var level = MicLevel()
        level.reset(at: 0)
        level.add(peakDB: -120, at: 0.1)
        XCTAssertEqual(level.state(at: 2.9), .connected)
        XCTAssertEqual(level.state(at: 3.1), .noSound)
        level.add(peakDB: -20, at: 3.2)
        XCTAssertEqual(level.state(at: 3.3), .connected)
        XCTAssertEqual(level.state(at: 6.3), .noSound)   // buffers stopped arriving
    }

    func testPeakHoldsThenFallsAndCellsMatchTheDesignColours() {
        var level = MicLevel()
        level.add(peakDB: -6, at: 0)
        level.add(peakDB: -40, at: 1)
        XCTAssertEqual(level.peak, -6, accuracy: 0.001)
        XCTAssertLessThan(level.bar, -6)
        level.add(peakDB: -40, at: 3)
        XCTAssertLessThan(level.peak, -6)
        XCTAssertEqual(MicLevel.litCells(-60), 0)
        XCTAssertEqual(MicLevel.litCells(0), 28)
        XCTAssertEqual(MicLevel.litCells(-100), 0)
        XCTAssertEqual(MicLevel.decibels(1), 0, accuracy: 0.001)
        XCTAssertEqual(MicLevel.decibels(0), -160)
    }
}

final class TorchTests: XCTestCase {
    func testOnReturnsToTheLastBrightnessAndBrightnessNeverSwitchesOff() {
        XCTAssertEqual(Torch.off.toggled(lastUsed: .medium), .medium)
        XCTAssertEqual(Torch.off.toggled(lastUsed: .off), .low)
        XCTAssertEqual(Torch.high.toggled(lastUsed: .high), .off)
        XCTAssertEqual([Torch.low, .medium, .high].map(\.nextBrightness), [.medium, .high, .low])
        XCTAssertEqual(Torch.allCases.map(\.level), Torch.allCases.map(\.level).sorted())
    }
}
