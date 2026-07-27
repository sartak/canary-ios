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
private struct NextWords {
    @Guide(description: "The three words most likely to be typed next, most likely first", .count(3))
    var words: [String]
}
#endif

/// Empty-prefix next-word predictions from the on-device Apple foundation
/// model (Foundation Models framework, iOS 26+ on Apple Intelligence
/// devices). Strictly on-device: `SystemLanguageModel` inference runs in a
/// system process and never touches the network — Private Cloud Compute is
/// deliberately not used from a keyboard. Everything is best-effort and
/// asynchronous: when the model is unavailable (older OS, ineligible device,
/// Apple Intelligence off, or the framework declining to run in a keyboard
/// extension) the bar simply keeps its frequency-ranked words.
final class PredictionService {
    private static let instructions = """
        You predict the next word a person will type on a phone keyboard.
        Given the text before the cursor, respond with the three words most
        likely to come next. Use plain, common words that fit the context.
        Single words only: no punctuation, no explanations.
        """

    /// Longest context suffix sent to the model; keeps prompts small and
    /// latency keystroke-friendly.
    private static let contextLimit = 240

    /// Monotonic staleness token: results for anything but the newest
    /// request are dropped, so a slow response can't repaint a newer bar.
    private var requestToken = 0
    private var cachedContext: String?
    private var cachedWords: [String] = []

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
            guard SystemLanguageModel.default.availability == .available else { return }
            LanguageModelSession(instructions: Self.instructions).prewarm()
        }
        #endif
    }

    /// Predicts next words for the text before the cursor. The completion
    /// runs on the main actor, only for the newest request; identical
    /// consecutive contexts answer synchronously from cache. A fresh session
    /// per query keeps the transcript from ever hitting the context ceiling
    /// and sidesteps the one-response-at-a-time session rule.
    /// The completion's second argument is the model latency in milliseconds,
    /// or nil for a synchronous cache hit (which shouldn't count as a serve).
    func predict(context: String, completion: @escaping ([String], Double?) -> Void) {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable else { return }
        let trimmed = String(context.suffix(Self.contextLimit))
        if trimmed == cachedContext {
            completion(cachedWords, nil)
            return
        }
        requestToken += 1
        let token = requestToken

        Task { @MainActor [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = "Text before the cursor:\n\(trimmed)\n\nThe three most likely next words:"
            let words: [String]
            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: NextWords.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                words = response.content.words
            } catch {
                // Guardrail refusal, context trouble, cancellation: the bar
                // keeps its frequency words; nothing to surface.
                return
            }
            guard let self, self.requestToken == token else { return }
            let latencyMS = (CFAbsoluteTimeGetCurrent() - started) * 1000

            var seen = Set<String>()
            let cleaned = words
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { word in
                    guard !word.isEmpty, word.count <= 24,
                          word.allSatisfy({ $0.isLetter || $0 == "'" }),
                          seen.insert(word.lowercased()).inserted else { return false }
                    return true
                }
            self.cachedContext = trimmed
            self.cachedWords = cleaned
            completion(cleaned, latencyMS)
        }
        #endif
    }
}
