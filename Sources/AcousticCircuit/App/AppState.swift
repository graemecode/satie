import AcousticCore
import AppKit
import Combine
import Foundation

enum VisualPreset: Int, CaseIterable, Identifiable, Sendable {
    case circuit = 0
    case ecology = 1
    case phosphor = 2
    case liquid = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .circuit: return "01 The Circuit"
        case .ecology: return "02 Ecology Wall"
        case .phosphor: return "03 Phosphor Scope"
        case .liquid: return "04 Liquid Warp"
        }
    }

    var shortTitle: String {
        switch self {
        case .circuit: return "01 Circuit"
        case .ecology: return "02 Ecology"
        case .phosphor: return "03 Scope"
        case .liquid: return "04 Liquid"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings = SettingsStore()

    @Published var preset: VisualPreset {
        didSet { settings.presetRaw = preset.rawValue }
    }
    @Published var amberPhosphor: Bool {
        didSet { settings.amberPhosphor = amberPhosphor }
    }
    @Published var showMenuBarKey: Bool {
        didSet { settings.showMenuBarKey = showMenuBarKey }
    }
    @Published var sensitivity: SensitivityMode {
        didSet { settings.sensitivity = sensitivity }
    }
    @Published var launchAtLogin: Bool = false

    @Published var demoMode: Bool = false
    @Published var tapTarget: TapTarget = .systemAll
    @Published var tapStatus: TapStatus = .stopped
    @Published var audioProcesses: [AudioProcessInfo] = []
    @Published var metadata: NowPlayingMetadata = .idle
    @Published var isPopoverOpen: Bool = false
    @Published var isMiniHUDOpen: Bool = false
    @Published var isStudioOpen: Bool = false
    @Published var isFullscreen: Bool = false

    private(set) var snapshot: AcousticSnapshot = .empty
    @Published var displayKey: String = "STANDBY"
    @Published var displayShortKey: String = "—"
    @Published var displayEnergy: Float = 0
    @Published var displayFlux: Float = 0
    @Published var displayPhase: Float = 1
    @Published var displayFPS: Int = 60

    let audioTap: ProcessAudioTap
    let dsp: AcousticDSP
    let media: MediaController

    var onFrameTick: ((AcousticSnapshot) -> Void)?

    private var menuBarTimer: Timer?
    private var currentMenuBarHz: Double = 24.0
    private var processRefreshTimer: Timer?
    private var isSleeping: Bool = false
    private var sleepObservers: [NSObjectProtocol] = []

    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var uiThrottleAccum: Double = 0
    private var menuBarTickAccum: Double = 0
    private var lastMenuBarWasSilent: Bool = false
    private var fpsCounter: Int = 0
    private var fpsAccum: Double = 0
    private var lastRenderDrivenTime: CFTimeInterval = 0

    private init() {
        self.preset = VisualPreset(rawValue: settings.presetRaw) ?? .circuit
        self.amberPhosphor = settings.amberPhosphor
        self.showMenuBarKey = settings.showMenuBarKey
        self.sensitivity = settings.sensitivity
        self.launchAtLogin = settings.launchAtLogin

        self.audioTap = ProcessAudioTap()
        self.dsp = AcousticDSP()
        self.media = MediaController()

        audioTap.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.tapStatus = status
            }
        }
        audioTap.onTargetFallback = { [weak self] fallback in
            Task { @MainActor in
                self?.tapTarget = fallback
            }
        }
        media.onMetadataUpdate = { [weak self] meta in
            Task { @MainActor in
                self?.metadata = meta
            }
        }
    }

    func boot() {
        installSleepObservers()
        refreshAudioProcesses()
        audioTap.start(target: .systemAll)
        media.start()

        scheduleMenuBarTimer(hz: 24.0)

        processRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSleeping else { return }
                self.refreshAudioProcesses()
            }
        }
        Log.app.info("Acoustic Circuit booted (preset=\(self.preset.title, privacy: .public), sensitivity=\(self.sensitivity.rawValue, privacy: .public))")
    }

    func shutdown() {
        for obs in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        sleepObservers.removeAll()
        menuBarTimer?.invalidate()
        processRefreshTimer?.invalidate()
        media.stop()
        audioTap.stop()
        Log.app.info("Acoustic Circuit shut down cleanly")
    }

    func toggleLaunchAtLogin() {
        let desired = !launchAtLogin
        if settings.setLaunchAtLogin(desired) {
            launchAtLogin = settings.launchAtLogin
        }
    }

    func refreshAudioProcesses() {
        audioProcesses = ProcessAudioTap.listAudioProcesses()
    }

    func selectTapTarget(_ target: TapTarget) {
        tapTarget = target
        audioTap.start(target: target)
    }

    func retryAudioTap() {
        audioTap.start(target: tapTarget)
    }

    private func installSleepObservers() {
        let ws = NSWorkspace.shared.notificationCenter

        let onSleep: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSleeping else { return }
                self.isSleeping = true
                self.menuBarTimer?.invalidate()
                self.menuBarTimer = nil
                self.media.stop()
                self.audioTap.pauseForSleep()
            }
        }
        let onWake: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSleeping else { return }
                self.isSleeping = false
                self.audioTap.resumeFromSleep()
                self.media.start()
                self.scheduleMenuBarTimer(hz: 24.0)
            }
        }

        sleepObservers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: onSleep),
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: onSleep),
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onWake),
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: onWake)
        ]
    }

    private func scheduleMenuBarTimer(hz: Double) {
        if menuBarTimer != nil, abs(currentMenuBarHz - hz) < 0.5 { return }
        menuBarTimer?.invalidate()
        currentMenuBarHz = hz
        menuBarTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSleeping else { return }
                let now = CACurrentMediaTime()
                if now - self.lastRenderDrivenTime > 0.06 {
                    let snap = self.stepDSP(drivenByMetal: false)
                    let targetHz: Double = (snap.isSilent && !self.demoMode) ? 4.0 : 28.0
                    if abs(self.currentMenuBarHz - targetHz) > 1.0 {
                        self.scheduleMenuBarTimer(hz: targetHz)
                    }
                }
            }
        }
    }

    @discardableResult
    func stepDSP(drivenByMetal: Bool) -> AcousticSnapshot {
        let now = CACurrentMediaTime()
        if drivenByMetal {
            lastRenderDrivenTime = now
        }
        let dt = now - lastFrameTime
        if dt < 0.004 {
            return snapshot
        }
        lastFrameTime = now

        let snap = dsp.process(
            ringBuffer: audioTap.ringBuffer,
            sampleRate: audioTap.sampleRate,
            dt: dt,
            demoMode: demoMode,
            sensitivity: sensitivity
        )
        snapshot = snap

        // Throttle menu bar icon redraws to <= 20Hz when active, and 0Hz once settled in standby
        menuBarTickAccum += dt
        let shouldRedrawMenuBar: Bool
        if snap.isSilent && !demoMode {
            shouldRedrawMenuBar = !lastMenuBarWasSilent
        } else {
            shouldRedrawMenuBar = (menuBarTickAccum >= 0.05) // 20 Hz max
        }
        if shouldRedrawMenuBar {
            menuBarTickAccum = 0
            lastMenuBarWasSilent = (snap.isSilent && !demoMode)
            onFrameTick?(snap)
        }

        fpsCounter += 1
        fpsAccum += dt
        if fpsAccum >= 1.0 {
            let newFPS = Int(round(Double(fpsCounter) / fpsAccum))
            if (isPopoverOpen || isStudioOpen) && abs(displayFPS - newFPS) >= 2 {
                displayFPS = newFPS
            }
            fpsCounter = 0
            fpsAccum = 0
        }

        // Only publish SwiftUI telemetry when a SwiftUI chrome surface is open AND formatted values actually changed
        if isPopoverOpen || isMiniHUDOpen || isStudioOpen {
            uiThrottleAccum += dt
            if uiThrottleAccum >= 0.25 {
                uiThrottleAccum = 0
                if displayKey != snap.detectedKey { displayKey = snap.detectedKey }
                if displayShortKey != snap.shortKey { displayShortKey = snap.shortKey }
                let qEnergy = (snap.energy * 100).rounded() / 100
                let qFlux = (snap.flux * 100).rounded() / 100
                let qPhase = (snap.stereoCorrelation * 100).rounded() / 100
                if displayEnergy != qEnergy { displayEnergy = qEnergy }
                if displayFlux != qFlux { displayFlux = qFlux }
                if displayPhase != qPhase { displayPhase = qPhase }
            }
        }

        return snap
    }
}
