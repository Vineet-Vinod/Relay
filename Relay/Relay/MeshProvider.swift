//
//  MeshProvider.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import Network

@MainActor
protocol MeshProvider {
    var displayName: String { get }
    var supportsManualHostManagement: Bool { get }

    func currentSnapshot() async -> MeshProviderSnapshot
    func fetchPeers() async throws -> [PeerDevice]
    func endpoint(for peer: PeerDevice) async throws -> Host
    func saveHost(_ host: SavedDevice) async throws
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
        case .endpointUnavailable(let message):
            return message
        }
    }
}

struct SavedDevice: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var defaultCodexPath: String?

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        defaultCodexPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.defaultCodexPath = defaultCodexPath
    }
}

@MainActor
final class ManualDeviceProvider: MeshProvider {
    let displayName = "Tailscale"
    let supportsManualHostManagement = true

    private let store: SavedDeviceStore
    private let reachability = HostReachabilityService.shared

    init(store: SavedDeviceStore = .shared) {
        self.store = store
    }

    func currentSnapshot() async -> MeshProviderSnapshot {
        MeshProviderSnapshot(
            status: .ready(
                title: "Tailscale Hosts",
                detail: "Add Tailscale hostnames or IP addresses and Relay will connect over direct SSH."
            )
        )
    }

    func fetchPeers() async throws -> [PeerDevice] {
        let hosts = await store.hosts()
        let reachabilityByHostID = await reachability.onlineStatusByHostID(for: hosts)

        return hosts.map { host in
            host.peerDevice(isOnline: reachabilityByHostID[host.id] ?? false)
        }
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
            defaultCodexPath: savedHost.defaultCodexPath
        )
    }

    func saveHost(_ host: SavedDevice) async throws {
        await store.save(host)
    }

    func deletePeer(_ peer: PeerDevice) async throws {
        await store.remove(id: peer.id)
    }
}

actor SavedDeviceStore {
    static let shared = SavedDeviceStore()

    private let defaults: UserDefaults
    private let storageKey = "relay.saved-devices.v1"
    private let legacyStorageKey = "relay.tailscale.saved-hosts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hosts() -> [SavedDevice] {
        guard let data = storedData,
              let hosts = try? JSONDecoder().decode([SavedDevice].self, from: data) else {
            return []
        }

        return hosts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save(_ host: SavedDevice) {
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

    func replaceAll(with hosts: [SavedDevice]) {
        persist(hosts)
    }

    func eraseAll() {
        persist([])
    }

    private func persist(_ hosts: [SavedDevice]) {
        guard let data = try? JSONEncoder().encode(hosts) else {
            return
        }

        defaults.set(data, forKey: storageKey)
        defaults.removeObject(forKey: legacyStorageKey)
    }

    private var storedData: Data? {
        if let currentData = defaults.data(forKey: storageKey) {
            return currentData
        }

        return defaults.data(forKey: legacyStorageKey)
    }
}

private extension SavedDevice {
    func peerDevice(isOnline: Bool) -> PeerDevice {
        PeerDevice(
            id: id,
            providerIdentifier: MeshProviderKind.tailscale.rawValue,
            name: name,
            networkAddress: hostname,
            port: port,
            sshUsername: username,
            isOnline: isOnline,
            operatingSystem: "Direct SSH",
            ownerName: "Saved Device",
            connectionKind: .ssh,
            supportsVoiceSession: true
        )
    }
}

extension String {
    var isIPAddress: Bool {
        IPv4Address(self) != nil || IPv6Address(self) != nil
    }

    var isValidRelayHost: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if trimmed.isIPAddress {
            return true
        }

        guard !trimmed.hasPrefix("."),
              !trimmed.hasSuffix("."),
              !trimmed.contains("..") else {
            return false
        }

        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        return trimmed.rangeOfCharacter(from: allowedCharacters.inverted) == nil
    }
}

actor HostReachabilityService {
    static let shared = HostReachabilityService()

    func onlineStatusByHostID(for hosts: [SavedDevice]) async -> [UUID: Bool] {
        await withTaskGroup(of: (UUID, Bool).self, returning: [UUID: Bool].self) { group in
            for host in hosts {
                group.addTask {
                    let isOnline = await Self.isReachable(hostname: host.hostname, port: host.port)
                    return (host.id, isOnline)
                }
            }

            var results: [UUID: Bool] = [:]
            for await (hostID, isOnline) in group {
                results[hostID] = isOnline
            }
            return results
        }
    }

    private static func isReachable(hostname: String, port: Int) async -> Bool {
        guard let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let probeState = ReachabilityProbeState()
            let queue = DispatchQueue(label: "relay.host-reachability.\(UUID().uuidString)")
            let connection = NWConnection(host: NWEndpoint.Host(hostname), port: networkPort, using: .tcp)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    probeState.finish(true, connection: connection, continuation: continuation)
                case .failed, .cancelled:
                    probeState.finish(false, connection: connection, continuation: continuation)
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + 2) {
                probeState.finish(false, connection: connection, continuation: continuation)
            }

            connection.start(queue: queue)
        }
    }
}

private final class ReachabilityProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func finish(
        _ isOnline: Bool,
        connection: NWConnection,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !completed else { return }
        completed = true
        connection.cancel()
        continuation.resume(returning: isOnline)
    }
}
