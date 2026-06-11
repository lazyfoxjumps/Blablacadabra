import AVFoundation

/// Combines two audio sources (system audio + mic) into one pipeline-format
/// stream by summing sample-aligned floats, so "caption the video AND the
/// people in the room" is one source as far as the pipeline cares.
///
/// Both lanes produce continuous buffers (SCStream and the mic tap both emit
/// silence as real zero samples), so mixing drains in lockstep: whenever both
/// lanes hold at least one mix frame, sum and emit. If one lane stalls
/// outright (device yanked, engine died), the other flows solo after a short
/// backlog so captions never freeze waiting for a dead lane.
public final class MixedAudioSource: AudioSource {
    private let sources: [AudioSource]
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var pumps: [Task<Void, Never>] = []
    private let mixer = Mixer()

    public init(_ first: AudioSource, _ second: AudioSource) {
        sources = [first, second]
    }

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard pumps.isEmpty else { throw AudioCaptureError.alreadyRunning }

        let firstStream = try await sources[0].start()
        let secondStream: AsyncStream<AVAudioPCMBuffer>
        do {
            secondStream = try await sources[1].start()
        } catch {
            await sources[0].stop()
            throw error
        }

        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.stop() }
            }
        }

        for (lane, upstream) in [firstStream, secondStream].enumerated() {
            pumps.append(Task { [weak self] in
                for await buffer in upstream {
                    guard let self else { return }
                    for mixed in await self.mixer.ingest(buffer, lane: lane) {
                        self.continuation?.yield(mixed)
                    }
                }
                // One lane ending (permission revoked, device gone) ends the
                // mix; the pipeline treats it like any source finishing.
                guard let self else { return }
                if let tail = await self.mixer.flush() {
                    self.continuation?.yield(tail)
                }
                self.continuation?.finish()
            })
        }

        return stream
    }

    public func stop() async {
        for source in sources {
            await source.stop()
        }
        for pump in pumps {
            await pump.value
        }
        pumps = []
        continuation?.finish()
        continuation = nil
    }

    private actor Mixer {
        /// 0.1 s at 16 kHz per emitted buffer.
        private let frameSize = 1_600
        /// A lane this far ahead (1 s) of a silent partner flows solo.
        private let soloBacklog = 16_000
        private var lanes: [[Float]] = [[], []]

        func ingest(_ buffer: AVAudioPCMBuffer, lane: Int) -> [AVAudioPCMBuffer] {
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
            lanes[lane].append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))

            var out: [AVAudioPCMBuffer] = []
            while min(lanes[0].count, lanes[1].count) >= frameSize {
                var mixed = [Float](repeating: 0, count: frameSize)
                for i in 0..<frameSize {
                    mixed[i] = max(-1, min(1, lanes[0][i] + lanes[1][i]))
                }
                lanes[0].removeFirst(frameSize)
                lanes[1].removeFirst(frameSize)
                if let pcm = Self.pipelineBuffer(mixed) { out.append(pcm) }
            }

            // Stalled-partner guard: my backlog is a second deep and the other
            // lane has nothing to pair it with, so stop waiting and flow solo.
            let other = 1 - lane
            while lanes[lane].count >= soloBacklog && lanes[other].count < frameSize {
                let solo = Array(lanes[lane].prefix(frameSize))
                lanes[lane].removeFirst(frameSize)
                if let pcm = Self.pipelineBuffer(solo) { out.append(pcm) }
            }
            return out
        }

        /// Emits whatever is left (summed where overlapping) when a lane ends.
        func flush() -> AVAudioPCMBuffer? {
            let count = max(lanes[0].count, lanes[1].count)
            guard count > 0 else { return nil }
            var mixed = [Float](repeating: 0, count: count)
            for lane in lanes {
                for (i, sample) in lane.enumerated() {
                    mixed[i] = max(-1, min(1, mixed[i] + sample))
                }
            }
            lanes = [[], []]
            return Self.pipelineBuffer(mixed)
        }

        private static func pipelineBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: AudioPipelineFormat.format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ), let channel = pcm.floatChannelData else { return nil }
            pcm.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                channel[0].update(from: src.baseAddress!, count: samples.count)
            }
            return pcm
        }
    }
}
