//
//  PredictionService.swift
//  Keyboard
//
//  Created by Claude on 7/27/26.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
// Each continuation is a nested object, not a bare string: flat [String]
// proved fatally ambiguous to the model in both directions (a word list
// became one sentence; one sentence became a word-per-element list). An
// object with a text field can't degenerate either way.
@available(iOS 26.0, *)
@Generable
private struct Continuation {
    @Guide(description: "One possible continuation of the text: just the next few words, as a single phrase")
    var text: String
}

@available(iOS 26.0, *)
@Generable
private struct Continuations {
    @Guide(description: "The different continuations, most likely first. Each starts with a different word; exactly as many as the instructions request.")
    var continuations: [Continuation]
}
#endif

/// Empty-prefix next-word predictions from the on-device Apple foundation
/// model (Foundation Models framework, iOS 26+ on Apple Intelligence
/// devices). Strictly on-device: `SystemLanguageModel` inference runs in a
/// system process and never touches the network — Private Cloud Compute is
/// deliberately not used from a keyboard. Everything is best-effort and
/// asynchronous: when the model is unavailable the bar simply never asks.
///
/// Latency posture: results deliver only within a short freshness window
/// (never repaint under a descending finger); superseded generations are
/// cancelled (inference burns battery); and after each delivery the caller
/// optimistically prefetches the world where the user taps the top word, so
/// chained picks are cache hits. A real request arriving for a context whose
/// speculative generation is already in flight RIDES it — with the freshness
/// clock restarted at the moment of the real request, since lateness is
/// measured against the user's ask, not speculation's head start.
final class PredictionService {
    // This whole instruction apparatus is an instruction-mediated stand-in
    // for distribution access the framework doesn't expose; issue #4 tracks
    // deleting it if Apple ships a native top-k API.
    //
    // CONTINUATION framing: chat models are natively good at continuing
    // text and bad at enumerating token alternatives (the earlier framing —
    // "N guesses for one word" — produced fragments and frequency spam).
    // We ask for N short continuations, each starting differently, and take
    // the first word of each; diversity across whole continuations is a
    // shape the model can actually produce. NO example text: the 3B model
    // parrots examples verbatim (a demonstration belongs in a seeded
    // transcript turn if ever needed). Built per config so the model
    // generates exactly as many continuations as the bar needs.
    private static func makeInstructions(count: Int) -> String {
        if count == 1 {
            return """
                Continue the text the person is typing.
                Never reply to the text or answer it - write what comes next.
                Give the most natural short continuation.
                """
        }
        return """
            Continue the text the person is typing.
            Never reply to the text or answer it - write what comes next.
            Give \(count) different short continuations, most likely first.
            Each must start with a different word.
            """
    }

    private var cache: [String: [String]] = [:]
    private var cacheOrder: [String] = []

    /// The ONE retained session — the KV cache. Sessions keep their
    /// transcript prefix hot across turns, so holding one and reusing it
    /// avoids re-prefilling the instructions (and lets prior turns act as
    /// accumulated few-shot examples). Stored as Any because stored
    /// properties can't be availability-gated; each use casts under
    /// #available. Rebuilt only when the count config changes (rare), a
    /// cancelled response hasn't unwound yet, the transcript nears the
    /// context window, or a generation failed.
    private var sessionBox: Any?
    private var sessionCount = 0
    private var sessionTurns = 0

    /// Turns before the session recycles: each turn's prompt carries full
    /// document context, so transcripts fatten fast against the 4k window.
    private static let maxSessionTurns = 6

    /// Monotonic staleness token: results for anything but the newest
    /// generation are dropped.
    private var requestToken = 0
    /// The context the in-flight generation is answering, nil when idle.
    private var inflightContext: String?
    private var inflightTask: Task<Void, Never>?
    /// Delivery for the in-flight generation (nil for pure prefetches), plus
    /// when it was asked for — the freshness clock.
    private var pendingCompletion: (([String]) -> Void)?
    private var deliveryRequestedAt: CFAbsoluteTime = 0

    /// Telemetry hook, fired once per completed model serve (delivered,
    /// cached-late, or speculative) with latency in ms and word count.
    var onServe: ((Double, Int) -> Void)?

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Loads shared model resources ahead of the first query (Apple cites
    /// large first-token latency wins). Call once at keyboard launch.
    func prewarm() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let availability = SystemLanguageModel.default.availability
            print("PredictionService: availability = \(availability)")
            guard availability == .available else { return }
            session(count: max(1, KeyboardSettings.predictionWordCount)).prewarm()
        }
        #else
        print("PredictionService: FoundationModels not present in this SDK")
        #endif
    }

    /// The retained session when it's still fit for purpose, else a fresh
    /// replacement (only ever one held).
    @available(iOS 26.0, *)
    private func session(count: Int) -> LanguageModelSession {
        #if canImport(FoundationModels)
        if let existing = sessionBox as? LanguageModelSession,
           sessionCount == count,
           sessionTurns < Self.maxSessionTurns,
           !existing.isResponding {
            return existing
        }
        let fresh = LanguageModelSession(instructions: Self.makeInstructions(count: count))
        sessionBox = fresh
        sessionCount = count
        sessionTurns = 0
        return fresh
        #else
        fatalError("unreachable")
        #endif
    }

    /// Cached words for a context and count, if a completed serve is already
    /// on hand (lets callers skip their debounce for instant delivery).
    /// Count-qualified: a setting change must never serve wrong-sized results.
    func cachedWords(context: String, count: Int) -> [String]? {
        cache[Self.cacheKey(context, count)]
    }

    private static func cacheKey(_ context: String, _ count: Int) -> String {
        "\(count)#\(context)"
    }

    /// Memory-pressure hook: drops the results cache and the retained
    /// session (with its up-to-six-turn transcript of recent contexts — the
    /// largest discretionary allocation here). Everything rebuilds lazily;
    /// the next request just pays one instruction prefill again.
    func releaseMemory() {
        cancel()
        cache.removeAll()
        cacheOrder.removeAll()
        sessionBox = nil
        sessionTurns = 0
    }

    /// Stops any in-flight generation. Call whenever the bar can no longer
    /// show predictions (typing resumed, field changed).
    func cancel() {
        inflightTask?.cancel()
        inflightTask = nil
        inflightContext = nil
        pendingCompletion = nil
    }

    /// Predicts next words for the text before the cursor; the completion
    /// runs on the main actor, only for fresh, newest-request results.
    /// Cache hits answer synchronously.
    func predict(context: String, count: Int, completion: @escaping ([String]) -> Void) {
        guard isAvailable, count > 0 else { return }
        let key = Self.cacheKey(context, count)
        if let hit = cache[key] {
            completion(hit)
            return
        }
        if key == inflightContext {
            // The speculative prefetch guessed right: ride its generation
            // instead of restarting it, clock reset to this real ask.
            pendingCompletion = completion
            deliveryRequestedAt = CFAbsoluteTimeGetCurrent()
            return
        }
        start(context: context, count: count, completion: completion)
    }

    /// Optimistic prefetch: warms the cache for `context` (typically the
    /// current context plus the top suggestion) without ever delivering.
    /// Never preempts an existing generation — speculation doesn't get to
    /// cancel real work, or earlier speculation that may yet be ridden.
    func prefetch(context: String, count: Int) {
        guard isAvailable, count > 0 else { return }
        guard cache[Self.cacheKey(context, count)] == nil, inflightContext == nil else { return }
        start(context: context, count: count, completion: nil)
    }

    private func start(context: String, count: Int, completion: (([String]) -> Void)?) {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return }
        requestToken += 1
        let token = requestToken
        inflightTask?.cancel()
        let key = Self.cacheKey(context, count)
        inflightContext = key
        pendingCompletion = completion
        deliveryRequestedAt = CFAbsoluteTimeGetCurrent()

        let session = session(count: count)
        inflightTask = Task { @MainActor [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            // The prompt is the user's text and nothing else — meta framing
            // ("the text before the cursor is...") makes the small model
            // extract words from the text instead of continuing it.
            let prompt = context
            print("PredictionService: predicting after ...\(String(context.suffix(120)))")
            let words: [String]
            do {
                // Default sampling, not greedy: greedy over an unconfident
                // distribution collapses to top-frequency words and can
                // early-close strings mid-word in constrained decoding
                // ("I will " -> "wi"). Determinism was never load-bearing —
                // the cache already pins repeat contexts.
                // Token cap is a runaway backstop only: it hard-stops
                // generation, so it must be generous enough that the JSON
                // envelope always closes (60 truncated mid-string and the
                // decode failed). Per-phrase brevity comes from the schema
                // guide, not the cap.
                let response = try await session.respond(
                    to: prompt,
                    generating: Continuations.self,
                    options: GenerationOptions(maximumResponseTokens: 200)
                )
                words = response.content.continuations.map(\.text)
            } catch is CancellationError {
                // Superseded: the session survives (its transcript didn't
                // advance); the isResponding guard covers the unwind race.
                return
            } catch {
                // Guardrail refusal, context-window overflow, anything else:
                // nothing to surface, and the session is suspect — drop it so
                // the next request starts clean.
                print("PredictionService: generation failed: \(error)")
                self?.sessionBox = nil
                return
            }
            guard let self, self.requestToken == token else { return }
            self.sessionTurns += 1
            // Raw, pre-filter emission — the ground truth for decoding
            // pathologies (fragments, early string-closes, junk elements)
            // that the cleaned log line below would mask.
            print("PredictionService: raw continuations: \(words)")

            // The prediction is the FIRST WORD of each continuation, stripped
            // of surrounding punctuation, deduped across continuations.
            var seen = Set<String>()
            let wordCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "'"))
            let cleaned = words
                .compactMap { continuation -> String? in
                    guard let first = continuation
                        .split(whereSeparator: { $0.isWhitespace })
                        .first else { return nil }
                    return String(first).trimmingCharacters(in: wordCharacters.inverted)
                }
                .filter { word in
                    guard !word.isEmpty, word.count <= 24,
                          word.allSatisfy({ $0.isLetter || $0 == "'" }),
                          seen.insert(word.lowercased()).inserted else { return false }
                    return true
                }

            let elapsedMS = (CFAbsoluteTimeGetCurrent() - started) * 1000
            print("PredictionService: \(cleaned.count) words in \(String(format: "%.0f", elapsedMS))ms: \(cleaned.joined(separator: ", "))")
            self.onServe?(elapsedMS, cleaned.count)
            self.store(cleaned, for: key)

            let completion = self.pendingCompletion
            let waited = CFAbsoluteTimeGetCurrent() - self.deliveryRequestedAt
            self.inflightContext = nil
            self.inflightTask = nil
            self.pendingCompletion = nil

            // Late results never repaint the bar mid-gaze; the cache above
            // surfaces them synchronously at the next refresh instead.
            if let completion, waited <= PredictionTuning.deliveryWindow {
                completion(cleaned)
            }
        }
        #endif
    }

    private func store(_ words: [String], for context: String) {
        if cache[context] == nil {
            cacheOrder.append(context)
            if cacheOrder.count > PredictionTuning.cacheCapacity {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[context] = words
    }
}
