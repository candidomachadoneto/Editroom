import AVFoundation
import Foundation

/// Low-latency full-duplex audio engine for Grok Voice 3.0 (`audio/pcm` 24kHz mono 16-bit LE).
/// Captures microphone chunks immediately (in parallel with WebSocket handshake), streams
/// incoming assistant PCM chunks to speaker output as soon as they arrive, and supports
/// instant barge-in interruption (`interruptPlayback()`).
final class VoiceAudioIO: @unchecked Sendable {
    static let wireSampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let lock = NSLock()
    private var captureActive = false
    private var engineRunning = false
    private var converter: AVAudioConverter?
    private var pendingBuffers = 0
    private var playbackFormat: AVAudioFormat?
    private var speechSynth: AVSpeechSynthesizer?

    /// PCM16 24kHz mono chunks captured from the microphone.
    var onCapturedPCM: ((Data) -> Void)?
    /// Fires when speaker playback transitions between playing audio and drained/silent.
    var onPlaybackStateChanged: ((Bool) -> Void)?

    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: VoiceAudioIO.wireSampleRate,
        channels: 1,
        interleaved: true
    )!

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
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "VoiceAudioIO", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Nenhum microfone ativo encontrado neste Mac."
            ])
        }

        // Convert hardware mic format (typically 48kHz Float32) -> 24kHz Int16 mono PCM.
        let monoInputFormat = AVAudioFormat(
            commonFormat: hwFormat.commonFormat,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: hwFormat.isInterleaved
        ) ?? hwFormat
        let conv = AVAudioConverter(from: hwFormat, to: wireFormat)
            ?? AVAudioConverter(from: monoInputFormat, to: wireFormat)
        converter = conv

        // ~40ms buffer size at hardware sample rate for ultra-low latency streaming.
        let tapFrames = AVAudioFrameCount(max(512, Int(hwFormat.sampleRate * 0.04)))
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: tapFrames, format: hwFormat) { [weak self] buffer, _ in
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
        }
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

    /// Speaks a short Portuguese fallback notice locally if the xAI WebSocket drops (Requirement 4.3).
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

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let active = captureActive
        let conv = converter
        lock.unlock()
        guard active, let conv else { return }

        let ratio = Self.wireSampleRate / max(1, buffer.format.sampleRate)
        let outCap = AVAudioFrameCount(max(64, ceil(Double(buffer.frameLength) * ratio) + 16))
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: outCap) else { return }

        var provided = false
        var error: NSError?
        let status = conv.convert(to: outBuf, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, outBuf.frameLength > 0,
              let ptr = outBuf.int16ChannelData?[0] else { return }

        let byteCount = Int(outBuf.frameLength) * MemoryLayout<Int16>.size
        let pcmData = Data(bytes: ptr, count: byteCount)
        onCapturedPCM?(pcmData)
    }
}
