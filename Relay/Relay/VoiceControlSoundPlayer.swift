//
//  VoiceControlSoundPlayer.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import AVFoundation

@MainActor
final class VoiceControlSoundPlayer: NSObject {
    private static let cuePlaybackVolume: Float = 0.46

    fileprivate struct CueSegment {
        let startFrequency: Double
        let endFrequency: Double
        let duration: Double
        let gain: Double

        static func tone(_ startFrequency: Double, _ endFrequency: Double, duration: Double, gain: Double) -> CueSegment {
            CueSegment(
                startFrequency: startFrequency,
                endFrequency: endFrequency,
                duration: duration,
                gain: gain
            )
        }

        static func silence(duration: Double) -> CueSegment {
            CueSegment(
                startFrequency: 0,
                endFrequency: 0,
                duration: duration,
                gain: 0
            )
        }
    }

    enum Cue {
        case mute
        case unmute

        fileprivate var segments: [CueSegment] {
            switch self {
            case .mute:
                return [
                    .tone(622, 587, duration: 0.05, gain: 0.72),
                    .silence(duration: 0.014),
                    .tone(523, 466, duration: 0.09, gain: 0.58),
                ]
            case .unmute:
                return [
                    .tone(466, 523, duration: 0.052, gain: 0.62),
                    .silence(duration: 0.014),
                    .tone(587, 659, duration: 0.095, gain: 0.82),
                ]
            }
        }
    }

    private static let muteData = makeWAVData(for: .mute)
    private static let unmuteData = makeWAVData(for: .unmute)

    private var player: AVAudioPlayer?
    private var completion: (() -> Void)?

    func play(_ cue: Cue, completion: (() -> Void)? = nil) {
        stop()

        do {
            let player = try AVAudioPlayer(data: data(for: cue))
            player.volume = Self.cuePlaybackVolume
            player.delegate = self
            player.prepareToPlay()

            self.player = player
            self.completion = completion

            guard player.play() else {
                finishPlayback()
                return
            }
        } catch {
            finishPlayback()
        }
    }

    func playAndWait(_ cue: Cue) async {
        await withCheckedContinuation { continuation in
            play(cue) {
                continuation.resume()
            }
        }
    }

    func stop() {
        guard player != nil || completion != nil else { return }
        player?.stop()
        finishPlayback()
    }

    private func data(for cue: Cue) -> Data {
        switch cue {
        case .mute:
            Self.muteData
        case .unmute:
            Self.unmuteData
        }
    }

    private func finishPlayback() {
        player?.delegate = nil
        player = nil

        let completion = completion
        self.completion = nil
        completion?()
    }

    private static func makeWAVData(for cue: Cue) -> Data {
        let sampleRate = 44_100.0
        let amplitude = 0.24
        let attackRatio = 0.22
        let releaseRatio = 0.34

        var samples: [Int16] = []
        var fundamentalPhase = 0.0
        var secondHarmonicPhase = 0.0
        var thirdHarmonicPhase = 0.0

        for segment in cue.segments {
            let frameCount = max(Int(sampleRate * segment.duration), 1)
            let progressDivisor = Double(max(frameCount - 1, 1))

            for frame in 0..<frameCount {
                let progress = Double(frame) / progressDivisor
                let attack = min(progress / attackRatio, 1)
                let release = min((1 - progress) / releaseRatio, 1)
                let envelope = min(attack, release)
                let easedProgress = easeInOut(progress)
                let frequency = segment.startFrequency + ((segment.endFrequency - segment.startFrequency) * easedProgress)

                let sampleValue: Double
                if frequency == 0 || segment.gain == 0 {
                    sampleValue = 0
                } else {
                    let phaseStep = (2 * .pi * frequency) / sampleRate
                    fundamentalPhase += phaseStep
                    secondHarmonicPhase += phaseStep * 2
                    thirdHarmonicPhase += phaseStep * 3

                    let tone =
                        (sin(fundamentalPhase) * 0.78) +
                        (sin(secondHarmonicPhase) * 0.16) +
                        (sin(thirdHarmonicPhase) * 0.06)

                    sampleValue = tone * amplitude * envelope * segment.gain
                }

                let clamped = max(-1.0, min(1.0, sampleValue))
                samples.append(Int16(clamped * Double(Int16.max)))
            }
        }

        return wavData(
            from: samples,
            sampleRate: UInt32(sampleRate),
            channelCount: 1,
            bitsPerSample: 16
        )
    }

    private static func easeInOut(_ value: Double) -> Double {
        0.5 - (cos(value * .pi) / 2)
    }

    private static func wavData(
        from samples: [Int16],
        sampleRate: UInt32,
        channelCount: UInt16,
        bitsPerSample: UInt16
    ) -> Data {
        let blockAlign = channelCount * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(samples.count * Int(blockAlign))
        let riffChunkSize = 36 + dataSize

        var data = Data()
        data.appendASCII("RIFF")
        data.appendUInt32(riffChunkSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32(16)
        data.appendUInt16(1)
        data.appendUInt16(channelCount)
        data.appendUInt32(sampleRate)
        data.appendUInt32(byteRate)
        data.appendUInt16(blockAlign)
        data.appendUInt16(bitsPerSample)
        data.appendASCII("data")
        data.appendUInt32(dataSize)

        for sample in samples {
            data.appendInt16(sample)
        }

        return data
    }
}

extension VoiceControlSoundPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishPlayback()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishPlayback()
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt16(_ value: Int16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
