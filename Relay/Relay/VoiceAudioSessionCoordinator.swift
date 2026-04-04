//
//  VoiceAudioSessionCoordinator.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import AVFoundation

@MainActor
final class VoiceAudioSessionCoordinator {
    private let session = AVAudioSession.sharedInstance()

    func activate() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .allowBluetooth,
                .allowBluetoothA2DP,
                .defaultToSpeaker,
            ]
        )
        try session.setActive(true, options: [])
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
