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
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(RelayDefaultsKey.terminalFontSize) private var terminalFontSize = 14.0
    @AppStorage(RelayDefaultsKey.bellBehavior) private var bellBehavior = RelayBellBehavior.haptic.rawValue
    @AppStorage(RelayDefaultsKey.keepScreenAwake) private var keepsScreenAwake = true
    @AppStorage(RelayDefaultsKey.automaticallyReconnect) private var automaticallyReconnect = true

    @State var viewModel: TerminalSessionViewModel
    @State private var terminalBridge = RelayTerminalBridge()
    @State private var isShowingPasswordSheet = false
    @State private var pendingReconnectHost: Host?
    @State private var didAttemptConnection = false
    @State private var autoReconnectTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            palette.backgroundColor
                .ignoresSafeArea()

            SSHTerminalSurface(
                bridge: terminalBridge,
                palette: palette,
                fontSize: CGFloat(terminalFontSize),
                bellBehavior: resolvedBellBehavior,
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

            if viewModel.isProvisioningSavedKey {
                TerminalProgressOverlay(
                    palette: palette,
                    title: "Installing saved SSH key"
                )
                .padding(.horizontal, RelayTheme.Spacing.content)
                .padding(.top, RelayTheme.Spacing.compact)
            } else if viewModel.isConnecting {
                TerminalProgressOverlay(
                    palette: palette,
                    title: "Connecting"
                )
                .padding(.horizontal, RelayTheme.Spacing.content)
                .padding(.top, RelayTheme.Spacing.compact)
            } else if let latestErrorMessage = viewModel.latestErrorMessage,
                      !viewModel.isShowingHostTrustPrompt {
                TerminalRecoveryOverlay(
                    palette: palette,
                    title: recoveryTitle,
                    message: latestErrorMessage,
                    primaryActionTitle: viewModel.isConnected ? "Dismiss" : "Reconnect",
                    primaryActionTint: viewModel.isConnected ? palette.textColor : palette.accentColor,
                    primaryAction: handlePrimaryRecoveryAction,
                    secondaryActionTitle: viewModel.canReconnectWithPassword ? "Use Password" : nil,
                    secondaryActionTint: palette.textColor,
                    secondaryAction: viewModel.canReconnectWithPassword ? { isShowingPasswordSheet = true } : nil
                )
                .padding(.horizontal, RelayTheme.Spacing.content)
                .padding(.top, RelayTheme.Spacing.compact)
            } else if shouldShowDisconnectedOverlay {
                TerminalRecoveryOverlay(
                    palette: palette,
                    title: "Disconnected",
                    message: "The SSH session is closed.",
                    primaryActionTitle: "Reconnect",
                    primaryActionTint: palette.accentColor,
                    primaryAction: reconnectTerminal,
                    secondaryActionTitle: nil,
                    secondaryActionTint: nil,
                    secondaryAction: nil
                )
                .padding(.horizontal, RelayTheme.Spacing.content)
                .padding(.top, RelayTheme.Spacing.compact)
            }
        }
        .navigationTitle(viewModel.host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.surfaceColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if viewModel.canReconnectWithPassword {
                        Button("Use Password") {
                            isShowingPasswordSheet = true
                        }
                    }

                    if viewModel.isConnecting || viewModel.isConnected {
                        Button(viewModel.isConnecting ? "Cancel Connection" : "Disconnect", role: .destructive) {
                            Task {
                                await viewModel.disconnect()
                            }
                        }
                    } else {
                        Button("Reconnect") {
                            reconnectTerminal()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(palette.textColor)
                }
            }
        }
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

            didAttemptConnection = true
            updateIdleTimer()
            if !viewModel.isConnected && !viewModel.isConnecting {
                await viewModel.connect()
            }
        }
        .onChange(of: viewModel.isConnected) { _, isConnected in
            updateIdleTimer()
            if isConnected {
                autoReconnectTask?.cancel()
                autoReconnectTask = nil
                terminalBridge.focus()
            }
        }
        .onChange(of: viewModel.isConnecting) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: keepsScreenAwake) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: viewModel.didDisconnectUnexpectedly) { _, didDisconnectUnexpectedly in
            guard didDisconnectUnexpectedly,
                  automaticallyReconnect,
                  viewModel.latestErrorMessage == nil,
                  !viewModel.isShowingHostTrustPrompt else {
                return
            }

            scheduleAutoReconnect()
        }
        .onDisappear {
            autoReconnectTask?.cancel()
            autoReconnectTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
            Task {
                await viewModel.disconnect()
            }
        }
    }

    private var palette: RelayTerminalPalette {
        RelayTerminalPalette.palette(for: colorScheme)
    }

    private var resolvedBellBehavior: RelayBellBehavior {
        RelayBellBehavior(rawValue: bellBehavior) ?? .haptic
    }

    private var recoveryTitle: String {
        if viewModel.canReconnectWithPassword {
            return "Couldn't connect with saved SSH key"
        }

        if viewModel.isConnected {
            return "Session error"
        }

        return "Connection failed"
    }

    private var shouldShowDisconnectedOverlay: Bool {
        didAttemptConnection &&
        !viewModel.isConnected &&
        !viewModel.isConnecting &&
        viewModel.latestErrorMessage == nil &&
        !viewModel.isShowingHostTrustPrompt
    }

    private func handlePrimaryRecoveryAction() {
        if viewModel.isConnected {
            viewModel.dismissLatestError()
            return
        }

        reconnectTerminal()
    }

    private func reconnectTerminal() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        terminalBridge.reset()
        viewModel.dismissLatestError()
        Task {
            await viewModel.connect()
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

    private func scheduleAutoReconnect() {
        guard autoReconnectTask == nil else { return }

        autoReconnectTask = Task {
            try? await Task.sleep(for: .seconds(1.25))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                terminalBridge.reset()
                viewModel.dismissLatestError()
            }
            await viewModel.connect()
            await MainActor.run {
                autoReconnectTask = nil
            }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake && (viewModel.isConnected || viewModel.isConnecting)
    }
}

private struct TerminalProgressOverlay: View {
    let palette: RelayTerminalPalette
    let title: String

    var body: some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            ProgressView()
                .tint(palette.textColor)

            Text(title)
                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 12, bold: true))
                .foregroundStyle(palette.textColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayTerminalPanel(palette, padding: 12)
    }
}

private struct TerminalRecoveryOverlay: View {
    let palette: RelayTerminalPalette
    let title: String
    let message: String
    let primaryActionTitle: String
    let primaryActionTint: SwiftUI.Color
    let primaryAction: () -> Void
    let secondaryActionTitle: String?
    let secondaryActionTint: SwiftUI.Color?
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.compact) {
            Text(title)
                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 14, bold: true))
                .foregroundStyle(palette.textColor)

            Text(message)
                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 13))
                .foregroundStyle(palette.mutedColor)
                .textSelection(.enabled)

            HStack(spacing: RelayTheme.Spacing.compact) {
                Button(primaryActionTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .tint(primaryActionTint)

                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle, action: secondaryAction)
                        .buttonStyle(.bordered)
                        .tint(secondaryActionTint ?? palette.textColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayTerminalPanel(palette)
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
    let palette: RelayTerminalPalette
    let fontSize: CGFloat
    let bellBehavior: RelayBellBehavior
    let onSend: (ArraySlice<UInt8>) -> Void
    let onResize: (Int, Int) -> Void

    func makeUIView(context: Context) -> RelayTerminalHostView {
        let view = RelayTerminalHostView(frame: .zero)
        view.relayBridge = bridge
        view.configure(onSend: onSend, onResize: onResize)
        view.applyPalette(palette)
        view.applyPreferences(fontSize: fontSize, bellBehavior: bellBehavior)
        bridge.attach(view)
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: RelayTerminalHostView, context: Context) {
        uiView.relayBridge = bridge
        uiView.configure(onSend: onSend, onResize: onResize)
        uiView.applyPalette(palette)
        uiView.applyPreferences(fontSize: fontSize, bellBehavior: bellBehavior)
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
    private var configuredFontSize: CGFloat?
    private var bellBehavior: RelayBellBehavior = .haptic

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        applyPreferences(fontSize: 14, bellBehavior: .haptic)
        optionAsMetaKey = false
        applyPalette(RelayTerminalPalette.palette(for: traitCollection))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else {
            return
        }

        applyPalette(RelayTerminalPalette.palette(for: traitCollection))
    }

    func configure(
        onSend: @escaping (ArraySlice<UInt8>) -> Void,
        onResize: @escaping (Int, Int) -> Void
    ) {
        self.onSend = onSend
        self.onResize = onResize
    }

    func applyPreferences(fontSize: CGFloat, bellBehavior: RelayBellBehavior) {
        self.bellBehavior = bellBehavior

        guard configuredFontSize != fontSize else { return }
        configuredFontSize = fontSize
        setFonts(
            normal: TerminalFontRegistry.terminalFont(size: fontSize, bold: false),
            bold: TerminalFontRegistry.terminalFont(size: fontSize, bold: true),
            italic: TerminalFontRegistry.terminalFont(size: fontSize, bold: false),
            boldItalic: TerminalFontRegistry.terminalFont(size: fontSize, bold: true)
        )
        setNeedsLayout()
        setNeedsDisplay()
    }

    func applyPalette(_ palette: RelayTerminalPalette) {
        nativeBackgroundColor = palette.background
        nativeForegroundColor = palette.text
        caretColor = palette.accent
        backgroundColor = palette.background
        tintColor = palette.accent
        setNeedsDisplay()
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

    func bell(source: SwiftTerm.TerminalView) {
        switch bellBehavior {
        case .off:
            return
        case .haptic:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        case .visual:
            flashBell()
        }
    }

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let string = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = string
        }
    }

    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    private func flashBell() {
        let overlay = UIView(frame: bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.18)
        overlay.isUserInteractionEnabled = false
        overlay.alpha = 0
        addSubview(overlay)

        UIView.animate(withDuration: 0.12, animations: {
            overlay.alpha = 1
        }, completion: { _ in
            UIView.animate(withDuration: 0.18, animations: {
                overlay.alpha = 0
            }, completion: { _ in
                overlay.removeFromSuperview()
            })
        })
    }
}
