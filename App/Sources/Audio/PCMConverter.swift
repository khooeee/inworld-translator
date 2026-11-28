import AVFAudio
import Foundation
import Synchronization
import TranslatorCore

/// Converts tap buffers to 16 kHz mono PCM16 and cuts them into 100 ms chunks.
/// While the gate is muted, the audio is replaced with silence.
///
/// Used only from the audio tap, which runs its callbacks one at a time on a
/// single thread; the lock makes that assumption safe rather than relying on it.
final class PCMConverter: Sendable {
    private static let outputRate = 16_000.0
    private static let chunkSamples = 1600 // 100 ms

    private struct State: @unchecked Sendable {
        // AVAudioConverter and AVAudioPCMBuffer are not Sendable; they never
        // leave this lock.
        let converter: AVAudioConverter
        let output: AVAudioPCMBuffer
        var pending: [Int16] = []
        var peak: UInt16 = 0
    }

    private let state: Mutex<State>
    private let chunks: AsyncStream<AudioChunk>.Continuation
    private let gate: SpeechGate

    init?(from input: AVAudioFormat, chunks: AsyncStream<AudioChunk>.Continuation, gate: SpeechGate) {
        guard
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.outputRate, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: input, to: outputFormat),
            // Room for a 2048-frame tap buffer at up to 48 kHz, with margin.
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)
        else { return nil }
        state = Mutex(State(converter: converter, output: output))
        self.chunks = chunks
        self.gate = gate
    }

    /// The loudest microphone sample since the last call, before muting, from 0 to 1.
    func takePeak() -> Float {
        state.withLock { state in
            defer { state.peak = 0 }
            return Float(state.peak) / Float(Int16.max)
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) {
        // The tap's buffer is only valid during the callback; the converter
        // copies out of it synchronously below.
        nonisolated(unsafe) let input = buffer
        let ready: [Data] = state.withLock { state in
            var consumed = false
            var error: NSError?
            state.output.frameLength = 0
            let status = state.converter.convert(to: state.output, error: &error) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, let samples = state.output.int16ChannelData?[0] else { return [] }
            let count = Int(state.output.frameLength)
            let heard = UnsafeBufferPointer(start: samples, count: count)
            state.peak = max(state.peak, heard.lazy.map(\.magnitude).max() ?? 0)
            if gate.isMuted {
                state.pending.append(contentsOf: repeatElement(0, count: count))
            } else {
                state.pending.append(contentsOf: heard)
            }

            var ready: [Data] = []
            while state.pending.count >= Self.chunkSamples {
                let chunk = state.pending.prefix(Self.chunkSamples)
                ready.append(chunk.withUnsafeBytes { Data($0) })
                state.pending.removeFirst(Self.chunkSamples)
            }
            return ready
        }
        for pcm in ready {
            chunks.yield(AudioChunk(pcm: pcm, level: PCMFileAudioSource.level(of: pcm)))
        }
    }
}
