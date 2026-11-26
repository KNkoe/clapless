import CoreGraphics
import Foundation

/// Where one app's picture is on a screen, for takes that record only that app. Window frames are in
/// the system's screen coordinates: points, with y growing downwards.
enum AppCrop {
    /// Anything smaller is a palette, a tooltip or an invisible helper, not a window to film.
    static let smallest = CGSize(width: 200, height: 150)

    /// The window to follow, from an app's windows listed front to back: the frontmost one that is at
    /// least half the size of the biggest, so a small panel does not pull the picture onto itself.
    static func main(_ windows: [CGRect]) -> CGRect? {
        let real = windows.filter { $0.width >= smallest.width && $0.height >= smallest.height }
        guard let biggest = real.map(area).max() else { return nil }
        return real.first { area($0) >= biggest / 2 }
    }

    /// Which display shows most of the window, or nil if it is on none.
    static func display(for window: CGRect, among displays: [CGRect]) -> Int? {
        let shown = displays.map { area($0.intersection(window)) }
        guard let most = shown.max(), most > 0 else { return nil }
        return shown.firstIndex(of: most)
    }

    /// The part of the window on that display, measured from the display's top left corner.
    static func source(window: CGRect, display: CGRect) -> CGRect? {
        let visible = window.intersection(display)
        guard !visible.isNull, visible.width >= smallest.width / 2, visible.height >= smallest.height / 2
        else { return nil }
        return visible.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    /// The video's size: the window at the screen's own sharpness, no wider than `widest`, in even numbers.
    static func pixels(of size: CGSize, scale: CGFloat, widest: CGFloat) -> (width: Int, height: Int) {
        let width = size.width * scale, height = size.height * scale
        let shrink = min(1, widest / width)
        return (Int(width * shrink) / 2 * 2, Int(height * shrink) / 2 * 2)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
