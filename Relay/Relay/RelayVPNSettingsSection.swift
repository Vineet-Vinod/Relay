//
//  RelayVPNSettingsSection.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI

struct RelayVPNSettingsSection: View {
    @Binding var selectedNetworkPath: RelayNetworkPath
    @ObservedObject var controller: RelayVPNController

    var body: some View {
        Section {
            Picker("Network Path", selection: $selectedNetworkPath) {
                ForEach(RelayNetworkPath.allCases) { path in
                    Text(path.title).tag(path)
                }
            }

            switch selectedNetworkPath {
            case .relayVPN:
                relayVPNContent
            case .tailscale:
                staticStatusRow(
                    title: "Tailscale",
                    detail: RelayNetworkPath.tailscale.detail,
                    systemImage: "point.3.connected.trianglepath.dotted",
                    tint: RelayTheme.info
                )
            case .direct:
                staticStatusRow(
                    title: "Direct",
                    detail: RelayNetworkPath.direct.detail,
                    systemImage: "cable.connector",
                    tint: RelayTheme.accent
                )
            }
        } header: {
            Text("Network")
        } footer: {
            Text(selectedNetworkPath.detail)
        }
    }

    private var relayVPNContent: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.content) {
            statusCard

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                Text("Relay Control Server")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("http://192.168.1.50:8080", text: $controller.controlServerURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .relayAppFieldBackground(isFocused: false, isTechnical: true)
            }

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                Text("Peer Identifier")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("relay-ios-1234abcd", text: $controller.peerIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .relayAppFieldBackground(isFocused: false, isTechnical: true)
            }

            if let profileRecord = controller.profileRecord {
                profileSummary(profileRecord)
            }

            actionStack
        }
        .padding(.vertical, 4)
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: RelayTheme.Spacing.compact) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(statusTint.opacity(0.14))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: statusSymbolName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(statusTint)
                }

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                Text(controller.presentationState.title)
                    .font(.headline)

                Text(controller.presentationState.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastErrorMessage = controller.lastErrorMessage, !lastErrorMessage.isEmpty {
                    Text(lastErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(RelayTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .relayAppCard()
    }

    private func profileSummary(_ profileRecord: RelayVPNProfileRecord) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
            Text("Installed Profile")
                .font(.headline)

            settingsLine(title: "Peer ID", value: profileRecord.peerIdentifier)
            settingsLine(title: "Assigned Address", value: profileRecord.assignedAddress)
            settingsLine(title: "Server Endpoint", value: profileRecord.serverEndpoint)
            settingsLine(title: "Keepalive", value: "\(profileRecord.persistentKeepalive)s")
        }
        .relayAppCard()
    }

    private var actionStack: some View {
        VStack(spacing: RelayTheme.Spacing.tight) {
            if controller.profileRecord == nil {
                Button("Register And Connect") {
                    Task {
                        await controller.registerAndConnect()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(RelayTheme.accent)
                .disabled(!controller.canRegister)
            } else {
                if controller.presentationState == .connected || controller.presentationState == .connecting {
                    Button("Disconnect Relay VPN") {
                        controller.disconnect()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Connect Relay VPN") {
                        controller.connect()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RelayTheme.accent)
                }

                Button("Re-Register Profile") {
                    Task {
                        await controller.registerAndConnect()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!controller.canRegister)

                Button("Remove Relay VPN", role: .destructive) {
                    Task {
                        await controller.removeConfiguration()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func settingsLine(title: String, value: String) -> some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 13))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func staticStatusRow(title: String, detail: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: RelayTheme.Spacing.compact) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusSymbolName: String {
        switch controller.presentationState {
        case .connected:
            return "checkmark.shield"
        case .connecting, .disconnecting:
            return "arrow.triangle.2.circlepath"
        case .disconnected, .notConfigured:
            return "shield"
        case .invalid, .error:
            return "exclamationmark.triangle"
        }
    }

    private var statusTint: Color {
        switch controller.presentationState {
        case .connected:
            return RelayTheme.success
        case .connecting, .disconnecting:
            return RelayTheme.info
        case .disconnected, .notConfigured:
            return RelayTheme.accent
        case .invalid, .error:
            return RelayTheme.warning
        }
    }
}
