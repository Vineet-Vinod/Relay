//
//  MeshProvider.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

@MainActor
protocol MeshProvider {
    var mode: MeshProviderMode { get }
    var displayName: String { get }
    var supportsManualHostManagement: Bool { get }

    func currentSnapshot() async -> MeshProviderSnapshot
    func fetchPeers() async throws -> [PeerDevice]
    func endpoint(for peer: PeerDevice) async throws -> Host
    func saveHost(_ host: SavedTailnetHost) async throws
    func deletePeer(_ peer: PeerDevice) async throws
}

enum MeshProviderMode: String, CaseIterable, Identifiable {
    case mock
    case tailscale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mock:
            return "Mock Network"
        case .tailscale:
            return "Tailscale"
        }
    }

    var subtitle: String {
        switch self {
        case .mock:
            return "Built-in demo devices for local development."
        case .tailscale:
            return "Use hosts that are reachable over the Tailscale app already running on this device."
        }
    }
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

struct MockMeshProvider: MeshProvider {
    let mode: MeshProviderMode = .mock
    let displayName = "Mock Network"
    let supportsManualHostManagement = false

    func currentSnapshot() async -> MeshProviderSnapshot {
        MeshProviderSnapshot(
            status: .ready(
                title: "Relay Preview Network",
                detail: "Built-in sample devices for local development and UI previews."
            )
        )
    }

    func fetchPeers() async throws -> [PeerDevice] {
        try await Task.sleep(for: .milliseconds(500))
        return AppEnvironment.mockPeers
    }

    func endpoint(for peer: PeerDevice) async throws -> Host {
        Host(
            id: peer.id,
            name: peer.name,
            hostname: peer.meshHostname ?? peer.networkAddress,
            port: 22,
            username: peer.sshUsername,
            transportMode: .mock
        )
    }

    func saveHost(_ host: SavedTailnetHost) async throws {
        _ = host
    }

    func deletePeer(_ peer: PeerDevice) async throws {
        _ = peer
    }
}

struct TailscaleMeshProvider: MeshProvider {
    let mode: MeshProviderMode = .tailscale
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
            username: savedHost.username,
            transportMode: .real
        )
    }

    func saveHost(_ host: SavedTailnetHost) async throws {
        await store.save(host)
    }

    func deletePeer(_ peer: PeerDevice) async throws {
        await store.remove(id: peer.id)
    }
}

enum MeshProviderFactory {
    static func makeProvider(mode: MeshProviderMode) -> any MeshProvider {
        switch mode {
        case .mock:
            return MockMeshProvider()
        case .tailscale:
            return TailscaleMeshProvider()
        }
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
