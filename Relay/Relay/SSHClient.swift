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

enum SSHClientFactory {
    @MainActor
    static func makeClient() -> SSHClient {
        RealSSHClient()
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
