//
//  RelaySettingsController.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Observation
import UIKit

@MainActor
@Observable
final class RelaySettingsController {
    var registration: RelayAppRegistration?
    var pairingCode: RelayPairingCode?
    var latestErrorMessage: String?
    var isRegistering = false
    var isGeneratingPairingCode = false

    private let apiClient: RelayAPIClient
    private let configurationStore: RelayConfigurationStore

    convenience init() {
        let configurationStore = RelayConfigurationStore.shared
        self.init(
            apiClient: RelayAPIClient(configurationStore: configurationStore),
            configurationStore: configurationStore
        )
    }

    init(
        apiClient: RelayAPIClient,
        configurationStore: RelayConfigurationStore
    ) {
        self.apiClient = apiClient
        self.configurationStore = configurationStore
        self.registration = configurationStore.registration()
    }

    var isRegistered: Bool {
        registration != nil
    }

    func load() {
        registration = configurationStore.registration()
    }

    func registerCurrentDevice() async {
        guard !isRegistering else { return }

        isRegistering = true
        latestErrorMessage = nil
        pairingCode = nil
        defer { isRegistering = false }

        do {
            registration = try await apiClient.bootstrapApp(deviceName: UIDevice.current.name)
        } catch {
            latestErrorMessage = error.localizedDescription
        }
    }

    func createPairingCode() async {
        guard !isGeneratingPairingCode else { return }

        isGeneratingPairingCode = true
        latestErrorMessage = nil
        defer { isGeneratingPairingCode = false }

        do {
            pairingCode = try await apiClient.createPairingCode()
        } catch {
            latestErrorMessage = error.localizedDescription
        }
    }

    func clearRegistration() {
        configurationStore.clearRegistration()
        registration = nil
        pairingCode = nil
        latestErrorMessage = nil
    }
}
