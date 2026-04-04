//
//  TerminalView.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI

struct TerminalView: View {
    @State var viewModel: TerminalSessionViewModel
    @FocusState private var isCommandFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            terminalOutput
            Divider()
            commandBar
        }
        .navigationTitle(viewModel.host.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.connect()
            isCommandFieldFocused = true
        }
        .onDisappear {
            Task {
                await viewModel.disconnect()
            }
        }
    }

    private var terminalOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.lines) { line in
                        Text(line.text)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding()
            }
            .background(Color.black)
            .onChange(of: viewModel.lines.count) {
                guard let lastLine = viewModel.lines.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(lastLine.id, anchor: .bottom)
                }
            }
        }
    }

    private var commandBar: some View {
        HStack(spacing: 12) {
            Text("$")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            TextField("Enter a command", text: $viewModel.command)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isCommandFieldFocused)
                .submitLabel(.send)
                .onSubmit {
                    Task {
                        await viewModel.runCommand()
                    }
                }

            Button("Run") {
                Task {
                    await viewModel.runCommand()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.isConnected || viewModel.isRunningCommand)
        }
        .padding()
        .background(.background)
    }

    private func color(for kind: TerminalLine.Kind) -> Color {
        switch kind {
        case .localPrompt:
            .green
        case .remoteOutput:
            .white
        case .status:
            .cyan
        case .error:
            .red
        }
    }
}

#Preview {
    NavigationStack {
        TerminalView(
            viewModel: TerminalSessionViewModel(
                host: Host(
                    peer: PeerDevice(
                        name: "Ryan MacBook Pro",
                        networkAddress: "192.168.1.25",
                        sshUsername: "ryan",
                        isOnline: true,
                        operatingSystem: "macOS",
                        ownerName: "Ryan Baker"
                    )
                )
            )
        )
    }
}
