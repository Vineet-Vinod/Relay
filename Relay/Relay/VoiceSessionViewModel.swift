//
//  VoiceSessionViewModel.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class VoiceSessionViewModel {
    private static let unmuteListeningResumeDelay: Duration = .milliseconds(90)
    private static let sendCuePauseDelay: Duration = .milliseconds(700)

    enum Status: Equatable {
        case preparing
        case ready
        case listening
        case processing
        case speaking
        case muted
        case ended
        case failed(String)

        var title: String {
            switch self {
            case .preparing:
                return "Preparing"
            case .ready:
                return "Ready"
            case .listening:
                return "Listening"
            case .processing:
                return "Working"
            case .speaking:
                return "Speaking"
            case .muted:
                return "Muted"
            case .ended:
                return "Ended"
            case .failed:
                return "Attention Needed"
            }
        }
    }

    let configuration: VoiceSessionConfiguration

    var transcript: [VoiceTranscriptItem] = []
    var draftUserSpeech = ""
    var status: Status = .preparing
    var resolvedWorkspacePath: String
    var sessionID: String?
    var latestErrorMessage: String?
    var isPrepared = false
    var isEnding = false
    var isManualEntryActive = false
    var availableAudioRoutes: [VoiceAudioSessionCoordinator.AudioRouteOption] = []
    var selectedAudioRoute: VoiceAudioSessionCoordinator.AudioRouteOption = .receiver

    var isMuted: Bool {
        isUserMuted || isWaitingForAssistantTurnToFinish
    }

    var hasDraftUserSpeech: Bool {
        !draftUserSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var showsConversationActivity: Bool {
        activeTurnTask != nil || status == .processing
    }

    var isAwaitingSendCue: Bool {
        hasDraftUserSpeech && !isMuted && activeTurnTask == nil && !isEnding
    }

    private let bridgeClient: CodexBridgeClient
    private let recognizer: SpeechRecognizerService
    private let playback: SpeechPlaybackService
    private let audioSession: VoiceAudioSessionCoordinator
    private let controlSoundPlayer: VoiceControlSoundPlayer

    private var activeTurnTask: Task<Void, Never>?
    private var muteTransitionTask: Task<Void, Never>?
    private var sendCuePauseTask: Task<Void, Never>?
    private var assistantSpeechBuffer = ""
    private var didReceiveAssistantDone = false
    private var shouldResumeListeningAfterPlayback = false
    private var typedDraftSpeech = ""
    private var committedDraftSpeech = ""
    private var liveDraftSpeech = ""
    private var isUserMuted = false
    private var isWaitingForAssistantTurnToFinish = false

    init(
        configuration: VoiceSessionConfiguration,
        bridgeClient: CodexBridgeClient? = nil
    ) {
        let recognizer = SpeechRecognizerService()
        let playback = SpeechPlaybackService()
        let audioSession = VoiceAudioSessionCoordinator()
        let controlSoundPlayer = VoiceControlSoundPlayer()

        self.configuration = configuration
        self.resolvedWorkspacePath = configuration.workspacePath
        self.bridgeClient = bridgeClient ?? CodexBridgeClient(host: configuration.host)
        self.recognizer = recognizer
        self.playback = playback
        self.audioSession = audioSession
        self.controlSoundPlayer = controlSoundPlayer
        self.availableAudioRoutes = audioSession.availableRoutes
        self.selectedAudioRoute = audioSession.selectedRoute

        self.recognizer.onPartialTranscription = { [weak self] text in
            self?.handlePartialTranscript(text)
        }
        self.recognizer.onFinalTranscription = { [weak self] text in
            self?.handleFinalTranscript(text)
        }
        self.recognizer.onRecognitionEvent = { [weak self] event in
            self?.handleRecognitionEvent(event)
        }
        self.recognizer.onError = { [weak self] message in
            self?.latestErrorMessage = message
            self?.appendTranscript(kind: .system, text: message)
            if self?.isMuted == true {
                self?.status = .muted
            } else {
                self?.status = .ready
            }
        }

        self.playback.onDidStartSpeaking = { [weak self] in
            guard let self, !self.isEnding else { return }
            self.status = .speaking
        }
        self.playback.onDidStartUtterance = { [weak self] kind, text in
            guard let self else { return }
            if kind == .assistant {
                self.revealAssistantSpeech(text)
            }
        }
        self.playback.onDidSkipUtterance = { [weak self] kind, text in
            guard let self else { return }
            if kind == .assistant {
                self.revealAssistantSpeech(text)
            }
        }
        self.playback.onDidFinishQueue = { [weak self] in
            guard let self else { return }
            if self.isEnding {
                self.status = .ended
                return
            }

            if self.isFailedStatus {
                return
            }

            if self.shouldResumeListeningAfterPlayback, self.activeTurnTask == nil {
                self.completeAssistantTurn(playCue: self.didReceiveAssistantDone)
            } else if self.activeTurnTask != nil {
                self.status = .processing
            } else if self.isMuted {
                self.status = .muted
            } else {
                self.status = .ready
            }
        }

        self.audioSession.onRouteStateChanged = { [weak self] routes, selected in
            self?.availableAudioRoutes = routes
            self?.selectedAudioRoute = selected
        }
    }

    private func handleRecognitionEvent(_ event: SpeechRecognizerService.RecognitionEvent) {
        cancelSendCuePauseTask()
        switch event {
        case .cancelled:
            syncDraftUserSpeech()
        case .noSpeechDetected:
            liveDraftSpeech = ""
            syncDraftUserSpeech()
            latestErrorMessage = nil
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                if !self.isMuted && !self.isEnding && self.activeTurnTask == nil && !self.playback.isSpeakingOrQueued {
                    self.beginListeningIfPossible(preservingDraft: self.hasDraftUserSpeech)
                }
            }
        case .failure:
            break
        }
    }

    var canInterrupt: Bool {
        activeTurnTask != nil || playback.isSpeakingOrQueued
    }

    var canFastForward: Bool {
        playback.canFastForward
    }

    var canListen: Bool {
        isPrepared && !isMuted && activeTurnTask == nil && !playback.isSpeakingOrQueued && !isEnding && !isManualEntryActive
    }

    var canSendCurrentTurn: Bool {
        activeTurnTask == nil &&
        !isMuted &&
        !isEnding &&
        hasDraftUserSpeech
    }

    func start() async {
        do {
            try audioSession.activate()
        } catch {
            status = .failed("Relay couldn't configure audio for voice mode.")
            latestErrorMessage = error.localizedDescription
            appendTranscript(kind: .system, text: error.localizedDescription)
            return
        }

        let authorization = await recognizer.requestAuthorization()
        guard authorization == .authorized else {
            let message = authorizationMessage(for: authorization)
            status = .failed(message)
            latestErrorMessage = message
            appendTranscript(kind: .system, text: message)
            return
        }

        do {
            let resolvedWorkspace = try await bridgeClient.prepare(workspacePath: configuration.workspacePath)
            resolvedWorkspacePath = resolvedWorkspace
            isPrepared = true
            beginListeningIfPossible()
        } catch {
            let message = describe(error)
            latestErrorMessage = message
            status = .failed(message)
            appendTranscript(kind: .system, text: message)
        }
    }

    func end() async {
        isEnding = true
        cancelSendCuePauseTask()
        cancelMuteTransition()
        activeTurnTask?.cancel()
        activeTurnTask = nil
        shouldResumeListeningAfterPlayback = false
        isWaitingForAssistantTurnToFinish = false
        recognizer.stopListening()
        playback.stop()
        await bridgeClient.endSession()
        audioSession.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        status = .ended
    }

    func toggleMute() {
        cancelMuteTransition()
        cancelSendCuePauseTask()
        if isUserMuted {
            isUserMuted = false
            status = currentStatusForSessionPhase()
            guard !isWaitingForAssistantTurnToFinish else { return }
            scheduleListeningResumeAfterUnmuteCue()
        } else {
            setUserMuted(true, playCue: true, clearDraft: true)
        }
    }

    func interrupt() {
        cancelSendCuePauseTask()
        recognizer.stopListening()
        playback.stop()
        assistantSpeechBuffer.removeAll(keepingCapacity: true)
        shouldResumeListeningAfterPlayback = false
        isWaitingForAssistantTurnToFinish = false
        clearDraftUserSpeech()

        if let activeTurnTask {
            Task {
                await bridgeClient.interruptCurrentTurn()
            }
            activeTurnTask.cancel()
            self.activeTurnTask = nil
        }

        if isMuted {
            status = .muted
        } else {
            beginListeningIfPossible()
        }
    }

    func fastForwardPlayback() {
        guard playback.canFastForward else { return }
        playback.fastForward()

        if playback.isSpeakingOrQueued {
            status = .speaking
        }
    }

    func updateSpeechRate(_ speechRate: Double) {
        playback.updateRate(Float(RelayVoicePreference.clampSpeechRate(speechRate)))
    }

    func updateSpeechVolume(_ volume: Double) {
        playback.updateVolume(Float(RelayVoicePreference.clampOutputVolume(volume)))
    }

    func beginManualEntry() {
        guard !isEnding else { return }
        guard !isManualEntryActive else { return }

        isManualEntryActive = true
        cancelSendCuePauseTask()
        recognizer.stopListening()

        typedDraftSpeech = currentDraftUserSpeech
        committedDraftSpeech = ""
        liveDraftSpeech = ""
        syncDraftUserSpeech()

        if playback.isSpeakingOrQueued {
            status = .speaking
        } else if activeTurnTask != nil {
            status = .processing
        } else if isMuted {
            status = .muted
        } else if isPrepared {
            status = .ready
        }
    }

    func endManualEntry() {
        guard isManualEntryActive else { return }

        isManualEntryActive = false
        typedDraftSpeech = draftUserSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        syncDraftUserSpeech()

        guard !isEnding else { return }
        guard !playback.isSpeakingOrQueued else {
            status = .speaking
            return
        }
        guard activeTurnTask == nil else {
            status = .processing
            return
        }
        guard !isMuted else {
            status = .muted
            return
        }
        guard isPrepared else {
            status = .preparing
            return
        }

        beginListeningIfPossible(preservingDraft: true)
    }

    func updateManualDraft(_ text: String) {
        typedDraftSpeech = text
        committedDraftSpeech = ""
        liveDraftSpeech = ""
        syncDraftUserSpeech()
    }

    func selectAudioRoute(_ route: VoiceAudioSessionCoordinator.AudioRouteOption) {
        do {
            try audioSession.selectRoute(route)
            latestErrorMessage = nil
        } catch {
            let message = "Relay couldn't switch audio output."
            latestErrorMessage = message
            appendTranscript(kind: .system, text: "\(message) \(error.localizedDescription)")
        }
    }

    func finishCurrentTurn() {
        guard canSendCurrentTurn else { return }
        recognizer.stopListening()
        submitCurrentDraft()
    }

    private func beginListeningIfPossible(preservingDraft: Bool = false) {
        cancelSendCuePauseTask()
        guard canListen else {
            if isMuted {
                status = .muted
            } else if isPrepared && activeTurnTask == nil {
                status = .ready
            }
            return
        }

        latestErrorMessage = nil
        if preservingDraft {
            liveDraftSpeech = ""
            syncDraftUserSpeech()
        } else {
            clearDraftUserSpeech()
        }
        status = .listening
        recognizer.startListening()
    }

    private func scheduleListeningResumeAfterUnmuteCue() {
        cancelMuteTransition()
        muteTransitionTask = Task { [weak self] in
            guard let self else { return }

            await self.controlSoundPlayer.playAndWait(.unmute)

            do {
                try await Task.sleep(for: Self.unmuteListeningResumeDelay)
            } catch {
                return
            }

            await MainActor.run {
                guard !self.isMuted && !self.isEnding else { return }
                guard !self.playback.isSpeakingOrQueued else { return }
                guard self.activeTurnTask == nil else { return }
                self.beginListeningIfPossible()
            }
        }
    }

    private func cancelMuteTransition() {
        muteTransitionTask?.cancel()
        muteTransitionTask = nil
        controlSoundPlayer.stop()
    }

    private func currentStatusForSessionPhase() -> Status {
        if playback.isSpeakingOrQueued {
            return .speaking
        }

        if activeTurnTask != nil {
            return .processing
        }

        if isMuted {
            return .muted
        }

        if isPrepared {
            return .ready
        }

        return .preparing
    }

    private func setUserMuted(_ muted: Bool, playCue: Bool, clearDraft: Bool) {
        isUserMuted = muted
        if muted {
            recognizer.stopListening()
            if clearDraft {
                clearDraftUserSpeech()
            }

            status = currentStatusForSessionPhase()

            if playCue {
                controlSoundPlayer.play(.mute)
            }

            return
        }

        status = currentStatusForSessionPhase()
    }

    private func setWaitingForAssistantTurn(_ waiting: Bool) {
        isWaitingForAssistantTurnToFinish = waiting

        if waiting {
            recognizer.stopListening()
        }
    }

    private func completeAssistantTurn(playCue: Bool) {
        shouldResumeListeningAfterPlayback = false
        setWaitingForAssistantTurn(false)

        guard !isUserMuted else {
            status = .muted
            return
        }

        if playCue {
            scheduleListeningResumeAfterUnmuteCue()
        } else {
            beginListeningIfPossible()
        }
    }

    private var isFailedStatus: Bool {
        if case .failed = status {
            return true
        }

        return false
    }

    private func handlePartialTranscript(_ text: String) {
        liveDraftSpeech = text.trimmingCharacters(in: .whitespacesAndNewlines)
        syncDraftUserSpeech()
        scheduleSendCuePauseIfNeeded()
    }

    private func handleFinalTranscript(_ text: String) {
        cancelSendCuePauseTask()
        liveDraftSpeech = text.trimmingCharacters(in: .whitespacesAndNewlines)
        syncDraftUserSpeech()

        let combinedDraft = currentDraftUserSpeech
        guard !combinedDraft.isEmpty else {
            clearDraftUserSpeech()
            beginListeningIfPossible()
            return
        }

        if let completedTurn = VoiceTurnEndCue.stripTrailingCue(from: combinedDraft) {
            submitUserTurn(completedTurn)
            return
        }

        commitLiveDraftSpeech()
        beginListeningIfPossible(preservingDraft: true)
    }

    private func handleBridgeEvent(_ event: CodexBridgeEvent) {
        switch event {
        case .sessionReady(let sessionID, let cwd):
            self.sessionID = sessionID ?? self.sessionID
            if let cwd {
                resolvedWorkspacePath = cwd
            }
        case .cwdResolved(let cwd):
            resolvedWorkspacePath = cwd
        case .processStarted:
            break
        case .assistantDelta(let text):
            latestErrorMessage = nil
            bufferAssistantDelta(text)
            queueSpeechIfNeeded(force: false)
            if playback.isSpeakingOrQueued {
                status = .speaking
            } else {
                status = .processing
            }
        case .assistantDone:
            didReceiveAssistantDone = true
            queueSpeechIfNeeded(force: true)
            if playback.isSpeakingOrQueued {
                status = .speaking
            } else if activeTurnTask == nil {
                completeAssistantTurn(playCue: true)
            } else {
                status = .processing
            }
        case .toolStatus(let text):
            if RelayPreferences.shared.voiceSpeaksToolStatus {
                playback.speak(
                    text,
                    rate: Float(RelayPreferences.shared.voiceSpeechRate),
                    volume: Float(RelayPreferences.shared.voiceOutputVolume),
                    kind: .toolStatus
                )
            }
        case .error(let message, _):
            shouldResumeListeningAfterPlayback = false
            setWaitingForAssistantTurn(false)
            latestErrorMessage = message
            appendTranscript(kind: .system, text: message)
            if !playback.isSpeakingOrQueued {
                status = .failed(message)
            }
        }
    }

    private func bufferAssistantDelta(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let separator = assistantSpeechBuffer.isEmpty || trimmed.hasPrefix("\n") ? "" : " "
        assistantSpeechBuffer += separator + trimmed
    }

    private func revealAssistantSpeech(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let lastIndex = transcript.lastIndex(where: { $0.kind == .assistant }),
           lastIndex == transcript.indices.last {
            let prefix = transcript[lastIndex].text.hasSuffix("\n") || trimmed.hasPrefix("\n") ? "" : " "
            transcript[lastIndex].text += prefix + trimmed
        } else {
            transcript.append(VoiceTranscriptItem(kind: .assistant, text: trimmed))
        }
    }

    private func appendTranscript(kind: VoiceTranscriptItem.Kind, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.append(VoiceTranscriptItem(kind: kind, text: trimmed))
    }

    private var currentDraftUserSpeech: String {
        joinSpeechSegments(typedDraftSpeech, joinSpeechSegments(committedDraftSpeech, liveDraftSpeech))
    }

    private func submitCurrentDraft() {
        let draft = VoiceTurnEndCue.stripTrailingCue(from: currentDraftUserSpeech) ?? currentDraftUserSpeech
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return }
        submitUserTurn(trimmedDraft)
    }

    private func submitUserTurn(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        cancelSendCuePauseTask()
        clearDraftUserSpeech()
        setWaitingForAssistantTurn(true)
        appendTranscript(kind: .user, text: trimmed)
        status = .processing
        shouldResumeListeningAfterPlayback = true
        didReceiveAssistantDone = false
        assistantSpeechBuffer.removeAll(keepingCapacity: true)

        activeTurnTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.bridgeClient.sendTurn(trimmed, workspacePath: self.resolvedWorkspacePath) { [weak self] event in
                    self?.handleBridgeEvent(event)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.shouldResumeListeningAfterPlayback = false
                self.setWaitingForAssistantTurn(false)
                let message = self.describe(error)
                self.latestErrorMessage = message
                self.status = .failed(message)
                self.appendTranscript(kind: .system, text: message)
            }

            await MainActor.run {
                self.activeTurnTask = nil
                guard !self.isEnding, !self.isFailedStatus else { return }
                if self.didReceiveAssistantDone && !self.playback.isSpeakingOrQueued {
                    self.completeAssistantTurn(playCue: true)
                } else if !self.didReceiveAssistantDone && !Task.isCancelled {
                    self.completeAssistantTurn(playCue: false)
                }
            }
        }
    }

    private func commitLiveDraftSpeech() {
        let trimmedLiveDraft = liveDraftSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLiveDraft.isEmpty {
            committedDraftSpeech = joinSpeechSegments(committedDraftSpeech, trimmedLiveDraft)
        }
        liveDraftSpeech = ""
        syncDraftUserSpeech()
    }

    private func clearDraftUserSpeech() {
        cancelSendCuePauseTask()
        typedDraftSpeech = ""
        committedDraftSpeech = ""
        liveDraftSpeech = ""
        draftUserSpeech = ""
    }

    private func syncDraftUserSpeech() {
        draftUserSpeech = currentDraftUserSpeech
    }

    private func joinSpeechSegments(_ leading: String, _ trailing: String) -> String {
        let trimmedLeading = leading.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTrailing = trailing.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (trimmedLeading.isEmpty, trimmedTrailing.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return trimmedTrailing
        case (false, true):
            return trimmedLeading
        case (false, false):
            return "\(trimmedLeading) \(trimmedTrailing)"
        }
    }

    private func scheduleSendCuePauseIfNeeded() {
        guard VoiceTurnEndCue.stripTrailingCue(from: currentDraftUserSpeech) != nil else {
            cancelSendCuePauseTask()
            return
        }

        sendCuePauseTask?.cancel()
        sendCuePauseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.sendCuePauseDelay)
            } catch {
                return
            }

            await MainActor.run {
                guard let self else { return }
                guard !self.isMuted, !self.isEnding else { return }
                guard self.activeTurnTask == nil else { return }
                guard self.recognizer.listening else { return }
                guard VoiceTurnEndCue.stripTrailingCue(from: self.currentDraftUserSpeech) != nil else { return }
                self.recognizer.finishListening()
            }
        }
    }

    private func cancelSendCuePauseTask() {
        sendCuePauseTask?.cancel()
        sendCuePauseTask = nil
    }

    private func queueSpeechIfNeeded(force: Bool) {
        while let chunk = nextSpeechChunk(from: assistantSpeechBuffer, force: force) {
            assistantSpeechBuffer.removeFirst(chunk.consumedCharacterCount)
            assistantSpeechBuffer = assistantSpeechBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            playback.speak(
                chunk.text,
                rate: Float(RelayPreferences.shared.voiceSpeechRate),
                volume: Float(RelayPreferences.shared.voiceOutputVolume),
                kind: .assistant
            )

            if force {
                break
            }
        }
    }

    private func nextSpeechChunk(from buffer: String, force: Bool) -> (text: String, consumedCharacterCount: Int)? {
        guard let contentStart = buffer.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) else {
            return nil
        }

        if force {
            let chunk = String(buffer[contentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { return nil }
            return (chunk, buffer.count)
        }

        let remaining = buffer[contentStart...]
        let delimiters = CharacterSet(charactersIn: ".!?\n")
        if let delimiterRange = remaining.rangeOfCharacter(from: delimiters) {
            let chunk = String(buffer[contentStart..<delimiterRange.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { return nil }
            let consumedCount = buffer.distance(from: buffer.startIndex, to: delimiterRange.upperBound)
            return (chunk, consumedCount)
        }

        let maxChunkLength = 140
        let remainingCount = buffer.distance(from: contentStart, to: buffer.endIndex)
        guard remainingCount >= maxChunkLength else { return nil }

        let tentativeEnd = buffer.index(contentStart, offsetBy: maxChunkLength, limitedBy: buffer.endIndex) ?? buffer.endIndex
        let prefix = buffer[contentStart..<tentativeEnd]
        let chunkEnd = prefix.lastIndex(where: \.isWhitespace) ?? tentativeEnd
        let chunk = String(buffer[contentStart..<chunkEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return nil }
        let consumedCount = buffer.distance(from: buffer.startIndex, to: chunkEnd)
        return (chunk, consumedCount)
    }

    private func authorizationMessage(for state: SpeechRecognizerService.AuthorizationState) -> String {
        switch state {
        case .authorized:
            return "Voice access is ready."
        case .denied:
            return "Relay needs microphone and speech recognition access for voice mode."
        case .restricted:
            return "Speech recognition is restricted on this device."
        case .unavailable:
            return "Speech recognition is unavailable on this device."
        }
    }

    private func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }

        let fallback = String(describing: error)
        if !fallback.isEmpty {
            return fallback
        }

        return (error as NSError).localizedDescription
    }
}
