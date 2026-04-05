//
//  VoiceAssistant.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

enum VoiceAssistant: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case codex
    case claude

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    var callLabel: String {
        "\(displayName) Voice"
    }

    var systemImage: String {
        switch self {
        case .codex:
            return "chevron.left.forwardslash.chevron.right"
        case .claude:
            return "sparkles"
        }
    }

    var isExperimental: Bool {
        switch self {
        case .codex:
            return false
        case .claude:
            return true
        }
    }
}

enum VoiceAssistantBridgeEvent: Sendable {
    case sessionReady(sessionID: String?, cwd: String?)
    case cwdResolved(String)
    case processStarted(Int32)
    case assistantDelta(String)
    case assistantDone
    case toolStatus(String)
    case error(message: String, recoverable: Bool)
}

@MainActor
protocol VoiceAssistantBridgeClient: AnyObject {
    var assistant: VoiceAssistant { get }

    func prepare(workspacePath: String) async throws -> String
    func sendTurn(
        _ prompt: String,
        workspacePath: String,
        onEvent: @escaping @MainActor (VoiceAssistantBridgeEvent) -> Void
    ) async throws
    func interruptCurrentTurn() async
    func endSession() async
}

enum VoiceAssistantBridgeFactory {
    @MainActor
    static func makeBridge(
        for assistant: VoiceAssistant,
        host: Host,
        credentials: SSHCredentialStore = RelayServices.sshCredentials
    ) -> any VoiceAssistantBridgeClient {
        switch assistant {
        case .codex:
            return CodexBridgeClient(host: host, credentials: credentials)
        case .claude:
            return ClaudeBridgeClient(host: host, credentials: credentials)
        }
    }
}
