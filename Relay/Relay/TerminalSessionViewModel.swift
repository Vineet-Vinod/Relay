//
//  TerminalSessionViewModel.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Observation
import Foundation

@MainActor
@Observable
final class TerminalSessionViewModel {
    let host: Host

    var lines: [TerminalLine] = []
    var command = ""
    var isConnecting = false
    var isConnected = false
    var isRunningCommand = false

    private let client: SSHClient

    init(host: Host, client: SSHClient? = nil) {
        self.host = host
        self.client = client ?? MockSSHClient()
    }

    func connect() async {
        guard !isConnecting, !isConnected else { return }

        isConnecting = true
        append("Connecting to \(host.username)@\(host.hostname):\(host.port)...", kind: .status)

        do {
            try await client.connect(to: host)
            isConnected = true
            append("Connected.", kind: .status)
            append("Type `help` to see mock commands.", kind: .status)
        } catch {
            append(error.localizedDescription, kind: .error)
        }

        isConnecting = false
    }

    func runCommand() async {
        let submittedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        command = ""

        guard !submittedCommand.isEmpty else { return }
        guard isConnected, !isRunningCommand else { return }

        isRunningCommand = true
        append("$ \(submittedCommand)", kind: .localPrompt)

        do {
            let output = try await client.execute(submittedCommand)

            if submittedCommand == "clear" {
                lines.removeAll()
            } else if !output.isEmpty {
                append(output, kind: .remoteOutput)
            }
        } catch {
            append(error.localizedDescription, kind: .error)
        }

        isRunningCommand = false
    }

    func disconnect() async {
        guard isConnected || isConnecting else { return }

        await client.disconnect()
        isConnected = false
        append("Disconnected.", kind: .status)
    }

    private func append(_ text: String, kind: TerminalLine.Kind) {
        lines.append(TerminalLine(text: text, kind: kind))
    }
}
