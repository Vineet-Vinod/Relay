//
//  RelayServices.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

enum RelayServices {
    nonisolated(unsafe) static let sshCredentials = SSHCredentialStore()
    nonisolated(unsafe) static let relayConfiguration = RelayConfigurationStore.shared
}
