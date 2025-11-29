//
//  KeyboardViewController.swift
//  Keyboard
//
//  Created by Shawn Moore on 7/29/25.
//

import UIKit

private let largeScreenWidth: CGFloat = 600

class KeyboardViewController: UIInputViewController, KeyActionDelegate, EditingBarViewDelegate, SuggestionServiceDelegate {
    private var currentLayer: Layer = .alpha
    private var userShiftState: ShiftState = .unshifted
    private var appShiftState: ShiftState = .unshifted
    private var userShiftOverride: Bool = false
    private var keyboardTouchView: KeyboardTouchView!
    private var deviceLayout: DeviceLayout!
    private var heightConstraint: NSLayoutConstraint?
    private var keyboardLayout: KeyboardLayout = .canary
    private var needsGlobe: Bool = false
    private var keyPopouts: [Int: UIView] = [:]
    private var editingBarView: EditingBarView!
    private var suggestionView: SuggestionView!
    var suggestionService: SuggestionService = SuggestionService()!
    private var pendingRefresh = false
    var maybePunctuating = false
    private var autocorrectAppDisabled = false
    private var autocorrectUserDisabled = false
    var autocorrectWordDisabled = false
    var undoActions: [InputAction]?
    private var debugVisualizationEnabled = false
    private var characterFrequencies: CharacterDistribution?
    private var charBeforeCursor: Character?
    private var backspaceShiftState: ShiftState = .unshifted

    // Expose autocorrect state for testing/debugging
    var isAutocorrectEnabled: Bool {
        return !autocorrectAppDisabled && !autocorrectUserDisabled
    }

    // Key repeat support
    private var keyRepeatTimer: Timer?
    private var currentlyRepeatingKey: KeyData?
    private let keyRepeatInitialDelay: TimeInterval = 0.5
    private let keyRepeatInterval: TimeInterval = 0.05

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (traitEnvironment: UITraitEnvironment, previousTraitCollection: UITraitCollection) in
            self?.keyboardTouchView?.setNeedsDisplay()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let currentBounds = view.bounds
        let screenBounds = UIScreen.main.bounds

        // Always setup keyboard initially
        if keyboardTouchView == nil {
            needsGlobe = needsInputModeSwitchKey
            updateAutocorrectSettings()
            setupKeyboard()

            // If bounds seem wrong (full screen on iPad), schedule a rebuild
            if currentBounds.width >= screenBounds.width * 0.95 && screenBounds.width > 1000 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if self.view.bounds != currentBounds {
                        self.rebuildKeyboard()
                    }
                }
            }
        } else {
            // Rebuild when bounds change
            let lastWidth = keyboardTouchView.bounds.width
            if abs(currentBounds.width - lastWidth) > 10 {
                rebuildKeyboard()
            }
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in
            self.rebuildKeyboard()
        }
    }

    private func setupKeyboard() {
        let screenBounds = UIScreen.main.bounds
        let viewBounds = view.bounds
        let isLandscape = screenBounds.width > screenBounds.height

        let effectiveWidth = viewBounds.width
        let effectiveHeight = isLandscape ? screenBounds.width : screenBounds.height

        deviceLayout = DeviceLayout.forCurrentDevice(containerWidth: effectiveWidth, containerHeight: effectiveHeight)

        keyboardTouchView = KeyboardTouchView()
        keyboardTouchView.backgroundColor = UIColor.clear
        keyboardTouchView.shiftState = effectiveShiftState()
        keyboardTouchView.deviceLayout = deviceLayout
        keyboardTouchView.autocorrectEnabled = !autocorrectUserDisabled
        keyboardTouchView.showHitboxDebug = debugVisualizationEnabled
        keyboardTouchView.characterFrequencies = characterFrequencies
        keyboardTouchView.keyData = createKeyData()
        keyboardTouchView.setNeedsDisplay()

        keyboardTouchView.onKeyTouchDown = { [weak self] keyData in
            self?.handleKeyTouchDown(keyData)
        }

        keyboardTouchView.onKeyTouchUp = { [weak self] keyData in
            self?.handleKeyTouchUp(keyData)
        }

        keyboardTouchView.onKeyLongPress = { [weak self] keyData in
            self?.handleKeyLongPress(keyData)
        }

        keyboardTouchView.onKeyDoubleTap = { [weak self] keyData in
            self?.handleKeyDoubleTap(keyData)
        }

        keyboardTouchView.onAlternateSelected = { [weak self] alternate, keyData in
            self?.handleAlternateSelected(alternate, from: keyData)
        }

        // Set up alternates callbacks on the gesture recognizer
        keyboardTouchView.gestureRecognizer.onAlternatesShow = { [weak self] keyData, alternates in
            self?.showAlternatesPopup(for: keyData, alternates: alternates)
        }

        keyboardTouchView.gestureRecognizer.onAlternatesMove = { [weak self] point in
            self?.keyboardTouchView.updateAlternatesSelection(at: point)
        }

        keyboardTouchView.gestureRecognizer.onAlternatesSelect = { [weak self] in
            self?.keyboardTouchView.selectCurrentAlternate()
        }

        keyboardTouchView.gestureRecognizer.onAlternatesDismiss = { [weak self] in
            self?.keyboardTouchView.dismissAlternatesPopup()
        }

        // Calculate keyboard height first
        let isShifted: Bool
        switch effectiveShiftState() {
        case .unshifted:
            isShifted = false
        case .shifted, .capsLock:
            isShifted = true
        }
        let calculatedHeight = deviceLayout.totalKeyboardHeight(for: currentLayer, shifted: isShifted, layout: keyboardLayout, needsGlobe: needsGlobe)

        // Disable implicit animations during initial keyboard setup to prevent keys sliding in from corners
        UIView.performWithoutAnimation {
            view.addSubview(keyboardTouchView)

            keyboardTouchView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                keyboardTouchView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                keyboardTouchView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                keyboardTouchView.topAnchor.constraint(equalTo: view.topAnchor),
                keyboardTouchView.heightAnchor.constraint(equalToConstant: calculatedHeight)
            ])

            // Set explicit height constraint for the main view
            heightConstraint = NSLayoutConstraint(
                item: view as Any,
                attribute: .height,
                relatedBy: .equal,
                toItem: nil,
                attribute: .notAnAttribute,
                multiplier: 1.0,
                constant: calculatedHeight
            )
            heightConstraint?.priority = UILayoutPriority(999)
            view.addConstraint(heightConstraint!)

            setupEditingBar()
            setupSuggestionView()
        }
    }

    private func createKeyData() -> [KeyData] {
        var keys: [KeyData] = []
        var yOffset: CGFloat = deviceLayout.topPadding

        let isShifted: Bool
        switch effectiveShiftState() {
        case .unshifted:
            isShifted = false
        case .shifted, .capsLock:
            isShifted = true
        }
        let allRows = keyboardLayout.nodeRows(for: currentLayer, shifted: isShifted, layout: deviceLayout, needsGlobe: needsGlobe)
        for (rowIndex, row) in allRows.enumerated() {
            let rowKeys = createRowKeyData(for: row, rowIndex: rowIndex, yOffset: yOffset, startingIndex: keys.count, allRows: allRows)
            keys.append(contentsOf: rowKeys)
            yOffset += deviceLayout.keyHeight + deviceLayout.verticalGap
        }

        return keys
    }

    private func calculateKeyHitbox(key: Key, frame: CGRect, prevNode: Node?, nextNode: Node?, allRows: [[Node]], currentRow: Int, currentNode: Int) -> CGRect {
        let hitboxOverage: CGFloat = 0.2
        let leftPadding: CGFloat
        if currentNode == 0 {
            leftPadding = deviceLayout.horizontalGap
        } else {
            var totalWidth: CGFloat = 0
            var nodeIndex = currentNode - 1
            let currentRowNodes = allRows[currentRow]
            var ratio = 0.5
            var leftKey: Key?

            leftLoop: while nodeIndex >= 0 {
                let node = currentRowNodes[nodeIndex]
                switch node {
                case .gap(let gapWidth):
                    totalWidth += gapWidth
                case .split(let splitWidth):
                    totalWidth += splitWidth
                case .key(let foundKey, _):
                    leftKey = foundKey
                    break leftLoop
                }
                nodeIndex -= 1
            }

            // Check if both current and left key are simple
            if let currentChar = key.simpleCharacter,
               let leftKey = leftKey,
               let leftChar = leftKey.simpleCharacter,
               let frequencies = characterFrequencies {
                ratio = frequencies.frequencyRatio(currentChar, leftChar)
            }

            leftPadding = totalWidth * (ratio * (1.0 + 2.0 * hitboxOverage) - hitboxOverage)
        }

        let rightPadding: CGFloat
        let currentRowNodes = allRows[currentRow]
        if currentNode == currentRowNodes.count - 1 {
            rightPadding = deviceLayout.horizontalGap
        } else {
            var totalWidth: CGFloat = 0
            var nodeIndex = currentNode + 1
            var ratio = 0.5
            var rightKey: Key?

            rightLoop: while nodeIndex < currentRowNodes.count {
                let node = currentRowNodes[nodeIndex]
                switch node {
                case .gap(let gapWidth):
                    totalWidth += gapWidth
                case .split(let splitWidth):
                    totalWidth += splitWidth
                case .key(let foundKey, _):
                    rightKey = foundKey
                    break rightLoop
                }
                nodeIndex += 1
            }

            // Check if both current and right key are simple
            if let currentChar = key.simpleCharacter,
               let rightKey = rightKey,
               let rightChar = rightKey.simpleCharacter,
               let frequencies = characterFrequencies {
                ratio = frequencies.frequencyRatio(currentChar, rightChar)
            }

            rightPadding = totalWidth * (ratio * (1.0 + 2.0 * hitboxOverage) - hitboxOverage)
        }

        var aboveRatio = 0.5
        var belowRatio = 0.5

        if let currentChar = key.simpleCharacter,
           let frequencies = characterFrequencies {
            if currentRow > 0 && currentNode < allRows[currentRow - 1].count {
                if case .key(let aboveKey, _) = allRows[currentRow - 1][currentNode],
                   let aboveChar = aboveKey.simpleCharacter {
                    aboveRatio = frequencies.frequencyRatio(currentChar, aboveChar)
                }
            }

            if currentRow < allRows.count - 1 && currentNode < allRows[currentRow + 1].count {
                if case .key(let belowKey, _) = allRows[currentRow + 1][currentNode],
                   let belowChar = belowKey.simpleCharacter {
                    belowRatio = frequencies.frequencyRatio(currentChar, belowChar)
                }
            }
        }

        let topPadding = deviceLayout.verticalGap * (aboveRatio * (1.0 + 2.0 * hitboxOverage) - hitboxOverage)
        let bottomPadding = deviceLayout.verticalGap * (belowRatio * (1.0 + 2.0 * hitboxOverage) - hitboxOverage)

        return CGRect(
            x: frame.origin.x - leftPadding,
            y: frame.origin.y - topPadding,
            width: frame.width + leftPadding + rightPadding,
            height: frame.height + topPadding + bottomPadding
        )
    }

    private func createRowKeyData(for row: [Node], rowIndex: Int, yOffset: CGFloat, startingIndex: Int, allRows: [[Node]]) -> [KeyData] {
        let containerWidth = view.bounds.width
        let rowWidth = Node.calculateRowWidth(for: row)
        let rowStartX = (containerWidth - rowWidth) / 2
        var xOffset: CGFloat = rowStartX
        var keys: [KeyData] = []

        for (nodeIndex, node) in row.enumerated() {
            switch node {
            case .key(let key, let keyWidth):
                let frame = CGRect(x: xOffset, y: yOffset, width: keyWidth, height: deviceLayout.keyHeight)
                _ = view.bounds.width > largeScreenWidth

                let debugColor: UIColor
                if rowIndex % 2 == 0 {
                    debugColor = keys.count % 2 == 0 ? UIColor.red.withAlphaComponent(0.4) : UIColor.blue.withAlphaComponent(0.4)
                } else {
                    debugColor = keys.count % 2 == 0 ? UIColor.green.withAlphaComponent(0.4) : UIColor.purple.withAlphaComponent(0.4)
                }

                let prevNode = row.indices.contains(nodeIndex - 1) ? row[nodeIndex - 1] : nil
                let nextNode = row.indices.contains(nodeIndex + 1) ? row[nodeIndex + 1] : nil

                let hitbox = calculateKeyHitbox(key: key, frame: frame, prevNode: prevNode, nextNode: nextNode, allRows: allRows, currentRow: rowIndex, currentNode: nodeIndex)

                let keyData = KeyData(
                    index: startingIndex + keys.count,
                    key: key,
                    viewFrame: frame,
                    hitbox: hitbox,
                    debugColor: debugColor
                )
                key.delegate = self
                keys.append(keyData)
                xOffset += keyWidth
            case .gap(let gapWidth):
                xOffset += gapWidth
            case .split(let splitWidth):
                xOffset += splitWidth
            }
        }

        return keys
    }





    private func handleKeyTouchDown(_ keyData: KeyData) {
        keyboardTouchView.setNeedsDisplay()

        // Provide haptic feedback for key press
        HapticFeedback.shared.keyPress(for: keyData.key, hasFullAccess: hasFullAccess)

        let isLargeScreen = view.bounds.width > largeScreenWidth
        if case .simple = keyData.key.keyType, !isLargeScreen {
            keyboardTouchView.keysWithPopouts.insert(keyData.index)
            showKeyPopout(for: keyData)
        }
    }

    private func handleKeyTouchUp(_ keyData: KeyData) {
        keyboardTouchView.setNeedsDisplay()

        keyboardTouchView.keysWithPopouts.remove(keyData.index)
        hideKeyPopout(for: keyData)

        // Stop key repeat if this key was repeating
        stopKeyRepeat()

        // Handle the key tap (only if it wasn't a long press that triggered repeat)
        if currentlyRepeatingKey == nil || currentlyRepeatingKey?.index != keyData.index {
            performKeyAction(keyData)
        }
    }

    private func handleKeyLongPress(_ keyData: KeyData) {
        // Check the key's long press behavior
        if let behavior = keyData.key.longPressBehavior {
            switch behavior {
            case .repeating:
                startKeyRepeat(for: keyData)
            case .alternates:
                // Alternates are handled by the gesture recognizer
                break
            }
        }
    }

    private func handleAlternateSelected(_ alternate: String, from keyData: KeyData) {
        // Handle smart punctuation for alternates
        let textToInsert: String
        if Key.shouldUnspacePunctuation(alternate) && maybePunctuating {
            textDocumentProxy.deleteBackward()
            let trailingSpace = Key.shouldAddTrailingSpaceAfterPunctuation(alternate) ? " " : ""
            textToInsert = alternate + trailingSpace
        } else {
            textToInsert = alternate
        }

        if Key.shouldTriggerAutocorrect(alternate) {
            Key.applyAutocorrectWithTrigger(text: textToInsert, to: textDocumentProxy, using: suggestionService, autocorrectWordDisabled: autocorrectWordDisabled, toggleAutocorrectWord: { [weak self] in
                self?.toggleAutocorrectWord()
            }, executeActions: { [weak self] actions in
                self?.executeActions(actions)
            })
        } else {
            textDocumentProxy.insertText(textToInsert)
        }

        // Auto-unshift after inserting alternate
        autoUnshift()

        refreshSuggestions()

        // Provide haptic feedback using the same system as regular key presses
        HapticFeedback.shared.keyPress(for: keyData.key, hasFullAccess: hasFullAccess)
    }

    private func handleKeyDoubleTap(_ keyData: KeyData) {
        guard let doubleTapBehavior = keyData.key.doubleTapBehavior else { return }

        switch doubleTapBehavior {
        case .capsLock:
            switch userShiftState {
            case .unshifted, .shifted:
                userShiftState = .capsLock
            case .capsLock:
                userShiftState = .unshifted
            }

            updateKeyboardForShiftChange()
        }
    }

    private func startKeyRepeat(for keyData: KeyData) {
        currentlyRepeatingKey = keyData

        // Perform the first repeat immediately
        performKeyAction(keyData)

        // Start the repeating timer
        keyRepeatTimer = Timer.scheduledTimer(withTimeInterval: keyRepeatInterval, repeats: true) { [weak self] _ in
            self?.performKeyAction(keyData)
        }
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
        currentlyRepeatingKey = nil
    }

    private func performKeyAction(_ keyData: KeyData) {
        keyData.key.didTap()

        // Provide haptic feedback for each repeat
        HapticFeedback.shared.keyPress(for: keyData.key, hasFullAccess: hasFullAccess)

        // Only reset maybePunctuating for keys that modify text content
        let shouldResetMaybePunctuating = keyData.key.shouldResetMaybePunctuating()
        if shouldResetMaybePunctuating {
            resetMaybePunctuating()
        }
        autoShift()
        refreshSuggestions()
    }

    private func effectiveShiftState() -> ShiftState {
        if userShiftOverride { return userShiftState }
        return max(appShiftState, userShiftState, backspaceShiftState)
    }

    func toggleShift() {
        if userShiftState == .unshifted && appShiftState != .unshifted {
            // User is toggling override of app's capitalization preference
            userShiftOverride.toggle()
        } else {
            // Normal shift toggle behavior
            switch userShiftState {
            case .unshifted:
                userShiftState = .shifted
            case .shifted:
                userShiftState = .unshifted
            case .capsLock:
                userShiftState = .unshifted
            }
        }

        updateKeyboardForShiftChange()
    }

    func autoUnshift() {
        switch userShiftState {
        case .unshifted:
            break
        case .shifted:
            userShiftState = .unshifted
            updateKeyboardForShiftChange()
        case .capsLock:
            // Caps lock should not auto-unshift
            break
        }

        // Always reset override after any key press that triggers auto-unshift
        userShiftOverride = false
    }

    func willHandleKeyTap() {
        charBeforeCursor = textDocumentProxy.documentContextBeforeInput?.last
        backspaceShiftState = .unshifted
    }

    func handleBackspace() {
        if let undoActions = undoActions {
            executeActions(undoActions)
            clearUndo()
        } else {
            backspaceShiftState = charBeforeCursor?.isUppercase == true ? .shifted : .unshifted
            charBeforeCursor = nil
            textDocumentProxy.deleteBackward()
            updateKeyboardForShiftChange()
        }
    }

    private func autoShift() {
        let beforeInput = textDocumentProxy.documentContextBeforeInput ?? ""

        // Update app shift state based on host app's autocapitalization setting
        switch textDocumentProxy.autocapitalizationType {
        case .some(.none):
            appShiftState = .unshifted
        case .some(.words), .some(.sentences), .some(.allCharacters):
            if beforeInput.isEmpty {
                appShiftState = .shifted
            } else {
                switch textDocumentProxy.autocapitalizationType {
                case .some(.words):
                    // Capitalize after any whitespace
                    appShiftState = beforeInput.last?.isWhitespace == true ? .shifted : .unshifted
                case .some(.sentences):
                    // Capitalize at start and after sentence endings
                    let sentenceEnders = [". ", "! ", "? ", "\n"]
                    appShiftState = sentenceEnders.contains { beforeInput.hasSuffix($0) } ? .shifted : .unshifted
                case .some(.allCharacters):
                    appShiftState = .capsLock
                default:
                    appShiftState = .unshifted
                }
            }
        case .some(_):
            appShiftState = .unshifted
        case nil:
            appShiftState = .unshifted
        }

        updateKeyboardForShiftChange()
    }

    func switchToLayer(_ layer: Layer) {
        currentLayer = layer
        rebuildKeyboard()
    }

    func switchToLayout(_ layout: KeyboardLayout) {
        keyboardLayout = layout
        currentLayer = .alpha
        rebuildKeyboard()
    }

    private func setupEditingBar() {
        editingBarView = EditingBarView(
            deviceLayout: deviceLayout,
            keyboardLayout: keyboardLayout,
            currentLayer: currentLayer,
            needsGlobe: needsGlobe
        )

        editingBarView.delegate = self
        editingBarView.setDebugVisualizationEnabled(debugVisualizationEnabled)

        UIView.performWithoutAnimation {
            view.addSubview(editingBarView)
            editingBarView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: deviceLayout.topPadding - deviceLayout.verticalGap / 2)
            editingBarView.updateLayout(for: effectiveShiftState(), containerWidth: view.bounds.width)
        }
    }

    private func setupSuggestionView() {
        suggestionView = SuggestionView(deviceLayout: deviceLayout)
        suggestionService.delegate = self

        suggestionView.setOnTypeaheadTapped { [weak self] actions in
            self?.executeActions(actions)
            self?.autoShift()
            self?.refreshSuggestions()
        }

        suggestionView.setOnAutocorrectToggle { [weak self] in
            self?.toggleAutocorrectWord()
        }

        view.addSubview(suggestionView)
        suggestionView.setDebugVisualizationEnabled(debugVisualizationEnabled)

        let suggestionY: CGFloat = 0
        let suggestionHeight = deviceLayout.topPadding - deviceLayout.verticalGap / 2

        // Calculate available space for suggestions
        let containerWidth = view.bounds.width
        let suggestionArea = editingBarView.calculateSuggestionArea(for: effectiveShiftState(), containerWidth: containerWidth)

        suggestionView.frame = CGRect(x: suggestionArea.x, y: suggestionY, width: suggestionArea.width, height: suggestionHeight)
    }

    private func resetMaybePunctuating() {
        maybePunctuating = false
    }

    func clearUndo() {
        undoActions = nil
        keyboardTouchView?.hasUndo = false
        keyboardTouchView?.setNeedsDisplay()
    }

    private func handleTextChange() {
        clearUndo()
        resetMaybePunctuating()
        autoShift()
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        guard !pendingRefresh else { return }
        pendingRefresh = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingRefresh = false

            let before = self.textDocumentProxy.documentContextBeforeInput
            let after = self.textDocumentProxy.documentContextAfterInput
            let selected = self.textDocumentProxy.selectedText

            self.suggestionService.updateContext(before: before, after: after, selected: selected, autocorrectEnabled: !autocorrectAppDisabled && !autocorrectUserDisabled, shiftState: effectiveShiftState())
        }
    }

    func executeActions(_ actions: [InputAction]) {
        var buildingUndoActions: [InputAction] = []

        buildingUndoActions.append(.maybePunctuating(maybePunctuating))

        for action in actions {
            switch action {
            case .insert(let text):
                for _ in 0..<text.count {
                    buildingUndoActions.append(.deleteBackward)
                }
                textDocumentProxy.insertText(text)
            case .moveCursor(let offset):
                buildingUndoActions.append(.moveCursor(-offset))
                if offset > 0 {
                    for _ in 0..<offset {
                        textDocumentProxy.adjustTextPosition(byCharacterOffset: 1)
                    }
                } else if offset < 0 {
                    for _ in 0..<(-offset) {
                        textDocumentProxy.adjustTextPosition(byCharacterOffset: -1)
                    }
                }
            case .maybePunctuating(let value):
                // Don't add undo action here - we captured initial state above
                maybePunctuating = value
            case .deleteBackward:
                if let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty {
                    let deletedChar = String(before.last!)
                    buildingUndoActions.append(.insert(deletedChar))
                }
                textDocumentProxy.deleteBackward()
            }
        }

        undoActions = Array(buildingUndoActions.reversed())

        keyboardTouchView?.hasUndo = true
        keyboardTouchView?.setNeedsDisplay()
    }


    private func updateKeyboardForShiftChange() {
        let effectiveShiftState = effectiveShiftState()

        // Only update if the effective shift state has actually changed
        if keyboardTouchView.shiftState == effectiveShiftState {
            return
        }

        // Update display state and key data - gesture recognizer persists now
        keyboardTouchView.shiftState = effectiveShiftState
        keyboardTouchView.autocorrectEnabled = !autocorrectUserDisabled
        keyboardTouchView.showHitboxDebug = debugVisualizationEnabled
        keyboardTouchView.hasUndo = undoActions != nil
        keyboardTouchView.characterFrequencies = characterFrequencies
        keyboardTouchView.keyData = createKeyData()
        keyboardTouchView.setNeedsDisplay()

        editingBarView.updateLayout(for: effectiveShiftState, containerWidth: view.bounds.width)
    }

    private func rebuildKeyboard() {
        stopKeyRepeat()
        UIView.performWithoutAnimation {
            view.subviews.forEach { $0.removeFromSuperview() }
            keyPopouts.removeAll()
            setupKeyboard()
        }
    }

    private func showKeyPopout(for keyData: KeyData) {
        let popout = KeyPopoutView.createPopout(for: keyData, shiftState: effectiveShiftState(), containerView: view, traitCollection: traitCollection, deviceLayout: deviceLayout)
        view.addSubview(popout)
        keyPopouts[keyData.index] = popout
    }

    private func showAlternatesPopup(for keyData: KeyData, alternates: [String]) {
        // Hide any existing popout for this key
        hideKeyPopout(for: keyData)

        // Show the alternates popup via the touch view
        keyboardTouchView.showAlternatesPopup(for: keyData, alternates: alternates)
    }

    private func hideKeyPopout(for keyData: KeyData) {
        guard let popout = keyPopouts[keyData.index] else { return }
        popout.removeFromSuperview()
        keyPopouts.removeValue(forKey: keyData.index)
    }



    // MARK: - UITextInputDelegate

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        backspaceShiftState = .unshifted
        updateAutocorrectSettings()
        handleTextChange()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        handleTextChange()
    }

    // MARK: - Autocorrect Detection

    private func updateAutocorrectSettings() {
        // Check the host app's autocorrect setting
        let hostDisablesAutocorrect = (textDocumentProxy.autocorrectionType == .no)

        // Disable autocorrect if the host app explicitly disables it
        // This covers SSH apps, password fields, code editors, and other contexts where text correction is unwanted
        if hostDisablesAutocorrect {
            disableAutocorrect()
        } else {
            // Regular text input contexts where autocorrect is welcome
            enableAutocorrect()
        }
    }

    private func disableAutocorrect() {
        autocorrectAppDisabled = true
        refreshSuggestions()
    }

    private func enableAutocorrect() {
        autocorrectAppDisabled = false
        refreshSuggestions()
    }

    func toggleAutocorrectWord() {
        autocorrectWordDisabled.toggle()
        suggestionView.setAutocorrectWordDisabled(autocorrectWordDisabled)
    }

    func handleConfiguration(_ config: Configuration) {
        switch config {
        case .toggleAutocorrect:
            autocorrectUserDisabled.toggle()
            keyboardTouchView?.autocorrectEnabled = !autocorrectUserDisabled
            keyboardTouchView?.setNeedsDisplay()
            refreshSuggestions()
        case .toggleDebugVisualization:
            debugVisualizationEnabled.toggle()
            keyboardTouchView?.showHitboxDebug = debugVisualizationEnabled
            editingBarView?.setDebugVisualizationEnabled(debugVisualizationEnabled)
            suggestionView?.setDebugVisualizationEnabled(debugVisualizationEnabled)
            keyboardTouchView?.setNeedsDisplay()
        }
    }

    private func updateKeyHitboxes() {
        let isShifted: Bool
        switch effectiveShiftState() {
        case .unshifted:
            isShifted = false
        case .shifted, .capsLock:
            isShifted = true
        }
        let allRows = keyboardLayout.nodeRows(for: currentLayer, shifted: isShifted, layout: deviceLayout, needsGlobe: needsGlobe)

        for (keyIndex, keyData) in keyboardTouchView.keyData.enumerated() {
            // Find the row and node indices for this key
            var currentRow = 0
            var currentNode = 0
            var keysProcessed = 0

            outerLoop: for (rowIndex, row) in allRows.enumerated() {
                for (nodeIndex, node) in row.enumerated() {
                    if case .key(_, _) = node {
                        if keysProcessed == keyIndex {
                            currentRow = rowIndex
                            currentNode = nodeIndex
                            break outerLoop
                        }
                        keysProcessed += 1
                    }
                }
            }

            let prevNode = currentNode > 0 ? allRows[currentRow][currentNode - 1] : nil
            let nextNode = currentNode < allRows[currentRow].count - 1 ? allRows[currentRow][currentNode + 1] : nil

            keyboardTouchView.keyData[keyIndex].hitbox = calculateKeyHitbox(
                key: keyData.key,
                frame: keyData.viewFrame,
                prevNode: prevNode,
                nextNode: nextNode,
                allRows: allRows,
                currentRow: currentRow,
                currentNode: currentNode
            )
        }

        keyboardTouchView.setNeedsDisplay()
    }

    // MARK: - SuggestionServiceDelegate

    func suggestionService(_ service: SuggestionService, didUpdateSuggestions typeahead: [(String, [InputAction])], autocorrect: String?, frequencies: CharacterDistribution) {
        characterFrequencies = frequencies
        keyboardTouchView?.characterFrequencies = characterFrequencies
        updateKeyHitboxes()
        suggestionView.suggestionService(service, didUpdateSuggestions: typeahead, autocorrect: autocorrect, frequencies: frequencies)
    }

    // MARK: - EditingBarViewDelegate

    func editingBarDismiss() {
        dismissKeyboard()
    }

    func editingBarCut() {
        if let selectedText = textDocumentProxy.selectedText, !selectedText.isEmpty {
            UIPasteboard.general.string = selectedText
            textDocumentProxy.deleteBackward()
            handleTextChange()
        }
    }

    func editingBarCopy() {
        if let selectedText = textDocumentProxy.selectedText, !selectedText.isEmpty {
            UIPasteboard.general.string = selectedText
        }
    }

    func editingBarPaste() {
        if let pasteText = UIPasteboard.general.string {
            textDocumentProxy.insertText(pasteText)
            handleTextChange()
        }
    }
}
