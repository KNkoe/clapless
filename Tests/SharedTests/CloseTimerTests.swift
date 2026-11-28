import XCTest
@testable import ClaplessKit

final class CloseTimerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: Double) -> Date { start + seconds }

    func testNeverCountsWhileTheMacIsThere() {
        var timer = CloseTimer(now: start)
        XCTAssertNil(timer.secondsLeft(at: at(10_000), linked: true, busy: false))
        // The wait starts from when the Mac was last there, not from when the app opened.
        XCTAssertEqual(timer.secondsLeft(at: at(10_001), linked: false, busy: false), CloseTimer.withoutMac - 1)
    }

    func testClosesAfterAWhileWithoutAMac() throws {
        var timer = CloseTimer(now: start)
        XCTAssertEqual(timer.secondsLeft(at: at(299), linked: false, busy: false), 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(timer.secondsLeft(at: at(300), linked: false, busy: false)), 0)
    }

    func testDisconnectClosesSooner() throws {
        var timer = CloseTimer(now: start)
        timer.disconnected(at: at(100))
        // The link is still up for a moment after the goodbye.
        XCTAssertEqual(timer.secondsLeft(at: at(101), linked: true, busy: false), 89)
        XCTAssertLessThanOrEqual(try XCTUnwrap(timer.secondsLeft(at: at(190), linked: false, busy: false)), 0)
    }

    func testComingBackCancelsIt() {
        var timer = CloseTimer(now: start)
        timer.disconnected(at: at(100))
        timer.stay(at: at(150))
        XCTAssertNil(timer.disconnectDue)
        XCTAssertNil(timer.secondsLeft(at: at(1_000), linked: true, busy: false))
        timer.stay(at: at(2_000))
        XCTAssertEqual(timer.secondsLeft(at: at(2_010), linked: false, busy: false), CloseTimer.withoutMac - 10)
    }

    func testATakeIsNeverCutOff() {
        var timer = CloseTimer(now: start)
        XCTAssertNil(timer.secondsLeft(at: at(5_000), linked: false, busy: true))
        XCTAssertEqual(timer.secondsLeft(at: at(5_001), linked: false, busy: false), CloseTimer.withoutMac - 1)
        timer.disconnected(at: at(5_001))
        XCTAssertNil(timer.secondsLeft(at: at(9_000), linked: false, busy: true))
        XCTAssertEqual(timer.secondsLeft(at: at(9_001), linked: false, busy: false), CloseTimer.afterDisconnect - 1)
    }
}
