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
    @FocusState private var isPromptFieldFocused: Bool

    init(configuration: VoiceSessionConfiguration) {
        _viewModel = State(initialValue: VoiceSessionViewModel(configuration: configuration))
    }

    var body: some View {
        let palette = RelayTerminalPalette.palette(for: colorScheme)

        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                palette.backgroundColor
                    .ignoresSafeArea()

                chatSurface(palette: palette)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                topRightSettingsButton(palette: palette)
                    .padding(.top, 18)
                    .padding(.trailing, 18)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls(palette: palette)
                    .frame(height: bottomTrayHeight(for: geometry.size.height))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .background(palette.backgroundColor.opacity(0.96))
            }
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
        .onChange(of: isPromptFieldFocused) { _, isFocused in
            if isFocused {
                viewModel.beginManualEntry()
            } else {
                viewModel.endManualEntry()
            }
        }
        .onChange(of: viewModel.status) { _, _ in
            updateIdleTimer()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()

                Button("Done") {
                    isPromptFieldFocused = false
                }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task {
                await viewModel.end()
            }
        }
    }

    private func topRightSettingsButton(palette: RelayTerminalPalette) -> some View {
        Button {
            isPresentingVoiceSettings = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.textColor)
                .frame(width: 46, height: 46)
                .background(
                    Circle()
                        .fill(palette.surfaceColor.opacity(0.96))
                )
                .overlay(
                    Circle()
                        .stroke(palette.subtleColor.opacity(0.8), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice settings")
        .accessibilityValue("Speech rate \(RelayVoicePreference.displaySpeedLabel(forSpeechRate: voiceSpeechRate))")
    }

    private func chatSurface(palette: RelayTerminalPalette) -> some View {
        VStack(spacing: RelayTheme.Spacing.compact) {
            transcriptPanel(palette: palette)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            composerPanel(palette: palette)
                .padding(.horizontal, 18)
        }
    }

    private func transcriptPanel(palette: RelayTerminalPalette) -> some View {
        let bottomAnchorID = "voice-transcript-bottom"

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: RelayTheme.Spacing.tight) {
                    ForEach(viewModel.transcript) { item in
                        VoiceTranscriptRow(item: item, palette: palette)
                            .id(item.id)
                    }

                    if viewModel.showsConversationActivity {
                        VoiceTranscriptActivityRow(palette: palette)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.transcript.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.transcript.last?.text ?? "") { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.showsConversationActivity) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isPromptFieldFocused else { return }
                isPromptFieldFocused = false
            }
        }
    }

    private func composerPanel(palette: RelayTerminalPalette) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.Spacing.tight) {
            HStack(alignment: .top, spacing: RelayTheme.Spacing.tight) {
                Text(">")
                    .font(TerminalFontRegistry.terminalSwiftUIFont(size: 15, bold: true))
                    .foregroundStyle(isPromptFieldFocused || viewModel.status == .listening ? palette.accentColor : palette.mutedColor)
                    .padding(.top, 3)

                Spacer(minLength: 0)

                promptStatusChip(palette: palette)
            }

            TextField("Speak or type a prompt", text: promptDraftBinding, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isPromptFieldFocused)
                .submitLabel(.send)
                .lineLimit(1...6)
                .onSubmit {
                    guard viewModel.canSendCurrentTurn else { return }
                    viewModel.finishCurrentTurn()
                    isPromptFieldFocused = false
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(promptHint)
                .font(.caption2)
                .foregroundStyle(palette.mutedColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .relayTerminalFieldBackground(palette, isFocused: isPromptFieldFocused || viewModel.status == .listening)
        .contentShape(RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous))
        .onTapGesture {
            isPromptFieldFocused = true
        }
    }

    private var promptDraftBinding: Binding<String> {
        Binding(
            get: { viewModel.draftUserSpeech },
            set: { viewModel.updateManualDraft($0) }
        )
    }

    private var promptHint: String {
        switch viewModel.status {
        case .ready:
            return "Speak naturally or tap here to type before sending."
        case .listening:
            return "Listening for your next turn."
        case .muted:
            return "Microphone is muted. Tap here if you want to type instead."
        case .processing:
            return "Sending your turn to Codex."
        case .speaking:
            return "Codex is responding."
        case .preparing:
            return "Preparing the remote bridge."
        case .ended:
            return "Session ended."
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private func promptStatusChip(palette: RelayTerminalPalette) -> some View {
        Label(promptStatusText, systemImage: promptStatusSymbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(promptStatusColor(palette: palette))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(promptStatusColor(palette: palette).opacity(0.14))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(promptStatusColor(palette: palette).opacity(0.24), lineWidth: 1)
            )
    }

    private var promptStatusText: String {
        if isPromptFieldFocused {
            return "Type"
        }

        switch viewModel.status {
        case .listening:
            return "Live"
        case .muted:
            return "Muted"
        case .processing:
            return "Sending"
        case .speaking:
            return "Codex"
        case .preparing:
            return "Starting"
        case .ended:
            return "Ended"
        case .failed:
            return "Alert"
        case .ready:
            return "Voice"
        }
    }

    private var promptStatusSymbol: String {
        if isPromptFieldFocused {
            return "keyboard"
        }

        switch viewModel.status {
        case .listening:
            return "waveform"
        case .muted:
            return "mic.slash"
        case .processing:
            return "arrow.up"
        case .speaking:
            return "speaker.wave.2"
        case .preparing:
            return "ellipsis"
        case .ended:
            return "phone.down"
        case .failed:
            return "exclamationmark.triangle"
        case .ready:
            return "mic"
        }
    }

    private func promptStatusColor(palette: RelayTerminalPalette) -> Color {
        if isPromptFieldFocused {
            return palette.accentColor
        }

        switch viewModel.status {
        case .failed:
            return palette.warningColor
        case .muted:
            return palette.warningColor
        case .ended:
            return palette.mutedColor
        default:
            return palette.accentColor
        }
    }

    private func controls(palette: RelayTerminalPalette) -> some View {
        VStack(spacing: RelayTheme.Spacing.content) {
            LazyVGrid(columns: controlColumns, alignment: .center, spacing: 18) {
                Button {
                    isPresentingAudioRoutes = true
                } label: {
                    VoicePhoneControlButton(
                        title: viewModel.selectedAudioRoute.name,
                        subtitle: nil,
                        systemImage: viewModel.selectedAudioRoute.systemImage,
                        palette: palette,
                        accentColor: palette.accentColor,
                        isActive: false,
                        usesSolidAccentFillWhenActive: false,
                        isDisabled: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Audio output")
                .accessibilityValue(viewModel.selectedAudioRoute.name)

                Button {
                    viewModel.toggleMute()
                } label: {
                    VoicePhoneControlButton(
                        title: viewModel.isMuted ? "Unmute" : "Mute",
                        subtitle: nil,
                        systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                        palette: palette,
                        accentColor: palette.warningColor,
                        isActive: viewModel.isMuted,
                        usesSolidAccentFillWhenActive: false,
                        isDisabled: false
                    )
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.finishCurrentTurn()
                    isPromptFieldFocused = false
                } label: {
                    VoicePhoneControlButton(
                        title: "Send",
                        subtitle: nil,
                        systemImage: "arrow.up.circle.fill",
                        palette: palette,
                        accentColor: palette.accentColor,
                        isActive: viewModel.canSendCurrentTurn,
                        usesSolidAccentFillWhenActive: false,
                        isDisabled: !viewModel.canSendCurrentTurn
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSendCurrentTurn)

                Button {
                    viewModel.fastForwardPlayback()
                } label: {
                    VoicePhoneControlButton(
                        title: "Skip",
                        subtitle: nil,
                        systemImage: "forward.end.fill",
                        palette: palette,
                        accentColor: palette.accentColor,
                        isActive: false,
                        usesSolidAccentFillWhenActive: false,
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
                        title: "Stop",
                        subtitle: nil,
                        systemImage: "waveform.badge.xmark",
                        palette: palette,
                        accentColor: palette.accentColor,
                        isActive: false,
                        usesSolidAccentFillWhenActive: false,
                        isDisabled: !viewModel.canInterrupt
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canInterrupt)

                Button {
                    dismiss()
                } label: {
                    VoicePhoneControlButton(
                        title: "End",
                        subtitle: nil,
                        systemImage: "phone.down.fill",
                        palette: palette,
                        accentColor: palette.dangerColor,
                        isActive: true,
                        usesSolidAccentFillWhenActive: true,
                        isDisabled: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End voice session")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(palette.surfaceColor.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(palette.subtleColor.opacity(0.75), lineWidth: 1)
        )
    }

    private var controlColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: RelayTheme.Spacing.section), count: 3)
    }

    private func bottomTrayHeight(for availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.30, 238), 320)
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
        Group {
            switch item.kind {
            case .system, .toolStatus:
                statusRow
            case .user, .assistant:
                messageRow
            }
        }
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

    private var messageRow: some View {
        VStack(alignment: messageAlignment, spacing: 6) {
            Text(label.uppercased())
                .font(TerminalFontRegistry.terminalSwiftUIFont(size: 11, bold: true))
                .foregroundStyle(metadataColor)

            Text(item.text)
                .font(font)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: rowAlignment)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayTheme.Radius.input, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: rowAlignment)
        .padding(.leading, item.kind == .user ? 56 : 0)
        .padding(.trailing, item.kind == .assistant ? 56 : 0)
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: RelayTheme.Spacing.tight) {
            Image(systemName: labelSymbolName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusAccentColor)
                .padding(.top, 1)

            Text(item.text)
                .font(.footnote)
                .foregroundStyle(palette.mutedColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.surfaceColor.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.subtleColor.opacity(0.55), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var messageAlignment: HorizontalAlignment {
        item.kind == .user ? .trailing : .leading
    }

    private var rowAlignment: Alignment {
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
        item.kind == .user ? palette.accentColor.opacity(0.12) : palette.raisedColor
    }

    private var borderColor: Color {
        item.kind == .user ? palette.accentColor.opacity(0.28) : palette.subtleColor.opacity(0.65)
    }

    private var textColor: Color {
        palette.textColor
    }

    private var metadataColor: Color {
        item.kind == .user ? palette.accentColor : palette.mutedColor
    }

    private var statusAccentColor: Color {
        item.kind == .system ? palette.warningColor : palette.mutedColor
    }
}

private struct VoiceTranscriptActivityRow: View {
    let palette: RelayTerminalPalette

    var body: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
                .tint(palette.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.raisedColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(palette.subtleColor.opacity(0.65), lineWidth: 1)
                )
                .accessibilityLabel("Codex is working")

            Spacer(minLength: 0)
        }
        .padding(.trailing, 56)
    }
}

private struct VoicePhoneControlButton: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let palette: RelayTerminalPalette
    let accentColor: Color
    let isActive: Bool
    let usesSolidAccentFillWhenActive: Bool
    let isDisabled: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 64, height: 64)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(palette.mutedColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
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
            if usesSolidAccentFillWhenActive {
                return accentColor
            }
            return accentColor.opacity(0.2)
        }

        return palette.raisedColor.opacity(0.95)
    }

    private var circleStrokeColor: Color {
        if isActive && usesSolidAccentFillWhenActive {
            return accentColor.opacity(0.95)
        }

        if isActive {
            return accentColor.opacity(0.65)
        }

        return palette.subtleColor.opacity(0.85)
    }

    private var iconColor: Color {
        if isDisabled {
            return palette.mutedColor.opacity(0.55)
        }

        if isActive && usesSolidAccentFillWhenActive {
            return .white
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
