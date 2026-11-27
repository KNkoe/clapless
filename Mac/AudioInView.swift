import SwiftUI

/// Audio In: which microphone, its live level, and whether it is usable.
struct AudioInView: View {
    @ObservedObject var mic: MicMonitor
    let locked: Bool     // no changing microphones during a take

    @Environment(\.unit) private var u

    var body: some View {
        DeckRow(label: "Mic") {
            VStack(alignment: .leading, spacing: 6 * u) {
                HStack(spacing: 8 * u) {
                    picker
                    StateMark(text: tag, colour: colour)
                }
                LevelMeter(bar: mic.bar, peak: mic.peak, live: mic.state != .notConnected)
                    .frame(height: 5 * u)
            }
            .padding(.trailing, 12 * u)
        }
        .help(note ?? "")
    }

    private var picker: some View {
        Menu {
            if mic.devices.isEmpty { Text("No microphones found") }
            Toggle(mic.defaultName.map { "Mac default (\($0))" } ?? "Mac default", isOn: Binding(
                get: { mic.selectedID == nil },
                set: { _ in mic.select(nil) }))
            Divider()
            ForEach(mic.devices) { device in
                Toggle(device.name, isOn: Binding(
                    get: { mic.selectedID == device.id },
                    set: { _ in mic.select(device) }))
            }
            if let id = mic.selectedID, !mic.devices.contains(where: { $0.id == id }) {
                Toggle("\(mic.selectedName ?? "Your microphone") (off)", isOn: .constant(true)).disabled(true)
            }
        } label: {
            HStack(spacing: 6 * u) {
                Text(title).font(Brand.font(12 * u, 600)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8 * u, weight: .bold)).foregroundStyle(Brand.grey)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Brand.bone)
            .frame(maxWidth: .infinity, minHeight: 18 * u)
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
        guard let name = mic.activeName else { return "No microphone" }
        return mic.selectedID == nil ? "Default: \(name)" : name
    }

    private var tag: String {
        switch mic.state {
        case .connected: return mic.standInNote == nil ? "Connected" : "Stand-in"
        case .noSound: return "No sound"
        case .notConnected: return "Not connected"
        }
    }

    private var note: String? {
        if mic.accessDenied { return "Microphone access is off in System Settings" }
        switch mic.state {
        case .connected: return mic.standInNote
        case .noSound: return [mic.standInNote, "Check the mic is on"].compactMap { $0 }.joined(separator: " ")
        case .notConnected: return "Start is off until a microphone is connected"
        }
    }

    /// Amber whenever another microphone is standing in.
    private var colour: Color {
        switch mic.state {
        case .connected: return mic.standInNote == nil ? Brand.green : Brand.amber
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
                context.fill(Path(cell), with: .color(colour))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue(live ? "\(Int(bar.rounded())) decibels" : "not connected")
    }
}
