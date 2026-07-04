import Foundation
import SQLite3

struct CharacterDistribution {
    private let frequencies: [Int]

    init(frequencies: [Int]) {
        precondition(frequencies.count == 26, "CharacterDistribution must have exactly 26 frequencies")
        self.frequencies = frequencies
    }

    subscript(char: Character) -> Int? {
        guard char >= "a" && char <= "z" else {
            return nil
        }
        let index = Int(char.asciiValue! - Character("a").asciiValue!)
        return frequencies[index]
    }

    func frequencyRatio(_ char1: Character, _ char2: Character) -> Double {
        let lowercased1 = Character(char1.lowercased())
        let lowercased2 = Character(char2.lowercased())
        guard let freq1 = self[lowercased1], let freq2 = self[lowercased2] else {
            return 0.5
        }
        let total = freq1 + freq2
        return total > 0 ? Double(freq1) / Double(total) : 0.5
    }

    static func fromDistributionString(_ distributionString: String) -> CharacterDistribution? {
        let counts = distributionString.split(separator: ",").compactMap { Int($0) }
        guard counts.count == 26 else { return nil }
        return CharacterDistribution(frequencies: counts)
    }
}

class FrequencyService {
    private let db: OpaquePointer

    private static let initialDistributionKey = "initial_distribution"
    private static let generalDistributionKey = "general_distribution"

    static private var initialDistribution: CharacterDistribution!
    static private var generalDistribution: CharacterDistribution!

    private let bigramStatement: OpaquePointer
    private let trigramStatement: OpaquePointer

    init?(db: OpaquePointer) {
        self.db = db

        var bigramStmt: OpaquePointer?
        var trigramStmt: OpaquePointer?

        let bigramQuery = "SELECT distribution FROM bigram_frequencies WHERE prefix = ?"
        let trigramQuery = "SELECT distribution FROM trigram_frequencies WHERE prefix = ?"

        guard sqlite3_prepare_v2(db, bigramQuery, -1, &bigramStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, trigramQuery, -1, &trigramStmt, nil) == SQLITE_OK,
              let bigramStatement = bigramStmt,
              let trigramStatement = trigramStmt else {

            sqlite3_finalize(bigramStmt)
            sqlite3_finalize(trigramStmt)
            return nil
        }

        self.bigramStatement = bigramStatement
        self.trigramStatement = trigramStatement

        FrequencyService.loadStaticDistributions(from: db)
    }

    deinit {
        sqlite3_finalize(bigramStatement)
        sqlite3_finalize(trigramStatement)
    }

    private static func loadStaticDistributions(from db: OpaquePointer) {
        guard initialDistribution == nil || generalDistribution == nil else { return }

        var stmt: OpaquePointer?
        let query = "SELECT key, value FROM kv WHERE key IN ('\(initialDistributionKey)', '\(generalDistributionKey)')"

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            print("FrequencyService: Failed to prepare statement")
            return
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let value = String(cString: sqlite3_column_text(stmt, 1))

            guard let distribution = CharacterDistribution.fromDistributionString(value) else { continue }

            switch key {
            case initialDistributionKey:
                initialDistribution = distribution
            case generalDistributionKey:
                generalDistribution = distribution
            default:
                break
            }
        }

        sqlite3_finalize(stmt)
    }

    private func loadBigramDistribution(prefix: String) -> CharacterDistribution? {
        sqlite3_bind_text(bigramStatement, 1, prefix, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var result: CharacterDistribution?
        if sqlite3_step(bigramStatement) == SQLITE_ROW {
            let value = String(cString: sqlite3_column_text(bigramStatement, 0))
            result = CharacterDistribution.fromDistributionString(value)
        }

        sqlite3_reset(bigramStatement)
        sqlite3_clear_bindings(bigramStatement)
        return result
    }

    private func loadTrigramDistribution(prefix: String) -> CharacterDistribution? {
        sqlite3_bind_text(trigramStatement, 1, prefix, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var result: CharacterDistribution?
        if sqlite3_step(trigramStatement) == SQLITE_ROW {
            let value = String(cString: sqlite3_column_text(trigramStatement, 0))
            result = CharacterDistribution.fromDistributionString(value)
        }

        sqlite3_reset(trigramStatement)
        sqlite3_clear_bindings(trigramStatement)
        return result
    }

    func updateFrequencies(prefix: String, suffix: String) -> CharacterDistribution {
        if prefix.isEmpty || prefix.last?.isWhitespace == true {
            return FrequencyService.initialDistribution
        }

        let lastTwoChars = String(prefix.suffix(2)).lowercased()
        if lastTwoChars.count == 2 && lastTwoChars.allSatisfy({ $0.isLetter }) {
            let startTime = CFAbsoluteTimeGetCurrent()
            if let distribution = loadTrigramDistribution(prefix: lastTwoChars) {
                let endTime = CFAbsoluteTimeGetCurrent()
                let duration = (endTime - startTime) * 1000
                print("FrequencyService: trigram '\(lastTwoChars)' in \(String(format: "%.3f", duration))ms")
                return distribution
            }
        }

        if let lastChar = prefix.last, lastChar.isLetter {
            let lastCharString = String(lastChar).lowercased()
            let startTime = CFAbsoluteTimeGetCurrent()
            if let distribution = loadBigramDistribution(prefix: lastCharString) {
                let endTime = CFAbsoluteTimeGetCurrent()
                let duration = (endTime - startTime) * 1000
                print("FrequencyService: bigram '\(lastCharString)' in \(String(format: "%.3f", duration))ms")
                return distribution
            }
        }

        return FrequencyService.generalDistribution
    }
}
