//
//  SpeechPlaybackService.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import AVFoundation

@MainActor
final class SpeechPlaybackService: NSObject {
    enum UtteranceKind: Equatable {
        case assistant
        case toolStatus
    }

    private enum CancellationBehavior {
        case none
        case advance
        case finish
        case restart
    }

    private struct QueuedSpeech {
        let kind: UtteranceKind
        let text: String
        var rate: Float
        var volume: Float
        let revealsTranscriptOnStart: Bool
    }

    var onDidStartSpeaking: (() -> Void)?
    var onDidFinishQueue: (() -> Void)?
    var onDidStartUtterance: ((UtteranceKind, String) -> Void)?
    var onDidSkipUtterance: ((UtteranceKind, String) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingSpeech: [QueuedSpeech] = []
    private var activeUtterance: AVSpeechUtterance?
    private var activeSpeech: QueuedSpeech?
    private var activeSpeechRange = NSRange(location: 0, length: 0)
    private var speechPendingRestart: QueuedSpeech?
    private var cancellationBehavior: CancellationBehavior = .none
    private var isExternallyPaused = false
    private let preferredVoice: AVSpeechSynthesisVoice?

    override init() {
        self.preferredVoice = RelaySpeechVoiceResolver.preferredVoice()
        super.init()
        synthesizer.delegate = self
    }

    var isSpeakingOrQueued: Bool {
        synthesizer.isSpeaking || synthesizer.isPaused || activeUtterance != nil || !pendingSpeech.isEmpty
    }

    var canFastForward: Bool {
        activeUtterance != nil || !pendingSpeech.isEmpty
    }

    var pendingUtteranceCount: Int {
        pendingSpeech.count + (speechPendingRestart == nil ? 0 : 1)
    }

    func speak(_ text: String, rate: Float, volume: Float, kind: UtteranceKind) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pendingSpeech.append(
            QueuedSpeech(
                kind: kind,
                text: trimmed,
                rate: rate,
                volume: min(max(volume, 0), 1),
                revealsTranscriptOnStart: true
            )
        )
        startNextUtteranceIfNeeded()
    }

    func updateRate(_ rate: Float) {
        updatePlayback(rate: max(0, rate), volume: nil)
    }

    func updateVolume(_ volume: Float) {
        updatePlayback(rate: nil, volume: min(max(volume, 0), 1))
    }

    func fastForward() {
        guard canFastForward else { return }

        if activeUtterance != nil || synthesizer.isSpeaking || synthesizer.isPaused {
            speechPendingRestart = nil
            cancellationBehavior = .advance
            synthesizer.stopSpeaking(at: .immediate)
            return
        }

        let skippedSpeech = pendingSpeech.removeFirst()
        onDidSkipUtterance?(skippedSpeech.kind, skippedSpeech.text)
        startNextUtteranceIfNeeded()
        if !isSpeakingOrQueued {
            onDidFinishQueue?()
        }
    }

    func stop() {
        let hadPlayback = isSpeakingOrQueued
        isExternallyPaused = false
        pendingSpeech.removeAll()
        speechPendingRestart = nil

        if activeUtterance != nil || synthesizer.isSpeaking || synthesizer.isPaused {
            cancellationBehavior = .finish
            synthesizer.stopSpeaking(at: .immediate)
            return
        }

        if hadPlayback {
            onDidFinishQueue?()
        }
    }

    func pausePreservingQueue() {
        isExternallyPaused = true

        guard let activeSpeech,
              activeUtterance != nil || synthesizer.isSpeaking || synthesizer.isPaused else {
            return
        }

        let remainingText = remainingTextForRestart(from: activeSpeech) ?? activeSpeech.text
        let remainingSpeech = QueuedSpeech(
            kind: activeSpeech.kind,
            text: remainingText,
            rate: activeSpeech.rate,
            volume: activeSpeech.volume,
            revealsTranscriptOnStart: false
        )

        speechPendingRestart = remainingSpeech
        cancellationBehavior = .restart
        synthesizer.stopSpeaking(at: .immediate)
    }

    func resumeFromPause() {
        guard isExternallyPaused else { return }
        isExternallyPaused = false
        startNextUtteranceIfNeeded()
    }

    private func startNextUtteranceIfNeeded() {
        guard !isExternallyPaused else { return }
        guard activeUtterance == nil else { return }
        guard !synthesizer.isSpeaking && !synthesizer.isPaused else { return }
        guard !pendingSpeech.isEmpty else { return }

        let nextSpeech = pendingSpeech.removeFirst()
        let utterance = AVSpeechUtterance(string: nextSpeech.text)
        utterance.voice = preferredVoice
        utterance.rate = nextSpeech.rate
        utterance.volume = nextSpeech.volume
        utterance.prefersAssistiveTechnologySettings = false
        activeUtterance = utterance
        activeSpeech = nextSpeech
        activeSpeechRange = NSRange(location: 0, length: 0)
        synthesizer.speak(utterance)
    }

    private func handleUtteranceCompletion() {
        activeUtterance = nil
        activeSpeech = nil
        activeSpeechRange = NSRange(location: 0, length: 0)

        let behavior = cancellationBehavior
        cancellationBehavior = .none

        switch behavior {
        case .none, .advance:
            speechPendingRestart = nil
            startNextUtteranceIfNeeded()
            if !isSpeakingOrQueued {
                onDidFinishQueue?()
            }
        case .finish:
            speechPendingRestart = nil
            onDidFinishQueue?()
        case .restart:
            if let speechPendingRestart {
                pendingSpeech.insert(speechPendingRestart, at: 0)
                self.speechPendingRestart = nil
            }
            if !isExternallyPaused {
                startNextUtteranceIfNeeded()
            }
        }
    }

    private func remainingTextForRestart(from speech: QueuedSpeech) -> String? {
        let spokenEnd = activeSpeechRange.location + activeSpeechRange.length
        let totalLength = speech.text.utf16.count
        guard spokenEnd < totalLength else { return nil }

        let utf16 = speech.text.utf16
        guard let restartIndex = utf16.index(utf16.startIndex, offsetBy: spokenEnd, limitedBy: utf16.endIndex),
              let stringIndex = String.Index(restartIndex, within: speech.text) else {
            return nil
        }

        let remaining = String(speech.text[stringIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return remaining.isEmpty ? nil : String(remaining)
    }

    private func updatePlayback(rate: Float?, volume: Float?) {
        for index in pendingSpeech.indices {
            if let rate {
                pendingSpeech[index].rate = rate
            }
            if let volume {
                pendingSpeech[index].volume = volume
            }
        }

        guard let activeSpeech else { return }

        let updatedSpeech = QueuedSpeech(
            kind: activeSpeech.kind,
            text: activeSpeech.text,
            rate: rate ?? activeSpeech.rate,
            volume: volume ?? activeSpeech.volume,
            revealsTranscriptOnStart: activeSpeech.revealsTranscriptOnStart
        )
        self.activeSpeech = updatedSpeech

        guard activeUtterance != nil || synthesizer.isSpeaking || synthesizer.isPaused else {
            return
        }

        let remainingText = remainingTextForRestart(from: activeSpeech)
        guard let remainingText else { return }

        speechPendingRestart = QueuedSpeech(
            kind: activeSpeech.kind,
            text: remainingText,
            rate: updatedSpeech.rate,
            volume: updatedSpeech.volume,
            revealsTranscriptOnStart: false
        )
        cancellationBehavior = .restart
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension SpeechPlaybackService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        if let activeSpeech, activeSpeech.revealsTranscriptOnStart {
            onDidStartUtterance?(activeSpeech.kind, activeSpeech.text)
        }
        onDidStartSpeaking?()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        activeSpeechRange = characterRange
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        handleUtteranceCompletion()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        handleUtteranceCompletion()
    }
}
