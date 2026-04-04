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
    }

    private struct QueuedSpeech {
        let kind: UtteranceKind
        let text: String
        let rate: Float
    }

    var onDidStartSpeaking: (() -> Void)?
    var onDidFinishQueue: (() -> Void)?
    var onDidStartUtterance: ((UtteranceKind, String) -> Void)?
    var onDidSkipUtterance: ((UtteranceKind, String) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingSpeech: [QueuedSpeech] = []
    private var activeUtterance: AVSpeechUtterance?
    private var activeSpeech: QueuedSpeech?
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

        pendingSpeech.append(QueuedSpeech(kind: kind, text: trimmed, rate: rate))
        startNextUtteranceIfNeeded()
    }

    func fastForward() {
        guard canFastForward else { return }

        if activeUtterance != nil || synthesizer.isSpeaking || synthesizer.isPaused {
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
        synthesizer.speak(utterance)
    }

    private func handleUtteranceCompletion() {
        activeUtterance = nil
        activeSpeech = nil

        let behavior = cancellationBehavior
        cancellationBehavior = .none

        switch behavior {
        case .none, .advance:
            startNextUtteranceIfNeeded()
            if !isSpeakingOrQueued {
                onDidFinishQueue?()
            }
        case .finish:
            onDidFinishQueue?()
        }
    }
}

extension SpeechPlaybackService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        if let activeSpeech {
            onDidStartUtterance?(activeSpeech.kind, activeSpeech.text)
        }
        onDidStartSpeaking?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        handleUtteranceCompletion()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        handleUtteranceCompletion()
    }
}
