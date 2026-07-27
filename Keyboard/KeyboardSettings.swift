//
//  KeyboardSettings.swift
//  Keyboard
//
//  Created by Claude on 7/5/26.
//

import Foundation

/// Shared app-group settings with a private-container fallback: keyboard
/// extensions can only access the group container when the user grants Full
/// Access, and settings must keep working without it. The containing app uses
/// this same facade (the file is a member of both targets), so values written
/// by either side are visible to the other. There is no live cross-process
/// push — the keyboard reads at launch and on toggle, which is when it cares.
enum KeyboardSettings {
    static let appGroupID = "group.net.rpglanguage.Canary"

    private static let migrationFlagKey = "settingsMigratedToGroup"
    private static let migratedKeys = ["swipeOnlyMode", "autocorrectUserDisabled", "debugVisualizationEnabled"]

    /// The group suite when usable, else `.standard`. Usability must be
    /// probed — `UserDefaults(suiteName:)` exists either way and its
    /// in-process cache can echo writes that were never persisted — and the
    /// probe is an actual file creation in the container, not access(2)
    /// (isWritableFile), which can report false inside the extension sandbox
    /// even when real writes through proper APIs succeed.
    static let store: UserDefaults = {
        guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID) else {
            print("KeyboardSettings: no group container (entitlement missing?); using standard defaults")
            return .standard
        }
        let probe = container.appendingPathComponent(".settings-write-probe")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else {
            print("KeyboardSettings: group container not writable (Full Access off?); using standard defaults")
            return .standard
        }
        try? FileManager.default.removeItem(at: probe)
        guard let suite = UserDefaults(suiteName: appGroupID) else {
            print("KeyboardSettings: group suite failed to open; using standard defaults")
            return .standard
        }
        migrateIfNeeded(into: suite)
        return suite
    }()

    static var swipeOnlyMode: Bool {
        get { store.bool(forKey: "swipeOnlyMode") }
        set { setStamped(newValue, forKey: "swipeOnlyMode") }
    }

    static var autocorrectUserDisabled: Bool {
        get { store.bool(forKey: "autocorrectUserDisabled") }
        set { setStamped(newValue, forKey: "autocorrectUserDisabled") }
    }

    static var debugVisualizationEnabled: Bool {
        get { store.bool(forKey: "debugVisualizationEnabled") }
        set { setStamped(newValue, forKey: "debugVisualizationEnabled") }
    }

    /// Companion change-stamp key for a setting; SettingsSync (app target)
    /// compares stamps to decide which side of the iCloud mirror is newer.
    static func changeStampKey(for key: String) -> String {
        key + ".changedAt"
    }

    /// Every write carries a change stamp so cross-device merging can be
    /// last-writer-wins — the same rule the settings already have locally.
    private static func setStamped(_ value: Bool, forKey key: String) {
        store.set(value, forKey: key)
        store.set(Date().timeIntervalSince1970, forKey: changeStampKey(for: key))
    }

    /// One-time copy of the pre-App-Group values out of `.standard`, which
    /// keeps its (now stale) copies as the fallback's values. Existing suite
    /// values are never overwritten.
    private static func migrateIfNeeded(into suite: UserDefaults) {
        guard !suite.bool(forKey: migrationFlagKey) else { return }
        for key in migratedKeys where suite.object(forKey: key) == nil {
            if let value = UserDefaults.standard.object(forKey: key) {
                suite.set(value, forKey: key)
            }
        }
        suite.set(true, forKey: migrationFlagKey)
    }
}
