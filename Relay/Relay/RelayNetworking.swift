//
//  RelayNetworking.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

struct RelayServerErrorEnvelope: Codable {
    let error: String
}

enum RelayURLSessionFactory {
    static func makeSession(allowInsecureTLS: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration,
            delegate: RelayNetworkSessionDelegate(allowInsecureTLS: allowInsecureTLS),
            delegateQueue: nil
        )
    }
}

final class RelayNetworkSessionDelegate: NSObject, URLSessionDelegate {
    private let allowInsecureTLS: Bool

    init(allowInsecureTLS: Bool) {
        self.allowInsecureTLS = allowInsecureTLS
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowInsecureTLS,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
