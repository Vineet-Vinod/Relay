//
//  RelayMeshProvider.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

@MainActor
final class RelayMeshProvider: MeshProvider {
    let displayName = "Relay"
    let supportsManualHostManagement = false

    private let apiClient: RelayAPIClient
    private let configurationStore: RelayConfigurationStore

    convenience init() {
        let configurationStore = RelayConfigurationStore.shared
        self.init(
            apiClient: RelayAPIClient(configurationStore: configurationStore),
            configurationStore: configurationStore
        )
    }

    init(
        apiClient: RelayAPIClient,
        configurationStore: RelayConfigurationStore
    ) {
        self.apiClient = apiClient
        self.configurationStore = configurationStore
    }

    func currentSnapshot() async -> MeshProviderSnapshot {
        guard configurationStore.configuredServerURL() != nil else {
            return MeshProviderSnapshot(
                status: .unavailable(message: "Set your Relay server URL in Settings to load paired devices.")
            )
        }

        guard configurationStore.registration() != nil else {
            return MeshProviderSnapshot(
                status: .unavailable(message: "Register this iPhone with the Relay server in Settings, then pair a Mac agent.")
            )
        }

        return MeshProviderSnapshot(
            status: .ready(
                title: "Relay Devices",
                detail: "Paired Macs connect through your Relay HTTPS server."
            )
        )
    }

    func fetchPeers() async throws -> [PeerDevice] {
        let serverLabel = configurationStore.configuredServerURL()?.host ?? "Relay"
        return try await apiClient.fetchDevices().map { device in
            PeerDevice(
                id: device.id,
                providerIdentifier: MeshProviderKind.relay.rawValue,
                name: device.name,
                networkAddress: "via \(serverLabel)",
                meshHostname: nil,
                port: 0,
                sshUsername: device.ownerName,
                isOnline: device.online,
                operatingSystem: device.platform,
                ownerName: device.ownerName,
                connectionKind: .relay,
                supportsVoiceSession: false
            )
        }
    }

    func endpoint(for peer: PeerDevice) async throws -> Host {
        Host(
            id: peer.id,
            name: peer.name,
            hostname: peer.name,
            port: 0,
            username: peer.ownerName,
            defaultCodexPath: nil,
            authentication: .automatic,
            transport: .relay(
                RelaySessionTarget(
                    deviceID: peer.id,
                    deviceName: peer.name,
                    ownerName: peer.ownerName,
                    platform: peer.operatingSystem
                )
            )
        )
    }

    func saveHost(_ host: SavedDevice) async throws {
        throw MeshProviderError.endpointUnavailable("Relay devices are managed by the server and agent pairing flow.")
    }

    func deletePeer(_ peer: PeerDevice) async throws {
        throw MeshProviderError.endpointUnavailable("Unpair Relay devices from the server instead of deleting them locally.")
    }
}
