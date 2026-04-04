//
//  RelayPreferences.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import CoreGraphics
import Foundation

enum RelayDefaultsKey {
    static let useSavedKeysAutomatically = "relay.preferences.use-saved-keys-automatically.v1"
    static let allowPasswordFallback = "relay.preferences.allow-password-fallback.v1"
    static let connectionTimeoutSeconds = "relay.preferences.connection-timeout-seconds.v1"
    static let terminalFontSize = "relay.preferences.terminal-font-size.v1"
    static let bellBehavior = "relay.preferences.bell-behavior.v1"
    static let keepScreenAwake = "relay.preferences.keep-screen-awake.v1"
    static let automaticallyReconnect = "relay.preferences.automatically-reconnect.v1"
    static let voiceSpeechRate = "relay.preferences.voice-speech-rate.v1"
    static let voiceOutputVolume = "relay.preferences.voice-output-volume.v1"
    static let voiceSpeaksToolStatus = "relay.preferences.voice-speaks-tool-status.v1"
    static let meshProviderKind = "relay.preferences.mesh-provider-kind.v1"
    static let relayServerURL = "relay.preferences.relay-server-url.v1"
    static let relayAllowInsecureTLS = "relay.preferences.relay-allow-insecure-tls.v1"

    static let all = [
        useSavedKeysAutomatically,
        allowPasswordFallback,
        connectionTimeoutSeconds,
        terminalFontSize,
        bellBehavior,
        keepScreenAwake,
        automaticallyReconnect,
        voiceSpeechRate,
        voiceOutputVolume,
        voiceSpeaksToolStatus,
        meshProviderKind,
        relayServerURL,
        relayAllowInsecureTLS,
    ]
}

enum RelayTerminalFontSizePreference {
    static let minimum: Double = 11
    static let maximum: Double = 22
    static let defaultSize: Double = 14

    static func clamp(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        CGFloat(clamp(Double(value)))
    }
}

enum RelayVoicePreference {
    static let minimumSpeechRate: Double = 0.32
    static let maximumSpeechRate: Double = 1.0

    static let minimumDisplaySpeed: Double = 0.5
    static let maximumDisplaySpeed: Double = 3.0
    static let displaySpeedStep: Double = 0.05
    static let defaultDisplaySpeed: Double = 1.0
    static let defaultSpeechRate: Double = speechRate(forDisplaySpeed: defaultDisplaySpeed)
    static let minimumOutputVolume: Double = 0.4
    static let maximumOutputVolume: Double = 1.0
    static let outputVolumeStep: Double = 0.05
    static let defaultOutputVolume: Double = 1.0

    static func clampSpeechRate(_ value: Double) -> Double {
        min(max(value, minimumSpeechRate), maximumSpeechRate)
    }

    static func clampOutputVolume(_ value: Double) -> Double {
        min(max(value, minimumOutputVolume), maximumOutputVolume)
    }

    static func speechRate(forDisplaySpeed value: Double) -> Double {
        let clampedValue = min(max(value, minimumDisplaySpeed), maximumDisplaySpeed)
        let progress = (clampedValue - minimumDisplaySpeed) / (maximumDisplaySpeed - minimumDisplaySpeed)
        return minimumSpeechRate + progress * (maximumSpeechRate - minimumSpeechRate)
    }

    static func displaySpeed(forSpeechRate value: Double) -> Double {
        let clampedValue = clampSpeechRate(value)
        let progress = (clampedValue - minimumSpeechRate) / (maximumSpeechRate - minimumSpeechRate)
        return minimumDisplaySpeed + progress * (maximumDisplaySpeed - minimumDisplaySpeed)
    }

    static func displaySpeedLabel(forSpeechRate value: Double) -> String {
        let displaySpeed = displaySpeed(forSpeechRate: value)
        return "\(displaySpeed.formatted(.number.precision(.fractionLength(2))))x"
    }

    static func outputVolumeLabel(for value: Double) -> String {
        let percentage = Int((clampOutputVolume(value) * 100).rounded())
        return "\(percentage)%"
    }
}

enum RelayBellBehavior: String, CaseIterable, Identifiable {
    case off
    case haptic
    case visual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .haptic:
            return "Haptic"
        case .visual:
            return "Visual"
        }
    }
}

struct RelayPreferences {
    static let shared = RelayPreferences()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    var usesSavedKeysAutomatically: Bool {
        defaults.object(forKey: RelayDefaultsKey.useSavedKeysAutomatically) as? Bool ?? true
    }

    var allowsPasswordFallback: Bool {
        defaults.object(forKey: RelayDefaultsKey.allowPasswordFallback) as? Bool ?? true
    }

    var connectionTimeoutSeconds: Int {
        let storedValue = defaults.object(forKey: RelayDefaultsKey.connectionTimeoutSeconds) as? Int ?? 12
        return min(max(storedValue, 5), 60)
    }

    var terminalFontSize: Double {
        let storedValue = defaults.object(forKey: RelayDefaultsKey.terminalFontSize) as? Double ?? RelayTerminalFontSizePreference.defaultSize
        return RelayTerminalFontSizePreference.clamp(storedValue)
    }

    var bellBehavior: RelayBellBehavior {
        guard let rawValue = defaults.string(forKey: RelayDefaultsKey.bellBehavior),
              let behavior = RelayBellBehavior(rawValue: rawValue) else {
            return .haptic
        }

        return behavior
    }

    var keepsScreenAwake: Bool {
        defaults.object(forKey: RelayDefaultsKey.keepScreenAwake) as? Bool ?? true
    }

    var automaticallyReconnects: Bool {
        defaults.object(forKey: RelayDefaultsKey.automaticallyReconnect) as? Bool ?? true
    }

    var voiceSpeechRate: Double {
        let storedValue = defaults.object(forKey: RelayDefaultsKey.voiceSpeechRate) as? Double ?? RelayVoicePreference.defaultSpeechRate
        return RelayVoicePreference.clampSpeechRate(storedValue)
    }

    var voiceOutputVolume: Double {
        let storedValue = defaults.object(forKey: RelayDefaultsKey.voiceOutputVolume) as? Double ?? RelayVoicePreference.defaultOutputVolume
        return RelayVoicePreference.clampOutputVolume(storedValue)
    }

    var voiceSpeaksToolStatus: Bool {
        defaults.object(forKey: RelayDefaultsKey.voiceSpeaksToolStatus) as? Bool ?? false
    }

    var meshProviderKind: MeshProviderKind {
        guard let rawValue = defaults.string(forKey: RelayDefaultsKey.meshProviderKind),
              let kind = MeshProviderKind(rawValue: rawValue) else {
            return .tailscale
        }

        return kind
    }

    func reset() {
        RelayDefaultsKey.all.forEach { defaults.removeObject(forKey: $0) }
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            RelayDefaultsKey.useSavedKeysAutomatically: true,
            RelayDefaultsKey.allowPasswordFallback: true,
            RelayDefaultsKey.connectionTimeoutSeconds: 12,
            RelayDefaultsKey.terminalFontSize: RelayTerminalFontSizePreference.defaultSize,
            RelayDefaultsKey.bellBehavior: RelayBellBehavior.haptic.rawValue,
            RelayDefaultsKey.keepScreenAwake: true,
            RelayDefaultsKey.automaticallyReconnect: true,
            RelayDefaultsKey.voiceSpeechRate: RelayVoicePreference.defaultSpeechRate,
            RelayDefaultsKey.voiceOutputVolume: RelayVoicePreference.defaultOutputVolume,
            RelayDefaultsKey.voiceSpeaksToolStatus: false,
            RelayDefaultsKey.meshProviderKind: MeshProviderKind.tailscale.rawValue,
            RelayDefaultsKey.relayServerURL: "",
            RelayDefaultsKey.relayAllowInsecureTLS: false,
        ])
    }
}
