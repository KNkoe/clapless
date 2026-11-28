import Foundation

/// What the two apps say to each other. Both sides are built from this one file.
enum Clapless {
    static let version = 2
    static let service = "_clapless._tcp"            // encrypted, paired Macs only
    static let pairService = "_clapless-pair._tcp"   // only advertised while the phone is waiting to pair
}

enum Lens: String, Codable, Equatable {
    case back, front
}

/// The iPhone's flashlight, used as a lamp. It exists only on the back of the phone.
enum Torch: String, Codable, Equatable, CaseIterable {
    case off, low, medium, high

    var level: Float {
        switch self {
        case .off: return 0
        case .low: return 0.1
        case .medium: return 0.4
        case .high: return 1
        }
    }

    /// Off to the last brightness used, and back.
    func toggled(lastUsed: Torch) -> Torch { self != .off ? .off : lastUsed == .off ? .low : lastUsed }

    /// Low, medium, high, and round again. Never off: that is its own button.
    var nextBrightness: Torch {
        switch self {
        case .low: return .medium
        case .medium: return .high
        case .high, .off: return .low
        }
    }
}

enum CaptureState: String, Codable, Equatable {
    case starting, ready, recording, finishing, unavailable
}

enum Heat: String, Codable, Equatable, CaseIterable {
    case nominal, fair, serious, critical

    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

enum LinkRole: String, Codable, Equatable {
    case control   // commands, status, preview
    case bulk      // take files, so a big download never delays Stop
}

struct CameraSettings: Codable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var codec: String
    var bitrate: Int
    var lens: Lens
    var colour: String
    var hdr: Bool
    var locked: Bool
    var shutterSeconds: Double?
    var iso: Double?
    var focusPosition: Double?
    var whiteBalanceKelvin: Double?
    var mainsHz: Int
    var note: String?
}

struct SegmentInfo: Codable, Equatable {
    var index: Int      // 0 is the header segment, then media in order
    var bytes: Int
    var sha256: String
}

struct TakeManifest: Codable, Equatable, Identifiable {
    var takeID: String
    var created: Date
    var complete: Bool                 // recording finished and every segment is listed
    var segments: [SegmentInfo]
    var sha256: String?                // all segments joined in order; set when complete
    var seconds: Double
    var frames: Int
    var droppedFrames: Int
    var firstFrameHostTime: Double?    // the phone's own clock, for the first guess at sync
    var audioStartOffset: Double?      // how long after the first picture the sound begins
    var endReason: String?
    var camera: CameraSettings
    var verifiedByMac: Bool

    var id: String { takeID }
    var totalBytes: Int { segments.reduce(0) { $0 + $1.bytes } }
}

struct PhoneStatus: Codable, Equatable {
    var name: String
    var model: String
    var state: CaptureState
    var note: String?
    var takeID: String?
    var seconds: Double
    var lens: Lens
    var freeBytes: Int64
    var bytesPerSecond: Int       // what a take costs at the current setting
    var battery: Double           // 0...1, or -1 when unknown
    var charging: Bool
    var heat: Heat
    var droppedFrames: Int
    var iso: Double?              // what the camera is using right now
    var shutterSeconds: Double?
    var lensWiped: Bool?          // seen being covered and uncovered since the app was opened
    var screenMirrored: Bool?     // the picture on the iPhone's screen is flipped like a mirror
    var fileMirrored: Bool?       // the recorded frames are flipped: this should always be false
    var processor: Double?        // share of the whole phone's processor in use, 0...100
    var appProcessor: Double?     // Clapless's own use, as a percentage of one core
    var cameraStrain: String?     // iOS's warning that the camera system is under pressure
    var cameraFPS: Int?           // frames a second the camera is running at
    var torch: Torch?             // what the light is really doing; nil when this lens has none

    var minutesLeft: Double { bytesPerSecond > 0 ? Double(freeBytes) / Double(bytesPerSecond) / 60 : 0 }
}

enum MacMessage: Codable, Equatable {
    case hello(name: String, version: Int, role: LinkRole)
    case startTake(takeID: String)
    case stopTake
    case setLens(Lens)
    case setTorch(Torch)
    case ping(id: Int, sent: Double)
    case listTakes
    case fetch(takeID: String, index: Int)
    case takeVerified(takeID: String, sha256: String)
    case deleteTake(takeID: String)     // deleted on the Mac: remove the phone's copy too
    case speedTest(bytes: Int)
    case previewShown                   // one preview picture arrived: the phone may send another
    case disconnect                     // Disconnect was pressed: stop everything and close shortly
}

enum PhoneMessage: Codable, Equatable {
    case hello(name: String, version: Int)
    case status(PhoneStatus)
    case manifest(TakeManifest)        // sent for every new segment and again when complete
    case takes([TakeManifest])
    case takeDeleted(takeID: String)    // the phone holds nothing under that name any more
    case pong(id: Int, sent: Double, received: Double, replied: Double)
    case refused(String)
    case level(Double)                  // peak of the phone's scratch sound in dB, a few times a second
    case exposure(iso: Double, shutterSeconds: Double)   // what the camera is using, several times a second
}

/// Header of a piece of a file on the bulk link.
struct ChunkHeader: Codable, Equatable {
    var takeID: String   // empty for a speed test
    var index: Int
    var offset: Int
    var total: Int
}

enum Coding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
