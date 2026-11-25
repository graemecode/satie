import AcousticCore
import Foundation
import WatchConnectivity

/// Receives closed-loop Apple Watch HealthKit HRV/HR target breath rates and remote transport commands
/// over WatchConnectivity so Satie's iPhone `DIVE` engine locks seamlessly to the user's wrist biometrics.
final class SatieWatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = SatieWatchBridge()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func pushState(mode: FocusSoundscape, isPlaying: Bool) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else { return }
        try? session.updateApplicationContext([
            "soundscape": mode.rawValue,
            "isPlaying": isPlaying,
            "updatedAt": Date().timeIntervalSince1970
        ])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handlePayload(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handlePayload(applicationContext)
    }

    private func handlePayload(_ payload: [String: Any]) {
        let targetBPM = payload["targetBreathBPM"] as? Double
        let command = payload["command"] as? String
        let soundscapeRaw = payload["soundscape"] as? String
        let durationMinutes = payload["durationMinutes"] as? Int

        Task { @MainActor in
            let state = SatieiOSState.shared
            if let bpm = targetBPM {
                state.updateBiofeedbackBreathBPM(bpm > 0 ? bpm : nil)
            }
            switch command {
            case "play":
                let mode = soundscapeRaw.flatMap(FocusSoundscape.init(rawValue:)) ?? .dive
                state.startFocusSound(mode, durationMinutes: durationMinutes)
            case "pause":
                state.stopFocusSound()
                state.updateBiofeedbackBreathBPM(nil)
            default:
                break
            }
        }
    }
}
