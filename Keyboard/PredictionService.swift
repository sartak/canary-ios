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

/// Every tunable constant for foundation-model predictions, in one place
/// (mirrors SwipeTuning's doc style). Expect these to move as real-world
/// latency and taste data comes in.
enum PredictionTuning {
    /// Longest context suffix sent to the model; keeps prompts small and
    /// latency keystroke-friendly.
    static let contextLimit = 240

    /// Results delivered later than this after they were asked for are
    /// cached but not shown; they surface at the next natural refresh.
    static let deliveryWindow: TimeInterval = 0.5

    /// Recent context → words cache slots. More than one so speculative
    /// prefetches can't evict the context currently on screen.
    static let cacheCapacity = 8

    /// After a swipe commits, how long until inference starts for the
    /// correction-to-prediction handoff (the model's head start).
    static let swipeInferenceDelay: TimeInterval = 0.5

    /// After a swipe commits, how long the correction candidates own the
    /// bar before predictions replace them.
    static let swipeHandoffDelay: TimeInterval = 1.0
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
private struct NextWords {
    @Guide(description: "The five words most likely to be typed next, most likely first", .count(5))
    var words: [String]
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
    private static let instructions = """
        You predict the next word a person will type on a phone keyboard.
        Given the text before the cursor, respond with the five words most
        likely to come next, most likely first. Use plain, common words that
        fit the context. Single words only: no punctuation, no explanations.
        """

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
            LanguageModelSession(instructions: Self.instructions).prewarm()
        }
        #else
        print("PredictionService: FoundationModels not present in this SDK")
        #endif
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
    func predict(context: String, completion: @escaping ([String]) -> Void) {
        guard isAvailable else { return }
        let trimmed = String(context.suffix(PredictionTuning.contextLimit))
        if let hit = cache[trimmed] {
            completion(hit)
            return
        }
        if trimmed == inflightContext {
            // The speculative prefetch guessed right: ride its generation
            // instead of restarting it, clock reset to this real ask.
            pendingCompletion = completion
            deliveryRequestedAt = CFAbsoluteTimeGetCurrent()
            return
        }
        start(context: trimmed, completion: completion)
    }

    /// Optimistic prefetch: warms the cache for `context` (typically the
    /// current context plus the top suggestion) without ever delivering.
    /// Never preempts an existing generation — speculation doesn't get to
    /// cancel real work, or earlier speculation that may yet be ridden.
    func prefetch(context: String) {
        guard isAvailable else { return }
        let trimmed = String(context.suffix(PredictionTuning.contextLimit))
        guard cache[trimmed] == nil, inflightContext == nil else { return }
        start(context: trimmed, completion: nil)
    }

    private func start(context: String, completion: (([String]) -> Void)?) {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return }
        requestToken += 1
        let token = requestToken
        inflightTask?.cancel()
        inflightContext = context
        pendingCompletion = completion
        deliveryRequestedAt = CFAbsoluteTimeGetCurrent()

        inflightTask = Task { @MainActor [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = "Text before the cursor:\n\(context)\n\nThe five most likely next words:"
            let words: [String]
            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: NextWords.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                words = response.content.words
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
            self.store(cleaned, for: context)

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
