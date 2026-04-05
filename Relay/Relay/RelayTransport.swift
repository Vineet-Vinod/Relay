//
//  RelayTransport.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

struct RelaySessionTarget: Hashable, Codable, Sendable {
    let deviceID: UUID
    let deviceName: String
    let ownerName: String
    let platform: String
}

enum HostTransport: Hashable, Codable {
    case directSSH
    case relay(RelaySessionTarget)
}

struct RelayAppRegistration: Hashable, Codable, Sendable {
    let appID: String
    let appToken: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case appToken = "app_token"
        case createdAt = "created_at"
    }
}

struct RelayPairingCode: Hashable, Codable, Sendable {
    let code: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case code
        case expiresAt = "expires_at"
    }
}

struct RelayPairedDevice: Hashable, Codable, Sendable {
    let id: UUID
    let name: String
    let ownerName: String
    let platform: String
    let online: Bool
    let lastSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerName = "owner_name"
        case platform
        case online
        case lastSeenAt = "last_seen_at"
    }
}

struct RelaySessionBootstrap: Hashable, Codable, Sendable {
    let sessionID: String
    let websocketURL: URL
    let sessionToken: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case websocketURL = "websocket_url"
        case sessionToken = "session_token"
    }
}

struct RelaySessionEnvelope: Hashable, Codable, Sendable {
    let type: String
    let sessionID: String?
    let payload: RelaySessionPayload?

    init(type: String, sessionID: String? = nil, payload: RelaySessionPayload? = nil) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case payload
    }
}

struct RelaySessionPayload: Hashable, Codable, Sendable {
    let message: String?
    let dataBase64: String?
    let cols: Int?
    let rows: Int?
    let reason: String?

    init(
        message: String? = nil,
        dataBase64: String? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        reason: String? = nil
    ) {
        self.message = message
        self.dataBase64 = dataBase64
        self.cols = cols
        self.rows = rows
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case message
        case dataBase64 = "data_base64"
        case cols
        case rows
        case reason
    }
}

enum RelaySessionError: LocalizedError {
    case missingServerURL
    case missingRegistration
    case invalidServerURL
    case invalidResponse
    case responseDecodingFailed(String)
    case notConnected
    case sessionRejected(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .missingServerURL:
            return "Configure the Relay server URL in Settings."
        case .missingRegistration:
            return "Register this iPhone with your Relay server in Settings."
        case .invalidServerURL:
            return "Relay could not parse the configured server URL."
        case .invalidResponse:
            return "Relay received an invalid response from the server."
        case .responseDecodingFailed(let message):
            return message
        case .notConnected:
            return "No active Relay session."
        case .sessionRejected(let reason):
            return reason
        case .serverError(let message):
            return message
        }
    }
}
