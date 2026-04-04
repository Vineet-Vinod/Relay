//
//  DirectSSHSessionClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

@MainActor
final class DirectSSHSessionClient: TerminalSessionClient {
    let host: Host

    private let sshClient: SSHClient

    init(host: Host, sshClient: SSHClient? = nil) {
        self.host = host
        self.sshClient = sshClient ?? SSHClientFactory.makeDirectClient()
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (TerminalEvent) -> Void)?) {
        sshClient.setEventHandler(handler)
    }

    func connect() async throws {
        try await sshClient.connect(to: host)
    }

    func provisionSavedKey() async throws {
        try await sshClient.provisionSavedKey(for: host)
    }

    func sendRawInput(_ bytes: [UInt8]) async throws {
        try await sshClient.sendRawInput(bytes)
    }

    func resizeTerminal(columns: Int, rows: Int) async {
        await sshClient.resizeTerminal(columns: columns, rows: rows)
    }

    func disconnect() async {
        await sshClient.disconnect()
    }
}
