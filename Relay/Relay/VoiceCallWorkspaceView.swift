//
//  VoiceCallWorkspaceView.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI
import UIKit

struct VoiceCallWorkspaceView: View {
    let provider: any MeshProvider

    @Environment(\.colorScheme) private var colorScheme
    @Environment(VoiceCallManager.self) private var callManager

    @AppStorage(RelayDefaultsKey.keepScreenAwake) private var keepsScreenAwake = true

    @State private var isPresentingNewCallPicker = false

    var body: some View {
        let palette = RelayTerminalPalette.palette(for: colorScheme)

        VStack(spacing: 0) {
            workspaceHeader(palette: palette)

            Rectangle()
                .fill(palette.subtleColor.opacity(0.75))
                .frame(height: 1)

            ZStack {
                palette.backgroundColor
                    .ignoresSafeArea()

                ForEach(callManager.calls) { session in
                    callSessionContent(for: session)
                }
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .interactiveDismissDisabled()
        .sheet(isPresented: $isPresentingNewCallPicker) {
            NavigationStack {
                VoiceNewCallPickerView(provider: provider) {
                    isPresentingNewCallPicker = false
                }
            }
            .environment(callManager)
        }
        .onAppear {
            updateIdleTimer()
        }
        .onChange(of: keepsScreenAwake) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: callManager.calls.count) { _, _ in
            updateIdleTimer()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func workspaceHeader(palette: RelayTerminalPalette) -> some View {
        VStack(spacing: RelayTheme.Spacing.tight) {
            HStack(spacing: RelayTheme.Spacing.compact) {
                VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                    Text("Calls")
                        .font(.headline)
                        .foregroundStyle(palette.textColor)

                    Text(headerSubtitle)
                        .font(.footnote)
                        .foregroundStyle(palette.mutedColor)
                        .lineLimit(1)
                }

                Spacer(minLength: RelayTheme.Spacing.content)

                Button {
                    isPresentingNewCallPicker = true
                } label: {
                    Label("New Call", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(palette.accentColor)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RelayTheme.Spacing.tight) {
                    ForEach(callManager.calls) { session in
                        VoiceCallTabChip(
                            session: session,
                            palette: palette,
                            isSelected: callManager.selectedCallID == session.id,
                            onSelect: {
                                callManager.selectCall(session.id)
                            },
                            onEnd: {
                                callManager.endCall(session.id)
                            }
                        )
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, RelayTheme.Spacing.content)
        .padding(.top, RelayTheme.Spacing.compact)
        .padding(.bottom, RelayTheme.Spacing.tight)
        .background(palette.surfaceColor)
    }

    private func callSessionContent(for session: VoiceCallManager.CallSession) -> some View {
        let isSelected = callManager.selectedCallID == session.id

        return VoiceSessionView(
            onEnd: {
                callManager.endCall(session.id)
            },
            isActive: isSelected,
            viewModel: session.viewModel
        )
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected)
        .accessibilityHidden(!isSelected)
        .zIndex(isSelected ? 1 : 0)
    }

    private var headerSubtitle: String {
        switch callManager.calls.count {
        case 0:
            return "No active calls"
        case 1:
            return "1 active voice call"
        default:
            return "\(callManager.calls.count) active voice calls"
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake && callManager.hasActiveCalls
    }
}

private struct VoiceCallTabChip: View {
    let session: VoiceCallManager.CallSession
    let palette: RelayTerminalPalette
    let isSelected: Bool
    let onSelect: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: RelayTheme.Spacing.tight) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: RelayTheme.Spacing.tight) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)

                        Text(session.viewModel.title)
                            .font(TerminalFontRegistry.terminalSwiftUIFont(size: 12, bold: true))
                            .foregroundStyle(palette.textColor)
                            .lineLimit(1)

                        assistantBadge

                        Spacer(minLength: 0)

                        if session.viewModel.pendingNarrationCount > 0 {
                            messageBadge
                        }
                    }

                    HStack(spacing: RelayTheme.Spacing.tight) {
                        Text(session.viewModel.resolvedWorkspacePath)
                            .font(TerminalFontRegistry.terminalSwiftUIFont(size: 11))
                            .foregroundStyle(palette.mutedColor)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: RelayTheme.Spacing.tight)

                        Text(session.viewModel.status.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(session.viewModel.title), \(session.viewModel.assistant.displayName), \(session.viewModel.subtitle)")
            .accessibilityValue("\(session.viewModel.status.title), \(session.viewModel.resolvedWorkspacePath)")

            Button(action: onEnd) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? palette.textColor : palette.mutedColor)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill((isSelected ? palette.textColor : palette.mutedColor).opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End call with \(session.viewModel.title)")
        }
        .padding(.vertical, 8)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(minWidth: isSelected ? 204 : 176, maxWidth: isSelected ? 220 : 192, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? palette.raisedColor : palette.backgroundColor.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? palette.accentColor.opacity(0.58) : palette.subtleColor.opacity(0.78),
                    lineWidth: 1
                )
        )
    }

    private var messageBadge: some View {
        Text("\(session.viewModel.pendingNarrationCount)")
            .font(TerminalFontRegistry.terminalSwiftUIFont(size: 10, bold: true))
            .foregroundStyle(palette.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(palette.accentColor.opacity(0.16))
            )
    }

    private var assistantBadge: some View {
        Text(session.viewModel.assistant.displayName)
            .font(TerminalFontRegistry.terminalSwiftUIFont(size: 9, bold: true))
            .foregroundStyle(palette.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(palette.accentColor.opacity(0.14))
            )
    }

    private var statusColor: Color {
        switch session.viewModel.status {
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

private struct VoiceNewCallPickerView: View {
    let provider: any MeshProvider
    let onStarted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(VoiceCallManager.self) private var callManager

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
        .navigationTitle("New Call")
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
        callManager.startCall(
            configuration: VoiceSessionConfiguration(
                host: host,
                workspacePath: trimmedWorkspacePath,
                assistant: assistant
            )
        )
        onStarted()
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
