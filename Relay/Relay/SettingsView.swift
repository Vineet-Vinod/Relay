//
//  SettingsView.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let provider: any MeshProvider

    @AppStorage(RelayDefaultsKey.useSavedKeysAutomatically) private var usesSavedKeysAutomatically = true
    @AppStorage(RelayDefaultsKey.allowPasswordFallback) private var allowsPasswordFallback = true
    @AppStorage(RelayDefaultsKey.connectionTimeoutSeconds) private var connectionTimeoutSeconds = 12
    @AppStorage(RelayDefaultsKey.terminalFontSize) private var terminalFontSize = 14.0
    @AppStorage(RelayDefaultsKey.bellBehavior) private var bellBehavior = RelayBellBehavior.haptic.rawValue
    @AppStorage(RelayDefaultsKey.keepScreenAwake) private var keepsScreenAwake = true
    @AppStorage(RelayDefaultsKey.automaticallyReconnect) private var automaticallyReconnect = true

    @State private var providerSnapshot: MeshProviderSnapshot = .checking
    @State private var storedKeys: [SSHStoredKeyRecord] = []
    @State private var trustedHosts: [TrustedSSHHostRecord] = []
    @State private var savedDevices: [SavedDevice] = []
    @State private var isImportingDevices = false
    @State private var isExportingDevices = false
    @State private var exportDocument = SavedDevicesDocument(devices: [])
    @State private var destructiveAction: SettingsDestructiveAction?
    @State private var notice: SettingsNotice?

    var body: some View {
        List {
            Section {
                overviewCard
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)

            Section {
                settingsValueRow(
                    title: "Mesh Provider",
                    value: provider.displayName,
                    detail: providerSnapshot.status.title
                )

                Toggle("Use Saved SSH Keys", isOn: $usesSavedKeysAutomatically)

                Toggle("Allow Password Fallback", isOn: $allowsPasswordFallback)

                Stepper(value: $connectionTimeoutSeconds, in: 5...60, step: 1) {
                    settingsValueRow(
                        title: "Connection Timeout",
                        value: "\(connectionTimeoutSeconds)s",
                        detail: nil
                    )
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(providerSnapshot.status.detail)
            }

            Section {
                NavigationLink {
                    StoredSSHKeysSettingsView(records: storedKeys) { remote in
                        RelayServices.sshCredentials.removeStoredKey(for: remote)
                        reloadCredentialData()
                    }
                } label: {
                    settingsChevronRow(
                        title: "Stored SSH Keys",
                        value: storedKeys.isEmpty ? "None" : "\(storedKeys.count)"
                    )
                }

                NavigationLink {
                    TrustedHostsSettingsView(records: trustedHosts) { endpoint in
                        RelayServices.sshCredentials.removeTrustedHostKey(for: endpoint)
                        reloadCredentialData()
                    }
                } label: {
                    settingsChevronRow(
                        title: "Trusted SSH Hosts",
                        value: trustedHosts.isEmpty ? "None" : "\(trustedHosts.count)"
                    )
                }

                Button("Show SSH Key Setup Prompts Again") {
                    RelayServices.sshCredentials.resetDismissedKeySetupPrompts()
                    notice = SettingsNotice(
                        title: "Prompts Reset",
                        message: "Relay will offer SSH key setup again after a successful password login."
                    )
                }
            } header: {
                Text("Security")
            } footer: {
                Text("SSH private keys stay in the device Keychain. Trusted host fingerprints stay in Relay storage on this device.")
            }

            Section {
                Stepper(value: $terminalFontSize, in: 11.0...22.0, step: 1.0) {
                    settingsValueRow(
                        title: "Font Size",
                        value: "\(Int(terminalFontSize.rounded())) pt",
                        detail: nil
                    )
                }

                Picker("Bell", selection: $bellBehavior) {
                    ForEach(RelayBellBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior.rawValue)
                    }
                }

                Toggle("Keep Screen Awake", isOn: $keepsScreenAwake)

                Toggle("Reconnect Automatically", isOn: $automaticallyReconnect)
            } header: {
                Text("Terminal")
            }

            Section {
                Button("Export Saved Devices") {
                    Task {
                        await prepareSavedDeviceExport()
                    }
                }

                Button("Import Saved Devices") {
                    isImportingDevices = true
                }

                Button("Reset Trusted Hosts", role: .destructive) {
                    destructiveAction = .resetTrustedHosts
                }

                Button("Remove Saved SSH Keys", role: .destructive) {
                    destructiveAction = .removeSavedKeys
                }

                Button("Erase Relay Data", role: .destructive) {
                    destructiveAction = .eraseRelayData
                }
            } header: {
                Text("Data")
            } footer: {
                Text("\(savedDevices.count) saved device\(savedDevices.count == 1 ? "" : "s") on this device.")
            }

            Section {
                settingsValueRow(title: "Version", value: appVersionString, detail: nil)
                settingsValueRow(title: "Storage", value: "On Device", detail: "Saved devices, trusted hosts, and keys stay local.")
                settingsValueRow(title: "Provider", value: provider.displayName, detail: nil)
            } header: {
                Text("About")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RelayTheme.surfaceBase)
        .navigationTitle("Settings")
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
        .fileExporter(
            isPresented: $isExportingDevices,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Relay-Saved-Devices"
        ) { result in
            switch result {
            case .success:
                notice = SettingsNotice(
                    title: "Devices Exported",
                    message: "Relay wrote your saved device list to a JSON file."
                )
            case .failure(let error):
                notice = SettingsNotice(
                    title: "Export Failed",
                    message: error.localizedDescription
                )
            }
        }
        .fileImporter(
            isPresented: $isImportingDevices,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await importSavedDevices(from: url)
                }
            case .failure(let error):
                notice = SettingsNotice(
                    title: "Import Failed",
                    message: error.localizedDescription
                )
            }
        }
        .confirmationDialog(
            destructiveAction?.title ?? "",
            isPresented: Binding(
                get: { destructiveAction != nil },
                set: { isPresented in
                    if !isPresented {
                        destructiveAction = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: destructiveAction
        ) { action in
            Button(action.confirmTitle, role: .destructive) {
                destructiveAction = nil
                Task {
                    await perform(action)
                }
            }

            Button("Cancel", role: .cancel) {
                destructiveAction = nil
            }
        } message: { action in
            Text(action.message)
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.content) {
            HStack(alignment: .top, spacing: RelayTheme.Spacing.compact) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(statusTint.opacity(0.14))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: statusSymbolName)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(statusTint)
                    }

                VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                    Text("Local SSH Configuration")
                        .font(.headline)

                    Text(providerSnapshot.status.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )

            HStack(spacing: RelayTheme.Spacing.compact) {
                overviewMetric(title: "Devices", value: "\(savedDevices.count)")
                overviewMetric(title: "Saved Keys", value: "\(storedKeys.count)")
                overviewMetric(title: "Trusted Hosts", value: "\(trustedHosts.count)")
            }
        }
        .relayAppCard()
    }

    private var statusSymbolName: String {
        switch providerSnapshot.status {
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .ready:
            return "checkmark.shield"
        case .unavailable:
            return "exclamationmark.triangle"
        }
    }

    private var statusTint: Color {
        switch providerSnapshot.status {
        case .checking:
            return RelayTheme.info
        case .ready:
            return RelayTheme.success
        case .unavailable:
            return RelayTheme.warning
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func overviewMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(value)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 72, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
    }

    private func settingsValueRow(title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
            HStack(spacing: RelayTheme.Spacing.compact) {
                Text(title)

                Spacer(minLength: 12)

                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsChevronRow(title: String, value: String) -> some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            Text(title)

            Spacer(minLength: 12)

            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        providerSnapshot = await provider.currentSnapshot()
        savedDevices = await SavedDeviceStore.shared.hosts()
        reloadCredentialData()
    }

    private func reloadCredentialData() {
        storedKeys = RelayServices.sshCredentials.storedKeyRecords()
        trustedHosts = RelayServices.sshCredentials.trustedHostRecords()
    }

    private func prepareSavedDeviceExport() async {
        exportDocument = SavedDevicesDocument(devices: await SavedDeviceStore.shared.hosts())
        isExportingDevices = true
    }

    private func importSavedDevices(from url: URL) async {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let importedDevices = try JSONDecoder().decode([SavedDevice].self, from: data)
            let mergedDevices = mergeSavedDevices(current: savedDevices, imported: importedDevices)
            await SavedDeviceStore.shared.replaceAll(with: mergedDevices)
            savedDevices = await SavedDeviceStore.shared.hosts()
            notice = SettingsNotice(
                title: "Devices Imported",
                message: "Relay imported \(importedDevices.count) device\(importedDevices.count == 1 ? "" : "s")."
            )
        } catch {
            notice = SettingsNotice(
                title: "Import Failed",
                message: error.localizedDescription
            )
        }
    }

    private func mergeSavedDevices(current: [SavedDevice], imported: [SavedDevice]) -> [SavedDevice] {
        var merged = [String: SavedDevice]()
        for device in current {
            merged[savedDeviceKey(for: device)] = device
        }
        for device in imported {
            merged[savedDeviceKey(for: device)] = device
        }
        return Array(merged.values)
    }

    private func savedDeviceKey(for device: SavedDevice) -> String {
        "\(device.hostname.lowercased()):\(device.port):\(device.username.lowercased())"
    }

    private func perform(_ action: SettingsDestructiveAction) async {
        switch action {
        case .resetTrustedHosts:
            RelayServices.sshCredentials.removeAllTrustedHostKeys()
            reloadCredentialData()
            notice = SettingsNotice(
                title: "Trusted Hosts Cleared",
                message: "Relay will ask you to verify SSH host fingerprints again."
            )
        case .removeSavedKeys:
            RelayServices.sshCredentials.removeAllStoredKeys()
            reloadCredentialData()
            notice = SettingsNotice(
                title: "Saved Keys Removed",
                message: "Relay removed locally stored SSH private keys from the Keychain."
            )
        case .eraseRelayData:
            RelayServices.sshCredentials.eraseAllData()
            await SavedDeviceStore.shared.eraseAll()
            RelayPreferences.shared.reset()
            savedDevices = await SavedDeviceStore.shared.hosts()
            providerSnapshot = await provider.currentSnapshot()
            reloadCredentialData()
            notice = SettingsNotice(
                title: "Relay Data Erased",
                message: "Saved devices, trusted hosts, keys, and local Relay preferences were removed."
            )
        }
    }
}

private struct StoredSSHKeysSettingsView: View {
    let records: [SSHStoredKeyRecord]
    let onDelete: (SSHRemoteIdentity) -> Void

    var body: some View {
        List {
            if records.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Saved SSH Keys",
                        systemImage: "key.horizontal",
                        description: Text("Relay will list generated keys here after you enable SSH key login.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            } else {
                Section {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                            Text("\(record.remote.username)@\(record.remote.hostname)")
                                .font(.headline)

                            Text("Port \(record.remote.port)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Text(record.metadata.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                onDelete(record.remote)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("Removing a saved key does not change the remote device. It only removes the local private key Relay uses for login.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RelayTheme.surfaceBase)
        .navigationTitle("Stored SSH Keys")
    }
}

private struct TrustedHostsSettingsView: View {
    let records: [TrustedSSHHostRecord]
    let onDelete: (SSHHostEndpointIdentity) -> Void

    var body: some View {
        List {
            if records.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Trusted Hosts",
                        systemImage: "checkmark.shield",
                        description: Text("Relay will store verified SSH host fingerprints here after you trust a device.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            } else {
                Section {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                            Text("\(record.endpoint.hostname):\(record.endpoint.port)")
                                .font(.headline)

                            Text(record.hostKey.fingerprint)
                                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                            Text(record.hostKey.firstSeenAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                onDelete(record.endpoint)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("Remove a fingerprint if the remote host identity changed and you need Relay to verify it again.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RelayTheme.surfaceBase)
        .navigationTitle("Trusted Hosts")
    }
}

private struct SavedDevicesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let devices: [SavedDevice]

    init(devices: [SavedDevice]) {
        self.devices = devices
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        devices = try JSONDecoder().decode([SavedDevice].self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(devices)
        return FileWrapper(regularFileWithContents: data)
    }
}

private struct SettingsNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum SettingsDestructiveAction: Identifiable {
    case resetTrustedHosts
    case removeSavedKeys
    case eraseRelayData

    var id: String { title }

    var title: String {
        switch self {
        case .resetTrustedHosts:
            return "Reset Trusted Hosts?"
        case .removeSavedKeys:
            return "Remove Saved SSH Keys?"
        case .eraseRelayData:
            return "Erase Relay Data?"
        }
    }

    var message: String {
        switch self {
        case .resetTrustedHosts:
            return "Relay will remove all stored SSH host fingerprints and ask you to verify hosts again."
        case .removeSavedKeys:
            return "Relay will remove locally stored SSH private keys from the Keychain."
        case .eraseRelayData:
            return "Relay will remove saved devices, trusted hosts, saved keys, and local preferences."
        }
    }

    var confirmTitle: String {
        switch self {
        case .resetTrustedHosts:
            return "Reset Hosts"
        case .removeSavedKeys:
            return "Remove Keys"
        case .eraseRelayData:
            return "Erase Data"
        }
    }
}
