import Foundation

/// Shared asymmetric raised-cosine breath pacer (42% inhale / 58% extended exhale) used identically
/// by `DeepMeditationEngine` (audio), `06 Oculus` (Metal visual), and `SatieWatch` (Taptic Engine).
public struct BreathCyclePacer: Sendable {
    public private(set) var phase: Double = 0.0        // 0..1 within one full breath cycle
    public private(set) var currentBPM: Double = 8.5   // live smooth respiratory frequency
    public private(set) var value: Double = 0.0        // 0 = end of exhale, 1 = peak of inhale
    public var isInhaling: Bool { phase < 0.42 }

    public init(initialBPM: Double = 8.5) {
        self.currentBPM = initialBPM
    }

    public mutating func reset(initialBPM: Double = 8.5) {
        phase = 0.0
        currentBPM = initialBPM
        value = 0.0
    }

    @inline(__always)
    public mutating func step(elapsedSec: Double, dt: Double, targetBPMOverride: Double? = nil) -> Double {
        let autoBPM: Double = {
            let u = max(0.0, min(1.0, elapsedSec / 600.0))
            let smooth = u * u * (3.0 - 2.0 * u)
            return 8.5 - 3.0 * smooth // 8.5 -> 5.5 breaths/min over 10 minutes
        }()

        let desiredBPM: Double
        if let override = targetBPMOverride, override.isFinite && override >= 4.0 && override <= 10.0 {
            desiredBPM = max(4.5, min(8.5, override))
        } else {
            desiredBPM = autoBPM
        }

        // Ultra-gentle slew (tau ~ 14s) so Apple Watch HRV updates never cause abrupt breath jolts
        let alpha = 1.0 - exp(-dt / 14.0)
        currentBPM += (desiredBPM - currentBPM) * alpha

        let cycleSec = 60.0 / max(4.2, currentBPM)
        phase += dt / cycleSec
        if phase >= 1.0 { phase -= floor(phase) }

        let inhaleFrac = 0.42
        if phase < inhaleFrac {
            let u = phase / inhaleFrac
            value = 0.5 - 0.5 * cos(Double.pi * u)
        } else {
            let v = (phase - inhaleFrac) / (1.0 - inhaleFrac)
            value = 0.5 + 0.5 * cos(Double.pi * v)
        }
        return value
    }
}

/// Closed-loop Vaschillo / Lehrer respiratory sinus arrhythmia (RSA) biofeedback controller.
/// Consumes live Apple Watch HealthKit Heart Rate (bpm) and HRV (SDNN ms) readings and smoothly
/// adapts Satie's Deep Dive respiratory target frequency inside [4.5, 7.8] breaths/min so:
/// - Elevated sympathetic arousal (high HR / low SDNN) receives a comfortable 6.8..7.6 bpm ramp
///   rather than forcing air hunger.
/// - Rising vagal tone (falling HR / rising SDNN) settles into personal 4.8..5.5 bpm resonance.
public struct HRVResonanceController: Sendable {
    public private(set) var targetBreathBPM: Double = 6.2
    public private(set) var calmnessIndex: Double = 0.5   // 0 = aroused, 1 = deep parasympathetic
    public private(set) var baselineHR: Double? = nil
    public private(set) var baselineSDNN: Double? = nil
    public private(set) var latestHR: Double? = nil
    public private(set) var latestSDNN: Double? = nil
    public private(set) var sampleCount: Int = 0

    public init(initialBPM: Double = 6.2) {
        self.targetBreathBPM = max(4.5, min(8.5, initialBPM))
    }

    public mutating func reset(initialBPM: Double = 6.2) {
        targetBreathBPM = max(4.5, min(8.5, initialBPM))
        calmnessIndex = 0.5
        baselineHR = nil
        baselineSDNN = nil
        latestHR = nil
        latestSDNN = nil
        sampleCount = 0
    }

    /// Ingests a new physiological sample from HealthKit / Apple Watch and returns the updated target breath rate (bpm).
    @discardableResult
    public mutating func ingest(heartRateBPM: Double? = nil, hrvSDNNms: Double? = nil) -> Double {
        if let hr = heartRateBPM, hr.isFinite, hr >= 35.0, hr <= 210.0 {
            latestHR = hr
            if let base = baselineHR {
                // Slow exponential baseline tracker so session-over-session trends adapt smoothly
                baselineHR = base * 0.94 + hr * 0.06
            } else {
                baselineHR = hr
            }
            sampleCount += 1
        }

        if let sdnn = hrvSDNNms, sdnn.isFinite, sdnn >= 5.0, sdnn <= 250.0 {
            latestSDNN = sdnn
            if let base = baselineSDNN {
                baselineSDNN = base * 0.90 + sdnn * 0.10
            } else {
                baselineSDNN = sdnn
            }
            sampleCount += 1
        }

        // Compute autonomic calmness index from absolute + relative HR and HRV SDNN
        var scoreSum = 0.0
        var weightSum = 0.0

        if let hr = latestHR {
            // Absolute resting HR calm curve: 92 bpm -> 0.0, 56 bpm -> 1.0
            let absCalm = max(0.0, min(1.0, (92.0 - hr) / 36.0))
            // Relative drop below session baseline (+8 bpm drop = deeper calm)
            let relCalm: Double
            if let base = baselineHR {
                relCalm = max(0.0, min(1.0, 0.5 + (base - hr) / 14.0))
            } else {
                relCalm = absCalm
            }
            scoreSum += (0.65 * absCalm + 0.35 * relCalm) * 1.0
            weightSum += 1.0
        }

        if let sdnn = latestSDNN {
            // Higher SDNN reflects stronger parasympathetic vagal tone (20 ms -> 0.1, 85 ms -> 0.95)
            let absHRV = max(0.0, min(1.0, (sdnn - 18.0) / 72.0))
            let relHRV: Double
            if let base = baselineSDNN {
                relHRV = max(0.0, min(1.0, 0.5 + (sdnn - base) / 30.0))
            } else {
                relHRV = absHRV
            }
            scoreSum += (0.60 * absHRV + 0.40 * relHRV) * 1.35
            weightSum += 1.35
        }

        guard weightSum > 0 else { return targetBreathBPM }
        let instantCalm = max(0.0, min(1.0, scoreSum / weightSum))
        calmnessIndex = calmnessIndex * 0.65 + instantCalm * 0.35

        // Map calmness [0..1] -> physiological breath target [7.6 bpm .. 4.9 bpm]
        // (anchored around the empirically validated 0.1 Hz / 5.5 bpm RSA resonance band)
        let idealBPM = 7.6 - 2.7 * calmnessIndex
        let clampedIdeal = max(4.5, min(7.8, idealBPM))

        // Rate-limit each closed-loop update (±0.28 bpm max per step) for imperceptible pacing
        let delta = max(-0.28, min(0.28, clampedIdeal - targetBreathBPM))
        targetBreathBPM = max(4.5, min(7.8, targetBreathBPM + delta))
        return targetBreathBPM
    }
}
