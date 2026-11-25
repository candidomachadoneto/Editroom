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

/// Self-contained VoiceBridge module (OpenAI GPT Realtime 2.1 + xAI Grok Voice 3.0 + Multi-Model Team + SQLite Taste Memory).
/// The Magic UI button only calls `start()`, `stop()`, `toggle()`, and observes published state.
/// Never calls internal Editroom editing APIs: every edit goes strictly through the single local Swarm HTTP executor (`127.0.0.1:7842`).
@MainActor
final class VoiceBridge: ObservableObject {
    static let shared = VoiceBridge()

    @Published private(set) var state: VoiceBridgeState = .idle
    @Published private(set) var liveSubtitle: String = ""
    @Published private(set) var preferences: [EditingPreference] = []
    @Published private(set) var activeTeamStatus: String?

    @Published var voiceModel: VoiceEngineModel {
        didSet {
            UserDefaults.standard.set(voiceModel.rawValue, forKey: "voiceBridge.voiceModel")
            if activeSession { reconnectWithCurrentSettings() }
        }
    }

    @Published var vadMode: VoiceVADMode {
        didSet {
            UserDefaults.standard.set(vadMode.rawValue, forKey: "voiceBridge.vadMode")
            if activeSession { pushUpdatedInstructions() }
        }
    }

    /// Multi-model co-director team (user can enable any 1 or multiple models together: OpenAI + Claude + Gemini + Grok!).
    @Published var enabledSpecialists: Set<SpecialistModel> {
        didSet {
            let raw = enabledSpecialists.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: "voiceBridge.specialists")
            if activeSession { pushUpdatedInstructions() }
        }
    }

    private let audio = VoiceAudioIO()
    private let swarm = SwarmHTTPClient()
    private let realtime = RealtimeClient()
    private let coordinator = MultiModelCoordinator()
    private let taste = EditingTasteDB.shared

    private var activeSession = false
    private var reconnectedOnce = false
    private var prewarmed = false
    private var healthTimer: Timer?
    private var sessionGeneration: Int = 0
    private var handledCallIDs = Set<String>()
    private var cachedStateCompact: String = ""
    private var cachedProjectID: String = "default"

    private init() {
        let savedVoice = UserDefaults.standard.string(forKey: "voiceBridge.voiceModel")
            .flatMap(VoiceEngineModel.init(rawValue:)) ?? .openaiRealtimeMini
        let savedVAD = UserDefaults.standard.string(forKey: "voiceBridge.vadMode")
            .flatMap(VoiceVADMode.init(rawValue:)) ?? .fastServer
        let savedSpecs = (UserDefaults.standard.stringArray(forKey: "voiceBridge.specialists"))
            .map { Set($0.compactMap(SpecialistModel.init(rawValue:))) }
        self.voiceModel = savedVoice
        self.vadMode = savedVAD
        self.enabledSpecialists = (savedSpecs?.isEmpty == false) ? savedSpecs! : [.openai, .claude, .gemini]
        self.preferences = taste.allPreferences()
        wireCallbacks()
    }

    /// Pre-warms the local Swarm keep-alive socket and refreshes timeline state snapshot.
    func prewarm() {
        guard !prewarmed else { return }
        prewarmed = true
        refreshPreferences()
        Task {
            _ = await swarm.health()
            await refreshCachedState()
        }
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { _ = await self.swarm.health() }
        }
    }

    func toggle() {
        if state.isActive { stop() } else { start() }
    }

    /// Instant local feedback (<50ms): activates button, starts mic in parallel with WebSocket handshake,
    /// and pre-injects compact timeline state + learned editing preferences so the first command runs in 1 turn!
    func start() {
        guard !activeSession else { return }
        let provider = voiceModel.provider
        guard let apiKey = VoiceKeychain.loadAPIKey(for: provider) else {
            let keyName = provider.envName
            state = .error("Chave \(keyName) não encontrada. Clique na seta ao lado de Magic para configurar no Keychain.")
            audio.speakLocalFallback("Chave da API não encontrada no Keychain.")
            return
        }

        sessionGeneration += 1
        let gen = sessionGeneration
        activeSession = true
        reconnectedOnce = false
        liveSubtitle = ""
        activeTeamStatus = nil
        handledCallIDs.removeAll()
        state = .listening

        // 1. Connect Realtime WebSocket immediately with cached state + learned taste.
        let initialInstructions = buildDynamicInstructions()
        realtime.connect(model: voiceModel, apiKey: apiKey, instructions: initialInstructions, vadMode: vadMode)

        // 2. In parallel: refresh fresh timeline state & verify local swarm health, then hot-update prompt!
        Task { @MainActor [weak self] in
            guard let self, self.activeSession, self.sessionGeneration == gen else { return }
            let health = await self.swarm.health()
            if !health.ok && self.activeSession && self.sessionGeneration == gen {
                self.state = .error("Enxame local offline em 127.0.0.1:7842.")
                self.audio.speakLocalFallback("O enxame local do Editroom não está respondendo.")
                return
            }
            await self.refreshCachedState()
            if self.activeSession && self.sessionGeneration == gen {
                self.pushUpdatedInstructions()
            }
        }

        // 3. In parallel: open microphone without waiting for WebSocket handshake.
        Task { @MainActor [weak self] in
            guard let self, self.activeSession, self.sessionGeneration == gen else { return }
            let granted = await VoiceAudioIO.requestMicrophonePermission()
            guard self.activeSession, self.sessionGeneration == gen else { return }
            guard granted else {
                self.activeSession = false
                self.state = .error("Permissão de microfone negada nos Ajustes do macOS.")
                return
            }
            do {
                try self.audio.startCapture()
                if self.activeSession && self.sessionGeneration == gen {
                    self.state = .listening
                }
            } catch {
                self.activeSession = false
                self.state = .error("Erro ao abrir microfone: \(error.localizedDescription)")
            }
        }
    }

    /// Cancels any in-flight multi-model plans, closes mic & WebSocket, and returns cleanly to `.idle`.
    func stop() {
        sessionGeneration += 1
        activeSession = false
        reconnectedOnce = false
        activeTeamStatus = nil
        coordinator.cancelAll()
        audio.stopAll()
        realtime.cancelResponse()
        realtime.clearInputAudioBuffer()
        realtime.disconnect()
        liveSubtitle = ""
        state = .idle
    }

    func shutdown() {
        healthTimer?.invalidate()
        healthTimer = nil
        stop()
        swarm.invalidate()
    }

    // MARK: Preference Management (UI & Voice)

    func refreshPreferences() {
        preferences = taste.allPreferences()
    }

    func addExplicitPreference(rule: String, category: String = "style", scope: EditingPreference.Scope = .global) {
        _ = taste.savePreference(rule: rule, category: category, scope: scope, projectID: cachedProjectID, source: .explicit)
        refreshPreferences()
        if activeSession { pushUpdatedInstructions() }
    }

    func deletePreference(id: String) {
        taste.deletePreference(id: id)
        refreshPreferences()
        if activeSession { pushUpdatedInstructions() }
    }

    func toggleSpecialist(_ model: SpecialistModel) {
        var next = enabledSpecialists
        if next.contains(model) {
            if next.count > 1 { next.remove(model) }
        } else {
            next.insert(model)
        }
        enabledSpecialists = next
    }

    // MARK: Dynamic Instructions (Compact State + Learned Taste + Active Team)

    private func buildDynamicInstructions() -> String {
        let teamNames = enabledSpecialists.sorted { $0.rawValue < $1.rawValue }.map(\.label).joined(separator: ", ")
        let tasteBlock = taste.promptSummary(projectID: cachedProjectID)
        let stateBlock = cachedStateCompact.isEmpty
            ? "Estado inicial ainda carregando — chame get_state se precisar de tempos/IDs exatos."
            : "RESUMO ATUAL DA TIMELINE (pré-carregado; use direto ou chame get_state se acabou de mudar):\n\(cachedStateCompact)"

        return """
        Você é o Diretor de Voz do Mafinha no Editroom. Fale sempre em português do Brasil, de forma ultra-rápida, natural e direta.
        - Para comandos diretos (cortar, desfazer, dar play, ajustar cor, áudio, enquadramento, títulos, legendas): chame exec_edit IMEDIATAMENTE sem pedir confirmação.
        - Para pedidos complexos, criativos, multi-frente, ou quando o usuário citar modelos (ex.: "usa Gemini com Claude", "junta os modelos"): avise em 3 palavras ("Chamando a equipe agora") e chame orchestrate_models(goal, models).
        - Modelos disponíveis na equipe ativa: [\(teamNames)].
        - Quando o usuário disser uma preferência ("gostei assim", "sempre deixa o título no topo", "neste vídeo sem zoom"): chame remember_preference diferenciando scope "global" (sempre) de "project" (só este vídeo). Se pedir para esquecer, chame forget_preference.
        - Responda sempre em 1 frase curta e natural confirmando o que foi feito. NUNCA leia JSON, caminhos de arquivo, IDs ou UUIDs.
        - Peça confirmação falada só antes de export que sobrescreva arquivo ou de apagar um trecho grande. Se algo falhar, diga em 1 frase e ofereça desfazer ou tentar de novo.

        PROTOCOLO EDITDSL (exec_edit):
        - "pace": 0.3 é OBRIGATÓRIO (nunca 0.0).
        - TODOS os parâmetros de cada tool vão SEMPRE dentro de "args".
        - Agentes pré-aquecidos: Grok-Diretor, Grok-Cortador, Grok-Prints, Grok-Titulos, Grok-Colorista, Grok-Audio.
        - Nunca coloque duas lanes no mesmo trecho da mesma track nem ripple: true em paralelo na mesma track.
        - Seletores em target: all_v1, all_v2, all_a1, all_video, all_audio, all_titles, track:V1, track:V2, track:V3, playhead, playhead:V1, at:SEGUNDOS:TRACK, range:INICIO-FIM:TRACK.
        - Tools com clip_ids (set_grade, delete_clips): use "id_field": "clip_ids".
        - Atalhos (pace 0.3): Desfazer -> Grok-Diretor history {action:"undo"}; Tocar -> Grok-Diretor playback {action:"play", time:S}; Cor -> Grok-Colorista all_v1 set_grade id_field:"clip_ids" {look:"Teal and orange", look_intensity:0.35}; Polir áudio -> Grok-Audio all_a1 set_audio {gain_db:2.0, fade_in:0.12, fade_out:0.12}; Enquadrar Kim -> Grok-Diretor all_v1 set_transform {scale:2.58, x:0.87, y:0.30}.
        - Projeto típico: TikTok 9:16 1080x1920 60fps; V1 Kim (scale 2.58, x 0.87, y 0.30), V2 prints (scale 1.56, x -0.28, y -0.17), V3 títulos topo (y 0.055), A1 áudio + legendas (position 0.77).

        \(tasteBlock)

        \(stateBlock)
        """
    }

    private func pushUpdatedInstructions() {
        realtime.updateSession(model: voiceModel, instructions: buildDynamicInstructions(), vadMode: vadMode)
    }

    private func reconnectWithCurrentSettings() {
        guard let apiKey = VoiceKeychain.loadAPIKey(for: voiceModel.provider) else {
            state = .error("Chave \(voiceModel.provider.envName) ausente no Keychain.")
            return
        }
        realtime.connect(model: voiceModel, apiKey: apiKey, instructions: buildDynamicInstructions(), vadMode: vadMode)
    }

    private func refreshCachedState() async {
        guard let raw = try? await swarm.getState(),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Keep compact summary under ~3.5KB so Realtime prompt caching stays blazing fast!
        let seq = obj["sequence"] ?? [:]
        let playhead = obj["playhead"] ?? 0
        let clips = (obj["clips"] as? [[String: Any]]) ?? []
        let markers = (obj["markers"] as? [[String: Any]]) ?? []
        let compact: [String: Any] = [
            "sequence": seq,
            "playhead": playhead,
            "clip_count": clips.count,
            "clips": Array(clips.prefix(24)),
            "markers": Array(markers.prefix(16)),
        ]
        if let d = try? JSONSerialization.data(withJSONObject: compact),
           let s = String(data: d, encoding: .utf8) {
            cachedStateCompact = s
            if let firstID = clips.first?["id"] as? String {
                cachedProjectID = String(firstID.prefix(12))
            }
        }
    }

    // MARK: Internal Wiring

    private func wireCallbacks() {
        audio.onCapturedPCM = { [weak self] pcm in
            self?.realtime.sendAudioChunk(pcm)
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

    private func handleRealtimeEvent(_ event: RealtimeClient.Event) {
        switch event {
        case .connected, .sessionReady:
            if activeSession, case .error = state { state = .listening }

        case .speechStarted:
            // Instant barge-in: stop audio, clear queue, cancel active model turn & late specialist tasks.
            guard activeSession else { return }
            audio.interruptPlayback()
            realtime.cancelResponse()
            liveSubtitle = ""
            state = .listening

        case .speechStopped, .responseDone:
            break

        case .audioDelta(let pcmData):
            guard activeSession else { return }
            audio.enqueuePCM16(pcmData)

        case .transcriptDelta(let delta):
            guard activeSession else { return }
            liveSubtitle += delta

        case .functionCall(let name, let callID, let arguments):
            guard activeSession else { return }
            // Idempotency guard: never execute the same tool call twice on reconnect.
            guard handledCallIDs.insert(callID).inserted else { return }
            let gen = sessionGeneration
            Task { await self.executeTool(name: name, callID: callID, argumentsJSON: arguments, generation: gen) }

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
        if !reconnectedOnce, let apiKey = VoiceKeychain.loadAPIKey(for: voiceModel.provider) {
            reconnectedOnce = true
            audio.speakLocalFallback("A conexão de voz caiu. Tentando reconectar agora.")
            let gen = sessionGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 850_000_000)
                guard let self, self.activeSession, self.sessionGeneration == gen else { return }
                self.realtime.connect(model: self.voiceModel, apiKey: apiKey,
                                      instructions: self.buildDynamicInstructions(), vadMode: self.vadMode)
                self.state = .listening
            }
        } else {
            audio.speakLocalFallback("Não consegui reconectar a sessão de voz.")
            activeSession = false
            audio.stopAll()
        }
    }

    private func executeTool(name: String, callID: String, argumentsJSON: String, generation: Int) async {
        do {
            switch name {
            case "get_state":
                let jsonStr = try await swarm.getState()
                guard activeSession, sessionGeneration == generation else { return }
                realtime.sendFunctionOutput(callID: callID, outputJSON: jsonStr)
                await refreshCachedState()

            case "exec_edit":
                let parsed = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
                let payload = (parsed["payload"] as? [String: Any]) ?? parsed
                guard activeSession, sessionGeneration == generation else { return }
                let resultStr = try await swarm.execEdit(payload: payload)
                guard activeSession, sessionGeneration == generation else { return }
                realtime.sendFunctionOutput(callID: callID, outputJSON: resultStr)

                // Record episodic trace (conservatively marking recent undo without promoting single undo to taste).
                let sig = Self.toolsSignature(from: payload)
                if sig == "history:undo" {
                    taste.markRecentInteractionUndone()
                } else {
                    taste.logInteraction(projectID: cachedProjectID, summary: sig, toolsSignature: sig, outcome: "ok")
                }
                await refreshCachedState()

            case "orchestrate_models":
                let parsed = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
                let goal = (parsed["goal"] as? String) ?? ""
                let requested = (parsed["models"] as? [String])?.compactMap(SpecialistModel.init(rawValue:))
                let team = (requested?.isEmpty == false) ? requested! : Array(enabledSpecialists).sorted { $0.rawValue < $1.rawValue }
                activeTeamStatus = team.map(\.label).joined(separator: " + ")
                let fullState = (try? await swarm.getState()) ?? cachedStateCompact
                let resultStr = await coordinator.orchestrate(
                    goal: goal,
                    models: team,
                    stateJSON: fullState,
                    tasteSummary: taste.promptSummary(projectID: cachedProjectID),
                    swarm: swarm
                )
                activeTeamStatus = nil
                guard activeSession, sessionGeneration == generation else { return }
                realtime.sendFunctionOutput(callID: callID, outputJSON: resultStr)
                taste.logInteraction(projectID: cachedProjectID, summary: goal, toolsSignature: "team:\(team.map(\.rawValue).joined(separator: "+"))", outcome: "ok")
                await refreshCachedState()

            case "remember_preference":
                let parsed = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
                let rule = (parsed["rule"] as? String) ?? ""
                let cat = (parsed["category"] as? String) ?? "style"
                let scope = EditingPreference.Scope(rawValue: (parsed["scope"] as? String) ?? "global") ?? .global
                let saved = taste.savePreference(rule: rule, category: cat, scope: scope, projectID: cachedProjectID, source: .explicit)
                refreshPreferences()
                pushUpdatedInstructions()
                realtime.sendFunctionOutput(callID: callID, outputJSON: "{\"saved\":true,\"scope\":\"\(saved.scope.rawValue)\"}")

            case "forget_preference":
                let parsed = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
                let query = (parsed["query"] as? String) ?? ""
                let removed = taste.removePreference(matching: query)
                refreshPreferences()
                pushUpdatedInstructions()
                realtime.sendFunctionOutput(callID: callID, outputJSON: "{\"removed\":\(removed)}")

            default:
                realtime.sendFunctionOutput(callID: callID, outputJSON: "{\"error\":\"Ferramenta desconhecida: \(name)\"}")
            }
        } catch {
            guard activeSession, sessionGeneration == generation else { return }
            let escaped = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
            realtime.sendFunctionOutput(callID: callID, outputJSON: "{\"status\":\"error\",\"error\":\"\(escaped)\"}")
        }
    }

    private static func toolsSignature(from payload: [String: Any]) -> String {
        let lanes = (payload["lanes"] as? [[String: Any]]) ?? []
        var parts: [String] = []
        for lane in lanes {
            for op in (lane["ops"] as? [[String: Any]]) ?? [] {
                let tool = (op["tool"] as? String) ?? ""
                if tool == "history", let act = (op["args"] as? [String: Any])?["action"] as? String {
                    parts.append("history:\(act)")
                } else if !tool.isEmpty {
                    parts.append(tool)
                }
            }
        }
        return Array(Set(parts)).sorted().joined(separator: ",")
    }
}
