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
    @State private var loginHost: Host?
    @State private var destinationHost: Host?

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
                Button {
                    loginHost = Host(peer: peer)
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
                .buttonStyle(.plain)
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
        .sheet(item: $loginHost) { host in
            NavigationStack {
                SSHLoginView(host: host) { authenticatedHost in
                    destinationHost = authenticatedHost
                }
            }
        }
        .navigationDestination(item: $destinationHost) { host in
            TerminalView(viewModel: TerminalSessionViewModel(host: host))
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

private struct SSHLoginView: View {
    let host: Host
    let onConnect: (Host) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @FocusState private var isPasswordFieldFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.07),
                    Color(red: 0.06, green: 0.09, blue: 0.11)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    terminalHeader
                    terminalPrompt
                    connectActions
                }
                .padding(20)
            }
        }
        .navigationTitle("SSH Session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isPasswordFieldFocused = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
    }

    private var terminalHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.37, blue: 0.33))
                    .frame(width: 10, height: 10)
                Circle()
                    .fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                    .frame(width: 10, height: 10)
                Circle()
                    .fill(Color(red: 0.19, green: 0.81, blue: 0.35))
                    .frame(width: 10, height: 10)

                Spacer()

                Text("relay ssh")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("ssh \(host.username)@\(host.hostname) -p \(host.port)")
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
                    .textSelection(.enabled)

                Text(host.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Password auth only. Relay opens the session after the SSH server accepts this credential.")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.72))
            }

            Divider()
                .overlay(Color.white.opacity(0.12))

            VStack(alignment: .leading, spacing: 6) {
                terminalMetaRow(label: "host", value: host.hostname)
                terminalMetaRow(label: "user", value: host.username)
                terminalMetaRow(label: "port", value: "\(host.port)")
                terminalMetaRow(label: "auth", value: "password")
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.green.opacity(0.18), lineWidth: 1)
        )
    }

    private var terminalPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password")
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(.white)

            HStack(alignment: .center, spacing: 12) {
                Text("[auth]")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)

                SecureField("Enter SSH password", text: $password)
                    .font(.system(.body, design: .monospaced))
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isPasswordFieldFocused)
                    .foregroundStyle(.white)
                    .tint(.green)
                    .submitLabel(.go)
                    .onSubmit {
                        submit()
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.08, blue: 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isPasswordFieldFocused ? Color.green.opacity(0.65) : Color.white.opacity(0.08), lineWidth: 1)
            )

            Text("The password is not stored. It is only attached to this session request.")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.58))
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var connectActions: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button("Start Session") {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(password.isEmpty)
        }
    }

    private func terminalMetaRow(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.5))
                .frame(width: 44, alignment: .leading)

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.82))
                .textSelection(.enabled)
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }

        let authenticatedHost = Host(
            id: host.id,
            name: host.name,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            password: password
        )
        isPasswordFieldFocused = false
        dismiss()
        DispatchQueue.main.async {
            onConnect(authenticatedHost)
        }
    }
}

#Preview {
    NavigationStack {
        HostListView(service: MockMeshServiceClient())
    }
}
