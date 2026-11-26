import SwiftUI

/// Pairing once: the same six digits show on both screens and the person confirms on both.
struct PairingOverlay: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        if let phase = model.pairingPhase {
            ZStack {
                Brand.ink.opacity(0.96).ignoresSafeArea()
                VStack(spacing: 22) {
                    Wordmark(size: 44)
                    Spacer().frame(height: 8)
                    content(phase)
                }
                .padding(32)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private func content(_ phase: PairingSession.Phase) -> some View {
        switch phase {
        case .exchanging:
            ProgressView().tint(Brand.bone)
            heading("Pair with your Mac")
            note("Open Clapless on your Mac, on the same Wi-Fi, and click Pair.")
            quiet("Cancel") { model.cancelPairing() }
        case .compare(let code, let mac):
            heading("Same code on \(mac)?")
            digits(code)
            note("Only continue if your Mac shows exactly this code.")
            primary("Codes match") { model.confirmPairing() }
            quiet("They differ: cancel") { model.cancelPairing() }
        case .waitingForPeer(let code, _):
            digits(code)
            note("Now click Codes match on your Mac.")
            ProgressView().tint(Brand.bone)
            quiet("Cancel") { model.cancelPairing() }
        case .done(let record):
            heading("Paired with \(record.peerName)")
            note("You will not need a code again.")
        case .failed(let why):
            heading("Not paired")
            note(why)
            primary("Pair again") { model.startPairing() }
            quiet("Close") { model.pairingPhase = nil }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(Brand.font(26, 700)).foregroundStyle(Brand.bone).multilineTextAlignment(.center)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Brand.font(14)).foregroundStyle(Brand.grey).multilineTextAlignment(.center)
    }

    private func digits(_ code: String) -> some View {
        Text("\(code.prefix(3)) \(code.suffix(3))")
            .font(Brand.digits(52, 700))
            .foregroundStyle(Brand.bone)
            .accessibilityLabel(code.map(String.init).joined(separator: " "))
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Brand.font(20, 700)).foregroundStyle(Brand.ink)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Brand.red)
        }
        .buttonStyle(.plain)
    }

    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Brand.font(14))
            .foregroundStyle(Brand.grey)
            .frame(minHeight: 44)
    }
}
