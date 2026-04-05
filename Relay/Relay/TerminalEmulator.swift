//
//  TerminalEmulator.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import SwiftUI

struct TerminalScreenSnapshot {
    static let empty = TerminalScreenSnapshot(rows: [TerminalRenderedRow.empty], cursor: .zero, totalRowCount: 1)

    var rows: [TerminalRenderedRow]
    var cursor: TerminalCursor?
    var totalRowCount: Int
}

struct TerminalCursor: Equatable {
    static let zero = TerminalCursor(row: 0, column: 0)

    let row: Int
    let column: Int
}

struct TerminalRenderedRow: Identifiable, Equatable {
    let id: Int
    let cells: [TerminalRenderedCell]

    static let empty = TerminalRenderedRow(id: 0, cells: [TerminalRenderedCell(id: 0, text: " ", style: .default)])
}

struct TerminalRenderedCell: Identifiable, Equatable {
    let id: Int
    let text: String
    let style: TerminalStyle
}

struct TerminalStyle: Equatable {
    struct TerminalColor: Equatable {
        let resolved: Color

        static let foreground = TerminalColor(resolved: .white)
        static let background = TerminalColor(resolved: .black)
    }

    var foreground: TerminalColor
    var background: TerminalColor
    var bold: Bool
    var underline: Bool
    var inverse: Bool

    static let `default` = TerminalStyle(
        foreground: .foreground,
        background: .background,
        bold: false,
        underline: false,
        inverse: false
    )
}

final class TerminalEmulator {
    private enum ParserState {
        case ground
        case escape
        case controlSequenceIntroducer
        case operatingSystemCommand
        case operatingSystemCommandEscape
    }

    private var columns: Int
    private var rows: Int
    private var lines: [String]
    private var activeLine = ""
    private var parserState: ParserState = .ground
    private var controlSequence = ""

    init(columns: Int, rows: Int) {
        self.columns = max(20, columns)
        self.rows = max(8, rows)
        self.lines = [""]
    }

    func consume(_ bytes: [UInt8]) {
        let text = String(decoding: bytes, as: UTF8.self)
        for scalar in text.unicodeScalars {
            consume(scalar)
        }

        replaceLastLine(with: activeLine)
    }

    func resize(columns: Int, rows: Int) {
        self.columns = max(20, columns)
        self.rows = max(8, rows)
        replaceLastLine(with: activeLine)
    }

    func snapshot() -> TerminalScreenSnapshot {
        let renderedLines = Array(lines.suffix(rows))
        let rows = renderedLines.enumerated().map { index, line in
            renderRow(id: index, text: line)
        }

        return TerminalScreenSnapshot(
            rows: rows.isEmpty ? [TerminalRenderedRow.empty] : rows,
            cursor: TerminalCursor(
                row: max(0, rows.count - 1),
                column: min(activeLine.count, max(0, columns - 1))
            ),
            totalRowCount: renderedLines.count
        )
    }

    func reset() {
        lines = [""]
        activeLine.removeAll()
        parserState = .ground
        controlSequence.removeAll()
    }

    private func consume(_ scalar: UnicodeScalar) {
        switch parserState {
        case .ground:
            consumeGround(scalar)
        case .escape:
            consumeEscape(scalar)
        case .controlSequenceIntroducer:
            consumeControlSequence(scalar)
        case .operatingSystemCommand:
            consumeOperatingSystemCommand(scalar)
        case .operatingSystemCommandEscape:
            parserState = scalar == "\\" ? .ground : .operatingSystemCommand
        }
    }

    private func consumeGround(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x08, 0x7F:
            if !activeLine.isEmpty {
                activeLine.removeLast()
            }
        case 0x09:
            appendTab()
        case 0x0A:
            commitActiveLine()
        case 0x0D:
            activeLine.removeAll()
        case 0x1B:
            parserState = .escape
        case 0x00...0x1F:
            return
        default:
            activeLine.unicodeScalars.append(scalar)
            wrapIfNeeded()
        }
    }

    private func consumeEscape(_ scalar: UnicodeScalar) {
        switch scalar {
        case "[":
            controlSequence.removeAll()
            parserState = .controlSequenceIntroducer
        case "]":
            parserState = .operatingSystemCommand
        default:
            parserState = .ground
        }
    }

    private func consumeControlSequence(_ scalar: UnicodeScalar) {
        if scalar.value >= 0x40 && scalar.value <= 0x7E {
            let parameters = controlSequence
            parserState = .ground
            controlSequence.removeAll()
            handleControlSequence(final: scalar, parameters: parameters)
            return
        }

        controlSequence.unicodeScalars.append(scalar)
    }

    private func consumeOperatingSystemCommand(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x07:
            parserState = .ground
        case 0x1B:
            parserState = .operatingSystemCommandEscape
        default:
            return
        }
    }

    private func handleControlSequence(final: UnicodeScalar, parameters: String) {
        switch final {
        case "J":
            if parameters.isEmpty || parameters == "2" {
                lines = [""]
                activeLine.removeAll()
            }
        case "K":
            replaceLastLine(with: activeLine)
        default:
            return
        }
    }

    private func appendTab() {
        let tabWidth = 8
        let remainder = activeLine.count % tabWidth
        let spaces = remainder == 0 ? tabWidth : tabWidth - remainder
        activeLine.append(String(repeating: " ", count: spaces))
        wrapIfNeeded()
    }

    private func wrapIfNeeded() {
        guard activeLine.count >= columns else {
            return
        }

        commitActiveLine()
    }

    private func commitActiveLine() {
        replaceLastLine(with: activeLine)
        lines.append("")
        activeLine.removeAll()
    }

    private func replaceLastLine(with text: String) {
        if lines.isEmpty {
            lines = [text]
        } else {
            lines[lines.count - 1] = text
        }
    }

    private func renderRow(id: Int, text: String) -> TerminalRenderedRow {
        let visible = Array(text.prefix(columns))
        let padded = visible + Array(repeating: Character(" "), count: max(0, columns - visible.count))
        let cells = padded.enumerated().map { index, character in
            TerminalRenderedCell(id: index, text: String(character), style: .default)
        }

        return TerminalRenderedRow(id: id, cells: cells)
    }
}
