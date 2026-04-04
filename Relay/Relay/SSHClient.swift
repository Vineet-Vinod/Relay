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

protocol SSHClient {
    func connect(to host: Host) async throws
    func execute(_ command: String) async throws -> String
    func disconnect() async
}

enum SSHClientError: LocalizedError {
    case emptyCommand

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            "Enter a command to run."
        }
    }
}

final class MockSSHClient: SSHClient {
    private var activeHost: Host?

    func connect(to host: Host) async throws {
        try await Task.sleep(for: .milliseconds(350))
        activeHost = host
    }

    func execute(_ command: String) async throws -> String {
        guard let activeHost else {
            return "No active session."
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

// Replace this with a real SSH transport backed by SwiftNIO SSH, libssh2, or
// another iOS-compatible client library once package integration is in place.
