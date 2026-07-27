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
    // "Your job is..." role line, short imperative rules, and one few-shot
    // example. The example plus the schema's "alternatives" framing carry
    // the two failure modes: extraction (echoing the text) and continuation
    // chains (CONSECUTIVE words instead of options for ONE word). Built per
    // request so the model generates exactly as many guesses as the bar
    // will show - decode tokens are the battery cost, so none are wasted.
    private static func makeInstructions(count: Int) -> String {
        if count == 1 {
            return """
                Your job is to predict the next word a person will type on their phone.
                The prompt is the text they have typed so far. It may end mid-sentence.
                Exactly one word comes next. Respond with your single best guess for
                that word.

                Never respond with a continuation of several words.
                Never repeat the text back. One single word, no punctuation.

                Example: for the text "I'll be there in a" the guess is minute.
                """
        }
        let exampleWords = ["minute", "few", "second", "bit", "moment"].prefix(count).joined(separator: ", ")
        return """
            Your job is to predict the next word a person will type on their phone.
            The prompt is the text they have typed so far. It may end mid-sentence.
            Exactly one word comes next. Respond with \(count) different guesses for
            that one word, most likely first.

            Every guess is a competing option for the same single position.
            Never respond with consecutive words of one sentence.
            Never repeat the text back. Single words only, no punctuation.

            Example: for the text "I'll be there in a" the \(count) guesses are
            \(exampleWords) - \(count) ways to fill the same blank.
            """
    }

    private var cache: [String: [String]] = [:]
    private var cacheOrder: [String] = []

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
            let count = max(1, KeyboardSettings.predictionWordCount)
            LanguageModelSession(instructions: Self.makeInstructions(count: count)).prewarm()
        }
        #else
        print("PredictionService: FoundationModels not present in this SDK")
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

        inflightTask = Task { @MainActor [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let session = LanguageModelSession(instructions: Self.makeInstructions(count: count))
            // The prompt is the user's text and nothing else — meta framing
            // ("the text before the cursor is...") makes the small model
            // extract words from the text instead of continuing it.
            let prompt = context
            print("PredictionService: predicting after ...\(String(context.suffix(120)))")
            let words: [String]
            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: NextWordAlternatives.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                words = response.content.alternatives
            } catch {
                // Guardrail refusal, context trouble, cancellation: nothing
                // to surface; the bar stays as it is.
                print("PredictionService: generation failed: \(error)")
                return
            }
            guard let self, self.requestToken == token else { return }

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
