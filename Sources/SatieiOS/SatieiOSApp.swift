import AcousticCore
import SwiftUI

@main
struct SatieiOSApp: App {
    @StateObject private var state = SatieiOSState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SatieiOSRootView(state: state)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    state.setForeground(phase == .active)
                }
                .onContinueUserActivity(SatieHandoff.activityType) { activity in
                    if let session = SatieHandoff(userInfo: activity.userInfo) {
                        state.continueHandoff(session)
                    }
                }
        }
    }
}
