//
//  TerminalSessionClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

@MainActor
protocol TerminalSessionClient: AnyObject {
    func setEventHandler(_ handler: (@MainActor @Sendable (TerminalEvent) -> Void)?)
    func connect() async throws
    func sendRawInput(_ bytes: [UInt8]) async throws
    func resizeTerminal(columns: Int, rows: Int) async
    func disconnect() async
}

@MainActor
enum TerminalSessionClientFactory {
    static func makeClient(for host: Host) -> TerminalSessionClient {
        switch host.transport {
        case .directSSH:
            return DirectSSHSessionClient(host: host)
        case .relay:
            return RelaySessionClient(host: host)
        }
    }
}
