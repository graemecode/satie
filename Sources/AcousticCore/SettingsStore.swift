#if os(macOS)
import AppKit
import ServiceManagement
#endif
import Foundation

public enum SensitivityMode: String, CaseIterable, Identifiable, Sendable {
    case calm
    case balanced
    case vivid

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .calm: return "Calm"
        case .balanced: return "Balanced"
        case .vivid: return "Vivid"
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
        static let presetRaw = "ac.preset"
        static let amberPhosphor = "ac.amberPhosphor"
        static let sensitivity = "ac.sensitivity"
        static let focusMode = "ac.focusMode"
        static let focusVolume = "ac.focusVolume"
        static let soundIntensity = "ac.soundIntensity"
        static let maskingBed = "ac.maskingBed"
        static let circadianOverride = "ac.circadianOverride"
        static let flowMinutes = "ac.flowMinutes"
        static let autoDuck = "ac.autoDuck"
        static let miniHUDFrame = "ac.miniHUDFrame"
        static let studioFrame = "ac.studioFrame"
        static let completedFocusSessions = "ac.completedFocusSessions"
        static let lastReviewPromptVersion = "ac.lastReviewPromptVersion"
        static let keepScreenAwake = "ac.keepScreenAwake"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var presetRaw: Int {
        get { defaults.object(forKey: Keys.presetRaw) as? Int ?? 0 }
        set { defaults.set(newValue, forKey: Keys.presetRaw) }
    }

    public var amberPhosphor: Bool {
        get { defaults.bool(forKey: Keys.amberPhosphor) }
        set { defaults.set(newValue, forKey: Keys.amberPhosphor) }
    }

    public var sensitivity: SensitivityMode {
        get {
            guard let raw = defaults.string(forKey: Keys.sensitivity),
                  let mode = SensitivityMode(rawValue: raw) else { return .balanced }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.sensitivity) }
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

    public var soundIntensity: SoundIntensity {
        get {
            guard let raw = defaults.string(forKey: Keys.soundIntensity),
                  let val = SoundIntensity(rawValue: raw) else { return .flow }
            return val
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.soundIntensity) }
    }

    public var maskingBed: MaskingBed {
        get {
            guard let raw = defaults.string(forKey: Keys.maskingBed),
                  let val = MaskingBed(rawValue: raw) else { return .off }
            return val
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.maskingBed) }
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

    public var autoDuck: Bool {
        get {
            if defaults.object(forKey: Keys.autoDuck) == nil { return true }
            return defaults.bool(forKey: Keys.autoDuck)
        }
        set { defaults.set(newValue, forKey: Keys.autoDuck) }
    }

    public var keepScreenAwake: Bool {
        get { defaults.bool(forKey: Keys.keepScreenAwake) }
        set { defaults.set(newValue, forKey: Keys.keepScreenAwake) }
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
