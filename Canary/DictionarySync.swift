//
//  DictionarySync.swift
//  Canary
//
//  Created by Claude on 7/5/26.
//

import CloudKit
import Foundation

/// App-owned CloudKit sync for the personal dictionary and shortcuts; the
/// keyboard never touches the network. CKSyncEngine over the private
/// database, custom zone `personalDictionary`: PersonalWord records keyed
/// `word:<word_lower>`, Shortcut records keyed `shortcut:<trigger_lower>`
/// (prefixes keep the two keyspaces from colliding in the zone). The word
/// text itself is end-to-end encrypted via encryptedValues; counts and flags
/// are plain. Merge semantics live in DictionaryMerge.
///
/// No push registration in v1: sync runs when the app becomes active and
/// after dictionary/shortcut edits, so cross-device latency is "next time the
/// app opens" — by design, and surfaced in the UI footer. Records are built
/// fresh rather than carrying server metadata; true conflicts surface as
/// serverRecordChanged, are merged into the server record, and re-queued —
/// self-correcting at the cost of an extra round trip.
///
/// Main-actor isolated: CKSyncEngineDelegate requires Sendable, and isolation
/// is what makes the mutable engine reference legal — every caller (SwiftUI
/// views, scenePhase) is main-actor already, and the async delegate
/// requirements hop to the main actor at the call site.
@MainActor
final class DictionarySync: NSObject, CKSyncEngineDelegate {
    static let shared = DictionarySync()

    static let containerID = "iCloud.net.rpglanguage.Canary"
    static let zoneID = CKRecordZone.ID(zoneName: "personalDictionary",
                                        ownerName: CKCurrentUserDefaultName)
    private static let wordPrefix = "word:"
    private static let shortcutPrefix = "shortcut:"
    private static let lastSyncKey = "lastDictionarySync"

    private var engine: CKSyncEngine?

    /// Kicks a sync pass: queue the zone, expired-tombstone deletions, and
    /// every dirty record, then fetch and send. Call on app-active and after
    /// dictionary/shortcut edits. Safe to call repeatedly.
    func kick() {
        guard let store = DictionaryStore() else { return }
        let engine = ensureEngine(store: store)

        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])

        let expired = store.purgeExpiredTombstones(now: Date())
        let deletions: [CKSyncEngine.PendingRecordZoneChange] =
            expired.words.map { .deleteRecord(Self.wordRecordID($0)) }
            + expired.shortcuts.map { .deleteRecord(Self.shortcutRecordID($0)) }
        engine.state.add(pendingRecordZoneChanges: deletions)

        let saves: [CKSyncEngine.PendingRecordZoneChange] =
            store.dirtyWordKeys().map { .saveRecord(Self.wordRecordID($0)) }
            + store.dirtyShortcutKeys().map { .saveRecord(Self.shortcutRecordID($0)) }
        engine.state.add(pendingRecordZoneChanges: saves)

        Task {
            try? await engine.fetchChanges()
            try? await engine.sendChanges()
        }
    }

    /// Deletes the CloudKit zone — the remote half of a typing-data reset
    /// (one operation removes every record in it). Call AFTER the local wipe;
    /// with local tables already empty, the zone-deletion echo the next fetch
    /// reports re-creates an empty zone and pushes nothing.
    func resetCloudData() {
        guard let store = DictionaryStore() else { return }
        let engine = ensureEngine(store: store)
        engine.state.add(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
        Task {
            try? await engine.sendChanges()
        }
    }

    /// Queues CloudKit record deletions for hard-deleted words and sends.
    /// This erases the records, not a propagating ban: a device still holding
    /// the word live will re-push it (absence is not deletion), which is the
    /// correct outcome — hard delete means "forget", the tombstone meant
    /// "block".
    func hardDeleteWords(_ wordLowers: [String]) {
        guard !wordLowers.isEmpty, let store = DictionaryStore() else { return }
        let engine = ensureEngine(store: store)
        engine.state.add(pendingRecordZoneChanges: wordLowers.map { .deleteRecord(Self.wordRecordID($0)) })
        Task {
            try? await engine.sendChanges()
        }
    }

    /// When the app last completed a send, for the UI footer.
    static var lastSync: Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    private func ensureEngine(store: DictionaryStore) -> CKSyncEngine {
        if let engine { return engine }
        var serialization: CKSyncEngine.State.Serialization?
        if let data = store.syncStateData() {
            serialization = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        let configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: Self.containerID).privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        let created = CKSyncEngine(configuration)
        engine = created
        return created
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                DictionaryStore()?.setSyncStateData(data)
            }

        case .accountChange:
            // Different account (or fresh sign-in): treat as first sync — the
            // merge rules reconcile per record; nothing local is discarded.
            markEverythingDirty()

        case .fetchedRecordZoneChanges(let changes):
            guard let store = DictionaryStore() else { break }
            for modification in changes.modifications {
                mergeRemoteRecord(modification.record, into: store, syncEngine: syncEngine)
            }
            for deletion in changes.deletions {
                applyRemoteDeletion(deletion.recordID, store: store, syncEngine: syncEngine)
            }

        case .sentRecordZoneChanges(let sent):
            guard let store = DictionaryStore() else { break }
            for record in sent.savedRecords {
                markClean(recordName: record.recordID.recordName, store: store)
            }
            for failure in sent.failedRecordSaves {
                // True conflict: merge into the server's record and re-queue.
                if failure.error.code == .serverRecordChanged,
                   let server = failure.error.serverRecord {
                    mergeRemoteRecord(server, into: store, syncEngine: syncEngine)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                }
            }
            UserDefaults.standard.set(Date(), forKey: Self.lastSyncKey)

        case .fetchedDatabaseChanges(let changes):
            // Zone deleted remotely (user reset iCloud, etc.): never delete
            // local data in response to remote absence — re-create and
            // re-push everything.
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                markEverythingDirty()
            }

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.record(for: recordID)
        }
    }

    // MARK: - Record mapping

    private static func wordRecordID(_ wordLower: String) -> CKRecord.ID {
        CKRecord.ID(recordName: wordPrefix + wordLower, zoneID: zoneID)
    }

    private static func shortcutRecordID(_ triggerLower: String) -> CKRecord.ID {
        CKRecord.ID(recordName: shortcutPrefix + triggerLower, zoneID: zoneID)
    }

    /// Builds the outgoing record for a queued save, or nil to drop the
    /// pending change (the local row vanished, e.g. an expired tombstone).
    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard let store = DictionaryStore() else { return nil }
        let name = recordID.recordName

        if name.hasPrefix(Self.wordPrefix) {
            let key = String(name.dropFirst(Self.wordPrefix.count))
            guard let state = store.wordState(for: key) else { return nil }
            let record = CKRecord(recordType: "PersonalWord", recordID: recordID)
            record.encryptedValues["word"] = state.word
            record["count"] = state.count
            record["learned"] = state.learned ? 1 : 0
            record["tombstoned"] = state.tombstoned ? 1 : 0
            record["updatedAt"] = state.updatedAt
            return record
        }

        if name.hasPrefix(Self.shortcutPrefix) {
            let key = String(name.dropFirst(Self.shortcutPrefix.count))
            guard let state = store.shortcutState(for: key) else { return nil }
            let record = CKRecord(recordType: "Shortcut", recordID: recordID)
            record.encryptedValues["trigger"] = state.trigger
            record.encryptedValues["phrase"] = state.phrase
            record["tombstoned"] = state.tombstoned ? 1 : 0
            record["updatedAt"] = state.updatedAt
            return record
        }

        return nil
    }

    /// Merges a fetched (or conflicting server) record into the local store.
    /// If the merge produced something the remote lacks, the row stays dirty
    /// and is re-queued so the winner propagates outward.
    private func mergeRemoteRecord(_ record: CKRecord, into store: DictionaryStore,
                                   syncEngine: CKSyncEngine) {
        let name = record.recordID.recordName

        if name.hasPrefix(Self.wordPrefix) {
            let key = String(name.dropFirst(Self.wordPrefix.count))
            let remote = DictionaryMerge.WordState(
                word: (record.encryptedValues["word"] as? String) ?? key,
                count: (record["count"] as? Int) ?? 0,
                learned: ((record["learned"] as? Int) ?? 0) != 0,
                tombstoned: ((record["tombstoned"] as? Int) ?? 0) != 0,
                updatedAt: (record["updatedAt"] as? Date) ?? Date(timeIntervalSince1970: 0)
            )
            guard let merged = DictionaryMerge.merge(local: store.wordState(for: key), remote: remote) else { return }
            let differsFromRemote = merged != remote
            store.applyWordState(merged, for: key, markDirty: differsFromRemote)
            if differsFromRemote {
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            }
            return
        }

        if name.hasPrefix(Self.shortcutPrefix) {
            let key = String(name.dropFirst(Self.shortcutPrefix.count))
            let remote = DictionaryMerge.ShortcutState(
                trigger: (record.encryptedValues["trigger"] as? String) ?? key,
                phrase: (record.encryptedValues["phrase"] as? String) ?? "",
                tombstoned: ((record["tombstoned"] as? Int) ?? 0) != 0,
                updatedAt: (record["updatedAt"] as? Date) ?? Date(timeIntervalSince1970: 0)
            )
            guard let merged = DictionaryMerge.merge(local: store.shortcutState(for: key), remote: remote) else { return }
            let differsFromRemote = merged != remote
            store.applyShortcutState(merged, for: key, markDirty: differsFromRemote)
            if differsFromRemote {
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            }
        }
    }

    /// A remote hard-deletion (another device expired a tombstone). Local
    /// tombstones follow it out; anything livelier re-pushes instead —
    /// absence is not deletion.
    private func applyRemoteDeletion(_ recordID: CKRecord.ID, store: DictionaryStore,
                                     syncEngine: CKSyncEngine) {
        let name = recordID.recordName
        if name.hasPrefix(Self.wordPrefix) {
            let key = String(name.dropFirst(Self.wordPrefix.count))
            guard let local = store.wordState(for: key) else { return }
            if local.tombstoned && !local.learned && local.count == 0 {
                var purged = local
                purged.tombstoned = false
                store.applyWordState(purged, for: key, markDirty: false)
            } else {
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
        } else if name.hasPrefix(Self.shortcutPrefix) {
            let key = String(name.dropFirst(Self.shortcutPrefix.count))
            guard let local = store.shortcutState(for: key), !local.tombstoned else { return }
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        }
    }

    private func markClean(recordName: String, store: DictionaryStore) {
        if recordName.hasPrefix(Self.wordPrefix) {
            store.clearWordDirty(String(recordName.dropFirst(Self.wordPrefix.count)))
        } else if recordName.hasPrefix(Self.shortcutPrefix) {
            store.clearShortcutDirty(String(recordName.dropFirst(Self.shortcutPrefix.count)))
        }
    }

    private func markEverythingDirty() {
        guard let store = DictionaryStore() else { return }
        store.markAllDirty()
        engine?.state.add(pendingRecordZoneChanges:
            store.dirtyWordKeys().map { .saveRecord(Self.wordRecordID($0)) }
            + store.dirtyShortcutKeys().map { .saveRecord(Self.shortcutRecordID($0)) })
    }
}
