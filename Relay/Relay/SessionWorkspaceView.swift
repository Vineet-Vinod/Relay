//
//  SessionWorkspaceView.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI
import UIKit

@MainActor
struct SessionWorkspaceView: View {
    private enum NewTabSheet: Identifiable {
        case terminal
        case voice

        var id: Self { self }
    }

    let provider: any MeshProvider

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SessionWorkspaceManager.self) private var workspaceManager

    @AppStorage(RelayDefaultsKey.keepScreenAwake) private var keepsScreenAwake = true

    @State private var presentedSheet: NewTabSheet?

    var body: some View {
        VStack(spacing: 0) {
            SessionWorkspaceTabStrip(
                tabs: workspaceManager.tabs,
                selectedTabID: workspaceManager.selectedTabID,
                palette: palette,
                onSelect: workspaceManager.selectTab,
                onClose: closeTab,
                onNewTerminalTab: {
                    presentedSheet = .terminal
                },
                onNewVoiceCall: {
                    presentedSheet = .voice
                }
            )

            Rectangle()
                .fill(palette.subtleColor.opacity(0.72))
                .frame(height: 1)

            ZStack {
                palette.backgroundColor
                    .ignoresSafeArea()

                ForEach(workspaceManager.tabs) { tab in
                    tabContent(for: tab)
                }
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .navigationTitle(workspaceManager.selectedTab?.title ?? "Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.surfaceColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .terminal:
                NavigationStack {
                    TerminalNewTabPickerView(
                        provider: provider,
                        currentHost: workspaceManager.selectedTab?.terminalSessionViewModel?.host,
                        onOpenHost: { host in
                            workspaceManager.openTerminalTab(for: host)
                            presentedSheet = nil
                        }
                    )
                }
            case .voice:
                NavigationStack {
                    VoiceNewCallPickerView(
                        provider: provider,
                        onStartCall: { configuration in
                            workspaceManager.openVoiceTab(configuration: configuration)
                            presentedSheet = nil
                        }
                    )
                }
            }
        }
        .task {
            workspaceManager.refreshVoiceFocus()
            updateVoiceIdleTimer()
        }
        .onChange(of: workspaceManager.selectedTabID) { _, _ in
            resignGlobalFirstResponder()
            updateVoiceIdleTimer()
        }
        .onChange(of: workspaceManager.tabs.count) { _, _ in
            updateVoiceIdleTimer()
        }
        .onChange(of: keepsScreenAwake) { _, _ in
            updateVoiceIdleTimer()
        }
        .onDisappear {
            resignGlobalFirstResponder()
            workspaceManager.suspendVoiceSessions()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var palette: RelayTerminalPalette {
        RelayTerminalPalette.palette(for: colorScheme)
    }

    private func resignGlobalFirstResponder() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )

        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { window in
                window.endEditing(true)
            }
    }

    @ViewBuilder
    private func tabContent(for tab: SessionWorkspaceTab) -> some View {
        let isSelected = workspaceManager.selectedTabID == tab.id

        switch tab.kind {
        case .terminal:
            if let viewModel = tab.terminalSessionViewModel {
                TerminalView(
                    viewModel: viewModel,
                    isActive: isSelected
                )
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .accessibilityHidden(!isSelected)
                .zIndex(isSelected ? 1 : 0)
            }
        case .voice:
            if let viewModel = tab.voiceSessionViewModel {
                VoiceSessionView(
                    onEnd: {
                        closeTab(tab.id)
                    },
                    isActive: isSelected,
                    viewModel: viewModel
                )
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .accessibilityHidden(!isSelected)
                .zIndex(isSelected ? 1 : 0)
            }
        }
    }

    private func closeTab(_ tabID: SessionWorkspaceTab.ID) {
        if workspaceManager.closeTab(id: tabID) {
            dismiss()
        } else {
            updateVoiceIdleTimer()
        }
    }

    private func updateVoiceIdleTimer() {
        guard keepsScreenAwake else {
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }

        guard let selectedTab = workspaceManager.selectedTab else {
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }

        switch selectedTab.kind {
        case .terminal:
            return
        case .voice:
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }
}

private struct SessionWorkspaceTabStrip: View {
    let tabs: [SessionWorkspaceTab]
    let selectedTabID: SessionWorkspaceTab.ID?
    let palette: RelayTerminalPalette
    let onSelect: (SessionWorkspaceTab.ID) -> Void
    let onClose: (SessionWorkspaceTab.ID) -> Void
    let onNewTerminalTab: () -> Void
    let onNewVoiceCall: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RelayTheme.Spacing.tight) {
                ForEach(tabs) { tab in
                    SessionWorkspaceTabChip(
                        tab: tab,
                        statusColor: statusColor(for: tab),
                        statusTitle: statusTitle(for: tab),
                        palette: palette,
                        isSelected: tab.id == selectedTabID,
                        onSelect: {
                            onSelect(tab.id)
                        },
                        onClose: {
                            onClose(tab.id)
                        }
                    )
                }

                Menu {
                    Button("New Terminal Tab", systemImage: "desktopcomputer") {
                        onNewTerminalTab()
                    }

                    Button("New Voice Call", systemImage: "waveform.and.mic") {
                        onNewVoiceCall()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.accentColor)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(palette.accentColor.opacity(0.12))
                        )
                        .overlay(
                            Circle()
                                .stroke(palette.accentColor.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open a new workspace tab")
            }
            .padding(.horizontal, RelayTheme.Spacing.content)
            .padding(.vertical, RelayTheme.Spacing.tight)
        }
        .background(palette.surfaceColor)
    }

    private func statusColor(for tab: SessionWorkspaceTab) -> Color {
        switch tab.kind {
        case .terminal:
            guard let session = tab.terminalSessionViewModel else {
                return palette.mutedColor
            }

            if session.isConnected {
                return palette.successColor
            }

            if session.isConnecting {
                return palette.accentColor
            }

            if session.latestErrorMessage != nil {
                return palette.dangerColor
            }

            return palette.mutedColor
        case .voice:
            guard let session = tab.voiceSessionViewModel else {
                return palette.mutedColor
            }

            switch session.status {
            case .ready:
                return palette.successColor
            case .listening, .speaking:
                return palette.accentColor
            case .processing, .preparing:
                return palette.warningColor
            case .muted:
                return palette.mutedColor
            case .ended, .failed:
                return palette.dangerColor
            }
        }
    }

    private func statusTitle(for tab: SessionWorkspaceTab) -> String {
        switch tab.kind {
        case .terminal:
            guard let session = tab.terminalSessionViewModel else {
                return "Idle"
            }

            if session.isConnected {
                return "Connected"
            }

            if session.isConnecting {
                return "Connecting"
            }

            if session.latestErrorMessage != nil {
                return "Attention"
            }

            return "Idle"
        case .voice:
            return tab.voiceSessionViewModel?.status.title ?? "Call"
        }
    }
}

private struct SessionWorkspaceTabChip: View {
    let tab: SessionWorkspaceTab
    let statusColor: Color
    let statusTitle: String
    let palette: RelayTerminalPalette
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: RelayTheme.Spacing.tight) {
            Button(action: onSelect) {
                HStack(spacing: RelayTheme.Spacing.tight) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(statusColor.opacity(0.16))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: tab.kind == .terminal ? "desktopcomputer" : "waveform.and.mic")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(statusColor)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(tab.title)
                                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 12, bold: true))
                                .foregroundStyle(isSelected ? palette.textColor : palette.mutedColor)
                                .lineLimit(1)

                            if tab.kind == .voice, let assistantName = tab.voiceSessionViewModel?.assistant.displayName {
                                Text(assistantName)
                                    .font(TerminalFontRegistry.terminalSwiftUIFont(size: 9, bold: true))
                                    .foregroundStyle(palette.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(palette.accentColor.opacity(0.14))
                                    )
                            }
                        }

                        HStack(spacing: RelayTheme.Spacing.tight) {
                            Text(tab.subtitle)
                                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 11))
                                .foregroundStyle(palette.mutedColor)
                                .lineLimit(1)
                                .truncationMode(tab.kind == .voice ? .middle : .tail)

                            Spacer(minLength: 0)

                            Text(statusTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(statusColor)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? palette.textColor : palette.mutedColor)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill((isSelected ? palette.textColor : palette.mutedColor).opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title) tab")
        }
        .padding(.vertical, 8)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(minWidth: isSelected ? 220 : 176, maxWidth: isSelected ? 248 : 208, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? palette.raisedColor : palette.backgroundColor.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? palette.accentColor.opacity(0.52) : palette.subtleColor.opacity(0.78),
                    lineWidth: 1
                )
        )
    }
}

private struct TerminalNewTabPickerView: View {
    let provider: any MeshProvider
    let currentHost: Host?
    let onOpenHost: (Host) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var snapshot: MeshProviderSnapshot = .checking
    @State private var peers: [PeerDevice] = []
    @State private var isLoading = false
    @State private var resolvingPeerID: PeerDevice.ID?
    @State private var errorMessage: String?
    @State private var loginHost: Host?
    @State private var pendingAuthenticatedHost: Host?

    var body: some View {
        List {
            if let currentHost {
                Section("Current Session") {
                    Button {
                        openCurrentHost(currentHost)
                    } label: {
                        VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                            Text("Open Another Tab")
                                .font(.headline)
                                .foregroundStyle(palette.textColor)

                            Text("\(currentHost.username)@\(currentHost.hostname)")
                                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 13))
                                .foregroundStyle(palette.mutedColor)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(palette.surfaceColor)
                }
            }

            Section(provider.displayName) {
                devicesContent
            }

            if let errorMessage, !peers.isEmpty {
                Section {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(palette.dangerColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(palette.surfaceColor)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(palette.backgroundColor.ignoresSafeArea())
        .navigationTitle("New Terminal Tab")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if isLoading {
                    ProgressView()
                        .tint(palette.textColor)
                } else {
                    Button {
                        Task {
                            await refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .foregroundStyle(palette.textColor)
                }
            }
        }
        .task {
            guard peers.isEmpty, case .checking = snapshot.status else { return }
            await refresh()
        }
        .refreshable {
            await refresh()
        }
        .sheet(item: $loginHost, onDismiss: openPendingAuthenticatedHostIfNeeded) { host in
            NavigationStack {
                SSHLoginView(host: host) { authenticatedHost in
                    pendingAuthenticatedHost = authenticatedHost
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var palette: RelayTerminalPalette {
        RelayTerminalPalette.palette(for: colorScheme)
    }

    @ViewBuilder
    private var devicesContent: some View {
        switch snapshot.status {
        case .checking:
            loadingRow(title: "Checking devices")
                .listRowBackground(palette.surfaceColor)
        case .unavailable(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(palette.mutedColor)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(palette.surfaceColor)
        case .ready:
            if isLoading && peers.isEmpty {
                loadingRow(title: "Refreshing devices")
                    .listRowBackground(palette.surfaceColor)
            } else if peers.isEmpty {
                Text("No devices are available to open in a new tab.")
                    .font(.subheadline)
                    .foregroundStyle(palette.mutedColor)
                    .padding(.vertical, 8)
                    .listRowBackground(palette.surfaceColor)
            } else {
                ForEach(peers) { peer in
                    Button {
                        Task {
                            await resolveEndpoint(for: peer)
                        }
                    } label: {
                        HStack(spacing: RelayTheme.Spacing.compact) {
                            Circle()
                                .fill((peer.isOnline ? palette.successColor : palette.mutedColor).opacity(0.18))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Image(systemName: peer.isOnline ? "desktopcomputer.and.arrow.down" : "desktopcomputer")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(peer.isOnline ? palette.successColor : palette.mutedColor)
                                }

                            VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                                Text(peer.name)
                                    .font(.headline)
                                    .foregroundStyle(palette.textColor)

                                Text(peer.networkAddress)
                                    .font(TerminalFontRegistry.terminalSwiftUIFont(size: 13))
                                    .foregroundStyle(palette.mutedColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: RelayTheme.Spacing.tight)

                            if resolvingPeerID == peer.id {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(palette.textColor)
                            } else {
                                Text(peer.isOnline ? "Online" : "Offline")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(peer.isOnline ? palette.successColor : palette.mutedColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!peer.isOnline || resolvingPeerID != nil)
                    .listRowBackground(palette.surfaceColor)
                }
            }
        }
    }

    private func loadingRow(title: String) -> some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            ProgressView()
                .tint(palette.textColor)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(palette.mutedColor)
        }
        .padding(.vertical, 8)
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
                openHost(host)
            } else {
                loginHost = host
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openCurrentHost(_ host: Host) {
        openHost(host)
    }

    private func openHost(_ host: Host) {
        onOpenHost(host)
        dismiss()
    }

    private func openPendingAuthenticatedHostIfNeeded() {
        guard let pendingAuthenticatedHost else { return }
        self.pendingAuthenticatedHost = nil
        openHost(pendingAuthenticatedHost)
    }
}

private struct VoiceNewCallPickerView: View {
    let provider: any MeshProvider
    let onStartCall: (VoiceSessionConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var snapshot: MeshProviderSnapshot = .checking
    @State private var peers: [PeerDevice] = []
    @State private var isLoading = false
    @State private var resolvingPeerID: PeerDevice.ID?
    @State private var errorMessage: String?
    @State private var loginHost: Host?
    @State private var pendingAuthenticatedHost: Host?
    @State private var pendingSavedDevice: SavedDevice?
    @State private var workspaceDraft: VoiceCallLaunchDraft?

    var body: some View {
        let palette = RelayTerminalPalette.palette(for: colorScheme)

        List {
            Section {
                devicesContent(palette: palette)
            }

            if let errorMessage, !peers.isEmpty {
                Section {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(palette.dangerColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(palette.surfaceColor)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(palette.backgroundColor.ignoresSafeArea())
        .navigationTitle("New Voice Call")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if isLoading {
                    ProgressView()
                        .tint(palette.textColor)
                } else {
                    Button {
                        Task {
                            await refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .foregroundStyle(palette.textColor)
                }
            }
        }
        .task {
            guard peers.isEmpty, case .checking = snapshot.status else { return }
            await refresh()
        }
        .refreshable {
            await refresh()
        }
        .sheet(item: $loginHost, onDismiss: openPendingAuthenticatedHostIfNeeded) { host in
            NavigationStack {
                SSHLoginView(host: host) { authenticatedHost in
                    pendingAuthenticatedHost = authenticatedHost
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $workspaceDraft) { draft in
            VoiceWorkspacePickerView(
                host: draft.host,
                initialWorkspacePath: draft.initialWorkspacePath,
                initialAssistant: .codex,
                supportsSavingDefault: provider.supportsManualHostManagement && draft.savedDevice != nil,
                onCancel: {
                    workspaceDraft = nil
                },
                onStart: { assistant, workspacePath, saveDefault in
                    Task {
                        await startCall(
                            from: draft,
                            assistant: assistant,
                            workspacePath: workspacePath,
                            persistAsDefault: saveDefault
                        )
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func devicesContent(palette: RelayTerminalPalette) -> some View {
        switch snapshot.status {
        case .checking:
            loadingRow(title: "Checking devices", palette: palette)
                .listRowBackground(palette.surfaceColor)
        case .unavailable(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(palette.mutedColor)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(palette.surfaceColor)
        case .ready:
            if isLoading && peers.isEmpty {
                loadingRow(title: "Refreshing devices", palette: palette)
                    .listRowBackground(palette.surfaceColor)
            } else if peers.isEmpty {
                Text("No devices are available for a new call.")
                    .font(.subheadline)
                    .foregroundStyle(palette.mutedColor)
                    .padding(.vertical, 8)
                    .listRowBackground(palette.surfaceColor)
            } else {
                ForEach(peers) { peer in
                    Button {
                        Task {
                            await resolveEndpoint(for: peer)
                        }
                    } label: {
                        HStack(spacing: RelayTheme.Spacing.compact) {
                            Circle()
                                .fill((peer.isOnline ? palette.successColor : palette.mutedColor).opacity(0.18))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Image(systemName: peer.isOnline ? "waveform.and.mic" : "desktopcomputer")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(peer.isOnline ? palette.successColor : palette.mutedColor)
                                }

                            VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                                Text(peer.name)
                                    .font(.headline)
                                    .foregroundStyle(palette.textColor)

                                Text(peer.networkAddress)
                                    .font(TerminalFontRegistry.terminalSwiftUIFont(size: 13))
                                    .foregroundStyle(palette.mutedColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: RelayTheme.Spacing.tight)

                            if resolvingPeerID == peer.id {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(palette.textColor)
                            } else {
                                Text(peer.isOnline ? "Online" : "Offline")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(peer.isOnline ? palette.successColor : palette.mutedColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!peer.isOnline || resolvingPeerID != nil)
                    .listRowBackground(palette.surfaceColor)
                }
            }
        }
    }

    private func loadingRow(title: String, palette: RelayTerminalPalette) -> some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            ProgressView()
                .tint(palette.textColor)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(palette.mutedColor)
        }
        .padding(.vertical, 8)
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

    private func resolveEndpoint(for peer: PeerDevice) async {
        guard peer.isOnline else { return }

        resolvingPeerID = peer.id
        errorMessage = nil

        defer {
            resolvingPeerID = nil
        }

        do {
            let host = try await provider.endpoint(for: peer)
            let savedDevice = makeSavedDeviceDraft(from: peer)
            pendingSavedDevice = savedDevice

            if shouldConnectDirectly(to: host) {
                workspaceDraft = VoiceCallLaunchDraft(
                    host: host,
                    initialWorkspacePath: savedDevice.defaultCodexPath ?? host.defaultCodexPath ?? "",
                    savedDevice: savedDevice
                )
            } else {
                loginHost = host
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shouldConnectDirectly(to host: Host) -> Bool {
        if host.usesPasswordAuthentication {
            return true
        }

        return RelayPreferences.shared.usesSavedKeysAutomatically &&
            RelayServices.sshCredentials.hasStoredKey(for: host.remoteIdentity)
    }

    private func openPendingAuthenticatedHostIfNeeded() {
        guard let pendingAuthenticatedHost else { return }

        let savedDevice = pendingSavedDevice
        self.pendingAuthenticatedHost = nil
        self.pendingSavedDevice = nil
        workspaceDraft = VoiceCallLaunchDraft(
            host: pendingAuthenticatedHost,
            initialWorkspacePath: savedDevice?.defaultCodexPath ?? pendingAuthenticatedHost.defaultCodexPath ?? "",
            savedDevice: savedDevice
        )
    }

    private func startCall(
        from draft: VoiceCallLaunchDraft,
        assistant: VoiceAssistant,
        workspacePath: String,
        persistAsDefault: Bool
    ) async {
        let trimmedWorkspacePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkspacePath.isEmpty else { return }

        if persistAsDefault, var savedDevice = draft.savedDevice {
            savedDevice.defaultCodexPath = trimmedWorkspacePath

            do {
                try await provider.saveHost(savedDevice)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        var host = draft.host
        host.defaultCodexPath = trimmedWorkspacePath
        workspaceDraft = nil
        onStartCall(
            VoiceSessionConfiguration(
                host: host,
                workspacePath: trimmedWorkspacePath,
                assistant: assistant
            )
        )
        dismiss()
    }

    private func makeSavedDeviceDraft(from peer: PeerDevice) -> SavedDevice {
        SavedDevice(
            id: peer.id,
            name: peer.name,
            hostname: peer.networkAddress,
            port: peer.port,
            username: peer.sshUsername,
            defaultCodexPath: nil
        )
    }
}

private struct VoiceCallLaunchDraft: Identifiable {
    let id = UUID()
    let host: Host
    let initialWorkspacePath: String
    let savedDevice: SavedDevice?
}
