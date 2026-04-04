//
//  VoiceCallManager.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class VoiceCallManager {
    struct CallSession: Identifiable {
        let id: UUID
        let viewModel: VoiceSessionViewModel
        let startedAt: Date

        init(viewModel: VoiceSessionViewModel) {
            self.id = viewModel.id
            self.viewModel = viewModel
            self.startedAt = Date()
        }
    }

    var calls: [CallSession] = []
    var selectedCallID: CallSession.ID?

    var hasActiveCalls: Bool {
        !calls.isEmpty
    }

    var selectedCall: CallSession? {
        guard let selectedCallID else { return nil }
        return calls.first(where: { $0.id == selectedCallID })
    }

    func startCall(configuration: VoiceSessionConfiguration) {
        let viewModel = VoiceSessionViewModel(configuration: configuration)
        let session = CallSession(viewModel: viewModel)
        calls.append(session)
        selectedCallID = session.id

        Task { [weak self] in
            guard let self else { return }
            await self.applyAudioFocus()
            await viewModel.startIfNeeded()
            await self.applyAudioFocus()
        }
    }

    func selectCall(_ id: CallSession.ID) {
        guard selectedCallID != id else { return }
        guard calls.contains(where: { $0.id == id }) else { return }

        selectedCallID = id
        Task { [weak self] in
            await self?.applyAudioFocus()
        }
    }

    func endCall(_ id: CallSession.ID) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }

        let endingSession = calls.remove(at: index)
        if selectedCallID == id {
            selectedCallID = calls.indices.contains(index) ? calls[index].id : calls.last?.id
        }

        Task { [weak self] in
            await endingSession.viewModel.setForegroundActive(false)
            await self?.applyAudioFocus()
            await endingSession.viewModel.end()
        }
    }

    private func applyAudioFocus() async {
        let selectedID = selectedCallID

        for session in calls where session.id != selectedID {
            await session.viewModel.setForegroundActive(false)
        }

        guard let selectedSession = calls.first(where: { $0.id == selectedID }) else { return }
        await selectedSession.viewModel.setForegroundActive(true)
    }
}
