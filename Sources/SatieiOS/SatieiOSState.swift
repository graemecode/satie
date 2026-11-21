import AcousticCore
import AVFoundation
import Foundation
import QuartzCore
import StoreKit
import UIKit

enum iOSVisualPreset: Int, CaseIterable, Identifiable, Sendable {
    case circuit = 0
    case ecology = 1
    case phosphor = 2
    case liquid = 3

    var id: Int { rawValue }

    var cleanName: String {
        switch self {
        case .circuit: return "Circuit"
        case .ecology: return "Ecology"
        case .phosphor: return "Scope"
        case .liquid: return "Liquid"
        }
    }
}

@MainActor
final class SatieiOSState: ObservableObject {
    static let shared = SatieiOSState()

    let settings = SettingsStore()

    @Published var preset: iOSVisualPreset {
        didSet { settings.presetRaw = preset.rawValue }
    }
    @Published var amberPhosphor: Bool {
        didSet { settings.amberPhosphor = amberPhosphor }
    }
    @Published var focusMode: FocusSoundscape {
        didSet {
            settings.focusMode = focusMode
            focusSound.setMode(focusMode)
            if isFocusPlaying {
                syncNowPlaying()
            }
        }
    }
    @Published var maskingBed: MaskingBed {
        didSet {
            settings.maskingBed = maskingBed
            focusSound.setMaskingBed(maskingBed)
        }
    }
    @Published var keepScreenAwake: Bool {
        didSet {
            settings.keepScreenAwake = keepScreenAwake
            updateIdleTimer()
        }
    }

    @Published var isFocusPlaying: Bool = false
    @Published var flowMinutes: Int = 0
    @Published var flowRemainingSeconds: Double? = nil
    @Published var isForeground: Bool = true

    private(set) var snapshot: AcousticSnapshot = .empty

    let focusRingBuffer: StereoRingBuffer
    let focusSound: FocusSoundEngine
    let dsp: AcousticDSP
    let nowPlaying = NowPlayingBridge()

    private var housekeepingTimer: Timer?
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var wasPlayingBeforeInterruption: Bool = false
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    nonisolated(unsafe) private var sessionObservers: [NSObjectProtocol] = []

    var sessionProgress: Float? {
        guard flowMinutes > 0, let rem = flowRemainingSeconds else { return nil }
        let total = Double(flowMinutes * 60)
        guard total > 1 else { return nil }
        return Float(max(0.0, min(1.0, (total - rem) / total)))
    }

    private init() {
        self.preset = iOSVisualPreset(rawValue: settings.presetRaw) ?? .circuit
        self.amberPhosphor = settings.amberPhosphor
        self.focusMode = settings.focusMode
        self.maskingBed = settings.maskingBed
        self.flowMinutes = settings.flowMinutes
        self.keepScreenAwake = settings.keepScreenAwake

        self.focusRingBuffer = StereoRingBuffer()
        self.focusSound = FocusSoundEngine(ringBuffer: focusRingBuffer)
        self.focusSound.setMode(settings.focusMode)
        // On iOS, hardware volume buttons control output level, so keep internal engine unity-matched cleanly
        self.focusSound.setVolume(0.88)
        self.focusSound.setIntensity(.flow)
        self.focusSound.setMaskingBed(settings.maskingBed)
        self.focusSound.setCircadianPhase(CircadianPhase.current())
        self.dsp = AcousticDSP()

        configureMediaControls()
        installAudioSessionObservers()
        startHousekeeping()
        lightHaptic.prepare()
        mediumHaptic.prepare()
    }

    deinit {
        for obs in sessionObservers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func performHaptic(strong: Bool = false) {
        if strong {
            mediumHaptic.impactOccurred()
        } else {
            lightHaptic.impactOccurred()
        }
    }

    func togglePlayOrPause() {
        if isFocusPlaying {
            performHaptic(strong: true)
            stopFocusSound()
        } else {
            toggleFocusSound(focusMode)
        }
    }

    func toggleFocusSound(_ mode: FocusSoundscape) {
        performHaptic(strong: !isFocusPlaying)
        if isFocusPlaying && focusMode == mode {
            stopFocusSound()
            return
        }
        focusMode = mode
        focusSound.setCircadianPhase(CircadianPhase.current())
        focusSound.start(mode: mode)
        isFocusPlaying = true
        if flowMinutes > 0 {
            if flowRemainingSeconds == nil {
                flowRemainingSeconds = Double(flowMinutes * 60)
            }
            focusSound.setSessionProgress(sessionProgress)
        } else {
            focusSound.setSessionProgress(nil)
        }
        updateIdleTimer()
        syncNowPlaying()
    }

    func stopFocusSound() {
        focusSound.stop()
        focusSound.setSessionProgress(nil)
        isFocusPlaying = false
        flowRemainingSeconds = nil
        updateIdleTimer()
        syncNowPlaying()
    }

    func setFlowMinutes(_ minutes: Int) {
        let clamped = max(0, min(120, minutes))
        flowMinutes = clamped
        settings.flowMinutes = clamped
        if clamped == 0 {
            flowRemainingSeconds = nil
            focusSound.setSessionProgress(nil)
        } else {
            flowRemainingSeconds = Double(clamped * 60)
            if isFocusPlaying {
                focusSound.setSessionProgress(0.0)
            }
        }
    }

    func cycleFocusMode(forward: Bool = true) {
        let all = FocusSoundscape.allCases
        guard let idx = all.firstIndex(of: focusMode) else { return }
        let next = all[(idx + (forward ? 1 : all.count - 1)) % all.count]
        if isFocusPlaying {
            performHaptic()
            focusMode = next
        } else {
            toggleFocusSound(next)
        }
    }

    func cycleVisual(forward: Bool = true) {
        let all = iOSVisualPreset.allCases
        let next = all[(preset.rawValue + (forward ? 1 : all.count - 1)) % all.count]
        preset = next
        performHaptic()
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        updateIdleTimer()
    }

    @discardableResult
    func stepDSP() -> AcousticSnapshot {
        let now = CACurrentMediaTime()
        let dt = now - lastFrameTime
        if dt < 0.004 {
            return snapshot
        }
        lastFrameTime = now
        let snap = dsp.process(
            ringBuffer: focusRingBuffer,
            sampleRate: 48_000.0,
            dt: dt,
            demoMode: false,
            sensitivity: .balanced
        )
        snapshot = snap
        return snap
    }

    // MARK: - Private

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake && isFocusPlaying && isForeground
    }

    private func syncNowPlaying() {
        if isFocusPlaying {
            nowPlaying.update(
                isPlaying: true,
                title: focusMode.title,
                subtitle: focusMode.subtitle
            )
        } else {
            nowPlaying.clear()
        }
    }

    private func configureMediaControls() {
        nowPlaying.configureCommands(
            onPlay: { [weak self] in
                guard let self, !self.isFocusPlaying else { return }
                self.toggleFocusSound(self.focusMode)
            },
            onPause: { [weak self] in
                guard let self, self.isFocusPlaying else { return }
                self.stopFocusSound()
            },
            onToggle: { [weak self] in
                self?.togglePlayOrPause()
            },
            onNext: { [weak self] in
                self?.cycleFocusMode(forward: true)
            },
            onPrevious: { [weak self] in
                self?.cycleFocusMode(forward: false)
            }
        )
    }

    private func installAudioSessionObservers() {
        let nc = NotificationCenter.default
        let intObs = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self, let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
                switch type {
                case .began:
                    self.wasPlayingBeforeInterruption = self.isFocusPlaying
                    if self.isFocusPlaying {
                        self.focusSound.stopImmediately()
                        self.isFocusPlaying = false
                        self.syncNowPlaying()
                    }
                case .ended:
                    let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                    if opts.contains(.shouldResume) && self.wasPlayingBeforeInterruption {
                        self.wasPlayingBeforeInterruption = false
                        self.toggleFocusSound(self.focusMode)
                    } else {
                        self.wasPlayingBeforeInterruption = false
                    }
                @unknown default:
                    break
                }
            }
        }

        let routeObs = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, let reasonRaw,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
                // Standard iOS etiquette: pause cleanly when headphones / AirPods disconnect
                if reason == .oldDeviceUnavailable && self.isFocusPlaying {
                    self.stopFocusSound()
                }
            }
        }

        sessionObservers = [intObs, routeObs]
    }

    private func startHousekeeping() {
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickHousekeeping()
            }
        }
    }

    private func tickHousekeeping() {
        focusSound.setCircadianPhase(CircadianPhase.current())

        if isFocusPlaying, let rem = flowRemainingSeconds {
            let next = rem - 1.0
            if next <= 0 {
                flowRemainingSeconds = nil
                focusSound.setSessionProgress(1.0)
                focusSound.triggerSessionChime()
                settings.completedFocusSessions += 1
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4.0))
                    guard let self, self.isFocusPlaying, self.flowRemainingSeconds == nil else { return }
                    self.stopFocusSound()
                }
            } else {
                flowRemainingSeconds = next
                focusSound.setSessionProgress(sessionProgress)
            }
        }
    }
}
