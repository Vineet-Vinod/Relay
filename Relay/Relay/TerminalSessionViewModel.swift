//
//  TerminalSessionViewModel.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class TerminalSessionViewModel {
    let host: Host

    var lines: [TerminalLine] = []
    var command = ""
    var isConnecting = false
    var isConnected = false

    private let client: SSHClient
    private var activeRemoteLineID: UUID?
    private var terminalSize = TerminalSize(columns: 120, rows: 32)

    init(host: Host, client: SSHClient? = nil) {
        self.host = host
        self.client = client ?? SSHClientFactory.makeClient()
        self.client.setEventHandler { [weak self] event in
            self?.handle(event)
        }
    }

    func connect() async {
        guard !isConnecting, !isConnected else { return }

        isConnecting = true
        append("Connecting to \(host.username)@\(host.hostname):\(host.port)...", kind: .status)

        do {
            try await client.connect(to: host)
            isConnected = true
            await client.resizeTerminal(columns: terminalSize.columns, rows: terminalSize.rows)

            if AppEnvironment.sshTransportMode == .mock {
                append("Type `help` to see mock commands.", kind: .status)
            }
        } catch {
            append(error.localizedDescription, kind: .error)
        }

        isConnecting = false
    }

    func sendCommand() async {
        let submittedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        command = ""

        guard !submittedCommand.isEmpty else { return }
        guard isConnected else { return }

        do {
            try await client.sendInput(submittedCommand)
        } catch {
            append(error.localizedDescription, kind: .error)
        }
    }

    func resizeTerminal(to size: CGSize) async {
        let nextSize = TerminalSize(viewSize: size)
        guard nextSize != terminalSize else { return }

        terminalSize = nextSize
        await client.resizeTerminal(columns: nextSize.columns, rows: nextSize.rows)
    }

    func disconnect() async {
        guard isConnected || isConnecting else { return }

        await client.disconnect()
        isConnected = false
        isConnecting = false
    }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .output(let text):
            appendRemoteOutput(text)
        case .status(let text):
            append(text, kind: .status)
        case .error(let text):
            append(text, kind: .error)
        case .disconnected:
            isConnected = false
            isConnecting = false
            activeRemoteLineID = nil
            append("Disconnected.", kind: .status)
        }
    }

    private func append(_ text: String, kind: TerminalLine.Kind) {
        lines.append(TerminalLine(text: text, kind: kind))
    }

    private func appendRemoteOutput(_ chunk: String) {
        let clearToken = "\u{001B}[2J\u{001B}[H"
        var normalized = chunk.replacingOccurrences(of: clearToken, with: "")

        if normalized.count != chunk.count {
            lines.removeAll()
            activeRemoteLineID = nil
        }

        normalized = stripANSIEscapeSequences(from: normalized)
        normalized.removeAll(where: \.isCarriageReturn)

        guard !normalized.isEmpty else { return }

        for character in normalized {
            if character == "\n" {
                activeRemoteLineID = nil
                continue
            }

            appendCharacterToRemoteLine(character)
        }
    }

    private func appendCharacterToRemoteLine(_ character: Character) {
        if let activeRemoteLineID,
           let index = lines.firstIndex(where: { $0.id == activeRemoteLineID }) {
            lines[index].text.append(character)
            return
        }

        let line = TerminalLine(text: String(character), kind: .remoteOutput)
        activeRemoteLineID = line.id
        lines.append(line)
    }

    private func stripANSIEscapeSequences(from text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            guard character == "\u{001B}" else {
                result.append(character)
                continue
            }

            guard let next = iterator.next() else { break }
            if next != "[" {
                continue
            }

            while let control = iterator.next() {
                if control.isASCIIControlTerminator {
                    break
                }
            }
        }

        return result
    }
}

private struct TerminalSize: Equatable {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    init(viewSize: CGSize) {
        let characterWidth = 8.5
        let rowHeight = 20.0
        self.columns = max(40, Int(viewSize.width / characterWidth))
        self.rows = max(12, Int(viewSize.height / rowHeight))
    }
}

private extension Character {
    var isASCIIControlTerminator: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return (64...126).contains(Int(scalar.value))
    }

    var isCarriageReturn: Bool {
        self == "\r"
    }
}
