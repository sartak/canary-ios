//
//  MultiTouchKeyboardGestureRecognizer.swift
//  Keyboard
//
//  Created by Claude on 7/31/25.
//

import UIKit

protocol MultiTouchKeyboardGestureRecognizerDelegate: AnyObject {
    func gestureRecognizer(_ gestureRecognizer: MultiTouchKeyboardGestureRecognizer, keyAt location: CGPoint) -> KeyData?
}

class MultiTouchKeyboardGestureRecognizer: UIGestureRecognizer {
    weak var hitTestDelegate: MultiTouchKeyboardGestureRecognizerDelegate?
    var onKeyTouchDown: ((KeyData) -> Void)?
    var onKeyTouchUp: ((KeyData) -> Void)?
    var onKeyLongPress: ((KeyData) -> Void)?
    var onAlternatesShow: ((KeyData, [String]) -> Void)?
    var onAlternatesMove: ((CGPoint) -> Void)?
    var onAlternatesSelect: (() -> Void)?
    var onAlternatesDismiss: (() -> Void)?
    var onSwipeStarted: ((KeyData) -> Void)?
    var onSwipePathUpdated: (() -> Void)?
    var onSwipeKeySequenceChanged: (([SwipeKey]) -> Void)?
    var onSwipeEnded: (([SwipeKey], [CGPoint]) -> Void)?

    // Multi-touch support - same as original implementation
    private var touchQueue: [(UITouch, KeyData)] = []
    private var pressedKeys: Set<Int> = []

    // Swipe detection
    private var touchPaths: [UITouch: [(point: CGPoint, time: Date)]] = [:]
    private var swipingTouches: Set<UITouch> = []
    private var fadingPaths: [[(point: CGPoint, time: Date)]] = []
    private var swipeAnimationTimer: Timer?
    private let tailDuration: TimeInterval = 0.5
    private(set) var swipeKeySequence: [SwipeKey] = []
    var deviceLayout: DeviceLayout?

    // Long press support
    private var longPressTimers: [UITouch: Timer] = [:]
    private var longPressTriggered: Set<UITouch> = []
    private let longPressDelay: TimeInterval = 0.5

    // Alternates support
    private var alternatesActiveTouch: UITouch? = nil
    private var alternatesActiveKey: KeyData? = nil

    var pressedKeyIndices: Set<Int> {
        return pressedKeys
    }

    var activeSwipePaths: [[(point: CGPoint, time: Date)]] {
        return swipingTouches.compactMap { touchPaths[$0] } + fadingPaths
    }

    var currentSwipePathPoints: [CGPoint] {
        guard let touch = swipingTouches.first,
              let path = touchPaths[touch] else {
            return []
        }
        return path.map(\.point)
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        setupGestureRecognizer()
    }

    private func setupGestureRecognizer() {
        // Don't cancel touches in view - we want to handle them
        cancelsTouchesInView = false
        delaysTouchesEnded = false
        delaysTouchesBegan = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)

        swipeKeySequence.removeAll()

        for touch in touches {
            // Ignore new touches while alternates are active
            if alternatesActiveTouch != nil {
                continue
            }

            let location = touch.location(in: view)

            if let key = hitTestDelegate?.gestureRecognizer(self, keyAt: location) {
                touchQueue.append((touch, key))
                pressedKeys.insert(key.index)
                touchPaths[touch] = [(point: location, time: Date())]
                onKeyTouchDown?(key)

                // Start long press timer
                startLongPressTimer(for: touch, key: key)
            }
        }

        // Always succeed for gesture recognition
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)

        for touch in touches {
            // Handle alternates movement
            if touch == alternatesActiveTouch {
                let location = touch.location(in: view)
                onAlternatesMove?(location)
                continue
            }

            // Track path
            let location = touch.location(in: view)
            touchPaths[touch, default: []].append((point: location, time: Date()))

            // Check for swipe transition
            if let threshold = deviceLayout?.swipeDistanceThreshold,
               !swipingTouches.contains(touch) && !longPressTriggered.contains(touch) {
                if pathDisplacementSquared(for: touch) >= threshold * threshold {
                    swipingTouches.insert(touch)
                    startSwipeAnimationTimer()
                    cancelLongPressTimer(for: touch)
                    initializeSwipeKeySequence(for: touch)
                    if let (_, key) = touchQueue.first(where: { $0.0 === touch }) {
                        pressedKeys.remove(key.index)
                        onSwipeStarted?(key)
                    }
                }
            } else if swipingTouches.contains(touch) {
                appendKeyToSequenceIfNew(at: location)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)

        for touch in touches {
            // Handle alternates selection
            if touch == alternatesActiveTouch {
                onAlternatesSelect?()
                alternatesActiveTouch = nil
                alternatesActiveKey = nil
                // Remove this touch from the queue since it was consumed by alternates selection
                if let touchIndex = touchQueue.firstIndex(where: { $0.0 === touch }) {
                    let (_, key) = touchQueue.remove(at: touchIndex)
                    pressedKeys.remove(key.index)
                }
            } else {
                cancelLongPressTimer(for: touch)
                let wasSwiping = swipingTouches.contains(touch)
                if wasSwiping {
                    // Swipe ended - finalize sequence and invoke callback
                    swipeKeySequence = finalizeSwipeKeySequence()
                    let pathPoints = touchPaths[touch]?.map(\.point) ?? []
                    onSwipeEnded?(swipeKeySequence, pathPoints)
                    if let path = touchPaths[touch] {
                        fadingPaths.append(path)
                    }
                    // Remove from queue without triggering tap
                    if let touchIndex = touchQueue.firstIndex(where: { $0.0 === touch }) {
                        let (_, key) = touchQueue.remove(at: touchIndex)
                        pressedKeys.remove(key.index)
                    }
                    touchPaths.removeValue(forKey: touch)
                    swipingTouches.remove(touch)
                } else {
                    processQueueUpToTouch(touch)
                    clearSwipeState(for: touch)
                }
            }
        }

        // Update gesture state based on remaining touches
        if touchQueue.isEmpty {
            state = .ended
        } else {
            state = .changed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)

        for touch in touches {
            // Handle alternates cancellation
            if touch == alternatesActiveTouch {
                onAlternatesDismiss?()
                alternatesActiveTouch = nil
                alternatesActiveKey = nil
            } else {
                cancelLongPressTimer(for: touch)
                processQueueUpToTouch(touch)
            }
            clearSwipeState(for: touch)
        }

        // Update gesture state
        if touchQueue.isEmpty {
            state = .cancelled
        } else {
            state = .changed
        }
    }

    private func processQueueUpToTouch(_ endingTouch: UITouch) {
        guard let endingTouchIndex = touchQueue.firstIndex(where: { $0.0 === endingTouch }) else { return }

        // Process all touches up to and including the ending touch, in order
        let touchesToProcess = Array(touchQueue[0...endingTouchIndex])

        for (_, key) in touchesToProcess {
            onKeyTouchUp?(key)
            pressedKeys.remove(key.index)
        }

        // Remove processed touches from queue
        touchQueue.removeFirst(touchesToProcess.count)
    }

    override func reset() {
        super.reset()
        touchQueue.removeAll()
        pressedKeys.removeAll()
        touchPaths.removeAll()
        swipingTouches.removeAll()
        swipeKeySequence.removeAll()
        cancelAllLongPressTimers()

        // Clear alternates state
        if alternatesActiveTouch != nil {
            onAlternatesDismiss?()
            alternatesActiveTouch = nil
            alternatesActiveKey = nil
        }
    }

    // MARK: - Long Press Support

    private func startLongPressTimer(for touch: UITouch, key: KeyData) {
        let timer = Timer.scheduledTimer(withTimeInterval: longPressDelay, repeats: false) { [weak self] _ in
            self?.handleLongPress(for: touch, key: key)
        }
        longPressTimers[touch] = timer
    }

    private func cancelLongPressTimer(for touch: UITouch) {
        longPressTimers[touch]?.invalidate()
        longPressTimers.removeValue(forKey: touch)
        longPressTriggered.remove(touch)
    }

    private func cancelAllLongPressTimers() {
        for timer in longPressTimers.values {
            timer.invalidate()
        }
        longPressTimers.removeAll()
        longPressTriggered.removeAll()
    }

    private func handleLongPress(for touch: UITouch, key: KeyData) {
        longPressTriggered.insert(touch)

        // Check if key has alternates
        if case .alternates(let alternates) = key.key.longPressBehavior {
            // Add the original key character to the alternates list
            var alternatesWithOriginal = alternates
            if case .simple(let originalChar) = key.key.keyType {
                alternatesWithOriginal.insert(originalChar, at: 0) // Put original first
            }

            // Show alternates popup
            alternatesActiveTouch = touch
            alternatesActiveKey = key
            onAlternatesShow?(key, alternatesWithOriginal)
        } else {
            // Regular long press behavior
            onKeyLongPress?(key)
        }
    }

    // MARK: - Swipe Detection Helpers

    private func pathDisplacementSquared(for touch: UITouch) -> CGFloat {
        guard let points = touchPaths[touch],
              let first = points.first?.point,
              let last = points.last?.point else { return 0 }
        let dx = last.x - first.x
        let dy = last.y - first.y
        return dx * dx + dy * dy
    }

    private func clearSwipeState(for touch: UITouch) {
        touchPaths.removeValue(forKey: touch)
        swipingTouches.remove(touch)
        if swipingTouches.isEmpty && fadingPaths.isEmpty {
            stopSwipeAnimationTimer()
        }
    }

    private func startSwipeAnimationTimer() {
        guard swipeAnimationTimer == nil else { return }
        swipeAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Prune fully faded paths
            let now = Date()
            self.fadingPaths.removeAll { path in
                path.allSatisfy { now.timeIntervalSince($0.time) > self.tailDuration }
            }
            // Stop timer if nothing left to animate
            if self.swipingTouches.isEmpty && self.fadingPaths.isEmpty {
                self.stopSwipeAnimationTimer()
            }
            self.onSwipePathUpdated?()
        }
    }

    private func stopSwipeAnimationTimer() {
        swipeAnimationTimer?.invalidate()
        swipeAnimationTimer = nil
    }

    private func initializeSwipeKeySequence(for touch: UITouch) {
        swipeKeySequence.removeAll()
        guard let path = touchPaths[touch] else { return }

        for entry in path {
            appendKeyToSequenceIfNew(at: entry.point, notify: false)
        }

        if !swipeKeySequence.isEmpty {
            onSwipeKeySequenceChanged?(swipeKeySequence)
        }
    }

    private func appendKeyToSequenceIfNew(at point: CGPoint, notify: Bool = true) {
        guard let key = hitTestDelegate?.gestureRecognizer(self, keyAt: point),
              case .simple(let char) = key.key.keyType,
              let firstChar = char.lowercased().first else {
            return
        }

        // Check if this is a different key than the last one
        if swipeKeySequence.last?.character == firstChar {
            return
        }

        let swipeKey: SwipeKey = swipeKeySequence.isEmpty ? .required(firstChar) : .optional(firstChar)
        swipeKeySequence.append(swipeKey)
        if notify {
            onSwipeKeySequenceChanged?(swipeKeySequence)
        }
    }

    private func finalizeSwipeKeySequence() -> [SwipeKey] {
        guard swipeKeySequence.count >= 2 else { return swipeKeySequence }

        // Change last entry to required
        var finalSequence = swipeKeySequence
        let lastIndex = finalSequence.count - 1
        if case .optional(let char) = finalSequence[lastIndex] {
            finalSequence[lastIndex] = .required(char)
        }
        return finalSequence
    }
}
