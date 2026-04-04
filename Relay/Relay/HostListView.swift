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
    @State private var detailPeer: PeerDevice?
    @State private var deviceEditor: DeviceEditorContext?
    @State private var loginHost: Host?
    @State private var pendingDestinationHost: Host?
    @State private var destinationHost: Host?

    var body: some View {
        List {
            Section {
                devicesContent
            }

            if let errorMessage, !peers.isEmpty {
                Section {
                    errorCard(message: errorMessage)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $deviceEditor) { context in
            AddDeviceSheet(device: context.device) { host in
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
        .navigationDestination(item: $detailPeer) { peer in
            DeviceDetailView(
                peer: peer,
                isConnecting: resolvingPeerID == peer.id,
                onEdit: {
                    deviceEditor = DeviceEditorContext(device: peer.savedDeviceDraft)
                },
                onConnect: {
                    Task {
                        await resolveEndpoint(for: peer)
                    }
                }
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentAddDeviceSheet()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(isLoading)
                .accessibilityLabel("Add device")
            }
        }
    }

    @ViewBuilder
    private var devicesContent: some View {
        switch snapshot.status {
        case .checking:
            loadingDevicesRow
        case .unavailable(let message):
            unavailableDevicesState(message: message)
        case .ready:
            if isLoading && peers.isEmpty {
                loadingDevicesRow
            } else if let errorMessage, peers.isEmpty {
                failedDevicesState(message: errorMessage)
            } else if peers.isEmpty {
                emptyDevicesState
            } else {
                ForEach(peers) { peer in
                    peerRow(for: peer)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    private var loadingDevicesRow: some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            ProgressView()
            Text("Checking devices")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var emptyDevicesState: some View {
        VStack(spacing: RelayTheme.Spacing.content) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: RelayTheme.Spacing.tight) {
                Text("No Devices")
                    .font(.headline)

                Button {
                    presentAddDeviceSheet()
                } label: {
                    Label("Add Device", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(RelayTheme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
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

    private func unavailableDevicesState(message: String) -> some View {
        ContentUnavailableView(
            "Devices Unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func failedDevicesState(message: String) -> some View {
        VStack(spacing: RelayTheme.Spacing.content) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(RelayTheme.warning)

            VStack(spacing: RelayTheme.Spacing.tight) {
                Text("Relay Couldn't Load Devices")
                    .font(.headline)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Try Again") {
                Task {
                    await refresh()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func peerRow(for peer: PeerDevice) -> some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            Button {
                Task {
                    await resolveEndpoint(for: peer)
                }
            } label: {
                HStack(alignment: .center, spacing: RelayTheme.Spacing.compact) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((peer.isOnline ? RelayTheme.success : Color.secondary).opacity(0.12))
                        .frame(width: 42, height: 42)
                        .overlay {
                            Image(systemName: peer.isOnline ? "desktopcomputer.and.arrow.down" : "desktopcomputer")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(peer.isOnline ? RelayTheme.success : .secondary)
                        }

                    VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                        Text(peer.name)
                            .font(.headline)

                        Text(peer.networkAddress)
                            .font(TerminalFontRegistry.terminalSwiftUIFont(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if resolvingPeerID == peer.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        statusBadge(isOnline: peer.isOnline)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!peer.isOnline || resolvingPeerID != nil)

            Button {
                detailPeer = peer
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(Color(uiColor: .systemBackground))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show device details")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: RelayTheme.Radius.card, style: .continuous)
                .fill(RelayTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayTheme.Radius.card, style: .continuous)
                .stroke(RelayTheme.surfaceStroke, lineWidth: 1)
        )
        .opacity(peer.isOnline ? 1 : 0.78)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if provider.supportsManualHostManagement {
                Button {
                    deviceEditor = DeviceEditorContext(device: peer.savedDeviceDraft)
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .tint(RelayTheme.accent)

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

    private func statusBadge(isOnline: Bool) -> some View {
        Text(isOnline ? "Online" : "Offline")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isOnline ? RelayTheme.success : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill((isOnline ? RelayTheme.success : Color.secondary).opacity(0.10))
            )
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

    private func saveHost(_ host: SavedDevice) async {
        errorMessage = nil

        do {
            try await provider.saveHost(host)
            deviceEditor = nil
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
            if RelayPreferences.shared.usesSavedKeysAutomatically,
               RelayServices.sshCredentials.hasStoredKey(for: host.remoteIdentity) {
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

    private func presentAddDeviceSheet() {
        deviceEditor = DeviceEditorContext(device: nil)
    }
}

private struct DeviceEditorContext: Identifiable {
    let id: UUID
    let device: SavedDevice?

    init(device: SavedDevice?) {
        self.id = device?.id ?? UUID()
        self.device = device
    }
}

private struct DeviceDetailView: View {
    let peer: PeerDevice
    let isConnecting: Bool
    let onEdit: () -> Void
    let onConnect: () -> Void

    var body: some View {
        List {
            Section {
                statusRow
            }

            Section("Connection") {
                detailRow(title: "Address", value: peer.networkAddress, monospaced: true)
                detailRow(title: "User", value: peer.sshUsername, monospaced: true)
                detailRow(title: "Port", value: "\(peer.port)", monospaced: true)
            }

            if peer.operatingSystem != "Direct SSH" || peer.ownerName != "Saved Device" {
                Section("Details") {
                    detailRow(title: "Type", value: peer.operatingSystem)
                    detailRow(title: "Owner", value: peer.ownerName)
                }
            }

            Section {
                Button {
                    onConnect()
                } label: {
                    HStack {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Text(peer.isOnline ? "Connect" : "Offline")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(RelayTheme.accent)
                .disabled(!peer.isOnline || isConnecting)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RelayTheme.surfaceBase)
        .navigationTitle(peer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    onEdit()
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill((peer.isOnline ? RelayTheme.success : Color.secondary).opacity(0.12))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: peer.isOnline ? "desktopcomputer.and.arrow.down" : "desktopcomputer")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(peer.isOnline ? RelayTheme.success : .secondary)
                }

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                Text(peer.isOnline ? "Online" : "Offline")
                    .font(.headline)

                Text(peer.networkAddress)
                    .font(TerminalFontRegistry.terminalSwiftUIFont(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private func detailRow(title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(monospaced ? TerminalFontRegistry.terminalSwiftUIFont(size: 14) : .body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct AddDeviceSheet: View {
    let device: SavedDevice?
    let onSave: (SavedDevice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var port = "22"
    @FocusState private var focusedField: AddDeviceField?

    init(device: SavedDevice? = nil, onSave: @escaping (SavedDevice) -> Void) {
        self.device = device
        self.onSave = onSave
        _name = State(initialValue: device?.name ?? "")
        _address = State(initialValue: device?.hostname ?? "")
        _username = State(initialValue: device?.username ?? "")
        _port = State(initialValue: String(device?.port ?? 22))
    }

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
            .navigationTitle(device == nil ? "Add Device" : "Edit Device")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    focusedField = device == nil ? .address : .username
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
            Label(device == nil ? "Connect By IP Address" : "Update Device Details", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title3.weight(.semibold))

            Text(device == nil
                 ? "Save a device with its IP address so Relay can check whether SSH is reachable and reconnect later."
                 : "Change the label, address, username, or port Relay should use the next time you connect.")
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
                hostField(title: "IP Address", prompt: "192.168.1.24", text: $address, field: .address, submitLabel: .next, isTechnical: true) {
                    focusedField = .username
                }

                hostField(title: "User", prompt: "ryanbaker", text: $username, field: .username, submitLabel: .next, isTechnical: true) {
                    focusedField = .port
                }

                hostField(title: "Port", prompt: "22", text: $port, field: .port, submitLabel: .next, isTechnical: true) {
                    focusedField = .name
                }

                hostField(title: "Label (Optional)", prompt: "Office Mac mini", text: $name, field: .name, submitLabel: .done) {
                    submit()
                }
            }
        }
        .relayAppCard()
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
            Label("Stored On Device", systemImage: "internaldrive")
                .font(.headline)

            Text("Relay stores the label, IP address, username, and port on this device so it can reconnect later. Passwords are requested only when needed and are not saved here.")
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
                Text(device == nil ? "Save Device" : "Update Device")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(RelayTheme.accent)
            .disabled(parsedHost == nil)

            Text("Use an IPv4 or IPv6 address that this device can reach over the network.")
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
        field: AddDeviceField,
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
                .keyboardType(
                    field == .address
                    ? .numbersAndPunctuation
                    : field == .port
                        ? .numberPad
                        : .default
                )
                .focused($focusedField, equals: field)
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)
                .relayAppFieldBackground(isFocused: focusedField == field, isTechnical: isTechnical)

            if field == .address, showAddressValidation {
                Text("Enter a valid IPv4 or IPv6 address.")
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.danger)
            } else if field == .port, showPortValidation {
                Text("Port must be between 1 and 65535.")
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.danger)
            }
        }
    }

    private var showAddressValidation: Bool {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedAddress.isEmpty && !trimmedAddress.isIPAddress
    }

    private var showPortValidation: Bool {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPort.isEmpty else {
            return false
        }

        guard let parsedPort = Int(trimmedPort) else {
            return true
        }

        return !(1...65535).contains(parsedPort)
    }

    private var parsedHost: SavedDevice? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAddress.isEmpty,
              trimmedAddress.isIPAddress,
              !trimmedUsername.isEmpty,
              let parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(parsedPort) else {
            return nil
        }

        return SavedDevice(
            id: device?.id ?? UUID(),
            name: trimmedName.isEmpty ? trimmedAddress : trimmedName,
            hostname: trimmedAddress,
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

private enum AddDeviceField: Hashable {
    case address
    case username
    case port
    case name
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
        ScrollView {
            VStack(spacing: RelayTheme.Spacing.section) {
                credentialsPanel
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 104)
            .frame(maxWidth: .infinity)
        }
        .background(RelayTheme.surfaceBase.ignoresSafeArea())
        .navigationTitle("Login")
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
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
    }

    private var credentialsPanel: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.compact) {
            VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                Text("Username")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("SSH username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit {
                        focusedField = .password
                    }
            }
            .relayAppFieldBackground(isFocused: focusedField == .username, isTechnical: true)

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                Text("Password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                SecureField("Enter SSH password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit {
                        submit()
                    }
            }
            .relayAppFieldBackground(isFocused: focusedField == .password, isTechnical: true)
        }
        .relayAppCard()
    }

    private var actionBar: some View {
        VStack(spacing: RelayTheme.Spacing.compact) {
            Button("Start Session") {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .tint(RelayTheme.accent)
            .disabled(!canSubmit)
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

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
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

private extension PeerDevice {
    var savedDeviceDraft: SavedDevice {
        SavedDevice(
            id: id,
            name: name,
            hostname: networkAddress,
            port: port,
            username: sshUsername
        )
    }
}

#Preview {
    NavigationStack {
        HostListView(provider: ManualDeviceProvider())
    }
}
