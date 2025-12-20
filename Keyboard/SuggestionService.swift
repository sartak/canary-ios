import Foundation
import SQLite3

protocol SuggestionServiceDelegate: AnyObject {
    func suggestionService(_ service: SuggestionService, didUpdateSuggestions typeahead: [(String, [InputAction])], autocorrect: String?, frequencies: CharacterDistribution)
}

enum InputAction {
    case insert(String)
    case moveCursor(Int)  // positive = forward, negative = backward
    case maybePunctuating(Bool)
    case deleteBackward
}

class SuggestionService {
    weak var delegate: SuggestionServiceDelegate?

    private var contextBefore: String?
    private var contextAfter: String?
    private var selectedText: String?

    private var typeaheadService: TypeaheadService
    private var frequencyService: FrequencyService
    private var swipeService: SwipeService

    private var autocorrectService: AutocorrectService
    private let db: OpaquePointer
    var autocorrectSuggestion: String?
    var autocorrectActions: [InputAction]?

    init?() {
        guard let path = Bundle(for: SuggestionService.self).path(forResource: "words", ofType: "db") else {
            return nil
        }

        var dbTemp: OpaquePointer?
        if sqlite3_open(path, &dbTemp) != SQLITE_OK {
            print("SuggestionService: Error opening database: \(String(cString: sqlite3_errmsg(dbTemp)))")
            if dbTemp != nil {
                sqlite3_close(dbTemp)
            }
            return nil
        }

        guard let db = dbTemp else {
            return nil
        }
        self.db = db

        let autocorrectService = AutocorrectService(db: db)
        guard let typeaheadService = TypeaheadService(db: db),
              let frequencyService = FrequencyService(db: db),
              let swipeService = SwipeService(db: db) else {
            sqlite3_close(db)
            return nil
        }

        self.autocorrectService = autocorrectService
        self.typeaheadService = typeaheadService
        self.frequencyService = frequencyService
        self.swipeService = swipeService
    }

    deinit {
        sqlite3_close(db)
    }

    func decodeSwipe(keySequence: [SwipeKey], shiftState: ShiftState) -> (word: String, actions: [InputAction])? {
        let pattern = keySequence.map(\.display).joined()

        let startTime = CFAbsoluteTimeGetCurrent()
        let word = swipeService.decode(keySequence: keySequence)
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = (endTime - startTime) * 1000

        guard let word = word else {
            print("SwipeService: '\(pattern)' -> no match in \(String(format: "%.3f", duration))ms")
            return nil
        }

        print("SwipeService: '\(pattern)' -> '\(word)' in \(String(format: "%.3f", duration))ms")
        let capitalizedWord = applySmartCapitalization(word: word, userPrefix: "", userSuffix: "", shiftState: shiftState)
        let actions: [InputAction] = [.insert(capitalizedWord + " "), .maybePunctuating(true)]
        return (capitalizedWord, actions)
    }

    func updateContext(before: String?, after: String?, selected: String?, autocorrectEnabled: Bool, shiftState: ShiftState) {
        self.contextBefore = before
        self.contextAfter = after
        self.selectedText = selected

        let (prefix, suffix) = extractCurrentWordContext()

        let frequencies = frequencyService.updateFrequencies(prefix: prefix, suffix: suffix)

        let (typeahead, exactMatch) = updateTypeahead(prefix: prefix, suffix: suffix, shiftState: shiftState)

        if autocorrectEnabled {
            if let exactMatch = exactMatch {
                // We have an exact match, do smart capitalization
                let smartCapitalizedWord = applySmartCapitalization(word: exactMatch, userPrefix: prefix, userSuffix: suffix, shiftState: shiftState)
                autocorrectSuggestion = smartCapitalizedWord != (prefix + suffix) ? smartCapitalizedWord : nil
            } else {
                // No exact match, proceed with autocorrect
                autocorrectSuggestion = updateAutocorrect(prefix: prefix, suffix: suffix, autocorrectEnabled: autocorrectEnabled, shiftState: shiftState)
            }
        } else {
            autocorrectSuggestion = nil
        }

        autocorrectActions = autocorrectSuggestion != nil ? createInputActions(for: autocorrectSuggestion!, prefix: prefix, suffix: suffix, excludeTrailingSpace: true) : nil

        let filteredTypeahead = if let correction = autocorrectSuggestion {
            typeahead.filter { $0.0 != correction }
        } else {
            typeahead
        }

        delegate?.suggestionService(self, didUpdateSuggestions: filteredTypeahead, autocorrect: autocorrectSuggestion, frequencies: frequencies)
    }

    private func updateAutocorrect(prefix: String, suffix: String, autocorrectEnabled: Bool = true, shiftState: ShiftState) -> String? {
        // Don't autocorrect when editing in the middle of text
        if prefix.isEmpty || !suffix.isEmpty || !autocorrectEnabled {
            return nil
        }

        // Handle possessive 's suffix: autocorrect just the word part, then append 's
        let (wordToCorrect, possessiveSuffix) = if (prefix.hasSuffix("'s") || prefix.hasSuffix("'S")) && prefix.count > 2 {
            (String(prefix.dropLast(2)), String(prefix.suffix(2)))
        } else {
            (prefix, "")
        }

        // Skip correction for strings containing invalid characters
        // Only allow words composed entirely of valid word characters
        if !wordToCorrect.indices.allSatisfy({ index in
            Self.isWordCharacter(in: wordToCorrect, at: index)
        }) {
            return nil
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let correction = autocorrectService.findBestCorrection(for: wordToCorrect.lowercased(), maxDistance: 2)
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = (endTime - startTime) * 1000 // Convert to milliseconds

        if let correction = correction {
            let finalCorrection = applySmartCapitalization(word: correction + possessiveSuffix, userPrefix: prefix, userSuffix: "", shiftState: shiftState)
            print("AutocorrectService: '\(prefix.lowercased())' -> '\(finalCorrection)' in \(String(format: "%.3f", duration))ms")
            return finalCorrection
        } else {
            print("AutocorrectService: '\(prefix.lowercased())' -> no correction in \(String(format: "%.3f", duration))ms")
            return nil
        }
    }

    private func updateTypeahead(prefix: String, suffix: String, shiftState: ShiftState) -> ([(String, [InputAction])], String?) {
        // Handle possessive 's suffix: search for just the word part
        let (searchPrefix, searchSuffix, possessiveSuffix) = if (prefix.hasSuffix("'s") || prefix.hasSuffix("'S")) && prefix.count > 2 {
            (String(prefix.dropLast(2)), suffix, String(prefix.suffix(2)))
        } else {
            (prefix, suffix, "")
        }

        let prefixLower = searchPrefix.lowercased()
        let suffixLower = searchSuffix.lowercased()

        let startTime = CFAbsoluteTimeGetCurrent()
        let (matchingWords, exactMatch) = typeaheadService.getCompletions(prefix: prefixLower, suffix: suffixLower)
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = (endTime - startTime) * 1000 // Convert to milliseconds

        if searchSuffix.isEmpty {
            print("TypeaheadService: '\(prefixLower)' -> \(matchingWords.count) completions in \(String(format: "%.3f", duration))ms")
        } else {
            print("TypeaheadService: '\(prefixLower)|\(suffixLower)' -> \(matchingWords.count) completions in \(String(format: "%.3f", duration))ms")
        }

        let filteredWords = if let exact = exactMatch {
            matchingWords.filter { $0 != exact }
        } else {
            matchingWords
        }

        let suggestions = filteredWords.map { word in
            let wordWithPossessive = word + possessiveSuffix
            let displayWord = applySmartCapitalization(word: wordWithPossessive, userPrefix: prefix, userSuffix: suffix, shiftState: shiftState)
            let actions = createInputActions(for: displayWord, prefix: prefix, suffix: suffix, excludeTrailingSpace: false)
            return (displayWord, actions)
        }

        let finalExactMatch = exactMatch.map { $0 + possessiveSuffix }
        return (suggestions, finalExactMatch)
    }

    /// Applies smart capitalization rules based on user input patterns
    ///
    /// Rules:
    /// - Users typically type lowercase, so preserve corpus capitalization unless user actively indicates otherwise
    /// - If user input is all lowercase → preserve corpus capitalization
    /// - If user uses capitals → apply their pattern, but only if it results in same or more capitals than corpus
    ///
    /// Examples with regular words:
    /// - "w|d" + "world" → "world" (all lowercase)
    /// - "W|d" + "world" → "World" (title case)
    /// - "Wo|d" + "world" → "World" (title case)
    /// - "W|D" + "world" → "WORLD" (all caps intent)
    /// - "WO|D" + "world" → "WORLD" (all caps)
    /// - "Wo|D" + "world" → "WorlD" (mixed case preserved)
    ///
    /// Examples with proper nouns:
    /// - "sh|" + "Shawn" → "Shawn" (preserve corpus caps)
    /// - "Sh|" + "Shawn" → "Shawn" (matches corpus)
    /// - "SH|" + "Shawn" → "SHAWN" (user wants all caps)
    /// - "SH|" + "should" → "SHOULD" (force all caps on regular word)
    ///
    /// Examples with acronyms:
    /// - "u|" + "USA" → "USA" (preserve corpus caps)
    /// - "U|" + "USA" → "USA" (preserve corpus caps)
    /// - "US|" + "USA" → "USA" (pattern matches corpus)
    /// - "us|" + "USA" → "USA" (preserve corpus caps)
    /// - "Us|" + "USA" → "USA" (preserve corpus caps)
    /// - "uS|" + "USA" → "USA" (preserve corpus caps)
    private func applySmartCapitalization(word: String, userPrefix: String, userSuffix: String, shiftState: ShiftState) -> String {
        let userPattern = userPrefix + userSuffix

        // If caps lock is on, capitalize the entire word unconditionally
        if shiftState == .capsLock {
            return word.uppercased()
        }

        // If user input is all lowercase, apply shift state only to untyped portions
        if userPattern.lowercased() == userPattern {
            let prefixLength = userPrefix.count
            let suffixLength = userSuffix.count
            let totalTypedLength = prefixLength + suffixLength

            // If entire word is typed, keep user's actual case
            if totalTypedLength >= word.count {
                switch shiftState {
                case .shifted:
                    // Only capitalize if this would be the first character
                    if prefixLength == 0 {
                        return word.prefix(1).uppercased() + word.dropFirst()
                    }
                    return word
                case .unshifted:
                    return word
                case .capsLock:
                    return word.uppercased()
                }
            } else {
                // Apply shift state only to untyped middle portion
                var result = word
                let middleEnd = word.count - suffixLength

                switch shiftState {
                case .shifted:
                    // Capitalize first untyped character if it's at the beginning
                    if prefixLength == 0 && middleEnd > 0 {
                        result = String(result.prefix(1)).uppercased() + String(result.dropFirst())
                    }
                case .unshifted:
                    // Keep corpus capitalization for untyped portion
                    break
                case .capsLock:
                    return word.uppercased()
                }

                return result
            }
        }

        // Apply user's capitalization pattern to the full word
        let patternLength = userPattern.count
        let wordLength = word.count

        guard patternLength > 0 && wordLength > 0 else { return word }

        var result = word
        let wordArray = Array(word)
        let patternArray = Array(userPattern)

        // Apply capitalization pattern character by character
        for i in 0..<min(patternLength, wordLength) {
            let patternChar = patternArray[i]
            let wordChar = wordArray[i]

            if patternChar.isUppercase {
                result = String(result.prefix(i)) + String(wordChar).uppercased() + String(result.dropFirst(i + 1))
            } else {
                result = String(result.prefix(i)) + String(wordChar).lowercased() + String(result.dropFirst(i + 1))
            }
        }

        // If pattern is shorter than word, preserve remaining corpus capitalization
        // If user pattern shows "all caps intent" (no lowercase letters and multiple letters), apply to whole word
        if patternLength < wordLength {
            let hasLowercase = userPattern.contains { $0.isLowercase }
            let hasMultipleLetters = userPattern.filter { $0.isLetter }.count > 1
            let isAllCapsIntent = !hasLowercase && hasMultipleLetters

            if isAllCapsIntent {
                result = result.uppercased()
            }
            // Otherwise keep remaining characters as they were in corpus
        }

        return result
    }

    static func isWordCharacter(in text: String, at index: String.Index) -> Bool {
        let char = text[index]

        if char.isLetter {
            return true
        }

        // Include apostrophe only if it's surrounded by letters on both sides
        if char == "'" {
            let hasLetterBefore = index > text.startIndex && text[text.index(before: index)].isLetter
            let hasLetterAfter = index < text.index(before: text.endIndex) && text[text.index(after: index)].isLetter
            return hasLetterBefore && hasLetterAfter
        }

        return false
    }

    private func extractCurrentWordContext() -> (prefix: String, suffix: String) {
        let prefix: String
        if let before = contextBefore {
            // Find the current word by walking backwards from the end until we hit a non-word character
            var wordStart = before.endIndex
            for index in before.indices.reversed() {
                if Self.isWordCharacter(in: before, at: index) {
                    wordStart = index
                } else {
                    break
                }
            }
            prefix = String(before[wordStart...])
        } else {
            prefix = ""
        }

        let suffix: String
        if let after = contextAfter {
            // Find the suffix by walking forward from the beginning until we hit a non-word character
            var wordEnd = after.startIndex
            for index in after.indices {
                if Self.isWordCharacter(in: after, at: index) {
                    wordEnd = after.index(after: index)
                } else {
                    break
                }
            }
            suffix = String(after[..<wordEnd])
        } else {
            suffix = ""
        }

        return (prefix, suffix)
    }

    private func createInputActions(for word: String, prefix: String, suffix: String, excludeTrailingSpace: Bool) -> [InputAction] {
        var actions: [InputAction] = []
        var addTrailingSpace = !excludeTrailingSpace

        // Find remaining part of word after matching prefix
        var remainingWord = word

        if !prefix.isEmpty {
            let wordChars = Array(word)
            let prefixChars = Array(prefix)
            let minLength = min(wordChars.count, prefixChars.count)
            var matchingPrefixLength = 0

            for i in 0..<minLength {
                if wordChars[i] == prefixChars[i] {
                    matchingPrefixLength += 1
                } else {
                    break
                }
            }

            // Delete the mismatched part of the prefix
            let charsToDelete = prefix.count - matchingPrefixLength
            for _ in 0..<charsToDelete {
                actions.append(.deleteBackward)
            }

            remainingWord = String(word.dropFirst(matchingPrefixLength))
        }

        if !remainingWord.isEmpty && !suffix.isEmpty {
            let insertText = String(remainingWord.dropLast(suffix.count))
            actions.append(.insert(insertText))

            // Move cursor past suffix
            actions.append(.moveCursor(suffix.count))

            // Check if we're at the very end of the document
            if let after = contextAfter, after.dropFirst(suffix.count).isEmpty {
            } else {
                addTrailingSpace = false
            }
        } else if !remainingWord.isEmpty {
            actions.append(.insert(remainingWord))
        } else if !suffix.isEmpty {
            let insertText = String(remainingWord.dropLast(suffix.count))
            actions.append(.insert(insertText))
            addTrailingSpace = false
        } else {
            addTrailingSpace = false
        }

        if addTrailingSpace {
            actions.append(.insert(" "))
            actions.append(.maybePunctuating(true))
        }

        return actions
    }
}
