//
//  RelaySpeechVoiceResolver.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import AVFoundation
import Foundation

enum RelaySpeechVoiceResolver {
    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let preferredLanguages = preferredLanguageIdentifiers()
        let eligibleVoices = AVSpeechSynthesisVoice.speechVoices().filter(isEligible(_:))

        if let preferred = eligibleVoices.max(by: {
            voiceScore($0, preferredLanguages: preferredLanguages) < voiceScore($1, preferredLanguages: preferredLanguages)
        }) {
            return preferred
        }

        for language in preferredLanguages {
            if let voice = AVSpeechSynthesisVoice(language: language) {
                return voice
            }
        }

        return nil
    }

    private static func isEligible(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let traits = voice.voiceTraits
        return !traits.contains(.isNoveltyVoice) && !traits.contains(.isPersonalVoice)
    }

    private static func voiceScore(
        _ voice: AVSpeechSynthesisVoice,
        preferredLanguages: [String]
    ) -> Int {
        qualityScore(for: voice.quality) + languageScore(for: voice.language, preferredLanguages: preferredLanguages)
    }

    private static func qualityScore(for quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium:
            return 400
        case .enhanced:
            return 250
        case .default:
            return 100
        @unknown default:
            return 0
        }
    }

    private static func languageScore(
        for voiceLanguage: String,
        preferredLanguages: [String]
    ) -> Int {
        let canonicalVoiceLanguage = canonicalLanguageIdentifier(voiceLanguage)
        let voiceBaseLanguage = baseLanguageIdentifier(canonicalVoiceLanguage)

        if let exactMatchIndex = preferredLanguages.firstIndex(of: canonicalVoiceLanguage) {
            return 120 - exactMatchIndex
        }

        if let baseMatchIndex = preferredLanguages.firstIndex(where: {
            baseLanguageIdentifier($0) == voiceBaseLanguage
        }) {
            return 60 - baseMatchIndex
        }

        return 0
    }

    private static func preferredLanguageIdentifiers() -> [String] {
        let rawIdentifiers = Locale.preferredLanguages + [Locale.current.identifier, "en-US", "en-GB", "en"]
        var orderedIdentifiers: [String] = []

        for identifier in rawIdentifiers {
            let canonicalIdentifier = canonicalLanguageIdentifier(identifier)
            guard !canonicalIdentifier.isEmpty, !orderedIdentifiers.contains(canonicalIdentifier) else {
                continue
            }
            orderedIdentifiers.append(canonicalIdentifier)
        }

        return orderedIdentifiers
    }

    private static func canonicalLanguageIdentifier(_ identifier: String) -> String {
        Locale.canonicalLanguageIdentifier(from: identifier.replacingOccurrences(of: "_", with: "-"))
    }

    private static func baseLanguageIdentifier(_ identifier: String) -> String {
        identifier
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased() ?? identifier.lowercased()
    }
}
