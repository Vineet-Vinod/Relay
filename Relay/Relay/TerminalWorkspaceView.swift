//
//  TerminalWorkspaceView.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Observation
import SwiftUI
import UIKit

@MainActor
struct TerminalWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var workspace: TerminalWorkspaceViewModel

    init(provider: any MeshProvider, initialHost: Host) {
        _workspace = State(initialValue: TerminalWorkspaceViewModel(provider: provider, initialHost: initialHost))
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalTabStrip(
                tabs: workspace.tabs,
                selectedTabID: workspace.selectedTabID,
                palette: palette,
                onSelect: workspace.selectTab,
                onClose: closeTab,
                onNewTab: workspace.presentNewTabPicker
            )

            Rectangle()
                .fill(palette.subtleColor.opacity(0.72))
                .frame(height: 1)

            ZStack {
                ForEach(workspace.tabs) { tab in
                    TerminalView(
                        viewModel: tab.sessionViewModel,
                        isActive: workspace.selectedTabID == tab.id
                    )
                    .opacity(workspace.selectedTabID == tab.id ? 1 : 0)
                    .allowsHitTesting(workspace.selectedTabID == tab.id)
                    .accessibilityHidden(workspace.selectedTabID != tab.id)
                    .zIndex(workspace.selectedTabID == tab.id ? 1 : 0)
                }
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .navigationTitle(workspace.selectedTab?.sessionViewModel.host.name ?? "Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.surfaceColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    workspace.presentNewTabPicker()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Open new terminal tab")
                .foregroundStyle(palette.textColor)
            }
        }
        .sheet(isPresented: newTabPickerBinding) {
            NavigationStack {
                TerminalNewTabPickerView(
                    provider: workspace.provider,
                    currentHost: workspace.selectedTab?.sessionViewModel.host,
                    onOpenHost: { host in
                        workspace.openTab(for: host)
                    }
                )
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var palette: RelayTerminalPalette {
        RelayTerminalPalette.palette(for: colorScheme)
    }

    private var newTabPickerBinding: Binding<Bool> {
        Binding(
            get: { workspace.isShowingNewTabPicker },
            set: { isPresented in
                if isPresented {
                    workspace.presentNewTabPicker()
                } else {
                    workspace.dismissNewTabPicker()
                }
            }
        )
    }

    private func closeTab(_ tabID: TerminalWorkspaceTab.ID) {
        if workspace.closeTab(id: tabID) {
            dismiss()
        }
    }
}

@MainActor
@Observable
private final class TerminalWorkspaceViewModel {
    let provider: any MeshProvider

    var tabs: [TerminalWorkspaceTab]
    var selectedTabID: TerminalWorkspaceTab.ID
    var isShowingNewTabPicker = false

    init(provider: any MeshProvider, initialHost: Host) {
        self.provider = provider

        let initialTab = TerminalWorkspaceTab(host: initialHost)
        self.tabs = [initialTab]
        self.selectedTabID = initialTab.id
    }

    var selectedTab: TerminalWorkspaceTab? {
        tabs.first(where: { $0.id == selectedTabID })
    }

    func selectTab(_ tabID: TerminalWorkspaceTab.ID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabID = tabID
    }

    func openTab(for host: Host) {
        let tab = TerminalWorkspaceTab(host: host)
        tabs.append(tab)
        selectedTabID = tab.id
        isShowingNewTabPicker = false
    }

    func closeTab(id: TerminalWorkspaceTab.ID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return tabs.isEmpty
        }

        let closingTab = tabs.remove(at: index)
        isShowingNewTabPicker = false

        Task {
            await closingTab.sessionViewModel.disconnect()
        }

        guard !tabs.isEmpty else {
            return true
        }

        if selectedTabID == id {
            let nextIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[nextIndex].id
        }

        return false
    }

    func presentNewTabPicker() {
        isShowingNewTabPicker = true
    }

    func dismissNewTabPicker() {
        isShowingNewTabPicker = false
    }
}

private struct TerminalWorkspaceTab: Identifiable {
    let id = UUID()
    let sessionViewModel: TerminalSessionViewModel

    init(host: Host) {
        self.sessionViewModel = TerminalSessionViewModel(host: host)
    }
}

private struct TerminalTabStrip: View {
    let tabs: [TerminalWorkspaceTab]
    let selectedTabID: TerminalWorkspaceTab.ID
    let palette: RelayTerminalPalette
    let onSelect: (TerminalWorkspaceTab.ID) -> Void
    let onClose: (TerminalWorkspaceTab.ID) -> Void
    let onNewTab: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RelayTheme.Spacing.tight) {
                ForEach(tabs) { tab in
                    TerminalTabChip(
                        title: tab.sessionViewModel.host.name,
                        subtitle: "\(tab.sessionViewModel.host.username)@\(tab.sessionViewModel.host.hostname)",
                        statusColor: statusColor(for: tab.sessionViewModel),
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

                Button(action: onNewTab) {
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
                .accessibilityLabel("Open new terminal tab")
            }
            .padding(.horizontal, RelayTheme.Spacing.content)
            .padding(.vertical, RelayTheme.Spacing.tight)
        }
        .background(palette.surfaceColor)
    }

    private func statusColor(for session: TerminalSessionViewModel) -> Color {
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
    }
}

private struct TerminalTabChip: View {
    let title: String
    let subtitle: String
    let statusColor: Color
    let palette: RelayTerminalPalette
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: RelayTheme.Spacing.tight) {
            Button(action: onSelect) {
                HStack(spacing: RelayTheme.Spacing.tight) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)

                    Text(title)
                        .font(TerminalFontRegistry.terminalSwiftUIFont(size: 12, bold: true))
                        .foregroundStyle(isSelected ? palette.textColor : palette.mutedColor)
                        .lineLimit(1)

                    if isSelected {
                        Text(subtitle)
                            .font(TerminalFontRegistry.terminalSwiftUIFont(size: 11))
                            .foregroundStyle(palette.mutedColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
            .accessibilityLabel("Close \(title) tab")
        }
        .padding(.vertical, 7)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(minWidth: isSelected ? 196 : 120, maxWidth: isSelected ? 220 : 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? palette.raisedColor : palette.backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? palette.accentColor.opacity(0.5) : palette.subtleColor.opacity(0.78),
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
        .navigationTitle("New Tab")
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
            if shouldConnectDirectly(to: host) {
                dismiss()
                DispatchQueue.main.async {
                    onOpenHost(host)
                }
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

    private func openCurrentHost(_ host: Host) {
        dismiss()
        DispatchQueue.main.async {
            onOpenHost(host)
        }
    }

    private func openPendingAuthenticatedHostIfNeeded() {
        guard let pendingAuthenticatedHost else { return }
        self.pendingAuthenticatedHost = nil
        dismiss()
        DispatchQueue.main.async {
            onOpenHost(pendingAuthenticatedHost)
        }
    }
}
