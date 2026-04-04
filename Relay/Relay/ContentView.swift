//
//  ContentView.swift
//  Relay
//
//  Created by Ryan Baker on 4/4/26.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedProviderMode: MeshProviderMode

    init(selectedProviderMode: MeshProviderMode = AppEnvironment.defaultMeshProviderMode) {
        _selectedProviderMode = State(initialValue: selectedProviderMode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                providerPicker
                HostListView(provider: MeshProviderFactory.makeProvider(mode: selectedProviderMode))
                    .id(selectedProviderMode)
            }
        }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Network")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Network", selection: $selectedProviderMode) {
                ForEach(MeshProviderMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedProviderMode.subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

#Preview {
    ContentView()
}
