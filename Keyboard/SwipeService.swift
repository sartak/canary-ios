import Foundation
import SQLite3

enum SwipeKey {
    case required(Character)
    case optional(Character)

    var character: Character {
        switch self {
        case .required(let c), .optional(let c): return c
        }
    }

    var display: String {
        switch self {
        case .required(let c): return String(c).uppercased()
        case .optional(let c): return String(c).lowercased()
        }
    }

    var isRequired: Bool {
        if case .required = self { return true }
        return false
    }
}

class SwipeService {
    private let db: OpaquePointer
    private let candidatesStatement: OpaquePointer

    init?(db: OpaquePointer) {
        self.db = db

        let query = """
            SELECT word, frequency_rank FROM words
            WHERE word_lower LIKE ?
            ORDER BY frequency_rank LIMIT 5
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else {
            return nil
        }
        self.candidatesStatement = statement
    }

    deinit {
        sqlite3_finalize(candidatesStatement)
    }

    /// Decodes a swipe path into the best matching word
    /// - Parameter keySequence: Array of SwipeKeys crossed during swipe
    /// - Returns: Best matching word, or nil if no match found
    func decode(keySequence: [SwipeKey]) -> String? {
        queryCandidates(keySequence: keySequence).first
    }

    private func buildPattern(keySequence: [SwipeKey]) -> String {
        let required = keySequence.filter(\.isRequired).map(\.character)
        guard !required.isEmpty else { return "" }

        var pattern = keySequence.first?.isRequired == true ? "" : "%"
        pattern += required.map(String.init).joined(separator: "%")
        if keySequence.last?.isRequired == false {
            pattern += "%"
        }
        return pattern
    }

    private func queryCandidates(keySequence: [SwipeKey]) -> [String] {
        let pattern = buildPattern(keySequence: keySequence)
        guard !pattern.isEmpty else { return [] }

        sqlite3_bind_text(candidatesStatement, 1, pattern, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var candidates: [String] = []
        while sqlite3_step(candidatesStatement) == SQLITE_ROW {
            if let wordPtr = sqlite3_column_text(candidatesStatement, 0) {
                candidates.append(String(cString: wordPtr))
            }
        }

        sqlite3_reset(candidatesStatement)
        sqlite3_clear_bindings(candidatesStatement)

        return candidates
    }
}
