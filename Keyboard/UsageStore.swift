//
//  UsageStore.swift
//  Keyboard
//
//  Created by Claude on 7/4/26.
//

import CoreGraphics
import Foundation
import SQLite3

/// Kinds of tap-typing correction signal we log (swiping.md §9, PLAN.md M9).
enum TapEventKind: String {
    case autocorrectApplied = "autocorrect_applied"
    case autocorrectRejected = "autocorrect_rejected"
    case suggestionPicked = "suggestion_picked"
}

/// Local, append-only usage/correction log for both swipe and tap typing.
///
/// PLAN.md Milestone 9 nominally calls for Core Data; we deliberately use raw
/// SQLite instead. It matches every other persistence surface in this codebase
/// (`SwipeLexicon`, `SuggestionService`, the bundled `words.db`) and avoids
/// standing up a Core Data stack inside a memory-capped keyboard extension.
///
/// This store owns its OWN database (`usage.db`) — never `words.db`, which ships
/// read-only in the app bundle. A keyboard extension *without* Full Access can
/// still read and write its own sandbox container, so no `RequestsOpenAccess` is
/// needed here. Only sharing this data with the containing app (a future
/// dictionary-management UI) would require an App Group; that is out of scope now.
///
/// Everything is best-effort and must never take typing down: the initializer is
/// failable, the database is opened lazily on the first write (cold-start latency
/// matters), and every method silently no-ops on any error, printing a one-line
/// diagnostic in the house style rather than asserting or crashing.
///
/// This milestone is logging only — no typing behavior changes based on the data.
final class UsageStore {
    private let dbURL: URL
    private var db: OpaquePointer?
    /// Latches once opening fails so we don't retry the open on every keystroke.
    private var openFailed = false

    private static let swipeCorrectionCap = 2000
    private static let tapEventCap = 5000

    /// Resolves the on-disk path; does NOT open the database yet.
    init?() {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else {
            print("UsageStore: could not resolve application support directory")
            return nil
        }
        self.dbURL = support.appendingPathComponent("usage.db")
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Increment the lifetime swipe-commit counter (denominator for correction rate).
    func recordSwipeCommit() {
        guard let db = connection() else { return }
        exec(db, """
            INSERT INTO counters (name, value) VALUES ('swipe_commits', 1)
            ON CONFLICT(name) DO UPDATE SET value = value + 1
            """)
        print("UsageStore: swipe commit")
    }

    /// A swiped word was replaced by the user via a suggestion-bar tap.
    func recordSwipeCorrection(path: [CGPoint], committed: String, corrected: String,
                               ranked: [String], layout: String,
                               keyboardSize: CGSize, keyPitch: CGFloat) {
        guard let db = connection() else { return }

        let pathString = path.map { String(format: "%.1f,%.1f", $0.x, $0.y) }.joined(separator: ";")
        let rankedJSON = jsonArray(ranked)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO swipe_corrections
            (created_at, layout, keyboard_width, keyboard_height, key_pitch, committed, corrected, ranked, path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            print("UsageStore: could not prepare swipe correction insert")
            return
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, layout, -1, transient)
        sqlite3_bind_double(statement, 3, Double(keyboardSize.width))
        sqlite3_bind_double(statement, 4, Double(keyboardSize.height))
        sqlite3_bind_double(statement, 5, Double(keyPitch))
        sqlite3_bind_text(statement, 6, committed, -1, transient)
        sqlite3_bind_text(statement, 7, corrected, -1, transient)
        sqlite3_bind_text(statement, 8, rankedJSON, -1, transient)
        sqlite3_bind_text(statement, 9, pathString, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("UsageStore: swipe correction insert failed")
            return
        }
        trim(db, table: "swipe_corrections", cap: Self.swipeCorrectionCap)
        print("UsageStore: swipe correction '\(committed)' -> '\(corrected)' (path \(path.count) pts)")
    }

    /// A tap-typing correction signal: autocorrect applied/rejected, or a
    /// typeahead suggestion picked.
    func recordTapEvent(kind: TapEventKind, typed: String, resolved: String) {
        guard let db = connection() else { return }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO tap_events (created_at, kind, typed, resolved) VALUES (?, ?, ?, ?)
            """, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            print("UsageStore: could not prepare tap event insert")
            return
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, transient)
        sqlite3_bind_text(statement, 3, typed, -1, transient)
        sqlite3_bind_text(statement, 4, resolved, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("UsageStore: tap event insert failed")
            return
        }
        trim(db, table: "tap_events", cap: Self.tapEventCap)
        print("UsageStore: tap \(kind.rawValue) '\(typed)' -> '\(resolved)'")
    }

    // MARK: - Lazy open

    /// Returns the open database, opening and provisioning it on first use.
    private func connection() -> OpaquePointer? {
        if let db = db { return db }
        if openFailed { return nil }
        guard let opened = openAndProvision() else {
            openFailed = true
            return nil
        }
        db = opened
        return opened
    }

    private func openAndProvision() -> OpaquePointer? {
        let directory = dbURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let opened = handle else {
            print("UsageStore: could not open \(dbURL.path)")
            if handle != nil { sqlite3_close(handle) }
            return nil
        }

        exec(opened, "PRAGMA journal_mode=WAL;")
        exec(opened, Self.schemaSQL)
        return opened
    }

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS swipe_corrections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            layout TEXT NOT NULL,
            keyboard_width REAL NOT NULL,
            keyboard_height REAL NOT NULL,
            key_pitch REAL NOT NULL,
            committed TEXT NOT NULL,
            corrected TEXT NOT NULL,
            ranked TEXT NOT NULL,
            path TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tap_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            kind TEXT NOT NULL,
            typed TEXT NOT NULL,
            resolved TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS counters (
            name TEXT PRIMARY KEY,
            value INTEGER NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1');
        """

    // MARK: - Helpers

    /// Retain only the newest `cap` rows; delete everything older. A no-op when
    /// the table holds `cap` rows or fewer (the OFFSET subquery yields no id).
    private func trim(_ db: OpaquePointer, table: String, cap: Int) {
        exec(db, """
            DELETE FROM \(table) WHERE id <= (
                SELECT id FROM \(table) ORDER BY id DESC LIMIT 1 OFFSET \(cap)
            )
            """)
    }

    private func jsonArray(_ items: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    @discardableResult
    private func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            print("UsageStore: exec failed: \(message)")
            sqlite3_free(errorMessage)
            return false
        }
        return true
    }
}
