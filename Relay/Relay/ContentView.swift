//
//  ContentView.swift
//  Relay
//
//  Created by Ryan Baker on 4/4/26.
//

import SwiftUI

struct ContentView: View {
    private let store = HostStore()

    var body: some View {
        NavigationStack {
            HostListView(store: store)
        }
    }
}

#Preview {
    ContentView()
}
