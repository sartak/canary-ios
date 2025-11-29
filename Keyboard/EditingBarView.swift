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

    private let deviceLayout: DeviceLayout
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
        let buttonConfig = UIImage.SymbolConfiguration(pointSize: deviceLayout.editingButtonSize, weight: .light, scale: .default)

        dismissButton = UIButton(type: .system)
        dismissButton.setTitle("", for: .normal)
        dismissButton.tintColor = theme.decorationColor
        let chevronImage = UIImage(systemName: "chevron.down", withConfiguration: buttonConfig)
        dismissButton.setImage(chevronImage, for: .normal)
        dismissButton.addTarget(self, action: #selector(handleDismissButton), for: .touchUpInside)
        addSubview(dismissButton)

        cutButton = UIButton(type: .system)
        cutButton.tintColor = theme.decorationColor
        let cutImage = UIImage(systemName: "scissors", withConfiguration: buttonConfig)
        cutButton.setImage(cutImage, for: .normal)
        cutButton.addTarget(self, action: #selector(handleCutButton), for: .touchUpInside)
        addSubview(cutButton)

        copyButton = UIButton(type: .system)
        copyButton.tintColor = theme.decorationColor
        let copyImage = UIImage(systemName: "doc.on.doc", withConfiguration: buttonConfig)
        copyButton.setImage(copyImage, for: .normal)
        copyButton.addTarget(self, action: #selector(handleCopyButton), for: .touchUpInside)
        addSubview(copyButton)

        pasteButton = UIButton(type: .system)
        pasteButton.tintColor = theme.decorationColor
        let pasteImage = UIImage(systemName: "doc.on.clipboard", withConfiguration: buttonConfig)
        pasteButton.setImage(pasteImage, for: .normal)
        pasteButton.addTarget(self, action: #selector(handlePasteButton), for: .touchUpInside)
        addSubview(pasteButton)
    }

    func updateLayout(for shiftState: ShiftState, containerWidth: CGFloat) {
        let rightOffset = calculateDismissButtonOffset(for: shiftState, containerWidth: containerWidth)
        let buttonY = (frame.height - deviceLayout.editingButtonSize) / 2

        // Position dismiss button
        let dismissX = containerWidth - rightOffset - deviceLayout.editingButtonSize
        dismissButton.frame = CGRect(x: dismissX, y: buttonY, width: deviceLayout.editingButtonSize, height: deviceLayout.editingButtonSize)

        // Position editing buttons
        let buttonSpacing = deviceLayout.editingButtonSpacing
        let buttonSize = deviceLayout.editingButtonSize

        // Paste button (leftmost of the three)
        let pasteX = containerWidth - (rightOffset + buttonSize + buttonSpacing + buttonSize)
        pasteButton.frame = CGRect(x: pasteX, y: buttonY, width: buttonSize, height: buttonSize)

        // Copy button (middle)
        let copyX = pasteX - buttonSpacing - buttonSize
        copyButton.frame = CGRect(x: copyX, y: buttonY, width: buttonSize, height: buttonSize)

        // Cut button (leftmost)
        let cutX = copyX - buttonSpacing - buttonSize
        cutButton.frame = CGRect(x: cutX, y: buttonY, width: buttonSize, height: buttonSize)
    }

    func calculateSuggestionArea(for shiftState: ShiftState, containerWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let dismissRightOffset = calculateDismissButtonOffset(for: shiftState, containerWidth: containerWidth)
        let editingButtonsWidth = deviceLayout.editingButtonSize * 4 + deviceLayout.editingButtonSpacing * 3

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
        return containerWidth - rightmostKeyCenterX - deviceLayout.editingButtonSize / 2
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
