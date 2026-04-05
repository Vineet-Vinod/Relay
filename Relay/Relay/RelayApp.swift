//
//  RelayApp.swift
//  Relay
//
//  Created by Ryan Baker on 4/4/26.
//

import SwiftUI
import OSLog

@main
struct RelayApp: App {
    private let logger = Logger(subsystem: "Relay", category: "App")

    init() {
        logger.info("Relay app init started")
        TerminalFontRegistry.registerBundledFonts()
        logger.info("Relay app init finished")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(RelayTheme.accent)
        }
    }
}
