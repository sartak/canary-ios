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

class EditingBarView: UIView {
    private var dismissButton: UIButton!
    private var cutButton: UIButton!
    private var copyButton: UIButton!
    private var pasteButton: UIButton!

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
        let buttonConfig = UIImage.SymbolConfiguration(pointSize: deviceLayout.editingButtonWidth, weight: .light, scale: .default)

        dismissButton = UIButton(type: .system)
        dismissButton.setTitle("", for: .normal)
        dismissButton.tintColor = theme.decorationColor
        let chevronImage = UIImage(systemName: "chevron.down", withConfiguration: buttonConfig)
        dismissButton.setImage(chevronImage, for: .normal)
        dismissButton.imageView?.contentMode = .scaleAspectFit
        dismissButton.addTarget(self, action: #selector(handleDismissButton), for: .touchUpInside)
        addSubview(dismissButton)

        cutButton = UIButton(type: .system)
        cutButton.tintColor = theme.decorationColor
        let cutImage = UIImage(systemName: "scissors", withConfiguration: buttonConfig)
        cutButton.setImage(cutImage, for: .normal)
        cutButton.imageView?.contentMode = .scaleAspectFit
        cutButton.addTarget(self, action: #selector(handleCutButton), for: .touchUpInside)
        addSubview(cutButton)

        copyButton = UIButton(type: .system)
        copyButton.tintColor = theme.decorationColor
        let copyImage = UIImage(systemName: "doc.on.doc", withConfiguration: buttonConfig)
        copyButton.setImage(copyImage, for: .normal)
        copyButton.imageView?.contentMode = .scaleAspectFit
        copyButton.addTarget(self, action: #selector(handleCopyButton), for: .touchUpInside)
        addSubview(copyButton)

        pasteButton = UIButton(type: .system)
        pasteButton.tintColor = theme.decorationColor
        let pasteImage = UIImage(systemName: "doc.on.clipboard", withConfiguration: buttonConfig)
        pasteButton.setImage(pasteImage, for: .normal)
        pasteButton.imageView?.contentMode = .scaleAspectFit
        pasteButton.addTarget(self, action: #selector(handlePasteButton), for: .touchUpInside)
        addSubview(pasteButton)
    }

    func updateLayout(for shiftState: ShiftState, containerWidth: CGFloat) {
        let rightOffset = calculateDismissButtonOffset(for: shiftState, containerWidth: containerWidth)
        let buttonHeight = frame.height
        let buttonSpacing = deviceLayout.editingButtonSpacing
        let buttonWidth = deviceLayout.editingButtonWidth
        let halfSpacing = buttonSpacing / 2

        // Calculate original icon center positions (before expanding hitboxes)
        let dismissCenterX = containerWidth - rightOffset - buttonWidth / 2
        let pasteCenterX = containerWidth - (rightOffset + buttonWidth + buttonSpacing + buttonWidth / 2)
        let copyCenterX = pasteCenterX - buttonSpacing - buttonWidth
        let cutCenterX = copyCenterX - buttonSpacing - buttonWidth

        // Dismiss button - extend left by halfSpacing, extend right to container edge
        let dismissRightExtra = containerWidth - (dismissCenterX + buttonWidth / 2)
        dismissButton.frame = CGRect(x: dismissCenterX - buttonWidth / 2 - halfSpacing, y: 0, width: buttonWidth + halfSpacing + dismissRightExtra, height: buttonHeight)
        dismissButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: halfSpacing, bottom: 0, right: dismissRightExtra)

        // Paste button - extend both sides by halfSpacing
        pasteButton.frame = CGRect(x: pasteCenterX - buttonWidth / 2 - halfSpacing, y: 0, width: buttonWidth + buttonSpacing, height: buttonHeight)
        pasteButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: halfSpacing, bottom: 0, right: halfSpacing)

        // Copy button - extend both sides by halfSpacing
        copyButton.frame = CGRect(x: copyCenterX - buttonWidth / 2 - halfSpacing, y: 0, width: buttonWidth + buttonSpacing, height: buttonHeight)
        copyButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: halfSpacing, bottom: 0, right: halfSpacing)

        // Cut button - extend right by halfSpacing, extend left to fill suggestionGap
        let cutLeftExtra = deviceLayout.suggestionGap
        cutButton.frame = CGRect(x: cutCenterX - buttonWidth / 2 - cutLeftExtra, y: 0, width: buttonWidth + halfSpacing + cutLeftExtra, height: buttonHeight)
        cutButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: cutLeftExtra, bottom: 0, right: halfSpacing)
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

    func setDebugVisualizationEnabled(_ enabled: Bool) {
        backgroundColor = enabled ? UIColor.cyan.withAlphaComponent(0.4) : UIColor.clear
        let buttons = [dismissButton!, cutButton!, copyButton!, pasteButton!]
        for (index, button) in buttons.enumerated() {
            button.backgroundColor = enabled ? debugColor(at: index) : UIColor.clear
        }
    }
}
