//
//  ContentView.swift
//  Relay
//
//  Created by Ryan Baker on 4/4/26.
//

import SwiftUI

@MainActor
struct ContentView: View {
    private let provider: any MeshProvider

    init() {
        self.provider = TailscaleMeshProvider()
    }

    init(provider: any MeshProvider) {
        self.provider = provider
    }

    var body: some View {
        NavigationStack {
            HostListView(provider: provider)
        }
    }
}

#Preview {
    ContentView()
}
