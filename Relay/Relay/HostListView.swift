//
//  HostListView.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI

struct HostListView: View {
    let store: HostStore

    var body: some View {
        List(store.hosts) { host in
            NavigationLink {
                TerminalView(viewModel: TerminalSessionViewModel(host: host))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.name)
                        .font(.headline)

                    Text("\(host.username)@\(host.hostname):\(host.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Hosts")
    }
}

#Preview {
    NavigationStack {
        HostListView(store: HostStore())
    }
}
