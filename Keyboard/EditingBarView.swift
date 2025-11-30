//
//  EditingBarView.swift
//  Keyboard
//
//  Created by Shawn Moore on 8/15/25.
//

import UIKit

private let debugColors: [UIColor] = [.red, .green, .blue, .yellow, .orange, .purple, .cyan, .magenta]

func debugColor(at index: Int) -> UIColor {
    debugColors[index % debugColors.count].withAlphaComponent(0.4)
}

protocol EditingBarViewDelegate: AnyObject {
    func editingBarDismiss()
    func editingBarCut()
    func editingBarCopy()
    func editingBarPaste()
}

enum EditingButton {
    case cut, copy, paste
}

class EditingBarView: UIView {
    private var dismissIcon: UIImageView!
    private var cutIcon: UIImageView!
    private var copyIcon: UIImageView!
    private var pasteIcon: UIImageView!
    private var flashResetWorkItems: [EditingButton: DispatchWorkItem] = [:]
    private var dismissTapArea: UIView!
    private var cutTapArea: UIView!
    private var copyTapArea: UIView!
    private var pasteTapArea: UIView!

    var deviceLayout: DeviceLayout
    private let keyboardLayout: KeyboardLayout
    private let currentLayer: Layer
    private let needsGlobe: Bool

    weak var delegate: EditingBarViewDelegate?

    init(deviceLayout: DeviceLayout, keyboardLayout: KeyboardLayout, currentLayer: Layer, needsGlobe: Bool) {
        self.deviceLayout = deviceLayout
        self.keyboardLayout = keyboardLayout
        self.currentLayer = currentLayer
        self.needsGlobe = needsGlobe
        super.init(frame: .zero)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupButtons() {
        let theme = ColorTheme.current(for: traitCollection)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: deviceLayout.editingButtonWidth, weight: .light, scale: .default)

        (dismissIcon, dismissTapArea) = makeIconWithTapArea(
            systemName: "chevron.down",
            symbolConfig: symbolConfig,
            tintColor: theme.decorationColor,
            action: #selector(handleDismissButton)
        )

        (cutIcon, cutTapArea) = makeIconWithTapArea(
            systemName: "scissors",
            symbolConfig: symbolConfig,
            tintColor: theme.decorationColor,
            action: #selector(handleCutButton)
        )

        (copyIcon, copyTapArea) = makeIconWithTapArea(
            systemName: "doc.on.doc",
            symbolConfig: symbolConfig,
            tintColor: theme.decorationColor,
            action: #selector(handleCopyButton)
        )

        (pasteIcon, pasteTapArea) = makeIconWithTapArea(
            systemName: "doc.on.clipboard",
            symbolConfig: symbolConfig,
            tintColor: theme.decorationColor,
            action: #selector(handlePasteButton)
        )
    }

    private func makeIconWithTapArea(systemName: String, symbolConfig: UIImage.SymbolConfiguration, tintColor: UIColor, action: Selector) -> (UIImageView, UIView) {
        let image = UIImage(systemName: systemName, withConfiguration: symbolConfig)
        let imageView = UIImageView(image: image)
        imageView.tintColor = tintColor
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let tapArea = UIView()
        tapArea.addGestureRecognizer(UITapGestureRecognizer(target: self, action: action))
        addSubview(tapArea)

        return (imageView, tapArea)
    }

    func updateLayout(for shiftState: ShiftState, containerWidth: CGFloat) {
        let rightOffset = calculateDismissButtonOffset(for: shiftState, containerWidth: containerWidth)
        let buttonHeight = frame.height
        let buttonSpacing = deviceLayout.editingButtonSpacing
        let buttonWidth = deviceLayout.editingButtonWidth
        let halfSpacing = buttonSpacing / 2

        // Calculate icon center positions
        let dismissCenterX = containerWidth - rightOffset - buttonWidth / 2
        let pasteCenterX = containerWidth - (rightOffset + buttonWidth + buttonSpacing + buttonWidth / 2)
        let copyCenterX = pasteCenterX - buttonSpacing - buttonWidth
        let cutCenterX = copyCenterX - buttonSpacing - buttonWidth

        // Position icons at their visual centers
        dismissIcon.frame = CGRect(x: dismissCenterX - buttonWidth / 2, y: 0, width: buttonWidth, height: buttonHeight)
        pasteIcon.frame = CGRect(x: pasteCenterX - buttonWidth / 2, y: 0, width: buttonWidth, height: buttonHeight)
        copyIcon.frame = CGRect(x: copyCenterX - buttonWidth / 2, y: 0, width: buttonWidth, height: buttonHeight)
        cutIcon.frame = CGRect(x: cutCenterX - buttonWidth / 2, y: 0, width: buttonWidth, height: buttonHeight)

        // Dismiss tap area - extend left by halfSpacing, extend right to container edge
        let dismissRightExtra = containerWidth - (dismissCenterX + buttonWidth / 2)
        dismissTapArea.frame = CGRect(x: dismissCenterX - buttonWidth / 2 - halfSpacing, y: 0, width: buttonWidth + halfSpacing + dismissRightExtra, height: buttonHeight)

        // Paste tap area - extend both sides by halfSpacing
        pasteTapArea.frame = CGRect(x: pasteCenterX - buttonWidth / 2 - halfSpacing, y: 0, width: buttonWidth + buttonSpacing, height: buttonHeight)

        // Copy tap area - extend both sides by halfSpacing
        copyTapArea.frame = CGRect(x: copyCenterX - buttonWidth / 2 - halfSpacing, y: 0, width: buttonWidth + buttonSpacing, height: buttonHeight)

        // Cut tap area - extend right by halfSpacing, extend left to fill suggestionGap
        let cutLeftExtra = deviceLayout.suggestionGap
        cutTapArea.frame = CGRect(x: cutCenterX - buttonWidth / 2 - cutLeftExtra, y: 0, width: buttonWidth + halfSpacing + cutLeftExtra, height: buttonHeight)
    }

    func calculateSuggestionArea(for shiftState: ShiftState, containerWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let dismissRightOffset = calculateDismissButtonOffset(for: shiftState, containerWidth: containerWidth)
        let editingButtonsWidth = deviceLayout.editingButtonWidth * 4 + deviceLayout.editingButtonSpacing * 3

        // Align with the left edge of the first column of keys
        let isShifted: Bool
        switch shiftState {
        case .unshifted:
            isShifted = false
        case .shifted, .capsLock:
            isShifted = true
        }
        let firstRow = keyboardLayout.nodeRows(for: currentLayer, shifted: isShifted, layout: deviceLayout, needsGlobe: needsGlobe)[0]
        let rowWidth = Node.calculateRowWidth(for: firstRow)
        let suggestionX = (containerWidth - rowWidth) / 2

        let availableWidth = containerWidth - dismissRightOffset - editingButtonsWidth - suggestionX - deviceLayout.suggestionGap

        return (x: suggestionX, width: availableWidth)
    }

    func calculateDismissButtonOffset(for shiftState: ShiftState, containerWidth: CGFloat) -> CGFloat {
        let isShifted: Bool
        switch shiftState {
        case .unshifted:
            isShifted = false
        case .shifted, .capsLock:
            isShifted = true
        }

        let firstRow = keyboardLayout.nodeRows(for: currentLayer, shifted: isShifted, layout: deviceLayout, needsGlobe: needsGlobe)[0]
        let rowWidth = Node.calculateRowWidth(for: firstRow)
        let rowStartX = (containerWidth - rowWidth) / 2

        // Find the rightmost key in the first row
        var rightmostKeyX: CGFloat = 0
        var rightmostKeyWidth: CGFloat = 0
        var xOffset = rowStartX

        for node in firstRow {
            switch node {
            case .key(_, let keyWidth):
                rightmostKeyX = xOffset
                rightmostKeyWidth = keyWidth
                xOffset += keyWidth
            case .gap(let gapWidth):
                xOffset += gapWidth
            case .split(let splitWidth):
                xOffset += splitWidth
            }
        }

        // Center the dismiss button above the rightmost key
        let rightmostKeyCenterX = rightmostKeyX + rightmostKeyWidth / 2
        return containerWidth - rightmostKeyCenterX - deviceLayout.editingButtonWidth / 2
    }

    @objc private func handleDismissButton() {
        delegate?.editingBarDismiss()
    }

    @objc private func handleCutButton() {
        delegate?.editingBarCut()
    }

    @objc private func handleCopyButton() {
        delegate?.editingBarCopy()
    }

    @objc private func handlePasteButton() {
        delegate?.editingBarPaste()
    }

    func flashError(for button: EditingButton) {
        flash(button: button, color: .systemRed)
    }

    private func flash(button: EditingButton, color: UIColor) {
        let icon: UIImageView
        switch button {
        case .cut: icon = cutIcon
        case .copy: icon = copyIcon
        case .paste: icon = pasteIcon
        }

        flashResetWorkItems[button]?.cancel()
        icon.tintColor = color

        let workItem = DispatchWorkItem { [weak self, weak icon] in
            guard let self, let icon else { return }
            let theme = ColorTheme.current(for: self.traitCollection)
            icon.tintColor = theme.decorationColor
        }
        flashResetWorkItems[button] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    func setDebugVisualizationEnabled(_ enabled: Bool) {
        backgroundColor = enabled ? UIColor.cyan.withAlphaComponent(0.4) : UIColor.clear
        let tapAreas = [dismissTapArea!, cutTapArea!, copyTapArea!, pasteTapArea!]
        for (index, tapArea) in tapAreas.enumerated() {
            tapArea.backgroundColor = enabled ? debugColor(at: index) : UIColor.clear
        }
    }
}
