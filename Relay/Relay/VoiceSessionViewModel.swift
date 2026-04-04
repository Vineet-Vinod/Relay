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
    private static let automaticTurnFinishDelay: Duration = .seconds(1.1)

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
    var isMuted = false
    var isPrepared = false
    var isEnding = false
    var isAwaitingTurnCompletion = false

    private let bridgeClient: CodexBridgeClient
    private let recognizer: SpeechRecognizerService
    private let playback: SpeechPlaybackService
    private let audioSession: VoiceAudioSessionCoordinator

    private var activeTurnTask: Task<Void, Never>?
    private var autoFinishTask: Task<Void, Never>?
    private var assistantSpeechBuffer = ""
    private var didReceiveAssistantDone = false
    private var shouldResumeListeningAfterPlayback = false

    init(
        configuration: VoiceSessionConfiguration,
        bridgeClient: CodexBridgeClient? = nil
    ) {
        let recognizer = SpeechRecognizerService()
        let playback = SpeechPlaybackService()
        let audioSession = VoiceAudioSessionCoordinator()

        self.configuration = configuration
        self.resolvedWorkspacePath = configuration.workspacePath
        self.bridgeClient = bridgeClient ?? CodexBridgeClient(host: configuration.host)
        self.recognizer = recognizer
        self.playback = playback
        self.audioSession = audioSession

        self.recognizer.onPartialTranscription = { [weak self] text in
            self?.handlePartialTranscript(text)
        }
        self.recognizer.onFinalTranscription = { [weak self] text in
            self?.cancelPendingAutoFinish()
            self?.handleFinalTranscript(text)
        }
        self.recognizer.onRecognitionEvent = { [weak self] event in
            self?.handleRecognitionEvent(event)
        }
        self.recognizer.onError = { [weak self] message in
            self?.cancelPendingAutoFinish()
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
        self.playback.onDidFinishQueue = { [weak self] in
            guard let self else { return }
            if self.isEnding {
                self.status = .ended
                return
            }

            if self.shouldResumeListeningAfterPlayback {
                self.shouldResumeListeningAfterPlayback = false
                self.beginListeningIfPossible()
            } else if self.isMuted {
                self.status = .muted
            } else if self.activeTurnTask != nil {
                self.status = .processing
            } else {
                self.status = .ready
            }
        }
    }

    private func handleRecognitionEvent(_ event: SpeechRecognizerService.RecognitionEvent) {
        switch event {
        case .cancelled:
            cancelPendingAutoFinish()
            isAwaitingTurnCompletion = false
        case .noSpeechDetected:
            cancelPendingAutoFinish()
            draftUserSpeech = ""
            isAwaitingTurnCompletion = false
            latestErrorMessage = nil
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                if !self.isMuted && !self.isEnding && self.activeTurnTask == nil && !self.playback.isSpeakingOrQueued {
                    self.beginListeningIfPossible()
                }
            }
        case .failure:
            break
        }
    }

    var canInterrupt: Bool {
        activeTurnTask != nil || playback.isSpeakingOrQueued
    }

    var canListen: Bool {
        isPrepared && !isMuted && activeTurnTask == nil && !playback.isSpeakingOrQueued && !isEnding
    }

    var canSendCurrentTurn: Bool {
        recognizer.listening &&
        activeTurnTask == nil &&
        !isMuted &&
        !isEnding &&
        !draftUserSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            appendTranscript(kind: .system, text: "Voice session ready in \(resolvedWorkspace).")
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
        cancelPendingAutoFinish()
        activeTurnTask?.cancel()
        activeTurnTask = nil
        recognizer.stopListening()
        playback.stop()
        await bridgeClient.endSession()
        audioSession.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        status = .ended
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            cancelPendingAutoFinish()
            recognizer.stopListening()
            draftUserSpeech = ""
            isAwaitingTurnCompletion = false
            status = .muted
        } else {
            beginListeningIfPossible()
        }
    }

    func interrupt() {
        cancelPendingAutoFinish()
        recognizer.stopListening()
        playback.stop()
        assistantSpeechBuffer.removeAll(keepingCapacity: true)
        shouldResumeListeningAfterPlayback = false
        isAwaitingTurnCompletion = false

        if let activeTurnTask {
            Task {
                await bridgeClient.interruptCurrentTurn()
            }
            activeTurnTask.cancel()
            self.activeTurnTask = nil
        }

        appendTranscript(kind: .system, text: "Interrupted.")
        if isMuted {
            status = .muted
        } else {
            beginListeningIfPossible()
        }
    }

    func finishCurrentTurn() {
        guard canSendCurrentTurn else { return }
        isAwaitingTurnCompletion = false
        cancelPendingAutoFinish()
        recognizer.finishListening()
    }

    private func beginListeningIfPossible() {
        guard canListen else {
            if isMuted {
                status = .muted
            } else if isPrepared && activeTurnTask == nil {
                status = .ready
            }
            return
        }

        latestErrorMessage = nil
        draftUserSpeech = ""
        isAwaitingTurnCompletion = false
        status = .listening
        recognizer.startListening()
    }

    private func handlePartialTranscript(_ text: String) {
        draftUserSpeech = text

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isAwaitingTurnCompletion = false
            cancelPendingAutoFinish()
            return
        }

        guard recognizer.listening else { return }
        isAwaitingTurnCompletion = true
        scheduleAutoFinish()
    }

    private func handleFinalTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isAwaitingTurnCompletion = false
        guard !trimmed.isEmpty else {
            draftUserSpeech = ""
            beginListeningIfPossible()
            return
        }

        draftUserSpeech = ""
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
                let message = self.describe(error)
                self.latestErrorMessage = message
                self.status = .failed(message)
                self.appendTranscript(kind: .system, text: message)
            }

            await MainActor.run {
                self.activeTurnTask = nil
                if self.didReceiveAssistantDone && !self.playback.isSpeakingOrQueued {
                    self.beginListeningIfPossible()
                } else if !self.didReceiveAssistantDone && !Task.isCancelled {
                    self.beginListeningIfPossible()
                }
            }
        }
    }

    private func scheduleAutoFinish() {
        cancelPendingAutoFinish()
        autoFinishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.automaticTurnFinishDelay)
            } catch {
                return
            }

            await MainActor.run {
                guard let self else { return }
                guard self.recognizer.listening else { return }
                guard self.activeTurnTask == nil else { return }
                guard !self.isMuted && !self.isEnding else { return }
                guard !self.draftUserSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.finishCurrentTurn()
            }
        }
    }

    private func cancelPendingAutoFinish() {
        autoFinishTask?.cancel()
        autoFinishTask = nil
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
            appendAssistantDelta(text)
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
            } else {
                beginListeningIfPossible()
            }
        case .toolStatus(let text):
            appendTranscript(kind: .toolStatus, text: text)
            if RelayPreferences.shared.voiceSpeaksToolStatus {
                playback.speak(text, rate: Float(RelayPreferences.shared.voiceSpeechRate))
            }
        case .error(let message, _):
            latestErrorMessage = message
            appendTranscript(kind: .system, text: message)
            if !playback.isSpeakingOrQueued {
                status = .failed(message)
            }
        }
    }

    private func appendAssistantDelta(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let lastIndex = transcript.lastIndex(where: { $0.kind == .assistant }),
           lastIndex == transcript.indices.last {
            let prefix = transcript[lastIndex].text.hasSuffix("\n") || trimmed.hasPrefix("\n") ? "" : " "
            transcript[lastIndex].text += prefix + trimmed
        } else {
            transcript.append(VoiceTranscriptItem(kind: .assistant, text: trimmed))
        }

        let separator = assistantSpeechBuffer.isEmpty || trimmed.hasPrefix("\n") ? "" : " "
        assistantSpeechBuffer += separator + trimmed
    }

    private func appendTranscript(kind: VoiceTranscriptItem.Kind, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.append(VoiceTranscriptItem(kind: kind, text: trimmed))
    }

    private func queueSpeechIfNeeded(force: Bool) {
        let candidate = speechChunkCandidate(from: assistantSpeechBuffer, force: force)
        guard let candidate, !candidate.isEmpty else { return }

        let chunkLength = candidate.count
        assistantSpeechBuffer.removeFirst(min(chunkLength, assistantSpeechBuffer.count))
        assistantSpeechBuffer = assistantSpeechBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        playback.speak(candidate, rate: Float(RelayPreferences.shared.voiceSpeechRate))
    }

    private func speechChunkCandidate(from buffer: String, force: Bool) -> String? {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if force {
            return trimmed
        }

        let delimiters = CharacterSet(charactersIn: ".!?\n")
        if let range = trimmed.rangeOfCharacter(from: delimiters) {
            return String(trimmed[..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.count >= 140 {
            return trimmed
        }

        return nil
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
