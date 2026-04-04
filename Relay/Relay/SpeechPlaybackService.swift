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

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeakingOrQueued: Bool {
        synthesizer.isSpeaking || synthesizer.isPaused || activeUtterance != nil || !pendingSpeech.isEmpty
    }

    var canFastForward: Bool {
        activeUtterance != nil || !pendingSpeech.isEmpty
    }

    func speak(_ text: String, rate: Float, kind: UtteranceKind) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pendingSpeech.append(QueuedSpeech(kind: kind, text: trimmed, rate: rate, revealsTranscriptOnStart: true))
        startNextUtteranceIfNeeded()
    }

    func updateRate(_ rate: Float) {
        let updatedRate = max(0, rate)

        for index in pendingSpeech.indices {
            pendingSpeech[index].rate = updatedRate
        }

        guard let activeSpeech else { return }

        self.activeSpeech = QueuedSpeech(
            kind: activeSpeech.kind,
            text: activeSpeech.text,
            rate: updatedRate,
            revealsTranscriptOnStart: activeSpeech.revealsTranscriptOnStart
        )

        guard activeUtterance != nil || synthesizer.isSpeaking || synthesizer.isPaused else {
            return
        }

        let remainingText = remainingTextForRestart(from: activeSpeech)
        guard let remainingText else { return }

        speechPendingRestart = QueuedSpeech(
            kind: activeSpeech.kind,
            text: remainingText,
            rate: updatedRate,
            revealsTranscriptOnStart: false
        )
        cancellationBehavior = .restart
        synthesizer.stopSpeaking(at: .immediate)
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

    private func startNextUtteranceIfNeeded() {
        guard activeUtterance == nil else { return }
        guard !synthesizer.isSpeaking && !synthesizer.isPaused else { return }
        guard !pendingSpeech.isEmpty else { return }

        let nextSpeech = pendingSpeech.removeFirst()
        let utterance = AVSpeechUtterance(string: nextSpeech.text)
        utterance.rate = nextSpeech.rate
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
            startNextUtteranceIfNeeded()
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
