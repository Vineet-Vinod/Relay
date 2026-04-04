//
//  VoiceTypes.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

enum SessionKind: String, Hashable, Sendable {
    case terminal
    case voiceCodex
}

struct VoiceSessionConfiguration: Identifiable, Hashable, Sendable {
    let id: UUID
    var host: Host
    var workspacePath: String

    init(id: UUID = UUID(), host: Host, workspacePath: String) {
        self.id = id
        self.host = host
        self.workspacePath = workspacePath
    }
}

struct VoiceTranscriptItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case user
        case assistant
        case toolStatus
        case system
    }

    let id: UUID
    var kind: Kind
    var text: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
    }
}
