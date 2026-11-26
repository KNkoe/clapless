import SwiftUI

@main
struct ClaplessPhoneApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var scene

    var body: some Scene {
        WindowGroup {
            CameraScreen(model: model)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
                .onAppear { model.activate() }
        }
        .onChange(of: scene) { _, new in
            if new == .active { model.activate() }
            if new == .background { model.enterBackground() }
        }
    }
}
