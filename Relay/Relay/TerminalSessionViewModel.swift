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
    var host: Host

    var messages: [TerminalLine] = []
    var latestErrorMessage: String?
    var isConnecting = false
    var isConnected = false
    var isShowingKeySetupPrompt = false
    var isShowingHostTrustPrompt = false
    var isProvisioningSavedKey = false
    var canReconnectWithPassword = false
    var didDisconnectUnexpectedly = false
    var pendingHostTrust: SSHHostTrustChallenge?

    var onTerminalOutput: (@MainActor ([UInt8]) -> Void)?
    var supportsVoiceSession: Bool { host.supportsVoiceCodex }
    var isDirectSSHSession: Bool { !host.usesRelayTransport }

    private let credentials: SSHCredentialStore
    private var client: TerminalSessionClient
    private var isDisconnectingManually = false

    init(host: Host, client: TerminalSessionClient? = nil, credentials: SSHCredentialStore = RelayServices.sshCredentials) {
        self.host = host
        self.client = client ?? TerminalSessionClientFactory.makeClient(for: host)
        self.credentials = credentials
        bindEventHandler()
    }

    func connect() async {
        guard !isConnecting, !isConnected else { return }

        rebuildClient(for: host)
        isConnecting = true
        latestErrorMessage = nil
        canReconnectWithPassword = false
        didDisconnectUnexpectedly = false
        isDisconnectingManually = false
        appendMessage(connectionMessage(for: host), kind: .status)

        do {
            try await client.connect()
            isConnected = true
            latestErrorMessage = nil
            if host.usesPasswordAuthentication, isDirectSSHSession {
                isShowingKeySetupPrompt = credentials.shouldOfferKeySetup(for: host.remoteIdentity)
            }
        } catch let error as SSHClientError {
            handleConnectError(error)
        } catch let error as RelaySessionError {
            latestErrorMessage = error.localizedDescription
            appendMessage(error.localizedDescription, kind: .error)
        } catch {
            let description = describe(error)
            latestErrorMessage = description
            appendMessage(description, kind: .error)
            if isDirectSSHSession,
               !host.usesPasswordAuthentication,
               RelayPreferences.shared.allowsPasswordFallback {
                canReconnectWithPassword = true
            }
        }

        isConnecting = false
    }

    func enableSavedKey() async {
        guard let directSSHClient,
              host.usesPasswordAuthentication,
              !isProvisioningSavedKey else { return }

        isShowingKeySetupPrompt = false
        isProvisioningSavedKey = true
        latestErrorMessage = nil
        appendMessage("Generating and installing a saved SSH key...", kind: .status)

        do {
            try await directSSHClient.provisionSavedKey()
            host.authentication = .automatic
            canReconnectWithPassword = false
            latestErrorMessage = nil
            appendMessage("Saved SSH key enabled for future logins.", kind: .status)
        } catch {
            let description = describe(error)
            latestErrorMessage = description
            appendMessage(description, kind: .error)
        }

        isProvisioningSavedKey = false
    }

    func dismissSavedKeyPrompt() {
        guard isDirectSSHSession else { return }
        isShowingKeySetupPrompt = false
        credentials.dismissKeySetupPrompt(for: host.remoteIdentity)
    }

    func trustPendingHostKey() async {
        guard isDirectSSHSession, let pendingHostTrust else { return }

        credentials.saveTrustedHostKey(
            TrustedSSHHostKey(
                algorithm: pendingHostTrust.algorithm,
                base64Payload: pendingHostTrust.base64Payload,
                fingerprint: pendingHostTrust.fingerprint,
                firstSeenAt: pendingHostTrust.firstSeenAt
            ),
            for: host.endpointIdentity
        )
        latestErrorMessage = nil
        isShowingHostTrustPrompt = false
        self.pendingHostTrust = nil
        didDisconnectUnexpectedly = false
        appendMessage("Trusted SSH host fingerprint \(pendingHostTrust.fingerprint).", kind: .status)
        await reconnect(with: host)
    }

    func rejectPendingHostKey() {
        guard isDirectSSHSession, pendingHostTrust != nil else { return }

        latestErrorMessage = nil
        isShowingHostTrustPrompt = false
        pendingHostTrust = nil
        appendMessage("Connection cancelled. SSH host key was not trusted.", kind: .status)
    }

    func reconnect(with host: Host) async {
        await disconnect()
        self.host = host
        rebuildClient(for: host)
        pendingHostTrust = nil
        isShowingHostTrustPrompt = false
        latestErrorMessage = nil
        didDisconnectUnexpectedly = false
        await connect()
    }

    func sendRawInput(_ bytes: [UInt8]) async {
        guard isConnected else { return }

        do {
            try await client.sendRawInput(bytes)
        } catch {
            let description = describe(error)
            latestErrorMessage = description
            appendMessage(description, kind: .error)
        }
    }

    func resizeTerminal(columns: Int, rows: Int) async {
        guard columns > 0, rows > 0 else { return }
        await client.resizeTerminal(columns: columns, rows: rows)
    }

    func disconnect() async {
        guard isConnected || isConnecting else { return }

        didDisconnectUnexpectedly = false
        isDisconnectingManually = true
        await client.disconnect()
        isConnected = false
        isConnecting = false
        isDisconnectingManually = false
    }

    func dismissLatestError() {
        latestErrorMessage = nil
    }

    var pendingHostTrustSummary: String {
        guard let pendingHostTrust else { return "" }
        return "\(pendingHostTrust.algorithm) \(pendingHostTrust.fingerprint)"
    }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .output(let bytes):
            onTerminalOutput?(bytes)
        case .status(let text):
            appendMessage(text, kind: .status)
        case .error(let text):
            latestErrorMessage = text
            appendMessage(text, kind: .error)
        case .disconnected:
            didDisconnectUnexpectedly = !isDisconnectingManually && (isConnected || isConnecting)
            isConnected = false
            isConnecting = false
            isDisconnectingManually = false
            appendMessage("Disconnected.", kind: .status)
        }
    }

    private func appendMessage(_ text: String, kind: TerminalLine.Kind) {
        messages.append(TerminalLine(text: text, kind: kind))
    }

    private func handleConnectError(_ error: SSHClientError) {
        guard isDirectSSHSession else {
            latestErrorMessage = error.localizedDescription
            appendMessage(error.localizedDescription, kind: .error)
            return
        }

        latestErrorMessage = error.localizedDescription
        appendMessage(error.localizedDescription, kind: .error)

        switch error {
        case .untrustedHostKey(let hostKey):
            pendingHostTrust = hostKey
            isShowingHostTrustPrompt = true
        default:
            if !host.usesPasswordAuthentication && RelayPreferences.shared.allowsPasswordFallback {
                canReconnectWithPassword = true
            }
        }
    }

    private var directSSHClient: DirectSSHSessionClient? {
        client as? DirectSSHSessionClient
    }

    private func rebuildClient(for host: Host) {
        client = TerminalSessionClientFactory.makeClient(for: host)
        bindEventHandler()
    }

    private func bindEventHandler() {
        client.setEventHandler { [weak self] event in
            self?.handle(event)
        }
    }

    private func connectionMessage(for host: Host) -> String {
        if host.usesRelayTransport {
            return "Connecting to \(host.name) through Relay..."
        }

        return "Connecting to \(host.username)@\(host.hostname):\(host.port)..."
    }

    private func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }

        let fallback = String(describing: error)
        if !fallback.isEmpty {
            return fallback
        }

        return (error as NSError).localizedDescription
    }
}
