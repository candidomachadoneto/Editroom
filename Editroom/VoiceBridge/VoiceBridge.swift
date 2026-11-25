import Combine
import Foundation

/// Public states observed by the Magic button UI.
enum VoiceBridgeState: Equatable {
    case idle
    case listening
    case speaking
    case error(String)

    var isActive: Bool {
        switch self {
        case .listening, .speaking: return true
        case .idle, .error: return false
        }
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

/// Self-contained VoiceBridge module (Grok Voice 3.0 Realtime + Local EditDSL Swarm HTTP).
/// The Magic UI button only calls `start()`, `stop()`, `toggle()`, and observes `state`.
/// Never calls internal Editroom editing APIs: every edit goes strictly through the local Swarm daemon.
@MainActor
final class VoiceBridge: ObservableObject {
    static let shared = VoiceBridge()

    @Published private(set) var state: VoiceBridgeState = .idle
    @Published private(set) var liveSubtitle: String = ""

    private let audio = VoiceAudioIO()
    private let swarm = SwarmHTTPClient()
    private let realtime = XAIRealtimeClient()

    private var activeSession = false
    private var reconnectedOnce = false
    private var prewarmed = false
    private var healthTimer: Timer?

    /// Exact system instructions combining Part 1 (2.5) + Part 2 (EditDSL protocol, warm agents & project context).
    static let systemInstructions = """
    Você é o Diretor de Voz do Mafinha no Editroom. Fale sempre em português do Brasil. Entenda o pedido de edição com precisão, traduza em JSON EditDSL e chame a ferramenta exec_edit sem pedir confirmação. Responda em uma frase curta e natural confirmando o que foi feito. Nunca leia JSON, caminhos, IDs ou UUIDs. Peça confirmação falada só antes de export que sobrescreva arquivo ou de apagar um trecho grande. Se algo falhar, diga em uma frase o que falhou e ofereça desfazer ou tentar de novo.

    PROTOCOLO DO ENXAME LOCAL (EditDSL):
    - SEMPRE consulte get_state antes de assumir tempos, quantidade de clipes ou IDs (o projeto atual pode estar como um único clipe bruto de ~1h30 com os 10 marcadores de capítulo).
    - Em exec_edit, passe {"payload": {"pace": 0.3, "lanes": [{"agent": "...", "ops": [{"tool": "...", "target": "...", "args": {...}}]}]}}.
    - "pace": 0.3 é OBRIGATÓRIO em todo comando (nunca 0.0).
    - TODOS os parâmetros de cada tool vão SEMPRE dentro de "args" (ex.: split_clip precisa de "args": {"at": 45.0}).
    - Use APENAS os 6 agentes pré-aquecidos: Grok-Diretor, Grok-Cortador, Grok-Prints, Grok-Titulos, Grok-Colorista, Grok-Audio.
    - Nunca coloque duas lanes editando o mesmo trecho da mesma track ao mesmo tempo, nem use "ripple": true em paralelo na mesma track.
    - Seletores em "target": all_v1, all_v2, all_a1, all_video, all_audio, all_titles, track:V1, track:V2, track:V3, playhead, playhead:V1, at:SEGUNDOS:TRACK, range:INICIO-FIM:TRACK.
    - Para tools com clip_ids (set_grade, delete_clips): use "id_field": "clip_ids" e opcionalmente "batch_ids": true.
    - Encadeamento na mesma lane: save_v, save_a, save_id, save_split_v e referências "$c1", "$t1".
    - Tools aceitas: add_clip, split_clip, trim_clip, move_clip, delete_clips, set_transform, set_grade, list_looks, set_audio, set_transition, add_title, set_title_style, set_captions, set_marker, delete_markers, set_sequence, set_speed, set_speed_ramp, freeze_frame, reverse_clip, detach_audio, duplicate_clip, add_track, set_track, add_solid, set_solid_color, playback, history, save_project, export.
    - Atalhos padrão (sempre com pace 0.3):
      • Desfazer: lane Grok-Diretor, {"tool": "history", "args": {"action": "undo"}}.
      • Tocar: lane Grok-Diretor, {"tool": "playback", "args": {"action": "play", "time": SEGUNDOS}}.
      • Cor em tudo: lane Grok-Colorista, target all_v1, {"tool": "set_grade", "id_field": "clip_ids", "args": {"look": "Teal and orange", "look_intensity": 0.35}}.
      • Polir áudio: lane Grok-Audio, target all_a1, {"tool": "set_audio", "args": {"gain_db": 2.0, "fade_in": 0.12, "fade_out": 0.12}}.
      • Enquadrar o Kim: lane Grok-Diretor, target all_v1, {"tool": "set_transform", "args": {"scale": 2.58, "x": 0.87, "y": 0.30}}.
    - Contexto da sequência: vertical TikTok 9:16 (1080x1920, 60 fps), V1 apresentador Kim Paim (scale 2.58, x 0.87, y 0.30), V2 prints/matérias na metade superior (scale 1.56, x -0.28, y -0.17), V3 títulos dourados no topo (y 0.055), A1 áudio principal com legendas TikTok (position 0.77, highlight ativo).
    """

    private init() {
        wireCallbacks()
    }

    /// Pre-warms both the local Swarm HTTP keep-alive socket and the xAI WebSocket when the app/button appears.
    func prewarm() {
        guard !prewarmed else { return }
        prewarmed = true

        Task {
            _ = await swarm.health()
        }
        if let apiKey = VoiceKeychain.loadAPIKey(), !realtime.connected {
            realtime.connect(apiKey: apiKey, instructions: Self.systemInstructions)
        }
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { _ = await self.swarm.health() }
        }
    }

    func toggle() {
        if state.isActive {
            stop()
        } else {
            start()
        }
    }

    /// Starts microphone capture in parallel with WebSocket session readiness (no waiting for open).
    func start() {
        guard !activeSession else { return }
        guard let apiKey = VoiceKeychain.loadAPIKey() else {
            state = .error("Chave XAI_API_KEY não encontrada no ambiente ou Keychain. Clique com o botão direito para configurar.")
            audio.speakLocalFallback("Chave da xAI não encontrada no Keychain.")
            return
        }

        activeSession = true
        reconnectedOnce = false
        liveSubtitle = ""

        // Connect WebSocket immediately in parallel if not already pre-warmed.
        if !realtime.connected {
            realtime.connect(apiKey: apiKey, instructions: Self.systemInstructions)
        }
        Task {
            let health = await swarm.health()
            if !health.ok && self.activeSession {
                self.state = .error("Enxame local offline em 127.0.0.1:7842.")
                self.audio.speakLocalFallback("O enxame local do Editroom não está respondendo.")
            }
        }

        Task { @MainActor [weak self] in
            guard let self, self.activeSession else { return }
            let granted = await VoiceAudioIO.requestMicrophonePermission()
            guard self.activeSession else { return }
            guard granted else {
                self.activeSession = false
                self.state = .error("Permissão de microfone negada nos Ajustes do macOS.")
                return
            }
            do {
                try self.audio.startCapture()
                self.state = .listening
            } catch {
                self.activeSession = false
                self.state = .error("Erro ao abrir microfone: \(error.localizedDescription)")
            }
        }
    }

    /// Stops listening, closes the microphone and active turn, and returns to `.idle`.
    func stop() {
        activeSession = false
        reconnectedOnce = false
        audio.stopAll()
        realtime.cancelResponse()
        realtime.clearInputAudioBuffer()
        realtime.disconnect()
        liveSubtitle = ""
        state = .idle
    }

    /// Called on app termination so zero sockets, timers, or audio devices stay open.
    func shutdown() {
        healthTimer?.invalidate()
        healthTimer = nil
        activeSession = false
        audio.stopAll()
        realtime.disconnect()
        swarm.invalidate()
        state = .idle
    }

    // MARK: Internal Wiring

    private func wireCallbacks() {
        audio.onCapturedPCM = { [weak self] pcm in
            guard let self else { return }
            self.realtime.sendAudioChunk(pcm)
        }

        audio.onPlaybackStateChanged = { [weak self] isPlaying in
            Task { @MainActor [weak self] in
                guard let self, self.activeSession else { return }
                if isPlaying {
                    self.state = .speaking
                } else if case .speaking = self.state {
                    self.state = .listening
                }
            }
        }

        realtime.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleRealtimeEvent(event)
            }
        }
    }

    private func handleRealtimeEvent(_ event: XAIRealtimeClient.Event) {
        switch event {
        case .connected, .sessionReady:
            if activeSession, case .error = state {
                state = .listening
            }

        case .speechStarted:
            // Server VAD barge-in: user spoke over assistant -> stop audio & clear queue immediately!
            guard activeSession else { return }
            audio.interruptPlayback()
            realtime.cancelResponse()
            liveSubtitle = ""
            state = .listening

        case .speechStopped:
            break

        case .audioDelta(let pcmData):
            guard activeSession else { return }
            audio.enqueuePCM16(pcmData)

        case .transcriptDelta(let delta):
            guard activeSession else { return }
            liveSubtitle += delta

        case .responseDone:
            break

        case .functionCall(let name, let callID, let arguments):
            guard activeSession else { return }
            Task { await self.executeTool(name: name, callID: callID, argumentsJSON: arguments) }

        case .serverError(let msg):
            guard activeSession else { return }
            handleConnectionFailure(msg)

        case .disconnected(let err):
            guard activeSession else { return }
            handleConnectionFailure(err?.localizedDescription ?? "Conexão de voz encerrada.")
        }
    }

    private func handleConnectionFailure(_ reason: String) {
        audio.interruptPlayback()
        state = .error(reason)
        if !reconnectedOnce, let apiKey = VoiceKeychain.loadAPIKey() {
            reconnectedOnce = true
            audio.speakLocalFallback("A conexão de voz caiu. Tentando reconectar agora.")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard let self, self.activeSession else { return }
                self.realtime.connect(apiKey: apiKey, instructions: Self.systemInstructions)
                self.state = .listening
            }
        } else {
            audio.speakLocalFallback("Não consegui reconectar a sessão de voz.")
            activeSession = false
            audio.stopAll()
        }
    }

    private func executeTool(name: String, callID: String, argumentsJSON: String) async {
        do {
            switch name {
            case "get_state":
                let jsonStr = try await swarm.getState()
                realtime.sendFunctionOutput(callID: callID, outputJSON: jsonStr)

            case "exec_edit":
                let parsed = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
                let payload = (parsed["payload"] as? [String: Any]) ?? parsed
                let resultStr = try await swarm.execEdit(payload: payload)
                realtime.sendFunctionOutput(callID: callID, outputJSON: resultStr)

            default:
                let err = "{\"error\":\"Ferramenta desconhecida: \(name)\"}"
                realtime.sendFunctionOutput(callID: callID, outputJSON: err)
            }
        } catch {
            let escaped = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
            let errJSON = "{\"status\":\"error\",\"error\":\"\(escaped)\"}"
            realtime.sendFunctionOutput(callID: callID, outputJSON: errJSON)
        }
    }
}
