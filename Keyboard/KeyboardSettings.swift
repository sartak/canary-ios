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

    /// The group suite when usable, else `.standard`. Usability is probed by
    /// container-directory writability — the same access boundary the shared
    /// database uses — because `UserDefaults(suiteName:)` exists either way
    /// and its in-process cache can echo writes that were never persisted.
    static let store: UserDefaults = {
        guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID),
              FileManager.default.isWritableFile(atPath: container.path),
              let suite = UserDefaults(suiteName: appGroupID) else {
            print("KeyboardSettings: group suite unusable; using standard defaults")
            return .standard
        }
        migrateIfNeeded(into: suite)
        return suite
    }()

    static var swipeOnlyMode: Bool {
        get { store.bool(forKey: "swipeOnlyMode") }
        set { store.set(newValue, forKey: "swipeOnlyMode") }
    }

    static var autocorrectUserDisabled: Bool {
        get { store.bool(forKey: "autocorrectUserDisabled") }
        set { store.set(newValue, forKey: "autocorrectUserDisabled") }
    }

    static var debugVisualizationEnabled: Bool {
        get { store.bool(forKey: "debugVisualizationEnabled") }
        set { store.set(newValue, forKey: "debugVisualizationEnabled") }
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
