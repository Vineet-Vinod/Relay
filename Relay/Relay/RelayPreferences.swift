//
//  RelayPreferences.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

enum RelayDefaultsKey {
    static let useSavedKeysAutomatically = "relay.preferences.use-saved-keys-automatically.v1"
    static let allowPasswordFallback = "relay.preferences.allow-password-fallback.v1"
    static let connectionTimeoutSeconds = "relay.preferences.connection-timeout-seconds.v1"
    static let terminalFontSize = "relay.preferences.terminal-font-size.v1"
    static let bellBehavior = "relay.preferences.bell-behavior.v1"
    static let keepScreenAwake = "relay.preferences.keep-screen-awake.v1"
    static let automaticallyReconnect = "relay.preferences.automatically-reconnect.v1"

    static let all = [
        useSavedKeysAutomatically,
        allowPasswordFallback,
        connectionTimeoutSeconds,
        terminalFontSize,
        bellBehavior,
        keepScreenAwake,
        automaticallyReconnect,
    ]
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
        let storedValue = defaults.object(forKey: RelayDefaultsKey.terminalFontSize) as? Double ?? 14
        return min(max(storedValue, 11), 22)
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

    func reset() {
        RelayDefaultsKey.all.forEach { defaults.removeObject(forKey: $0) }
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            RelayDefaultsKey.useSavedKeysAutomatically: true,
            RelayDefaultsKey.allowPasswordFallback: true,
            RelayDefaultsKey.connectionTimeoutSeconds: 12,
            RelayDefaultsKey.terminalFontSize: 14.0,
            RelayDefaultsKey.bellBehavior: RelayBellBehavior.haptic.rawValue,
            RelayDefaultsKey.keepScreenAwake: true,
            RelayDefaultsKey.automaticallyReconnect: true,
        ])
    }
}
