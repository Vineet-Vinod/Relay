//
//  RelaySessionClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import OSLog

@MainActor
final class RelaySessionClient: NSObject, TerminalSessionClient {
    let host: Host

    private let logger = Logger(subsystem: "Relay", category: "RelaySessionClient")
    private let apiClient: RelayAPIClient
    private let configurationStore: RelayConfigurationStore

    private var eventHandler: (@MainActor @Sendable (TerminalEvent) -> Void)?
    private var webSocketTask: URLSessionWebSocketTask?
    private var webSocketSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var sessionID: String?
    private var isConnected = false

    init(
        host: Host,
        apiClient: RelayAPIClient,
        configurationStore: RelayConfigurationStore
    ) {
        self.host = host
        self.apiClient = apiClient
        self.configurationStore = configurationStore
    }

    convenience init(host: Host) {
        let configurationStore = RelayConfigurationStore.shared
        self.init(
            host: host,
            apiClient: RelayAPIClient(configurationStore: configurationStore),
            configurationStore: configurationStore
        )
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (TerminalEvent) -> Void)?) {
        eventHandler = handler
    }

    func connect() async throws {
        guard case .relay(let target) = host.transport else {
            throw RelaySessionError.invalidResponse
        }

        do {
            let bootstrap = try await apiClient.createSession(for: target.deviceID, columns: 80, rows: 24)
            let request = try websocketRequest(for: bootstrap)
            let session = RelayURLSessionFactory.makeSession(allowInsecureTLS: configurationStore.allowsInsecureTLS())
            let task = session.webSocketTask(with: request)

            logger.info(
                "Opening Relay websocket for \(self.host.name, privacy: .public) at \(bootstrap.websocketURL.absoluteString, privacy: .public)"
            )

            webSocketSession = session
            webSocketTask = task
            sessionID = bootstrap.sessionID
            task.resume()

            let ready = try await waitForReadyMessage(on: task)
            guard ready else {
                throw RelaySessionError.sessionRejected("Relay could not start the remote shell session.")
            }

            isConnected = true
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        } catch {
            logger.error("Relay websocket connect failed for \(self.host.name, privacy: .public): \(String(describing: error), privacy: .public)")
            resetConnectionState()
            throw mapRelayTransportError(
                error,
                serverURL: configurationStore.configuredServerURL(),
                operation: "the terminal session"
            )
        }
    }

    func sendRawInput(_ bytes: [UInt8]) async throws {
        guard isConnected, let webSocketTask, let sessionID else {
            throw RelaySessionError.notConnected
        }

        let message = RelaySessionEnvelope(
            type: "session.input",
            sessionID: sessionID,
            payload: RelaySessionPayload(dataBase64: Data(bytes).base64EncodedString())
        )
        try await send(message, on: webSocketTask)
    }

    func resizeTerminal(columns: Int, rows: Int) async {
        guard isConnected, let webSocketTask, let sessionID else {
            return
        }

        let message = RelaySessionEnvelope(
            type: "session.resize",
            sessionID: sessionID,
            payload: RelaySessionPayload(cols: columns, rows: rows)
        )

        try? await send(message, on: webSocketTask)
    }

    func disconnect() async {
        if let webSocketTask, let sessionID {
            let closeEnvelope = RelaySessionEnvelope(
                type: "session.close",
                sessionID: sessionID,
                payload: RelaySessionPayload(reason: "client_disconnect")
            )
            try? await send(closeEnvelope, on: webSocketTask)
        }

        resetConnectionState()
    }

    private func resetConnectionState() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        webSocketSession?.invalidateAndCancel()
        webSocketSession = nil
        isConnected = false
        sessionID = nil
    }

    private func websocketRequest(for bootstrap: RelaySessionBootstrap) throws -> URLRequest {
        guard var components = URLComponents(url: bootstrap.websocketURL, resolvingAgainstBaseURL: false) else {
            throw RelaySessionError.invalidServerURL
        }

        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "session_token", value: bootstrap.sessionToken)
        ]

        guard let url = components.url else {
            throw RelaySessionError.invalidServerURL
        }

        return URLRequest(url: url)
    }

    private func waitForReadyMessage(on task: URLSessionWebSocketTask) async throws -> Bool {
        while true {
            let message = try await task.receive()
            let envelope = try decodeEnvelope(from: message)

            switch envelope.type {
            case "session.ready":
                eventHandler?(.status("Relay connected to \(host.name)."))
                return true
            case "session.waiting":
                if let detail = envelope.payload?.message {
                    eventHandler?(.status(detail))
                }
            case "error":
                let message = envelope.payload?.message ?? "Relay rejected the session."
                throw RelaySessionError.sessionRejected(message)
            case "session.closed":
                let reason = envelope.payload?.reason ?? "Relay closed the session before the shell was ready."
                throw RelaySessionError.sessionRejected(reason)
            default:
                break
            }
        }
    }

    private func receiveLoop() async {
        guard let webSocketTask else {
            return
        }

        while !Task.isCancelled {
            do {
                let message = try await webSocketTask.receive()
                let envelope = try decodeEnvelope(from: message)
                handle(envelope)
            } catch {
                if !Task.isCancelled {
                    logger.error("Relay receive loop ended for \(self.host.name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                break
            }
        }

        isConnected = false
        eventHandler?(.disconnected)
    }

    private func handle(_ envelope: RelaySessionEnvelope) {
        switch envelope.type {
        case "session.output":
            guard let payload = envelope.payload?.dataBase64,
                  let data = Data(base64Encoded: payload) else {
                return
            }

            eventHandler?(.output(Array(data)))
        case "status":
            if let message = envelope.payload?.message {
                eventHandler?(.status(message))
            }
        case "error":
            eventHandler?(.error(envelope.payload?.message ?? "Relay reported a session error."))
        case "session.closed":
            if let reason = envelope.payload?.reason, !reason.isEmpty {
                eventHandler?(.status(reason))
            }
            eventHandler?(.disconnected)
        default:
            break
        }
    }

    private func decodeEnvelope(from message: URLSessionWebSocketTask.Message) throws -> RelaySessionEnvelope {
        switch message {
        case .string(let string):
            guard let data = string.data(using: .utf8) else {
                throw RelaySessionError.invalidResponse
            }

            return try JSONDecoder.relay.decode(RelaySessionEnvelope.self, from: data)
        case .data(let data):
            return try JSONDecoder.relay.decode(RelaySessionEnvelope.self, from: data)
        @unknown default:
            throw RelaySessionError.invalidResponse
        }
    }

    private func send(_ envelope: RelaySessionEnvelope, on task: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder.relay.encode(envelope)
        guard let string = String(data: data, encoding: .utf8) else {
            throw RelaySessionError.invalidResponse
        }

        try await task.send(.string(string))
    }
}
