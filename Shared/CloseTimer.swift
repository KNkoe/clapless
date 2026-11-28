import Foundation

/// When the iPhone app closes itself, so a phone nobody is filming with stops warming up.
struct CloseTimer {
    static let afterDisconnect = 90.0   // after Disconnect on the Mac
    static let withoutMac = 300.0       // with no Mac and nobody touching the phone

    private(set) var disconnectDue: Date?
    private var quietSince: Date

    init(now: Date = Date()) { quietSince = now }

    /// The Mac's Disconnect button.
    mutating func disconnected(at now: Date) { disconnectDue = now + Self.afterDisconnect }

    /// The Mac came back, the screen was tapped, or the app came forward again: start over.
    mutating func stay(at now: Date) {
        disconnectDue = nil
        quietSince = now
    }

    /// Seconds until the app should close, or nil while nothing is counting down. Zero or less means now.
    /// `busy` is a take being recorded or saved, or a pairing under way: neither is ever cut off, and
    /// the full wait starts again when it ends.
    mutating func secondsLeft(at now: Date, linked: Bool, busy: Bool) -> Double? {
        if busy {
            quietSince = now
            if disconnectDue != nil { disconnectDue = now + Self.afterDisconnect }
            return nil
        }
        // Counted even while the link is still up: the goodbye arrives just before it closes.
        if let disconnectDue { return disconnectDue.timeIntervalSince(now) }
        if linked {
            quietSince = now
            return nil
        }
        return quietSince.addingTimeInterval(Self.withoutMac).timeIntervalSince(now)
    }
}
