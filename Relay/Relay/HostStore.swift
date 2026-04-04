//
//  HostStore.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

struct HostStore {
    let hosts: [Host]

    init(hosts: [Host] = Host.samples) {
        self.hosts = hosts
    }
}
