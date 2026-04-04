//
//  ContentView.swift
//  Relay
//
//  Created by Ryan Baker on 4/4/26.
//

import SwiftUI

struct ContentView: View {
    private let meshService = MockMeshServiceClient()

    var body: some View {
        NavigationStack {
            HostListView(service: meshService)
        }
    }
}

#Preview {
    ContentView()
}
