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
@available(iOS 26.0, *)
@Generable
private struct NextWordAlternatives {
    @Guide(description: "Different guesses for the same single next word - competing options for one position, never consecutive words of a phrase. Most likely guess first; exactly as many guesses as the instructions request.")
    var alternatives: [String]
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
    // Apple's instruction house style (Foundation Models code-along): a
    // "Your job is..." role line and short imperative rules. NO example —
    // the 3B model parroted the example words verbatim as its answer for
    // every input (logs: "What " -> minute, few, second), and the retained
    // session then reinforced its own parroting from the transcript. If
    // quality needs a demonstration, the right form is a seeded transcript
    // turn, never example text in the instructions. Built per config so the
    // model generates exactly as many guesses as the bar will show.
    private static func makeInstructions(count: Int) -> String {
        if count == 1 {
            return """
                Your job is to predict the next word a person will type on their phone.
                The prompt is the text they have typed so far. It may end mid-sentence.
                Exactly one word comes next. Respond with your single best guess for
                that word.

                Never respond with a continuation of several words.
                Never repeat the text back. One single word, no punctuation.
                """
        }
        return """
            Your job is to predict the next word a person will type on their phone.
            The prompt is the text they have typed so far. It may end mid-sentence.
            Exactly one word comes next. Respond with \(count) different guesses for
            that one word, most likely first.

            Every guess is a competing option for the same single position.
            Never respond with consecutive words of one sentence.
            Never repeat the text back. Single words only, no punctuation.
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
                let response = try await session.respond(
                    to: prompt,
                    generating: NextWordAlternatives.self
                )
                words = response.content.alternatives
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
            print("PredictionService: raw response: \(words)")

            var seen = Set<String>()
            let cleaned = words
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
