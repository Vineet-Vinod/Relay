//
//  TerminalFontRegistry.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import CoreText
import Foundation
import UIKit

enum TerminalFontRegistry {
    private static let regularPostScriptName = "FiraCodeNFM-Reg"
    private static let boldPostScriptName = "FiraCodeNFM-Bold"
    private static let resourceNames = [
        "FiraCodeNerdFontMono-Regular.ttf",
        "FiraCodeNerdFontMono-Bold.ttf",
    ]

    private static var hasRegisteredFonts = false

    static func registerBundledFonts() {
        guard !hasRegisteredFonts else { return }

        for name in resourceNames {
            let components = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard components.count == 2,
                  let url = Bundle.main.url(
                    forResource: components[0],
                    withExtension: components[1],
                    subdirectory: "Fonts"
                  ) else {
                continue
            }

            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }

        hasRegisteredFonts = true
    }

    static func terminalFont(size: CGFloat, bold: Bool) -> UIFont {
        registerBundledFonts()

        let postScriptName = bold ? boldPostScriptName : regularPostScriptName
        if let font = UIFont(name: postScriptName, size: size) {
            return font
        }

        return UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}
