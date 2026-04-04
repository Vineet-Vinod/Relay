//
//  ContentView.swift
//  Relay
//
//  Created by Ryan Baker on 4/4/26.
//

import SwiftUI

@MainActor
struct ContentView: View {
    private enum Tab: Hashable {
        case devices
        case settings
    }

    @AppStorage(RelayDefaultsKey.meshProviderKind) private var providerKindRawValue = MeshProviderKind.tailscale.rawValue
    private let injectedProvider: (any MeshProvider)?
    @State private var selectedTab: Tab = .devices

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
        return MeshProviderFactory.makeProvider(for: kind)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HostListView(provider: provider)
            }
            .tabItem {
                Label("Devices", systemImage: "desktopcomputer")
            }
            .tag(Tab.devices)

            NavigationStack {
                SettingsView(provider: provider)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
    }
}

#Preview {
    ContentView()
}
