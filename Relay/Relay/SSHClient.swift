//
//  SSHClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

struct TerminalLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let kind: Kind

    enum Kind {
        case localPrompt
        case remoteOutput
        case status
        case error
    }
}

@MainActor
protocol SSHClient {
    func connect(to host: Host) async throws
    func execute(_ command: String) async throws -> String
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
        }
    }
}

@MainActor
final class MockSSHClient: SSHClient {
    private var activeHost: Host?

    func connect(to host: Host) async throws {
        try await Task.sleep(for: .milliseconds(350))
        activeHost = host
    }

    func execute(_ command: String) async throws -> String {
        guard let activeHost else {
            throw SSHClientError.notConnected
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SSHClientError.emptyCommand
        }

        try await Task.sleep(for: .milliseconds(180))

        switch trimmed {
        case "pwd":
            return "/home/\(activeHost.username)"
        case "whoami":
            return activeHost.username
        case "hostname":
            return activeHost.hostname
        case "ls":
            return "logs\nreleases\nshared"
        case "help":
            return "Try pwd, whoami, hostname, ls, uname -a"
        case "clear":
            return ""
        default:
            return """
            mock@\(activeHost.hostname): command not found: \(trimmed)
            """
        }
    }

    func disconnect() async {
        activeHost = nil
    }
}
