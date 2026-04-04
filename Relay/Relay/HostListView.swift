//
//  HostListView.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI

struct HostListView: View {
    let provider: any MeshProvider

    @State private var snapshot: MeshProviderSnapshot = .checking
    @State private var peers: [PeerDevice] = []
    @State private var isLoading = false
    @State private var resolvingPeerID: PeerDevice.ID?
    @State private var errorMessage: String?
    @State private var isShowingAddHostSheet = false
    @State private var loginHost: Host?
    @State private var pendingDestinationHost: Host?
    @State private var destinationHost: Host?

    var body: some View {
        List {
            Section {
                statusCard
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            .listRowBackground(Color.clear)

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if snapshot.status.isReadyForPeers {
                if isLoading {
                    Section("Devices") {
                        HStack {
                            ProgressView()
                            Text("Loading devices...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !isLoading && peers.isEmpty {
                    Section("Devices") {
                        ContentUnavailableView(
                            "No Devices Found",
                            systemImage: "desktopcomputer",
                            description: Text(emptyStateMessage)
                        )
                    }
                }

                if !peers.isEmpty {
                    Section("Devices") {
                        ForEach(peers) { peer in
                            Button {
                                Task {
                                    await resolveEndpoint(for: peer)
                                }
                            } label: {
                                peerRow(for: peer)
                            }
                            .buttonStyle(.plain)
                            .disabled(!peer.isOnline || resolvingPeerID != nil)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Devices")
        .task {
            guard peers.isEmpty, case .checking = snapshot.status else { return }
            await refresh()
        }
        .refreshable {
            await refresh()
        }
        .sheet(item: $loginHost, onDismiss: presentPendingDestinationIfNeeded) { host in
            NavigationStack {
                SSHLoginView(host: host) { authenticatedHost in
                    pendingDestinationHost = authenticatedHost
                }
            }
        }
        .sheet(isPresented: $isShowingAddHostSheet) {
            AddTailnetHostSheet { host in
                Task {
                    await saveHost(host)
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(item: $destinationHost) { host in
            TerminalView(viewModel: TerminalSessionViewModel(host: host))
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusIconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusTint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(snapshot.status.title)
                        .font(.headline)

                    Text(snapshot.status.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isLoading {
                    ProgressView()
                }
            }

            if provider.supportsManualHostManagement {
                providerActionRow
            }

            if snapshot.status.isReadyForPeers && !peers.isEmpty {
                Text("\(peers.count) device\(peers.count == 1 ? "" : "s") available")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    @ViewBuilder
    private var providerActionRow: some View {
        Button {
            isShowingAddHostSheet = true
        } label: {
            Label("Add Tailnet Host", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .disabled(isLoading)
    }

    private var statusIconName: String {
        switch snapshot.status {
        case .checking:
            "dot.radiowaves.left.and.right"
        case .unavailable:
            "exclamationmark.triangle.fill"
        case .ready:
            "checkmark.circle.fill"
        }
    }

    private var statusTint: Color {
        switch snapshot.status {
        case .checking:
            .secondary
        case .unavailable:
            .orange
        case .ready:
            .green
        }
    }

    private var emptyStateMessage: String {
        if provider.mode == .tailscale {
            return "No tailnet hosts are saved yet. Add a host using its Tailscale IP or MagicDNS hostname, then connect over your active tailnet."
        }

        return "Relay didn't find any devices in the selected network that it can use for SSH."
    }

    private func peerRow(for peer: PeerDevice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(peer.isOnline ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(peer.name)
                    .font(.headline)

                Text("\(peer.sshUsername)@\(peer.displayAddress)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("\(peer.operatingSystem) • \(peer.ownerName)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if resolvingPeerID == peer.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(peer.isOnline ? "Online" : "Offline")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(peer.isOnline ? .green : .secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(peer.isOnline ? 1 : 0.62)
        .swipeActions(edge: .trailing, allowsFullSwipe: provider.supportsManualHostManagement) {
            if provider.supportsManualHostManagement {
                Button(role: .destructive) {
                    Task {
                        await deletePeer(peer)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func refresh() async {
        isLoading = true
        errorMessage = nil
        snapshot = await provider.currentSnapshot()

        guard snapshot.status.isReadyForPeers else {
            peers = []
            isLoading = false
            return
        }

        do {
            peers = try await provider.fetchPeers()
                .sorted { lhs, rhs in
                    if lhs.isOnline == rhs.isOnline {
                        return lhs.name < rhs.name
                    }

                    return lhs.isOnline && !rhs.isOnline
                }
        } catch {
            peers = []
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func saveHost(_ host: SavedTailnetHost) async {
        errorMessage = nil

        do {
            try await provider.saveHost(host)
            isShowingAddHostSheet = false
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePeer(_ peer: PeerDevice) async {
        errorMessage = nil

        do {
            try await provider.deletePeer(peer)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveEndpoint(for peer: PeerDevice) async {
        guard peer.isOnline else { return }

        resolvingPeerID = peer.id
        errorMessage = nil

        defer {
            resolvingPeerID = nil
        }

        do {
            let host = try await provider.endpoint(for: peer)
            if RelayServices.sshCredentials.hasStoredKey(for: host.remoteIdentity) {
                destinationHost = host
            } else {
                loginHost = host
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func presentPendingDestinationIfNeeded() {
        guard let pendingDestinationHost else { return }
        self.pendingDestinationHost = nil
        destinationHost = pendingDestinationHost
    }
}

private struct AddTailnetHostSheet: View {
    let onSave: (SavedTailnetHost) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostname = ""
    @State private var username = ""
    @State private var port = "22"
    @FocusState private var focusedField: TailnetHostField?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add Tailnet Host")
                        .font(.title2.weight(.semibold))

                    Text("Add a machine that is reachable through the Tailscale app already running on this device. Use either a Tailscale IP or a MagicDNS hostname.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 14) {
                    hostField(title: "Name", prompt: "Mac mini", text: $name, field: .name, submitLabel: .next) {
                        focusedField = .hostname
                    }

                    hostField(title: "Host", prompt: "100.101.102.103 or server.tailnet.ts.net", text: $hostname, field: .hostname, submitLabel: .next) {
                        focusedField = .username
                    }

                    hostField(title: "User", prompt: "ryanbaker", text: $username, field: .username, submitLabel: .next) {
                        focusedField = .port
                    }

                    hostField(title: "Port", prompt: "22", text: $port, field: .port, submitLabel: .done) {
                        submit()
                    }
                    .keyboardType(.numberPad)
                }

                Spacer()

                Button {
                    submit()
                } label: {
                    Text("Save Host")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(parsedHost == nil)
            }
            .padding(24)
            .navigationTitle("Tailnet Host")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    focusedField = .name
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
    }

    private func hostField(
        title: String,
        prompt: String,
        text: Binding<String>,
        field: TailnetHostField,
        submitLabel: SubmitLabel,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .focused($focusedField, equals: field)
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)
        }
    }

    private var parsedHost: SavedTailnetHost? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty,
              !trimmedHostname.isEmpty,
              !trimmedUsername.isEmpty,
              let parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(parsedPort) else {
            return nil
        }

        return SavedTailnetHost(
            name: trimmedName,
            hostname: trimmedHostname,
            port: parsedPort,
            username: trimmedUsername
        )
    }

    private func submit() {
        guard let parsedHost else { return }
        dismiss()
        DispatchQueue.main.async {
            onSave(parsedHost)
        }
    }
}

private enum TailnetHostField: Hashable {
    case name
    case hostname
    case username
    case port
}

struct SSHLoginView: View {
    let host: Host
    let onConnect: (Host) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password = ""
    @FocusState private var focusedField: SSHLoginField?

    init(host: Host, onConnect: @escaping (Host) -> Void) {
        self.host = host
        self.onConnect = onConnect
        _username = State(initialValue: host.username)
    }

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
                focusedField = .password
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
                Text("ssh \(username)@\(host.hostname) -p \(host.port)")
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
                    .textSelection(.enabled)

                Text(host.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Relay uses this password for the current login only. After a successful session it can offer SSH key setup for future logins.")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.72))
            }

            Divider()
                .overlay(Color.white.opacity(0.12))

            VStack(alignment: .leading, spacing: 6) {
                terminalMetaRow(label: "host", value: host.hostname)
                terminalMetaRow(label: "user", value: username)
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
            Text("Credentials")
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(.white)

            HStack(alignment: .center, spacing: 12) {
                Text("[user]")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)

                TextField("SSH username", text: $username)
                    .font(.system(.body, design: .monospaced))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .foregroundStyle(.white)
                    .tint(.green)
                    .submitLabel(.next)
                    .onSubmit {
                        focusedField = .password
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
                    .stroke(focusedField == .username ? Color.green.opacity(0.65) : Color.white.opacity(0.08), lineWidth: 1)
            )

            HStack(alignment: .center, spacing: 12) {
                Text("[pass]")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)

                SecureField("Enter SSH password", text: $password)
                    .font(.system(.body, design: .monospaced))
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
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
                    .stroke(focusedField == .password ? Color.green.opacity(0.65) : Color.white.opacity(0.08), lineWidth: 1)
            )

            Text("The username can be adjusted before connecting. The password is not stored.")
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
            .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
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
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else { return }

        let authenticatedHost = Host(
            id: host.id,
            name: host.name,
            hostname: host.hostname,
            port: host.port,
            username: trimmedUsername,
            transportMode: host.transportMode,
            authentication: .password(password)
        )
        focusedField = nil
        dismiss()
        DispatchQueue.main.async {
            onConnect(authenticatedHost)
        }
    }
}

private enum SSHLoginField: Hashable {
    case username
    case password
}

#Preview {
    NavigationStack {
        HostListView(provider: MockMeshProvider())
    }
}
