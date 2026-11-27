#if os(macOS)
import AppKit
import ServiceManagement
#endif
import Foundation

public enum VisualPreset: Int, CaseIterable, Identifiable, Sendable {
    case circuit = 0
    case ecology = 1
    case phosphor = 2
    case liquid = 3
    case horizon = 4
    case oculus = 5
    case sunset = 6

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .circuit:  return SatieL10n.string("visual.circuit.title", fallback: "01 The Circuit")
        case .ecology:  return SatieL10n.string("visual.ecology.title", fallback: "02 Ecology Wall")
        case .phosphor: return SatieL10n.string("visual.phosphor.title", fallback: "03 Phosphor Scope")
        case .liquid:   return SatieL10n.string("visual.liquid.title", fallback: "04 Nocturne Silk")
        case .horizon:  return SatieL10n.string("visual.horizon.title", fallback: "05 Horizon")
        case .oculus:   return SatieL10n.string("visual.oculus.title", fallback: "06 Oculus")
        case .sunset:   return SatieL10n.string("visual.sunset.title", fallback: "07 Low Sun")
        }
    }

    public var shortTitle: String {
        switch self {
        case .circuit:  return SatieL10n.string("visual.circuit.short", fallback: "01 Circuit")
        case .ecology:  return SatieL10n.string("visual.ecology.short", fallback: "02 Ecology")
        case .phosphor: return SatieL10n.string("visual.phosphor.short", fallback: "03 Scope")
        case .liquid:   return SatieL10n.string("visual.liquid.short", fallback: "04 Nocturne")
        case .horizon:  return SatieL10n.string("visual.horizon.short", fallback: "05 Horizon")
        case .oculus:   return SatieL10n.string("visual.oculus.short", fallback: "06 Oculus")
        case .sunset:   return SatieL10n.string("visual.sunset.short", fallback: "07 Low Sun")
        }
    }

    public var cleanName: String {
        switch self {
        case .circuit:  return SatieL10n.string("visual.circuit.clean", fallback: "Circuit")
        case .ecology:  return SatieL10n.string("visual.ecology.clean", fallback: "Ecology")
        case .phosphor: return SatieL10n.string("visual.phosphor.clean", fallback: "Scope")
        case .liquid:   return SatieL10n.string("visual.liquid.clean", fallback: "Nocturne")
        case .horizon:  return SatieL10n.string("visual.horizon.clean", fallback: "Horizon")
        case .oculus:   return SatieL10n.string("visual.oculus.clean", fallback: "Oculus")
        case .sunset:   return SatieL10n.string("visual.sunset.clean", fallback: "Low Sun")
        }
    }

    /// Signature audiovisual world paired by default to each soundscape.
    public static func paired(for mode: FocusSoundscape) -> VisualPreset {
        switch mode {
        case .focus: return .circuit
        case .pulse: return .phosphor
        case .rain:  return .ecology
        case .still: return .horizon
        case .dive:  return .oculus
        case .drift: return .liquid
        case .groove: return .sunset
        case .loops: return .horizon
        case .furniture: return .liquid
        case .gymnopedies: return .liquid
        case .gnossiennes: return .oculus
        case .sarabandes: return .ecology
        case .debussy: return .horizon
        case .faure: return .liquid
        case .scriabin: return .circuit
        }
    }
}

public enum SensitivityMode: String, CaseIterable, Identifiable, Sendable {
    case calm
    case balanced
    case vivid

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .calm: return SatieL10n.string("sensitivity.calm", fallback: "Calm")
        case .balanced: return SatieL10n.string("sensitivity.balanced", fallback: "Balanced")
        case .vivid: return SatieL10n.string("sensitivity.vivid", fallback: "Vivid")
        }
    }

    /// Gain offset in dB applied to the perceptual FFT curve.
    public var gainOffsetDB: Float {
        switch self {
        case .calm: return -5.0
        case .balanced: return 0.0
        case .vivid: return +6.5
        }
    }

    /// Multiplier for beat & flux onset responsiveness.
    public var transientScale: Float {
        switch self {
        case .calm: return 0.72
        case .balanced: return 1.0
        case .vivid: return 1.32
        }
    }
}

/// Persistent preferences backed by UserDefaults + native macOS Login Item (SMAppService).
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Keys {
        static let focusMode = "ac.focusMode"
        static let focusVolume = "ac.focusVolume"
        static let circadianOverride = "ac.circadianOverride"
        static let flowMinutes = "ac.flowMinutes"
        static let miniHUDFrame = "ac.miniHUDFrame"
        static let studioFrame = "ac.studioFrame"
        static let completedFocusSessions = "ac.completedFocusSessions"
        static let lastReviewPromptVersion = "ac.lastReviewPromptVersion"
        static let mixWithOthers = "ac.mixWithOthers"
    }

    /// Settings that existed in earlier versions. The visual now always follows the soundscape, the scope is
    /// emerald by day and amber at night, and the screen stays awake on its own in landscape or immersion,
    /// so these values are no longer read. Clearing them keeps an old choice (such as a background noise bed)
    /// from lingering in the defaults database.
    private static let retiredKeys = [
        "ac.preset", "ac.amberPhosphor", "ac.sensitivity", "ac.soundIntensity", "ac.maskingBed",
        "ac.autoDuck", "ac.keepScreenAwake", "ac.visualFollowsSoundscape",
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for key in Self.retiredKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    public var focusMode: FocusSoundscape {
        get {
            guard let raw = defaults.string(forKey: Keys.focusMode),
                  let mode = FocusSoundscape(rawValue: raw) else { return .focus }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.focusMode) }
    }

    public var focusVolume: Float {
        get {
            if defaults.object(forKey: Keys.focusVolume) == nil { return 0.48 }
            return max(0.05, min(1.0, defaults.float(forKey: Keys.focusVolume)))
        }
        set { defaults.set(max(0.05, min(1.0, newValue)), forKey: Keys.focusVolume) }
    }

    public var circadianOverride: CircadianOverride {
        get {
            guard let raw = defaults.string(forKey: Keys.circadianOverride),
                  let val = CircadianOverride(rawValue: raw) else { return .auto }
            return val
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.circadianOverride) }
    }

    public var flowMinutes: Int {
        get { defaults.integer(forKey: Keys.flowMinutes) }
        set { defaults.set(max(0, min(120, newValue)), forKey: Keys.flowMinutes) }
    }

    public var mixWithOthers: Bool {
        get { defaults.bool(forKey: Keys.mixWithOthers) }
        set { defaults.set(newValue, forKey: Keys.mixWithOthers) }
    }

    #if os(macOS)
    public var miniHUDOrigin: NSPoint? {
        get {
            guard let str = defaults.string(forKey: Keys.miniHUDFrame) else { return nil }
            let pt = NSPointFromString(str)
            return (pt == .zero && str != "{0, 0}") ? nil : pt
        }
        set {
            if let pt = newValue {
                defaults.set(NSStringFromPoint(pt), forKey: Keys.miniHUDFrame)
            }
        }
    }

    public var studioFrame: NSRect? {
        get {
            guard let str = defaults.string(forKey: Keys.studioFrame) else { return nil }
            let rect = NSRectFromString(str)
            return (rect.width >= 600 && rect.height >= 400) ? rect : nil
        }
        set {
            if let rect = newValue {
                defaults.set(NSStringFromRect(rect), forKey: Keys.studioFrame)
            }
        }
    }
    #endif

    public var completedFocusSessions: Int {
        get { defaults.integer(forKey: Keys.completedFocusSessions) }
        set { defaults.set(max(0, newValue), forKey: Keys.completedFocusSessions) }
    }

    public var lastReviewPromptVersion: String? {
        get { defaults.string(forKey: Keys.lastReviewPromptVersion) }
        set { defaults.set(newValue, forKey: Keys.lastReviewPromptVersion) }
    }

    #if os(macOS)
    // MARK: - Native macOS Login Item (SMAppService)

    public var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    public func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("Launch at login set to \(enabled, privacy: .public) (status: \(String(describing: SMAppService.mainApp.status), privacy: .public))")
            return true
        } catch {
            Log.app.error("Failed to update Launch at Login: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    #endif
}
