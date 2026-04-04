//
//  RelayJSONCoding.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

extension JSONEncoder {
    static let relay: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let relay: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
