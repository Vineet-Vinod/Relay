//
//  SpeechPlaybackService.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import AVFoundation

@MainActor
final class SpeechPlaybackService: NSObject {
    var onDidStartSpeaking: (() -> Void)?
    var onDidFinishQueue: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var queuedUtteranceCount = 0
    private var activeUtteranceCount = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeakingOrQueued: Bool {
        synthesizer.isSpeaking || synthesizer.isPaused || queuedUtteranceCount > 0 || activeUtteranceCount > 0
    }

    func speak(_ text: String, rate: Float) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = rate
        utterance.prefersAssistiveTechnologySettings = true
        queuedUtteranceCount += 1
        synthesizer.speak(utterance)
    }

    func stop() {
        queuedUtteranceCount = 0
        activeUtteranceCount = 0
        synthesizer.stopSpeaking(at: .immediate)
        onDidFinishQueue?()
    }
}

extension SpeechPlaybackService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        queuedUtteranceCount = max(queuedUtteranceCount - 1, 0)
        activeUtteranceCount += 1
        onDidStartSpeaking?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        activeUtteranceCount = max(activeUtteranceCount - 1, 0)
        if !isSpeakingOrQueued {
            onDidFinishQueue?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        activeUtteranceCount = max(activeUtteranceCount - 1, 0)
        if !isSpeakingOrQueued {
            onDidFinishQueue?()
        }
    }
}
