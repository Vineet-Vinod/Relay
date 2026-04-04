//
//  RelayApp.swift
//  Relay
//
//  Created by Ryan Baker on 4/4/26.
//

import SwiftUI

@main
struct RelayApp: App {
    init() {
        TerminalFontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
