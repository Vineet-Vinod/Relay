//
//  RelayVPNController.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import CryptoKit
import Foundation
import NetworkExtension
import UIKit

@MainActor
final class RelayVPNController: ObservableObject {
    @Published var controlServerURLText: String
    @Published var peerIdentifier: String
    @Published private(set) var profileRecord: RelayVPNProfileRecord?
    @Published private(set) var presentationState: RelayVPNPresentationState = .notConfigured
    @Published private(set) var isBusy = false
    @Published private(set) var lastErrorMessage: String?

    private let defaults: UserDefaults
    private let apiClient: RelayVPNAPIClient
    private let tunnelManager: RelayTunnelManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        apiClient: RelayVPNAPIClient = RelayVPNAPIClient(),
        tunnelManager: RelayTunnelManager = RelayTunnelManager()
    ) {
        self.defaults = defaults
        self.apiClient = apiClient
        self.tunnelManager = tunnelManager

        controlServerURLText = defaults.string(forKey: RelayDefaultsKey.relayVPNControlServerURL) ?? ""
        peerIdentifier = defaults.string(forKey: RelayDefaultsKey.relayVPNPeerIdentifier) ??
            RelayVPNController.makeDefaultPeerIdentifier()
        profileRecord = RelayVPNController.loadStoredProfileRecord(defaults: defaults, decoder: JSONDecoder())

        tunnelManager.onStatusDidChange = { [weak self] in
            self?.syncPresentationState()
        }
    }

    func load() async {
        controlServerURLText = defaults.string(forKey: RelayDefaultsKey.relayVPNControlServerURL) ?? controlServerURLText
        peerIdentifier = defaults.string(forKey: RelayDefaultsKey.relayVPNPeerIdentifier) ?? peerIdentifier
        profileRecord = Self.loadStoredProfileRecord(defaults: defaults, decoder: decoder)

        do {
            try await tunnelManager.refreshInstalledManager()
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        syncPresentationState()
    }

    func registerAndConnect() async {
        guard !isBusy else { return }
        isBusy = true
        lastErrorMessage = nil

        defer {
            isBusy = false
            syncPresentationState()
        }

        do {
            let controlServerURL = try normalizedControlServerURL(from: controlServerURLText)
            let trimmedPeerIdentifier = sanitizedPeerIdentifier(from: peerIdentifier)
            let keyPair = RelayVPNKeyPair.make()
            let response = try await apiClient.register(
                controlServerURL: controlServerURL,
                peerIdentifier: trimmedPeerIdentifier,
                publicKey: keyPair.publicKeyBase64
            )

            let configuration = RelayTunnelConfiguration(
                name: UIDevice.current.name,
                peerIdentifier: trimmedPeerIdentifier,
                controlServerURL: controlServerURL.absoluteString,
                clientPrivateKey: keyPair.privateKeyBase64,
                clientAddress: response.assigned_ip,
                serverPublicKey: response.server_public_key,
                serverEndpoint: response.server_endpoint,
                allowedIPs: ["0.0.0.0/0"],
                persistentKeepalive: response.persistent_keepalive
            )

            try await tunnelManager.install(configuration: configuration)

            let profileRecord = RelayVPNProfileRecord(
                peerIdentifier: trimmedPeerIdentifier,
                controlServerURL: controlServerURL.absoluteString,
                assignedAddress: response.assigned_ip,
                serverPublicKey: response.server_public_key,
                serverEndpoint: response.server_endpoint,
                persistentKeepalive: response.persistent_keepalive,
                registeredAt: Date()
            )
            controlServerURLText = controlServerURL.absoluteString
            peerIdentifier = trimmedPeerIdentifier
            persist(profileRecord: profileRecord)

            do {
                try tunnelManager.connect()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func connect() {
        guard !isBusy else { return }
        lastErrorMessage = nil

        do {
            try tunnelManager.connect()
        } catch {
            lastErrorMessage = error.localizedDescription
            syncPresentationState()
        }
    }

    func disconnect() {
        guard !isBusy else { return }
        lastErrorMessage = nil
        tunnelManager.disconnect()
        syncPresentationState()
    }

    func removeConfiguration() async {
        guard !isBusy else { return }
        isBusy = true
        lastErrorMessage = nil

        defer {
            isBusy = false
            syncPresentationState()
        }

        do {
            let peerIdentifier = try await tunnelManager.removeInstalledConfiguration() ?? profileRecord?.peerIdentifier
            if let peerIdentifier {
                try RelayTunnelKeychain.deleteConfiguration(peerIdentifier: peerIdentifier)
            }
            clearStoredProfileRecord()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func resetStoredState() async {
        await removeConfiguration()
        defaults.removeObject(forKey: RelayDefaultsKey.relayVPNControlServerURL)
        defaults.removeObject(forKey: RelayDefaultsKey.relayVPNPeerIdentifier)
        controlServerURLText = ""
        peerIdentifier = Self.makeDefaultPeerIdentifier()
        defaults.set(peerIdentifier, forKey: RelayDefaultsKey.relayVPNPeerIdentifier)
    }

    var canRegister: Bool {
        !controlServerURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !peerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !isBusy
    }

    var isConfigured: Bool {
        profileRecord != nil
    }

    private func persist(profileRecord: RelayVPNProfileRecord) {
        self.profileRecord = profileRecord
        defaults.set(controlServerURLText, forKey: RelayDefaultsKey.relayVPNControlServerURL)
        defaults.set(peerIdentifier, forKey: RelayDefaultsKey.relayVPNPeerIdentifier)

        if let data = try? encoder.encode(profileRecord) {
            defaults.set(data, forKey: RelayDefaultsKey.relayVPNProfileRecord)
        }

        syncPresentationState()
    }

    private func clearStoredProfileRecord() {
        profileRecord = nil
        defaults.removeObject(forKey: RelayDefaultsKey.relayVPNProfileRecord)
        syncPresentationState()
    }

    private func syncPresentationState() {
        if let lastErrorMessage {
            presentationState = .error(lastErrorMessage)
            return
        }

        switch tunnelManager.connectionStatus {
        case .connected:
            presentationState = .connected
        case .connecting:
            presentationState = .connecting
        case .disconnecting:
            presentationState = .disconnecting
        case .disconnected:
            presentationState = profileRecord == nil ? .notConfigured : .disconnected
        case .invalid:
            presentationState = profileRecord == nil ? .notConfigured : .invalid
        @unknown default:
            presentationState = .invalid
        }
    }

    private func normalizedControlServerURL(from rawValue: String) throws -> URL {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw RelayVPNError.invalidControlServerURL
        }

        guard let url = URL(string: trimmedValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw RelayVPNError.registrationRequiresHTTPOrHTTPS
        }

        return url
    }

    private func sanitizedPeerIdentifier(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let generated = Self.makeDefaultPeerIdentifier()
            defaults.set(generated, forKey: RelayDefaultsKey.relayVPNPeerIdentifier)
            return generated
        }

        defaults.set(trimmed, forKey: RelayDefaultsKey.relayVPNPeerIdentifier)
        return trimmed
    }

    private static func makeDefaultPeerIdentifier() -> String {
        "relay-ios-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func loadStoredProfileRecord(
        defaults: UserDefaults,
        decoder: JSONDecoder
    ) -> RelayVPNProfileRecord? {
        guard let data = defaults.data(forKey: RelayDefaultsKey.relayVPNProfileRecord) else {
            return nil
        }

        return try? decoder.decode(RelayVPNProfileRecord.self, from: data)
    }
}

private struct RelayVPNKeyPair {
    let privateKeyBase64: String
    let publicKeyBase64: String

    static func make() -> RelayVPNKeyPair {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return RelayVPNKeyPair(
            privateKeyBase64: privateKey.rawRepresentation.base64EncodedString(),
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
    }
}
