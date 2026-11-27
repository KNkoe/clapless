import AppKit
import SwiftUI

/// Asked every time the record button is pressed: a whole screen, one app, or no screen.
/// The last answer is already picked, so Return records straight away.
struct RecordChooser: View {
    @ObservedObject var model: MacModel

    var body: some View {
        ZStack {
            Brand.ink
            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    Text("What should be recorded?").font(Brand.font(19, 700)).foregroundStyle(Brand.bone)
                    Caption(text: "Camera and voice are always on")
                }
                .padding(.top, 48)
                if !model.screenAllowed { permission }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        section("Whole screen")
                        ForEach(model.displays) { display in
                            row(display.name, detail: model.displays.count > 1 ? display.size : nil,
                                picked: model.recordScreen && model.screenApp == nil
                                    && model.chosenDisplay?.id == display.id) {
                                Image(systemName: "display").font(.system(size: 15))
                            } pick: { model.chooseScreen(display) }
                        }
                        section("One app")
                        if let app = model.screenApp, model.recordScreen, !model.apps.contains(where: { $0.id == app.id }) {
                            row(app.name, detail: "Not open", picked: true) {
                                Image(systemName: "macwindow").font(.system(size: 15))
                            } pick: {}
                        }
                        ForEach(model.apps) { app in
                            row(app.name, detail: app.hasWindow ? nil : "Not on screen now",
                                picked: model.recordScreen && model.screenApp?.id == app.id) {
                                if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                                }
                            } pick: { model.chooseApp(app) }
                        }
                        section("No screen")
                        row("Camera and voice only", detail: nil, picked: !model.recordScreen) {
                            Image(systemName: "person.crop.rectangle").font(.system(size: 15))
                        } pick: { model.chooseScreen(nil) }
                    }
                }
                footer
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isModal)
    }

    private var permission: some View {
        Button { model.allowScreen() } label: {
            Text("Allow screen recording, then reopen Clapless")
                .font(Brand.font(12, 700))
                .foregroundStyle(Brand.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Brand.amber)
        }
        .buttonStyle(PressStyle())
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text(model.blocker ?? explanation)
                .font(Brand.font(11.5, 600))
                .foregroundStyle(model.blocker == nil ? Brand.grey : Brand.amber)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
            Button { model.startTake() } label: {
                HStack(spacing: 8) {
                    Circle().fill(Brand.ink).frame(width: 10, height: 10)
                    Text("Start recording").font(Brand.font(16, 700))
                }
                .foregroundStyle(Brand.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Brand.red)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(model.blocker != nil)
            .opacity(model.blocker == nil ? 1 : 0.35)
            Button("Cancel") { model.stopAsking() }
                .buttonStyle(.plain)
                .font(Brand.font(13))
                .foregroundStyle(Brand.grey)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var explanation: String {
        if !model.recordScreen { return "Nothing on your screen is recorded" }
        if let app = model.screenApp { return "\(app.name) comes to the front. Only its window is recorded." }
        return "Everything on that screen except Clapless"
    }

    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: title)
            Rule()
        }
        .padding(.top, 14)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ title: String, detail: String?, picked: Bool, @ViewBuilder icon: () -> some View,
                     pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                icon().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Brand.font(13, 600)).lineLimit(1).truncationMode(.middle)
                    if let detail { Text(detail).font(Brand.digits(10.5, 500)).foregroundStyle(Brand.grey) }
                }
                Spacer(minLength: 0)
                Rectangle()
                    .fill(picked ? Brand.green : .clear)
                    .frame(width: 8, height: 8)
                    .padding(2)
                    .overlay(Rectangle().strokeBorder(picked ? Brand.green : Brand.rule, lineWidth: 1))
            }
            .foregroundStyle(Brand.bone)
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .background(Brand.bone.opacity(picked ? 0.08 : 0))
            .overlay(alignment: .bottom) { Rule() }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
