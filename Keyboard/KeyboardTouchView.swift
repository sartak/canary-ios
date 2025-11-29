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
    var characterFrequencies: CharacterDistribution?
    var onNeedsKeyData: (() -> Void)?
    private var lastLayoutWidth: CGFloat = 0

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
            let color = key.key.backgroundColor(shiftState: shiftState, traitCollection: self.traitCollection, tapped: isPressed, isLargeScreen: isLargeScreen)
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
                    debugVisualizationEnabled: showHitboxDebug
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
    }

    private func drawKeyText(for key: KeyData, theme: ColorTheme) {
        let text = key.key.label(shiftState: shiftState)
        if !text.isEmpty {
            let fontSize = key.key.fontSize(deviceLayout: deviceLayout)
            let font = UIFont.systemFont(ofSize: fontSize)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: theme.textColor
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
}
