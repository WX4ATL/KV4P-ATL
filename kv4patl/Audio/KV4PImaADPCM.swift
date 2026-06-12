// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

protocol VoiceCodec {
    func encode(_ samples: [Float]) throws -> [Data]
    func decode(_ frame: Data) throws -> [Float]
    func decodePLC() throws -> [Float]
    func resetEncoder() throws
    func resetDecoder() throws
}

enum AudioCodecError: Error, LocalizedError {
    case converterUnavailable
    case encodeFailed
    case decodeFailed
    case playbackUnavailable
    case captureUnavailable

    var errorDescription: String? {
        switch self {
        case .converterUnavailable:
            "The IMA ADPCM voice codec is unavailable on this device."
        case .encodeFailed:
            "IMA ADPCM encode failed."
        case .decodeFailed:
            "IMA ADPCM decode failed."
        case .playbackUnavailable:
            "Audio playback is unavailable on this device right now."
        case .captureUnavailable:
            "Microphone capture is unavailable on this device right now."
        }
    }
}

enum KV4PVoice {
    static let engineSampleRate = 48_000.0
    static let codecSampleRate = 8_000.0
    static let frameDurationMS = 20
    static let engineFrameSize = 960
    static let codecFrameSize = 160
    static let encodedFrameSize = 84
    static let adpcmHeaderBytes = 4
    static let samplesPerCodecSample = engineFrameSize / codecFrameSize
}

final class IMAADPCMCodec: VoiceCodec {
    private let encoderLock = NSLock()
    private let decoderLock = NSLock()
    private var encoderStepIndex = 0
    private var frameSequence: UInt8 = 0
    private var decoderLastSample: Float = 0

    func encode(_ samples: [Float]) throws -> [Data] {
        encoderLock.lock()
        defer { encoderLock.unlock() }

        let pcm = downsampleToCodecPCM(samples)
        guard let firstSample = pcm.first else { throw AudioCodecError.encodeFailed }

        var predictor = Int(firstSample)
        var stepIndex = encoderStepIndex
        var encoded = Data(capacity: KV4PVoice.encodedFrameSize)
        encoded.appendLittleEndian(UInt16(bitPattern: firstSample))
        encoded.append(UInt8(max(0, min(Self.stepTable.count - 1, stepIndex))))
        encoded.append(frameSequence)

        var pendingLowNibble: UInt8?
        for sample in pcm.dropFirst() {
            let nibble = Self.encodeNibble(sample: sample, predictor: &predictor, stepIndex: &stepIndex)
            if let low = pendingLowNibble {
                encoded.append(low | (nibble << 4))
                pendingLowNibble = nil
            } else {
                pendingLowNibble = nibble
            }
        }
        if let low = pendingLowNibble {
            encoded.append(low)
        }

        guard encoded.count == KV4PVoice.encodedFrameSize else { throw AudioCodecError.encodeFailed }
        encoderStepIndex = stepIndex
        frameSequence &+= 1
        return [encoded]
    }

    func decode(_ frame: Data) throws -> [Float] {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        guard frame.count == KV4PVoice.encodedFrameSize else { throw AudioCodecError.decodeFailed }
        var predictor = Int(Int16(bitPattern: frame.uint16LE(at: 0)))
        var stepIndex = Int(frame[2])
        stepIndex = max(0, min(Self.stepTable.count - 1, stepIndex))
        var pcm = [Int16]()
        pcm.reserveCapacity(KV4PVoice.codecFrameSize)
        pcm.append(Self.clampInt16(predictor))

        var byteOffset = KV4PVoice.adpcmHeaderBytes
        while pcm.count < KV4PVoice.codecFrameSize, byteOffset < frame.count {
            let packed = frame[byteOffset]
            byteOffset += 1
            let lowNibble = packed & 0x0f
            pcm.append(Self.decodeNibble(lowNibble, predictor: &predictor, stepIndex: &stepIndex))
            if pcm.count < KV4PVoice.codecFrameSize {
                let highNibble = (packed >> 4) & 0x0f
                pcm.append(Self.decodeNibble(highNibble, predictor: &predictor, stepIndex: &stepIndex))
            }
        }

        guard pcm.count == KV4PVoice.codecFrameSize else { throw AudioCodecError.decodeFailed }
        let upsampled = upsampleToEnginePCM(pcm)
        decoderLastSample = upsampled.last ?? 0
        return upsampled
    }

    func decodePLC() throws -> [Float] {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        var samples = [Float](repeating: 0, count: KV4PVoice.engineFrameSize)
        var held = decoderLastSample
        for index in samples.indices {
            held *= 0.992
            samples[index] = held
        }
        decoderLastSample = held
        return samples
    }

    func resetEncoder() throws {
        encoderLock.lock()
        encoderStepIndex = 0
        frameSequence = 0
        encoderLock.unlock()
    }

    func resetDecoder() throws {
        decoderLock.lock()
        decoderLastSample = 0
        decoderLock.unlock()
    }

    private func downsampleToCodecPCM(_ samples: [Float]) -> [Int16] {
        var pcm = [Int16]()
        pcm.reserveCapacity(KV4PVoice.codecFrameSize)
        for codecIndex in 0..<KV4PVoice.codecFrameSize {
            let sourceStart = codecIndex * KV4PVoice.samplesPerCodecSample
            let sourceEnd = min(sourceStart + KV4PVoice.samplesPerCodecSample, samples.count)
            let averaged: Float
            if sourceStart < sourceEnd {
                var sum = Float(0)
                for sourceIndex in sourceStart..<sourceEnd {
                    sum += samples[sourceIndex]
                }
                averaged = sum / Float(sourceEnd - sourceStart)
            } else {
                averaged = 0
            }
            let clamped = max(-1, min(1, averaged))
            pcm.append(Int16(max(Int(Int16.min), min(Int(Int16.max), Int((clamped * Float(Int16.max)).rounded())))))
        }
        return pcm
    }

    private func upsampleToEnginePCM(_ pcm: [Int16]) -> [Float] {
        guard !pcm.isEmpty else {
            return [Float](repeating: 0, count: KV4PVoice.engineFrameSize)
        }

        var samples = [Float](repeating: 0, count: KV4PVoice.engineFrameSize)
        for codecIndex in 0..<KV4PVoice.codecFrameSize {
            let current = Float(pcm[codecIndex]) / 32_768.0
            let nextIndex = min(codecIndex + 1, pcm.count - 1)
            let next = Float(pcm[nextIndex]) / 32_768.0
            for subSample in 0..<KV4PVoice.samplesPerCodecSample {
                let fraction = Float(subSample) / Float(KV4PVoice.samplesPerCodecSample)
                samples[codecIndex * KV4PVoice.samplesPerCodecSample + subSample] = current + (next - current) * fraction
            }
        }
        return samples
    }

    private static func encodeNibble(sample: Int16, predictor: inout Int, stepIndex: inout Int) -> UInt8 {
        let step = stepTable[stepIndex]
        var diff = Int(sample) - predictor
        var nibble = 0
        if diff < 0 {
            nibble = 8
            diff = -diff
        }

        var delta = step >> 3
        if diff >= step {
            nibble |= 4
            diff -= step
            delta += step
        }
        if diff >= (step >> 1) {
            nibble |= 2
            diff -= step >> 1
            delta += step >> 1
        }
        if diff >= (step >> 2) {
            nibble |= 1
            delta += step >> 2
        }

        if (nibble & 8) != 0 {
            predictor -= delta
        } else {
            predictor += delta
        }
        predictor = max(Int(Int16.min), min(Int(Int16.max), predictor))
        stepIndex = max(0, min(stepTable.count - 1, stepIndex + indexTable[nibble & 0x0f]))
        return UInt8(nibble & 0x0f)
    }

    private static func decodeNibble(_ nibble: UInt8, predictor: inout Int, stepIndex: inout Int) -> Int16 {
        let step = stepTable[stepIndex]
        var delta = step >> 3
        if (nibble & 4) != 0 { delta += step }
        if (nibble & 2) != 0 { delta += step >> 1 }
        if (nibble & 1) != 0 { delta += step >> 2 }
        if (nibble & 8) != 0 {
            predictor -= delta
        } else {
            predictor += delta
        }
        predictor = max(Int(Int16.min), min(Int(Int16.max), predictor))
        stepIndex = max(0, min(stepTable.count - 1, stepIndex + indexTable[Int(nibble & 0x0f)]))
        return clampInt16(predictor)
    }

    private static func clampInt16(_ value: Int) -> Int16 {
        Int16(max(Int(Int16.min), min(Int(Int16.max), value)))
    }

    private static let indexTable = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8
    ]

    private static let stepTable = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
}
