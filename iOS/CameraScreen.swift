import AVFoundation
import SwiftUI

/// The camera screen, drawn like the Mac's window: the whole recorded frame across the full width,
/// a few ruled tags on it, a red tally border while recording, and a ruled bar underneath.
struct CameraScreen: View {
    @ObservedObject var model: PhoneModel
    @State private var showMac = false

    var body: some View {
        GeometryReader { screen in
            let w = screen.size.width / 100          // the design's unit: 1% of the screen width
            VStack(spacing: 0) {
                picture(w)
                    // Fitted, never filled: what you see is exactly what is recorded. The bar gets
                    // the height that is left, so the picture reaches both sides.
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                Rule()
                bar(w).frame(minHeight: 16 * w, maxHeight: .infinity)
            }
            .background(Brand.ink.ignoresSafeArea())
            .overlay {
                if model.state == .recording || model.state == .finishing {
                    RoundedRectangle(cornerRadius: 47, style: .continuous)
                        .strokeBorder(Brand.red, lineWidth: 1.6 * w)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { model.touched() })
        .overlay {
            if model.dark || model.resting { QuietScreen(model: model) }
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

    private func picture(_ w: CGFloat) -> some View {
        ZStack {
            CameraPreview(session: model.camera.session, lens: model.lens, state: model.state) {
                model.screenMirrored = $0
            }
            .opacity(model.dark || model.resting ? 0 : 1)
            CornerMarks(length: 5 * w)
                .stroke(Brand.bone.opacity(0.65), lineWidth: 1)
                .padding(3 * w)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { top(w).padding(6 * w) }
        .overlay(alignment: .bottom) {
            VStack(spacing: 2 * w) {
                if model.state == .ready, !model.recordedYet, model.sending == nil, model.lensNote != .none {
                    lensNote(w)
                }
                if let sending = model.sending {
                    SendingRow(sending: sending, linked: model.macName != nil, unit: w)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(6 * w)
            .animation(.smooth(duration: 0.3), value: model.sending == nil)
        }
    }

    private func top(_ w: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2 * w) {
            let recording = model.state == .recording || model.state == .finishing
            HStack(spacing: 2.4 * w) {
                Rectangle()
                    .fill(recording ? Brand.ink : model.state == .ready ? Brand.green : Brand.amber)
                    .frame(width: 2.4 * w, height: 2.4 * w)
                if recording {
                    Text(model.state == .finishing ? "SAVING" : timecode(model.seconds))
                        .font(Brand.digits(7 * w, 700))
                        .foregroundStyle(Brand.ink)
                } else {
                    Caption(text: model.state == .ready ? "Ready" : model.state == .starting ? "Starting" : "Not ready",
                            size: 4.4 * w, colour: Brand.bone)
                }
            }
            .padding(.horizontal, 3 * w)
            .frame(height: 10 * w)
            .background(recording ? Brand.red : Brand.ink.opacity(0.76))
            .overlay(Rectangle().strokeBorder(recording ? .clear : Brand.rule, lineWidth: 1))
            ForEach(([model.problem].compactMap { $0 }) + model.warnings, id: \.self) { text in
                HStack(alignment: .firstTextBaseline, spacing: 2 * w) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 2.8 * w))
                        .foregroundStyle(Brand.amber)
                    Text(text).font(Brand.font(3.6 * w, 600)).foregroundStyle(Brand.bone)
                }
                .padding(.horizontal, 3 * w).padding(.vertical, 1.8 * w)
                .background(Brand.ink.opacity(0.84))
                .overlay(Rectangle().strokeBorder(Brand.amber.opacity(0.7), lineWidth: 1))
            }
        }
    }

    private func lensNote(_ w: CGFloat) -> some View {
        let done = model.lensNote == .wiped
        return Button { model.dismissLensNote() } label: {
            HStack(spacing: 2.4 * w) {
                Rectangle().fill(done ? Brand.green : Brand.bone).frame(width: 2 * w, height: 2 * w)
                Text(done ? "Lens wiped" : "Wipe the lens before you start").font(Brand.font(3.6 * w, 600))
                Spacer()
                if !done { Caption(text: "Done", size: 3 * w, colour: Brand.bone) }
            }
            .foregroundStyle(Brand.bone)
            .padding(.horizontal, 3.4 * w)
            .frame(minHeight: 11 * w)
            .background(Brand.ink.opacity(0.84))
            .overlay(Rectangle().strokeBorder(Brand.rule, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.25), value: done)
    }

    private func bar(_ w: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button {
                model.choose(model.lens == .back ? .front : .back)
            } label: {
                cell(w, top: "4K 30", bottom: model.lens == .back ? "Back 1×" : "Front", colour: Brand.grey)
            }
            .disabled(model.state != .ready)
            .accessibilityLabel("Camera: \(model.lens == .back ? "back" : "front"). Tap to switch.")
            Rule(vertical: true)
            RecordButton(unit: w, recording: model.state == .recording) { model.toggleFromPhone() }
                .disabled(model.state != .ready && model.state != .recording)
                .opacity(model.state == .ready || model.state == .recording ? 1 : 0.4)
                .frame(width: 30 * w)
            Rule(vertical: true)
            Button { showMac = true } label: {
                cell(w, top: model.macName != nil ? "Mac" : model.pairedName != nil ? "Finding" : "No Mac",
                     bottom: model.macName != nil ? "Linked" : model.pairedName != nil ? "Mac" : "Paired",
                     colour: model.macName != nil ? Brand.green : Brand.amber)
            }
            .disabled(model.state == .recording)
        }
        .buttonStyle(.plain)
    }

    private func cell(_ w: CGFloat, top: String, bottom: String, colour: Color) -> some View {
        VStack(spacing: 1.2 * w) {
            Caption(text: top, size: 3.6 * w, colour: Brand.bone)
            Caption(text: bottom, size: 3.2 * w, colour: colour)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

/// Black, which costs an OLED screen next to nothing: either the Mac is showing the picture, or
/// the camera is resting. A tap brings everything back.
private struct QuietScreen: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        GeometryReader { screen in
            let w = screen.size.width / 100
            VStack(spacing: 4 * w) {
                if model.state == .recording || model.state == .finishing {
                    HStack(spacing: 2 * w) {
                        Circle().fill(Brand.red).frame(width: 3 * w, height: 3 * w)
                        Text(model.state == .finishing ? "SAVING" : timecode(model.seconds))
                            .font(Brand.digits(7 * w, 700))
                            .foregroundStyle(Brand.red)
                    }
                }
                Text(model.disconnected && model.resting ? "Disconnected"
                     : model.resting ? "Camera resting" : "Your Mac is showing the picture")
                    .font(Brand.font(4.6 * w, 700))
                    .foregroundStyle(Brand.bone.opacity(0.7))
                if let sending = model.sending {
                    Text(sending.arrived ? "On your Mac" : "Sending to Mac \(Int(sending.fraction * 100))%")
                        .font(Brand.digits(4 * w, 700))
                        .foregroundStyle(sending.arrived ? Brand.green : Brand.bone.opacity(0.7))
                }
                ForEach(model.resting ? [] : ([model.problem].compactMap { $0 }) + model.warnings, id: \.self) {
                    Text($0).font(Brand.font(3.6 * w)).foregroundStyle(Brand.amber)
                }
                if model.resting, let left = model.closingIn {
                    Text("Clapless closes in \(left / 60):\(String(format: "%02d", left % 60))")
                        .font(Brand.digits(4.6 * w, 700))
                        .foregroundStyle(Brand.bone)
                        .contentTransition(.numericText(countsDown: true))
                }
                Text(!model.resting ? "Tap to see it here"
                     : model.disconnected ? "Camera and light are off. Tap to keep it open."
                     : "No Mac for a while. Tap to wake.")
                    .font(Brand.font(3.6 * w))
                    .foregroundStyle(Brand.grey)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8 * w)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { model.touched() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// That the take is on its way, and that the app must stay open until it has arrived.
private struct SendingRow: View {
    let sending: PhoneModel.Sending
    let linked: Bool
    let unit: CGFloat

    private var title: String {
        sending.arrived ? "On your Mac" : linked ? "Sending to Mac" : "Not sent yet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * unit) {
            HStack {
                Text(title).font(Brand.font(4 * unit, 700))
                Spacer()
                if sending.arrived {
                    Image(systemName: "checkmark").foregroundStyle(Brand.green)
                } else {
                    Text("\(Int(sending.fraction * 100))%").font(Brand.digits(4 * unit, 700))
                }
            }
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Brand.rule)
                    Rectangle().fill(sending.arrived ? Brand.green : Brand.bone)
                        .frame(width: bar.size.width * min(1, max(0, sending.fraction)))
                }
            }
            .frame(height: 0.8 * unit)
            .animation(.linear(duration: 0.3), value: sending.fraction)
            if !sending.arrived {
                Text(linked ? "Keep Clapless open until it arrives" : "Waiting for your Mac")
                    .font(Brand.font(3.2 * unit))
                    .foregroundStyle(linked ? Brand.grey : Brand.amber)
            }
        }
        .foregroundStyle(Brand.bone)
        .padding(3.4 * unit)
        .background(Brand.ink.opacity(0.84))
        .overlay(Rectangle().strokeBorder(Brand.rule, lineWidth: 1))
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
                Circle().strokeBorder(Brand.bone, lineWidth: 0.5 * unit)
                RoundedRectangle(cornerRadius: recording ? 0.8 * unit : 5.8 * unit)
                    .fill(Brand.red)
                    .frame(width: (recording ? 6 : 11.6) * unit, height: (recording ? 6 : 11.6) * unit)
            }
            .frame(width: 15 * unit, height: 15 * unit)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.22), value: recording)
        .sensoryFeedback(.impact, trigger: recording)
        .accessibilityLabel(recording ? "Stop recording" : "Record the camera")
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
