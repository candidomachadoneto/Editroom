import AVFoundation
import Foundation

/// Lightweight diagnostic logger for VoiceBridge (`~/Library/Logs/Editroom-VoiceBridge.log`).
/// Never logs secrets or API keys.
enum VoiceLog {
    private static let queue = DispatchQueue(label: "editroom.voicebridge.log")
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Editroom-VoiceBridge.log")
    }()

    static func info(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path),
               let fh = try? FileHandle(forWritingTo: url) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
                try? fh.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

/// Low-latency full-duplex audio engine for OpenAI / xAI Realtime (`audio/pcm` 24kHz mono 16-bit LE).
/// Directly reads channel 0 from the hardware / AEC-processed input tap and resamples cleanly to
/// 24kHz Int16 mono without relying on `AVAudioConverter` channel-layout heuristics (which zero out
/// 3-channel Voice Processing IO streams on Apple Silicon macOS).
final class VoiceAudioIO: @unchecked Sendable {
    static let wireSampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let lock = NSLock()
    private var captureActive = false
    private var engineRunning = false
    private var voiceProcessingConfigured = false
    private var pendingBuffers = 0
    private var playbackFormat: AVAudioFormat?
    private var speechSynth: AVSpeechSynthesizer?
    private var micChunksLogged = 0

    /// PCM16 24kHz mono chunks captured from the microphone.
    var onCapturedPCM: ((Data) -> Void)?
    /// Normalized peak level (0...1) from microphone input for live UI visual feedback.
    var onMicLevel: ((Float) -> Void)?
    /// Fires when speaker playback transitions between playing audio and drained/silent.
    var onPlaybackStateChanged: ((Bool) -> Void)?

    private let playFloatFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: VoiceAudioIO.wireSampleRate,
        channels: 1,
        interleaved: false
    )!

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playFloatFormat)
        playbackFormat = playFloatFormat
    }

    deinit {
        stopAll()
    }

    /// Requests macOS microphone permission cleanly on first use.
    static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    /// Starts microphone capture and prepares immediate speaker streaming.
    func startCapture() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !captureActive else { return }

        let inputNode = engine.inputNode
        if !voiceProcessingConfigured {
            // Enable macOS hardware Acoustic Echo Cancellation (AEC) so speaker voice doesn't re-trigger mic.
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                VoiceLog.info("AEC voice processing enabled")
            } catch {
                VoiceLog.info("AEC unavailable (falling back to standard mic): \(error.localizedDescription)")
            }
            voiceProcessingConfigured = true
        }
        let hwFormat = inputNode.outputFormat(forBus: 0)
        VoiceLog.info("Mic format: sr=\(hwFormat.sampleRate) ch=\(hwFormat.channelCount) fmt=\(hwFormat.commonFormat.rawValue) interleaved=\(hwFormat.isInterleaved)")
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "VoiceAudioIO", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Nenhum microfone ativo encontrado neste Mac."
            ])
        }

        micChunksLogged = 0
        let tapFrames = AVAudioFrameCount(max(512, Int(hwFormat.sampleRate * 0.04)))
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: tapFrames, format: nil) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
            engineRunning = true
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        captureActive = true
        VoiceLog.info("Audio engine started (captureActive=true)")
    }

    /// Stops microphone capture and clears any queued response audio.
    func stopAll() {
        lock.lock()
        let wasActive = captureActive || engineRunning
        captureActive = false
        pendingBuffers = 0
        lock.unlock()

        if wasActive {
            engine.inputNode.removeTap(onBus: 0)
            playerNode.stop()
            playerNode.reset()
            engine.stop()
            lock.lock()
            engineRunning = false
            lock.unlock()
            VoiceLog.info("Audio engine stopped")
        }
        onMicLevel?(0)
        onPlaybackStateChanged?(false)
    }

    /// Immediately stops response audio and drops all queued playback buffers (barge-in).
    func interruptPlayback() {
        lock.lock()
        let hadAudio = pendingBuffers > 0
        pendingBuffers = 0
        lock.unlock()

        playerNode.stop()
        playerNode.reset()
        if engine.isRunning {
            playerNode.play()
        }
        if hadAudio {
            onPlaybackStateChanged?(false)
        }
    }

    /// Plays an incoming PCM16 24kHz mono chunk immediately without waiting for the full response.
    func enqueuePCM16(_ data: Data) {
        let sampleCount = data.count / 2
        guard sampleCount > 0, let fmt = playbackFormat else { return }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)

        if let dst = pcmBuffer.floatChannelData?[0] {
            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Int16.self)
                let scale: Float = 1.0 / 32768.0
                for i in 0..<sampleCount {
                    dst[i] = Float(Int16(littleEndian: src[i])) * scale
                }
            }
        }

        if !engine.isRunning {
            try? engine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }

        lock.lock()
        let becameActive = pendingBuffers == 0
        pendingBuffers += 1
        lock.unlock()
        if becameActive {
            onPlaybackStateChanged?(true)
        }

        playerNode.scheduleBuffer(pcmBuffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingBuffers = max(0, self.pendingBuffers - 1)
            let finished = self.pendingBuffers == 0
            self.lock.unlock()
            if finished {
                self.onPlaybackStateChanged?(false)
            }
        }
    }

    /// Speaks a short Portuguese fallback notice locally if the WebSocket drops.
    func speakLocalFallback(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let synth = self.speechSynth ?? AVSpeechSynthesizer()
            self.speechSynth = synth
            synth.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "pt-BR")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
            synth.speak(utterance)
        }
    }

    /// Direct, zero-failure conversion from ANY hardware / VPIO channel layout -> 24kHz mono Int16 PCM.
    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let active = captureActive
        lock.unlock()
        guard active else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let srcRate = buffer.format.sampleRate
        guard srcRate > 0 else { return }

        // Read channel 0 directly (primary AEC-processed mic channel on macOS VPIO & standard mics).
        var floatSamples = [Float](repeating: 0, count: frameCount)
        var peak: Float = 0

        if let ch0 = buffer.floatChannelData?[0] {
            if buffer.format.isInterleaved {
                let stride = max(1, Int(buffer.format.channelCount))
                for i in 0..<frameCount {
                    let s = ch0[i * stride]
                    floatSamples[i] = s
                    peak = max(peak, abs(s))
                }
            } else {
                for i in 0..<frameCount {
                    let s = ch0[i]
                    floatSamples[i] = s
                    peak = max(peak, abs(s))
                }
            }
        } else if let ch0 = buffer.int16ChannelData?[0] {
            let stride = buffer.format.isInterleaved ? max(1, Int(buffer.format.channelCount)) : 1
            let scale: Float = 1.0 / 32768.0
            for i in 0..<frameCount {
                let s = Float(ch0[i * stride]) * scale
                floatSamples[i] = s
                peak = max(peak, abs(s))
            }
        } else {
            return
        }

        // Convert / linearly resample to 24,000 Hz Int16 Little-Endian mono.
        let outCount: Int
        var pcm16: [Int16]
        if abs(srcRate - Self.wireSampleRate) < 1.0 {
            outCount = frameCount
            pcm16 = [Int16](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let clamped = max(-1.0, min(1.0, floatSamples[i]))
                pcm16[i] = Int16((clamped * 32767.0).rounded()).littleEndian
            }
        } else {
            let ratio = srcRate / Self.wireSampleRate
            outCount = max(1, Int((Double(frameCount) / ratio).rounded()))
            pcm16 = [Int16](repeating: 0, count: outCount)
            let lastIdx = frameCount - 1
            for i in 0..<outCount {
                let pos = Double(i) * ratio
                let idx0 = min(lastIdx, Int(pos))
                let idx1 = min(lastIdx, idx0 + 1)
                let frac = Float(pos - Double(idx0))
                let sample = floatSamples[idx0] * (1 - frac) + floatSamples[idx1] * frac
                let clamped = max(-1.0, min(1.0, sample))
                pcm16[i] = Int16((clamped * 32767.0).rounded()).littleEndian
            }
        }

        let pcmData = pcm16.withUnsafeBytes { Data($0) }

        lock.lock()
        micChunksLogged += 1
        let count = micChunksLogged
        lock.unlock()
        if count == 1 || count == 25 {
            VoiceLog.info(String(format: "Mic chunk #%d: inFrames=%d outBytes=%d peak=%.4f", count, frameCount, pcmData.count, peak))
        }

        onMicLevel?(min(1, peak * 3.5))
        onCapturedPCM?(pcmData)
    }
}
