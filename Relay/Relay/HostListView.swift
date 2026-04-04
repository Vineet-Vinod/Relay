//
//  HostListView.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI

struct HostListView: View {
    let service: any MeshServiceClient

    @State private var peers: [PeerDevice] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            if isLoading {
                HStack {
                    ProgressView()
                    Text("Loading devices...")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(peers) { peer in
                NavigationLink {
                    TerminalView(viewModel: TerminalSessionViewModel(host: Host(peer: peer)))
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(peer.isOnline ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                            .padding(.top, 6)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(peer.name)
                                .font(.headline)

                            Text("\(peer.sshUsername)@\(peer.networkAddress)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Text("\(peer.operatingSystem) • \(peer.ownerName)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(peer.isOnline ? "Online" : "Offline")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(peer.isOnline ? .green : .secondary)
                    }
                    .padding(.vertical, 4)
                }
                .disabled(!peer.isOnline)
            }
        }
        .navigationTitle("Devices")
        .task {
            guard peers.isEmpty else { return }
            await loadPeers()
        }
        .refreshable {
            await loadPeers()
        }
    }

    private func loadPeers() async {
        isLoading = true
        errorMessage = nil

        do {
            peers = try await service.fetchPeers()
                .sorted { lhs, rhs in
                    if lhs.isOnline == rhs.isOnline {
                        return lhs.name < rhs.name
                    }

                    return lhs.isOnline && !rhs.isOnline
                }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

#Preview {
    NavigationStack {
        HostListView(service: MockMeshServiceClient())
    }
}
