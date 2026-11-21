import SwiftUI

@main
struct SatieiOSApp: App {
    @StateObject private var state = SatieiOSState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SatieiOSRootView(state: state)
                .preferredColorScheme(.dark)
                .statusBarHidden(false)
                .onChange(of: scenePhase) { _, phase in
                    state.setForeground(phase == .active)
                }
        }
    }
}
