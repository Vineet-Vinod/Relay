//
//  ContentView.swift
//  Relay
//
//  Created by Ryan Baker on 4/4/26.
//

import SwiftUI
import OSLog

@MainActor
struct ContentView: View {
    private enum Tab: Hashable {
        case devices
        case settings
    }

    @AppStorage(RelayDefaultsKey.meshProviderKind) private var providerKindRawValue = MeshProviderKind.tailscale.rawValue
    private let injectedProvider: (any MeshProvider)?
    @State private var sessionWorkspaceManager = SessionWorkspaceManager()
    @State private var selectedTab: Tab = .devices
    @State private var tailscaleProvider = ManualDeviceProvider()
    @State private var relayProvider = RelayMeshProvider()

    private let logger = Logger(subsystem: "Relay", category: "ContentView")

    init() {
        self.injectedProvider = nil
    }

    init(provider: any MeshProvider) {
        self.injectedProvider = provider
    }

    private var provider: any MeshProvider {
        if let injectedProvider {
            return injectedProvider
        }

        let kind = MeshProviderKind(rawValue: providerKindRawValue) ?? .tailscale
        switch kind {
        case .tailscale:
            return tailscaleProvider
        case .relay:
            return relayProvider
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                if selectedTab == .devices {
                    HostListView(
                        provider: provider,
                        isActive: true
                    )
                    .id(provider.displayName)
                } else {
                    Color.clear
                }
            }
            .tabItem {
                Label("Devices", systemImage: "desktopcomputer")
            }
            .tag(Tab.devices)

            NavigationStack {
                if selectedTab == .settings {
                    SettingsView(
                        provider: provider,
                        isActive: true
                    )
                    .id(provider.displayName)
                } else {
                    Color.clear
                }
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
        .task {
            logger.info("ContentView loaded with provider kind \(self.providerKindRawValue, privacy: .public)")
        }
        .environment(sessionWorkspaceManager)
    }
}

#Preview {
    ContentView()
}
