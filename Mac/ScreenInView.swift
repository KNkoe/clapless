import SwiftUI

/// What is recorded from the screen, if anything. Click to change it.
struct ScreenInView: View {
    @ObservedObject var model: MacModel
    @Environment(\.unit) private var u

    var body: some View {
        DeckRow(label: "Screen") {
            HStack(spacing: 8 * u) {
                Button { model.askToRecord() } label: {
                    HStack(spacing: 6 * u) {
                        Text(model.recordScreen ? model.screenName : "Off")
                            .font(Brand.font(12 * u, 600)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.system(size: 8 * u, weight: .bold))
                            .foregroundStyle(Brand.grey)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(model.recordScreen ? Brand.bone : Brand.grey)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .idle)
                .help("Choose a whole screen, one app, or no screen")
                .accessibilityLabel("Screen: \(model.screenName)")
                if model.recordScreen, !model.screenAllowed {
                    Button { model.allowScreen() } label: {
                        Caption(text: "Allow", size: 9.5 * u, colour: Brand.ink)
                            .padding(.horizontal, 10 * u)
                            .frame(height: 20 * u)
                            .background(Brand.amber)
                    }
                    .buttonStyle(PressStyle())
                    .help("Allow Clapless under Screen Recording, then quit and reopen it")
                } else if model.recordScreen {
                    StateMark(text: tag, colour: colour)
                }
            }
            .padding(.trailing, 12 * u)
        }
    }

    private var tag: String {
        if model.screenBlocker == nil { return "Ready" }
        return model.screenApp == nil ? "Not connected" : "Not open"
    }

    private var colour: Color { model.screenBlocker == nil ? Brand.green : Brand.red }
}

/// A square lamp and a word: the state of an input.
struct StateMark: View {
    let text: String
    let colour: Color
    @Environment(\.unit) private var u

    var body: some View {
        HStack(spacing: 5 * u) {
            Rectangle().fill(colour).frame(width: 5 * u, height: 5 * u)
            Caption(text: text, size: 9.5 * u)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
