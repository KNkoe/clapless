import Foundation

/// How loud the voice is, so a quiet take can be caught before it is recorded.
/// Fed with the average power of short stretches of sound.
struct VoiceLevel {
    static let block = 0.4          // seconds per measurement
    static let window = 20.0        // seconds remembered, to know how quiet the room is
    static let recent = 6.0         // seconds of speech the verdict is about
    /// Speech averaging below this is too quiet. The first take, which came out at -44 LUFS, would trip it.
    static let quietDB = -36.0
    private static let aboveRoom = 12.0   // speech stands at least this far above the room

    private var power = 0.0
    private var count = 0
    private var blocks: [Double] = []     // dB, newest last

    /// `sumOfSquares` over `samples` samples at `rate`.
    mutating func add(sumOfSquares: Double, samples: Int, rate: Double) {
        power += sumOfSquares
        count += samples
        guard Double(count) >= Self.block * rate else { return }
        let mean = power / Double(count)
        blocks.append(mean > 0 ? 10 * log10(mean) : -160)
        if blocks.count > Int(Self.window / Self.block) { blocks.removeFirst() }
        power = 0
        count = 0
    }

    /// The level of the speech heard in the last few seconds, or nil when nobody has clearly been speaking.
    var speechDB: Double? {
        guard blocks.count >= 5 else { return nil }
        let sorted = blocks.sorted()
        let room = sorted[sorted.count / 10]
        let loud = blocks.suffix(Int(Self.recent / Self.block)).filter { $0 > room + Self.aboveRoom && $0 > -60 }.sorted()
        guard loud.count >= 3 else { return nil }          // about a second of sound at least
        let top = loud.suffix(max(3, loud.count / 2))
        return 10 * log10(top.reduce(0) { $0 + pow(10, $1 / 10) } / Double(top.count))
    }

    /// Speaking up clears this at once; so does falling silent, a few seconds later.
    var isQuiet: Bool {
        if blocks.suffix(3).contains(where: { $0 >= Self.quietDB + 2 }) { return false }
        return speechDB.map { $0 < Self.quietDB } ?? false
    }
}

/// Notices the lens being wiped: for a moment the picture is one flat patch (cloth or finger over
/// the glass), then the room comes back. It cannot tell whether the glass is clean.
struct LensWatch {
    static let flat = 6.0       // brightness spread of a covered lens, on a 0-255 scale
    static let clear = 18.0     // and of an ordinary room
    private var covered = 0

    /// Feed about ten readings a second. True once, when the lens is uncovered again.
    mutating func add(spread: Double) -> Bool {
        if spread < Self.flat {
            covered += 1
        } else if spread > Self.clear {
            defer { covered = 0 }
            return covered >= 2
        }
        return false
    }
}

enum LightAdvice {
    enum Level: String { case good, dim, dark }

    /// Up to here the picture is clean.
    static let goodISO = 800.0
    /// Above this it looks soft and grainy, and it is worth a warning. The first take ran at about 1,800.
    static let darkISO = 1400.0

    /// The ISO the camera needs at the 1/50 s a take is shot at.
    static func isoAtFiftieth(iso: Double, shutterSeconds: Double) -> Double {
        iso * shutterSeconds / 0.02
    }

    static func reading(iso: Double?, shutterSeconds: Double?) -> (level: Level, iso: Int)? {
        guard let iso, let shutterSeconds, shutterSeconds > 0 else { return nil }
        let needed = isoAtFiftieth(iso: iso, shutterSeconds: shutterSeconds)
        let level: Level = needed > darkISO ? .dark : needed > goodISO ? .dim : .good
        return (level, Int((needed / 50).rounded()) * 50)
    }

    static func warning(iso: Double?, shutterSeconds: Double?) -> String? {
        guard let now = reading(iso: iso, shutterSeconds: shutterSeconds), now.level == .dark else { return nil }
        return "Too dark: add light on your face"
    }
}
