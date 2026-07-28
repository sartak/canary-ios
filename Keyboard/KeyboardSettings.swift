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

    /// How many foundation-model suggestions the empty-prefix bar shows;
    /// 0 disables predictions entirely. App-configured (no keyboard-layer
    /// key); the keyboard only reads it. Clamped 0...5; the model is always
    /// asked for five and the bar takes a prefix, so the cache and this
    /// setting stay independent.
    static var predictionWordCount: Int {
        get {
            guard store.object(forKey: "predictionWordCount") != nil else { return 3 }
            return min(max(store.integer(forKey: "predictionWordCount"), 0), 5)
        }
        set {
            store.set(min(max(newValue, 0), 5), forKey: "predictionWordCount")
            store.set(Date().timeIntervalSince1970, forKey: changeStampKey(for: "predictionWordCount"))
        }
    }

    /// Whether the behavioral stats streams (keystrokes, word events, tap
    /// events, swipe corrections) are collected. OPT-IN: nothing is recorded
    /// until the app's Settings enables it. Deliberately PER-DEVICE — never
    /// listed in SettingsSync's mirrored keys — so enabling on the personal
    /// phone can't silently enable it on a work phone.
    static var statsCollectionEnabled: Bool {
        get { store.bool(forKey: "statsCollectionEnabled") }
        set { setStamped(newValue, forKey: "statsCollectionEnabled") }
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

    /// Stable per-device identity for stats rows (the devices table).
    /// Generated once; per-device by nature and never synced.
    static var statsDeviceUUID: String {
        if let existing = store.string(forKey: "statsDeviceUUID") { return existing }
        let fresh = UUID().uuidString
        store.set(fresh, forKey: "statsDeviceUUID")
        return fresh
    }
}

/// Every tunable for foundation-model predictions (mirrors SwipeTuning's doc
/// style). The timings read live overrides from the app's Settings tuning
/// dials — deliberately unsynced experiment knobs, not preferences — and fall
/// back to the baked defaults. Report the keepers and they get locked in.
enum PredictionTuning {
    /// After a swipe commits, how long until inference starts for the
    /// correction-to-prediction handoff (the model's head start).
    static var swipeInferenceDelay: TimeInterval { tuned("swipeInferenceDelay", 0.5) }

    /// After a swipe commits, how long the correction candidates own the
    /// bar before predictions replace them.
    static var swipeHandoffDelay: TimeInterval { tuned("swipeHandoffDelay", 1.0) }

    /// After a tap-typed word boundary, how long the hopper must stay empty
    /// before inference starts. Continuous typing cancels the wait and burns
    /// nothing; cache hits bypass it entirely.
    static var tapInferenceDelay: TimeInterval { tuned("tapInferenceDelay", 0.35) }

    /// Recent context → words cache slots. More than one so speculative
    /// prefetches can't evict the context currently on screen.
    static let cacheCapacity = 8

    /// The dial names the app's tuning UI iterates, with their defaults.
    static let dials: [(key: String, name: String, defaultValue: TimeInterval)] = [
        ("tapInferenceDelay", "Tap inference delay", 0.35),
        ("swipeInferenceDelay", "Swipe inference delay", 0.5),
        ("swipeHandoffDelay", "Swipe handoff delay", 1.0),
    ]

    static func override(_ key: String) -> TimeInterval? {
        KeyboardSettings.store.object(forKey: "tuning." + key) as? TimeInterval
    }

    static func setOverride(_ value: TimeInterval?, forKey key: String) {
        if let value {
            KeyboardSettings.store.set(value, forKey: "tuning." + key)
        } else {
            KeyboardSettings.store.removeObject(forKey: "tuning." + key)
        }
    }

    private static func tuned(_ key: String, _ defaultValue: TimeInterval) -> TimeInterval {
        override(key) ?? defaultValue
    }
}
