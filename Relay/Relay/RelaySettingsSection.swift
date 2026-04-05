//
//  RelaySettingsSection.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI
import UIKit

struct RelaySetupView: View {
    @State private var controller = RelaySettingsController()
    @State private var serverURL = UserDefaults.standard.string(forKey: RelayDefaultsKey.relayServerURL) ?? ""
    @State private var allowInsecureTLS = UserDefaults.standard.object(forKey: RelayDefaultsKey.relayAllowInsecureTLS) as? Bool ?? false
    @State private var hasLoaded = false
    @State private var notice: RelaySetupNotice?

    var body: some View {
        List {
            Section {
                overviewCard
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)

            Section {
                TextField("https://relay.example.com", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        saveDraftSettings()
                    }

                Toggle("Allow Self-Signed TLS", isOn: $allowInsecureTLS)

                Button("Save Relay Server") {
                    saveDraftSettings()
                    notice = RelaySetupNotice(
                        title: "Relay Saved",
                        message: "Relay will use this server for registration, pairing, and remote sessions."
                    )
                }
                .buttonStyle(.bordered)
                .disabled(trimmedServerURL.isEmpty)
            } header: {
                Text("Connection")
            } footer: {
                Text("Use your Relay server URL here. For local development, self-signed certificates require the toggle above.")
            }

            Section {
                if let registration = controller.registration {
                    LabeledContent("App Registration") {
                        Text(registration.appID)
                            .font(TerminalFontRegistry.terminalSwiftUIFont(size: 13))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Register this iPhone before pairing a Mac agent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(controller.isRegistering ? "Registering This iPhone..." : "Register This iPhone") {
                    Task {
                        saveDraftSettings()
                        await controller.registerCurrentDevice()
                    }
                }
                .disabled(controller.isRegistering || trimmedServerURL.isEmpty)

                Button(controller.isGeneratingPairingCode ? "Creating Pairing Code..." : "Create Pairing Code") {
                    Task {
                        saveDraftSettings()
                        await controller.createPairingCode()
                    }
                }
                .disabled(!controller.isRegistered || controller.isGeneratingPairingCode || trimmedServerURL.isEmpty)

                if let pairingCode = controller.pairingCode {
                    VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                        Text("Pairing Code")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(pairingCode.code)
                            .font(TerminalFontRegistry.terminalSwiftUIFont(size: 22))
                            .foregroundStyle(RelayTheme.accent)

                        Text("Expires \(pairingCode.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Copy Code") {
                            UIPasteboard.general.string = pairingCode.code
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }

                if controller.isRegistered {
                    Button("Forget Relay Registration", role: .destructive) {
                        controller.clearRegistration()
                    }
                }

                if let latestErrorMessage = controller.latestErrorMessage {
                    Text(latestErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(RelayTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Pairing")
            } footer: {
                Text("Pair a Mac agent after this iPhone is registered. The agent keeps one outbound secure WebSocket connected to your Relay server.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RelayTheme.surfaceBase)
        .navigationTitle("Relay Server")
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            loadDraftSettings()
        }
        .onChange(of: allowInsecureTLS) { _, _ in
            saveDraftSettings()
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
                    .fill(RelayTheme.accent.opacity(0.14))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "server.rack")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(RelayTheme.accent)
                    }

                VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                    Text("Hosted Relay")
                        .font(.headline)

                    Text("Use Relay when you want remote terminal access through your HTTPS server and a paired macOS agent.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: RelayTheme.Spacing.compact) {
                overviewMetric(title: "Server", value: trimmedServerURL.isEmpty ? "Unset" : "Configured")
                overviewMetric(title: "iPhone", value: controller.isRegistered ? "Registered" : "Unpaired")
            }
        }
        .relayAppCard()
    }

    private func overviewMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
    }

    private var trimmedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadDraftSettings() {
        serverURL = UserDefaults.standard.string(forKey: RelayDefaultsKey.relayServerURL) ?? ""
        allowInsecureTLS = UserDefaults.standard.object(forKey: RelayDefaultsKey.relayAllowInsecureTLS) as? Bool ?? false
        controller.load()
    }

    private func saveDraftSettings() {
        let defaults = UserDefaults.standard
        defaults.set(trimmedServerURL, forKey: RelayDefaultsKey.relayServerURL)
        defaults.set(allowInsecureTLS, forKey: RelayDefaultsKey.relayAllowInsecureTLS)
    }
}

private struct RelaySetupNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
