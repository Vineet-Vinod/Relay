//
//  SSHClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

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
    case output(String)
    case status(String)
    case error(String)
    case disconnected
}

@MainActor
protocol SSHClient {
    func setEventHandler(_ handler: (@MainActor @Sendable (TerminalEvent) -> Void)?)
    func connect(to host: Host) async throws
    func sendInput(_ text: String) async throws
    func resizeTerminal(columns: Int, rows: Int) async
    func disconnect() async
}

enum SSHTransportMode {
    case mock
    case real
}

enum SSHClientFactory {
    @MainActor
    static func makeClient() -> SSHClient {
        switch AppEnvironment.sshTransportMode {
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
    case notConnected
    case authenticationFailed
    case invalidChannelType
    case commandDidNotReturnOutput
    case pseudoTerminalRequestFailed
    case shellRequestFailed

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            "Enter a command to run."
        case .missingPassword:
            "No SSH password is configured for this device."
        case .notConnected:
            "No active SSH session."
        case .authenticationFailed:
            "Authentication failed. Check the SSH password and try again."
        case .invalidChannelType:
            "The SSH server returned an unexpected channel type."
        case .commandDidNotReturnOutput:
            "The SSH command completed without returning output."
        case .pseudoTerminalRequestFailed:
            "The SSH server rejected the terminal request."
        case .shellRequestFailed:
            "The SSH server rejected the shell request."
        }
    }
}

@MainActor
final class MockSSHClient: SSHClient {
    private var activeHost: Host?
    private var currentDirectory = ""
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

    func sendInput(_ text: String) async throws {
        guard let activeHost else {
            throw SSHClientError.notConnected
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            try await Task.sleep(for: .milliseconds(120))

            if trimmed.isEmpty {
                emitPrompt()
                continue
            }

            emit(.output("\(activeHost.username)@\(activeHost.hostname):\(currentDirectory)$ \(trimmed)\n"))

            switch trimmed {
            case "pwd":
                emit(.output("\(currentDirectory)\n"))
            case "whoami":
                emit(.output("\(activeHost.username)\n"))
            case "hostname":
                emit(.output("\(activeHost.hostname)\n"))
            case "ls":
                emit(.output("logs\nreleases\nshared\n"))
            case "help":
                emit(.output("Try pwd, whoami, hostname, ls, cd /tmp, uname -a\n"))
            case "clear":
                emit(.output("\u{001B}[2J\u{001B}[H"))
            case "uname -a":
                emit(.output("MockOS relay 1.0.0 Darwin Kernel Version\n"))
            default:
                if let directory = trimmed.removingPrefix("cd ") {
                    currentDirectory = resolve(path: directory, from: currentDirectory)
                } else {
                    emit(.output("mock@\(activeHost.hostname): command not found: \(trimmed)\n"))
                }
            }

            emitPrompt()
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
        emit(.output("\(activeHost.username)@\(activeHost.hostname):\(currentDirectory)$ "))
    }

    private func emit(_ event: TerminalEvent) {
        guard let eventHandler else { return }
        eventHandler(event)
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
