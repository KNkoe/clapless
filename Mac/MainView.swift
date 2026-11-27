import AppKit
import SwiftUI

/// A narrow window drawn like a schematic: the picture fills its whole width, and everything else
/// sits quietly in ruled rows beneath it. The window keeps the shape that makes that fit.
struct MainView: View {
    /// The layout at its usual size. The window scales all of it together.
    static let design = CGSize(width: 400, height: 34 + 400 * 16 / 9 + 160)
    static let narrowest: CGFloat = 360

    @ObservedObject var model: MacModel
    @ObservedObject var mic: MicMonitor
    @AppStorage("floatOnTop") private var floating = true
    @State private var showTakes = false

    var body: some View {
        GeometryReader { window in
            let u = window.size.width / Self.design.width
            VStack(spacing: 0) {
                header(u).frame(height: 34 * u - 1)
                Rule()
                viewfinder(u).frame(width: window.size.width, height: window.size.width * 16 / 9)
                deck(u).frame(maxHeight: .infinity)
            }
        }
        .background(Brand.ink)
        .overlay { if model.choosing { RecordChooser(model: model).transition(.opacity) } }
        .overlay { PairingView(model: model) }
        .background(WindowShape(floating: floating))
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.18), value: model.choosing)
    }

    private var recording: Bool { model.phase == .recording || model.phase == .stopping }

    // MARK: - Title strip

    private func header(_ u: CGFloat) -> some View {
        ZStack {
            Wordmark(size: 16 * u)
            HStack {
                Spacer()
                Button { floating.toggle() } label: {
                    Image(systemName: floating ? "pin.fill" : "pin")
                        .font(.system(size: 11 * u, weight: .semibold))
                        .foregroundStyle(floating ? Brand.bone : Brand.grey)
                        .frame(width: 34 * u, height: 32 * u)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(floating ? "Stays above other windows" : "Keep above other windows")
                .accessibilityLabel("Keep above other windows")
                .accessibilityAddTraits(floating ? .isSelected : [])
            }
        }
    }

    // MARK: - Camera

    private func viewfinder(_ u: CGFloat) -> some View {
        ZStack {
            Color.black
            if let image = model.preview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // Both cameras are shown like a mirror: move left and the picture moves left.
                    // Only what is shown is flipped; camera.mov is not, so writing reads correctly.
                    .scaleEffect(x: -1)
                    .accessibilityLabel("Live picture from the iPhone")
            } else {
                Placeholder(message: model.linked ? "Waiting for the picture"
                            : model.pairedName == nil ? "To pair, open Clapless on your iPhone"
                            : "Open Clapless on your iPhone")
            }
            CornerMarks(length: 14 * u)
                .stroke(Brand.bone.opacity(0.55), lineWidth: 1)
                .padding(10 * u)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { stateTag(u).padding(18 * u) }
        .overlay(alignment: .topTrailing) { lensTag(u).padding(18 * u) }
        .overlay(alignment: .bottom) { warnings(u).padding(18 * u) }
        .overlay { if showTakes { TakesView(model: model) } }
        .overlay(Rectangle().strokeBorder(recording ? Brand.red : .clear, lineWidth: 2))
        .overlay(alignment: .top) { Rule().opacity(recording ? 0 : 1) }
        .overlay(alignment: .bottom) { Rule().opacity(recording ? 0 : 1) }
        .clipped()
    }

    private func stateTag(_ u: CGFloat) -> some View {
        HStack(spacing: 7 * u) {
            Rectangle().fill(stateColour).frame(width: 7 * u, height: 7 * u)
            if recording {
                Text(model.phase == .stopping ? "SAVING" : timecode(model.elapsed)).font(Brand.digits(15 * u, 700))
            } else {
                Caption(text: model.phase == .starting ? "Starting"
                        : model.deviceBlocker == nil ? "Ready" : "Not ready", size: 10.5 * u, colour: Brand.bone)
            }
        }
        .foregroundStyle(recording ? Brand.ink : Brand.bone)
        .padding(.horizontal, 9 * u)
        .frame(height: 26 * u)
        .background(recording ? Brand.red : Brand.ink.opacity(0.72))
        .overlay(Rectangle().strokeBorder(recording ? .clear : Brand.rule, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var stateColour: Color {
        if recording { return Brand.ink }
        return model.phase == .idle && model.deviceBlocker == nil ? Brand.green : Brand.amber
    }

    @ViewBuilder private func lensTag(_ u: CGFloat) -> some View {
        if let status = model.status, !recording {
            Button { model.switchLens() } label: {
                HStack(spacing: 7 * u) {
                    Caption(text: "4K \(status.lens == .back ? "Back" : "Front")", size: 10.5 * u, colour: Brand.bone)
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10 * u, weight: .semibold))
                }
                .foregroundStyle(Brand.bone)
                .padding(.horizontal, 9 * u)
                .frame(height: 26 * u)
                .background(Brand.ink.opacity(0.72))
                .overlay(Rectangle().strokeBorder(Brand.rule, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .disabled(model.phase != .idle)
            .help("Switch between the back and front camera")
        }
    }

    /// The only things allowed over the picture while it is being framed.
    @ViewBuilder private func warnings(_ u: CGFloat) -> some View {
        let all = model.warnings
        if !all.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(all.prefix(2).enumerated()), id: \.element) { index, text in
                    if index > 0 { Rule() }
                    HStack(alignment: .firstTextBaseline, spacing: 8 * u) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9 * u))
                            .foregroundStyle(Brand.amber)
                        Text(text).font(Brand.font(11.5 * u, 600)).foregroundStyle(Brand.bone)
                        Spacer(minLength: 0)
                        if index == 1, all.count > 2 {
                            Text("+\(all.count - 2)").font(Brand.digits(11 * u, 600)).foregroundStyle(Brand.grey)
                        }
                    }
                    .padding(.horizontal, 10 * u)
                    .padding(.vertical, 6 * u)
                }
            }
            .background(Brand.ink.opacity(0.84))
            .overlay(Rectangle().strokeBorder(Brand.amber.opacity(0.7), lineWidth: 1))
            .help(all.joined(separator: "\n"))
        }
    }

    // MARK: - The deck: inputs, record, and one line of news

    private func deck(_ u: CGFloat) -> some View {
        VStack(spacing: 0) {
            if recording {
                track("Face", model.faceHistory, u).frame(height: 48 * u)
                Rule()
                track("Mic", mic.history, u).frame(height: 34 * u)
            } else {
                AudioInView(mic: mic, locked: model.phase != .idle).frame(height: 48 * u)
                Rule()
                ScreenInView(model: model).frame(height: 34 * u)
            }
            Rule()
            transport(u).frame(maxHeight: .infinity)
            Rule()
            StatusLine(model: model, mic: mic).frame(height: 28 * u)
        }
        .environment(\.unit, u)
    }

    private func track(_ label: String, _ levels: [Double], _ u: CGFloat) -> some View {
        DeckRow(label: label) {
            Waveform(levels: levels).padding(.vertical, 6 * u).padding(.trailing, 12 * u)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) sound")
    }

    private func transport(_ u: CGFloat) -> some View {
        let idle = model.phase == .idle
        let blocker = idle ? model.deviceBlocker : nil
        let off = blocker != nil || model.phase == .stopping
        return HStack(spacing: 0) {
            Button { showTakes.toggle() } label: {
                VStack(spacing: 4 * u) {
                    Image(systemName: showTakes ? "xmark" : "square.stack").font(.system(size: 15 * u))
                    Caption(text: showTakes ? "Close" : "Takes", size: 9.5 * u, colour: Brand.bone)
                }
                .foregroundStyle(Brand.bone)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            Rule(vertical: true)
            Button { showTakes = false; model.toggle() } label: {
                ZStack {
                    Circle().strokeBorder(Brand.bone, lineWidth: 1.5)
                    RoundedRectangle(cornerRadius: (idle ? 18 : 3) * u, style: .continuous)
                        .fill(Brand.red)
                        .frame(width: (idle ? 36 : 18) * u, height: (idle ? 36 : 18) * u)
                }
                .frame(width: 46 * u, height: 46 * u)
                .frame(width: 112 * u)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(.snappy(duration: 0.22), value: idle)
            }
            .buttonStyle(PressStyle())
            .disabled(off)
            .opacity(off ? 0.35 : 1)
            .help(blocker ?? (idle ? "Start take (⌘↩)" : "Stop take (⌘↩)"))
            .accessibilityLabel(idle ? "Start take" : "Stop take")
            Rule(vertical: true)
            phoneInfo(u).frame(maxWidth: .infinity)
        }
    }

    /// Battery, room left and the light on the face. They update several times a second.
    private func phoneInfo(_ u: CGFloat) -> some View {
        VStack(spacing: 3 * u) {
            if let status = model.status {
                HStack(spacing: 4 * u) {
                    if status.charging { Image(systemName: "bolt.fill").font(.system(size: 9 * u)) }
                    Text(status.battery >= 0 ? "\(Int(status.battery * 100))%" : "—").font(Brand.digits(13 * u, 700))
                    Text("· \(room(Int(status.minutesLeft)))").font(Brand.digits(11 * u, 500)).foregroundStyle(Brand.grey)
                }
                if let light = LightAdvice.reading(iso: status.iso, shutterSeconds: status.shutterSeconds),
                   light.level != .dark {
                    let colour = light.level == .good ? Brand.green : Brand.amber
                    HStack(spacing: 5 * u) {
                        Rectangle().fill(colour).frame(width: 5 * u, height: 5 * u)
                        Caption(text: light.level == .good ? "Light good" : "A bit dim", size: 9.5 * u)
                    }
                    .help("ISO \(light.iso). Lower means a cleaner picture; under 800 is good.")
                }
            } else {
                Image(systemName: "iphone.slash").font(.system(size: 14 * u))
                Caption(text: "No iPhone", size: 9.5 * u)
            }
        }
        .foregroundStyle(Brand.bone)
        .lineLimit(1)
        .help("iPhone battery and recording time left")
        .accessibilityElement(children: .combine)
    }

    private func room(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }
}

/// A row of the deck: its name in a ruled margin, then whatever it holds.
struct DeckRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    @Environment(\.unit) private var u

    var body: some View {
        HStack(spacing: 0) {
            Caption(text: label, size: 9.5 * u)
                .frame(width: 64 * u, alignment: .leading)
                .padding(.leading, 12 * u)
            Rule(vertical: true)
            content.padding(.leading, 12 * u).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A track drawn the way the design shows it: a line that swings with how loud each moment was.
private struct Waveform: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let slots = 120
            let step = size.width / CGFloat(slots)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            let recent = levels.suffix(slots)
            for (i, db) in recent.enumerated() {
                let loud = max(0, min(1, (db - MicLevel.floorDB) / -MicLevel.floorDB))
                let swing = CGFloat(loud * loud) * size.height / 2 * (i % 2 == 0 ? -1 : 1)
                path.addLine(to: CGPoint(x: CGFloat(slots - recent.count + i) * step, y: size.height / 2 + swing))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(Brand.bone), lineWidth: 1)
        }
    }
}

/// Keeps the window in the shape that fits the picture edge to edge, whatever its size. When pinned
/// it stays above other windows and comes along to other desktops, so the stop button stays in
/// reach when recording moves to an app elsewhere.
private struct WindowShape: NSViewRepresentable {
    let floating: Bool

    final class Coordinator { var shaped = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let level: NSWindow.Level = floating ? .floating : .normal
        let behaviour: NSWindow.CollectionBehavior = floating ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenNone]
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = level
            window.collectionBehavior = behaviour
            // Zooming or full screen would leave bare strips beside the picture.
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.contentAspectRatio = MainView.design
            // Set on the window: a minimum on the view would have the title bar's height added to it.
            window.contentMinSize = NSSize(width: MainView.narrowest,
                                           height: (MainView.narrowest * MainView.design.height / MainView.design.width).rounded())
            guard !coordinator.shaped else { return }
            coordinator.shaped = true
            Self.shape(window)
        }
    }

    /// Fit a remembered window to the shape, keeping its top right corner where it was.
    private static func shape(_ window: NSWindow) {
        let design = MainView.design
        let room = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        // The first time this layout is seen it opens at its usual size, not the old narrow one.
        let seen = UserDefaults.standard.bool(forKey: "window.schematic")
        UserDefaults.standard.set(true, forKey: "window.schematic")
        let wanted = seen ? window.frame.width : design.width
        let tallest = (room.height - 16) * design.width / design.height
        let width = max(MainView.narrowest, min(wanted, tallest)).rounded()
        let height = (width * design.height / design.width).rounded()
        var frame = NSRect(x: window.frame.maxX - width, y: window.frame.maxY - height, width: width, height: height)
        frame.origin.x = min(max(frame.origin.x, room.minX), max(room.minX, room.maxX - width))
        frame.origin.y = max(room.minY, min(frame.origin.y, room.maxY - height))
        window.setFrame(frame, display: true)
    }
}

/// A button that gives a little when pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct UnitKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// One point of the layout at its usual size.
    var unit: CGFloat {
        get { self[UnitKey.self] }
        set { self[UnitKey.self] = newValue }
    }
}
