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
    /// Whether the pending autocorrect may be applied automatically on a
    /// boundary keypress. Mid-word corrections are bar-tap only: a boundary
    /// typed mid-word is an intentional split, and silently replacing the
    /// whole word would fight it.
    private(set) var autocorrectAutoApplies = true

    struct PendingShortcutExpansion {
        /// The trigger as typed (original casing).
        let trigger: String
        let phrase: String
        /// The character that completed the trigger; re-inserted after the
        /// phrase by the expansion.
        let boundary: Character
    }
    /// Fired when the token just completed by a boundary keypress is a known
    /// shortcut trigger. Detection only reports; the controller decides and
    /// performs the expansion.
    var onShortcutDetected: ((PendingShortcutExpansion) -> Void)?
    /// Whether the autocorrect slot currently shows a shortcut-phrase preview
    /// rather than a correction: no actions, no auto-apply — tapping the slot
    /// opts out for this word through the existing toggle path.
    private(set) var pendingShortcutPreview = false

    /// Mean key-center distance (in key pitches) at or below which a wrong
    /// character counts as physically plausible fat-fingering. One key pitch is
    /// an immediate neighbor; 1.5 admits the diagonal ring.
    private static let adjacentKeyThreshold: CGFloat = 1.5

    /// Foundation-model next-word predictions for the empty-prefix bar.
    /// A no-op off Apple Intelligence devices and pre-iOS 26.
    private let predictionService = PredictionService()
    /// Lowercased predicted words currently in the bar, for the view's
    /// affordance and for classifying bar taps as prediction picks. Cleared
    /// on every context update; set again when a delivery lands.
    private(set) var lastPredictedWords: Set<String> = []

    /// Lowercased runner-up corrections currently in the bar — they're
    /// spelling corrections, so the view paints them correction-orange.
    var correctionsInBar: Set<String> {
        Set(alternativeCorrections.map { $0.lowercased() })
    }

    /// Loads model resources ahead of the first query; call at launch.
    func prewarmPredictions() {
        guard !KeyboardSettings.predictionsDisabled else { return }
        predictionService.prewarm()
    }

    func updateKeyGeometry(keyCenters: KeyCenters, keyPitch: CGFloat) {
        self.keyCenters = keyCenters
        self.keyPitch = keyPitch
    }

    /// Routes iOS-provided UILexicon entries into the session state. Entries
    /// whose sides match case-insensitively are vocabulary (contact names)
    /// and join the personal dictionary — corpus words filtered out so no
    /// consumption path sees a word from two sources. Entries whose sides
    /// differ are text-replacement pairs ("omw" → "On my way!"), including
    /// the multi-word phrases the word path drops; they join the session
    /// shortcut map.
    func setSupplementaryLexicon(entries: [(userInput: String, documentText: String)]) {
        guard let store = usageStore else { return }
        var words: [String] = []
        var pairs: [(trigger: String, phrase: String)] = []
        for entry in entries {
            if entry.userInput.lowercased() == entry.documentText.lowercased() {
                if !lexiconContains(entry.documentText.lowercased()) {
                    words.append(entry.documentText)
                }
            } else {
                pairs.append((trigger: entry.userInput, phrase: entry.documentText))
            }
        }
        store.setExternalWords(words)
        store.setExternalShortcuts(pairs)
    }
    /// The prefix from the PREVIOUS `updateContext`, used to detect a word commit:
    /// a non-empty previous prefix followed by an empty one means the user just
    /// typed a word boundary and completed a word (see `detectWordCommit`).
    private var previousPrefix: String = ""
    /// The correction most recently applied by autocorrect, remembered so a word
    /// commit can attribute the count to the CORRECTED word even when it shares no
    /// prefix with what was typed (e.g. "teh" → "the"). Consumed once, then cleared.
    private var lastAppliedCorrection: String?
    /// The most recent autocorrect application, for silent-revert detection.
    private var lastAutocorrectApplication: (typed: String, corrected: String, at: Date)?

    /// Seconds after an apply within which a backspace counts as a revert.
    private static let revertWindow: TimeInterval = 3

    /// Called on every backspace press: a backspace inside the revert window
    /// after an autocorrect applied logs the silent rejection (the user is
    /// undoing/retyping rather than tapping the bar). One-shot per apply.
    func noteBackspace() {
        guard let application = lastAutocorrectApplication else { return }
        lastAutocorrectApplication = nil
        guard Date().timeIntervalSince(application.at) < Self.revertWindow else { return }
        usageStore?.recordTapEvent(kind: .autocorrectReverted,
                                   typed: application.typed,
                                   resolved: application.corrected)
    }

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

        let decodeStart = CFAbsoluteTimeGetCurrent()
        let candidates = swipeDecoder.decode(path: path, keyCenters: keyCenters, keyPitch: keyPitch)
        guard let best = candidates.first else { return nil }

        // Per-swipe telemetry (opt-in): duration, path length in key pitches,
        // pool size, and the top-two score margin — the distribution every
        // future decoder change gets judged against.
        usageStore?.recordSwipeEvent(
            word: best.word,
            durationMS: (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000,
            arcLengthPitches: keyPitch > 0 ? Double(PathGeometry.arcLength(path) / keyPitch) : 0,
            candidateCount: candidates.count,
            scoreMargin: candidates.count > 1 ? best.logScore - candidates[1].logScore : nil)

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
        // Armed for silent-revert detection: a backspace shortly after an
        // apply is a rejection the bar-tap path never sees (see noteBackspace).
        lastAutocorrectApplication = (typed: lastTypedWord, corrected: correction, at: Date())
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
            // Shortcut detection rides the same boundary transition and the
            // same host gate: fields that disable autocorrection (terminals)
            // must not expand tokens either.
            if !previousPrefix.isEmpty, prefix.isEmpty {
                detectShortcut(before: before)
            }
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
        pendingShortcutPreview = false
        lastPredictedWords = []

        if autocorrectEnabled {
            let typedForShortcut = prefix + suffix
            if !typedForShortcut.isEmpty,
               let phrase = usageStore?.shortcutPhrase(for: typedForShortcut.lowercased()) {
                // A trigger's phrase preview outranks every other proposal —
                // exact match, learned casing, correction — because the
                // expansion is what the boundary keypress will actually do.
                // (A trigger that also became a learned word would otherwise
                // show a casing proposal here instead of its phrase.)
                pendingShortcutPreview = true
                autocorrectSuggestion = phrase.count > 24 ? String(phrase.prefix(24)) + "…" : phrase
            } else if let exactMatch = exactMatch {
                // We have an exact match, do smart capitalization
                let smartCapitalizedWord = applySmartCapitalization(word: exactMatch, userPrefix: prefix, userSuffix: suffix, shiftState: shiftState)
                autocorrectSuggestion = smartCapitalizedWord != (prefix + suffix) ? smartCapitalizedWord : nil
            } else if !prefix.isEmpty,
                      let learnedWord = usageStore?.learnedWord(for: (prefix + suffix).lowercased()) {
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

        if let suggestion = autocorrectSuggestion {
            if pendingShortcutPreview {
                // A preview is not a correction: nothing to apply; the
                // expansion itself happens at the boundary keypress.
                autocorrectActions = nil
                autocorrectAutoApplies = false
            } else if suffix.isEmpty || exactMatch != nil {
                // End-of-word corrections and exact-match casing fixes keep
                // the completion-shaped actions (exact matches end with the
                // suffix by construction, so createInputActions is sound).
                autocorrectActions = createInputActions(for: suggestion, prefix: prefix, suffix: suffix, excludeTrailingSpace: true)
                autocorrectAutoApplies = true
            } else {
                autocorrectActions = midWordReplacementActions(for: suggestion, prefix: prefix, suffix: suffix)
                autocorrectAutoApplies = false
            }
        } else {
            autocorrectActions = nil
            autocorrectAutoApplies = true
        }

        let filteredTypeahead = if let correction = autocorrectSuggestion {
            typeahead.filter { $0.0 != correction }
        } else {
            typeahead
        }

        // Runner-up corrections are manually pickable from the bar, ahead of
        // literal-prefix completions (which rarely exist for a typo). The top
        // correction stays in the dedicated autocorrect slot. Mid-word,
        // completion-shaped actions are unsound (a correction need not end
        // with the suffix), so alternates use whole-word replacement too.
        let alternativeItems: [(String, [InputAction])] = alternativeCorrections.map { word in
            suffix.isEmpty
                ? (word, createInputActions(for: word, prefix: prefix, suffix: suffix, excludeTrailingSpace: false))
                : (word, midWordReplacementActions(for: word, prefix: prefix, suffix: suffix))
        }
        let alternativeWords = Set(alternativeItems.map { $0.0 })
        let combinedTypeahead = alternativeItems + filteredTypeahead.filter { !alternativeWords.contains($0.0) }

        // Empty hopper with the model available: the bar stays EMPTY while
        // inference runs — the frequency filler isn't worth reading, and an
        // empty bar that fills with purple beats a gray bar that shuffles.
        // Everywhere else (typing, predictions off, non-AI device, empty
        // document) the bar behaves as it always has. Gated on the host's
        // natural-language signal (terminals get no predictions); staleness
        // is re-checked on delivery.
        let willPredict = prefix.isEmpty && suffix.isEmpty && learningEnabled
            && !KeyboardSettings.predictionsDisabled
            && predictionService.isAvailable
            && before?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        delegate?.suggestionService(self, didUpdateSuggestions: willPredict ? [] : combinedTypeahead,
                                    autocorrect: autocorrectSuggestion, frequencies: frequencies)

        if willPredict, let before {
            predictionService.onServe = { [weak self] latencyMS, wordCount in
                self?.usageStore?.recordPredictionServe(durationMS: latencyMS, wordCount: wordCount)
            }
            predictionService.predict(context: before) { [weak self] words in
                guard let self, !words.isEmpty,
                      self.lastTypedWord.isEmpty, self.contextBefore == before else { return }
                self.lastPredictedWords = Set(words.map { $0.lowercased() })
                let items = words.map { word in
                    (word, self.createInputActions(for: word, prefix: "", suffix: "", excludeTrailingSpace: false))
                }
                self.delegate?.suggestionService(self, didUpdateSuggestions: items,
                                                 autocorrect: nil, frequencies: frequencies)
            }
        } else {
            // Typing resumed (or the field stopped qualifying): stop burning
            // inference on a bar that can no longer show the result.
            predictionService.cancel()
        }
    }

    private func updateAutocorrect(prefix: String, suffix: String, autocorrectEnabled: Bool = true, shiftState: ShiftState) -> String? {
        if prefix.isEmpty || !autocorrectEnabled {
            return nil
        }

        // Mid-word (non-empty suffix) the WHOLE word around the cursor is
        // corrected; the proposal is bar-tap only (see updateContext).
        let typedWord = prefix + suffix

        // Handle possessive 's suffix: autocorrect just the word part, then append 's
        let (wordToCorrect, possessiveSuffix) = if (typedWord.hasSuffix("'s") || typedWord.hasSuffix("'S")) && typedWord.count > 2 {
            (String(typedWord.dropLast(2)), String(typedWord.suffix(2)))
        } else {
            (typedWord, "")
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
            print("AutocorrectService: '\(typedWord.lowercased())' -> no correction in \(String(format: "%.3f", duration))ms")
            return nil
        }

        let finalCorrection = applySmartCapitalization(word: best.word + possessiveSuffix, userPrefix: prefix, userSuffix: suffix, shiftState: shiftState)
        alternativeCorrections = corrections.dropFirst().map { candidate in
            applySmartCapitalization(word: candidate.word + possessiveSuffix, userPrefix: prefix, userSuffix: suffix, shiftState: shiftState)
        }

        let source = best.learned ? " (learned)" : ""
        let alts = alternativeCorrections.isEmpty ? "" : " alts=[\(alternativeCorrections.joined(separator: ", "))]"
        print("AutocorrectService: '\(typedWord.lowercased())' -> '\(finalCorrection)'\(source)\(alts) in \(String(format: "%.3f", duration))ms")
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
    /// - "WRNg" + "wrong" → "WRoNg" (case follows the letters, not the indices)
    /// - "Teh" + "the" → "The" (case follows a transposition)
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
        guard !userPattern.isEmpty && !word.isEmpty else { return word }

        // All-caps intent (no lowercase letters, more than one letter) applies
        // to the whole word regardless of length differences.
        let hasLowercase = userPattern.contains { $0.isLowercase }
        let hasMultipleLetters = userPattern.filter { $0.isLetter }.count > 1
        if !hasLowercase && hasMultipleLetters {
            return word.uppercased()
        }

        return Self.caseTransferred(pattern: userPattern, onto: word)
    }

    /// Case-transfers `pattern`'s per-character casing onto `word` by aligning
    /// the two strings (optimal string alignment), so an inserted letter in a
    /// correction doesn't shift every subsequent transfer: "WRNg" + "wrong" is
    /// "WRoNg", not "WROng". Alignment ops and their transfer rules:
    /// match/substitution → the pattern char's case restyles the word char;
    /// insertion (char only in the word) → corpus casing survives;
    /// deletion (char only in the pattern) → contributes nothing;
    /// adjacent transposition → cases transfer crosswise, following each
    /// letter through the swap ("Teh" + "the" → "The").
    /// Backtrace ties prefer match > transposition > substitution > insertion
    /// > deletion, making the output deterministic.
    private static func caseTransferred(pattern: String, onto word: String) -> String {
        let p = Array(pattern)
        let w = Array(word)
        let pl = Array(pattern.lowercased())
        let wl = Array(word.lowercased())
        // Multi-character case foldings would desynchronize the arrays; bail
        // to the untouched word rather than misalign (vanishingly rare here).
        guard pl.count == p.count, wl.count == w.count else { return word }
        let m = p.count
        let n = w.count

        // Optimal string alignment DP (insert/delete/substitute/adjacent
        // transposition, all cost 1). Words are tiny; the full matrix is fine.
        var d = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { d[i][0] = i }
        for j in 0...n { d[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                let cost = pl[i - 1] == wl[j - 1] ? 0 : 1
                var best = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, pl[i - 1] == wl[j - 2], pl[i - 2] == wl[j - 1] {
                    best = min(best, d[i - 2][j - 2] + 1)
                }
                d[i][j] = best
            }
        }

        /// The pattern char's case restyles the word char; caseless pattern
        /// chars (apostrophes) leave the word char untouched.
        func styled(_ wordChar: Character, by patternChar: Character) -> Character {
            if patternChar.isUppercase {
                return Character(String(wordChar).uppercased())
            }
            if patternChar.isLowercase {
                return Character(String(wordChar).lowercased())
            }
            return wordChar
        }

        // Backtrace, building the result right-to-left. Tie order: match >
        // transposition > substitution > insertion > deletion.
        var result: [Character] = []
        var i = m
        var j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, pl[i - 1] == wl[j - 1], d[i][j] == d[i - 1][j - 1] {
                result.append(styled(w[j - 1], by: p[i - 1]))
                i -= 1
                j -= 1
            } else if i > 1, j > 1, pl[i - 1] == wl[j - 2], pl[i - 2] == wl[j - 1],
                      d[i][j] == d[i - 2][j - 2] + 1 {
                result.append(styled(w[j - 1], by: p[i - 2]))
                result.append(styled(w[j - 2], by: p[i - 1]))
                i -= 2
                j -= 2
            } else if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + 1 {
                result.append(styled(w[j - 1], by: p[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0, d[i][j] == d[i][j - 1] + 1 {
                result.append(w[j - 1])
                j -= 1
            } else {
                i -= 1
            }
        }
        return String(result.reversed())
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

        // A shortcut trigger is not vocabulary: the expansion is about to
        // replace it, and counting it would eventually learn "omw" as a word
        // (with whatever casing) that then competes with its own phrase.
        guard usageStore?.shortcutPhrase(for: committed.lowercased()) == nil else { return }

        // Sentence-initial capitalization is auto-shift noise, not evidence of
        // how the user cases the word — count the use but keep the stored casing.
        recordCommittedWord(committed, trustCasing: !sentenceInitial)
    }

    /// Reports the just-completed token when it is a shortcut trigger.
    private func detectShortcut(before: String?) {
        guard let before,
              let (token, boundary) = Self.lastCompletedToken(in: before),
              let phrase = usageStore?.shortcutPhrase(for: token.lowercased()) else { return }
        print("SuggestionService: shortcut '\(token)' detected (boundary '\(boundary)')")
        onShortcutDetected?(PendingShortcutExpansion(trigger: token, phrase: phrase, boundary: boundary))
    }

    /// The token immediately before EXACTLY ONE trailing boundary character.
    /// Distinct from the word-commit extractor: triggers may contain digits
    /// ("2nite"), so token characters are letters, digits, and apostrophes —
    /// the trigger hygiene charset. Two boundaries in a row return nil.
    static func lastCompletedToken(in before: String) -> (token: String, boundary: Character)? {
        guard let boundary = before.last, !isTokenCharacter(boundary) else { return nil }
        let end = before.index(before: before.endIndex)
        var start = end
        while start > before.startIndex {
            let previous = before.index(before: start)
            if isTokenCharacter(before[previous]) {
                start = previous
            } else {
                break
            }
        }
        guard start < end else { return nil }
        return (String(before[start..<end]), boundary)
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'"
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
    func recordCommittedWord(_ word: String, trustCasing: Bool = true,
                             source: WordEventSource = .tap) {
        guard let store = usageStore else { return }
        store.recordWordEvent(word: word, source: source)
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

    /// Whole-word replacement around a mid-word cursor: hop past the suffix,
    /// delete the typed word, insert the replacement; the cursor lands after
    /// the corrected word (deterministic, and matching what tapping a
    /// completion feels like).
    private func midWordReplacementActions(for word: String, prefix: String, suffix: String) -> [InputAction] {
        var actions: [InputAction] = [.moveCursor(suffix.count)]
        actions.append(contentsOf: Array(repeating: .deleteBackward, count: prefix.count + suffix.count))
        actions.append(.insert(word))
        return actions
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
