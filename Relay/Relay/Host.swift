//
//  Host.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

struct Host: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
    }
}

extension Host {
    static let samples = [
        Host(name: "Production", hostname: "prod.example.com", username: "deploy"),
        Host(name: "Staging", hostname: "staging.example.com", username: "deploy"),
        Host(name: "Lab", hostname: "192.168.1.40", username: "ryan"),
    ]
}
