import Foundation
import HealthKit
import SwiftUI
import WatchConnectivity
import WatchKit

/// Apple Watch Taptic Breath + HealthKit HRV Closed-Loop Companion for Satie Deep Dive.
/// - Drives eyes-closed wrist haptics synchronized to Satie's exact 42% inhale / 58% extended exhale curve.
/// - Reads live HealthKit Heart Rate & HRV SDNN (when authorized) to feed `HRVResonanceController` and
///   stream the personalized target respiratory frequency over WatchConnectivity to iPhone `DIVE`.
@MainActor
final class SatieWatchController: NSObject, ObservableObject {
    @Published var isSessionActive: Bool = false
    @Published var breath01: Double = 0.0
    @Published var isInhaling: Bool = true
    @Published var targetBPM: Double = 6.0
    @Published var liveHeartRate: Double? = nil
    @Published var liveHRV: Double? = nil
    @Published var calmness01: Double = 0.5
    @Published var crownOverrideBPM: Double = 0.0 // 0 = auto HRV closed-loop

    private var pacer = BreathCyclePacer(initialBPM: 7.5)
    private var hrvController = HRVResonanceController(initialBPM: 6.2)
    private var sessionStart = Date()
    private var tickTimer: Timer?
    private var lastTick = Date()
    private var lastHapticStep: Int = -1
    private var lastWasInhaling: Bool = false

    private let healthStore = HKHealthStore()
    private var hrObserverQuery: HKObserverQuery?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    var isNight: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 20 || hour < 6
    }

    func toggleSession() {
        if isSessionActive {
            stopSession()
        } else {
            startSession()
        }
    }

    func startSession() {
        isSessionActive = true
        sessionStart = Date()
        lastTick = Date()
        lastHapticStep = -1
        pacer.reset(initialBPM: crownOverrideBPM > 4.0 ? crownOverrideBPM : 7.8)
        hrvController.reset(initialBPM: 6.2)

        WKInterfaceDevice.current().play(.start)
        requestHealthKitAndObserve()
        sendToPhone(["command": "play", "soundscape": "dive", "targetBreathBPM": targetBPM])

        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepFrame()
            }
        }
    }

    func stopSession() {
        isSessionActive = false
        tickTimer?.invalidate()
        tickTimer = nil
        if let q = hrObserverQuery {
            healthStore.stop(q)
            hrObserverQuery = nil
        }
        WKInterfaceDevice.current().play(.stop)
        sendToPhone(["command": "pause", "targetBreathBPM": 0.0])
    }

    private func stepFrame() {
        guard isSessionActive else { return }
        let now = Date()
        let dt = max(0.01, min(0.25, now.timeIntervalSince(lastTick)))
        lastTick = now
        let elapsed = now.timeIntervalSince(sessionStart)

        let override: Double? = crownOverrideBPM >= 4.5
            ? crownOverrideBPM
            : (hrvController.sampleCount > 0 ? hrvController.targetBreathBPM : nil)

        let val = pacer.step(elapsedSec: elapsed, dt: dt, targetBPMOverride: override)
        breath01 = val
        isInhaling = pacer.isInhaling
        targetBPM = pacer.currentBPM

        // Eyes-closed Taptic Engine choreography:
        // - Gentle ascending tactile taps during the 42% inhale swell (3 soft pulses)
        // - Single settling exhale cue at peak transition + deep rest silence on exhale
        let phase = pacer.phase
        if pacer.isInhaling {
            let inhaleStep = Int((phase / 0.42) * 3.0) // 0, 1, 2
            if inhaleStep != lastHapticStep {
                lastHapticStep = inhaleStep
                WKInterfaceDevice.current().play(inhaleStep == 0 ? .directionUp : .click)
            }
        } else if lastWasInhaling {
            // Turnaround crest -> soft exhale release cue
            lastHapticStep = -1
            WKInterfaceDevice.current().play(.directionDown)
        }
        lastWasInhaling = pacer.isInhaling
    }

    private func requestHealthKitAndObserve() {
        guard HKHealthStore.isHealthDataAvailable(),
              let hrType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return }

        healthStore.requestAuthorization(toShare: nil, read: [hrType, hrvType]) { [weak self] granted, _ in
            guard granted else { return }
            Task { @MainActor [weak self] in
                self?.fetchLatestPhysiology()
                self?.installHeartRateObserver(hrType: hrType)
            }
        }
    }

    private func installHeartRateObserver(hrType: HKQuantityType) {
        if let existing = hrObserverQuery {
            healthStore.stop(existing)
        }
        let query = HKObserverQuery(sampleType: hrType, predicate: nil) { [weak self] _, completion, error in
            defer { completion() }
            guard error == nil else { return }
            Task { @MainActor [weak self] in
                self?.fetchLatestPhysiology()
            }
        }
        hrObserverQuery = query
        healthStore.execute(query)
    }

    private func fetchLatestPhysiology() {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let hrQuery = HKSampleQuery(sampleType: hrType, predicate: nil, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            Task { @MainActor [weak self] in
                self?.ingestPhysiology(hr: bpm, sdnn: nil)
            }
        }
        let hrvQuery = HKSampleQuery(sampleType: hrvType, predicate: nil, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let ms = sample.quantity.doubleValue(for: .secondUnit(with: .milli))
            Task { @MainActor [weak self] in
                self?.ingestPhysiology(hr: nil, sdnn: ms)
            }
        }
        healthStore.execute(hrQuery)
        healthStore.execute(hrvQuery)
    }

    private func ingestPhysiology(hr: Double?, sdnn: Double?) {
        if let hr { liveHeartRate = hr }
        if let sdnn { liveHRV = sdnn }
        let newTarget = hrvController.ingest(heartRateBPM: hr, hrvSDNNms: sdnn)
        calmness01 = hrvController.calmnessIndex
        if isSessionActive && crownOverrideBPM < 4.5 {
            sendToPhone(["targetBreathBPM": newTarget])
        }
    }

    private func sendToPhone(_ payload: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            try? session.updateApplicationContext(payload)
        }
    }
}

extension SatieWatchController: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
}

struct SatieWatchRootView: View {
    @StateObject private var controller = SatieWatchController()

    private var accentColor: Color {
        controller.isNight
            ? Color(red: 0.90, green: 0.48, blue: 0.18) // Low-melanopic evening ember
            : Color(red: 0.72, green: 0.85, blue: 0.96) // Turrell Skyspace cerulean
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {
                HStack {
                    Text("SATIE · DIVE")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.60))
                    Spacer()
                    if let hr = controller.liveHeartRate {
                        Text("\(Int(hr.rounded())) ♥")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(accentColor.opacity(0.9))
                    }
                }
                .padding(.horizontal, 4)

                // Breathing Turrell Oculus concentric aperture (pure OLED black surround)
                ZStack {
                    let scale = 0.78 + 0.24 * controller.breath01
                    Circle()
                        .stroke(accentColor.opacity(0.22), lineWidth: 1.5)
                        .frame(width: 96, height: 96)
                        .scaleEffect(scale)
                    Circle()
                        .stroke(accentColor.opacity(0.45), lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .scaleEffect(scale)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [accentColor.opacity(0.92), accentColor.opacity(0.18), .clear],
                                center: .center,
                                startRadius: 2,
                                endRadius: 34
                            )
                        )
                        .frame(width: 58, height: 58)
                        .scaleEffect(scale)

                    VStack(spacing: 1) {
                        Text(controller.isSessionActive ? (controller.isInhaling ? "INHALE" : "EXHALE") : "TAP")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(.white.opacity(0.92))
                        Text(String(format: "%.1f bpm", controller.targetBPM))
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .contentShape(Circle())
                .onTapGesture {
                    controller.toggleSession()
                }
                .focusable(true)
                .digitalCrownRotation(
                    $controller.crownOverrideBPM,
                    from: 0.0,
                    through: 7.5,
                    by: 0.5,
                    sensitivity: .low,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )

                HStack(spacing: 6) {
                    Text(controller.crownOverrideBPM >= 4.5 ? "MANUAL" : (controller.liveHRV != nil ? "HRV LOCK" : "AUTO 5.5"))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accentColor.opacity(0.85))
                    if let hrv = controller.liveHRV {
                        Text("· \(Int(hrv.rounded())) ms")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

@main
struct SatieWatchApp: App {
    var body: some Scene {
        WindowGroup {
            SatieWatchRootView()
        }
    }
}
