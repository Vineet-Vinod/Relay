//
//  RelayAPIClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

@MainActor
final class RelayAPIClient {
    private let configurationStore: RelayConfigurationStore

    convenience init() {
        self.init(configurationStore: .shared)
    }

    init(configurationStore: RelayConfigurationStore) {
        self.configurationStore = configurationStore
    }

    func bootstrapApp(deviceName: String) async throws -> RelayAppRegistration {
        let serverURL = try configuredServerURL()
        let session = RelayURLSessionFactory.makeSession(allowInsecureTLS: configurationStore.allowsInsecureTLS())

        struct RequestBody: Codable {
            let deviceName: String

            enum CodingKeys: String, CodingKey {
                case deviceName = "device_name"
            }
        }

        let request = try request(
            url: serverURL.appending(path: "/v1/app/bootstrap"),
            method: "POST",
            body: RequestBody(deviceName: deviceName),
            bearerToken: nil
        )

        let registration: RelayAppRegistration = try await send(request, using: session)
        try configurationStore.saveRegistration(registration)
        return registration
    }

    func fetchDevices() async throws -> [RelayPairedDevice] {
        let registration = try registration()
        let serverURL = try configuredServerURL()
        let session = RelayURLSessionFactory.makeSession(allowInsecureTLS: configurationStore.allowsInsecureTLS())
        let request = try request(
            url: serverURL.appending(path: "/v1/devices"),
            method: "GET",
            body: Optional<String>.none,
            bearerToken: registration.appToken
        )

        return try await send(request, using: session)
    }

    func createPairingCode() async throws -> RelayPairingCode {
        let registration = try registration()
        let serverURL = try configuredServerURL()
        let session = RelayURLSessionFactory.makeSession(allowInsecureTLS: configurationStore.allowsInsecureTLS())
        let request = try request(
            url: serverURL.appending(path: "/v1/pairings"),
            method: "POST",
            body: Optional<String>.none,
            bearerToken: registration.appToken
        )

        return try await send(request, using: session)
    }

    func createSession(for deviceID: UUID, columns: Int, rows: Int) async throws -> RelaySessionBootstrap {
        let registration = try registration()
        let serverURL = try configuredServerURL()
        let session = RelayURLSessionFactory.makeSession(allowInsecureTLS: configurationStore.allowsInsecureTLS())

        struct RequestBody: Codable {
            let deviceID: UUID
            let cols: Int
            let rows: Int

            enum CodingKeys: String, CodingKey {
                case deviceID = "device_id"
                case cols
                case rows
            }
        }

        let request = try request(
            url: serverURL.appending(path: "/v1/sessions"),
            method: "POST",
            body: RequestBody(deviceID: deviceID, cols: columns, rows: rows),
            bearerToken: registration.appToken
        )

        return try await send(request, using: session)
    }

    private func configuredServerURL() throws -> URL {
        guard let url = configurationStore.configuredServerURL() else {
            throw RelaySessionError.missingServerURL
        }

        return url
    }

    private func registration() throws -> RelayAppRegistration {
        guard let registration = configurationStore.registration() else {
            throw RelaySessionError.missingRegistration
        }

        return registration
    }

    private func request<Body: Encodable>(
        url: URL,
        method: String,
        body: Body?,
        bearerToken: String?
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.relay.encode(body)
        }

        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest, using session: URLSession) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RelaySessionError.invalidResponse
        }

        if (200...299).contains(httpResponse.statusCode) {
            return try JSONDecoder.relay.decode(Response.self, from: data)
        }

        if let serverError = try? JSONDecoder().decode(RelayServerErrorEnvelope.self, from: data) {
            throw RelaySessionError.serverError(serverError.error)
        }

        throw RelaySessionError.invalidResponse
    }
}
