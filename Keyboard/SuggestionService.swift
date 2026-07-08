import CoreGraphics
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
    private var swipeDecoder: SwipeDecoder

    private var autocorrectService: AutocorrectService
    private let db: OpaquePointer
    var autocorrectSuggestion: String?
    var autocorrectActions: [InputAction]?

    /// Usage/learning store (Milestone 9). Correction logging plus word learning
    /// and personal frequency. Propagated to the decoder so the swipe prior can
    /// blend in personal counts.
    weak var usageStore: UsageStore? {
        didSet { swipeDecoder.usageStore = usageStore }
    }
    /// Raw word the user has actually typed (the current prefix), captured on each
    /// context update so autocorrect events can be logged with what was typed.
    private(set) var lastTypedWord: String = ""
    /// Alpha-layer key geometry, pushed by the controller whenever key frames
    /// change, so correction ranking can prefer physically plausible
    /// substitutions (the mistyped key's neighbors). nil until first pushed;
    /// ranking falls back to frequency alone.
    private var keyCenters: KeyCenters?
    private var keyPitch: CGFloat = 0
    /// Runner-up corrections behind `autocorrectSuggestion` (already
    /// smart-capitalized), surfaced in the suggestion bar for manual picking.
    private var alternativeCorrections: [String] = []

    /// Mean key-center distance (in key pitches) at or below which a wrong
    /// character counts as physically plausible fat-fingering. One key pitch is
    /// an immediate neighbor; 1.5 admits the diagonal ring.
    private static let adjacentKeyThreshold: CGFloat = 1.5

    func updateKeyGeometry(keyCenters: KeyCenters, keyPitch: CGFloat) {
        self.keyCenters = keyCenters
        self.keyPitch = keyPitch
    }

    /// Feeds iOS-provided UILexicon words (contact names, single-word text
    /// replacements) into the session's personal dictionary. Corpus words are
    /// already first-class and are filtered out here so no consumption path
    /// ever sees the same word from two sources; multi-word phrases fail the
    /// store's word hygiene (text expansion is Milestone 10's business).
    func setSupplementaryLexicon(words: [String]) {
        guard let store = usageStore else { return }
        store.setExternalWords(words.filter { !lexiconContains($0.lowercased()) })
    }
    /// The prefix from the PREVIOUS `updateContext`, used to detect a word commit:
    /// a non-empty previous prefix followed by an empty one means the user just
    /// typed a word boundary and completed a word (see `detectWordCommit`).
    private var previousPrefix: String = ""
    /// The correction most recently applied by autocorrect, remembered so a word
    /// commit can attribute the count to the CORRECTED word even when it shares no
    /// prefix with what was typed (e.g. "teh" → "the"). Consumed once, then cleared.
    private var lastAppliedCorrection: String?

    /// Prepared existence check against the shipped lexicon, so promotions and the
    /// rejection fast-track never "learn" a word the corpus already knows.
    private lazy var lexiconExistsStatement: OpaquePointer? = {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM words WHERE word_lower = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            print("SuggestionService: could not prepare lexicon exists check")
            return nil
        }
        return stmt
    }()

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
              let frequencyService = FrequencyService(db: db) else {
            sqlite3_close(db)
            return nil
        }

        self.autocorrectService = autocorrectService
        self.typeaheadService = typeaheadService
        self.frequencyService = frequencyService
        self.swipeDecoder = SwipeDecoder(lexicon: SwipeLexicon(db: db))
    }

    deinit {
        if let lexiconExistsStatement {
            sqlite3_finalize(lexiconExistsStatement)
        }
        sqlite3_close(db)
    }

    /// Memory-pressure hook: forwards to the swipe decoder's template cache
    /// and asks SQLite to shed page cache.
    func releaseMemory() {
        swipeDecoder.releaseMemory()
        sqlite3_db_release_memory(db)
    }

    struct SwipeDecodeResult {
        /// Capitalized word that was committed.
        let word: String
        /// Actions that insert the word (word + trailing space + maybePunctuating).
        let actions: [InputAction]
        /// Tap-to-replace alternatives, committed word excluded: each deletes the
        /// inserted word (word.count + 1 including trailing space) and inserts itself.
        let replacements: [(String, [InputAction])]
        /// Top-ranked candidates' ideal polylines for the debug overlay (max 3).
        let debugTemplatePaths: [[CGPoint]]
    }

    /// Single decode on touch-up: commit actions and replacement suggestions come
    /// from one ranked list (swiping.md §4.8). Returns nil when the decoder
    /// rejects the swipe.
    func decodeSwipe(path: [CGPoint], keyCenters: KeyCenters, keyPitch: CGFloat,
                     shiftState: ShiftState) -> SwipeDecodeResult? {
        guard !path.isEmpty else { return nil }

        let candidates = swipeDecoder.decode(path: path, keyCenters: keyCenters, keyPitch: keyPitch)
        guard let best = candidates.first else { return nil }

        let committedWord = applySmartCapitalization(word: best.word, userPrefix: "", userSuffix: "", shiftState: shiftState)
        let actions: [InputAction] = [.insert(committedWord + " "), .maybePunctuating(true)]

        // Replacements: every candidate except the committed one. Each deletes the
        // inserted word plus its trailing space, then inserts itself.
        let replaceLength = committedWord.count + 1
        let replacements: [(String, [InputAction])] = candidates.dropFirst().map { candidate in
            let capitalizedWord = applySmartCapitalization(word: candidate.word, userPrefix: "", userSuffix: "", shiftState: shiftState)
            var replaceActions: [InputAction] = []
            for _ in 0..<replaceLength {
                replaceActions.append(.deleteBackward)
            }
            replaceActions.append(.insert(capitalizedWord + " "))
            replaceActions.append(.maybePunctuating(true))
            return (capitalizedWord, replaceActions)
        }

        // Debug overlay: the ideal polylines of the top ≤3 candidates. SwipeCandidate
        // doesn't carry the template, so rebuild them locally.
        let debugTemplatePaths: [[CGPoint]] = candidates.prefix(3).compactMap { candidate in
            SwipeTemplate.make(word: candidate.word, keyCenters: keyCenters)?.polyline
        }

        return SwipeDecodeResult(word: committedWord, actions: actions,
                                 replacements: replacements, debugTemplatePaths: debugTemplatePaths)
    }

    /// Mid-swipe candidates for the suggestion bar.
    func liveSwipeSuggestions(path: [CGPoint], keyCenters: KeyCenters, keyPitch: CGFloat,
                              shiftState: ShiftState) -> [(String, [InputAction])] {
        swipeDecoder.liveCandidates(path: path, keyCenters: keyCenters, keyPitch: keyPitch).map { candidate in
            let capitalizedWord = applySmartCapitalization(word: candidate.word, userPrefix: "", userSuffix: "", shiftState: shiftState)
            let actions: [InputAction] = [.insert(capitalizedWord + " "), .maybePunctuating(true)]
            return (capitalizedWord, actions)
        }
    }

    /// Called when the pending autocorrect is actually applied on commit, so the
    /// signal can be logged (swiping.md §9). Logging only; no behavior change.
    func noteAutocorrectApplied() {
        guard let correction = autocorrectSuggestion else { return }
        usageStore?.recordTapEvent(kind: .autocorrectApplied, typed: lastTypedWord, resolved: correction)
        // Remember the correction so the imminent word-commit counts the CORRECTED
        // word (see detectWordCommit). Built-in safety: because the committed
        // context word is the correction — never the typo — a misspelling can
        // never accumulate usage counts and so can never be promoted.
        lastAppliedCorrection = correction
    }

    /// `learningEnabled` gates word-usage counting and promotion; the
    /// controller passes false when the HOST app disables autocorrection
    /// (terminal emulators, code editors — not natural language, so commands
    /// like 'sudo' must never accrue counts and get learned). The user's own
    /// autocorrect toggle deliberately does NOT gate learning: it means "stop
    /// correcting me", not "stop learning my vocabulary".
    func updateContext(before: String?, after: String?, selected: String?, autocorrectEnabled: Bool, learningEnabled: Bool, shiftState: ShiftState) {
        self.contextBefore = before
        self.contextAfter = after
        self.selectedText = selected

        let (prefix, suffix) = Self.extractWordContext(before: before, after: after)
        lastTypedWord = prefix

        if learningEnabled {
            detectWordCommit(before: before, prefix: prefix)
        } else {
            // Keep the transition state coherent so re-entering a normal field
            // can't misattribute a commit across the boundary.
            lastAppliedCorrection = nil
        }
        previousPrefix = prefix

        let frequencies = frequencyService.updateFrequencies(prefix: prefix, suffix: suffix)

        let (typeahead, exactMatch) = updateTypeahead(prefix: prefix, suffix: suffix, shiftState: shiftState)

        // updateAutocorrect repopulates these when it proposes a correction;
        // every other path through the branch below leaves them empty.
        alternativeCorrections = []

        if autocorrectEnabled {
            if let exactMatch = exactMatch {
                // We have an exact match, do smart capitalization
                let smartCapitalizedWord = applySmartCapitalization(word: exactMatch, userPrefix: prefix, userSuffix: suffix, shiftState: shiftState)
                autocorrectSuggestion = smartCapitalizedWord != (prefix + suffix) ? smartCapitalizedWord : nil
            } else if suffix.isEmpty, !prefix.isEmpty,
                      let learnedWord = usageStore?.learnedWord(for: prefix.lowercased()) {
                // A learned word is first-class, exactly like a lexicon exact
                // match: never correct it away, but do propose its learned
                // casing when that differs from what was typed ("claude" ->
                // "Claude"), the same way the lexicon's "i" -> "I" works.
                // Declining that proposal flows through the rejection
                // fast-track, whose trusted bump downgrades the learned casing
                // — so the proposal stops recurring.
                let smartCapitalizedWord = applySmartCapitalization(word: learnedWord, userPrefix: prefix, userSuffix: suffix, shiftState: shiftState)
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

        // Runner-up corrections are manually pickable from the bar, ahead of
        // literal-prefix completions (which rarely exist for a typo). The top
        // correction stays in the dedicated autocorrect slot.
        let alternativeItems: [(String, [InputAction])] = alternativeCorrections.map { word in
            (word, createInputActions(for: word, prefix: prefix, suffix: suffix, excludeTrailingSpace: false))
        }
        let alternativeWords = Set(alternativeItems.map { $0.0 })
        let combinedTypeahead = alternativeItems + filteredTypeahead.filter { !alternativeWords.contains($0.0) }

        delegate?.suggestionService(self, didUpdateSuggestions: combinedTypeahead, autocorrect: autocorrectSuggestion, frequencies: frequencies)
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
        let corrections = rankedCorrections(for: wordToCorrect.lowercased(), maxDistance: 2, limit: 4)
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = (endTime - startTime) * 1000 // Convert to milliseconds

        guard let best = corrections.first else {
            alternativeCorrections = []
            print("AutocorrectService: '\(prefix.lowercased())' -> no correction in \(String(format: "%.3f", duration))ms")
            return nil
        }

        let finalCorrection = applySmartCapitalization(word: best.word + possessiveSuffix, userPrefix: prefix, userSuffix: "", shiftState: shiftState)
        alternativeCorrections = corrections.dropFirst().map { candidate in
            applySmartCapitalization(word: candidate.word + possessiveSuffix, userPrefix: prefix, userSuffix: "", shiftState: shiftState)
        }

        let source = best.learned ? " (learned)" : ""
        let alts = alternativeCorrections.isEmpty ? "" : " alts=[\(alternativeCorrections.joined(separator: ", "))]"
        print("AutocorrectService: '\(prefix.lowercased())' -> '\(finalCorrection)'\(source)\(alts) in \(String(format: "%.3f", duration))ms")
        return finalCorrection
    }

    private struct CorrectionCandidate {
        let word: String
        let distance: Int
        /// 0 = physically adjacent substitutions, 1 = plausibility unknown
        /// (length changed, or no geometry), 2 = far substitutions.
        let spatialBucket: Int
        let learned: Bool
        let frequencyRank: Int
        let personalCount: Int
    }

    /// SymSpell corrections over the corpus merged with a direct scan of the
    /// learned set (which is tiny, so verifying every entry with the same
    /// edit-distance metric costs less than the corpus query's own
    /// delete-generation — no parallel deletes table needed). Ranking is
    /// lexicographic so every decision is explainable: smaller edit distance;
    /// then physical plausibility (an x→d slip beats an x→s reach when d is
    /// the neighboring key); then learned over corpus (personal vocabulary
    /// bias); then personal count / corpus frequency.
    private func rankedCorrections(for wordLower: String, maxDistance: Int,
                                   limit: Int) -> [(word: String, learned: Bool)] {
        var candidates = autocorrectService
            .findCorrections(for: wordLower, maxDistance: maxDistance, limit: 8)
            .map { corpus in
                CorrectionCandidate(word: corpus.word, distance: corpus.distance,
                                    spatialBucket: spatialBucket(typed: wordLower, candidate: corpus.word.lowercased()),
                                    learned: false, frequencyRank: corpus.frequencyRank,
                                    personalCount: 0)
            }

        if let store = usageStore {
            for candidate in store.learnedWords() {
                let candidateLower = candidate.lowercased()
                if candidateLower == wordLower { continue }  // exact match is exempted upstream
                let distance = autocorrectService.editDistance(wordLower, candidateLower, maxDistance: maxDistance)
                guard distance <= maxDistance else { continue }
                candidates.append(CorrectionCandidate(
                    word: candidate, distance: distance,
                    spatialBucket: spatialBucket(typed: wordLower, candidate: candidateLower),
                    learned: true, frequencyRank: 0,
                    personalCount: store.personalCount(for: candidateLower)))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            if lhs.spatialBucket != rhs.spatialBucket { return lhs.spatialBucket < rhs.spatialBucket }
            if lhs.learned != rhs.learned { return lhs.learned }
            if lhs.learned { return lhs.personalCount > rhs.personalCount }
            return lhs.frequencyRank < rhs.frequencyRank
        }

        // A word can reach here from both sources when a corpus update adds a
        // previously-learned word; keep only its best-ranked appearance.
        var seen: Set<String> = []
        var deduped: [(word: String, learned: Bool)] = []
        for candidate in candidates where seen.insert(candidate.word.lowercased()).inserted {
            deduped.append((candidate.word, candidate.learned))
            if deduped.count == limit { break }
        }
        return deduped
    }

    /// Physical plausibility of mistyping `candidate` as `typed`. Computable
    /// only for equal-length candidates: an adjacent transposition ("teh" for
    /// "the") is maximally plausible regardless of key positions — the fingers
    /// hit the right keys in the wrong order; otherwise the mean key-center
    /// distance of the mismatched positions, bucketed against
    /// `adjacentKeyThreshold`. Length-changing edits and missing geometry land
    /// in the middle bucket.
    private func spatialBucket(typed: String, candidate: String) -> Int {
        guard let keyCenters, keyPitch > 0 else { return 1 }
        let a = Array(typed), b = Array(candidate)
        guard a.count == b.count else { return 1 }

        var mismatchIndices: [Int] = []
        for i in 0..<a.count where a[i] != b[i] {
            mismatchIndices.append(i)
        }
        guard !mismatchIndices.isEmpty else { return 1 }

        if mismatchIndices.count == 2 {
            let (first, second) = (mismatchIndices[0], mismatchIndices[1])
            if second == first + 1, a[first] == b[second], a[second] == b[first] {
                return 0
            }
        }

        var total: CGFloat = 0
        for i in mismatchIndices {
            guard let typedCenter = keyCenters.centers[a[i]],
                  let candidateCenter = keyCenters.centers[b[i]] else { return 1 }
            let dx = typedCenter.x - candidateCenter.x
            let dy = typedCenter.y - candidateCenter.y
            total += (dx * dx + dy * dy).squareRoot()
        }

        let meanPitches = total / CGFloat(mismatchIndices.count) / keyPitch
        return meanPitches <= Self.adjacentKeyThreshold ? 0 : 2
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

        var suggestions = filteredWords.map { word in
            let wordWithPossessive = word + possessiveSuffix
            let displayWord = applySmartCapitalization(word: wordWithPossessive, userPrefix: prefix, userSuffix: suffix, shiftState: shiftState)
            let actions = createInputActions(for: displayWord, prefix: prefix, suffix: suffix, excludeTrailingSpace: false)
            return (displayWord, actions)
        }

        // Append learned words that complete the current prefix, using the same
        // capitalization/action plumbing as regular completions. Regular
        // completions keep priority (they're already in `suggestions`); learned
        // extras are capped so they never crowd the bar.
        if !searchPrefix.isEmpty, let store = usageStore {
            var existing = Set(suggestions.map { $0.0.lowercased() })
            var added = 0
            for learnedWord in store.learnedWords() {
                if added >= 2 { break }
                let learnedLower = learnedWord.lowercased()
                // Complete the prefix, but don't suggest the word the user has
                // already typed in full.
                guard learnedLower.hasPrefix(prefixLower), learnedLower != prefixLower else { continue }
                let wordWithPossessive = learnedWord + possessiveSuffix
                let displayWord = applySmartCapitalization(word: wordWithPossessive, userPrefix: prefix, userSuffix: suffix, shiftState: shiftState)
                if existing.contains(displayWord.lowercased()) { continue }
                let actions = createInputActions(for: displayWord, prefix: prefix, suffix: suffix, excludeTrailingSpace: false)
                suggestions.append((displayWord, actions))
                existing.insert(displayWord.lowercased())
                added += 1
            }
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

    // MARK: - Word learning (Milestone 9 stage 2)

    /// Detects a completed word from the prefix transition and records one use of
    /// it, promoting it when warranted. A word is committed when the previous
    /// update had a partial word (`previousPrefix` non-empty) and this one has
    /// none (`prefix` empty) — the user just typed a boundary character.
    ///
    /// Guarded against cursor-jump / field-switch false positives: the completed
    /// word from the new context must be EITHER the word the user was typing
    /// (`previousPrefix` is a case-insensitive prefix of it) OR the correction
    /// autocorrect just applied. Suggestion picks and autocorrect commits both
    /// flow through this same transition, so they are counted here (not double).
    private func detectWordCommit(before: String?, prefix: String) {
        guard !previousPrefix.isEmpty, prefix.isEmpty, let before = before else { return }

        let appliedCorrection = lastAppliedCorrection
        lastAppliedCorrection = nil

        let (committed, sentenceInitial) = Self.lastCompletedWord(in: before)
        guard !committed.isEmpty else { return }

        let matchesTyped = committed.lowercased().hasPrefix(previousPrefix.lowercased())
        let matchesCorrection = appliedCorrection.map { $0 == committed } ?? false
        guard matchesTyped || matchesCorrection else { return }

        // Sentence-initial capitalization is auto-shift noise, not evidence of
        // how the user cases the word — count the use but keep the stored casing.
        recordCommittedWord(committed, trustCasing: !sentenceInitial)
    }

    /// The word immediately before the trailing boundary character(s) of `before`,
    /// using the same `isWordCharacter` rule as prefix/suffix extraction, plus
    /// whether that word sat at a sentence start (field start, or after a
    /// sentence terminator) where auto-shift capitalizes regardless of intent.
    private static func lastCompletedWord(in before: String) -> (word: String, sentenceInitial: Bool) {
        // Skip the trailing boundary character(s) the user just typed.
        var end = before.endIndex
        while end > before.startIndex {
            let prev = before.index(before: end)
            if isWordCharacter(in: before, at: prev) { break }
            end = prev
        }
        guard end > before.startIndex else { return ("", false) }

        // Walk back to the start of that word.
        var start = end
        while start > before.startIndex {
            let prev = before.index(before: start)
            if isWordCharacter(in: before, at: prev) {
                start = prev
            } else {
                break
            }
        }

        // Sentence-initial: nothing but spaces between the word and the field
        // start or the previous sentence's terminator.
        var probe = start
        while probe > before.startIndex, before[before.index(before: probe)] == " " {
            probe = before.index(before: probe)
        }
        let sentenceInitial: Bool
        if probe == before.startIndex {
            sentenceInitial = true
        } else {
            let preceding = before[before.index(before: probe)]
            sentenceInitial = preceding == "." || preceding == "!" || preceding == "?" || preceding == "\n"
        }

        return (String(before[start..<end]), sentenceInitial)
    }

    /// Records one committed use of `word`: bumps personal usage and, when the
    /// count crosses the promotion threshold for a word the lexicon doesn't know
    /// and hasn't already learned, promotes it to the learned set. Pass
    /// `trustCasing: false` when the word's capitalization is not the user's own
    /// doing (sentence-start auto-shift, swipe-inserted casing).
    func recordCommittedWord(_ word: String, trustCasing: Bool = true) {
        guard let store = usageStore else { return }
        let count = store.bumpWordUsage(word, trustCasing: trustCasing)
        guard count >= LearningTuning.promotionThreshold else { return }
        let lower = word.lowercased()
        guard !store.isLearned(lower), !lexiconContains(lower) else { return }
        store.markLearned(word)
    }

    /// Fast-track learn: the user tapped the bar to reject an autocorrect of
    /// `lastTypedWord`, so learn it immediately — one rejection = learned — and
    /// count the use. Same lexicon + hygiene guards as threshold promotion.
    func learnRejectedWord() {
        guard let store = usageStore else { return }
        let word = lastTypedWord
        let count = store.bumpWordUsage(word)
        guard count > 0 else { return }  // hygiene guard rejected it
        let lower = word.lowercased()
        guard !lexiconContains(lower) else { return }
        store.markLearned(word, reason: "rejection")
    }

    /// Whether the shipped lexicon (`words.db`) already contains `wordLower`.
    private func lexiconContains(_ wordLower: String) -> Bool {
        guard let statement = lexiconExistsStatement else { return false }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, wordLower, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func extractWordContext(before: String?, after: String?) -> (prefix: String, suffix: String) {
        let prefix: String
        if let before = before {
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
        if let after = after {
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
