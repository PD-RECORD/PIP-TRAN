import SwiftUI

@main
struct PiPTranslatorApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
        .onChange(of: phase) { _, p in
            model.setForeground(p == .active)
        }
    }
}
