import Foundation

/// `take.json`: what is in a take folder, for the app, the command line and the video editor.
struct TakeRecord: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case recording     // the take is running
        case transferring  // stopped; the camera file is still coming from the iPhone
        case ready         // every file is on this Mac and checked
        case failed
    }

    struct Camera: Codable, Equatable {
        var file: String
        var bytes: Int
        var sha256: String           // of camera.mov
        var phoneSha256: String      // of the take as the phone wrote it; the pieces were checked against this
        var seconds: Double
        var frames: Int
        var droppedFrames: Int
        var firstFrameHostTime: Double?   // iPhone clock
        var audioStartOffset: Double?
        var endReason: String?
        var settings: CameraSettings
    }

    struct Mic: Codable, Equatable {
        var file: String
        var name: String
        var id: String
        var bytes: Int
        var sha256: String
        var seconds: Double
        var firstSampleHostTime: Double?  // Mac clock
    }

    /// iPhone clock minus Mac clock, measured by timing messages back and forth.
    struct ClockReading: Codable, Equatable {
        var atMacHostTime: Double
        var phoneMinusMac: Double
        var roundTripMs: Double
    }

    struct Screen: Codable, Equatable {
        var file: String
        var bytes: Int
        var sha256: String
        var seconds: Double
        var frames: Int
        var skippedFrames: Int
        var width: Int
        var height: Int
        var fps: Int
        var display: String
        var app: String?                  // set when only this app's window was recorded
        var firstFrameHostTime: Double    // Mac clock; mic.m4a begins at the same moment
    }

    /// How the camera lines up with the Mac's sound and screen. First a guess from the two clocks,
    /// then the match by sound: camera time = screen time + videoOffset + videoDrift * screen time.
    struct Sync: Codable, Equatable {
        var method = "none"
        var matchedBySound = false
        var cameraStartMinusMicStart: Double?   // the clock guess, seconds
        var uncertaintySeconds: Double?
        var tried: Bool?                        // sound matching has been attempted
        var videoOffset: Double?
        var videoDrift: Double?
        var matchedPoints: Int?
        var points: Int?
        var worstMs: Double?
        var driftMeasured: Bool?
        var weak: Bool?
        var note: String?
    }

    var app = "Clapless"
    var version = 1
    var take: String
    var created: Date
    var status: Status
    var camera: Camera?
    var mic: Mic?
    var screen: Screen?
    var clock: [ClockReading] = []
    var sync: Sync?
    var warnings: [String] = []

    var id: String { take }

    mutating func warn(_ text: String) {
        if !warnings.contains(text) { warnings.append(text) }
    }

    /// A stopped take is ready once the camera file is in.
    mutating func settle() {
        if status == .transferring, camera != nil { status = .ready }
    }

    mutating func estimateSync() {
        guard sync?.matchedBySound != true,
              let first = camera?.firstFrameHostTime, let micFirst = mic?.firstSampleHostTime,
              let reading = clock.min(by: { $0.roundTripMs < $1.roundTripMs }) else { return }
        var new = sync ?? Sync()
        if new.method == "none" { new.method = "clock estimate only" }
        new.cameraStartMinusMicStart = (first - reading.phoneMinusMac) - micFirst
        // Half the round trip, plus an allowance for delays inside the two devices.
        new.uncertaintySeconds = reading.roundTripMs / 2000 + 0.1
        sync = new
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

extension PhoneStatus {
    /// What to watch before and during a take.
    var warnings: [String] {
        var out: [String] = []
        if let dark = LightAdvice.warning(iso: iso, shutterSeconds: shutterSeconds) { out.append(dark) }
        if minutesLeft < 15 { out.append("iPhone has space for \(Int(minutesLeft)) min") }
        if heat == .serious || heat == .critical { out.append("iPhone is hot") }
        // Running on battery is fine; only a low one is worth interrupting for.
        if !charging, battery >= 0, battery < 0.3 { out.append("iPhone battery at \(Int(battery * 100))%: plug it in") }
        return out
    }
}
