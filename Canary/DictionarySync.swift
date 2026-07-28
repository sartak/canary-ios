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
/// app opens" — by design, and surfaced in the UI footer. Outgoing records
/// are built on each record's archived system fields (stored per record in
/// sync_state) so saves are UPDATES; a fresh CKRecord is an insert, which the
/// server permanently rejects with serverRecordChanged once the record
/// exists. True conflicts merge into the server's record — capturing its
/// change tag — and re-queue, converging in one extra round trip.
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
    private static let lastSendKey = "lastDictionarySend"
    private static let lastReceiveKey = "lastDictionaryReceive"

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

    /// When a send pass last completed (engine's didSendChanges).
    static var lastSend: Date? {
        UserDefaults.standard.object(forKey: lastSendKey) as? Date
    }

    /// When a fetch pass last completed (engine's didFetchChanges).
    static var lastReceive: Date? {
        UserDefaults.standard.object(forKey: lastReceiveKey) as? Date
    }

    /// Most recent activity in either direction, for the dictionary footer.
    static var lastSync: Date? {
        switch (lastSend, lastReceive) {
        case (nil, nil): nil
        case (let send?, nil): send
        case (nil, let receive?): receive
        case (let send?, let receive?): max(send, receive)
        }
    }

    /// Manual send: queue everything dirty and push. The engine still owns
    /// scheduling niceties; this just asks it to go now.
    func sendNow() {
        guard let store = DictionaryStore() else { return }
        let engine = ensureEngine(store: store)
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        engine.state.add(pendingRecordZoneChanges:
            store.dirtyWordKeys().map { .saveRecord(Self.wordRecordID($0)) }
            + store.dirtyShortcutKeys().map { .saveRecord(Self.shortcutRecordID($0)) })
        Task {
            try? await engine.sendChanges()
        }
    }

    /// Manual receive: fetch whatever other devices have pushed.
    func receiveNow() {
        guard let store = DictionaryStore() else { return }
        let engine = ensureEngine(store: store)
        Task {
            try? await engine.fetchChanges()
        }
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
            // Stored change tags refer to the old account's records.
            DictionaryStore()?.purgeSystemFields()
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
                // The saved record carries the fresh change tag; the next
                // save of this record must build on it.
                if let data = Self.archiveSystemFields(of: record) {
                    store.setSystemFields(data, forRecordName: record.recordID.recordName)
                }
                markClean(recordName: record.recordID.recordName, store: store)
            }
            for recordID in sent.deletedRecordIDs {
                store.deleteSystemFields(forRecordName: recordID.recordName)
            }
            for failure in sent.failedRecordSaves {
                switch failure.error.code {
                case .serverRecordChanged:
                    // True conflict: merge into the server's record (which
                    // archives its change tag) and re-queue — the retry is
                    // then an update against the right tag.
                    if let server = failure.error.serverRecord {
                        mergeRemoteRecord(server, into: store, syncEngine: syncEngine)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    }
                case .unknownItem:
                    // Our stored tag points at a record that no longer exists
                    // (deleted elsewhere): forget it and retry as an insert.
                    store.deleteSystemFields(forRecordName: failure.record.recordID.recordName)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                default:
                    break
                }
            }
        case .fetchedDatabaseChanges(let changes):
            // Zone deleted remotely (user reset iCloud, etc.): never delete
            // local data in response to remote absence — re-create and
            // re-push everything.
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                DictionaryStore()?.purgeSystemFields()
                markEverythingDirty()
            }

        case .didSendChanges:
            UserDefaults.standard.set(Date(), forKey: Self.lastSendKey)

        case .didFetchChanges:
            UserDefaults.standard.set(Date(), forKey: Self.lastReceiveKey)

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
            let record = Self.baseRecord(recordType: "PersonalWord", recordID: recordID, store: store)
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
            let record = Self.baseRecord(recordType: "Shortcut", recordID: recordID, store: store)
            record.encryptedValues["trigger"] = state.trigger
            record.encryptedValues["phrase"] = state.phrase
            record["opensURL"] = state.opensURL ? 1 : 0
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

        // Whatever else happens, this is the server's current version of the
        // record: its change tag is what the next outgoing save must carry.
        if let data = Self.archiveSystemFields(of: record) {
            store.setSystemFields(data, forRecordName: name)
        }

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
                opensURL: ((record["opensURL"] as? Int) ?? 0) != 0,
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
        store.deleteSystemFields(forRecordName: name)
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

    /// Starts an outgoing record from its archived system fields when we have
    /// them (making the save an update against the server's change tag), or a
    /// fresh record (a first-time insert) when we don't.
    private static func baseRecord(recordType: CKRecord.RecordType, recordID: CKRecord.ID,
                                   store: DictionaryStore) -> CKRecord {
        if let data = store.systemFields(forRecordName: recordID.recordName),
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data),
           let record = CKRecord(coder: unarchiver),
           record.recordID == recordID {
            return record
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    private static func archiveSystemFields(of record: CKRecord) -> Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
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
