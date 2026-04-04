//
//  RelayVPNAPIClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

struct RelayVPNAPIClient {
    var session: URLSession = .shared

    func register(
        controlServerURL: URL,
        peerIdentifier: String,
        publicKey: String
    ) async throws -> RelayVPNRegistrationResponse {
        let endpoint = controlServerURL.appending(path: "register")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RelayVPNRegistrationRequest(
                user_id: peerIdentifier,
                public_key: publicKey
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RelayVPNError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw RelayVPNError.rejectedStatusCode(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(RelayVPNRegistrationResponse.self, from: data)
        } catch {
            throw RelayVPNError.invalidResponse
        }
    }
}
