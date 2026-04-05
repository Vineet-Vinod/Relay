//
//  SessionWorkspaceManager.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import Observation

enum SessionWorkspaceTabKind: Hashable {
    case terminal
    case voice
}

struct SessionWorkspaceTab: Identifiable {
    let id: UUID
    let kind: SessionWorkspaceTabKind
    let startedAt: Date
    let terminalSessionViewModel: TerminalSessionViewModel?
    let voiceSessionViewModel: VoiceSessionViewModel?

    init(host: Host) {
        self.id = UUID()
        self.kind = .terminal
        self.startedAt = Date()
        self.terminalSessionViewModel = TerminalSessionViewModel(host: host)
        self.voiceSessionViewModel = nil
    }

    init(configuration: VoiceSessionConfiguration) {
        let viewModel = VoiceSessionViewModel(configuration: configuration)
        self.id = viewModel.id
        self.kind = .voice
        self.startedAt = Date()
        self.terminalSessionViewModel = nil
        self.voiceSessionViewModel = viewModel
    }

    var title: String {
        switch kind {
        case .terminal:
            return terminalSessionViewModel?.host.name ?? "Terminal"
        case .voice:
            return voiceSessionViewModel?.title ?? "Voice Call"
        }
    }

    var subtitle: String {
        switch kind {
        case .terminal:
            guard let host = terminalSessionViewModel?.host else { return "" }
            return "\(host.username)@\(host.hostname)"
        case .voice:
            return voiceSessionViewModel?.resolvedWorkspacePath ?? ""
        }
    }
}

@MainActor
@Observable
final class SessionWorkspaceManager {
    var tabs: [SessionWorkspaceTab] = []
    var selectedTabID: SessionWorkspaceTab.ID?

    var hasTabs: Bool {
        !tabs.isEmpty
    }

    var selectedTab: SessionWorkspaceTab? {
        guard let selectedTabID else { return nil }
        return tabs.first(where: { $0.id == selectedTabID })
    }

    func openTerminalTab(for host: Host) {
        let tab = SessionWorkspaceTab(host: host)
        tabs.append(tab)
        selectedTabID = tab.id
        refreshVoiceFocus()
    }

    func openVoiceTab(configuration: VoiceSessionConfiguration) {
        let tab = SessionWorkspaceTab(configuration: configuration)
        tabs.append(tab)
        selectedTabID = tab.id

        Task { [weak self] in
            guard let self else { return }
            await self.syncVoiceFocus()
            await tab.voiceSessionViewModel?.startIfNeeded()
            await self.syncVoiceFocus()
        }
    }

    func selectTab(_ tabID: SessionWorkspaceTab.ID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        guard selectedTabID != tabID else { return }

        selectedTabID = tabID
        refreshVoiceFocus()
    }

    @discardableResult
    func closeTab(id: SessionWorkspaceTab.ID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return tabs.isEmpty
        }

        let closingTab = tabs.remove(at: index)

        if selectedTabID == id {
            let nextIndex = min(index, tabs.count - 1)
            selectedTabID = tabs.indices.contains(nextIndex) ? tabs[nextIndex].id : nil
        }

        Task { [weak self] in
            switch closingTab.kind {
            case .terminal:
                await closingTab.terminalSessionViewModel?.disconnect()
            case .voice:
                await closingTab.voiceSessionViewModel?.setForegroundActive(false)
                await closingTab.voiceSessionViewModel?.end()
            }

            await self?.syncVoiceFocus()
        }

        return tabs.isEmpty
    }

    func refreshVoiceFocus() {
        Task { [weak self] in
            await self?.syncVoiceFocus()
        }
    }

    func suspendVoiceSessions() {
        Task { [weak self] in
            guard let self else { return }

            for tab in self.tabs {
                await tab.voiceSessionViewModel?.setForegroundActive(false)
            }
        }
    }

    private func syncVoiceFocus() async {
        for tab in tabs {
            let isSelected = tab.id == selectedTabID
            await tab.voiceSessionViewModel?.setForegroundActive(isSelected)
        }
    }
}
