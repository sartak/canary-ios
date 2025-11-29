//
//  Key.swift
//  Keyboard
//
//  Created by Shawn Moore on 7/29/25.
//

import UIKit

protocol KeyActionDelegate: AnyObject {
    var textDocumentProxy: UITextDocumentProxy { get }
    var suggestionService: SuggestionService { get }
    var maybePunctuating: Bool { get }
    var autocorrectWordDisabled: Bool { get }
    var undoActions: [InputAction]? { get }

    func switchToLayer(_ layer: Layer)
    func switchToLayout(_ layout: KeyboardLayout)
    func toggleShift()
    func autoUnshift()
    func willHandleKeyTap()
    func handleBackspace()
    func advanceToNextInputMode()
    func handleConfiguration(_ config: Configuration)
    func toggleAutocorrectWord()
    func executeActions(_ actions: [InputAction])
    func clearUndo()
}

enum ShiftState: Equatable, Comparable {
    case unshifted
    case shifted
    case capsLock

    static func < (lhs: ShiftState, rhs: ShiftState) -> Bool {
        switch (lhs, rhs) {
        case (.unshifted, .shifted), (.unshifted, .capsLock):
            return true
        case (.shifted, .capsLock):
            return true
        default:
            return false
        }
    }
}

enum RepeatingBehavior: Equatable {
    case repeating
}

enum LongPressBehavior: Equatable {
    case repeating
    case alternates([String])
}

enum DoubleTapBehavior: Equatable {
    case capsLock
}

enum FeedbackPattern: Equatable {
    case subtle
    case light
    case selection
    case none
}

enum Configuration: Equatable {
    case toggleAutocorrect
    case toggleDebugVisualization
}

enum KeyType: Equatable {
    case simple(String)
    case backspace
    case shift
    case enter
    case space
    case layerSwitch(Layer)
    case layoutSwitch(KeyboardLayout)
    case globe
    case configuration(Configuration)
    case empty
}

class Key {
    let keyType: KeyType
    let longPressBehavior: LongPressBehavior?
    let doubleTapBehavior: DoubleTapBehavior?
    weak var delegate: KeyActionDelegate?

    init(_ keyType: KeyType, longPressBehavior: LongPressBehavior? = nil, doubleTapBehavior: DoubleTapBehavior? = nil) {
        self.keyType = keyType
        self.longPressBehavior = longPressBehavior
        self.doubleTapBehavior = doubleTapBehavior
    }

    static func shouldUnspacePunctuation(_ text: String) -> Bool {
        let unspacingCharacters: Set<Character> = [".", ",", "!", "?", ":", ";", ")", "]", "}", "'", "\"", "—", "…"]
        return text.count == 1 && unspacingCharacters.contains(text.first!)
    }

    static func shouldAddTrailingSpaceAfterPunctuation(_ text: String) -> Bool {
        let noTrailingSpaceCharacters: Set<Character> = ["—"]
        return !(text.count == 1 && noTrailingSpaceCharacters.contains(text.first!))
    }

    var simpleCharacter: Character? {
        if case .simple(let text) = keyType, text.count == 1 {
            return text.first
        }
        return nil
    }

    static func shouldTriggerAutocorrect(_ text: String) -> Bool {
        // Trigger autocorrect for punctuation that ends words, but not for apostrophe
        // since apostrophe may be part of contractions that aren't complete yet
        let autocorrectTriggers: Set<Character> = [".", ",", "!", "?", ":", ";", ")", "]", "}", "\"", "—", "…"]
        return text.count == 1 && autocorrectTriggers.contains(text.first!)
    }

    static func applyAutocorrect(to textDocumentProxy: UITextDocumentProxy, using suggestionService: SuggestionService, autocorrectWordDisabled: Bool, toggleAutocorrectWord: @escaping () -> Void, executeActions: @escaping ([InputAction]) -> Void) {
        if autocorrectWordDisabled {
            toggleAutocorrectWord()
        } else {
            if let actions = suggestionService.autocorrectActions {
                executeActions(actions)
            }
        }
    }

    static func applyAutocorrectWithTrigger(text: String, to textDocumentProxy: UITextDocumentProxy, using suggestionService: SuggestionService, autocorrectWordDisabled: Bool, toggleAutocorrectWord: @escaping () -> Void, executeActions: @escaping ([InputAction]) -> Void) {
        if autocorrectWordDisabled {
            toggleAutocorrectWord()
            textDocumentProxy.insertText(text)
        } else {
            if let autocorrectActions = suggestionService.autocorrectActions {
                // Combine autocorrect actions with triggering character insertion
                var combinedActions = autocorrectActions
                combinedActions.append(.insert(text))
                executeActions(combinedActions)
            } else {
                // No autocorrect, just insert the character
                textDocumentProxy.insertText(text)
            }
        }
    }

    func didTap() {
        guard let delegate = delegate else { return }

        delegate.willHandleKeyTap()

        // Clear undo state before handling any key (except when backspace uses undo)
        if case .backspace = keyType, delegate.undoActions != nil {
            // Don't clear undo yet - backspace will use it
        } else {
            delegate.clearUndo()
        }

        // Handle the key action
        switch keyType {
        case .simple(let text):
            // Handle spacing for punctuation first
            if Key.shouldUnspacePunctuation(text) {
                if delegate.maybePunctuating {
                    delegate.textDocumentProxy.deleteBackward()
                }
                let trailingSpace = (delegate.maybePunctuating && Key.shouldAddTrailingSpaceAfterPunctuation(text)) ? " " : ""
                let fullText = text + trailingSpace

                // Check if this character should trigger autocorrect
                if Key.shouldTriggerAutocorrect(text) {
                    Key.applyAutocorrectWithTrigger(text: fullText, to: delegate.textDocumentProxy, using: delegate.suggestionService, autocorrectWordDisabled: delegate.autocorrectWordDisabled, toggleAutocorrectWord: delegate.toggleAutocorrectWord, executeActions: delegate.executeActions)
                } else {
                    delegate.textDocumentProxy.insertText(fullText)
                }
            } else {
                // Check if this character should trigger autocorrect
                if Key.shouldTriggerAutocorrect(text) {
                    Key.applyAutocorrectWithTrigger(text: text, to: delegate.textDocumentProxy, using: delegate.suggestionService, autocorrectWordDisabled: delegate.autocorrectWordDisabled, toggleAutocorrectWord: delegate.toggleAutocorrectWord, executeActions: delegate.executeActions)
                } else {
                    delegate.textDocumentProxy.insertText(text)
                }
            }
        case .backspace:
            delegate.handleBackspace()
        case .shift:
            delegate.toggleShift()
        case .enter:
            Key.applyAutocorrectWithTrigger(text: "\n", to: delegate.textDocumentProxy, using: delegate.suggestionService, autocorrectWordDisabled: delegate.autocorrectWordDisabled, toggleAutocorrectWord: delegate.toggleAutocorrectWord, executeActions: delegate.executeActions)
        case .space:
            Key.applyAutocorrectWithTrigger(text: " ", to: delegate.textDocumentProxy, using: delegate.suggestionService, autocorrectWordDisabled: delegate.autocorrectWordDisabled, toggleAutocorrectWord: delegate.toggleAutocorrectWord, executeActions: delegate.executeActions)
        case .layerSwitch(let layer):
            delegate.switchToLayer(layer)
        case .layoutSwitch(let layout):
            delegate.switchToLayout(layout)
        case .globe:
            delegate.advanceToNextInputMode()
        case .configuration(let config):
            delegate.handleConfiguration(config)
        case .empty:
            // Do nothing for empty keys
            break
        }

        // Handle auto-unshift for all keys except shift
        switch keyType {
        case .shift:
            break
        case .simple, .backspace, .enter, .space, .layerSwitch, .layoutSwitch, .globe, .configuration:
            delegate.autoUnshift()
        case .empty:
            break
        }
    }

    func sfSymbolName(shiftState: ShiftState = .unshifted, pressed: Bool = false, autocorrectEnabled: Bool = true, hasUndo: Bool = false, debugVisualizationEnabled: Bool = false) -> String? {
        switch keyType {
        case .globe:
            return "globe"
        case .shift:
            switch shiftState {
            case .unshifted:
                return "shift"
            case .shifted:
                return "shift.fill"
            case .capsLock:
                return "capslock.fill"
            }
        case .backspace:
            if hasUndo {
                return "arrow.uturn.backward"
            } else {
                return pressed ? "delete.backward.fill" : "delete.backward"
            }
        case .configuration(let config):
            switch config {
            case .toggleAutocorrect:
                return autocorrectEnabled ? "checkmark.circle" : "checkmark.circle.badge.xmark"
            case .toggleDebugVisualization:
                return debugVisualizationEnabled ? "square.dotted" : "star.square"
            }
        default:
            return nil
        }
    }

    func label(shiftState: ShiftState) -> String {
        switch keyType {
        case .simple(let text):
            return text
        case .backspace:
            return "⌫" // Fallback if SF Symbol rendering fails
        case .shift:
            switch shiftState {
            case .unshifted:
                return "⇧" // Fallback if SF Symbol rendering fails
            case .shifted:
                return "⬆︎" // Fallback if SF Symbol rendering fails
            case .capsLock:
                return "⇪" // Fallback if SF Symbol rendering fails
            }
        case .enter:
            return "↩︎"
        case .space:
            return ""
        case .layerSwitch(let layer):
            switch layer {
            case .symbol:
                return "λ"
            case .number:
                return "#"
            case .alpha:
                return "ABC"
            }
        case .layoutSwitch(let layout):
            switch layout {
            case .canary:
                return "CAN"
            case .qwerty:
                return "QWE"
            }
        case .globe:
            return "◉" // Fallback if SF Symbol rendering fails
        case .configuration(let config):
            switch config {
            case .toggleAutocorrect:
                return "AC"
            case .toggleDebugVisualization:
                return "▣"
            }
        case .empty:
            return ""
        }
    }

    func fontSize() -> CGFloat {
        switch keyType {
        case .simple, .space, .empty:
            return 22
        case .backspace, .shift, .enter:
            return 16
        case .globe:
            return 12
        case .layerSwitch:
            let labelText = self.label(shiftState: .unshifted)
            return labelText.count > 1 ? 12 : 16
        case .layoutSwitch:
            return 12
        case .configuration:
            return 12
        }
    }

    func fontSize(deviceLayout: DeviceLayout) -> CGFloat {
        switch keyType {
        case .simple, .space, .empty:
            return deviceLayout.regularFontSize
        case .backspace, .shift, .enter:
            return deviceLayout.specialFontSize
        case .globe:
            return deviceLayout.smallFontSize
        case .layerSwitch:
            let labelText = self.label(shiftState: .unshifted)
            return labelText.count > 1 ? deviceLayout.smallFontSize : deviceLayout.specialFontSize
        case .layoutSwitch:
            return deviceLayout.smallFontSize
        case .configuration:
            return deviceLayout.smallFontSize
        }
    }

    func backgroundColor(shiftState: ShiftState, traitCollection: UITraitCollection, tapped: Bool = false, isLargeScreen: Bool = false) -> UIColor {
        let theme = ColorTheme.current(for: traitCollection)

        switch keyType {
        case .simple:
            return tapped ? (isLargeScreen ? theme.secondaryKeyColor : theme.primaryKeyColor) : theme.primaryKeyColor
        case .space:
            return tapped ? theme.secondaryKeyColor : theme.primaryKeyColor
        case .shift:
            switch shiftState {
            case .unshifted:
                return tapped ? theme.primaryKeyColor : theme.secondaryKeyColor
            case .shifted, .capsLock:
                return tapped ? theme.secondaryKeyColor : theme.primaryKeyColor
            }
        case .backspace, .enter, .layerSwitch, .layoutSwitch, .globe, .configuration:
            return tapped ? theme.primaryKeyColor : theme.secondaryKeyColor
        case .empty:
            return UIColor.clear
        }
    }

    func feedbackPattern() -> FeedbackPattern {
        switch keyType {
        case .simple, .shift, .layerSwitch, .layoutSwitch, .configuration:
            return .subtle
        case .space, .enter:
            return .light
        case .backspace:
            return .selection
        case .globe, .empty:
            return .none
        }
    }

    func shouldResetMaybePunctuating() -> Bool {
        switch keyType {
        case .simple, .backspace, .enter, .space:
            return true
        case .shift, .layerSwitch, .layoutSwitch, .globe, .configuration, .empty:
            return false
        }
    }
}
