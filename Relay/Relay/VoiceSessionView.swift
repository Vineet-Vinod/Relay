//
//  VoiceSessionView.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import SwiftUI
import UIKit

struct VoiceSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(RelayDefaultsKey.keepScreenAwake) private var keepsScreenAwake = true

    @State private var viewModel: VoiceSessionViewModel

    init(configuration: VoiceSessionConfiguration) {
        _viewModel = State(initialValue: VoiceSessionViewModel(configuration: configuration))
    }

    var body: some View {
        let palette = RelayTerminalPalette.palette(for: colorScheme)

        ZStack {
            LinearGradient(
                colors: [
                    palette.backgroundColor,
                    palette.surfaceColor.opacity(0.94),
                    palette.backgroundColor,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: RelayTheme.Spacing.section) {
                header(palette: palette)

                transcriptPanel(palette: palette)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                composerPanel(palette: palette)

                controls(palette: palette)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .task {
            updateIdleTimer()
            await viewModel.start()
        }
        .onChange(of: keepsScreenAwake) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: viewModel.status) { _, _ in
            updateIdleTimer()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task {
                await viewModel.end()
            }
        }
    }

    private func header(palette: RelayTerminalPalette) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.compact) {
            HStack(alignment: .top, spacing: RelayTheme.Spacing.compact) {
                VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                    Text(viewModel.configuration.host.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(palette.textColor)

                    Text(viewModel.configuration.host.hostname)
                        .font(TerminalFontRegistry.terminalSwiftUIFont(size: 13))
                        .foregroundStyle(palette.mutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: RelayTheme.Spacing.content)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(palette.textColor)
                        .frame(width: 42, height: 42)
                        .background(
                            Circle()
                                .fill(palette.raisedColor.opacity(0.9))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End voice session")
            }

            HStack(spacing: RelayTheme.Spacing.tight) {
                statusBadge(palette: palette)

                Text(viewModel.resolvedWorkspacePath)
                    .font(TerminalFontRegistry.terminalSwiftUIFont(size: 12))
                    .foregroundStyle(palette.mutedColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .relayTerminalPanel(palette, padding: 18)
    }

    private func statusBadge(palette: RelayTerminalPalette) -> some View {
        let tint: Color = switch viewModel.status {
        case .listening:
            palette.successColor
        case .processing, .speaking:
            palette.accentColor
        case .muted:
            palette.warningColor
        case .failed:
            palette.dangerColor
        case .ended:
            palette.mutedColor
        case .preparing, .ready:
            palette.textColor
        }

        return Text(viewModel.status.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
    }

    private func transcriptPanel(palette: RelayTerminalPalette) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: RelayTheme.Spacing.compact) {
                    ForEach(viewModel.transcript) { item in
                        VoiceTranscriptRow(item: item, palette: palette)
                            .id(item.id)
                    }
                }
                .padding(16)
            }
            .relayTerminalPanel(palette, padding: 0)
            .onChange(of: viewModel.transcript.count) { _, _ in
                guard let lastID = viewModel.transcript.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private func composerPanel(palette: RelayTerminalPalette) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
            HStack(alignment: .center, spacing: RelayTheme.Spacing.compact) {
                VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                    Text("Live Transcript")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.mutedColor)

                    if viewModel.status == .listening || viewModel.isAwaitingTurnCompletion {
                        Text(viewModel.isAwaitingTurnCompletion ? "Relay will send after a short pause." : "Speak naturally, then pause or tap Send.")
                            .font(.caption2)
                            .foregroundStyle(palette.mutedColor)
                    }
                }

                Spacer(minLength: RelayTheme.Spacing.content)

                Button {
                    viewModel.finishCurrentTurn()
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accentColor)
                .disabled(!viewModel.canSendCurrentTurn)
            }

            Text(viewModel.draftUserSpeech.isEmpty ? draftPlaceholder : viewModel.draftUserSpeech)
                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 16))
                .foregroundStyle(viewModel.draftUserSpeech.isEmpty ? palette.mutedColor : palette.textColor)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        }
        .relayTerminalFieldBackground(palette, isFocused: viewModel.status == .listening)
    }

    private var draftPlaceholder: String {
        switch viewModel.status {
        case .listening:
            return "Listening for your next turn..."
        case .muted:
            return "Microphone is muted."
        case .processing:
            return "Sending your turn to Codex..."
        case .speaking:
            return "Codex is responding..."
        case .preparing:
            return "Preparing the remote bridge..."
        case .ready:
            return "Ready."
        case .ended:
            return "Session ended."
        case .failed(let message):
            return message
        }
    }

    private func controls(palette: RelayTerminalPalette) -> some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            Button {
                viewModel.toggleMute()
            } label: {
                VoiceControlLabel(
                    title: viewModel.isMuted ? "Unmute" : "Mute",
                    systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                    tint: viewModel.isMuted ? palette.warningColor : palette.textColor
                )
            }
            .buttonStyle(.plain)

            Button {
                viewModel.interrupt()
            } label: {
                VoiceControlLabel(
                    title: "Interrupt",
                    systemImage: "waveform.badge.xmark",
                    tint: viewModel.canInterrupt ? palette.accentColor : palette.mutedColor
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canInterrupt)

            Button {
                dismiss()
            } label: {
                VoiceControlLabel(
                    title: "End",
                    systemImage: "phone.down.fill",
                    tint: palette.dangerColor
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func updateIdleTimer() {
        let shouldStayAwake = keepsScreenAwake && viewModel.status != .ended
        UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
    }
}

struct VoiceWorkspacePickerView: View {
    let host: Host
    let supportsSavingDefault: Bool
    let onCancel: () -> Void
    let onStart: (String, Bool) -> Void

    @State private var workspacePath: String
    @State private var saveAsDefault: Bool
    @FocusState private var isWorkspaceFocused: Bool

    init(
        host: Host,
        initialWorkspacePath: String,
        supportsSavingDefault: Bool,
        onCancel: @escaping () -> Void,
        onStart: @escaping (String, Bool) -> Void
    ) {
        self.host = host
        self.supportsSavingDefault = supportsSavingDefault
        self.onCancel = onCancel
        self.onStart = onStart
        _workspacePath = State(initialValue: initialWorkspacePath)
        _saveAsDefault = State(initialValue: supportsSavingDefault && !initialWorkspacePath.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RelayTheme.Spacing.section) {
                    introCard
                    workspaceCard
                    if supportsSavingDefault {
                        defaultCard
                    }
                }
                .padding(20)
                .padding(.bottom, 120)
            }
            .background(RelayTheme.surfaceBase.ignoresSafeArea())
            .navigationTitle("Codex Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isWorkspaceFocused = workspacePath.isEmpty
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: RelayTheme.Spacing.tight) {
                    Button("Start Voice Session") {
                        onStart(trimmedWorkspacePath, saveAsDefault && supportsSavingDefault)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RelayTheme.accent)
                    .disabled(trimmedWorkspacePath.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .background(Color(uiColor: .systemBackground))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(RelayTheme.surfaceStroke)
                        .frame(height: 1)
                }
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.compact) {
            Text("Talk to Codex on \(host.name)")
                .font(.title3.weight(.semibold))

            Text("Choose the directory Codex should operate in before Relay opens the voice session.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .relayAppCard()
    }

    private var workspaceCard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.content) {
            Text("Workspace")
                .font(.headline)

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
                Text("Remote Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("~/Projects/Relay", text: $workspacePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(TerminalFontRegistry.terminalSwiftUIFont(size: 16))
                    .focused($isWorkspaceFocused)
                    .submitLabel(.go)
                    .onSubmit {
                        guard !trimmedWorkspacePath.isEmpty else { return }
                        onStart(trimmedWorkspacePath, saveAsDefault && supportsSavingDefault)
                    }
                    .relayAppFieldBackground(isFocused: isWorkspaceFocused, isTechnical: true)
            }

            Text("Relay validates this directory on the remote host before starting the Codex voice session.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .relayAppCard()
    }

    private var defaultCard: some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
            Toggle("Save as this device's default Codex workspace", isOn: $saveAsDefault)
        }
        .relayAppCard()
    }

    private var trimmedWorkspacePath: String {
        workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct VoiceTranscriptRow: View {
    let item: VoiceTranscriptItem
    let palette: RelayTerminalPalette

    var body: some View {
        VStack(alignment: alignment, spacing: RelayTheme.Spacing.tight) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(labelColor)

            Text(item.text)
                .font(font)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                .fill(backgroundColor)
        )
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .padding(.leading, alignment == .trailing ? 44 : 0)
        .padding(.trailing, alignment == .leading ? 44 : 0)
    }

    private var label: String {
        switch item.kind {
        case .user:
            return "You"
        case .assistant:
            return "Codex"
        case .toolStatus:
            return "Relay"
        case .system:
            return "System"
        }
    }

    private var alignment: HorizontalAlignment {
        item.kind == .user ? .trailing : .leading
    }

    private var font: Font {
        switch item.kind {
        case .assistant, .toolStatus, .system:
            return TerminalFontRegistry.terminalSwiftUIFont(size: 14)
        case .user:
            return .body
        }
    }

    private var backgroundColor: Color {
        switch item.kind {
        case .user:
            return palette.accentColor.opacity(0.14)
        case .assistant:
            return palette.raisedColor
        case .toolStatus:
            return palette.warningColor.opacity(0.12)
        case .system:
            return palette.dangerColor.opacity(0.10)
        }
    }

    private var textColor: Color {
        switch item.kind {
        case .user:
            return palette.textColor
        case .assistant:
            return palette.textColor
        case .toolStatus:
            return palette.textColor
        case .system:
            return palette.textColor
        }
    }

    private var labelColor: Color {
        switch item.kind {
        case .user:
            return palette.accentColor
        case .assistant:
            return palette.mutedColor
        case .toolStatus:
            return palette.warningColor
        case .system:
            return palette.dangerColor
        }
    }
}

private struct VoiceControlLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: RelayTheme.Spacing.tight) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 58, height: 58)
                .background(
                    Circle()
                        .fill(tint.opacity(0.12))
                )

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
