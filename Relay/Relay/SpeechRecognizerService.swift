//
//  SpeechRecognizerService.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechRecognizerService {
    enum RecognitionEvent {
        case noSpeechDetected
        case cancelled
        case failure(String)
    }

    enum AuthorizationState: Equatable {
        case authorized
        case denied
        case restricted
        case unavailable
    }

    var onPartialTranscription: ((String) -> Void)?
    var onFinalTranscription: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onRecognitionEvent: ((RecognitionEvent) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isListening = false
    private var latestTranscript = ""
    private var ignoresRecognitionCallbacks = false

    var listening: Bool {
        isListening
    }

    func requestAuthorization() async -> AuthorizationState {
        guard speechRecognizer != nil else {
            return .unavailable
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                return .denied
            }
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }

        switch speechStatus {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func startListening() {
        guard !isListening else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            onError?("Speech recognition is unavailable right now.")
            return
        }

        stopListening()

        latestTranscript = ""
        ignoresRecognitionCallbacks = false
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            onError?(error.localizedDescription)
            teardownRecognition()
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            Task { @MainActor in
                guard !self.ignoresRecognitionCallbacks else { return }

                if let result {
                    let transcript = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !transcript.isEmpty {
                        self.latestTranscript = transcript
                        self.onPartialTranscription?(transcript)
                    }

                    if result.isFinal {
                        self.onFinalTranscription?(transcript)
                        self.stopListening()
                    }
                }

                if let error {
                    switch self.classifyRecognitionError(error) {
                    case .cancelled:
                        break
                    case .noSpeechDetected:
                        self.onRecognitionEvent?(.noSpeechDetected)
                    case .failure(let message):
                        self.onRecognitionEvent?(.failure(message))
                        self.onError?(message)
                    }
                    self.stopListening()
                }
            }
        }

        isListening = true
    }

    func finishListening() {
        guard isListening || recognitionTask != nil || audioEngine.isRunning else { return }

        let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        ignoresRecognitionCallbacks = true

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        teardownRecognition()

        if !transcript.isEmpty {
            onFinalTranscription?(transcript)
        }
    }

    func stopListening() {
        guard isListening || recognitionTask != nil || audioEngine.isRunning else {
            teardownRecognition()
            return
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        teardownRecognition()
    }

    private func teardownRecognition() {
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        latestTranscript = ""
        ignoresRecognitionCallbacks = false
    }

    private func classifyRecognitionError(_ error: Error) -> RecognitionEvent {
        let nsError = error as NSError
        let message = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.lowercased()

        if normalized.contains("request was canceled") || normalized.contains("was cancelled") {
            return .cancelled
        }

        if normalized.contains("no speech detected") {
            return .noSpeechDetected
        }

        if nsError.domain == "kAFAssistantErrorDomain" {
            switch nsError.code {
            case 203:
                return .cancelled
            case 1110:
                return .noSpeechDetected
            default:
                break
            }
        }

        return .failure(message.isEmpty ? nsError.localizedDescription : message)
    }
}
