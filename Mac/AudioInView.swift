import SwiftUI

/// Audio In: which microphone, its live level, and whether it is usable.
struct AudioInView: View {
    @ObservedObject var mic: MicMonitor
    let locked: Bool     // no changing microphones during a take

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                picker
                HStack(spacing: 5) {
                    Circle().fill(colour).frame(width: 7, height: 7)
                    Text(tag).font(Brand.font(11.5, 700)).foregroundStyle(colour)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
            LevelMeter(bar: mic.bar, peak: mic.peak, live: mic.state != .notConnected)
                .frame(height: 7)
            if let note {
                Text(note).font(Brand.font(11)).foregroundStyle(colour)
            }
        }
        .padding(11)
        .background(Brand.bone.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(mic.state == .connected ? .clear : colour.opacity(0.55), lineWidth: 1))
    }

    private var picker: some View {
        Menu {
            if mic.devices.isEmpty { Text("No microphones found") }
            ForEach(mic.devices) { device in
                Toggle(device.name, isOn: Binding(
                    get: { mic.selectedID == device.id },
                    set: { _ in mic.select(device) }))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").font(.system(size: 11))
                Text(title).font(Brand.font(12.5, 600)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.grey)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Brand.bone)
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(locked)
        .help("Audio In")
        .accessibilityLabel("Audio In: \(title)")
    }

    private var title: String {
        guard mic.selectedID != nil else { return "Choose a microphone" }
        return mic.selectedName ?? "Microphone"
    }

    private var tag: String {
        switch mic.state {
        case .connected: return "Connected"
        case .noSound: return "No sound"
        case .notConnected: return "Not connected"
        }
    }

    private var note: String? {
        if mic.accessDenied { return "Microphone access is off in System Settings" }
        switch mic.state {
        case .connected: return nil
        case .noSound: return "Check the mic is on"
        case .notConnected: return mic.selectedID == nil ? nil : "Start is off until this mic is back"
        }
    }

    private var colour: Color {
        switch mic.state {
        case .connected: return Brand.green
        case .noSound: return Brand.amber
        case .notConnected: return Brand.red
        }
    }
}

/// Twenty-eight cells: green, then amber, then red, with a bone-white peak that holds.
struct LevelMeter: View {
    let bar: Double
    let peak: Double
    let live: Bool

    var body: some View {
        Canvas { context, size in
            let count = MicLevel.cells
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let lit = live ? MicLevel.litCells(bar) : 0
            let peakCell = live && peak > MicLevel.floorDB ? MicLevel.litCells(peak) - 1 : -1
            for i in 0..<count {
                let colour: Color = i == peakCell ? Brand.bone
                    : i >= lit ? Brand.bone.opacity(0.1)
                    : i >= 25 ? Brand.red : i >= 21 ? Brand.amber : Brand.green
                let cell = CGRect(x: CGFloat(i) * (width + gap), y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: cell, cornerRadius: 1.5), with: .color(colour))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue(live ? "\(Int(bar.rounded())) decibels" : "not connected")
    }
}
