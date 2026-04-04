//
//  MeshProvider.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

@MainActor
protocol MeshProvider {
    var displayName: String { get }
    var supportsManualHostManagement: Bool { get }

    func currentSnapshot() async -> MeshProviderSnapshot
    func fetchPeers() async throws -> [PeerDevice]
    func endpoint(for peer: PeerDevice) async throws -> Host
    func saveHost(_ host: SavedTailnetHost) async throws
    func deletePeer(_ peer: PeerDevice) async throws
}

struct MeshProviderSnapshot: Equatable {
    let status: MeshStatus

    static let checking = MeshProviderSnapshot(status: .checking)
}

enum MeshStatus: Equatable {
    case checking
    case ready(title: String, detail: String)
    case unavailable(message: String)

    var isReadyForPeers: Bool {
        if case .ready = self {
            return true
        }

        return false
    }

    var title: String {
        switch self {
        case .checking:
            return "Checking Mesh Provider"
        case .ready(let title, _):
            return title
        case .unavailable:
            return "Mesh Provider Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            return "Relay is checking the selected mesh provider."
        case .ready(_, let detail):
            return detail
        case .unavailable(let message):
            return message
        }
    }
}

enum MeshProviderError: LocalizedError {
    case endpointUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .endpointUnavailable(let name):
            return "Relay couldn't resolve an SSH endpoint for \(name)."
        }
    }
}

struct SavedTailnetHost: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
    }
}

struct TailscaleMeshProvider: MeshProvider {
    let displayName = "Tailscale"
    let supportsManualHostManagement = true

    private let store: TailnetHostStore

    init(store: TailnetHostStore = .shared) {
        self.store = store
    }

    func currentSnapshot() async -> MeshProviderSnapshot {
        MeshProviderSnapshot(
            status: .ready(
                title: "Tailnet Hosts",
                detail: "Relay assumes the Tailscale app is already connected. Add hosts using a Tailscale IP or MagicDNS hostname, then SSH directly over the tailnet."
            )
        )
    }

    func fetchPeers() async throws -> [PeerDevice] {
        let hosts = await store.hosts()
        return hosts.map(\.peerDevice)
    }

    func endpoint(for peer: PeerDevice) async throws -> Host {
        let hosts = await store.hosts()
        guard let savedHost = hosts.first(where: { $0.id == peer.id }) else {
            throw MeshProviderError.endpointUnavailable(peer.name)
        }

        return Host(
            id: savedHost.id,
            name: savedHost.name,
            hostname: savedHost.hostname,
            port: savedHost.port,
            username: savedHost.username
        )
    }

    func saveHost(_ host: SavedTailnetHost) async throws {
        await store.save(host)
    }

    func deletePeer(_ peer: PeerDevice) async throws {
        await store.remove(id: peer.id)
    }
}

actor TailnetHostStore {
    static let shared = TailnetHostStore()

    private let defaults: UserDefaults
    private let storageKey = "relay.tailscale.saved-hosts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hosts() -> [SavedTailnetHost] {
        guard let data = defaults.data(forKey: storageKey),
              let hosts = try? JSONDecoder().decode([SavedTailnetHost].self, from: data) else {
            return []
        }

        return hosts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save(_ host: SavedTailnetHost) {
        var currentHosts = hosts()

        if let index = currentHosts.firstIndex(where: { $0.id == host.id }) {
            currentHosts[index] = host
        } else {
            currentHosts.append(host)
        }

        persist(currentHosts)
    }

    func remove(id: UUID) {
        let filtered = hosts().filter { $0.id != id }
        persist(filtered)
    }

    private func persist(_ hosts: [SavedTailnetHost]) {
        guard let data = try? JSONEncoder().encode(hosts) else {
            return
        }

        defaults.set(data, forKey: storageKey)
    }
}

private extension SavedTailnetHost {
    var peerDevice: PeerDevice {
        PeerDevice(
            id: id,
            providerIdentifier: id.uuidString,
            name: name,
            networkAddress: hostname,
            meshHostname: hostname.looksLikeIPAddress ? nil : hostname,
            sshUsername: username,
            isOnline: true,
            operatingSystem: "Tailnet",
            ownerName: "Saved Host"
        )
    }
}

private extension String {
    var looksLikeIPAddress: Bool {
        allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
    }
}
