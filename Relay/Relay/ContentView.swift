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

    private let provider: any MeshProvider
    @State private var voiceCallManager = VoiceCallManager()
    @State private var selectedTab: Tab = .devices

    init() {
        self.provider = ManualDeviceProvider()
    }

    init(provider: any MeshProvider) {
        self.provider = provider
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
        .environment(voiceCallManager)
        .fullScreenCover(
            isPresented: Binding(
                get: { voiceCallManager.hasActiveCalls },
                set: { _ in }
            )
        ) {
            VoiceCallWorkspaceView(provider: provider)
                .environment(voiceCallManager)
        }
    }
}

#Preview {
    ContentView()
}
