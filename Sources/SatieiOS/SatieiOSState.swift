import AcousticCore
import AVFoundation
import Foundation
import QuartzCore
import UIKit

@MainActor
final class SatieiOSState: ObservableObject {
    static let shared = SatieiOSState()

    let settings = SettingsStore()

    /// The visual always belongs to the soundscape; swiping the stage changes the soundscape, not the visual.
    @Published private(set) var preset: VisualPreset
    @Published var focusMode: FocusSoundscape {
        didSet {
            settings.focusMode = focusMode
            focusSound.setMode(focusMode)
            let target = VisualPreset.paired(for: focusMode)
            if preset != target {
                preset = target
            }
            if isFocusPlaying {
                syncNowPlaying()
                syncLiveActivity()
            }
        }
    }
    /// Set by the view while the phone is in landscape (a desk stand) or Immersion Mode. Not a setting.
    @Published var wantsScreenAwake: Bool = false {
        didSet { updateIdleTimer() }
    }
    @Published var mixWithOthers: Bool {
        didSet {
            settings.mixWithOthers = mixWithOthers
            focusSound.setMixWithOthers(mixWithOthers)
        }
    }
    @Published var circadianOverride: CircadianOverride {
        didSet {
            settings.circadianOverride = circadianOverride
            let resolved = circadianOverride.resolvedPhase()
            focusSound.setCircadianPhase(resolved)
            if isFocusPlaying {
                syncLiveActivity()
            }
        }
    }

    var effectiveCircadianPhase: CircadianPhase {
        circadianOverride.resolvedPhase()
    }

    @Published var isFocusPlaying: Bool = false
    @Published var flowMinutes: Int = 0
    @Published var flowRemainingSeconds: Double? = nil
    @Published var isForeground: Bool = true
    private(set) var liveBreathBPM: Double = 5.5

    private(set) var snapshot: AcousticSnapshot = .empty

    let focusRingBuffer: StereoRingBuffer
    let focusSound: FocusSoundEngine
    let dsp: AcousticDSP
    let nowPlaying = NowPlayingBridge()
    private let liveActivity = SatieLiveActivityManager()

    private var housekeepingTimer: Timer?
    private var flowEndDate: Date? = nil
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
        let initialMode = settings.focusMode
        self.preset = VisualPreset.paired(for: initialMode)
        self.focusMode = initialMode
        self.flowMinutes = settings.flowMinutes
        self.mixWithOthers = settings.mixWithOthers
        self.circadianOverride = settings.circadianOverride

        self.focusRingBuffer = StereoRingBuffer()
        self.focusSound = FocusSoundEngine(ringBuffer: focusRingBuffer)
        self.focusSound.setMode(settings.focusMode)
        // On iOS, hardware volume buttons control output level, so keep internal engine unity-matched cleanly
        self.focusSound.setVolume(0.88)
        self.focusSound.setIntensity(.flow)
        self.focusSound.setMaskingBed(.off)
        self.focusSound.setMixWithOthers(settings.mixWithOthers)
        self.focusSound.setCircadianPhase(settings.circadianOverride.resolvedPhase())
        self.dsp = AcousticDSP()

        // Clear any orphaned Dynamic Island / Lock Screen Live Activity left over from a background-terminated session
        liveActivity.endAll()
        configureMediaControls()
        installAudioSessionObservers()
        SatieWatchBridge.shared.activate()
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

    /// Idempotent start for Shortcuts, Action Button, Focus Filters, and Siri (never accidentally toggles off).
    func startFocusSound(_ mode: FocusSoundscape, durationMinutes: Int? = nil) {
        if let mins = durationMinutes {
            setFlowMinutes(mins)
        }
        if isFocusPlaying {
            if focusMode != mode {
                focusMode = mode
                syncNowPlaying()
            }
            return
        }
        toggleFocusSound(mode)
    }

    func toggleFocusSound(_ mode: FocusSoundscape) {
        performHaptic(strong: !isFocusPlaying)
        if isFocusPlaying && focusMode == mode {
            stopFocusSound()
            return
        }
        focusMode = mode
        focusSound.setCircadianPhase(effectiveCircadianPhase)
        let started = focusSound.start(mode: mode)
        guard started else {
            isFocusPlaying = false
            stopHousekeeping()
            updateIdleTimer()
            syncNowPlaying()
            syncLiveActivity()
            return
        }

        isFocusPlaying = true
        if flowMinutes > 0 {
            if flowEndDate == nil {
                let dur = Double(flowMinutes * 60)
                flowEndDate = Date().addingTimeInterval(dur)
                flowRemainingSeconds = dur
            } else {
                refreshCountdownFromWallClock()
            }
            focusSound.setSessionProgress(sessionProgress)
        } else {
            flowEndDate = nil
            flowRemainingSeconds = nil
            focusSound.setSessionProgress(nil)
        }
        startHousekeepingIfNeeded()
        updateIdleTimer()
        syncNowPlaying()
        syncLiveActivity()
    }

    func stopFocusSound() {
        focusSound.stop()
        focusSound.setSessionProgress(nil)
        isFocusPlaying = false
        flowEndDate = nil
        flowRemainingSeconds = nil
        stopHousekeeping()
        updateIdleTimer()
        syncNowPlaying()
        syncLiveActivity()
    }

    func updateBiofeedbackBreathBPM(_ bpm: Double?) {
        focusSound.setBiofeedbackBreathBPM(bpm)
        let next = (bpm ?? 5.5)
        let changed = abs(next - liveBreathBPM) >= 0.15
        liveBreathBPM = next
        if changed && isFocusPlaying && focusMode == .dive {
            syncLiveActivity()
        }
    }

    private func syncLiveActivity() {
        liveActivity.sync(
            mode: focusMode,
            isPlaying: isFocusPlaying,
            endDate: flowEndDate,
            breathBPM: liveBreathBPM,
            isNight: effectiveCircadianPhase == .night
        )
        SatieWatchBridge.shared.pushState(mode: focusMode, isPlaying: isFocusPlaying)
    }

    func setFlowMinutes(_ minutes: Int) {
        let clamped = max(0, min(120, minutes))
        flowMinutes = clamped
        settings.flowMinutes = clamped
        if clamped == 0 {
            flowEndDate = nil
            flowRemainingSeconds = nil
            focusSound.setSessionProgress(nil)
        } else {
            let dur = Double(clamped * 60)
            flowRemainingSeconds = dur
            if isFocusPlaying {
                flowEndDate = Date().addingTimeInterval(dur)
                focusSound.setSessionProgress(0.0)
            } else {
                flowEndDate = nil
            }
        }
        syncLiveActivity()
    }

    /// Swipe on the stage: move to the neighboring soundscape (and its visual) without starting or stopping playback.
    func stepFocusMode(forward: Bool) {
        let all = FocusSoundscape.allCases
        guard let idx = all.firstIndex(of: focusMode) else { return }
        performHaptic()
        focusMode = all[(idx + (forward ? 1 : all.count - 1)) % all.count]
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


    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground {
            focusSound.setCircadianPhase(effectiveCircadianPhase)
            // Reconcile state & wall-clock timer immediately upon returning to foreground
            if isFocusPlaying && !focusSound.isPlaying {
                isFocusPlaying = false
                flowEndDate = nil
                flowRemainingSeconds = nil
                stopHousekeeping()
                syncNowPlaying()
                syncLiveActivity()
            } else if isFocusPlaying {
                refreshCountdownFromWallClock()
            }
        }
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
        UIApplication.shared.isIdleTimerDisabled = wantsScreenAwake && isFocusPlaying && isForeground
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
                        self.stopHousekeeping()
                        self.updateIdleTimer()
                        self.syncNowPlaying()
                        self.syncLiveActivity()
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

    private func startHousekeepingIfNeeded() {
        guard housekeepingTimer == nil else { return }
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickHousekeeping()
            }
        }
    }

    private func stopHousekeeping() {
        housekeepingTimer?.invalidate()
        housekeepingTimer = nil
    }

    private func tickHousekeeping() {
        guard isFocusPlaying else {
            stopHousekeeping()
            return
        }
        focusSound.setCircadianPhase(effectiveCircadianPhase)
        refreshCountdownFromWallClock()
    }

    private func refreshCountdownFromWallClock() {
        guard isFocusPlaying, let endDate = flowEndDate else { return }
        let rem = endDate.timeIntervalSinceNow
        if rem <= 0 {
            flowEndDate = nil
            flowRemainingSeconds = nil
            focusSound.setSessionProgress(1.0)
            focusSound.triggerSessionChime()
            settings.completedFocusSessions += 1
            syncLiveActivity()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4.0))
                guard let self, self.isFocusPlaying, self.flowEndDate == nil else { return }
                self.stopFocusSound()
            }
        } else {
            flowRemainingSeconds = rem
            focusSound.setSessionProgress(sessionProgress)
        }
    }
}
