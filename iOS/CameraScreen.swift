import AVFoundation
import SwiftUI

/// The camera screen from the approved design: the whole recorded frame, corner guides,
/// READY or the red timecode, a red tally border while recording, and the bottom bar.
struct CameraScreen: View {
    @ObservedObject var model: PhoneModel
    @State private var showMac = false

    var body: some View {
        GeometryReader { screen in
            let w = screen.size.width / 100          // the design's unit: 1% of the screen width
            let dock = 38 * w
            ZStack {
                Brand.ink.ignoresSafeArea()
                VStack(spacing: 0) {
                    ZStack {
                        // Fitted, never filled: what you see is exactly what is recorded.
                        CameraPreview(session: model.camera.session, lens: model.lens, state: model.state) {
                            model.screenMirrored = $0
                        }
                        FramingGuides(unit: w).padding(8 * w)
                        VStack {
                            Spacer()
                            if model.state == .ready, !model.recordedYet, model.sending == nil, model.lensNote != .none {
                                let done = model.lensNote == .wiped
                                Button { model.dismissLensNote() } label: {
                                    Label(done ? "Lens wiped" : "Wipe the lens before you start",
                                          systemImage: done ? "checkmark" : "sparkles")
                                        .font(Brand.font(3.6 * w, 700))
                                        .foregroundStyle(Brand.ink)
                                        .padding(.horizontal, 3.4 * w).padding(.vertical, 2 * w)
                                        .background(done ? Brand.green : Brand.bone.opacity(0.92), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(.bottom, 3 * w)
                                .animation(.snappy(duration: 0.25), value: done)
                            }
                            if let sending = model.sending {
                                SendingChip(sending: sending, linked: model.macName != nil, unit: w)
                                    .padding(.bottom, 3 * w)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .animation(.smooth(duration: 0.3), value: model.sending == nil)
                    }
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bar(w).frame(height: dock)
                }
                top(w)
            }
            .overlay {
                if model.state == .recording || model.state == .finishing {
                    RoundedRectangle(cornerRadius: 47, style: .continuous)
                        .strokeBorder(Brand.red, lineWidth: 1.6 * w)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay { PairingOverlay(model: model) }
        .confirmationDialog(model.pairedName.map { "Paired with \($0)" } ?? "No Mac paired", isPresented: $showMac,
                            titleVisibility: .visible) {
            Button("Pair a different Mac") { model.startPairing() }
            if model.pairedName != nil {
                Button("Forget this Mac", role: .destructive) { model.forgetMac() }
            }
        }
    }

    private func top(_ w: CGFloat) -> some View {
        VStack(spacing: 2.4 * w) {
            switch model.state {
            case .recording, .finishing:
                Text(model.state == .finishing ? "SAVING" : timecode(model.seconds))
                    .font(Brand.digits(8.4 * w, 700))
                    .foregroundStyle(Brand.ink)
                    .padding(.horizontal, 3 * w).padding(.vertical, 1 * w)
                    .background(Brand.red)
            default:
                Text(model.state == .ready ? "READY" : model.state == .starting ? "STARTING" : "NOT READY")
                    .font(Brand.font(6.4 * w, 700))
                    .tracking(0.9 * w)
                    .foregroundStyle(Brand.bone)
                    .padding(.horizontal, 3 * w).padding(.vertical, 1 * w)
                    .border(Brand.bone, width: 0.7 * w)
                    .shadow(color: .black.opacity(0.6), radius: 3)
            }
            ForEach(([model.problem].compactMap { $0 }) + model.warnings, id: \.self) { text in
                Text(text)
                    .font(Brand.font(3.6 * w))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.ink)
                    .padding(.horizontal, 2.4 * w).padding(.vertical, 1.2 * w)
                    .background(Brand.amber)
            }
            Spacer()
        }
        .padding(.top, 3 * w)
        .padding(.horizontal, 6 * w)
    }

    private func bar(_ w: CGFloat) -> some View {
        HStack {
            Button {
                model.choose(model.lens == .back ? .front : .back)
            } label: {
                VStack(spacing: 0.6 * w) {
                    Text("4K 30")
                    Text(model.lens == .back ? "BACK 1×" : "FRONT").foregroundStyle(Brand.grey)
                }
                .frame(width: 24 * w, height: 18 * w)
                .contentShape(Rectangle())
            }
            .disabled(model.state != .ready)
            .accessibilityLabel("Camera: \(model.lens == .back ? "back" : "front"). Tap to switch.")
            Spacer()
            RecordButton(unit: w, recording: model.state == .recording) { model.toggleFromPhone() }
                .disabled(model.state != .ready && model.state != .recording)
                .opacity(model.state == .ready || model.state == .recording ? 1 : 0.4)
            Spacer()
            Button { showMac = true } label: {
                VStack(spacing: 0.6 * w) {
                    Text(model.macName != nil ? "MAC" : model.pairedName != nil ? "FINDING" : "NO MAC")
                    Text(model.macName != nil ? "LINKED" : model.pairedName != nil ? "MAC" : "PAIRED")
                }
                .foregroundStyle(model.macName != nil ? Brand.bone : Brand.amber)
                .frame(width: 24 * w, height: 18 * w)
                .contentShape(Rectangle())
            }
            .disabled(model.state == .recording)
        }
        .font(Brand.font(4.2 * w))
        .foregroundStyle(Brand.bone)
        .buttonStyle(.plain)
        .padding(.horizontal, 6 * w)
    }
}

/// That the take is on its way, and that the app must stay open until it has arrived.
private struct SendingChip: View {
    let sending: PhoneModel.Sending
    let linked: Bool
    let unit: CGFloat

    private var title: String {
        sending.arrived ? "On your Mac" : linked ? "Sending to Mac" : "Not sent yet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1.6 * unit) {
            HStack {
                Text(title).font(Brand.font(4.2 * unit, 700))
                Spacer()
                if sending.arrived {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
                } else {
                    Text("\(Int(sending.fraction * 100))%").font(Brand.digits(4.2 * unit, 700))
                }
            }
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.bone.opacity(0.18))
                    Capsule().fill(sending.arrived ? Brand.green : Brand.bone)
                        .frame(width: bar.size.width * min(1, max(0, sending.fraction)))
                }
            }
            .frame(height: 1.4 * unit)
            .animation(.linear(duration: 0.3), value: sending.fraction)
            if !sending.arrived {
                Text(linked ? "Keep Clapless open until it arrives" : "Waiting for your Mac")
                    .font(Brand.font(3.2 * unit))
                    .foregroundStyle(linked ? Brand.grey : Brand.amber)
            }
        }
        .foregroundStyle(Brand.bone)
        .padding(3.4 * unit)
        .frame(width: 82 * unit)
        .background(Brand.ink.opacity(0.84), in: RoundedRectangle(cornerRadius: 4 * unit, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct RecordButton: View {
    let unit: CGFloat
    let recording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Brand.bone, lineWidth: 1.3 * unit)
                RoundedRectangle(cornerRadius: recording ? 1.4 * unit : 6.8 * unit)
                    .fill(Brand.record)
                    .frame(width: (recording ? 7.4 : 13.6) * unit, height: (recording ? 7.4 : 13.6) * unit)
            }
            .frame(width: 19 * unit, height: 19 * unit)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.22), value: recording)
        .sensoryFeedback(.impact, trigger: recording)
        .accessibilityLabel(recording ? "Stop recording" : "Record the camera")
    }
}

private struct FramingGuides: View {
    let unit: CGFloat

    var body: some View {
        GeometryReader { area in
            let side = 10 * unit
            Path { path in
                let size = area.size
                for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (size.width, 0, -1, 1),
                                       (0, size.height, 1, -1), (size.width, size.height, -1, -1)] {
                    path.move(to: CGPoint(x: x, y: y + dy * side))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + dx * side, y: y))
                }
            }
            .stroke(Brand.bone.opacity(0.8), lineWidth: 0.7 * unit)
        }
        .allowsHitTesting(false)
    }
}

/// The iPhone's own live picture, shown as a mirror for both cameras. This changes only what is on
/// screen: the frames that are recorded and sent to the Mac come from a separate, unmirrored output.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    // Changing either rebuilds the preview's connection, so the mirror has to be set again.
    let lens: Lens
    let state: CaptureState
    let mirrored: (Bool) -> Void

    final class View: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var mirrored: ((Bool) -> Void)?

        func mirror() {
            guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
            if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
            if !connection.isVideoMirrored { connection.isVideoMirrored = true }
            mirrored?(connection.isVideoMirrored)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            mirror()
        }
    }

    func makeUIView(context: Context) -> View {
        let view = View()
        view.backgroundColor = .black
        view.preview.session = session
        view.preview.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: View, context: Context) {
        view.mirrored = mirrored
        // After this update, so the model is not changed while the screen is being drawn.
        DispatchQueue.main.async { view.mirror() }
    }
}
