import SwiftUI

/// Pairing once: pick the iPhone, then check both screens show the same six digits.
struct PairingView: View {
    @ObservedObject var model: MacModel

    var body: some View {
        // Only in the way once there is an iPhone to pair with, so the microphone can be set up first.
        if (model.pairedName == nil && !model.candidates.isEmpty) || model.pairingPhase != nil {
            ZStack {
                Brand.ink.opacity(0.96)
                VStack(spacing: 18) {
                    Wordmark(size: 34)
                    content
                }
                .padding(28)
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder private var content: some View {
        switch model.pairingPhase {
        case nil:
            heading("Pair your iPhone")
            ForEach(model.candidates) { phone in
                primary("Pair with \(phone.name)") { model.pair(phone) }
            }
            if let problem = model.linkProblem { note(problem) }
        case .exchanging:
            heading("Connecting")
            ProgressView().controlSize(.small)
            quiet("Cancel") { model.cancelPairing() }
        case .compare(let code, let phone):
            heading("Same code on \(phone)?")
            digits(code)
            note("Only continue if your iPhone shows exactly this code.")
            primary("Codes match") { model.confirmPairing() }
            quiet("They differ: cancel") { model.cancelPairing() }
        case .waitingForPeer(let code, _):
            digits(code)
            note("Now tap Codes match on your iPhone.")
            ProgressView().controlSize(.small)
            quiet("Cancel") { model.cancelPairing() }
        case .done(let record):
            heading("Paired with \(record.peerName)")
            note("You will not need a code again.")
        case .failed(let why):
            heading("Not paired")
            note(why)
            primary("Try again") { model.dismissPairing() }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(Brand.font(21, 700)).foregroundStyle(Brand.bone).multilineTextAlignment(.center)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Brand.font(13)).foregroundStyle(Brand.grey).multilineTextAlignment(.center)
    }

    private func digits(_ code: String) -> some View {
        Text("\(code.prefix(3)) \(code.suffix(3))")
            .font(Brand.digits(52, 700))
            .foregroundStyle(Brand.bone)
            .accessibilityLabel(code.map(String.init).joined(separator: " "))
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Brand.font(16, 700)).foregroundStyle(Brand.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Brand.red, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }

    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Brand.font(13))
            .foregroundStyle(Brand.grey)
    }
}
