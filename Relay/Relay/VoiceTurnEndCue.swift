//
//  VoiceTurnEndCue.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

enum VoiceTurnEndCue {
    private static let cuePattern = try! NSRegularExpression(
        pattern: #"(?i)^(.+?)(?:[\s,;:]+)(over(?:\s+and\s+out)?)[.!?]*$"#
    )

    static func stripTrailingCue(from transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = cuePattern.firstMatch(in: trimmed, options: [], range: range),
              let contentRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }

        let content = trimmed[contentRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return String(content)
    }
}
