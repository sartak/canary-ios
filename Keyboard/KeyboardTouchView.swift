//
//  KeyboardTouchView.swift
//  Keyboard
//
//  Created by Shawn Moore on 7/29/25.
//

import UIKit

private let largeScreenWidth: CGFloat = 600

class KeyboardTouchView: UIView, UIGestureRecognizerDelegate, MultiTouchKeyboardGestureRecognizerDelegate {
    var keyData: [KeyData] = []
    var shiftState: ShiftState = .unshifted
    var deviceLayout: DeviceLayout!
    var autocorrectEnabled: Bool = true
    var hasUndo: Bool = false
    var keysWithPopouts: Set<Int> = []
    var onKeyTouchDown: ((KeyData) -> Void)? {
        didSet {
            gestureRecognizer?.onKeyTouchDown = onKeyTouchDown
        }
    }
    var onKeyTouchUp: ((KeyData) -> Void)? {
        didSet {
            gestureRecognizer?.onKeyTouchUp = onKeyTouchUp
        }
    }
    var onKeyLongPress: ((KeyData) -> Void)? {
        didSet {
            gestureRecognizer?.onKeyLongPress = onKeyLongPress
        }
    }
    var onKeyDoubleTap: ((KeyData) -> Void)?
    var onAlternateSelected: ((String, KeyData) -> Void)?

    var showHitboxDebug: Bool = false
    var showDebugSwipePath: Bool = false
    var characterFrequencies: CharacterDistribution?
    var onNeedsKeyData: (() -> Void)?
    private var lastLayoutWidth: CGFloat = 0
    private var debugSwipePath: [CGPoint] = []
    private var debugTemplatePaths: [[CGPoint]] = []

    /// Whether swipe-only mode is active for the CURRENT layer (the
    /// controller combines the user toggle with the alpha-layer gate). Letter
    /// keys dim to `swipeDimAlpha` to signal they are tap-inert.
    var swipeOnlyActive: Bool = false {
        didSet { if swipeOnlyActive != oldValue { setNeedsDisplay() } }
    }
    /// The raw user toggle, un-gated by layer, so the number layer's
    /// configuration key shows the real setting.
    var swipeOnlyToggleOn: Bool = false {
        didSet { if swipeOnlyToggleOn != oldValue { setNeedsDisplay() } }
    }
    private let swipeDimAlpha: CGFloat = 0.65
    private let shimmerDuration: TimeInterval = 1.1
    private var shimmerStart: CFAbsoluteTime?
    private var shimmerTimer: Timer?

    // Multi-touch gesture recognizer
    private(set) var gestureRecognizer: MultiTouchKeyboardGestureRecognizer!

    // Alternates popup
    private var alternatesPopup: AlternatesPopoutView?
    private var alternatesActiveTouchIndex: Int?

    // Double-tap gesture recognizer for keys with double-tap behavior
    private var doubleTapRecognizer: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTouchHandling()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTouchHandling()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0 && bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            onNeedsKeyData?()
        }
    }

    private func setupTouchHandling() {
        // Enable multi-touch support
        isMultipleTouchEnabled = true

        // Create and configure gesture recognizer
        gestureRecognizer = MultiTouchKeyboardGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        gestureRecognizer.delegate = self
        gestureRecognizer.hitTestDelegate = self
        addGestureRecognizer(gestureRecognizer)

        // Create double-tap recognizer once
        setupDoubleTapGestureRecognizer()
    }

    @objc private func handleGesture(_ recognizer: MultiTouchKeyboardGestureRecognizer) {
        // The gesture recognizer handles all touch logic through callbacks
        // This method exists to satisfy the target-action pattern but doesn't need implementation
    }

    private func setupDoubleTapGestureRecognizer() {
        // Create double-tap recognizer for keys with double-tap behavior
        let doubleTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleKeyDoubleTap(_:)))
        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.numberOfTouchesRequired = 1
        doubleTapRecognizer.delegate = self

        // Make the multi-touch recognizer wait for double-tap to fail
        gestureRecognizer.require(toFail: doubleTapRecognizer)

        addGestureRecognizer(doubleTapRecognizer)
        self.doubleTapRecognizer = doubleTapRecognizer
    }

    @objc private func handleKeyDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)

        // Find which key was double-tapped
        guard let tappedKey = key(at: location) else {
            return
        }

        // Verify the key has double-tap behavior
        if tappedKey.key.doubleTapBehavior != nil {
            onKeyDoubleTap?(tappedKey)
        }
    }

    // MARK: - Alternates Popup

    func showAlternatesPopup(for keyData: KeyData, alternates: [String]) {
        dismissAlternatesPopup()

        // Skip existing popout removal to prevent race condition crash
        // The existing popout will be cleaned up when the view is redrawn

        guard let superview = self.superview else { return }

        let popup = AlternatesPopoutView(
            keyData: keyData,
            alternates: alternates,
            containerView: superview,
            deviceLayout: deviceLayout,
            onAlternateSelected: { [weak self] alternate in
                self?.onAlternateSelected?(alternate, keyData)
                self?.dismissAlternatesPopup()
            },
            onDismiss: { [weak self] in
                self?.dismissAlternatesPopup()
            }
        )

        superview.addSubview(popup)
        alternatesPopup = popup
        alternatesActiveTouchIndex = keyData.index

        // Hide the original key content while popup is showing
        keysWithPopouts.insert(keyData.index)
        setNeedsDisplay()
    }

    func updateAlternatesSelection(at point: CGPoint) {
        alternatesPopup?.updateSelection(at: point)
    }

    func selectCurrentAlternate() {
        alternatesPopup?.selectCurrentAlternate()
    }

    func dismissAlternatesPopup() {
        if let index = alternatesActiveTouchIndex {
            keysWithPopouts.remove(index)
        }

        alternatesPopup?.removeFromSuperview()
        alternatesPopup = nil
        alternatesActiveTouchIndex = nil
        setNeedsDisplay()
    }

    func hasActiveAlternatesPopup() -> Bool {
        return alternatesPopup != nil
    }

    func setDebugSwipePath(_ path: [CGPoint]) {
        debugSwipePath = path
        setNeedsDisplay()
    }

    func setDebugTemplatePaths(_ paths: [[CGPoint]]) {
        debugTemplatePaths = paths
        setNeedsDisplay()
    }

    func clearDebugSwipePath() {
        debugSwipePath.removeAll()
        debugTemplatePaths.removeAll()
        setNeedsDisplay()
    }

    private func key(at location: CGPoint) -> KeyData? {
        // This method is using a heuristic; non-letter keys typically won't be
        // affected by this decision
        let keys = keyData.filter { $0.hitbox.contains(location) }
        guard !keys.isEmpty else { return nil }

        return keys.max { keyA, keyB in
            let freqA = keyA.key.simpleCharacter.map { characterFrequencies?[$0] ?? 0 } ?? 0
            let freqB = keyB.key.simpleCharacter.map { characterFrequencies?[$0] ?? 0 } ?? 0
            return freqA < freqB
        }
    }

    // MARK: - MultiTouchKeyboardGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: MultiTouchKeyboardGestureRecognizer, keyAt location: CGPoint) -> KeyData? {
        return key(at: location)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Don't allow simultaneous recognition between tap gestures and multi-touch gestures
        // This prevents conflicts between single-tap and double-tap detection
        if gestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer is MultiTouchKeyboardGestureRecognizer {
            return false
        }
        if gestureRecognizer is MultiTouchKeyboardGestureRecognizer && otherGestureRecognizer is UITapGestureRecognizer {
            return false
        }

        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let location = touch.location(in: self)

        if gestureRecognizer is UITapGestureRecognizer {
            // Only allow double-tap recognizer to receive touches on keys with double-tap behavior
            if let tappedKey = key(at: location) {
                return tappedKey.key.doubleTapBehavior != nil
            }
            return false
        }

        return true
    }



    override func draw(_ rect: CGRect) {
        super.draw(rect)

        let isLargeScreen = bounds.width > largeScreenWidth

        let theme = ColorTheme.current(for: self.traitCollection)

        for key in keyData {
            let isPressed = gestureRecognizer.pressedKeyIndices.contains(key.index)

            // Draw key shadow (only for visible keys, not when pressed)
            if !isPressed && key.key.keyType != .empty {
                let shadowPath = UIBezierPath(roundedRect: key.viewFrame, cornerRadius: deviceLayout.cornerRadius)
                let context = UIGraphicsGetCurrentContext()
                context?.saveGState()
                context?.setShadow(offset: theme.keyShadowOffset, blur: theme.keyShadowRadius, color: theme.keyShadowColor.cgColor)
                theme.keyShadowColor.setFill()
                shadowPath.fill()
                context?.restoreGState()
            }

            // Draw rounded key background
            let path = UIBezierPath(roundedRect: key.viewFrame, cornerRadius: deviceLayout.cornerRadius)
            var color = key.key.backgroundColor(shiftState: shiftState, traitCollection: self.traitCollection, tapped: isPressed, isLargeScreen: isLargeScreen)
            // Swipe-only mode dims the whole key face, not just the glyph;
            // pressed keys keep full-strength feedback.
            if !isPressed, let dim = swipeDimFactor(for: key) {
                color = color.withAlphaComponent(dim)
            }
            color.setFill()
            path.fill()

            // Draw key content (hide if this key has a popout showing)
            let shouldHideContent = keysWithPopouts.contains(key.index)
            if !shouldHideContent {
                let fontSize = key.key.fontSize(deviceLayout: deviceLayout)

                // Try to render SF Symbol first
                if let symbolView = SFSymbolRenderer.render(
                    for: key.key,
                    shiftState: shiftState,
                    fontSize: fontSize,
                    theme: theme,
                    pressed: isPressed,
                    autocorrectEnabled: autocorrectEnabled,
                    hasUndo: key.key.keyType == .backspace ? hasUndo : false,
                    debugVisualizationEnabled: showHitboxDebug,
                    swipeOnlyMode: swipeOnlyToggleOn
                ) as? UIImageView {
                    // Draw SF Symbol
                    let symbolImage = symbolView.image!
                    let imageSize = symbolImage.size
                    let imageRect = CGRect(
                        x: key.viewFrame.midX - imageSize.width / 2,
                        y: key.viewFrame.midY - imageSize.height / 2,
                        width: imageSize.width,
                        height: imageSize.height
                    )

                    symbolImage.draw(in: imageRect)
                } else {
                    // Fallback to text
                    drawKeyText(for: key, theme: theme)
                }
            }
        }

        // Swipe-only shimmer: a soft highlight band washing left-to-right,
        // clipped to the dimmed letter-key faces so the glow follows the
        // keycaps and blends continuously across key boundaries.
        if swipeOnlyActive, let start = shimmerStart,
           let context = UIGraphicsGetCurrentContext() {
            let progress = CGFloat((CFAbsoluteTimeGetCurrent() - start) / shimmerDuration)
            if progress >= 0 && progress <= 1 {
                let eased = progress * progress * (3 - 2 * progress)
                let band = bounds.width * 0.25
                // The band leans ~20° like a light glare rather than sweeping
                // as a vertical bar; the extra travel margin keeps the tilted
                // band fully off-screen at both ends of the sweep.
                let axis = CGPoint(x: 0.94, y: 0.34)
                let skew = bounds.height * (axis.y / axis.x) / 2
                let margin = band + skew
                let bandCenter = eased * (bounds.width + 2 * margin) - margin

                context.saveGState()
                let clip = UIBezierPath()
                for key in keyData where swipeDimFactor(for: key) != nil {
                    clip.append(UIBezierPath(roundedRect: key.viewFrame, cornerRadius: deviceLayout.cornerRadius))
                }
                clip.addClip()

                let colors = [
                    UIColor.white.withAlphaComponent(0).cgColor,
                    UIColor.white.withAlphaComponent(0.35).cgColor,
                    UIColor.white.withAlphaComponent(0).cgColor,
                ]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: colors as CFArray,
                                             locations: [0, 0.5, 1]) {
                    context.setBlendMode(.plusLighter)
                    let mid = bounds.midY
                    context.drawLinearGradient(gradient,
                                               start: CGPoint(x: bandCenter - band * axis.x, y: mid - band * axis.y),
                                               end: CGPoint(x: bandCenter + band * axis.x, y: mid + band * axis.y),
                                               options: [])
                }
                context.restoreGState()
            }
        }

        // Draw hitbox debug visualization
        if showHitboxDebug {
            for key in keyData {
                if case .empty = key.key.keyType {
                    continue
                }

                let debugContext = UIGraphicsGetCurrentContext()
                debugContext?.setFillColor(key.debugColor.cgColor)
                debugContext?.fill(key.hitbox)
            }
        }

        // Draw swipe paths
        if showDebugSwipePath {
            // Debug mode: draw persistent 3px black bezier
            if debugSwipePath.count >= 2 {
                let bezier = UIBezierPath()
                bezier.move(to: debugSwipePath[0])
                for point in debugSwipePath.dropFirst() {
                    bezier.addLine(to: point)
                }
                bezier.lineWidth = 3
                UIColor.black.setStroke()
                bezier.stroke()
            }

            // Overlay the top candidates' ideal template polylines, one color
            // per rank (swiping.md §8.4).
            let templateColors: [UIColor] = [.systemGreen, .systemOrange, .systemPurple]
            for (rank, template) in debugTemplatePaths.enumerated() where template.count >= 2 {
                let bezier = UIBezierPath()
                bezier.move(to: template[0])
                for point in template.dropFirst() {
                    bezier.addLine(to: point)
                }
                bezier.lineWidth = 1.5
                templateColors[rank % templateColors.count].withAlphaComponent(0.8).setStroke()
                bezier.stroke()
            }
        } else {
            // Normal mode: draw tapered width path (tail fades over ~500ms)
            let now = Date()
            let tailDuration: TimeInterval = 0.5

            for path in gestureRecognizer.activeSwipePaths {
                // Filter to points within tail duration
                let visiblePath = path.filter { now.timeIntervalSince($0.time) <= tailDuration }
                guard visiblePath.count >= 2 else { continue }

                let maxWidth = deviceLayout.swipePathMaxWidth

                // Build polygon outline
                var leftEdge: [CGPoint] = []
                var rightEdge: [CGPoint] = []

                for i in 0..<visiblePath.count {
                    let age = now.timeIntervalSince(visiblePath[i].time)
                    let linearProgress = CGFloat(1.0 - age / tailDuration)
                    let progress = linearProgress * linearProgress  // Quadratic falloff
                    let halfWidth = maxWidth * progress / 2.0

                    // Calculate direction
                    let direction: CGPoint
                    if i == 0 {
                        direction = CGPoint(x: visiblePath[1].point.x - visiblePath[0].point.x,
                                            y: visiblePath[1].point.y - visiblePath[0].point.y)
                    } else if i == visiblePath.count - 1 {
                        direction = CGPoint(x: visiblePath[i].point.x - visiblePath[i-1].point.x,
                                            y: visiblePath[i].point.y - visiblePath[i-1].point.y)
                    } else {
                        direction = CGPoint(x: visiblePath[i+1].point.x - visiblePath[i-1].point.x,
                                            y: visiblePath[i+1].point.y - visiblePath[i-1].point.y)
                    }

                    // Normalize and get perpendicular
                    let length = sqrt(direction.x * direction.x + direction.y * direction.y)
                    guard length > 0 else { continue }
                    let perpendicular = CGPoint(x: -direction.y / length, y: direction.x / length)

                    let point = visiblePath[i].point
                    leftEdge.append(CGPoint(x: point.x + perpendicular.x * halfWidth,
                                            y: point.y + perpendicular.y * halfWidth))
                    rightEdge.append(CGPoint(x: point.x - perpendicular.x * halfWidth,
                                             y: point.y - perpendicular.y * halfWidth))
                }

                // Draw filled polygon with rounded head
                let polygon = UIBezierPath()
                guard let first = leftEdge.first else { continue }
                polygon.move(to: first)
                for point in leftEdge.dropFirst() {
                    polygon.addLine(to: point)
                }
                // Add semicircle at the head
                if let lastPoint = visiblePath.last?.point, let lastLeft = leftEdge.last {
                    let lastAge = now.timeIntervalSince(visiblePath.last!.time)
                    let lastProgress = CGFloat(1.0 - lastAge / tailDuration)
                    let radius = maxWidth * lastProgress * lastProgress / 2.0
                    let direction = CGPoint(x: lastLeft.x - lastPoint.x, y: lastLeft.y - lastPoint.y)
                    let startAngle = atan2(direction.y, direction.x)
                    polygon.addArc(withCenter: lastPoint, radius: radius, startAngle: startAngle, endAngle: startAngle + .pi, clockwise: false)
                }
                for point in rightEdge.reversed().dropFirst() {
                    polygon.addLine(to: point)
                }
                polygon.close()

                UIColor.systemRed.withAlphaComponent(0.7).setFill()
                polygon.fill()
            }
        }
    }

    private func drawKeyText(for key: KeyData, theme: ColorTheme) {
        let text = key.key.label(shiftState: shiftState)
        if !text.isEmpty {
            let fontSize = key.key.fontSize(deviceLayout: deviceLayout)
            let font = UIFont.systemFont(ofSize: fontSize)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: labelColor(for: key, theme: theme)
            ]

            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: key.viewFrame.midX - textSize.width / 2,
                y: key.viewFrame.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )

            text.draw(in: textRect, withAttributes: attributes)
        }
    }

    // MARK: - Swipe-mode letter treatment

    /// Dim factor for swipe-only mode on this key, or nil when it doesn't
    /// apply. All letters dim — deliberately broader than the controller's
    /// tap-blocking rule, which exempts "a" and "i" (they're words; a single
    /// key can't be swiped) while keeping their dimmed look. Non-letters like
    /// the apostrophe stay tappable and keep full brightness.
    private func swipeDimFactor(for key: KeyData) -> CGFloat? {
        guard swipeOnlyActive, case .simple(let text) = key.key.keyType,
              let first = text.lowercased().first, first.isLetter else {
            return nil
        }
        return swipeDimAlpha
    }

    private func labelColor(for key: KeyData, theme: ColorTheme) -> UIColor {
        guard let factor = swipeDimFactor(for: key) else { return theme.textColor }
        return theme.textColor.withAlphaComponent(factor)
    }

    /// Plays the one-shot left-to-right shimmer. Called when swipe-only mode
    /// is toggled on and when the keyboard first appears with it enabled; the
    /// timer lives only for the sweep, so nothing animates while idle.
    func playSwipeShimmer() {
        guard swipeOnlyActive else {
            print("KeyboardTouchView: shimmer skipped (swipe-only mode not active on this layer)")
            return
        }
        print("KeyboardTouchView: playing swipe shimmer")
        shimmerTimer?.invalidate()
        shimmerStart = CFAbsoluteTimeGetCurrent()
        shimmerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let start = self.shimmerStart,
               CFAbsoluteTimeGetCurrent() - start > self.shimmerDuration {
                self.shimmerTimer?.invalidate()
                self.shimmerTimer = nil
                self.shimmerStart = nil
            }
            self.setNeedsDisplay()
        }
    }
}
