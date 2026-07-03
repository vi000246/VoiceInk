import Foundation
import AVFoundation
import Accelerate
import os

class AudioProcessor {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioProcessor")
    
    struct AudioFormat {
        static let targetSampleRate: Double = 16000.0
        static let targetChannels: UInt32 = 1
        static let targetBitDepth: UInt32 = 16
    }
    
    enum AudioProcessingError: LocalizedError {
        case invalidAudioFile
        case conversionFailed
        case exportFailed
        case unsupportedFormat
        case sampleExtractionFailed
        
        var errorDescription: String? {
            switch self {
            case .invalidAudioFile:
                return String(localized: "The audio file is invalid or corrupted")
            case .conversionFailed:
                return String(localized: "Failed to convert the audio format")
            case .exportFailed:
                return String(localized: "Failed to export the processed audio")
            case .unsupportedFormat:
                return String(localized: "The audio format is not supported")
            case .sampleExtractionFailed:
                return String(localized: "Failed to extract audio samples")
            }
        }
    }
    
    func processAudioToSamples(_ url: URL) async throws -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            throw AudioProcessingError.invalidAudioFile
        }
        
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let channels = format.channelCount
        let totalFrames = audioFile.length
        
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.targetSampleRate,
            channels: AudioFormat.targetChannels,
            interleaved: false
        )
        
        guard let outputFormat = outputFormat else {
            throw AudioProcessingError.unsupportedFormat
        }
        
        // ~22 s @ 48 kHz per read: bounds peak memory to a few MB per buffer instead of
        // materializing the whole decoded file (the previous 50M-frame "chunk").
        let chunkSize: AVAudioFrameCount = 1_048_576
        let needsConversion = !(sampleRate == AudioFormat.targetSampleRate && channels == AudioFormat.targetChannels)
        let ratio = AudioFormat.targetSampleRate / sampleRate

        // One converter for the whole file: its resampler state carries across chunks, so
        // chunk boundaries don't lose the filter tail (a fresh converter per chunk did).
        var converter: AVAudioConverter?
        if needsConversion {
            guard let created = AVAudioConverter(from: format, to: outputFormat) else {
                throw AudioProcessingError.conversionFailed
            }
            converter = created
        }

        var allSamples: [Float] = []
        allSamples.reserveCapacity(Int(Double(totalFrames) * (needsConversion ? ratio : 1)) + 1024)
        var currentFrame: AVAudioFramePosition = 0

        while currentFrame < totalFrames {
            let remainingFrames = totalFrames - currentFrame
            let framesToRead = min(chunkSize, AVAudioFrameCount(remainingFrames))

            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw AudioProcessingError.conversionFailed
            }

            audioFile.framePosition = currentFrame
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)
            currentFrame += AVAudioFramePosition(framesToRead)

            if let converter {
                let isLastChunk = currentFrame >= totalFrames
                let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64

                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
                    throw AudioProcessingError.conversionFailed
                }

                var error: NSError?
                var consumedInput = false
                let status = converter.convert(
                    to: outputBuffer,
                    error: &error,
                    withInputFrom: { _, outStatus in
                        // Hand the chunk over exactly once; afterwards tell the converter to wait
                        // for the next chunk (or drain, at end of file).
                        if consumedInput {
                            outStatus.pointee = isLastChunk ? .endOfStream : .noDataNow
                            return nil
                        }
                        consumedInput = true
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                )

                if error != nil || status == .error {
                    throw AudioProcessingError.conversionFailed
                }

                appendMonoSamples(from: outputBuffer, to: &allSamples)
            } else {
                appendMonoSamples(from: inputBuffer, to: &allSamples)
            }
        }

        normalizeInPlace(&allSamples)
        return allSamples
    }

    /// Mixes the buffer down to mono and appends it — no per-chunk normalization (gain is applied
    /// once, globally, in `normalizeInPlace`; per-chunk peaks gave each chunk a different gain).
    private func appendMonoSamples(from buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        if channelCount == 1 {
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))
        } else {
            var mixed = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            for channel in 1..<channelCount {
                vDSP_vadd(mixed, 1, channelData[channel], 1, &mixed, 1, vDSP_Length(frameLength))
            }
            var scale = 1 / Float(channelCount)
            vDSP_vsmul(mixed, 1, &scale, &mixed, 1, vDSP_Length(frameLength))
            samples.append(contentsOf: mixed)
        }
    }

    /// Peak-normalizes in place with a single vectorized pass (the old `.map(abs).max()` +
    /// `.map { $0 / max }` allocated two full-size throwaway arrays).
    private func normalizeInPlace(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 0 else { return }
        var scale = 1 / peak
        vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(samples.count))
    }
    func saveSamplesAsWav(samples: [Float], to url: URL) throws {
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioFormat.targetSampleRate,
            channels: AudioFormat.targetChannels,
            interleaved: true
        )

        guard let outputFormat = outputFormat else {
            throw AudioProcessingError.unsupportedFormat
        }

        let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        )
        
        guard let buffer = buffer else {
            throw AudioProcessingError.conversionFailed
        }
        
        // Convert float samples to int16
        let int16Samples = samples.map { max(-1.0, min(1.0, $0)) * Float(Int16.max) }.map { Int16($0) }

        // Copy samples to buffer
        int16Samples.withUnsafeBufferPointer { int16Buffer in
            let int16Pointer = int16Buffer.baseAddress!
            buffer.int16ChannelData![0].update(from: int16Pointer, count: int16Samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Create audio file
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        try audioFile.write(from: buffer)
    }
} 
