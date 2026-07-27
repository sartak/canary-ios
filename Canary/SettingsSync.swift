//
//  SettingsSync.swift
//  Canary
//
//  Created by Claude on 7/5/26.
//

import Foundation

/// Two-way mirror between the shared app-group settings (KeyboardSettings)
/// and the iCloud key-value store. NSUbiquitousKeyValueStore is unusable
/// inside keyboard extensions, so the app owns the mirror; cross-device
/// latency is app-open (plus KVS push while the app is running), matching
/// dictionary sync.
///
/// Conflict rule: newest change wins per key, decided by the change stamps
/// KeyboardSettings writes alongside every value — the same last-writer-wins
/// the settings themselves have on one device. Equal stamps (including the
/// never-written 0/0 case) are a no-op.
enum SettingsSync {
    private static let keys = ["swipeOnlyMode", "autocorrectUserDisabled", "debugVisualizationEnabled", "predictionWordCount"]
    private static var observing = false

    /// Reconciles both directions once, and (first call only) subscribes to
    /// external KVS changes so remote flips land while the app is open.
    /// Call on app-active.
    static func sync() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: NSUbiquitousKeyValueStore.default,
                queue: .main
            ) { _ in reconcile() }
        }
        reconcile()
    }

    private static func reconcile() {
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.synchronize()
        let local = KeyboardSettings.store
        for key in keys {
            let stampKey = KeyboardSettings.changeStampKey(for: key)
            let localStamp = local.double(forKey: stampKey)
            let remoteStamp = kvs.double(forKey: stampKey)
            // Object-valued copies so bools and ints ride the same mirror;
            // the stamp guard guarantees the winning side has a value.
            if remoteStamp > localStamp {
                local.set(kvs.object(forKey: key), forKey: key)
                local.set(remoteStamp, forKey: stampKey)
            } else if localStamp > remoteStamp {
                kvs.set(local.object(forKey: key), forKey: key)
                kvs.set(localStamp, forKey: stampKey)
            }
        }
        kvs.synchronize()
    }
}
