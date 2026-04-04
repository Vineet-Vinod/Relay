//
//  RelayTunnelManager.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import NetworkExtension

@MainActor
final class RelayTunnelManager {
    static let localizedDescription = "Relay VPN"
    static let providerBundleIdentifier = "rybkr.Relay.RelayTunnelExtension"

    var onStatusDidChange: (@MainActor () -> Void)?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        statusObserver = notificationCenter.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onStatusDidChange?()
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func refreshInstalledManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.relayLoadAllFromPreferences()
        let match = managers.first { manager in
            guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }

            return tunnelProtocol.providerBundleIdentifier == Self.providerBundleIdentifier ||
                manager.localizedDescription == Self.localizedDescription
        }

        manager = match
        return match
    }

    func install(configuration: RelayTunnelConfiguration) async throws {
        let persistentReference = try RelayTunnelKeychain.storeConfiguration(configuration)
        let manager = try await refreshInstalledManager() ?? NETunnelProviderManager()

        let tunnelProtocol = NETunnelProviderProtocol()
        let serverEndpoint = try RelayServerEndpoint(endpointString: configuration.serverEndpoint)
        tunnelProtocol.providerBundleIdentifier = Self.providerBundleIdentifier
        tunnelProtocol.serverAddress = serverEndpoint.host
        tunnelProtocol.disconnectOnSleep = false
        tunnelProtocol.providerConfiguration = [
            "assignedAddress": configuration.clientAddress,
            "serverEndpoint": configuration.serverEndpoint,
            "peerIdentifier": configuration.peerIdentifier,
            "configurationVersion": 1,
        ]
        tunnelProtocol.passwordReference = persistentReference

        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = Self.localizedDescription
        manager.isEnabled = true

        try await manager.relaySaveToPreferences()
        try await manager.relayLoadFromPreferences()
        self.manager = manager
    }

    func connect() throws {
        guard let manager else {
            throw RelayVPNError.missingTunnelManager
        }

        if manager.connection.status == .connected || manager.connection.status == .connecting {
            return
        }

        try manager.connection.startVPNTunnel()
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    func removeInstalledConfiguration() async throws -> String? {
        guard let manager = try await refreshInstalledManager() else {
            return nil
        }

        let peerIdentifier = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["peerIdentifier"] as? String
        manager.connection.stopVPNTunnel()
        try await manager.relayRemoveFromPreferences()
        self.manager = nil
        return peerIdentifier
    }

    var connectionStatus: NEVPNStatus {
        manager?.connection.status ?? .invalid
    }
}

private extension NETunnelProviderManager {
    static func relayLoadAllFromPreferences() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: managers ?? [])
            }
        }
    }

    func relayLoadFromPreferences() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: ())
            }
        }
    }

    func relaySaveToPreferences() async throws {
        try await withCheckedThrowingContinuation { continuation in
            saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: ())
            }
        }
    }

    func relayRemoveFromPreferences() async throws {
        try await withCheckedThrowingContinuation { continuation in
            removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: ())
            }
        }
    }
}
