//
//  RelayNetworking.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import OSLog

struct RelayServerErrorEnvelope: Codable {
    let error: String
}

enum RelayURLSessionFactory {
    static func makeSession(allowInsecureTLS: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(
            configuration: configuration,
            delegate: RelayNetworkSessionDelegate(allowInsecureTLS: allowInsecureTLS),
            delegateQueue: nil
        )
    }
}

final class RelayNetworkSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    private let allowInsecureTLS: Bool
    private let logger = Logger(subsystem: "Relay", category: "RelayNetworking")

    init(allowInsecureTLS: Bool) {
        self.allowInsecureTLS = allowInsecureTLS
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        logger.info("Relay websocket opened using protocol \(String(describing: `protocol`), privacy: .public)")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        logger.info("Relay websocket closed code=\(closeCode.rawValue, privacy: .public) reason=\(reasonText, privacy: .public)")
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleTLSChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleTLSChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleTLSChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowInsecureTLS,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        logger.info("Allowing insecure TLS for Relay host \(challenge.protectionSpace.host, privacy: .public)")
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

func mapRelayTransportError(
    _ error: Error,
    serverURL: URL?,
    operation: String
) -> RelaySessionError {
    if let relayError = error as? RelaySessionError {
        return relayError
    }

    let hostLabel = serverURL?.host ?? "the Relay server"
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else {
        return .connectionFailed("Relay couldn't complete \(operation).")
    }
    let code = URLError.Code(rawValue: nsError.code)

    switch code {
    case .cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .resourceUnavailable:
        return .serverOffline("Relay couldn't reach \(hostLabel). Make sure the Relay server is running and reachable from this iPhone.")
    case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .serverCertificateUntrusted:
        return .connectionFailed("Relay couldn't verify the server certificate. If you're using a local development certificate, enable Allow Self-Signed TLS in Settings.")
    case .cancelled:
        return .connectionFailed("Relay cancelled \(operation).")
    default:
        return .connectionFailed("Relay couldn't complete \(operation).")
    }
}
