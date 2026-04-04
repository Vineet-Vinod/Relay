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
                    errorCard(message: errorMessage)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if snapshot.status.isReadyForPeers {
                Section {
                    if isLoading {
                        loadingDevicesRow
                    } else if peers.isEmpty {
                        emptyDevicesState
                    } else {
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
                } header: {
                    devicesHeader
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RelayTheme.surfaceBase)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || resolvingPeerID != nil)
                .accessibilityLabel("Refresh devices")
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.content) {
            HStack(alignment: .top, spacing: RelayTheme.Spacing.compact) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(statusTint.opacity(0.14))
                        .frame(width: 46, height: 46)

                    Image(systemName: statusIconName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(statusTint)
                }

                VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                    Text(provider.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(snapshot.status.title)
                        .font(.title3.weight(.semibold))

                    Text(snapshot.status.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if snapshot.status.isReadyForPeers {
                HStack(spacing: RelayTheme.Spacing.tight) {
                    statusChip(
                        title: "\(onlinePeerCount) available",
                        systemImage: "desktopcomputer",
                        tint: onlinePeerCount == 0 ? .secondary : RelayTheme.success
                    )

                    if provider.supportsManualHostManagement {
                        statusChip(
                            title: "Passwords requested as needed",
                            systemImage: "key.horizontal"
                        )
                    }
                }
            }

            if provider.supportsManualHostManagement {
                providerActionRow
            }
        }
        .relayAppCard(padding: 18)
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
        .tint(RelayTheme.accent)
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
            RelayTheme.warning
        case .ready:
            RelayTheme.success
        }
    }

    private var emptyStateMessage: String {
        "No tailnet hosts are saved yet. Add a host using its Tailscale IP or MagicDNS hostname, then connect over your active tailnet."
    }

    private var onlinePeerCount: Int {
        peers.reduce(into: 0) { count, peer in
            if peer.isOnline {
                count += 1
            }
        }
    }

    private var devicesHeader: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
            Text("Devices")
                .font(.headline)
                .textCase(nil)

            Text("Saved hosts are sorted by availability, then name.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
        .padding(.top, 8)
    }

    private var loadingDevicesRow: some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            ProgressView()
            Text("Loading devices")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var emptyDevicesState: some View {
        ContentUnavailableView(
            "No Devices Found",
            systemImage: "desktopcomputer",
            description: Text(emptyStateMessage)
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.compact) {
            HStack(alignment: .top, spacing: RelayTheme.Spacing.compact) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(RelayTheme.danger)

                VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                    Text("Relay couldn't load devices")
                        .font(.headline)

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button("Try Again") {
                Task {
                    await refresh()
                }
            }
            .buttonStyle(.bordered)
        }
        .relayAppCard()
    }

    private func statusChip(title: String, systemImage: String, tint: Color = .secondary) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(tint.opacity(0.10))
            )
    }

    private func peerRow(for peer: PeerDevice) -> some View {
        HStack(alignment: .top, spacing: RelayTheme.Spacing.compact) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((peer.isOnline ? RelayTheme.success : Color.secondary).opacity(0.12))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: peer.isOnline ? "desktopcomputer.and.arrow.down" : "desktopcomputer")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(peer.isOnline ? RelayTheme.success : .secondary)
                }

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                Text(peer.name)
                    .font(.headline)

                Text("\(peer.sshUsername)@\(peer.displayAddress)")
                    .font(TerminalFontRegistry.terminalSwiftUIFont(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(peer.operatingSystem) • \(peer.ownerName)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: RelayTheme.Spacing.tight) {
                if resolvingPeerID == peer.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(peer.isOnline ? "Online" : "Offline")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(peer.isOnline ? RelayTheme.success : .secondary)
                }

                if peer.isOnline && resolvingPeerID != peer.id {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
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
            ScrollView {
                VStack(alignment: .leading, spacing: RelayTheme.Spacing.section) {
                    introCard
                    detailsCard
                    storageCard
                }
                .padding(20)
                .padding(.bottom, 120)
            }
            .background(RelayTheme.surfaceBase.ignoresSafeArea())
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
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.compact) {
            Label("Add Tailnet Host", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title3.weight(.semibold))

            Text("Add a machine that is reachable through the Tailscale app already running on this device. Use either a Tailscale IP or a MagicDNS hostname.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .relayAppCard()
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.content) {
            Text("Connection Details")
                .font(.headline)

            VStack(spacing: 14) {
                hostField(title: "Name", prompt: "Mac mini", text: $name, field: .name, submitLabel: .next) {
                    focusedField = .hostname
                }

                hostField(title: "Host", prompt: "100.101.102.103 or server.tailnet.ts.net", text: $hostname, field: .hostname, submitLabel: .next, isTechnical: true) {
                    focusedField = .username
                }

                hostField(title: "User", prompt: "ryanbaker", text: $username, field: .username, submitLabel: .next, isTechnical: true) {
                    focusedField = .port
                }

                hostField(title: "Port", prompt: "22", text: $port, field: .port, submitLabel: .done, isTechnical: true) {
                    submit()
                }
                .keyboardType(.numberPad)
            }
        }
        .relayAppCard()
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
            Label("Stored On Device", systemImage: "internaldrive")
                .font(.headline)

            Text("Relay stores the host name, address, username, and port on this device so it can reconnect later. Passwords are requested only when needed and are not saved here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .relayAppCard()
    }

    private var actionBar: some View {
        VStack(spacing: RelayTheme.Spacing.tight) {
            Button {
                submit()
            } label: {
                Text("Save Host")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(RelayTheme.accent)
            .disabled(parsedHost == nil)

            Text("Use a Tailscale IP or MagicDNS hostname that is already reachable from this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RelayTheme.surfaceStroke)
                .frame(height: 1)
        }
    }

    private func hostField(
        title: String,
        prompt: String,
        text: Binding<String>,
        field: TailnetHostField,
        submitLabel: SubmitLabel,
        isTechnical: Bool = false,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)
                .relayAppFieldBackground(isFocused: focusedField == field, isTechnical: isTechnical)
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
    @Environment(\.colorScheme) private var colorScheme
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
            palette.backgroundColor
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: RelayTheme.Spacing.section) {
                    authenticationCard
                    credentialsPanel
                    securityPanel
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 132)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Authenticate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.surfaceColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
    }

    private var palette: RelayTerminalPalette {
        RelayTerminalPalette.palette(for: colorScheme)
    }

    private var authenticationCard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.content) {
            HStack(alignment: .top, spacing: RelayTheme.Spacing.compact) {
                VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                    Label("Password Authentication", systemImage: "lock.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.accentColor)

                    Text(host.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(palette.textColor)

                    Text("Enter the SSH password for this host to start a session.")
                        .font(.callout)
                        .foregroundStyle(palette.mutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Label("This Session", systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.warningColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(palette.warningColor.opacity(0.14))
                    )
            }

            Text("ssh \(username)@\(host.hostname) -p \(host.port)")
                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 18, bold: true))
                .foregroundStyle(palette.accentColor)
                .textSelection(.enabled)

            Divider()
                .overlay(palette.subtleColor)

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                authenticationDetailRow(label: "Host", value: host.hostname)
                authenticationDetailRow(label: "User", value: username)
                authenticationDetailRow(label: "Port", value: "\(host.port)")
            }
        }
        .relayTerminalPanel(palette)
    }

    private var credentialsPanel: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.content) {
            Text("Credentials")
                .font(.headline)
                .foregroundStyle(palette.textColor)

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                Text("Username")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.mutedColor)

                TextField("SSH username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .foregroundStyle(palette.textColor)
                    .tint(palette.accentColor)
                    .submitLabel(.next)
                    .onSubmit {
                        focusedField = .password
                    }
            }
            .relayTerminalFieldBackground(palette, isFocused: focusedField == .username)

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                Text("Password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.mutedColor)

                SecureField("Enter SSH password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
                    .foregroundStyle(palette.textColor)
                    .tint(palette.accentColor)
                    .submitLabel(.go)
                    .onSubmit {
                        submit()
                    }
            }
            .relayTerminalFieldBackground(palette, isFocused: focusedField == .password)
        }
        .relayTerminalPanel(palette)
    }

    private var securityPanel: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
            Label("Password Handling", systemImage: "key.horizontal")
                .font(.headline)
                .foregroundStyle(palette.textColor)

            Text("Relay uses the password for this login only. It is not stored on the device, and Relay can offer SSH key setup after a successful connection.")
                .font(.footnote)
                .foregroundStyle(palette.mutedColor)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: RelayTheme.Spacing.tight) {
                securityChip("Not Stored", tint: palette.accentColor)
                securityChip("Editable Username", tint: palette.mutedColor)
            }
        }
        .relayTerminalPanel(palette)
    }

    private var actionBar: some View {
        VStack(spacing: RelayTheme.Spacing.tight) {
            Button("Start Session") {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accentColor)
            .disabled(!canSubmit)

            Text("Relay will use this password once to establish the SSH session.")
                .font(.footnote)
                .foregroundStyle(palette.mutedColor)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(palette.surfaceColor)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.subtleColor.opacity(0.85))
                .frame(height: 1)
        }
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func authenticationDetailRow(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.mutedColor)
                .frame(width: 52, alignment: .leading)

            Text(value)
                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 12))
                .foregroundStyle(palette.textColor)
                .textSelection(.enabled)
        }
    }

    private func securityChip(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(tint.opacity(0.14))
            )
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
        HostListView(provider: TailscaleMeshProvider())
    }
}
