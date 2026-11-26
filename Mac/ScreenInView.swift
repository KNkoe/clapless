import SwiftUI

/// What is recorded from the screen, if anything. Click to change it.
struct ScreenInView: View {
    @ObservedObject var model: MacModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.askToRecord() } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11))
                    Text(model.screenName).font(Brand.font(12.5, 600)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.grey)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(model.recordScreen ? Brand.bone : Brand.grey)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.phase != .idle)
            .help("Choose a whole screen, one app, or no screen")
            .accessibilityLabel("Screen: \(model.screenName)")
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

    private var symbol: String {
        if !model.recordScreen { return "display.trianglebadge.exclamationmark" }
        return model.screenApp == nil ? "display" : "macwindow"
    }

    private var tag: String {
        if !model.recordScreen { return "Not recorded" }
        if model.screenBlocker == nil { return "Ready" }
        return model.screenApp == nil ? "Not connected" : "Not open"
    }

    private var colour: Color {
        if !model.recordScreen { return Brand.grey }
        return model.screenBlocker == nil ? Brand.green : Brand.red
    }
}
