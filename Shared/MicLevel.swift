import Foundation

enum MicState: Equatable {
    case notConnected   // no chosen microphone, or it is unplugged: Start is off
    case noSound        // chosen and present, but nothing is coming through
    case connected
}

/// Turns raw peak readings into what the level bar shows. Time is passed in, so it can be tested.
struct MicLevel {
    static let floorDB = -60.0
    static let cells = 28
    /// Below this for `silenceAfter` seconds means "No sound". A live microphone in a quiet room
    /// sits above it; a receiver whose transmitter is off sends near-digital silence.
    static let silenceDB = -65.0
    static let silenceAfter = 3.0
    private static let fall = 24.0      // dB per second the bar drops
    private static let hold = 1.5       // seconds the peak marker stays

    private(set) var bar = floorDB
    private(set) var peak = floorDB
    private var peakAt = 0.0
    private var updatedAt: Double?
    private var heardAt: Double?
    private var startedAt: Double?

    mutating func reset(at now: Double) {
        self = MicLevel()
        startedAt = now
    }

    static func decibels(_ linearPeak: Float) -> Double {
        linearPeak > 0 ? max(-160, 20 * log10(Double(linearPeak))) : -160
    }

    /// One buffer of audio arrived with this loudest sample.
    mutating func add(peakDB: Double, at now: Double) {
        if startedAt == nil { startedAt = now }
        decay(to: now)
        let shown = min(0, max(Self.floorDB, peakDB))
        bar = max(bar, shown)
        if shown >= peak || now - peakAt > Self.hold {
            peak = shown
            peakAt = now
        }
        if peakDB > Self.silenceDB { heardAt = now }
    }

    mutating func decay(to now: Double) {
        if let updatedAt { bar = max(Self.floorDB, bar - Self.fall * max(0, now - updatedAt)) }
        updatedAt = now
        if now - peakAt > Self.hold { peak = max(bar, peak - Self.fall * 0.1) }
    }

    /// State for a microphone that is present. Buffers that stop arriving count as silence too.
    func state(at now: Double) -> MicState {
        guard let startedAt else { return .connected }
        let quietSince = heardAt ?? startedAt
        return now - quietSince >= Self.silenceAfter ? .noSound : .connected
    }

    /// How many of the 28 cells light for a level.
    static func litCells(_ db: Double) -> Int {
        let fraction = (db - floorDB) / -floorDB
        return max(0, min(cells, Int((fraction * Double(cells)).rounded())))
    }
}
