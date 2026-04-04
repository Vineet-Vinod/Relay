//
//  VoiceAudioSessionCoordinator.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import AVFoundation
import UIKit

@MainActor
final class VoiceAudioSessionCoordinator {
    struct AudioRouteOption: Identifiable, Equatable {
        enum Kind: Equatable {
            case receiver
            case speaker
            case external
        }

        let id: String
        let name: String
        let detail: String
        let systemImage: String
        let kind: Kind
        let inputPortUID: String?

        static var receiver: AudioRouteOption {
            AudioRouteOption(
                id: "built-in-receiver",
                name: UIDevice.current.userInterfaceIdiom == .phone ? "Phone" : "Device",
                detail: "Built-in earpiece",
                systemImage: "phone.fill",
                kind: .receiver,
                inputPortUID: nil
            )
        }

        static var speaker: AudioRouteOption {
            AudioRouteOption(
                id: "built-in-speaker",
                name: "Speaker",
                detail: "Built-in speaker",
                systemImage: "speaker.wave.3.fill",
                kind: .speaker,
                inputPortUID: nil
            )
        }
    }

    private let session = AVAudioSession.sharedInstance()
    private var notificationObservers: [NSObjectProtocol] = []

    var availableRoutes: [AudioRouteOption] = [.receiver, .speaker]
    var selectedRoute: AudioRouteOption = .speaker
    var onRouteStateChanged: (([AudioRouteOption], AudioRouteOption) -> Void)?

    init() {
        refreshRouteState()
    }

    func activate() throws {
        if notificationObservers.isEmpty {
            registerForRouteChanges()
        }

        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [
                .allowBluetooth,
                .allowBluetoothA2DP,
            ]
        )
        try session.setActive(true, options: [])
        refreshRouteState()
        if selectedRoute.kind == .receiver {
            try? selectRoute(.speaker)
        }
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        removeRouteChangeObservers()
    }

    func selectRoute(_ route: AudioRouteOption) throws {
        switch route.kind {
        case .receiver:
            try session.overrideOutputAudioPort(.none)
            try setPreferredBuiltInMic()
        case .speaker:
            try session.overrideOutputAudioPort(.none)
            try setPreferredBuiltInMic()
            try session.overrideOutputAudioPort(.speaker)
        case .external:
            guard let inputPortUID = route.inputPortUID else {
                refreshRouteState()
                return
            }

            guard let preferredInput = session.availableInputs?.first(where: { $0.uid == inputPortUID }) else {
                throw VoiceAudioSessionError.routeUnavailable
            }

            try session.overrideOutputAudioPort(.none)
            try session.setPreferredInput(preferredInput)
        }

        refreshRouteState()
    }

    private func registerForRouteChanges() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ]

        notificationObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshRouteState()
            }
        }
    }

    private func removeRouteChangeObservers() {
        notificationObservers.forEach { observer in
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func refreshRouteState() {
        var routes = makeAvailableRoutes()
        let selected = currentSelectedRoute(from: routes)

        if !routes.contains(selected) {
            routes.insert(selected, at: min(1, routes.count))
        }

        availableRoutes = routes
        selectedRoute = selected
        onRouteStateChanged?(routes, selected)
    }

    private func makeAvailableRoutes() -> [AudioRouteOption] {
        var routes: [AudioRouteOption] = [.receiver, .speaker]
        let inputs = session.availableInputs ?? []

        for input in inputs where isSelectableExternalInput(input.portType) {
            let route = AudioRouteOption(
                id: "external-\(input.uid)",
                name: input.portName,
                detail: routeDetail(for: input.portType),
                systemImage: routeSymbol(for: input.portType),
                kind: .external,
                inputPortUID: input.uid
            )

            if !routes.contains(route) {
                routes.append(route)
            }
        }

        return routes
    }

    private func currentSelectedRoute(from availableRoutes: [AudioRouteOption]) -> AudioRouteOption {
        let outputs = session.currentRoute.outputs

        if outputs.contains(where: { $0.portType == .builtInSpeaker }) {
            return .speaker
        }

        if outputs.contains(where: { $0.portType == .builtInReceiver }) {
            return .receiver
        }

        if let currentOutput = outputs.first {
            if let matchingAvailableRoute = availableRoutes.first(where: { route in
                route.kind == .external && route.name == currentOutput.portName
            }) {
                return matchingAvailableRoute
            }

            if isSelectableExternalOutput(currentOutput.portType) {
                return AudioRouteOption(
                    id: "external-current-\(currentOutput.portName)-\(currentOutput.portType.rawValue)",
                    name: currentOutput.portName,
                    detail: routeDetail(for: currentOutput.portType),
                    systemImage: routeSymbol(for: currentOutput.portType),
                    kind: .external,
                    inputPortUID: nil
                )
            }
        }

        return .receiver
    }

    private func setPreferredBuiltInMic() throws {
        let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic })
        try session.setPreferredInput(builtInMic)
    }

    private func isSelectableExternalInput(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .bluetoothHFP, .bluetoothLE, .headsetMic, .usbAudio, .carAudio:
            return true
        default:
            return false
        }
    }

    private func isSelectableExternalOutput(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .headsetMic, .usbAudio, .carAudio:
            return true
        default:
            return false
        }
    }

    private func routeDetail(for portType: AVAudioSession.Port) -> String {
        switch portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return "Bluetooth audio"
        case .headphones, .headsetMic:
            return "Wired audio"
        case .usbAudio:
            return "USB audio"
        case .carAudio:
            return "Car audio"
        default:
            return "External audio"
        }
    }

    private func routeSymbol(for portType: AVAudioSession.Port) -> String {
        switch portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return "dot.radiowaves.left.and.right"
        case .headphones, .headsetMic:
            return "headphones"
        case .carAudio:
            return "car.fill"
        case .usbAudio:
            return "memorychip"
        default:
            return "speaker.wave.2.fill"
        }
    }
}

enum VoiceAudioSessionError: LocalizedError {
    case routeUnavailable

    var errorDescription: String? {
        switch self {
        case .routeUnavailable:
            return "That audio route is no longer available."
        }
    }
}
