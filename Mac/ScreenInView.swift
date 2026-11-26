import SwiftUI

/// Which screen is recorded, if any.
struct ScreenInView: View {
    @ObservedObject var model: MacModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.displays) { display in
                    Toggle(display.name, isOn: Binding(
                        get: { model.recordScreen && model.chosenDisplay?.id == display.id },
                        set: { _ in model.chooseScreen(display) }))
                }
                Divider()
                Toggle("Don't record the screen", isOn: Binding(
                    get: { !model.recordScreen }, set: { _ in model.chooseScreen(nil) }))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.recordScreen ? "display" : "display.trianglebadge.exclamationmark")
                        .font(.system(size: 11))
                    Text(title).font(Brand.font(12.5, 600)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.grey)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(model.recordScreen ? Brand.bone : Brand.grey)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(model.phase != .idle)
            .accessibilityLabel("Screen: \(title)")
            if model.recordScreen, !model.screenAllowed {
                Button("Allow") { model.allowScreen() }
                    .buttonStyle(PressStyle())
                    .font(Brand.font(12, 700))
                    .foregroundStyle(Brand.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Brand.amber, in: Capsule())
                    .help("Allow Clapless under Screen Recording, then quit and reopen it")
            } else {
                HStack(spacing: 5) {
                    Circle().fill(colour).frame(width: 7, height: 7)
                    Text(tag).font(Brand.font(11.5, 700)).foregroundStyle(colour)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Brand.bone.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var title: String {
        guard model.recordScreen else { return "Screen off" }
        return model.chosenDisplay?.name ?? "Choose a screen"
    }

    private var tag: String {
        if !model.recordScreen { return "Not recorded" }
        return model.chosenDisplay == nil ? "Not connected" : "Ready"
    }

    private var colour: Color {
        if !model.recordScreen { return Brand.grey }
        return model.chosenDisplay == nil ? Brand.red : Brand.green
    }
}
