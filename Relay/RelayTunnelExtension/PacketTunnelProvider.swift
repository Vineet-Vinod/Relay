//
//  PacketTunnelProvider.swift
//  RelayTunnelExtension
//
//  Created by Codex on 4/4/26.
//

import NetworkExtension
import OSLog
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "rybkr.Relay", category: "RelayTunnel")

    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { [weak self] logLevel, message in
            self?.log(message, level: logLevel)
        }
    }()

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            let relayConfiguration = try RelayTunnelProviderConfiguration.load(
                from: protocolConfiguration as? NETunnelProviderProtocol
            )
            let tunnelConfiguration = try relayConfiguration.makeWireGuardConfiguration()

            adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] error in
                if let error {
                    self?.logger.error("Failed to start Relay tunnel: \(error.localizedDescription, privacy: .public)")
                    completionHandler(error)
                    return
                }

                self?.logger.info("Relay tunnel started")
                completionHandler(nil)
            }
        } catch {
            logger.error("Failed to prepare Relay tunnel: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        adapter.stop { [weak self] error in
            if let error {
                self?.logger.error("Failed to stop Relay tunnel cleanly: \(error.localizedDescription, privacy: .public)")
            } else {
                self?.logger.info("Relay tunnel stopped")
            }

            completionHandler()
        }
    }

    private func log(_ message: String, level: WireGuardLogLevel) {
        switch level {
        case .verbose:
            logger.debug("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}
