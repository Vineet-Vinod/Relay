//
//  TerminalFontRegistry.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import CoreText
import Foundation
import SwiftUI
import UIKit

enum TerminalFontRegistry {
    private struct FontResource {
        let fileName: String
        let fallbackPostScriptName: String
    }

    private static let regularResource = FontResource(
        fileName: "FiraCodeNerdFontMono-Regular.ttf",
        fallbackPostScriptName: "FiraCodeNFM-Reg"
    )
    private static let boldResource = FontResource(
        fileName: "FiraCodeNerdFontMono-Bold.ttf",
        fallbackPostScriptName: "FiraCodeNFM-Bold"
    )
    private static let resources = [
        regularResource,
        boldResource,
    ]

    private static var hasRegisteredFonts = false
    private static var registeredPostScriptNames = [String: String]()

    static func registerBundledFonts() {
        guard !hasRegisteredFonts else { return }

        for resource in resources {
            let components = resource.fileName.split(separator: ".", maxSplits: 1).map(String.init)
            guard components.count == 2,
                  let url = bundleURL(forResource: components[0], withExtension: components[1]) else {
                continue
            }

            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if let postScriptName = postScriptName(for: url) {
                registeredPostScriptNames[resource.fileName] = postScriptName
            }
        }

        hasRegisteredFonts = true
    }

    static func terminalFont(size: CGFloat, bold: Bool) -> UIFont {
        registerBundledFonts()

        let postScriptName = resolvedPostScriptName(bold: bold)
        if let font = UIFont(name: postScriptName, size: size) {
            return font
        }

        return UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    static func terminalSwiftUIFont(size: CGFloat, bold: Bool = false) -> Font {
        registerBundledFonts()

        let postScriptName = resolvedPostScriptName(bold: bold)
        if UIFont(name: postScriptName, size: size) != nil {
            return .custom(postScriptName, size: size)
        }

        return .system(size: size, weight: bold ? .semibold : .regular, design: .monospaced)
    }

    private static func bundleURL(forResource name: String, withExtension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fonts") {
            return url
        }

        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    private static func resolvedPostScriptName(bold: Bool) -> String {
        let resource = bold ? boldResource : regularResource
        return registeredPostScriptNames[resource.fileName] ?? resource.fallbackPostScriptName
    }

    private static func postScriptName(for url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            return nil
        }

        return CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
    }
}
