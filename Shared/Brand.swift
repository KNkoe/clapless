import CoreText
import SwiftUI

/// Colours and type from the approved design (look 2).
enum Brand {
    static let ink = Color(hex: 0x0C0C0E)
    static let bone = Color(hex: 0xEFECE4)
    static let red = Color(hex: 0xFF4A22)
    static let green = Color(hex: 0x7CE38B)
    static let amber = Color(hex: 0xFFC24A)
    static let grey = Color(hex: 0xA9A69E)
    static let record = Color(hex: 0xFF4433)

    /// Space Grotesk, SIL Open Font License 1.1 (Resources/Fonts). Weights 300 to 700.
    static func font(_ size: CGFloat, _ weight: CGFloat = 500) -> Font {
        make(size, weight, evenDigits: false)
    }

    /// The same face with equal-width figures, so a running timecode does not jiggle.
    static func digits(_ size: CGFloat, _ weight: CGFloat = 600) -> Font {
        make(size, weight, evenDigits: true)
    }

    private static var descriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "SpaceGrotesk-Variable", withExtension: "ttf"),
              let found = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return found.first
    }()

    private static func make(_ size: CGFloat, _ weight: CGFloat, evenDigits: Bool) -> Font {
        guard let base = descriptor else { return .system(size: size) }
        let wght = 0x7767_6874
        var attributes: [CFString: Any] = [kCTFontVariationAttribute: [wght: weight]]
        if evenDigits {
            attributes[kCTFontFeatureSettingsAttribute] =
                [[kCTFontOpenTypeFeatureTag: "tnum", kCTFontOpenTypeFeatureValue: 1]]
        }
        let styled = CTFontDescriptorCreateCopyWithAttributes(base, attributes as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(styled, size, nil))
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// "clapless." with the red full stop.
struct Wordmark: View {
    var size: CGFloat

    var body: some View {
        Text("\(Text("clapless").foregroundStyle(Brand.bone))\(Text(".").foregroundStyle(Brand.red))")
            .font(Brand.font(size, 700))
            .tracking(-0.05 * size)
            .accessibilityLabel("Clapless")
    }
}
