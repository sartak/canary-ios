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
    private var cachedSuggestions: (typeaheads: [(String, [InputAction])], autocorrect: String?)?
    var suggestionService: SuggestionService = SuggestionService()!
    private var pendingRefresh = false
    var maybePunctuating = false
    private var autocorrectAppDisabled = false
    private var autocorrectUserDisabled = UserDefaults.standard.bool(forKey: "autocorrectUserDisabled")
    var autocorrectWordDisabled = false
    var undoActions: [InputAction]?
    private var debugVisualizationEnabled = UserDefaults.standard.bool(forKey: "debugVisualizationEnabled")

    /// Local usage/correction log (Milestone 9). Logging only — no typing
    /// behavior changes based on it. Created eagerly (cheap — resolves a path);
    /// the database opens lazily on the first write.
    let usageStore = UsageStore()
    /// Context of the most recent swipe commit, kept alive so a subsequent
    /// suggestion-bar tap can be logged as a swipe correction. Cleared eagerly
    /// on any other text-changing action.
    private var pendingSwipeContext: PendingSwipeContext?

    private struct PendingSwipeContext {
        let path: [CGPoint]
        let committed: String
        /// Decoder's ranked words, committed first.
        let ranked: [String]
        let layout: String
        let keyboardSize: CGSize
        let keyPitch: CGFloat
    }

    private var lastSwipePath: [CGPoint] = []
    private var lastLiveDecodeTime: CFAbsoluteTime = 0
    /// Swipe-only mode (configuration key on the number layer, like
    /// the debug toggle), persisted across sessions: letter keys become
    /// tap-inert so entering letters requires swiping — for unlearning tap
    /// muscle memory. Swiping itself is always available on the alpha layer.
    private var swipeOnlyModeEnabled = UserDefaults.standard.bool(forKey: "swipeOnlyMode")
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

    private var screen: UIScreen {
        view.window!.windowScene!.screen
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // iOS-provided personal vocabulary (contact names, single-word text
        // replacements) joins the personal dictionary for this session. iOS
        // owns the source, so it is re-fetched each launch, never persisted.
        // The completion can arrive off the main queue.
        requestSupplementaryLexicon { [weak self] lexicon in
            let words = lexicon.entries.map { $0.documentText }
            DispatchQueue.main.async {
                self?.suggestionService.setSupplementaryLexicon(words: words)
            }
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        print("KeyboardViewController: memory warning — releasing caches")
        usageStore?.releaseMemory()
        suggestionService.releaseMemory()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // The containing app may have edited the shared dictionary while this
        // process was alive; start the session on its version of the truth.
        usageStore?.invalidateCaches()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (traitEnvironment: UITraitEnvironment, previousTraitCollection: UITraitCollection) in
            self?.keyboardTouchView?.setNeedsDisplay()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let currentBounds = view.bounds
        let screenBounds = screen.bounds

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
        let screenBounds = screen.bounds
        let viewBounds = view.bounds
        let isLandscape = screenBounds.width > screenBounds.height

        let effectiveWidth = viewBounds.width
        let effectiveHeight = isLandscape ? screenBounds.width : screenBounds.height

        deviceLayout = DeviceLayout.forCurrentDevice(containerWidth: effectiveWidth, containerHeight: effectiveHeight)

        keyboardTouchView = KeyboardTouchView()
        keyboardTouchView.backgroundColor = UIColor.clear
        keyboardTouchView.shiftState = effectiveShiftState()
        keyboardTouchView.deviceLayout = deviceLayout
        keyboardTouchView.gestureRecognizer.deviceLayout = deviceLayout
        keyboardTouchView.gestureRecognizer.swipeEnabled = (currentLayer == .alpha)
        keyboardTouchView.swipeOnlyActive = swipeOnlyEffective
        keyboardTouchView.swipeOnlyToggleOn = swipeOnlyModeEnabled
        keyboardTouchView.autocorrectEnabled = !autocorrectUserDisabled

        // Swipe-only mode announces itself with a shimmer whenever the alpha
        // layer appears (launch, layer switch back, rebuild).
        if swipeOnlyEffective {
            // A sliver of delay so the sweep starts after the first frame is
            // on screen rather than burning its opening mid-layout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.keyboardTouchView?.playSwipeShimmer()
            }
        }
        keyboardTouchView.showHitboxDebug = debugVisualizationEnabled
        keyboardTouchView.showDebugSwipePath = debugVisualizationEnabled && (currentLayer == .alpha)
        if debugVisualizationEnabled {
            keyboardTouchView.setDebugSwipePath(lastSwipePath)
        }
        keyboardTouchView.characterFrequencies = characterFrequencies
        keyboardTouchView.keyData = createKeyData()
        keyboardTouchView.setNeedsDisplay()
        pushKeyGeometryIfAlpha()

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

        keyboardTouchView.gestureRecognizer.onSwipeStarted = { [weak self] keyData in
            self?.lastSwipePath.removeAll()
            self?.restoreKeyDisplay(for: keyData)
        }

        keyboardTouchView.gestureRecognizer.onSwipePathUpdated = { [weak self] in
            guard let self = self else { return }
            if self.keyboardTouchView.showHitboxDebug {
                let pathPoints = self.keyboardTouchView.gestureRecognizer.currentSwipePathPoints
                if !pathPoints.isEmpty {
                    self.keyboardTouchView.setDebugSwipePath(pathPoints)
                }
            }
            self.keyboardTouchView.setNeedsDisplay()
        }

        keyboardTouchView.gestureRecognizer.onSwipeProgressed = { [weak self] path in
            guard let self = self, !path.isEmpty else { return }
            // Throttle live decodes; the path array is always read fresh.
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastLiveDecodeTime >= SwipeTuning.liveDecodeInterval else { return }
            self.lastLiveDecodeTime = now

            let suggestions = self.suggestionService.liveSwipeSuggestions(
                path: path,
                keyCenters: self.currentKeyCenters(),
                keyPitch: self.keyPitch,
                shiftState: self.effectiveShiftState()
            )
            self.suggestionView.setSuggestions(typeaheads: suggestions, autocorrect: nil)
        }

        keyboardTouchView.gestureRecognizer.onSwipeEnded = { [weak self] pathPoints in
            guard let self = self else { return }
            self.lastSwipePath = pathPoints
            if self.keyboardTouchView.showHitboxDebug {
                self.keyboardTouchView.setDebugSwipePath(pathPoints)
            }
            self.handleSwipeEnded(pathPoints)
        }

        keyboardTouchView.onNeedsKeyData = { [weak self] in
            guard let self = self else { return }
            let containerWidth = self.keyboardTouchView.bounds.width

            // Recreate deviceLayout with correct bounds
            let screenBounds = self.screen.bounds
            let isLandscape = screenBounds.width > screenBounds.height
            let effectiveHeight = isLandscape ? screenBounds.width : screenBounds.height
            self.deviceLayout = DeviceLayout.forCurrentDevice(containerWidth: containerWidth, containerHeight: effectiveHeight)
            self.keyboardTouchView.deviceLayout = self.deviceLayout
            self.keyboardTouchView.gestureRecognizer.deviceLayout = self.deviceLayout

            self.keyboardTouchView.keyData = self.createKeyData()
            self.keyboardTouchView.setNeedsDisplay()

            // Update editing bar and suggestion view if they exist
            if let editingBarView = self.editingBarView {
                editingBarView.deviceLayout = self.deviceLayout
                editingBarView.frame = CGRect(x: 0, y: 0, width: containerWidth, height: self.deviceLayout.topPadding - self.deviceLayout.verticalGap / 2)
                editingBarView.updateLayout(for: self.effectiveShiftState(), containerWidth: containerWidth)

                if let suggestionView = self.suggestionView {
                    suggestionView.deviceLayout = self.deviceLayout
                    let suggestionArea = editingBarView.calculateSuggestionArea(for: self.effectiveShiftState(), containerWidth: containerWidth)
                    suggestionView.frame = CGRect(x: suggestionArea.x, y: 0, width: suggestionArea.width, height: self.deviceLayout.topPadding - self.deviceLayout.verticalGap / 2)
                }
            }
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
        let containerWidth = keyboardTouchView?.bounds.width ?? view.bounds.width
        let rowWidth = Node.calculateRowWidth(for: row)
        let rowStartX = (containerWidth - rowWidth) / 2
        var xOffset: CGFloat = rowStartX
        var keys: [KeyData] = []

        for (nodeIndex, node) in row.enumerated() {
            switch node {
            case .key(let key, let keyWidth):
                let frame = CGRect(x: xOffset, y: yOffset, width: keyWidth, height: deviceLayout.keyHeight)
                _ = containerWidth > largeScreenWidth

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





    /// Whether swipe-only mode is in force right now: the toggle, on the
    /// alpha layer, in a field where the host allows autocorrection. Fields
    /// that disable it (terminals, code editors) aren't natural language —
    /// bash pipelines can't be swiped — so the tap block lifts there and the
    /// dim lifts with it; the toggle itself stays on for normal fields.
    private var swipeOnlyEffective: Bool {
        swipeOnlyModeEnabled && currentLayer == .alpha && !autocorrectAppDisabled
    }

    /// In swipe-only mode, letter keys are tap-inert: entering
    /// letters requires swiping (the mode exists to unlearn tap muscle
    /// memory). Everything a swipe can't produce — space, backspace, shift,
    /// enter, layers, apostrophe, and long-press alternates — still works.
    private func isTapBlocked(_ keyData: KeyData) -> Bool {
        guard swipeOnlyEffective,
              case .simple(let text) = keyData.key.keyType,
              let first = text.lowercased().first, first.isLetter else {
            return false
        }
        return true
    }

    private func handleKeyTouchDown(_ keyData: KeyData) {
        if keyboardTouchView.showHitboxDebug {
            keyboardTouchView.clearDebugSwipePath()
        }
        keyboardTouchView.setNeedsDisplay()

        // Tap-inert keys give no press feedback: the silence is the signal.
        if isTapBlocked(keyData) { return }

        // Provide haptic feedback for key press
        HapticFeedback.shared.keyPress(for: keyData.key, hasFullAccess: hasFullAccess)

        let isLargeScreen = view.bounds.width > largeScreenWidth
        if case .simple = keyData.key.keyType, !isLargeScreen {
            keyboardTouchView.keysWithPopouts.insert(keyData.index)
            showKeyPopout(for: keyData)
        }
    }

    private func handleKeyTouchUp(_ keyData: KeyData) {
        restoreKeyDisplay(for: keyData)

        // Stop key repeat if this key was repeating
        stopKeyRepeat()

        if isTapBlocked(keyData) { return }

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
        clearPendingSwipeContext()
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
        // Any physical key tap abandons the just-swiped word for logging purposes.
        clearPendingSwipeContext()
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

    /// Key centers of the CURRENT key layout's simple-character keys, keyed by
    /// the key's lowercased character. Swipes are only enabled on the alpha
    /// layer, so the current keyData is the alpha layer whenever this runs.
    private func currentKeyCenters() -> KeyCenters {
        var centers: [Character: CGPoint] = [:]
        for keyData in keyboardTouchView.keyData {
            guard let character = keyData.key.simpleCharacter,
                  let lowered = character.lowercased().first else { continue }
            let frame = keyData.viewFrame
            centers[lowered] = CGPoint(x: frame.midX, y: frame.midY)
        }
        return KeyCenters(centers: centers)
    }

    private var keyPitch: CGFloat {
        deviceLayout.alphaKeyWidth + deviceLayout.horizontalGap
    }

    private var layoutName: String {
        switch keyboardLayout {
        case .canary: return "canary"
        case .qwerty: return "qwerty"
        }
    }

    /// Discards the stashed swipe context. Called eagerly whenever the text
    /// context changes for a reason other than a swipe-replacement tap, so a
    /// stale swipe is never mislogged as a correction.
    private func clearPendingSwipeContext() {
        pendingSwipeContext = nil
    }

    /// Logs a suggestion-bar tap: a swipe correction when it replaces a
    /// just-swiped word, otherwise a plain typeahead pick.
    private func recordSuggestionTap(word: String) {
        if let context = pendingSwipeContext {
            if word != context.committed && context.ranked.contains(word) {
                usageStore?.recordSwipeCorrection(
                    path: context.path, committed: context.committed, corrected: word,
                    ranked: context.ranked, layout: context.layout,
                    keyboardSize: context.keyboardSize, keyPitch: context.keyPitch
                )
            }
        } else {
            usageStore?.recordTapEvent(kind: .suggestionPicked, typed: suggestionService.lastTypedWord, resolved: word)
        }
        clearPendingSwipeContext()
    }

    /// Logs an autocorrect rejection when the user taps the bar's autocorrect
    /// preview to opt out (i.e. a pending correction is currently enabled).
    private func recordAutocorrectRejectionIfNeeded() {
        guard !autocorrectWordDisabled, let correction = suggestionService.autocorrectSuggestion else { return }
        usageStore?.recordTapEvent(kind: .autocorrectRejected, typed: suggestionService.lastTypedWord, resolved: correction)
        // Fast-track: one rejection learns the defended word immediately.
        suggestionService.learnRejectedWord()
    }

    private func handleSwipeEnded(_ path: [CGPoint]) {
        let shiftState = effectiveShiftState()
        guard let result = suggestionService.decodeSwipe(
            path: path,
            keyCenters: currentKeyCenters(),
            keyPitch: keyPitch,
            shiftState: shiftState
        ) else {
            return
        }

        executeActions(result.actions)
        autoShift()

        // Milestone 9: count the commit and stash context so a following
        // suggestion-bar tap can be logged as a swipe correction.
        usageStore?.recordSwipeCommit()
        // Swiped words never pass through the type-a-boundary word-commit
        // transition (nothing was typed), so bump personal usage explicitly.
        // Their casing comes from stored casing + shift state, not from the
        // user's fingers — count the use, don't treat it as casing evidence.
        suggestionService.recordCommittedWord(result.word, trustCasing: false)
        pendingSwipeContext = PendingSwipeContext(
            path: path,
            committed: result.word,
            ranked: [result.word] + result.replacements.map { $0.0 },
            layout: layoutName,
            keyboardSize: keyboardTouchView.bounds.size,
            keyPitch: keyPitch
        )

        // Show replacement suggestions (tapping replaces the inserted word).
        // Replacements already exclude the committed word.
        suggestionView.setSuggestions(typeaheads: result.replacements, autocorrect: nil)

        // Debug overlay: draw the top candidates' ideal template polylines.
        if keyboardTouchView.showDebugSwipePath {
            keyboardTouchView.setDebugTemplatePaths(result.debugTemplatePaths)
        }
    }

    func switchToLayer(_ layer: Layer) {
        clearPendingSwipeContext()
        currentLayer = layer
        rebuildKeyboard()
    }

    func switchToLayout(_ layout: KeyboardLayout) {
        clearPendingSwipeContext()
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
        suggestionService.usageStore = usageStore

        suggestionView.setOnTypeaheadTapped { [weak self] word, actions in
            guard let self = self else { return }
            self.executeActions(actions)
            self.autoShift()
            self.recordSuggestionTap(word: word)
            self.refreshSuggestions()
        }

        suggestionView.setOnAutocorrectToggle { [weak self] in
            guard let self = self else { return }
            if !self.suggestionService.autocorrectAutoApplies,
               let actions = self.suggestionService.autocorrectActions {
                // Mid-word proposals are never auto-applied; tapping the slot
                // APPLIES them (whole-word replacement around the cursor).
                self.suggestionService.noteAutocorrectApplied()
                self.executeActions(actions)
                self.refreshSuggestions()
            } else {
                self.recordAutocorrectRejectionIfNeeded()
                self.toggleAutocorrectWord()
            }
        }

        view.addSubview(suggestionView)
        suggestionView.setDebugVisualizationEnabled(debugVisualizationEnabled)

        let suggestionY: CGFloat = 0
        let suggestionHeight = deviceLayout.topPadding - deviceLayout.verticalGap / 2

        // Calculate available space for suggestions
        let containerWidth = view.bounds.width
        let suggestionArea = editingBarView.calculateSuggestionArea(for: effectiveShiftState(), containerWidth: containerWidth)

        suggestionView.frame = CGRect(x: suggestionArea.x, y: suggestionY, width: suggestionArea.width, height: suggestionHeight)

        // Populate with cached suggestions immediately (avoids flicker on layer switch)
        if let cached = cachedSuggestions {
            suggestionView.setSuggestions(typeaheads: cached.typeaheads, autocorrect: cached.autocorrect)
        }
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

            self.suggestionService.updateContext(before: before, after: after, selected: selected, autocorrectEnabled: !autocorrectAppDisabled && !autocorrectUserDisabled, learningEnabled: !autocorrectAppDisabled, shiftState: effectiveShiftState())
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
        pushKeyGeometryIfAlpha()

        editingBarView.updateLayout(for: effectiveShiftState, containerWidth: view.bounds.width)

        // Suggestions were capitalized under the previous shift state; recompute
        // so the bar reflects e.g. a caps-lock toggle immediately.
        refreshSuggestions()
    }

    /// Keeps SuggestionService's letter-key geometry current for correction
    /// ranking. Only the alpha layer's keyData maps letters to centers; other
    /// layers keep the last alpha geometry.
    private func pushKeyGeometryIfAlpha() {
        guard currentLayer == .alpha else { return }
        suggestionService.updateKeyGeometry(keyCenters: currentKeyCenters(), keyPitch: keyPitch)
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
        restoreKeyDisplay(for: keyData)

        // Show the alternates popup via the touch view
        keyboardTouchView.showAlternatesPopup(for: keyData, alternates: alternates)
    }

    private func restoreKeyDisplay(for keyData: KeyData) {
        keyboardTouchView.keysWithPopouts.remove(keyData.index)
        if let popout = keyPopouts.removeValue(forKey: keyData.index) {
            popout.removeFromSuperview()
        }
        keyboardTouchView.setNeedsDisplay()
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
        keyboardTouchView?.swipeOnlyActive = swipeOnlyEffective
        refreshSuggestions()
    }

    private func enableAutocorrect() {
        autocorrectAppDisabled = false
        keyboardTouchView?.swipeOnlyActive = swipeOnlyEffective
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
            UserDefaults.standard.set(autocorrectUserDisabled, forKey: "autocorrectUserDisabled")
            keyboardTouchView?.autocorrectEnabled = !autocorrectUserDisabled
            keyboardTouchView?.setNeedsDisplay()
            refreshSuggestions()
        case .toggleDebugVisualization:
            debugVisualizationEnabled.toggle()
            UserDefaults.standard.set(debugVisualizationEnabled, forKey: "debugVisualizationEnabled")
            keyboardTouchView?.showHitboxDebug = debugVisualizationEnabled
            keyboardTouchView?.showDebugSwipePath = debugVisualizationEnabled && (currentLayer == .alpha)
            editingBarView?.setDebugVisualizationEnabled(debugVisualizationEnabled)
            suggestionView?.setDebugVisualizationEnabled(debugVisualizationEnabled)
            if debugVisualizationEnabled {
                keyboardTouchView?.setDebugSwipePath(lastSwipePath)
            }
            keyboardTouchView?.setNeedsDisplay()
        case .toggleSwipeOnly:
            swipeOnlyModeEnabled.toggle()
            print("KeyboardViewController: swipe-only mode toggled \(swipeOnlyModeEnabled ? "ON" : "OFF") (layer: \(currentLayer))")
            UserDefaults.standard.set(swipeOnlyModeEnabled, forKey: "swipeOnlyMode")
            keyboardTouchView?.swipeOnlyActive = swipeOnlyEffective
            keyboardTouchView?.swipeOnlyToggleOn = swipeOnlyModeEnabled
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
        cachedSuggestions = (typeahead, autocorrect)
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
        guard hasFullAccess else {
            editingBarView.flashError(for: .cut)
            return
        }
        if let selectedText = textDocumentProxy.selectedText, !selectedText.isEmpty {
            UIPasteboard.general.string = selectedText
            textDocumentProxy.deleteBackward()
            handleTextChange()
            editingBarView.flashSuccess(for: .cut)
        }
    }

    func editingBarCopy() {
        guard hasFullAccess else {
            editingBarView.flashError(for: .copy)
            return
        }
        if let selectedText = textDocumentProxy.selectedText, !selectedText.isEmpty {
            UIPasteboard.general.string = selectedText
            editingBarView.flashSuccess(for: .copy)
        }
    }

    func editingBarPaste() {
        guard hasFullAccess else {
            editingBarView.flashError(for: .paste)
            return
        }
        if let pasteText = UIPasteboard.general.string {
            textDocumentProxy.insertText(pasteText)
            handleTextChange()
            editingBarView.flashSuccess(for: .paste)
        }
    }
}
