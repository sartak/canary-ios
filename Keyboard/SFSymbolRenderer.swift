//
//  SFSymbolRenderer.swift
//  Keyboard
//
//  Created by Shawn Moore on 7/29/25.
//

import UIKit

enum SFSymbolRenderer {
    static func render(
        for key: Key,
        shiftState: ShiftState,
        fontSize: CGFloat,
        theme: ColorTheme,
        pressed: Bool = false,
        autocorrectEnabled: Bool = true,
        hasUndo: Bool = false,
        debugVisualizationEnabled: Bool = false,
        swipeOnlyMode: Bool = false
    ) -> UIView? {
        guard let symbolName = key.sfSymbolName(shiftState: shiftState, pressed: pressed, autocorrectEnabled: autocorrectEnabled, hasUndo: hasUndo, debugVisualizationEnabled: debugVisualizationEnabled, swipeOnlyMode: swipeOnlyMode) else {
            return nil
        }

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: fontSize, weight: .light)
        guard let symbolImage = UIImage(systemName: symbolName, withConfiguration: symbolConfig) else {
            return nil
        }

        let imageView = UIImageView(image: symbolImage.withTintColor(theme.textColor, renderingMode: .alwaysOriginal))
        imageView.contentMode = .scaleAspectFit

        return imageView
    }

    static func createTextLabel(
        for key: Key,
        shiftState: ShiftState,
        fontSize: CGFloat,
        theme: ColorTheme
    ) -> UILabel {
        let label = UILabel()
        label.text = key.label(shiftState: shiftState)
        label.font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
        label.textColor = theme.textColor
        label.textAlignment = .center

        return label
    }

    static func createContentView(
        for key: Key,
        shiftState: ShiftState,
        fontSize: CGFloat,
        theme: ColorTheme,
        pressed: Bool = false,
        autocorrectEnabled: Bool = true,
        hasUndo: Bool = false
    ) -> UIView {
        if let symbolView = render(for: key, shiftState: shiftState, fontSize: fontSize, theme: theme, pressed: pressed, autocorrectEnabled: autocorrectEnabled, hasUndo: hasUndo) {
            return symbolView
        } else {
            return createTextLabel(for: key, shiftState: shiftState, fontSize: fontSize, theme: theme)
        }
    }
}
