import CoreMedia
import Foundation

func timecode(_ seconds: Double) -> String {
    let whole = Int(max(0, seconds))
    return String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
}

/// Take names are used as folder names, so only plain ones are accepted from the network.
func isSafeTakeID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
}

/// The clock camera and microphone frames are stamped with, on both devices.
enum HostClock {
    static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
