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

    @AppStorage(RelayDefaultsKey.terminalFontSize) private var terminalFontSize = RelayTerminalFontSizePreference.defaultSize
    @AppStorage(RelayDefaultsKey.bellBehavior) private var bellBehavior = RelayBellBehavior.haptic.rawValue
    @AppStorage(RelayDefaultsKey.keepScreenAwake) private var keepsScreenAwake = true
    @AppStorage(RelayDefaultsKey.automaticallyReconnect) private var automaticallyReconnect = true

    let viewModel: TerminalSessionViewModel
    let isActive: Bool
    @State private var terminalBridge = RelayTerminalBridge()
    @State private var isShowingPasswordSheet = false
    @State private var isShowingVoiceWorkspacePicker = false
    @State private var pendingReconnectHost: Host?
    @State private var activeVoiceSession: VoiceSessionConfiguration?
    @State private var didAttemptConnection = false
    @State private var autoReconnectTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            palette.backgroundColor
                .ignoresSafeArea()

            SSHTerminalSurface(
                bridge: terminalBridge,
                palette: palette,
                fontSize: $terminalFontSize,
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
                    message: "The session is closed.",
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
        .toolbar {
            if isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if viewModel.canReconnectWithPassword {
                            Button("Use Password") {
                                isShowingPasswordSheet = true
                            }
                        }

                        if viewModel.supportsVoiceSession {
                            Button("Talk to Codex") {
                                isShowingVoiceWorkspacePicker = true
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
        }
        .alert(
            "Use an SSH key for future logins?",
            isPresented: savedKeyPromptBinding
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
            isPresented: hostTrustPromptBinding
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
        .sheet(isPresented: $isShowingVoiceWorkspacePicker) {
            if viewModel.supportsVoiceSession {
                VoiceWorkspacePickerView(
                    host: viewModel.host,
                    initialWorkspacePath: viewModel.host.defaultCodexPath ?? "",
                    supportsSavingDefault: false,
                    onCancel: {
                        isShowingVoiceWorkspacePicker = false
                    },
                    onStart: { workspacePath, _ in
                        var host = viewModel.host
                        let trimmedWorkspacePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
                        host.defaultCodexPath = trimmedWorkspacePath
                        isShowingVoiceWorkspacePicker = false
                        activeVoiceSession = VoiceSessionConfiguration(
                            host: host,
                            workspacePath: trimmedWorkspacePath
                        )
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .fullScreenCover(item: $activeVoiceSession) { configuration in
            VoiceSessionView(configuration: configuration)
        }
        .task {
            viewModel.onTerminalOutput = { bytes in
                terminalBridge.feed(bytes)
            }

            didAttemptConnection = true
            if isActive {
                updateIdleTimer()
            }
            if !viewModel.isConnected && !viewModel.isConnecting {
                await viewModel.connect()
            }
        }
        .onChange(of: viewModel.isConnected) { _, isConnected in
            if isActive {
                updateIdleTimer()
            }
            if isConnected {
                autoReconnectTask?.cancel()
                autoReconnectTask = nil
                if isActive {
                    terminalBridge.focus()
                }
            }
        }
        .onChange(of: viewModel.isConnecting) { _, _ in
            if isActive {
                updateIdleTimer()
            }
        }
        .onChange(of: keepsScreenAwake) { _, _ in
            if isActive {
                updateIdleTimer()
            }
        }
        .onChange(of: isActive) { _, isNowActive in
            updateIdleTimer()
            if isNowActive, viewModel.isConnected {
                terminalBridge.focus()
            }
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
            if isActive {
                UIApplication.shared.isIdleTimerDisabled = false
            }
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

    private var savedKeyPromptBinding: Binding<Bool> {
        Binding(
            get: { isActive && viewModel.isShowingKeySetupPrompt },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissSavedKeyPrompt()
                }
            }
        )
    }

    private var hostTrustPromptBinding: Binding<Bool> {
        Binding(
            get: { isActive && viewModel.isShowingHostTrustPrompt },
            set: { _ in }
        )
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
        UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake && isActive && (viewModel.isConnected || viewModel.isConnecting)
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
            terminalView.feedRelayOutput(byteArray: ArraySlice(bytes))
        } else {
            pendingOutput.append(bytes)
        }
    }

    func focus() {
        _ = terminalView?.becomeFirstResponder()
    }

    func reset() {
        pendingOutput.removeAll()
        terminalView?.feedRelayOutput(text: "\u{001B}c")
    }

    private func flushPendingOutput() {
        guard let terminalView, !pendingOutput.isEmpty else { return }
        for bytes in pendingOutput {
            terminalView.feedRelayOutput(byteArray: ArraySlice(bytes))
        }
        pendingOutput.removeAll()
    }
}

private struct SSHTerminalSurface: UIViewRepresentable {
    let bridge: RelayTerminalBridge
    let palette: RelayTerminalPalette
    @Binding var fontSize: Double
    let bellBehavior: RelayBellBehavior
    let onSend: (ArraySlice<UInt8>) -> Void
    let onResize: (Int, Int) -> Void

    func makeUIView(context: Context) -> RelayTerminalHostView {
        let fontSizeBinding = _fontSize
        let view = RelayTerminalHostView(frame: .zero)
        view.relayBridge = bridge
        view.configure(
            onSend: onSend,
            onResize: onResize,
            onFontSizeChange: { updatedFontSize in
                let clampedSize = RelayTerminalFontSizePreference.clamp(Double(updatedFontSize))
                guard abs(fontSizeBinding.wrappedValue - clampedSize) > 0.01 else { return }
                fontSizeBinding.wrappedValue = clampedSize
            }
        )
        view.applyPalette(palette)
        view.applyPreferences(fontSize: CGFloat(RelayTerminalFontSizePreference.clamp(fontSize)), bellBehavior: bellBehavior)
        bridge.attach(view)
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: RelayTerminalHostView, context: Context) {
        let fontSizeBinding = _fontSize
        uiView.relayBridge = bridge
        uiView.configure(
            onSend: onSend,
            onResize: onResize,
            onFontSizeChange: { updatedFontSize in
                let clampedSize = RelayTerminalFontSizePreference.clamp(Double(updatedFontSize))
                guard abs(fontSizeBinding.wrappedValue - clampedSize) > 0.01 else { return }
                fontSizeBinding.wrappedValue = clampedSize
            }
        )
        uiView.applyPalette(palette)
        uiView.applyPreferences(fontSize: CGFloat(RelayTerminalFontSizePreference.clamp(fontSize)), bellBehavior: bellBehavior)
        bridge.attach(uiView)
    }

    static func dismantleUIView(_ uiView: RelayTerminalHostView, coordinator: ()) {
        uiView.relayBridge?.detach(uiView)
    }
}

private struct RelayGitCommandTemplate: Identifiable {
    let id: String
    let title: String
    let command: String
    let trailingCursorLeftMoves: Int
    let symbolName: String

    static let all: [RelayGitCommandTemplate] = [
        RelayGitCommandTemplate(
            id: "status",
            title: "git status",
            command: "git status",
            trailingCursorLeftMoves: 0,
            symbolName: "list.bullet.rectangle"
        ),
        RelayGitCommandTemplate(
            id: "diff",
            title: "git diff",
            command: "git diff",
            trailingCursorLeftMoves: 0,
            symbolName: "doc.text.magnifyingglass"
        ),
        RelayGitCommandTemplate(
            id: "add-dot",
            title: "git add .",
            command: "git add .",
            trailingCursorLeftMoves: 0,
            symbolName: "plus.square.on.square"
        ),
        RelayGitCommandTemplate(
            id: "add-path",
            title: "git add ...",
            command: "git add ",
            trailingCursorLeftMoves: 0,
            symbolName: "plus.rectangle.on.folder"
        ),
        RelayGitCommandTemplate(
            id: "commit-message",
            title: "git commit -m \"\"",
            command: "git commit -m \"\"",
            trailingCursorLeftMoves: 1,
            symbolName: "text.quote"
        ),
        RelayGitCommandTemplate(
            id: "pull-rebase",
            title: "git pull --rebase",
            command: "git pull --rebase",
            trailingCursorLeftMoves: 0,
            symbolName: "arrow.down.circle"
        ),
        RelayGitCommandTemplate(
            id: "push",
            title: "git push",
            command: "git push",
            trailingCursorLeftMoves: 0,
            symbolName: "arrow.up.circle"
        ),
        RelayGitCommandTemplate(
            id: "switch",
            title: "git switch ...",
            command: "git switch ",
            trailingCursorLeftMoves: 0,
            symbolName: "arrow.triangle.branch"
        ),
        RelayGitCommandTemplate(
            id: "switch-create",
            title: "git switch -c ...",
            command: "git switch -c ",
            trailingCursorLeftMoves: 0,
            symbolName: "arrow.triangle.branch"
        ),
        RelayGitCommandTemplate(
            id: "log",
            title: "git log --oneline --graph --decorate -20",
            command: "git log --oneline --graph --decorate -20",
            trailingCursorLeftMoves: 0,
            symbolName: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        ),
    ]
}

private enum RelayTerminalAccessoryAction: CaseIterable {
    case tab
    case escape
    case control
    case git

    var title: String {
        switch self {
        case .tab:
            return "Tab"
        case .escape:
            return "Esc"
        case .control:
            return "Ctrl"
        case .git:
            return "Git"
        }
    }
}

private final class RelayTerminalAccessoryButton: UIButton {
    let action: RelayTerminalAccessoryAction

    init(action: RelayTerminalAccessoryAction) {
        self.action = action
        super.init(frame: .zero)

        var configuration = UIButton.Configuration.plain()
        configuration.title = action.title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 12

        self.configuration = configuration
        titleLabel?.font = TerminalFontRegistry.terminalFont(size: 13, bold: true)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.82
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth(for: action)).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyPalette(_ palette: RelayTerminalPalette, isSelected: Bool) {
        let background = isSelected ? palette.accent.withAlphaComponent(0.18) : palette.raised
        let border = isSelected ? palette.accent.withAlphaComponent(0.72) : palette.subtle.withAlphaComponent(0.82)

        var configuration = configuration ?? UIButton.Configuration.plain()
        var backgroundConfiguration = configuration.background
        configuration.baseForegroundColor = isSelected ? palette.accent : palette.text
        backgroundConfiguration.backgroundColor = background
        backgroundConfiguration.strokeColor = border
        backgroundConfiguration.strokeWidth = 1
        configuration.background = backgroundConfiguration
        self.configuration = configuration
    }

    private func minimumWidth(for action: RelayTerminalAccessoryAction) -> CGFloat {
        switch action {
        case .git:
            return 68
        default:
            return 54
        }
    }
}

private final class RelayTerminalAccessoryView: UIInputView, UIInputViewAudioFeedback {
    weak var terminalView: RelayTerminalHostView?

    private let borderView = UIView()
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var buttons: [RelayTerminalAccessoryAction: RelayTerminalAccessoryButton] = [:]
    private var controlResetObserver: NSObjectProtocol?

    init(terminalView: RelayTerminalHostView) {
        self.terminalView = terminalView
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 56), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        setupUI()
        observeControlReset()
        applyPalette(RelayTerminalPalette.palette(for: traitCollection))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let controlResetObserver {
            NotificationCenter.default.removeObserver(controlResetObserver)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 56)
    }

    var enableInputClicksWhenVisible: Bool { true }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else {
            return
        }

        applyPalette(RelayTerminalPalette.palette(for: traitCollection))
    }

    func applyPalette(_ palette: RelayTerminalPalette) {
        backgroundColor = palette.surface
        borderView.backgroundColor = palette.subtle.withAlphaComponent(0.9)

        for (action, button) in buttons {
            let isSelected = action == .control && (terminalView?.controlModifier ?? false)
            button.applyPalette(palette, isSelected: isSelected)
        }

        scrollView.indicatorStyle = traitCollection.userInterfaceStyle == .dark ? .white : .black
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        autoresizingMask = .flexibleHeight

        borderView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(borderView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = RelayTheme.Spacing.tight
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            borderView.topAnchor.constraint(equalTo: topAnchor),
            borderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            borderView.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: RelayTheme.Spacing.tight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -RelayTheme.Spacing.micro),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: RelayTheme.Spacing.compact),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -RelayTheme.Spacing.compact),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        RelayTerminalAccessoryAction.allCases.forEach { action in
            let button = RelayTerminalAccessoryButton(action: action)
            buttons[action] = button
            stackView.addArrangedSubview(button)

            if action == .git {
                button.showsMenuAsPrimaryAction = true
                button.menu = makeGitMenu()
            } else {
                button.addTarget(self, action: #selector(handleButtonTap(_:)), for: .touchUpInside)
            }
        }
    }

    private func observeControlReset() {
        guard let terminalView else { return }

        controlResetObserver = NotificationCenter.default.addObserver(
            forName: .terminalViewControlModifierReset,
            object: terminalView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyPalette(RelayTerminalPalette.palette(for: self.traitCollection))
        }
    }

    private func makeGitMenu() -> UIMenu {
        UIMenu(
            title: "Git Commands",
            children: RelayGitCommandTemplate.all.map { template in
                UIAction(
                    title: template.title,
                    image: UIImage(systemName: template.symbolName)
                ) { [weak self] _ in
                    guard let self, let terminalView else { return }

                    #if os(iOS)
                    UIDevice.current.playInputClick()
                    #endif

                    _ = terminalView.becomeFirstResponder()
                    terminalView.insertCommandTemplate(template)
                    self.applyPalette(RelayTerminalPalette.palette(for: self.traitCollection))
                }
            }
        )
    }

    @objc
    private func handleButtonTap(_ sender: RelayTerminalAccessoryButton) {
        perform(action: sender.action)
    }

    private func perform(action: RelayTerminalAccessoryAction) {
        guard let terminalView else { return }

        #if os(iOS)
        UIDevice.current.playInputClick()
        #endif

        _ = terminalView.becomeFirstResponder()

        switch action {
        case .tab:
            terminalView.sendAccessoryBytes([0x09])
        case .escape:
            terminalView.sendAccessoryBytes([0x1B])
        case .control:
            terminalView.controlModifier.toggle()
        case .git:
            break
        }

        applyPalette(RelayTerminalPalette.palette(for: traitCollection))
    }
}

private final class RelayTerminalHostView: SwiftTerm.TerminalView, TerminalViewDelegate, UIGestureRecognizerDelegate {
    weak var relayBridge: RelayTerminalBridge?

    private var onSend: ((ArraySlice<UInt8>) -> Void)?
    private var onResize: ((Int, Int) -> Void)?
    private var onFontSizeChange: ((CGFloat) -> Void)?
    private var configuredFontSize: CGFloat?
    private var bellBehavior: RelayBellBehavior = .haptic
    private weak var relayAccessoryView: RelayTerminalAccessoryView?
    private var pinchBaseFontSize: CGFloat?
    private lazy var relayPinchGestureRecognizer: UIPinchGestureRecognizer = {
        let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchZoom(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        applyPreferences(fontSize: CGFloat(RelayTerminalFontSizePreference.defaultSize), bellBehavior: .haptic)
        optionAsMetaKey = false
        configureKeyboardTraits()
        installRelayAccessory()
        addGestureRecognizer(relayPinchGestureRecognizer)
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
        onResize: @escaping (Int, Int) -> Void,
        onFontSizeChange: ((CGFloat) -> Void)? = nil
    ) {
        self.onSend = onSend
        self.onResize = onResize
        self.onFontSizeChange = onFontSizeChange
    }

    func applyPreferences(fontSize: CGFloat, bellBehavior: RelayBellBehavior) {
        self.bellBehavior = bellBehavior

        let clampedFontSize = RelayTerminalFontSizePreference.clamp(fontSize)
        guard configuredFontSize != clampedFontSize else { return }

        let preservedScrollPosition = scrollPosition
        configuredFontSize = clampedFontSize
        setFonts(
            normal: TerminalFontRegistry.terminalFont(size: clampedFontSize, bold: false),
            bold: TerminalFontRegistry.terminalFont(size: clampedFontSize, bold: true),
            italic: TerminalFontRegistry.terminalFont(size: clampedFontSize, bold: false),
            boldItalic: TerminalFontRegistry.terminalFont(size: clampedFontSize, bold: true)
        )
        setNeedsLayout()
        layoutIfNeeded()
        scroll(toPosition: preservedScrollPosition)
        setNeedsDisplay()
    }

    func feedRelayOutput(byteArray: ArraySlice<UInt8>) {
        let preservedScrollPosition = scrollPosition
        feed(byteArray: byteArray)
        scroll(toPosition: preservedScrollPosition)
    }

    func feedRelayOutput(text: String) {
        let preservedScrollPosition = scrollPosition
        feed(text: text)
        scroll(toPosition: preservedScrollPosition)
    }

    func applyPalette(_ palette: RelayTerminalPalette) {
        nativeBackgroundColor = palette.background
        nativeForegroundColor = palette.text
        caretColor = palette.accent
        backgroundColor = palette.background
        tintColor = palette.accent
        relayAccessoryView?.applyPalette(palette)
        setNeedsDisplay()
    }

    func sendAccessoryBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        controlModifier = false
        send(bytes)
    }

    func insertCommandTemplate(_ template: RelayGitCommandTemplate) {
        sendAccessoryBytes(Array(template.command.utf8))

        if template.trailingCursorLeftMoves > 0 {
            let moveLeft = Array("\u{001B}[D".utf8)
            for _ in 0..<template.trailingCursorLeftMoves {
                sendAccessoryBytes(moveLeft)
            }
        }
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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === relayPinchGestureRecognizer
    }

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

    private func installRelayAccessory() {
        let accessoryView = RelayTerminalAccessoryView(terminalView: self)
        relayAccessoryView = accessoryView
        inputAccessoryView = accessoryView
    }

    @objc
    private func handlePinchZoom(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchBaseFontSize = configuredFontSize ?? CGFloat(RelayTerminalFontSizePreference.defaultSize)
            _ = becomeFirstResponder()
        case .changed:
            guard let pinchBaseFontSize else { return }
            updateZoomFontSize(to: pinchBaseFontSize * recognizer.scale)
        case .ended, .cancelled, .failed:
            if let pinchBaseFontSize {
                updateZoomFontSize(to: pinchBaseFontSize * recognizer.scale)
            }
            pinchBaseFontSize = nil
        default:
            break
        }
    }

    private func configureKeyboardTraits() {
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        autocapitalizationType = .none
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    private func updateZoomFontSize(to proposedSize: CGFloat) {
        let clampedSize = RelayTerminalFontSizePreference.clamp(proposedSize)
        guard abs((configuredFontSize ?? 0) - clampedSize) > 0.01 else { return }

        applyPreferences(fontSize: clampedSize, bellBehavior: bellBehavior)
        onFontSizeChange?(clampedSize)
    }

}
