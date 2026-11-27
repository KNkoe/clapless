import SwiftUI

/// What the viewfinder shows without a picture: the drawing grid, and where head and shoulders go.
struct Placeholder: View {
    let message: String
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        GeometryReader { area in
            let u = area.size.width / 100
            ZStack {
                DraftingGrid(step: 10 * u)
                // The head goes on top, so the chin sits in front of the neck.
                drawn(Bust(head: false))
                drawn(Bust(head: true))
                // Where the eyes sit in a well-framed shot.
                Path { path in
                    path.move(to: CGPoint(x: 22 * u, y: 61 * u))
                    path.addLine(to: CGPoint(x: 78 * u, y: 61 * u))
                }
                .stroke(Brand.bone.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                Text(message)
                    .font(Brand.font(3.3 * u, 600))
                    .foregroundStyle(Brand.bone)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4 * u)
                    .padding(.vertical, 2.4 * u)
                    .overlay(Rectangle().strokeBorder(Brand.rule, lineWidth: 1))
                    .background(Brand.ink)
                    .padding(.horizontal, 8 * u)
                    .position(x: 50 * u, y: 148 * u)
            }
        }
    }

    private func drawn(_ shape: Bust) -> some View {
        shape.fill(Brand.ink)
            .overlay(shape.fill(Brand.bone.opacity(0.05)))
            .overlay(shape.stroke(Brand.bone.opacity(0.55),
                                  style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)))
    }
}

/// The head, or the shoulders and neck, on a frame 100 wide and 178 tall.
private struct Bust: Shape {
    let head: Bool

    func path(in rect: CGRect) -> Path {
        let u = rect.width / 100
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
        var path = Path()
        guard head else {
            path.move(to: at(42.5, 79))
            path.addLine(to: at(42.5, 89))
            path.addCurve(to: at(27, 101), control1: at(42.5, 96), control2: at(34, 97.5))
            path.addCurve(to: at(14, 130), control1: at(18, 105.5), control2: at(14, 115))
            path.addLine(to: at(86, 130))
            path.addCurve(to: at(73, 101), control1: at(86, 115), control2: at(82, 105.5))
            path.addCurve(to: at(57.5, 89), control1: at(66, 97.5), control2: at(57.5, 96))
            path.addLine(to: at(57.5, 79))
            return path
        }
        // Head: fuller at the crown, narrowing to the chin.
        path.move(to: at(50, 38))
        path.addCurve(to: at(67, 58), control1: at(60.5, 38), control2: at(67, 46))
        path.addCurve(to: at(50, 85), control1: at(67, 72.5), control2: at(58.5, 85))
        path.addCurve(to: at(33, 58), control1: at(41.5, 85), control2: at(33, 72.5))
        path.addCurve(to: at(50, 38), control1: at(33, 46), control2: at(39.5, 38))
        path.closeSubpath()
        return path
    }
}
