//
//  RelayTheme.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI
import UIKit

enum RelayTheme {
    static let accent = Color(uiColor: .systemBlue)
    static let success = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let warning = Color(red: 1.000, green: 0.839, blue: 0.039)
    static let danger = Color(red: 1.000, green: 0.271, blue: 0.227)
    static let info = Color(red: 0.392, green: 0.824, blue: 1.000)

    static let surfaceBase = Color(uiColor: .systemGroupedBackground)
    static let surfaceRaised = Color(uiColor: .secondarySystemBackground)
    static let surfaceStroke = Color(uiColor: .separator).opacity(0.14)

    enum Spacing {
        static let micro: CGFloat = 4
        static let tight: CGFloat = 8
        static let compact: CGFloat = 12
        static let content: CGFloat = 16
        static let section: CGFloat = 20
        static let card: CGFloat = 24
        static let major: CGFloat = 32
    }

    enum Radius {
        static let input: CGFloat = 14
        static let card: CGFloat = 20
        static let terminalPanel: CGFloat = 22
    }
}

struct RelayTerminalPalette {
    let background: UIColor
    let surface: UIColor
    let raised: UIColor
    let text: UIColor
    let muted: UIColor
    let subtle: UIColor
    let accent: UIColor
    let success: UIColor
    let danger: UIColor
    let warning: UIColor

    static func palette(for colorScheme: ColorScheme) -> RelayTerminalPalette {
        if colorScheme == .dark {
            return RelayTerminalPalette(
                background: UIColor(red: 0.051, green: 0.059, blue: 0.082, alpha: 1.0),
                surface: UIColor(red: 0.082, green: 0.094, blue: 0.122, alpha: 1.0),
                raised: UIColor(red: 0.116, green: 0.133, blue: 0.169, alpha: 1.0),
                text: UIColor(red: 0.905, green: 0.922, blue: 0.961, alpha: 1.0),
                muted: UIColor(red: 0.620, green: 0.667, blue: 0.761, alpha: 1.0),
                subtle: UIColor(red: 0.216, green: 0.243, blue: 0.314, alpha: 1.0),
                accent: UIColor(red: 0.420, green: 0.702, blue: 1.000, alpha: 1.0),
                success: UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1.0),
                danger: UIColor(red: 1.000, green: 0.271, blue: 0.227, alpha: 1.0),
                warning: UIColor(red: 1.000, green: 0.839, blue: 0.039, alpha: 1.0)
            )
        }

        return RelayTerminalPalette(
            background: UIColor(red: 0.953, green: 0.957, blue: 0.973, alpha: 1.0),
            surface: UIColor(red: 0.914, green: 0.922, blue: 0.949, alpha: 1.0),
            raised: UIColor(red: 0.982, green: 0.985, blue: 0.992, alpha: 1.0),
            text: UIColor(red: 0.094, green: 0.110, blue: 0.157, alpha: 1.0),
            muted: UIColor(red: 0.365, green: 0.404, blue: 0.490, alpha: 1.0),
            subtle: UIColor(red: 0.780, green: 0.804, blue: 0.867, alpha: 1.0),
            accent: UIColor(red: 0.208, green: 0.502, blue: 0.969, alpha: 1.0),
            success: UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1.0),
            danger: UIColor(red: 0.843, green: 0.231, blue: 0.184, alpha: 1.0),
            warning: UIColor(red: 0.769, green: 0.569, blue: 0.000, alpha: 1.0)
        )
    }

    static func palette(for traitCollection: UITraitCollection) -> RelayTerminalPalette {
        palette(for: traitCollection.userInterfaceStyle == .dark ? .dark : .light)
    }

    var backgroundColor: Color { Color(uiColor: background) }
    var surfaceColor: Color { Color(uiColor: surface) }
    var raisedColor: Color { Color(uiColor: raised) }
    var textColor: Color { Color(uiColor: text) }
    var mutedColor: Color { Color(uiColor: muted) }
    var subtleColor: Color { Color(uiColor: subtle) }
    var accentColor: Color { Color(uiColor: accent) }
    var successColor: Color { Color(uiColor: success) }
    var dangerColor: Color { Color(uiColor: danger) }
    var warningColor: Color { Color(uiColor: warning) }
}

extension View {
    func relayAppCard(padding: CGFloat = RelayTheme.Spacing.content) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: RelayTheme.Radius.card, style: .continuous)
                    .fill(RelayTheme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayTheme.Radius.card, style: .continuous)
                    .stroke(RelayTheme.surfaceStroke, lineWidth: 1)
            )
    }

    func relayAppFieldBackground(isFocused: Bool, isTechnical: Bool = false) -> some View {
        self
            .font(
                isTechnical
                ? TerminalFontRegistry.terminalSwiftUIFont(size: 16)
                : .body
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                    .stroke(
                        isFocused ? RelayTheme.accent.opacity(0.85) : RelayTheme.surfaceStroke,
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
    }

    func relayTerminalPanel(_ palette: RelayTerminalPalette, padding: CGFloat = RelayTheme.Spacing.content) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: RelayTheme.Radius.terminalPanel, style: .continuous)
                    .fill(palette.surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayTheme.Radius.terminalPanel, style: .continuous)
                    .stroke(palette.subtleColor.opacity(0.65), lineWidth: 1)
            )
    }

    func relayTerminalFieldBackground(_ palette: RelayTerminalPalette, isFocused: Bool) -> some View {
        self
            .font(TerminalFontRegistry.terminalSwiftUIFont(size: 16))
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                    .fill(palette.raisedColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                    .stroke(
                        isFocused ? palette.accentColor.opacity(0.9) : palette.subtleColor.opacity(0.8),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
    }
}
