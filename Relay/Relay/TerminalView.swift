//
//  TerminalView.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftTerm
import SwiftUI
import UIKit

struct TerminalView: View {
    @State var viewModel: TerminalSessionViewModel
    @State private var terminalBridge = RelayTerminalBridge()
    @State private var isShowingPasswordSheet = false
    @State private var pendingReconnectHost: Host?

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.messages.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.messages) { message in
                            Text(message.text)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(color(for: message.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 140)
                .background(Color(uiColor: .secondarySystemBackground))
            }

            SSHTerminalSurface(
                bridge: terminalBridge,
                onSend: { data in
                    Task {
                        await viewModel.sendRawInput(Array(data))
                    }
                },
                onResize: { cols, rows in
                    Task {
                        await viewModel.resizeTerminal(columns: cols, rows: rows)
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.host.name)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)

                    if !viewModel.host.usesPasswordAuthentication && RelayServices.sshCredentials.hasStoredKey(for: viewModel.host.remoteIdentity) {
                        Text("Saved SSH key available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if viewModel.isConnecting || viewModel.isProvisioningSavedKey {
                    ProgressView()
                }

                if viewModel.canReconnectWithPassword {
                    Button("Use Password") {
                        isShowingPasswordSheet = true
                    }
                    .buttonStyle(.bordered)
                }

                Button(viewModel.isConnected ? "Disconnect" : "Connect") {
                    Task {
                        if viewModel.isConnected {
                            await viewModel.disconnect()
                        } else {
                            await viewModel.connect()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .navigationTitle(viewModel.host.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Use an SSH key for future logins?",
            isPresented: Binding(
                get: { viewModel.isShowingKeySetupPrompt },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissSavedKeyPrompt()
                    }
                }
            )
        ) {
            Button("Not Now", role: .cancel) {
                viewModel.dismissSavedKeyPrompt()
            }

            Button("Enable") {
                Task {
                    await viewModel.enableSavedKey()
                }
            }
        } message: {
            Text("Relay will generate an Ed25519 key on this device, install the public key on the remote account, and use it for future logins.")
        }
        .alert(
            "Verify SSH Host",
            isPresented: Binding(
                get: { viewModel.isShowingHostTrustPrompt },
                set: { _ in }
            )
        ) {
            Button("Cancel", role: .cancel) {
                viewModel.rejectPendingHostKey()
            }

            Button("Trust and Connect") {
                Task {
                    await viewModel.trustPendingHostKey()
                }
            }
        } message: {
            Text(
                """
                Relay has not seen this SSH host before.

                Host: \(viewModel.host.hostname):\(viewModel.host.port)
                Fingerprint: \(viewModel.pendingHostTrustSummary)

                Only trust this fingerprint if it matches the remote device.
                """
            )
        }
        .sheet(isPresented: $isShowingPasswordSheet, onDismiss: reconnectWithPendingPasswordHostIfNeeded) {
            NavigationStack {
                SSHLoginView(host: viewModel.host) { authenticatedHost in
                    pendingReconnectHost = authenticatedHost
                }
            }
        }
        .task {
            viewModel.onTerminalOutput = { bytes in
                terminalBridge.feed(bytes)
            }

            if !viewModel.isConnected && !viewModel.isConnecting {
                await viewModel.connect()
            }
        }
        .onChange(of: viewModel.isConnected) { _, isConnected in
            if isConnected {
                terminalBridge.focus()
            }
        }
        .onDisappear {
            Task {
                await viewModel.disconnect()
            }
        }
    }

    private func color(for kind: TerminalLine.Kind) -> SwiftUI.Color {
        switch kind {
        case .remoteOutput:
            return .primary
        case .status:
            return .secondary
        case .error:
            return .red
        }
    }

    private func reconnectWithPendingPasswordHostIfNeeded() {
        guard let pendingReconnectHost else { return }
        self.pendingReconnectHost = nil
        terminalBridge.reset()
        Task {
            await viewModel.reconnect(with: pendingReconnectHost)
        }
    }
}

@MainActor
private final class RelayTerminalBridge {
    private weak var terminalView: RelayTerminalHostView?
    private var pendingOutput = [[UInt8]]()

    func attach(_ terminalView: RelayTerminalHostView) {
        self.terminalView = terminalView
        flushPendingOutput()
    }

    func detach(_ terminalView: RelayTerminalHostView) {
        guard self.terminalView === terminalView else { return }
        self.terminalView = nil
    }

    func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }

        if let terminalView {
            terminalView.feed(byteArray: ArraySlice(bytes))
        } else {
            pendingOutput.append(bytes)
        }
    }

    func focus() {
        terminalView?.becomeFirstResponder()
    }

    func reset() {
        pendingOutput.removeAll()
        terminalView?.feed(text: "\u{001B}c")
    }

    private func flushPendingOutput() {
        guard let terminalView, !pendingOutput.isEmpty else { return }
        for bytes in pendingOutput {
            terminalView.feed(byteArray: ArraySlice(bytes))
        }
        pendingOutput.removeAll()
    }
}

private struct SSHTerminalSurface: UIViewRepresentable {
    let bridge: RelayTerminalBridge
    let onSend: (ArraySlice<UInt8>) -> Void
    let onResize: (Int, Int) -> Void

    func makeUIView(context: Context) -> RelayTerminalHostView {
        let view = RelayTerminalHostView(frame: .zero)
        view.relayBridge = bridge
        view.configure(onSend: onSend, onResize: onResize)
        bridge.attach(view)
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: RelayTerminalHostView, context: Context) {
        uiView.relayBridge = bridge
        uiView.configure(onSend: onSend, onResize: onResize)
        bridge.attach(uiView)
    }

    static func dismantleUIView(_ uiView: RelayTerminalHostView, coordinator: ()) {
        uiView.relayBridge?.detach(uiView)
    }
}

private final class RelayTerminalHostView: SwiftTerm.TerminalView, TerminalViewDelegate {
    weak var relayBridge: RelayTerminalBridge?

    private var onSend: ((ArraySlice<UInt8>) -> Void)?
    private var onResize: ((Int, Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        nativeBackgroundColor = .black
        nativeForegroundColor = UIColor(red: 0.89, green: 0.95, blue: 0.90, alpha: 1.0)
        caretColor = .systemGreen
        optionAsMetaKey = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        onSend: @escaping (ArraySlice<UInt8>) -> Void,
        onResize: @escaping (Int, Int) -> Void
    ) {
        self.onSend = onSend
        self.onResize = onResize
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        onSend?(data)
    }

    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func bell(source: SwiftTerm.TerminalView) {}

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let string = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = string
        }
    }

    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}
