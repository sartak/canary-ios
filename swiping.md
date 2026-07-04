# Swipe Typing v2: Template Matching

This document is the complete design and implementation plan for replacing Canary's
swipe-typing decoder with a SHARK2-style template matcher. It is self-contained:
it describes the current implementation, why it fails, the replacement algorithm
(including the math), integration points, tuning, testing, and a milestone-by-milestone
build order.

Primary reference: Kristensson & Zhai, *SHARK2: A Large Vocabulary Shorthand Writing
System for Pen-based Computers*, UIST 2004. This is the algorithm that shipped as
ShapeWriter and inspired Swype. We adopt its two-channel (shape + location) scoring
and its pruning strategy; exact constants are ours to tune.

---

## 1. The current implementation and why it demands too much precision

### 1.1 Pipeline today

1. **Gesture capture** — `MultiTouchKeyboardGestureRecognizer` records the touch path
   (`touchPaths`, one `(point, time)` per touch-move). A drag becomes a swipe once
   straight-line displacement exceeds `swipeDistanceThreshold` (0.75 key widths,
   `DeviceLayout.swift:111`).
2. **Path → key sequence** — `appendKeyToSequenceIfNew`
   (`MultiTouchKeyboardGestureRecognizer.swift:354`) hit-tests each path point against
   key hitboxes and appends a `SwipeKey` whenever the path enters a different key.
   The first key is `.required`; later keys are `.optional`.
3. **Corner promotion** — when the path turns ≥60° at a key
   (`angleChangeThreshold`, line 48), that key is promoted to `.required`.
   On touch-up the last key is also promoted (`finalizeSwipeKeySequence`, line 397).
4. **Key sequence → SQL** — `SwipeService.buildPattern` (`SwipeService.swift:71`)
   throws away every optional key and joins the required letters into a `LIKE`
   pattern: required s, w, e → `s%w%e`.
5. **Lookup & ranking** — `SELECT word FROM words WHERE word_lower LIKE ? ORDER BY
   frequency_rank LIMIT 10` (`SwipeService.swift:36-40`). The best word is `.first`.

### 1.2 The structural problems

- **Hard filtering, no scoring.** A word either matches the `LIKE` pattern or it is
  gone. If any required letter is wrong — start, end, or any ≥60° corner — the
  intended word is *excluded from the candidate set entirely*. There is no notion of
  "close"; frequency is the only ranking signal among survivors.
- **Hard hit-testing.** `key(at:)` (`KeyboardTouchView.swift:185`) uses hitbox
  containment with no nearest-key fallback. A path segment that grazes the gap
  between keys contributes nothing.
- **Early, binary decisions on noisy data.** Corner detection with a fixed 60°
  threshold on raw finger input decides which letters are load-bearing before the
  gesture is even complete. Smooth corners (arcs), overshoot, and wobble all
  misclassify.
- **Information thrown away.** The actual path geometry — the thing the user
  carefully produced — is discarded after being quantized to a letter list.
- **Unindexable query.** `LIKE 's%w%e'` with mid-pattern wildcards cannot use an
  index; every swipe scans the 89k-row `words` table.
- **Bug: hidden words are not excluded.** The swipe query has no `hidden = 0`
  filter, unlike other suggestion paths.

The fix in one sentence: **defer all decisions to the end, keep the whole path, and
*score* every candidate word against it instead of filtering.**

---

## 2. Goals and non-goals

### Goals

- Sloppy-but-recognizable swipes decode to the intended word. Precision affects
  ranking, never eligibility (within a generous pruning radius).
- Deterministic, pure-function decoding: `(path, key centers, lexicon) → ranked
  candidates`. Unit-testable without UIKit, without a device, without SQLite.
- Works with both layouts (`.canary`, `.qwerty`) and any device geometry, because
  templates are generated at runtime from the actual key centers on screen —
  nothing geometric is precomputed into the corpus.
- Preserve the existing UX: live suggestions while swiping, commit on touch-up,
  tap-to-replace suggestions after.
- Keep the SQLite-backed lexicon; fix the query to be indexable.

### Non-goals (explicitly deferred)

- Probabilistic incremental decoding (beam search over a trie, Gboard-style). The
  scoring machinery built here is the emission model that design would need, so
  nothing is wasted if we go there later — but it requires real usage data to tune,
  which we don't have yet.
- Personalization / learned vocabulary (PLAN.md Milestone 9). The decoder reads
  from the lexicon abstraction; when learned words land, they join the candidate
  pool with no decoder changes.
- Distinguishing double letters ("to" vs "too") geometrically. Their swipe paths
  are identical; the language-model prior picks the more frequent one and the
  suggestion bar offers the other. Loop/dwell detection is future work.

---

## 3. Algorithm overview

For every candidate word we can compute its **ideal template**: the polyline through
the centers of its letters' keys, in the same coordinate space as the user's path.
Decoding is then:

```
user path ──resample──► U (N points)
                                      ┌─ shape distance  x_s ─┐
for each candidate word w:            │                       ├─► score(w) ─► rank
  template(w) ──resample──► T_w ──────┴─ location distance x_l┘      ▲
                                                                     │
lexicon prior P(w) ──────────────────────────────────────────────────┘
```

- **Pruning** limits "each candidate word" to a few hundred: only words whose first
  letter's key center is near the path's start and whose last letter's key center is
  near the path's end.
- **Shape channel** compares the *normalized* shapes (translation/scale invariant):
  did the user draw the right pattern, even if drifted or shrunken?
- **Location channel** compares the paths in absolute keyboard coordinates: was the
  gesture in the right place?
- **Integration**: each channel distance converts to a likelihood via a Gaussian;
  multiply likelihoods with the word prior; rank by the product.

Every stage is a total, deterministic function. When decoding picks the wrong word,
debugging is: print `(x_s, x_l, prior, score)` for the expected word and the winner,
and look at which term lost.

---

## 4. Detailed design

All new code lives in the `Keyboard/` directory as new files. Everything below
`SwipeDecoder` depends only on `Foundation` + `CoreGraphics` (no UIKit) so it can be
tested off-device.

### 4.1 New components

| Component | File | Responsibility |
|---|---|---|
| `PathGeometry` | `Keyboard/PathGeometry.swift` | Pure geometry: arc length, resampling, bounding box, centroid, normalization |
| `SwipeTemplate` | `Keyboard/SwipeTemplate.swift` | word + key centers → resampled template polyline; per-layout template cache |
| `SwipeLexicon` | `Keyboard/SwipeLexicon.swift` | SQLite candidate retrieval by (first letters, last letters), frequency-ranked |
| `SwipeDecoder` | `Keyboard/SwipeDecoder.swift` | Pruning + two-channel scoring + prior integration → ranked candidates |
| `SwipeTuning` | `Keyboard/SwipeTuning.swift` | Every tunable constant in one struct, documented |

`SwipeService.swift` and the `SwipeKey` type are deleted at the end (§4.9).

### 4.2 Geometry primitives (`PathGeometry`)

```swift
enum PathGeometry {
    /// Total arc length of a polyline.
    static func arcLength(_ points: [CGPoint]) -> CGFloat

    /// Resample a polyline to `count` points spaced equally by arc length.
    /// Precondition: points.count >= 1. A single point repeats `count` times.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint]

    /// Truncate a polyline at the given arc length (walks segments, interpolates
    /// the final point). Used for live partial-path matching (§4.7).
    static func truncated(_ points: [CGPoint], atArcLength length: CGFloat) -> [CGPoint]

    /// Translate centroid to origin and scale so the longer bounding-box side
    /// equals `size`, preserving aspect ratio. Degenerate boxes (max side < ε)
    /// translate only.
    static func normalized(_ points: [CGPoint], toSize size: CGFloat) -> [CGPoint]

    /// Mean pointwise Euclidean distance between two equal-length point arrays.
    static func meanPointwiseDistance(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat

    /// Weighted pointwise distance: Σ αᵢ·‖aᵢ−bᵢ‖ with Σαᵢ = 1.
    static func weightedPointwiseDistance(_ a: [CGPoint], _ b: [CGPoint],
                                          weights: [CGFloat]) -> CGFloat
}
```

Resampling detail (this is the classic $1-recognizer / SHARK2 approach): walk the
polyline accumulating segment lengths; emit a point every `arcLength / (count - 1)`;
linear-interpolate within segments. This is the single most important primitive —
it aligns user path and template point-by-point so all "distance" computations are
simple pointwise sums, with no dynamic alignment (that's the complexity we are
deliberately avoiding).

`N = SwipeTuning.resampleCount = 64` points. (SHARK2 used ~100 for pen input;
64 is plenty at keyboard scale and keeps the inner loop cheap.)

### 4.3 Template generation (`SwipeTemplate`)

Input: a word and the current layout's key centers.

```swift
struct KeyCenters {
    /// Lowercased character → center of its key, in KeyboardTouchView coordinates.
    /// Built from KeyData.viewFrame midpoints for the alpha layer.
    let centers: [Character: CGPoint]
}

struct SwipeTemplate {
    let word: String            // original cased word from the lexicon
    let points: [CGPoint]       // resampled to N, keyboard coordinates
    let idealArcLength: CGFloat // arc length of the raw (unresampled) polyline
}
```

Construction rules, in order:

1. Lowercase the word and keep only characters that have a key center on the alpha
   layer. Apostrophes and any other unmapped characters are dropped: "don't" and
   "dont" produce the same template (both stay in the lexicon as distinct words —
   the prior and the suggestion bar disambiguate).
2. Collapse *consecutive duplicate keys*: "hello" → h,e,l,o. A swipe cannot express
   a doubled letter, so the template must not contain zero-length segments.
3. If fewer than 2 distinct points remain (e.g. single-letter words, or all letters
   on one key), the word is **not swipe-decodable** — it never enters the candidate
   pool. (Single letters are typed by tap; the swipe-start displacement threshold
   already guarantees real swipes span ≥ 0.75 key widths.)
4. The polyline through the surviving key centers is resampled to N points.

Templates depend on layout geometry, which is only known at runtime and changes on
rotation/layout switch. Therefore:

- **No precomputation in the corpus DB.** `build_corpus.py` stays geometry-free.
- Templates are built lazily per candidate at decode time and memoized in an
  in-memory cache keyed by word, invalidated whenever key frames change (rotation,
  layout switch — hook the same path that calls `updateKeyHitboxes`). Building a
  template is ~word-length point ops plus a 64-point resample; even cold, a few
  hundred templates per decode is well under a millisecond in aggregate (§6).

### 4.4 Candidate pruning (`SwipeLexicon`)

Scoring is cheap but not free; we bound the candidate pool before scoring.

**Spatial pruning (SHARK2's start/end pruning):**

- Let `s` = first point of the user path, `e` = last point.
- `startLetters` = all letters whose key center is within `SwipeTuning.pruneRadius`
  of `s`; `endLetters` = same for `e`.
- `pruneRadius` default: **1.6 × (alphaKeyWidth + horizontalGap)** — deliberately
  generous (≈ the key and its full ring of neighbors). The user's complaint is
  precision; pruning exists for speed, not accuracy, so it must be loose. It is the
  *only* hard cut in the whole design, and at 1.6 key-pitches a miss means the
  finger started more than one and a half keys away from every key of the intended
  letter — at that point no decoder can help.

**Lexicon query:**

Schema change in `build_corpus.py` (`create_database_tables`, ~line 137): add to
`words`:

```sql
first_char TEXT NOT NULL,   -- first letter of the letters-only lowercased word
last_char  TEXT NOT NULL,   -- last  letter of same
distinct_key_count INTEGER NOT NULL,  -- after consecutive-dup collapse; 0/1 ⇒ not swipeable
```

with a covering index:

```sql
CREATE INDEX idx_words_swipe
ON words (first_char, last_char, frequency_rank, word, hidden, distinct_key_count);
```

The letters-only form strips apostrophes (matching §4.3 rule 1), so `first_char`/
`last_char` agree with the template's endpoints.

Swift-side query (prepared once, like the existing services):

```sql
SELECT word, frequency_rank FROM words
WHERE first_char IN (…startLetters…)
  AND last_char  IN (…endLetters…)
  AND hidden = 0
  AND distinct_key_count >= 2
ORDER BY frequency_rank
LIMIT ?     -- SwipeTuning.maxCandidates, default 1500
```

(`IN` lists are small — typically 3–7 letters each; bind them into a statement
prepared with the maximum plausible list sizes, or build the statement per-query;
either is fine at one query per swipe. Measure, keep the simpler one.)

`maxCandidates = 1500` is a speed guard, not an accuracy knob: candidates are
frequency-ordered, so anything cut at 1500 is deep-tail vocabulary. Log when the
limit is actually hit so we know if it ever matters in practice.

**Length pruning (in Swift, after fetch, before scoring):**

Reject candidates whose ideal template arc length is wildly different from the user
path's arc length:

```
1 / lengthRatioLimit ≤ userArcLength / template.idealArcLength ≤ lengthRatioLimit
```

with `lengthRatioLimit` default **2.2** (generous: users cut corners, so real paths
run shorter than ideal polylines; overshoot runs longer). This cheaply kills e.g.
3-key words against a path that visited 9 keys, without any letter-level decisions.

### 4.5 Scoring (`SwipeDecoder`) — the core

Let `U` = user path resampled to N points, `T` = candidate template (already
resampled). All distances are computed in **key-pitch units** — divide by
`(alphaKeyWidth + horizontalGap)` — so every tuning constant is device-independent.

**Shape channel** (translation/scale invariant — "did they draw the right pattern"):

```
U' = normalized(U, toSize: 1.0)      // centroid at origin, long side = 1
T' = normalized(T, toSize: 1.0)
x_s = meanPointwiseDistance(U', T')                    // dimensionless
```

**Location channel** (absolute position — "was it in the right place"):

```
x_l = Σᵢ αᵢ · ‖Uᵢ − Tᵢ‖ / keyPitch
```

where the weights `αᵢ` emphasize endpoints (users are most deliberate at the start
and end of a swipe; mid-gesture corner-cutting is normal and should be cheap):

```
αᵢ = lerp(1.0, 0.4, min(i, N−1−i) / (N/2))   then normalize so Σαᵢ = 1
```

i.e. weight 1.0 at both ends falling linearly to 0.4 at the middle. (SHARK2 §4.2
uses the same idea; the exact ramp is a tunable, `SwipeTuning.midPathWeight`.)

**Channel → likelihood → posterior:**

```
score(w) = exp(−x_s² / (2σ_s²)) · exp(−x_l² / (2σ_l²)) · P(w)^γ
```

- `σ_s` default **0.35** (shape distances are in normalized-box units; a clean
  trace of the right word lands around 0.1–0.2, a wrong-but-similar word 0.4+.
  Validated by the synthetic harness in §8.3 before shipping.)
- `σ_l` default **0.8** key-pitches (a whole-key parallel drift costs ~1.0; this
  keeps such a swipe alive but penalized).
- `P(w)`: Zipf approximation from the existing `frequency_rank`
  (`P(w) ∝ 1 / rank`, normalized by the harmonic number H₈₉₄₀₄ ≈ 12.0). No schema
  change needed; if we later want true counts, `corpus/word_frequencies.txt`
  already has them and this is a one-column addition.
- `γ` default **0.2**: the LM-vs-geometry balance. γ=1 lets frequency steamroll
  geometry (the current design's failure mode, inverted); γ=0 ignores frequency.
  This is the single most user-feelable knob; the harness (§8.3) picks the default,
  the debug overlay (§8.4) sanity-checks it on-device. (Initially shipped at 0.4;
  on-device testing showed common words overmatching — a 500× rank advantage was
  worth ~2.5 log units, more than accurate tracing could recover.)

Work in log space to avoid underflow:

```
logScore(w) = −x_s²/(2σ_s²) − x_l²/(2σ_l²) + γ·log P(w)
```

**Confidence gate:** if the best candidate's `x_s` and `x_l` are both beyond
`SwipeTuning.rejectionDistance` (default: `x_s > 0.9` **and** `x_l > 2.5`), return
no result — inserting a wildly wrong word is worse than inserting nothing. (The
current implementation's equivalent is an empty LIKE result.)

**Output:**

```swift
struct SwipeCandidate {
    let word: String
    let logScore: Double
    let shapeDistance: CGFloat     // exposed for debug overlay + tests
    let locationDistance: CGFloat
}

struct SwipeDecoder {
    /// Pure function. `path` in KeyboardTouchView coordinates.
    func decode(path: [CGPoint],
                keyCenters: KeyCenters,
                keyPitch: CGFloat,
                limit: Int = 10) -> [SwipeCandidate]
}
```

`decode` sorted-descending-by-logScore replaces all three of
`SwipeService.decode` / `candidates` / `finalCandidates`.

### 4.6 What replaces `SwipeKey` in the gesture recognizer

The gesture recognizer keeps: path recording (`touchPaths`), swipe-start detection
(displacement threshold), the drawn tapered path, and the fade-out animation.
It loses: `swipeKeySequence`, `swipeKeyPositions`, `appendKeyToSequenceIfNew`,
`initializeSwipeKeySequence`, `finalizeSwipeKeySequence`, `angleChangeThreshold`,
and `setSwipeKeySequence`.

Callback changes:

```swift
// removed:
var onSwipeKeySequenceChanged: (([SwipeKey]) -> Void)?
var onSwipeEnded: (([SwipeKey], [CGPoint]) -> Void)?
// added:
var onSwipeProgressed: (([CGPoint]) -> Void)?   // throttled, see §4.7
var onSwipeEnded: (([CGPoint]) -> Void)?        // full path, touch-down to touch-up
```

Note the path already includes the pre-threshold points (recorded from
`touchesBegan`), so the decoder sees the true start of the gesture — better than
today, where the sequence is replayed only once the threshold trips.

The mid-swipe **hitbox biasing** (`swipeFrequencies` →
`distributionForSwipeContext` → `updateKeyHitboxes` in the
`onSwipeKeySequenceChanged` handler, `KeyboardViewController.swift:180-189`) is
deleted: the decoder never hit-tests, so reshaping hitboxes during a swipe no
longer does anything for decoding. (Tap-time predictive hitboxes are untouched.)
`FrequencyService.distributionForSwipeContext` becomes dead code — remove it.

### 4.7 Live suggestions during the swipe

Today, live suggestions re-query on every new key crossed. The replacement: score
the **partial path** against **arc-length-truncated templates**.

On each (throttled) `onSwipeProgressed`:

1. Prune by start point only (`first_char IN startLetters AND hidden = 0 AND
   distinct_key_count >= 2`), `LIMIT SwipeTuning.liveCandidates = 300` by frequency.
2. For each candidate, truncate its raw template polyline to the user path's current
   arc length: `PathGeometry.truncated(templatePolyline, atArcLength: userLen)`.
   Skip candidates whose full ideal length is less than `userLen / lengthRatioLimit`
   (the swipe has already gone on too long for this word).
3. Resample both to N and score exactly as §4.5 (same code path — the scorer doesn't
   know it's looking at a prefix).
4. Top 3–4 by score → suggestion bar, via the existing
   `SuggestionService`/`suggestionView` plumbing.

Throttling: at most one live decode per `SwipeTuning.liveDecodeInterval = 60 ms`,
skipping intermediate points (the path array is always read fresh). 300 candidates
× (truncate + resample + 2 channels) is comfortably under a frame (§6); the
interval is a safety margin for older devices, not a hard requirement.

Live mode uses a reduced location weight for the *endpoint* (the user hasn't
committed to an end yet, so the final resampled points shouldn't be
endpoint-weighted): reuse the α ramp but flat-cap the tail at the mid-path weight.
One boolean parameter on the scorer (`endpointCommitted: Bool`).

### 4.8 Integration (`SuggestionService`, `KeyboardViewController`)

`SuggestionService` keeps its role (capitalization + `InputAction` assembly) with
signature changes only:

```swift
// SwipeKey-based                            →  path-based
decodeSwipe(keySequence:shiftState:)         →  decodeSwipe(path:shiftState:)
swipeSuggestions(keySequence:shiftState:)    →  liveSwipeSuggestions(path:shiftState:)
swipeReplacements(keySequence:shiftState:replaceLength:)
                                             →  swipeReplacements(path:shiftState:replaceLength:)
swipeFrequencies(keySequence:)               →  (deleted)
```

Internally these call `SwipeDecoder` instead of `SwipeService`. The decoder needs
`KeyCenters` + `keyPitch`; `KeyboardViewController` owns both (it builds `KeyData`
and `DeviceLayout`) and passes them down — either per-call or via a
`updateGeometry(keyCenters:keyPitch:)` setter invoked from `rebuildKeyboard()` /
rotation. Per-call is more honest (no hidden state); start there.

`handleSwipeEnded` (`KeyboardViewController.swift:654`) keeps its flow — decode,
`executeActions`, `autoShift`, then `swipeReplacements` for tap-to-replace — with
the path in place of the key sequence. A single decode on touch-up should return
the full ranked list so commit + replacements come from **one** decoder call, not
two (today it queries twice; the decode/replacements consistency bug class from
commit `f2c39e0` disappears structurally).

Debug visualization (`setDebugSwipePath`, debug mode from commits `327f40c`,
`e58959a`) is extended, not replaced (§8.4).

### 4.9 Deletions (final cleanup, separate structural commit)

- `SwipeService.swift` (entire file, `SwipeKey` included)
- Corner-promotion machinery in `MultiTouchKeyboardGestureRecognizer` (§4.6 list)
- `FrequencyService.distributionForSwipeContext` and the `swipeFrequencies` bridge
- `lastSwipeKeySequence` debug state in `KeyboardViewController` (path is enough;
  the debug overlay now draws templates instead of required/optional letters)

---

## 5. Tuning constants — single source of truth

```swift
struct SwipeTuning {
    static let resampleCount = 64            // N; points per resampled polyline
    static let pruneRadius: CGFloat = 1.6    // × keyPitch; start/end candidate radius
    static let maxCandidates = 1500          // SQL LIMIT, final decode
    static let liveCandidates = 300          // SQL LIMIT, mid-swipe decode
    static let lengthRatioLimit: CGFloat = 2.2
    static let sigmaShape: CGFloat = 0.35    // normalized-box units
    static let sigmaLocation: CGFloat = 0.8  // key-pitch units
    static let lmWeight: Double = 0.2        // γ
    static let midPathWeight: CGFloat = 0.4  // α at path middle (ends are 1.0)
    static let rejectShape: CGFloat = 0.9    // gate: BOTH must exceed to reject
    static let rejectLocation: CGFloat = 2.5
    static let liveDecodeInterval: TimeInterval = 0.060
}
```

Ten knobs, each with a physical meaning and a documented unit, all validated by the
synthetic harness (§8.3) rather than by feel. Compare: the current design's knobs
(60° corner threshold, hitbox shapes, bigram-biased hitbox growth) interact with
touch noise in ways that can't be tested off-device at all.

---

## 6. Performance and memory budget

Per final decode (worst case, generous estimates):

| Stage | Cost |
|---|---|
| SQL candidate fetch (indexed, ≤1500 rows) | ~1 ms |
| Template build (cold) ≤1500 × (polyline + resample-64) | ~1–2 ms |
| Scoring: 1500 × 2 channels × 64 points | ~0.5–1 ms |
| **Total** | **< 5 ms** on any supported device |

Live decode: 300 candidates, same math ⇒ well under 2 ms, every 60 ms.

Memory: template cache worst case = every candidate ever scored in a session.
64 points × 8 bytes × 2 + overhead ≈ ~1.2 KB/word ⇒ 5k cached words ≈ 6 MB. Cap the
cache at `10_000` entries with wholesale eviction (clear on layout change anyway);
keyboard extensions live under a tight jetsam ceiling (tens of MB) and PLAN.md
already lists memory-pressure response — clearing this cache is that hook's first
customer. No new persistent storage; the DB grows by two TEXT columns + one INTEGER
+ one index (~a few MB on disk, not resident).

Keep the existing `print` timing-log style (`SwipeService.swift:110` pattern) on the
decode path: `SwipeDecoder: 'their' beat 'there' by 0.42 (1391 candidates) in 3.1ms`.

---

## 7. Edge cases (each becomes a test)

| Case | Behavior |
|---|---|
| Path shorter than 2 points / zero arc length | No decode (can't happen post-threshold, but the pure function must not crash) |
| Straight-line swipe (bbox height ≈ 0), e.g. "we", "were" on qwerty | Normalization guard: scale by long side only; shape channel still valid |
| Word with apostrophe ("don't") | Template = letters only; candidate keeps its cased/apostrophized form for insertion |
| Word with characters absent from layout | Unmapped chars dropped; if < 2 distinct keys remain, excluded via `distinct_key_count` |
| Double letters ("too", "hello") | Consecutive dups collapse in template; prior + suggestion bar disambiguate "to"/"too" |
| All candidates rejected by gate | Insert nothing (match current no-match behavior); path fades normally |
| Hidden words | Excluded by `hidden = 0` (fixes an existing gap) |
| Same word, different case in lexicon ("us" / "US") | Both survive pruning; identical geometry ⇒ prior decides; both appear in replacements |
| Rotation / layout switch mid-session | Template cache invalidated with key frames; next decode rebuilds lazily |
| Layout split (`splitWidth`, Canary layout) | Nothing special — templates use real key centers, the split is just geometry |
| QWERTY vs Canary layout | Same — `KeyCenters` is built from live `KeyData` |

---

## 8. Testing strategy

Test infrastructure note: `CanaryTests` currently contains one empty example test
and `@testable import Canary` — keyboard-extension sources aren't test-target
members. First structural step: add the new decoder files (`PathGeometry`,
`SwipeTemplate`, `SwipeLexicon`, `SwipeDecoder`, `SwipeTuning`) to **both** the
`Keyboard` target and `CanaryTests` target membership. They are UIKit-free by
design, so they compile in the test target without the extension environment.
(A shared framework target is the cleaner long-term shape but is over-engineering
for five files; revisit if a third target ever needs them.)

Development follows the house rules: red → green → refactor, one behavior per test,
structural commits separated from behavioral ones, format → lint → test → commit
after each change.

### 8.1 Unit tests (pure functions, hand-computable values)

- `PathGeometry.resample`: point counts, endpoint preservation, equal spacing on a
  known L-shape; single-point and two-point degenerate inputs.
- `PathGeometry.truncated`: exact interpolation at a segment boundary and mid-segment.
- `normalized`: centroid at origin; long side = 1; aspect preserved; flat-line guard.
- `SwipeTemplate`: "hello" collapses the double-l; "don't" drops the apostrophe;
  "a"/"aa" excluded; unmapped characters dropped.
- Scoring identities: `decode` on a word's own ideal template returns that word's
  `x_s ≈ 0, x_l ≈ 0`; symmetric inputs give symmetric scores; α weights sum to 1.
- Confidence gate: garbage path (e.g. a circle over the space bar) returns empty.

### 8.2 Lexicon tests (fixture DB)

Build a tiny fixture `words.db` (a dozen hand-picked words incl. one hidden, one
apostrophized, one single-letter) with the real `build_corpus.py` schema — a small
Python fixture script under `bin/`, run as part of test setup, so schema drift
breaks tests instead of production. Assert pruning by first/last sets, hidden
exclusion, `distinct_key_count` exclusion, frequency ordering, LIMIT.

### 8.3 Synthetic accuracy harness — this is how we tune before we have users

A test-target harness that (a) builds `KeyCenters` from a hardcoded iPhone-16-Pro
qwerty geometry, (b) generates noisy synthetic swipes for a word list, (c) reports
top-1 / top-3 accuracy.

Noise model per generated swipe (all magnitudes in key-pitch units):

- Gaussian jitter on every path point (σ = 0.15, 0.3, 0.5 — three difficulty tiers)
- Corner cutting: replace each interior vertex with a quadratic-Bézier arc of random
  radius up to 0.8
- Start/end offset: uniform within 0.5 of the true key center
- Resample to a realistic point count (~30–120 points) before feeding the decoder

Word set: top 1000 words by frequency + 200 random mid-tail words + a curated
confusion list ("there/their", "to/too", "hat/gat/hay", "was/wad", "on/in").

Acceptance targets before wiring into the UI (M6): **top-1 ≥ 90%, top-3 ≥ 97%** at
the σ=0.3 tier on the top-1000 set. (SHARK2 reported ~97% top-1 in comparable
conditions; we have a weaker prior, so demand a bit less and let real-use tuning
close the gap.) The harness is also the tuning loop: grid-search `σ_s, σ_l, γ`
against it and check the defaults in §5; record the chosen grid results in a
comment in `SwipeTuning`.

This harness is explicitly *not* proof of real-world accuracy — synthetic noise is
not human noise. It is a regression net and a tuning rig; real-world truth comes
from §9.

### 8.4 On-device debug support

Extend the existing debug visualization (commits `327f40c`, `e58959a`): after each
swipe, overlay the top-3 candidates' template polylines (color-coded) on the drawn
path, annotated with `(word, x_s, x_l, logScore)`. When a swipe decodes wrongly on
device, one screenshot shows which channel misjudged — this replaces the current
required/optional letter display in debug mode.

### 8.5 Manual acceptance script

A short checklist run on-device before declaring M6 done: 20 common words swiped
casually (not carefully), 5 deliberately sloppy (drift a full key row on the middle
of the word), "there"→check bar contains "their", "to"→check bar contains "too",
one garbage scribble → nothing inserted, rotate mid-session → next swipe fine,
switch Canary↔qwerty → next swipe fine, symbol layer → swipe disabled (existing
`swipeEnabled` gate, commit `30f6198`, untouched).

---

## 9. Feedback loop (ties into PLAN.md Milestone 9)

PLAN.md line 112 already calls for: *"Track swipe accuracy based on whether word was
corrected, for fine-tuning."* This design makes that actionable:

- When a swiped word is immediately replaced via the suggestion bar or retyped,
  log (locally) the path, the committed word, and the corrected word.
- Each logged triple is a labeled example: the corrected word *should* have won.
  Re-run the tuning grid (§8.3) against real examples instead of synthetic ones.
- This same dataset is the prerequisite for ever moving to incremental
  probabilistic decoding (the deferred design C) — collect it from day one.

Implementation of the logging is Milestone 9 scope, not this plan's; the decoder's
pure-function shape (path in, ranked list out) is what makes replay possible at all.

---

## 10. Milestones

Each milestone lands as one or more commits following red → green → refactor, with
structural changes (file moves, target membership, renames) in separate commits
from behavioral ones. Formatter → linter → tests → commit after every change.

**M0 — Test target plumbing** *(structural)*
Add new (empty) decoder files to `Keyboard` + `CanaryTests` targets; delete the
placeholder example test; prove a trivial decoder-file test runs.

**M1 — `PathGeometry`** *(behavioral)*
arcLength → resample → truncated → normalized → distances, one test-first function
at a time. No dependencies; pure CoreGraphics.

**M2 — `SwipeTemplate` + `KeyCenters`** *(behavioral)*
Construction rules of §4.3 with tests. Cache is a plain dictionary + invalidation
method; capacity cap.

**M3 — Corpus schema + `SwipeLexicon`** *(behavioral; DB rebuild)*
`build_corpus.py` columns/index (§4.4) + fixture-DB script + `SwipeLexicon` with
tests. Rebuild the bundled `words.db`. Existing services are unaffected by additive
columns — verify typeahead/autocorrect tests (or manual smoke) still pass.

**M4 — `SwipeDecoder` scoring** *(behavioral)*
Two channels, prior, gate, ranked output (§4.5) with unit tests including the
scoring identities and the edge-case table (§7).

**M5 — Synthetic harness + tuning** *(behavioral, test-target only)*
Build §8.3, grid-search the constants, commit tuned defaults with the grid results
recorded. Gate: accuracy targets met.

**M6 — Wire-up: final decode on touch-up** *(behavioral)*
Gesture-recognizer callback change (§4.6), `SuggestionService` path-based API
(§4.8), `handleSwipeEnded` single-decode flow, debug overlay (§8.4). Old `SwipeKey`
pipeline still present but unreferenced. Gate: manual script §8.5.

**M7 — Live suggestions** *(behavioral)*
`onSwipeProgressed` + truncated-template scoring (§4.7) with the throttle;
`endpointCommitted` weighting. Suggestion bar updates mid-swipe as today.

**M8 — Deletions** *(structural)*
Everything in §4.9. The codebase now has no `SwipeKey`, no corner threshold, no
LIKE-pattern matching, no swipe-time hitbox biasing.

**M9 — (Milestone 9 scope, unblocnked by this work)** Correction logging (§9).

Rough dependency graph: M0 → M1 → M2 → M4 → M5 → M6 → M7 → M8, with M3
parallelizable any time after M0 (M4's tests use the fixture DB from M3).

---

## 11. Future work (explicitly out of scope, enabled by this design)

- **Dwell/loop detection for double letters** — timestamps are already recorded
  (`touchPaths` stores `(point, time)`); a dwell feature could bias "too" over "to".
- **True frequency counts** — replace the Zipf-from-rank prior with real counts
  from `corpus/word_frequencies.txt` (one DB column).
- **Context prior** — condition `P(w)` on the previous word once n-gram data
  exists beyond the current character-level bigram/trigram tables.
- **Incremental probabilistic decoding (design C)** — the location channel is the
  emission model; the correction log (§9) is the tuning data. Revisit only when
  that data says template matching has plateaued.
