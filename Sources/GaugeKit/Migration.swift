import Foundation

/// Moves settings written under the old bundle identifier.
///
/// Renaming a bundle gives the app a different preferences domain and a
/// different keychain service, so everything it had saved becomes invisible
/// rather than lost. This copies it across once.
public enum Migration {
    public static let legacyBundleIdentifier = "com.gauge.app"
    public static let currentBundleIdentifier = "com.thaisimply.gauge"
    private static let completedKey = "migrated.from.com.gauge.app"

    /// Called before the settings are first read.
    ///
    /// Only the app's own domain is migrated. Tests and any other suite get a
    /// clean slate — inheriting a developer's real settings would make them
    /// pass or fail depending on whose machine they run on.
    public static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults === UserDefaults.standard else { return }
        guard !defaults.bool(forKey: completedKey) else { return }
        defer { defaults.set(true, forKey: completedKey) }

        // Nothing to do if this install never ran under the old identifier,
        // or if the new domain already holds settings.
        guard defaults.data(forKey: "settings.v1") == nil,
              let legacy = UserDefaults(suiteName: legacyBundleIdentifier),
              let stored = legacy.data(forKey: "settings.v1")
        else { return }

        defaults.set(stored, forKey: "settings.v1")

        // The keychain entry is keyed by service name, which also changed.
        if Keychain.get(Keychain.accuWeatherKey) == nil,
           let key = Keychain.get(Keychain.accuWeatherKey, service: legacyBundleIdentifier) {
            Keychain.set(key, for: Keychain.accuWeatherKey)
        }
    }
}
