//
//  SSHClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import Security

struct TerminalLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
    let kind: Kind

    enum Kind {
        case remoteOutput
        case status
        case error
    }
}

enum TerminalEvent: Sendable {
    case output([UInt8])
    case status(String)
    case error(String)
    case disconnected
}

struct SSHHostTrustChallenge: Hashable, Sendable {
    let algorithm: String
    let base64Payload: String
    let fingerprint: String
    let firstSeenAt: Date
}

@MainActor
protocol SSHClient {
    func setEventHandler(_ handler: (@MainActor @Sendable (TerminalEvent) -> Void)?)
    func connect(to host: Host) async throws
    func provisionSavedKey(for host: Host) async throws
    func sendInput(_ text: String) async throws
    func sendRawInput(_ bytes: [UInt8]) async throws
    func resizeTerminal(columns: Int, rows: Int) async
    func disconnect() async
}

extension SSHClient {
    func sendInput(_ text: String) async throws {
        guard !text.isEmpty else {
            throw SSHClientError.emptyCommand
        }

        try await sendRawInput(Array(text.utf8) + [0x0D])
    }
}

enum SSHTransportMode: Hashable, Codable {
    case mock
    case real
}

enum SSHClientFactory {
    @MainActor
    static func makeClient(for host: Host) -> SSHClient {
        switch host.transportMode {
        case .mock:
            MockSSHClient()
        case .real:
            RealSSHClient()
        }
    }
}

enum SSHClientError: LocalizedError {
    case emptyCommand
    case missingPassword
    case missingPrivateKey
    case notConnected
    case authenticationFailed
    case invalidChannelType
    case commandDidNotReturnOutput
    case pseudoTerminalRequestFailed
    case shellRequestFailed
    case unsupportedHostKey
    case untrustedHostKey(SSHHostTrustChallenge)
    case hostKeyMismatch(expected: String, actual: String)
    case keyProvisioningFailed(String)
    case publicKeyVerificationFailed
    case keychainFailure(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            "Enter a command to run."
        case .missingPassword:
            "No SSH password is configured for this device."
        case .missingPrivateKey:
            "No saved SSH key is configured for this device."
        case .notConnected:
            "No active SSH session."
        case .authenticationFailed:
            "Authentication failed. Check the SSH credential and try again."
        case .invalidChannelType:
            "The SSH server returned an unexpected channel type."
        case .commandDidNotReturnOutput:
            "The SSH command completed without returning output."
        case .pseudoTerminalRequestFailed:
            "The SSH server rejected the terminal request."
        case .shellRequestFailed:
            "The SSH server rejected the shell request."
        case .unsupportedHostKey:
            "Relay could not serialize the SSH host key for trust validation."
        case .untrustedHostKey(let hostKey):
            "Verify the SSH host fingerprint before connecting: \(hostKey.fingerprint)"
        case .hostKeyMismatch(let expected, let actual):
            "SSH host identity changed. Expected \(expected), received \(actual)."
        case .keyProvisioningFailed(let message):
            message
        case .publicKeyVerificationFailed:
            "Relay installed the public key but could not verify a key-based login."
        case .keychainFailure:
            "Relay could not access the device keychain."
        }
    }
}

@MainActor
final class MockSSHClient: SSHClient {
    private var activeHost: Host?
    private var currentDirectory = ""
    private var pendingInput = ""
    private var eventHandler: (@MainActor @Sendable (TerminalEvent) -> Void)?

    func setEventHandler(_ handler: (@MainActor @Sendable (TerminalEvent) -> Void)?) {
        self.eventHandler = handler
    }

    func connect(to host: Host) async throws {
        try await Task.sleep(for: .milliseconds(350))
        activeHost = host
        currentDirectory = "/home/\(host.username)"
        emit(.status("Connected."))
        emitPrompt()
    }

    func provisionSavedKey(for host: Host) async throws {
        guard host.usesPasswordAuthentication else {
            throw SSHClientError.missingPassword
        }

        emit(.status("Saved SSH key enabled for future logins."))
    }

    func sendRawInput(_ bytes: [UInt8]) async throws {
        guard let activeHost else {
            throw SSHClientError.notConnected
        }

        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch scalar.value {
            case 0x08, 0x7F:
                if !pendingInput.isEmpty {
                    pendingInput.removeLast()
                    emitOutput("\u{0008} \u{0008}")
                }
            case 0x0D, 0x0A:
                let command = pendingInput.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingInput.removeAll()
                emitOutput("\r\n")
                try await Task.sleep(for: .milliseconds(80))
                try handle(command, on: activeHost)
                emitPrompt()
            case 0x1B:
                emitOutput(String(scalar))
            default:
                let text = String(scalar)
                pendingInput.append(text)
                emitOutput(text)
            }
        }
    }

    func resizeTerminal(columns: Int, rows: Int) async {
        _ = (columns, rows)
    }

    func disconnect() async {
        activeHost = nil
        emit(.disconnected)
    }

    private func emitPrompt() {
        guard let activeHost else { return }
        emitOutput("\(activeHost.username)@\(activeHost.hostname):\(currentDirectory)$ ")
    }

    private func handle(_ command: String, on activeHost: Host) throws {
        if command.isEmpty {
            return
        }

        switch command {
        case "pwd":
            emitOutput("\(currentDirectory)\r\n")
        case "whoami":
            emitOutput("\(activeHost.username)\r\n")
        case "hostname":
            emitOutput("\(activeHost.hostname)\r\n")
        case "ls":
            emitOutput("\u{001B}[32mlogs\u{001B}[0m  \u{001B}[34mreleases\u{001B}[0m  shared\r\n")
        case "help":
            emitOutput("Try pwd, whoami, hostname, ls, cd /tmp, uname -a, colors\r\n")
        case "clear":
            emitOutput("\u{001B}[2J\u{001B}[H")
        case "uname -a":
            emitOutput("MockOS relay 1.0.0 Darwin Kernel Version\r\n")
        case "colors":
            emitOutput("\u{001B}[31mred\u{001B}[0m \u{001B}[32mgreen\u{001B}[0m \u{001B}[34mblue\u{001B}[0m \u{001B}[7minverse\u{001B}[0m\r\n")
        default:
            if let directory = command.removingPrefix("cd ") {
                currentDirectory = resolve(path: directory, from: currentDirectory)
            } else {
                emitOutput("mock@\(activeHost.hostname): command not found: \(command)\r\n")
            }
        }
    }

    private func emit(_ event: TerminalEvent) {
        guard let eventHandler else { return }
        eventHandler(event)
    }

    private func emitOutput(_ text: String) {
        emit(.output(Array(text.utf8)))
    }

    private func resolve(path: String, from base: String) -> String {
        guard !path.isEmpty else { return base }

        if path.hasPrefix("/") {
            return normalize(path)
        }

        return normalize(base + "/" + path)
    }

    private func normalize(_ path: String) -> String {
        var components: [Substring] = []

        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }

        return "/" + components.joined(separator: "/")
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
