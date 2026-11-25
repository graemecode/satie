import Foundation

/// Zero-dependency Apple-native localization loader shared across macOS, iOS, iPadOS,
/// watchOS, tvOS, visionOS, Widgets, and SwiftPM tests.
///
/// Automatically resolves strings against the operating system's current language
/// (`Bundle.main` in app/extension bundles, `Bundle.module` in SwiftPM test/CLI builds).
public enum SatieL10n {
    /// All eight shipped Apple locale identifiers (including Taiwanese Traditional Chinese `zh-Hant`).
    public static let supportedLanguages: [String] = [
        "en", "ja", "fr", "zh-Hans", "zh-Hant", "es", "de", "ko"
    ]

    /// Resolves the bundle containing `<lang>.lproj/Localizable.strings`.
    public static var resourceBundle: Bundle {
        if Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") != nil {
            return .main
        }
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    /// Look up a localized string for the current system language.
    public static func string(_ key: String, fallback: String? = nil) -> String {
        let defaultValue = fallback ?? key
        return resourceBundle.localizedString(forKey: key, value: defaultValue, table: "Localizable")
    }

    /// Format a localized string using the user's current locale.
    public static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = string(key)
        return String(format: template, locale: Locale.current, arguments: args)
    }

    /// Resolves `<language>.lproj` handling both Xcode canonical case (`zh-Hant.lproj`) and SwiftPM lowercased bundles (`zh-hant.lproj`).
    public static func lprojBundle(for language: String) -> Bundle? {
        let path = resourceBundle.path(forResource: language, ofType: "lproj")
            ?? resourceBundle.path(forResource: language.lowercased(), ofType: "lproj")
        guard let path else { return nil }
        return Bundle(path: path)
    }

    /// Look up a localized string explicitly for a specific `.lproj` language code (used by release tests).
    public static func string(_ key: String, language: String) -> String? {
        guard let langBundle = lprojBundle(for: language) else {
            return nil
        }
        let sentinel = "__SATIE_MISSING_L10N_KEY__"
        let value = langBundle.localizedString(forKey: key, value: sentinel, table: "Localizable")
        return value == sentinel ? nil : value
    }

    /// Returns all key-value entries from a specific `.lproj/Localizable.strings` file.
    public static func table(for language: String) -> [String: String]? {
        guard let langBundle = lprojBundle(for: language),
              let url = langBundle.url(forResource: "Localizable", withExtension: "strings"),
              let dict = NSDictionary(contentsOf: url) as? [String: String] else {
            return nil
        }
        return dict
    }

    /// Localizes `AcousticSnapshot.detectedKey` at the presentation boundary without changing the DSP sentinel.
    public static func displayKey(_ rawKey: String) -> String {
        rawKey == "STANDBY" ? string("common.standby") : rawKey
    }
}
