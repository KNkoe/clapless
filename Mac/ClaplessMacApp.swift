import AppKit
import SwiftUI

@main
struct ClaplessMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Clapless", id: "studio") {
            MainView(model: delegate.model, mic: delegate.model.mic)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(MainView.design)
        // Portrait, at the right-hand edge, where it can sit beside whatever is being shown.
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect
            let design = MainView.design
            let width = min(design.width, (screen.height - 24) * design.width / design.height)
            let size = CGSize(width: width, height: width * design.height / design.width)
            return WindowPlacement(CGPoint(x: screen.maxX - size.width - 12, y: screen.minY + 12), size: size)
        }
        .commands {
            CommandMenu("Take") {
                Button("Start or Stop Take") { delegate.model.toggle() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Switch iPhone Camera") { delegate.model.switchLens() }
                Divider()
                Button("Forget Paired iPhone") { delegate.model.forgetPhone() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MacModel()
    private let control = ControlSocket()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would fight over the microphone, the take folders and the command socket.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        if let other = others.first {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        model.start()
        control.start { [model] command, argument, reply in
            MainActor.assumeIsolated { model.command(command, argument, reply: reply) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting during a take stops it properly first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.phase == .recording || model.phase == .starting else { return .terminateNow }
        model.stopTake(because: "Clapless was quit during the take") {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
