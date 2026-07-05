//
//  KeyboardLayout.swift
//  Keyboard
//
//  Created by Shawn Moore on 7/29/25.
//

import UIKit

enum Layer: Equatable {
    case alpha
    case symbol
    case number
}

enum Node {
    case key(Key, CGFloat)
    case gap(CGFloat)
    case split(CGFloat)

    static func calculateRowWidth(for row: [Node]) -> CGFloat {
        return row.reduce(0) { total, node in
            switch node {
            case .key(_, let width): return total + width
            case .gap(let width): return total + width
            case .split(let width): return total + width
            }
        }
    }
}

struct KeyData {
    let index: Int
    let key: Key
    let viewFrame: CGRect      // Visual frame for drawing
    var hitbox: CGRect         // Touch area frame for hit testing
    var debugColor: UIColor

    init(index: Int, key: Key, viewFrame: CGRect, hitbox: CGRect, debugColor: UIColor) {
        self.index = index
        self.key = key
        self.viewFrame = viewFrame
        self.hitbox = hitbox
        self.debugColor = debugColor
    }
}

enum KeyboardLayout: Equatable {
    case canary
    case qwerty

    func rows(for layer: Layer, shifted: Bool, needsGlobe: Bool) -> [[Key]] {
        switch self {
        case .canary:
            let baseRows = canaryRows(for: layer, shifted: shifted)
            if needsGlobe {
                return baseRows
            } else {
                // Filter out globe key from all rows
                return baseRows.map { row in
                    row.filter { key in
                        if case .globe = key.keyType {
                            return false
                        }
                        return true
                    }
                }
            }
        case .qwerty:
            let baseRows = qwertyRows(for: layer, shifted: shifted)
            if needsGlobe {
                return baseRows
            } else {
                // Filter out globe key from all rows
                return baseRows.map { row in
                    row.filter { key in
                        if case .globe = key.keyType {
                            return false
                        }
                        return true
                    }
                }
            }
        }
    }

    func nodeRows(for layer: Layer, shifted: Bool, layout: DeviceLayout, needsGlobe: Bool) -> [[Node]] {
        switch self {
        case .canary:
            return canaryNodeRows(for: layer, shifted: shifted, layout: layout, needsGlobe: needsGlobe)
        case .qwerty:
            return qwertyNodeRows(for: layer, shifted: shifted, layout: layout, needsGlobe: needsGlobe)
        }
    }

    private func canaryRows(for layer: Layer, shifted: Bool) -> [[Key]] {
        let apostrophe = Key(shifted ? .simple("\"") : .simple("'"), longPressBehavior: .alternates([";", "\""]))
        let period = Key(shifted ? .simple("!") : .simple("."), longPressBehavior: .alternates(["!"]))
        let comma = Key(shifted ? .simple("?") : .simple(","), longPressBehavior: .alternates(["?"]))

        switch layer {
        case .alpha:
            if shifted {
                return [
                    [Key(.simple("W"), longPressBehavior: .alternates(["`", "∞"])), Key(.simple("L"), longPressBehavior: .alternates(["~", "6", "λ"])), Key(.simple("Y"), longPressBehavior: .alternates(["\\", "5", "°", "Ÿ"])), Key(.simple("P"), longPressBehavior: .alternates(["{", "4", "•"])), Key(.simple("B"), longPressBehavior: .alternates(["$", "‽"])), Key(.simple("Z"), longPressBehavior: .alternates(["%", "←"])), Key(.simple("F"), longPressBehavior: .alternates(["}", "↓"])), Key(.simple("O"), longPressBehavior: .alternates(["/", "↑", "Ó", "Ò", "Ö", "Ō", "Ø"])), Key(.simple("U"), longPressBehavior: .alternates(["#", "→", "Ú", "Ù", "Ü", "Ū"])), apostrophe],
                    [Key(.simple("C"), longPressBehavior: .alternates(["&", "¢"])), Key(.simple("R"), longPressBehavior: .alternates(["*", "3"])), Key(.simple("S"), longPressBehavior: .alternates(["=", "2", "ß"])), Key(.simple("T"), longPressBehavior: .alternates(["(", "1"])), Key(.simple("G"), longPressBehavior: .alternates(["<", "0"])), Key(.simple("M"), longPressBehavior: .alternates([">", "Μ"])), Key(.simple("N"), longPressBehavior: .alternates([")", "Ñ"])), Key(.simple("E"), longPressBehavior: .alternates(["-", "É", "È", "Ë", "Ē"])), Key(.simple("I"), longPressBehavior: .alternates(["+", "Í", "Ì", "Ï", "Ī"])), Key(.simple("A"), longPressBehavior: .alternates([":", "|", "Á", "À", "Ä", "Ā", "Å"]))],
                    [Key(.simple("Q"), longPressBehavior: .alternates(["—", "¢"])), Key(.simple("J"), longPressBehavior: .alternates(["@", "9", "£"])), Key(.simple("V"), longPressBehavior: .alternates(["_", "8", "¥"])), Key(.simple("D"), longPressBehavior: .alternates(["[", "7", "€"])), Key(.simple("K"), longPressBehavior: .alternates(["…", "⋯"])), Key(.simple("X"), longPressBehavior: .alternates(["^", "✗"])), Key(.simple("H"), longPressBehavior: .alternates(["]", "✔"])), period, comma, Key(.enter)],
                    [Key(.globe), Key(.layerSwitch(.symbol)), Key(.shift, doubleTapBehavior: .capsLock), Key(.backspace, longPressBehavior: .repeating), Key(.space), Key(.layerSwitch(.number))],
                ]
            } else {
                return [
                    [Key(.simple("w"), longPressBehavior: .alternates(["`", "∞"])), Key(.simple("l"), longPressBehavior: .alternates(["~", "6", "λ"])), Key(.simple("y"), longPressBehavior: .alternates(["\\", "5", "°", "ÿ"])), Key(.simple("p"), longPressBehavior: .alternates(["{", "4", "•"])), Key(.simple("b"), longPressBehavior: .alternates(["$", "‽"])), Key(.simple("z"), longPressBehavior: .alternates(["%", "←"])), Key(.simple("f"), longPressBehavior: .alternates(["}", "↓"])), Key(.simple("o"), longPressBehavior: .alternates(["/", "↑", "ó", "ò", "ö", "ō", "ø"])), Key(.simple("u"), longPressBehavior: .alternates(["#", "→", "ú", "ù", "ü", "ū"])), apostrophe],
                    [Key(.simple("c"), longPressBehavior: .alternates(["&", "¢"])), Key(.simple("r"), longPressBehavior: .alternates(["*", "3"])), Key(.simple("s"), longPressBehavior: .alternates(["=", "2", "ß"])), Key(.simple("t"), longPressBehavior: .alternates(["(", "1"])), Key(.simple("g"), longPressBehavior: .alternates(["<", "0"])), Key(.simple("m"), longPressBehavior: .alternates([">", "μ"])), Key(.simple("n"), longPressBehavior: .alternates([")", "ñ"])), Key(.simple("e"), longPressBehavior: .alternates(["-", "é", "è", "ë", "ē"])), Key(.simple("i"), longPressBehavior: .alternates(["+", "í", "ì", "ï", "ī"])), Key(.simple("a"), longPressBehavior: .alternates([":", "|", "á", "à", "ä", "ā", "å"]))],
                    [Key(.simple("q"), longPressBehavior: .alternates(["—", "¢"])), Key(.simple("j"), longPressBehavior: .alternates(["@", "9", "£"])), Key(.simple("v"), longPressBehavior: .alternates(["_", "8", "¥"])), Key(.simple("d"), longPressBehavior: .alternates(["[", "7", "€"])), Key(.simple("k"), longPressBehavior: .alternates(["…", "⋯"])), Key(.simple("x"), longPressBehavior: .alternates(["^", "✗"])), Key(.simple("h"), longPressBehavior: .alternates(["]", "✔"])), period, comma, Key(.enter)],
                    [Key(.globe), Key(.layerSwitch(.symbol)), Key(.shift, doubleTapBehavior: .capsLock), Key(.backspace, longPressBehavior: .repeating), Key(.space), Key(.layerSwitch(.number))],
                ]
            }
        case .symbol:
            return [
                [Key(.simple("`"), longPressBehavior: .alternates(["∞", "w", "W"])), Key(.simple("~"), longPressBehavior: .alternates(["λ", "6", "l", "L"])), Key(.simple("\\"), longPressBehavior: .alternates(["°", "5", "y", "Y"])), Key(.simple("{"), longPressBehavior: .alternates(["•", "4", "p", "P"])), Key(.simple("$"), longPressBehavior: .alternates(["‽", "b", "B"])), Key(.simple("%"), longPressBehavior: .alternates(["←", "z", "Z"])), Key(.simple("}"), longPressBehavior: .alternates(["↓", "f", "F"])), Key(.simple("/"), longPressBehavior: .alternates(["↑", "o", "O"])), Key(.simple("#"), longPressBehavior: .alternates(["→", "u", "U"])), apostrophe],
                [Key(.simple("&"), longPressBehavior: .alternates(["c", "C"])), Key(.simple("*"), longPressBehavior: .alternates(["3", "r", "R"])), Key(.simple("="), longPressBehavior: .alternates(["2", "s", "S"])), Key(.simple("("), longPressBehavior: .alternates(["1", "t", "T"])), Key(.simple("<"), longPressBehavior: .alternates(["0", "g", "G"])), Key(.simple(">"), longPressBehavior: .alternates(["m", "M"])), Key(.simple(")"), longPressBehavior: .alternates(["n", "N"])), Key(.simple("-"), longPressBehavior: .alternates(["e", "E"])), Key(.simple("+"), longPressBehavior: .alternates(["i", "I"])), Key(.simple(":"), longPressBehavior: .alternates(["|", "a", "A"]))],
                [Key(.simple("—"), longPressBehavior: .alternates(["¢", "q", "Q"])), Key(.simple("@"), longPressBehavior: .alternates(["£", "9", "j", "J"])), Key(.simple("_"), longPressBehavior: .alternates(["¥", "8", "v", "V"])), Key(.simple("["), longPressBehavior: .alternates(["€", "7", "d", "D"])), Key(.simple("…"), longPressBehavior: .alternates(["⋯", "k", "K"])), Key(.simple("^"), longPressBehavior: .alternates(["✗", "x", "X"])), Key(.simple("]"), longPressBehavior: .alternates(["✔", "h", "H"])), period, comma, Key(.enter)],
                [Key(.globe), Key(.layerSwitch(.alpha)), Key(.shift, doubleTapBehavior: .capsLock), Key(.backspace, longPressBehavior: .repeating), Key(.space), Key(.layerSwitch(.number))],
            ]
        case .number:
            return [
                [Key(.empty), Key(.simple("6"), longPressBehavior: .alternates(["~", "λ", "l", "L"])), Key(.simple("5"), longPressBehavior: .alternates(["\\", "°", "y", "Y"])), Key(.simple("4"), longPressBehavior: .alternates(["{", "•", "p", "P"])), Key(.empty), Key(.layoutSwitch(.qwerty)), Key(.configuration(.toggleAutocorrect)), Key(.configuration(.toggleDebugVisualization)), Key(.configuration(.toggleSwipeOnly)), apostrophe],
                [Key(.empty), Key(.simple("3"), longPressBehavior: .alternates(["*", "r", "R"])), Key(.simple("2"), longPressBehavior: .alternates(["=", "s", "S"])), Key(.simple("1"), longPressBehavior: .alternates(["(", "t", "T"])), Key(.simple("0"), longPressBehavior: .alternates(["<", "g", "G"])), Key(.empty), Key(.empty), Key(.empty), Key(.empty), Key(.empty)],
                [Key(.empty), Key(.simple("9"), longPressBehavior: .alternates(["@", "£", "j", "J"])), Key(.simple("8"), longPressBehavior: .alternates(["_", "¥", "v", "V"])), Key(.simple("7"), longPressBehavior: .alternates(["[", "€", "d", "D"])), Key(.empty), Key(.empty), Key(.empty), period, comma, Key(.enter)],
                [Key(.globe), Key(.layerSwitch(.alpha)), Key(.shift, doubleTapBehavior: .capsLock), Key(.backspace, longPressBehavior: .repeating), Key(.space), Key(.layerSwitch(.symbol))],
            ]
        }
    }

    private func qwertyRows(for layer: Layer, shifted: Bool) -> [[Key]] {
        switch layer {
        case .alpha:
            if shifted {
                return [
                    [Key(.simple("Q")), Key(.simple("W")), Key(.simple("E")), Key(.simple("R")), Key(.simple("T")), Key(.simple("Y")), Key(.simple("U")), Key(.simple("I")), Key(.simple("O")), Key(.simple("P"))],
                    [Key(.simple("A")), Key(.simple("S")), Key(.simple("D")), Key(.simple("F")), Key(.simple("G")), Key(.simple("H")), Key(.simple("J")), Key(.simple("K")), Key(.simple("L"))],
                    [Key(.shift, doubleTapBehavior: .capsLock), Key(.simple("Z")), Key(.simple("X")), Key(.simple("C")), Key(.simple("V")), Key(.simple("B")), Key(.simple("N")), Key(.simple("M")), Key(.backspace, longPressBehavior: .repeating)],
                    [Key(.layerSwitch(.number)), Key(.layoutSwitch(.canary)), Key(.globe), Key(.space), Key(.enter)],
                ]
            } else {
                return [
                    [Key(.simple("q")), Key(.simple("w")), Key(.simple("e")), Key(.simple("r")), Key(.simple("t")), Key(.simple("y")), Key(.simple("u")), Key(.simple("i")), Key(.simple("o")), Key(.simple("p"))],
                    [Key(.simple("a")), Key(.simple("s")), Key(.simple("d")), Key(.simple("f")), Key(.simple("g")), Key(.simple("h")), Key(.simple("j")), Key(.simple("k")), Key(.simple("l"))],
                    [Key(.shift, doubleTapBehavior: .capsLock), Key(.simple("z")), Key(.simple("x")), Key(.simple("c")), Key(.simple("v")), Key(.simple("b")), Key(.simple("n")), Key(.simple("m")), Key(.backspace, longPressBehavior: .repeating)],
                    [Key(.layerSwitch(.number)), Key(.layoutSwitch(.canary)), Key(.globe), Key(.space), Key(.enter)],
                ]
            }
        case .symbol:
            return [
                [Key(.simple("[")), Key(.simple("]")), Key(.simple("{")), Key(.simple("}")), Key(.simple("#")), Key(.simple("%")), Key(.simple("^")), Key(.simple("*")), Key(.simple("+")), Key(.simple("="))],
                [Key(.simple("_")), Key(.simple("\\")), Key(.simple("|")), Key(.simple("~")), Key(.simple("<")), Key(.simple(">")), Key(.simple("€")), Key(.simple("£")), Key(.simple("¥")), Key(.simple("·"))],
                [Key(.layerSwitch(.number)), Key(.simple(".")), Key(.simple(",")), Key(.simple("?")), Key(.simple("!")), Key(.simple("'")), Key(.backspace, longPressBehavior: .repeating)],
                [Key(.layerSwitch(.alpha)), Key(.layoutSwitch(.canary)), Key(.globe), Key(.space), Key(.enter)],
            ]
        case .number:
            return [
                [Key(.simple("1")), Key(.simple("2")), Key(.simple("3")), Key(.simple("4")), Key(.simple("5")), Key(.simple("6")), Key(.simple("7")), Key(.simple("8")), Key(.simple("9")), Key(.simple("0"))],
                [Key(.simple("-")), Key(.simple("/")), Key(.simple(":")), Key(.simple(";")), Key(.simple("(")), Key(.simple(")")), Key(.simple("$")), Key(.simple("&")), Key(.simple("@")), Key(.simple("\""))],
                [Key(.layerSwitch(.symbol)), Key(.simple(".")), Key(.simple(",")), Key(.simple("?")), Key(.simple("!")), Key(.simple("'")), Key(.backspace, longPressBehavior: .repeating)],
                [Key(.layerSwitch(.alpha)), Key(.layoutSwitch(.canary)), Key(.globe), Key(.space), Key(.enter)],
            ]
        }
    }

    private func canaryNodeRows(for layer: Layer, shifted: Bool, layout: DeviceLayout, needsGlobe: Bool) -> [[Node]] {
        let keyRows = self.rows(for: layer, shifted: shifted, needsGlobe: needsGlobe)
        let allNodeRows = keyRows.enumerated().map { rowIndex, row in
            var nodeRow: [Node] = []

            for (keyIndex, key) in row.enumerated() {
                // Add the key with Canary-specific sizing
                let keyWidth: CGFloat
                switch key.keyType {
                case .space:
                    keyWidth = layout.alphaKeyWidth * 2 + layout.horizontalGap
                case .layerSwitch, .shift, .backspace:
                    // Make special keys narrower when globe key is present
                    keyWidth = needsGlobe ? layout.alphaKeyWidth * 1.3 : (layout.alphaKeyWidth * 1.5 + layout.horizontalGap * 0.5)
                case .simple, .enter, .layoutSwitch, .globe, .configuration, .empty:
                    keyWidth = layout.alphaKeyWidth
                }
                nodeRow.append(.key(key, keyWidth))

                // Add split gap in middle
                let splitAfterIndex: Int
                if rowIndex == 3 {
                    // Bottom row: split after backspace (index 3 with globe, index 2 without globe)
                    splitAfterIndex = needsGlobe ? 3 : 2
                } else {
                    splitAfterIndex = (row.count / 2) - 1
                }

                if keyIndex == splitAfterIndex {
                    nodeRow.append(.split(layout.splitWidth))
                } else if keyIndex < row.count - 1 {
                    // Add gap after key (except last key and before split)
                    nodeRow.append(.gap(layout.horizontalGap))
                }
            }

            return nodeRow
        }

        // Align bottom row split with first row
        return allNodeRows.enumerated().map { rowIndex, nodeRow in
            if rowIndex == 3 {
                // Find split positions in both rows
                let firstRowSplitIndex = allNodeRows[0].firstIndex { if case .split = $0 { return true } else { return false } }!
                let bottomRowSplitIndex = nodeRow.firstIndex { if case .split = $0 { return true } else { return false } }!

                // Calculate left and right side widths using split as delimiter
                let firstRowLeftWidth = Node.calculateRowWidth(for: Array(allNodeRows[0].prefix(firstRowSplitIndex)))
                let firstRowRightWidth = Node.calculateRowWidth(for: Array(allNodeRows[0].suffix(from: firstRowSplitIndex + 1)))

                let bottomRowLeftWidth = Node.calculateRowWidth(for: Array(nodeRow.prefix(bottomRowSplitIndex)))
                let bottomRowRightWidth = Node.calculateRowWidth(for: Array(nodeRow.suffix(from: bottomRowSplitIndex + 1)))

                let leftGap = firstRowLeftWidth - bottomRowLeftWidth
                let rightGap = firstRowRightWidth - bottomRowRightWidth

                // Create dual gaps: inner constant gap + outer remaining gap
                let leftInnerGap = 2 * layout.horizontalGap
                let leftOuterGap = max(0, leftGap - leftInnerGap)
                let rightInnerGap = 2 * layout.horizontalGap
                let rightOuterGap = max(0, rightGap - rightInnerGap)

                return [.gap(leftOuterGap), .gap(leftInnerGap)] + nodeRow + [.gap(rightInnerGap), .gap(rightOuterGap)]
            }
            return nodeRow
        }
    }

    private func qwertySpecialKeyWidth(_ layout: DeviceLayout) -> CGFloat {
        return round(layout.alphaKeyWidth * 1.2)
    }

    private func qwertyThirdRowSimpleKeyWidth(_ layout: DeviceLayout) -> CGFloat {
        return round(layout.alphaKeyWidth * 1.4)
    }

    private func qwertyStandardRowWidth(_ layout: DeviceLayout, needsGlobe: Bool) -> CGFloat {
        let firstRow = KeyboardLayout.qwerty.rows(for: .alpha, shifted: false, needsGlobe: needsGlobe)[0]
        return layout.alphaKeyWidth * CGFloat(firstRow.count) + layout.horizontalGap * CGFloat(firstRow.count - 1)
    }

    private func qwertyThirdRowSpecialGap(layer: Layer, _ layout: DeviceLayout, needsGlobe: Bool) -> CGFloat {
        let thirdRow = KeyboardLayout.qwerty.rows(for: layer, shifted: false, needsGlobe: needsGlobe)[2]
        let specialKeyWidth = qwertySpecialKeyWidth(layout)
        let simpleKeyWidth = (layer == .number || layer == .symbol) ? qwertyThirdRowSimpleKeyWidth(layout) : layout.alphaKeyWidth
        let middleKeysWidth = CGFloat(thirdRow.count - 2) * simpleKeyWidth + CGFloat(thirdRow.count - 3) * layout.horizontalGap
        let availableWidth = qwertyStandardRowWidth(layout, needsGlobe: needsGlobe)
        let totalSpecialWidth = specialKeyWidth * 2
        let totalGapWidth = availableWidth - totalSpecialWidth - middleKeysWidth
        return totalGapWidth / 2
    }

    private func qwertyEnterKeyWidth(_ layout: DeviceLayout, needsGlobe: Bool) -> CGFloat {
        let specialKeyWidth = qwertySpecialKeyWidth(layout)
        let specialGap = qwertyThirdRowSpecialGap(layer: .alpha, layout, needsGlobe: needsGlobe)
        return layout.alphaKeyWidth + specialKeyWidth + specialGap
    }

    private func qwertySpaceKeyWidth(_ layout: DeviceLayout, needsGlobe: Bool) -> CGFloat {
        let bottomRow = KeyboardLayout.qwerty.rows(for: .alpha, shifted: false, needsGlobe: needsGlobe)[3]
        let availableWidth = qwertyStandardRowWidth(layout, needsGlobe: needsGlobe)

        let otherKeysWidth: CGFloat = bottomRow.compactMap { key -> CGFloat? in
            if case .space = key.keyType {
                return nil
            }
            return qwertyKeyWidth(for: key, rowIndex: 3, layer: .alpha, layout: layout, needsGlobe: needsGlobe)
        }.reduce(0.0, +)

        let gapsWidth = layout.horizontalGap * CGFloat(bottomRow.count - 1)
        let spaceWidth = availableWidth - otherKeysWidth - gapsWidth

        return spaceWidth
    }

    private func qwertyKeyWidth(for key: Key, rowIndex: Int, layer: Layer, layout: DeviceLayout, needsGlobe: Bool) -> CGFloat {
        switch key.keyType {
        case .space:
            return qwertySpaceKeyWidth(layout, needsGlobe: needsGlobe)
        case .enter:
            return qwertyEnterKeyWidth(layout, needsGlobe: needsGlobe)
        case .layerSwitch, .shift, .backspace, .layoutSwitch:
            return qwertySpecialKeyWidth(layout)
        case .simple, .globe, .configuration, .empty:
            // Third row simple keys are 40% larger on number/symbol layers
            if rowIndex == 2 && (layer == .number || layer == .symbol) {
                return qwertyThirdRowSimpleKeyWidth(layout)
            } else {
                return layout.alphaKeyWidth
            }
        }
    }

    private func qwertyNodeRows(for layer: Layer, shifted: Bool, layout: DeviceLayout, needsGlobe: Bool) -> [[Node]] {
        let keyRows = self.rows(for: layer, shifted: shifted, needsGlobe: needsGlobe)
        return keyRows.enumerated().map { rowIndex, row in
            var nodeRow: [Node] = []

            for (keyIndex, key) in row.enumerated() {
                // Add the key with QWERTY-specific sizing
                let keyWidth = qwertyKeyWidth(for: key, rowIndex: rowIndex, layer: layer, layout: layout, needsGlobe: needsGlobe)
                nodeRow.append(.key(key, keyWidth))

                // Add gap after key (except last key)
                if keyIndex < row.count - 1 {
                    let gapWidth = if rowIndex == 2 && (keyIndex == 0 || keyIndex == row.count - 2) {
                        qwertyThirdRowSpecialGap(layer: layer, layout, needsGlobe: false)
                    } else {
                        layout.horizontalGap
                    }
                    nodeRow.append(.gap(gapWidth))
                }
            }

            return nodeRow
        }
    }
}
