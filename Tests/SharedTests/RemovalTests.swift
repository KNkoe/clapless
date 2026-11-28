import XCTest
@testable import ClaplessKit

/// Deleting takes, on made-up folders in a temporary place. No real take is touched.
final class RemovalTests: XCTestCase {
    private var outside: URL!
    private var root: URL!

    override func setUpWithError() throws {
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("clapless-del-\(UUID().uuidString)")
        root = outside.appendingPathComponent("takes")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: outside)
    }

    private func make(_ take: String, files: [String: Int]) throws {
        for (name, bytes) in files {
            let file = root.appendingPathComponent(take).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: file)
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testSizeCountsEveryFileIncludingHiddenPieces() throws {
        try make("one", files: ["camera.mov": 3000, "mic.m4a": 200, ".incoming/segment-00000.m4s": 40])
        XCTAssertEqual(TakeRemoval.size(of: root.appendingPathComponent("one")), 3240)
        XCTAssertEqual(TakeRemoval.size(of: root.appendingPathComponent("missing")), 0)
    }

    func testRemovesOnlyTheTakeAskedFor() throws {
        try make("one", files: ["camera.mov": 10, ".incoming/manifest.json": 5])
        try make("two", files: ["camera.mov": 10])
        try TakeRemoval.remove("one", from: root)
        XCTAssertFalse(exists(root.appendingPathComponent("one")))
        XCTAssertTrue(exists(root.appendingPathComponent("two/camera.mov")))
        // Asking again is fine: the phone is asked until it answers.
        XCTAssertNoThrow(try TakeRemoval.remove("one", from: root))
    }

    func testNamesThatCouldReachElsewhereAreRefused() throws {
        try make("one", files: ["camera.mov": 10])
        try Data(count: 1).write(to: outside.appendingPathComponent("keep"))
        for name in ["", ".", "..", "../keep", "one/camera.mov", "/tmp", ".deleted.json"] {
            XCTAssertThrowsError(try TakeRemoval.remove(name, from: root), name)
        }
        XCTAssertTrue(exists(root.appendingPathComponent("one/camera.mov")))
        XCTAssertTrue(exists(outside.appendingPathComponent("keep")))
    }

    func testDeletesWaitingForThePhoneSurviveARestart() throws {
        let file = root.appendingPathComponent(".deleted.json")
        try DeletedTakes(file: file).add("one")
        try DeletedTakes(file: file).add("two")
        try DeletedTakes(file: file).add("one")
        XCTAssertEqual(DeletedTakes(file: file).all(), ["one", "two"])
        try DeletedTakes(file: file).remove("one")
        XCTAssertEqual(DeletedTakes(file: file).all(), ["two"])
    }

    func testTheDeleteMessagesSurviveTheTrip() throws {
        let ask = MacMessage.deleteTake(takeID: "one")
        XCTAssertEqual(try Coding.decoder.decode(MacMessage.self, from: Coding.encoder.encode(ask)), ask)
        let done = PhoneMessage.takeDeleted(takeID: "one")
        XCTAssertEqual(try Coding.decoder.decode(PhoneMessage.self, from: Coding.encoder.encode(done)), done)
    }
}
