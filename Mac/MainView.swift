import AppKit
import SwiftUI

/// A narrow window that stays out of the way: the camera is the point, everything else is small.
struct MainView: View {
    @ObservedObject var model: MacModel
    @ObservedObject var mic: MicMonitor
    @AppStorage("floatOnTop") private var floating = true
    @State private var showTakes = false

    var body: some View {
        VStack(spacing: 10) {
            header
            viewfinder
            if let take = featured {
                TakeCard(take: take, progress: model.progress[take.take], linked: model.linked) { model.reveal(take) }
                    .transition(.opacity)
            }
            ScreenInView(model: model)
            AudioInView(mic: mic, locked: model.phase != .idle)
            controls
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .background(Brand.ink)
        .overlay { PairingView(model: model) }
        .background(WindowLevel(floating: floating))
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.25), value: featured?.take)
    }

    /// The take worth showing: one still on its way, otherwise the newest.
    private var featured: TakeRecord? {
        model.takes.first { model.progress[$0.take] != nil } ?? model.takes.first
    }

    private var header: some View {
        ZStack {
            Wordmark(size: 17)
            HStack {
                Spacer()
                Button { floating.toggle() } label: {
                    Image(systemName: floating ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(floating ? Brand.bone : Brand.grey)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(floating ? "Stays above other windows" : "Keep above other windows")
                .accessibilityLabel("Keep above other windows")
                .accessibilityAddTraits(floating ? .isSelected : [])
            }
        }
        .frame(height: 36)
        .padding(.top, 2)
    }

    private var recording: Bool { model.phase == .recording || model.phase == .stopping }

    // MARK: - Camera

    private var viewfinder: some View {
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
                Text(model.linked ? "Waiting for the picture"
                     : model.pairedName == nil ? "To pair, open Clapless on your iPhone"
                     : "Open Clapless on your iPhone")
                    .font(Brand.font(14))
                    .foregroundStyle(Brand.grey)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                statePill
                lightPill
            }
            .padding(10)
        }
        .overlay(alignment: .topTrailing) { cameraPill.padding(10) }
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                lensReminder
                warnings
                if recording { tracks }
            }
            .padding(10)
        }
        .overlay { if showTakes { takeList } }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(recording ? Brand.red : Brand.bone.opacity(0.12), lineWidth: recording ? 3 : 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statePill: some View {
        HStack(spacing: 6) {
            Circle().fill(stateColour).frame(width: 7, height: 7)
            if recording {
                Text(model.phase == .stopping ? "Saving" : timecode(model.elapsed)).font(Brand.digits(15, 700))
            } else {
                Text(model.phase == .starting ? "Starting" : model.blocker == nil ? "Ready" : "Not ready")
                    .font(Brand.font(12, 700))
            }
        }
        .foregroundStyle(recording ? Brand.ink : Brand.bone)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(recording ? AnyShapeStyle(Brand.red) : AnyShapeStyle(Brand.ink.opacity(0.72)), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    /// Updates several times a second, so a lamp can be moved while watching it.
    @ViewBuilder private var lightPill: some View {
        if !recording, let status = model.status,
           let light = LightAdvice.reading(iso: status.iso, shutterSeconds: status.shutterSeconds) {
            let words = light.level == .good ? "Light good" : light.level == .dim ? "A bit dim" : "Too dark"
            HStack(spacing: 6) {
                Image(systemName: light.level == .good ? "sun.max.fill" : "sun.min.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(light.level == .good ? Brand.green : light.level == .dim ? Brand.amber : Brand.red)
                Text(words).font(Brand.font(12, 700))
                Text("ISO \(light.iso)").font(Brand.digits(11, 500)).foregroundStyle(Brand.grey)
            }
            .foregroundStyle(Brand.bone)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Brand.ink.opacity(0.72), in: Capsule())
            .help("Lower ISO means a cleaner picture. Under 800 is good.")
            .accessibilityElement(children: .combine)
        }
    }

    private var stateColour: Color {
        if recording { return Brand.ink }
        return model.phase == .idle && model.blocker == nil ? Brand.green : Brand.amber
    }

    @ViewBuilder private var cameraPill: some View {
        if let status = model.status, !recording {
            Button { model.switchLens() } label: {
                HStack(spacing: 5) {
                    Text("4K · \(status.lens == .back ? "Back" : "Front")")
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                }
                .font(Brand.font(12, 700))
                .foregroundStyle(Brand.bone)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Brand.ink.opacity(0.72), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .disabled(model.phase != .idle)
            .help("Switch between the back and front camera")
        }
    }

    @ViewBuilder private var lensReminder: some View {
        if model.lensThanks {
            Label("Lens wiped", systemImage: "checkmark")
                .font(Brand.font(11.5, 700))
                .foregroundStyle(Brand.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Brand.green, in: Capsule())
        } else if model.linked, model.phase == .idle, !model.lensReminded {
            Button { model.lensReminded = true } label: {
                HStack(spacing: 6) {
                    Text("Wipe the iPhone lens")
                    Image(systemName: "checkmark")
                }
                .font(Brand.font(11.5, 700))
                .foregroundStyle(Brand.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Brand.bone, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .help("Click once it is clean")
        }
    }

    @ViewBuilder private var warnings: some View {
        ForEach(model.warnings.prefix(3), id: \.self) { text in
            Text(text)
                .font(Brand.font(11.5, 600))
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Brand.amber, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var tracks: some View {
        VStack(spacing: 4) {
            track("Face", model.faceHistory)
            track("Mic", mic.history)
        }
        .padding(8)
        .background(Brand.ink.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func track(_ label: String, _ levels: [Double]) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Brand.font(10.5, 600)).foregroundStyle(Brand.grey).frame(width: 28, alignment: .leading)
            Waveform(levels: levels).frame(height: 18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) sound")
    }

    // MARK: - Controls

    private var controls: some View {
        let idle = model.phase == .idle
        let blocker = idle ? model.blocker : nil
        let off = blocker != nil || model.phase == .stopping
        return VStack(spacing: 6) {
            HStack {
                Button { showTakes.toggle() } label: {
                    side(showTakes ? "xmark" : "rectangle.stack", showTakes ? "Close" : "Takes")
                }
                .buttonStyle(PressStyle())
                Spacer()
                Button { showTakes = false; model.toggle() } label: {
                    ZStack {
                        Circle().strokeBorder(Brand.bone, lineWidth: 3)
                        RoundedRectangle(cornerRadius: idle ? 24 : 6, style: .continuous)
                            .fill(Brand.red)
                            .frame(width: idle ? 46 : 24, height: idle ? 46 : 24)
                    }
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
                    .animation(.snappy(duration: 0.22), value: idle)
                }
                .buttonStyle(PressStyle())
                .disabled(off)
                .opacity(off ? 0.35 : 1)
                .help(blocker ?? (idle ? "Start take (⌘↩)" : "Stop take (⌘↩)"))
                .accessibilityLabel(idle ? "Start take" : "Stop take")
                Spacer()
                phoneInfo
            }
            Text(blocker ?? (model.recordScreen ? "Records camera, mic and screen" : "Records camera and mic only"))
                .font(Brand.font(11))
                .foregroundStyle(blocker == nil ? Brand.grey.opacity(0.8) : Brand.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func side(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
            Text(label).font(Brand.font(11, 600))
        }
        .foregroundStyle(Brand.bone)
        .frame(width: 74, height: 48)
        .contentShape(Rectangle())
    }

    private var phoneInfo: some View {
        VStack(spacing: 3) {
            if let status = model.status {
                HStack(spacing: 3) {
                    if status.charging { Image(systemName: "bolt.fill").font(.system(size: 10)) }
                    Text(status.battery >= 0 ? "\(Int(status.battery * 100))%" : "—").font(Brand.digits(15, 700))
                }
                Text(room(Int(status.minutesLeft))).font(Brand.font(11)).foregroundStyle(Brand.grey)
            } else {
                Image(systemName: "iphone.slash").font(.system(size: 17))
                Text("No iPhone").font(Brand.font(11)).foregroundStyle(Brand.grey)
            }
        }
        .foregroundStyle(Brand.bone)
        .frame(width: 74, height: 48)
        .help("iPhone battery and recording time left")
        .accessibilityElement(children: .combine)
    }

    private func room(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m left" : "\(minutes) m left"
    }

    // MARK: - Takes

    private var takeList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if model.takes.isEmpty {
                    Text("Takes appear here, saved in Movies › Clapless.")
                        .font(Brand.font(13))
                        .foregroundStyle(Brand.grey)
                        .multilineTextAlignment(.center)
                        .padding(.top, 60)
                }
                ForEach(model.takes) { take in
                    TakeCard(take: take, progress: model.progress[take.take], linked: model.linked) { model.reveal(take) }
                }
            }
            .padding(10)
            .padding(.top, 36)
        }
        .background(Brand.ink.opacity(0.96))
    }
}

/// One take and, while it is on its way, how far along it is.
private struct TakeCard: View {
    let take: TakeRecord
    let progress: Downloader.Progress?
    let linked: Bool
    let reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
                Text(title).font(Brand.font(13, 700)).foregroundStyle(Brand.bone)
                Spacer()
                if let fraction, progress?.recording == false {
                    Text("\(Int(fraction * 100))%").font(Brand.digits(13, 700)).foregroundStyle(Brand.bone)
                }
                if take.status == .ready || take.status == .failed {
                    Button("Show", action: reveal)
                        .buttonStyle(PressStyle())
                        .font(Brand.font(12, 700))
                        .foregroundStyle(Brand.bone)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Brand.bone.opacity(0.12), in: Capsule())
                        .help("Show in Finder")
                }
            }
            if take.status != .ready, take.status != .failed {
                ProgressBar(fraction: progress?.checking == true ? nil : fraction, tint: tint)
            }
            Text(detail)
                .font(Brand.digits(11.5, 500))
                .foregroundStyle(Brand.grey)
                .lineLimit(3)
        }
        .padding(11)
        .background(Brand.bone.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(take.warnings.joined(separator: "\n"))
        .accessibilityElement(children: .contain)
    }

    private var syncLine: String {
        guard take.mic != nil else { return "" }
        guard let sync = take.sync, sync.tried == true else { return "\nLining up by sound…" }
        if !sync.matchedBySound { return "\nNot synced: the sound did not match" }
        if sync.weak == true { return "\nSync is weak: check lip sync" }
        return sync.driftMeasured == true ? "\nSynced by sound, drift measured" : "\nSynced by sound"
    }

    private var fraction: Double? {
        guard let progress, progress.listed > 0 else { return nil }
        return min(1, Double(progress.received) / Double(progress.listed))
    }

    private var when: String {
        take.created.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private var title: String {
        if progress?.problem != nil || take.status == .failed { return "Take has a problem" }
        if take.status == .ready { return "Saved on this Mac" }
        if progress?.checking == true { return "Checking the file" }
        if progress?.recording == true { return "Sending while recording" }
        if take.status == .recording { return "Recording" }
        return linked && progress != nil ? "Sending to Mac" : "Waiting for the iPhone"
    }

    private var symbol: String? {
        if progress?.problem != nil || take.status == .failed { return "exclamationmark.triangle.fill" }
        if take.status == .ready { return "checkmark.circle.fill" }
        return nil
    }

    private var tint: Color {
        if progress?.problem != nil || take.status == .failed { return Brand.red }
        if take.status == .ready { return Brand.green }
        return linked ? Brand.bone : Brand.amber
    }

    private var detail: String {
        if let problem = progress?.problem { return problem }
        if take.status == .failed { return take.warnings.last ?? "Something went wrong" }
        if take.status == .ready, let camera = take.camera {
            let sound = take.mic == nil ? " · no Mac mic" : ""
            let note = take.warnings.first.map { "\n\($0)" } ?? ""
            let screen = take.screen == nil ? " · no screen" : ""
            return "\(when) · \(timecode(camera.seconds)) · \(bytes(camera.bytes))\(screen)\(sound)\(syncLine)\(note)"
        }
        guard let progress else { return "\(when) · open Clapless on the iPhone" }
        if progress.checking { return "\(bytes(progress.listed)) · making sure nothing is missing" }
        if !linked { return "\(bytes(progress.received)) of \(bytes(progress.listed)) · open Clapless on the iPhone" }
        let speed = progress.bytesPerSecond > 1000 ? " · \(bytes(Int(progress.bytesPerSecond)))/s" : ""
        if progress.recording {
            return "\(bytes(progress.listed - progress.received)) behind\(speed)"
        }
        var left = ""
        if progress.bytesPerSecond > 1000 {
            let seconds = Int((Double(progress.listed - progress.received) / progress.bytesPerSecond).rounded(.up))
            left = seconds >= 90 ? " · about \((seconds + 30) / 60) min left" : " · \(seconds) s left"
        }
        return "\(bytes(progress.received)) of \(bytes(progress.listed))\(speed)\(left)"
    }

    private func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, count)), countStyle: .file)
    }
}

/// A filled bar, or a travelling one when there is no number to show.
private struct ProgressBar: View {
    let fraction: Double?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        GeometryReader { bar in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.bone.opacity(0.14))
                if let fraction {
                    Capsule().fill(tint)
                        .frame(width: max(5, bar.size.width * fraction))
                        .animation(.linear(duration: 0.25), value: fraction)
                } else {
                    TimelineView(.animation(paused: still)) { time in
                        let phase = still ? 0.35 : time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                        Capsule().fill(tint)
                            .frame(width: bar.size.width * 0.3)
                            .offset(x: bar.size.width * (phase * 1.3 - 0.3))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "working")
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

/// Keeps the window above others, so it can sit beside whatever is being shown.
private struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let level: NSWindow.Level = floating ? .floating : .normal
        DispatchQueue.main.async { view.window?.level = level }
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
