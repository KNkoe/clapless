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

// MARK: - The schematic look: hairlines, square corners, small spaced captions.

extension Brand {
    static let rule = bone.opacity(0.16)
}

/// A hairline between two parts of a drawing.
struct Rule: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Brand.rule)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

/// The small spaced capitals that name a part.
struct Caption: View {
    let text: String
    var size: CGFloat = 10
    var colour = Brand.grey

    var body: some View {
        Text(text.uppercased())
            .font(Brand.font(size, 600))
            .tracking(size * 0.14)
            .foregroundStyle(colour)
            .lineLimit(1)
    }
}

/// Registration marks at the four corners of a picture.
struct CornerMarks: Shape {
    var length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1, 1),
                               (rect.minX, rect.maxY, 1, -1), (rect.maxX, rect.maxY, -1, -1)] {
            path.move(to: CGPoint(x: x, y: y + dy * length))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + dx * length, y: y))
        }
        return path
    }
}

/// A faint drawing grid with a centre mark, for a viewfinder that has no picture.
struct DraftingGrid: View {
    var step: CGFloat

    var body: some View {
        Canvas { context, size in
            var lines = Path()
            var x = size.width / 2
            while x > 0 { x -= step }
            while x < size.width {
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y = size.height / 2
            while y > 0 { y -= step }
            while y < size.height {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(lines, with: .color(Brand.bone.opacity(0.05)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
