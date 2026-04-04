//
//  RelaySettingsSection.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Observation
import SwiftUI
import UIKit

struct RelaySettingsSection: View {
    @Bindable var controller: RelaySettingsController
    @Binding var serverURL: String
    @Binding var allowInsecureTLS: Bool

    let isSelected: Bool

    var body: some View {
        Section {
            TextField("https://relay.example.com", text: $serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Toggle("Allow Self-Signed TLS", isOn: $allowInsecureTLS)

            if let registration = controller.registration {
                LabeledContent("App Registration") {
                    Text(registration.appID)
                        .font(TerminalFontRegistry.terminalSwiftUIFont(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Register this iPhone before pairing a Mac agent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(controller.isRegistering ? "Registering This iPhone..." : "Register This iPhone") {
                Task {
                    await controller.registerCurrentDevice()
                }
            }
            .disabled(controller.isRegistering || trimmedServerURL.isEmpty)

            Button(controller.isGeneratingPairingCode ? "Creating Pairing Code..." : "Create Pairing Code") {
                Task {
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
            Text("Relay")
        } footer: {
            Text(footerText)
        }
    }

    private var trimmedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var footerText: String {
        if isSelected {
            return "Relay routes terminal sessions through your HTTPS server and a paired macOS agent."
        }

        return "Configure Relay now so it is ready when you switch providers."
    }
}
