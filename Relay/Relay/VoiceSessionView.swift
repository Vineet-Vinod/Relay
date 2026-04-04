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
    @AppStorage(RelayDefaultsKey.voiceSpeechRate) private var voiceSpeechRate = RelayVoicePreference.defaultSpeechRate

    @State private var isPresentingAudioRoutes = false
    @State private var isPresentingVoiceSettings = false
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
        .sheet(isPresented: $isPresentingVoiceSettings) {
            VoiceSessionSettingsSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingAudioRoutes) {
            VoiceAudioRoutePickerSheet(
                routes: viewModel.availableAudioRoutes,
                selectedRoute: viewModel.selectedAudioRoute,
                onSelect: { route in
                    viewModel.selectAudioRoute(route)
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .task {
            updateIdleTimer()
            viewModel.updateSpeechRate(voiceSpeechRate)
            await viewModel.start()
        }
        .onChange(of: keepsScreenAwake) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: voiceSpeechRate) { _, newValue in
            viewModel.updateSpeechRate(newValue)
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

                HStack(spacing: RelayTheme.Spacing.tight) {
                    Button {
                        isPresentingVoiceSettings = true
                    } label: {
                        VStack(spacing: RelayTheme.Spacing.micro) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(palette.textColor)
                                .frame(width: 42, height: 42)
                                .background(
                                    Circle()
                                        .fill(palette.raisedColor.opacity(0.9))
                                )

                            Text(RelayVoicePreference.displaySpeedLabel(forSpeechRate: voiceSpeechRate))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(palette.mutedColor)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Voice settings")
                    .accessibilityValue("Speech rate \(RelayVoicePreference.displaySpeedLabel(forSpeechRate: voiceSpeechRate))")

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
        HStack(spacing: 6) {
            Image(systemName: statusSymbolName)
                .font(.caption2.weight(.semibold))

            Text(viewModel.status.title)
                .font(.caption2.weight(.semibold))
        }
            .foregroundStyle(palette.mutedColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(palette.surfaceColor.opacity(0.96))
            )
            .overlay(
                Capsule()
                    .stroke(palette.subtleColor.opacity(0.7), lineWidth: 1)
            )
    }

    private var statusSymbolName: String {
        switch viewModel.status {
        case .preparing:
            return "clock.fill"
        case .ready:
            return "checkmark.circle.fill"
        case .listening:
            return "mic.fill"
        case .processing:
            return "ellipsis.circle.fill"
        case .speaking:
            return "speaker.wave.2.fill"
        case .muted:
            return "mic.slash.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        case .ended:
            return "phone.down.fill"
        }
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

                    if viewModel.status == .listening || viewModel.isAwaitingSendCue {
                        Text(
                            viewModel.isAwaitingSendCue
                            ? "Say \"\(VoiceTurnEndCue.token)\" or tap Send."
                            : "Speak, then say \"\(VoiceTurnEndCue.token)\" or tap Send."
                        )
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
        VStack(spacing: 22) {
            Button {
                isPresentingAudioRoutes = true
            } label: {
                VoiceAudioRouteControl(
                    route: viewModel.selectedAudioRoute,
                    palette: palette
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Audio output")
            .accessibilityValue(viewModel.selectedAudioRoute.name)

            HStack(alignment: .top, spacing: RelayTheme.Spacing.section) {
                Button {
                    viewModel.toggleMute()
                } label: {
                    VoicePhoneControlButton(
                        title: viewModel.isMuted ? "Unmute" : "Mute",
                        subtitle: viewModel.isMuted ? "Microphone off" : nil,
                        systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                        palette: palette,
                        accentColor: palette.warningColor,
                        isActive: viewModel.isMuted,
                        isDisabled: false
                    )
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.fastForwardPlayback()
                } label: {
                    VoicePhoneControlButton(
                        title: "Skip",
                        subtitle: viewModel.canFastForward ? "Current reply" : "Unavailable",
                        systemImage: "forward.end.fill",
                        palette: palette,
                        accentColor: palette.accentColor,
                        isActive: false,
                        isDisabled: !viewModel.canFastForward
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canFastForward)
                .accessibilityLabel("Fast forward speech")

                Button {
                    viewModel.interrupt()
                } label: {
                    VoicePhoneControlButton(
                        title: "Interrupt",
                        subtitle: viewModel.canInterrupt ? "Stop speaking" : "Unavailable",
                        systemImage: "waveform.badge.xmark",
                        palette: palette,
                        accentColor: palette.accentColor,
                        isActive: false,
                        isDisabled: !viewModel.canInterrupt
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canInterrupt)
            }

            Button {
                dismiss()
            } label: {
                VStack(spacing: RelayTheme.Spacing.tight) {
                    Image(systemName: "phone.down.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 76, height: 76)
                        .background(
                            Circle()
                                .fill(palette.dangerColor)
                        )

                    Text("End")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textColor)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End voice session")
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(palette.surfaceColor.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(palette.subtleColor.opacity(0.75), lineWidth: 1)
        )
    }

    private func updateIdleTimer() {
        let shouldStayAwake = keepsScreenAwake && viewModel.status != .ended
        UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
    }
}

private struct VoiceSessionSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(RelayDefaultsKey.voiceSpeechRate) private var voiceSpeechRate = RelayVoicePreference.defaultSpeechRate

    var body: some View {
        let palette = RelayTerminalPalette.palette(for: colorScheme)

        ZStack {
            palette.backgroundColor
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.section) {
                HStack(alignment: .top, spacing: RelayTheme.Spacing.compact) {
                    VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                        Text("Voice Settings")
                            .font(.headline)
                            .foregroundStyle(palette.textColor)

                        Text("Adjust how quickly Codex speaks during the call.")
                            .font(.subheadline)
                            .foregroundStyle(palette.mutedColor)
                    }

                    Spacer(minLength: RelayTheme.Spacing.content)

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.accentColor)
                }

                VStack(alignment: .leading, spacing: RelayTheme.Spacing.content) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Speech Speed")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.textColor)

                        Spacer(minLength: RelayTheme.Spacing.content)

                        Text(RelayVoicePreference.displaySpeedLabel(forSpeechRate: voiceSpeechRate))
                            .font(TerminalFontRegistry.terminalSwiftUIFont(size: 13))
                            .foregroundStyle(palette.accentColor)
                    }

                    Slider(
                        value: speechSpeedBinding,
                        in: RelayVoicePreference.minimumDisplaySpeed...RelayVoicePreference.maximumDisplaySpeed,
                        step: RelayVoicePreference.displaySpeedStep
                    ) {
                        Text("Speech Speed")
                    } minimumValueLabel: {
                        Text("Slower")
                            .font(.caption)
                            .foregroundStyle(palette.mutedColor)
                    } maximumValueLabel: {
                        Text("Faster")
                            .font(.caption)
                            .foregroundStyle(palette.mutedColor)
                    }
                    .tint(palette.accentColor)

                    Text("Changes apply to queued and active speech while the call is in progress.")
                        .font(.footnote)
                        .foregroundStyle(palette.mutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .relayTerminalPanel(palette, padding: 18)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }

    private var speechSpeedBinding: Binding<Double> {
        Binding(
            get: { RelayVoicePreference.displaySpeed(forSpeechRate: voiceSpeechRate) },
            set: { voiceSpeechRate = RelayVoicePreference.speechRate(forDisplaySpeed: $0) }
        )
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
            HStack(spacing: 6) {
                Image(systemName: labelSymbolName)
                    .font(.caption2.weight(.semibold))

                Text(label)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(palette.mutedColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(palette.surfaceColor.opacity(0.96))
            )
            .overlay(
                Capsule()
                    .stroke(palette.subtleColor.opacity(0.7), lineWidth: 1)
            )

            Text(item.text)
                .font(font)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                .stroke(palette.subtleColor.opacity(0.65), lineWidth: 1)
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

    private var labelSymbolName: String {
        switch item.kind {
        case .user:
            return "person.fill"
        case .assistant:
            return "chevron.left.forwardslash.chevron.right"
        case .toolStatus:
            return "gearshape.fill"
        case .system:
            return "info.circle.fill"
        }
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
        palette.raisedColor
    }

    private var textColor: Color {
        palette.textColor
    }
}

private struct VoicePhoneControlButton: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let palette: RelayTerminalPalette
    let accentColor: Color
    let isActive: Bool
    let isDisabled: Bool

    var body: some View {
        VStack(spacing: RelayTheme.Spacing.compact) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 72, height: 72)
                .background(
                    Circle()
                        .fill(circleFillColor)
                )
                .overlay(
                    Circle()
                        .stroke(circleStrokeColor, lineWidth: 1)
                )

            VStack(spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(labelColor)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(palette.mutedColor)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var circleFillColor: Color {
        if isDisabled {
            return palette.raisedColor.opacity(0.45)
        }

        if isActive {
            return accentColor.opacity(0.2)
        }

        return palette.raisedColor.opacity(0.95)
    }

    private var circleStrokeColor: Color {
        if isActive {
            return accentColor.opacity(0.65)
        }

        return palette.subtleColor.opacity(0.85)
    }

    private var iconColor: Color {
        if isDisabled {
            return palette.mutedColor.opacity(0.55)
        }

        if isActive {
            return accentColor
        }

        return palette.textColor
    }

    private var labelColor: Color {
        isDisabled ? palette.mutedColor.opacity(0.7) : palette.textColor
    }
}

private struct VoiceAudioRouteControl: View {
    let route: VoiceAudioSessionCoordinator.AudioRouteOption
    let palette: RelayTerminalPalette

    var body: some View {
        HStack(spacing: RelayTheme.Spacing.compact) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.raisedColor)
                .frame(width: 54, height: 54)
                .overlay {
                    Image(systemName: route.systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(route.kind == .receiver ? palette.textColor : palette.accentColor)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.mutedColor)

                Text(route.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.textColor)

                Text(route.detail)
                    .font(.caption2)
                    .foregroundStyle(palette.mutedColor)
            }

            Spacer(minLength: RelayTheme.Spacing.content)

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.mutedColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.raisedColor.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.subtleColor.opacity(0.85), lineWidth: 1)
        )
    }
}

private struct VoiceAudioRoutePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let routes: [VoiceAudioSessionCoordinator.AudioRouteOption]
    let selectedRoute: VoiceAudioSessionCoordinator.AudioRouteOption
    let onSelect: (VoiceAudioSessionCoordinator.AudioRouteOption) -> Void

    var body: some View {
        let palette = RelayTerminalPalette.palette(for: colorScheme)

        ZStack {
            palette.backgroundColor
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: RelayTheme.Spacing.section) {
                HStack(alignment: .top, spacing: RelayTheme.Spacing.compact) {
                    VStack(alignment: .leading, spacing: RelayTheme.Spacing.micro) {
                        Text("Audio Output")
                            .font(.headline)
                            .foregroundStyle(palette.textColor)

                        Text("Choose where the call plays and which microphone Relay listens to.")
                            .font(.subheadline)
                            .foregroundStyle(palette.mutedColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: RelayTheme.Spacing.content)

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.accentColor)
                }

                VStack(spacing: RelayTheme.Spacing.compact) {
                    ForEach(routes) { route in
                        Button {
                            onSelect(route)
                            dismiss()
                        } label: {
                            HStack(spacing: RelayTheme.Spacing.compact) {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(palette.raisedColor)
                                    .frame(width: 46, height: 46)
                                    .overlay {
                                        Image(systemName: route.systemImage)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(route == selectedRoute ? palette.accentColor : palette.textColor)
                                    }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(route.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.textColor)

                                    Text(route.detail)
                                        .font(.caption)
                                        .foregroundStyle(palette.mutedColor)
                                }

                                Spacer(minLength: RelayTheme.Spacing.content)

                                Image(systemName: route == selectedRoute ? "checkmark.circle.fill" : "circle")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(route == selectedRoute ? palette.accentColor : palette.subtleColor)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                                    .fill(palette.surfaceColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                                    .stroke(
                                        route == selectedRoute ? palette.accentColor.opacity(0.65) : palette.subtleColor.opacity(0.8),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }
}
