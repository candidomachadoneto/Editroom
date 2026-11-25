import Foundation

/// Selectable Realtime Voice front-end engine (low-latency speech-to-speech over WebSocket).
enum VoiceEngineModel: String, CaseIterable, Identifiable {
    case openaiRealtimeMini = "gpt-realtime-2.1-mini"
    case openaiRealtime = "gpt-realtime-2.1"
    case xaiGrokVoice = "grok-voice-latest"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openaiRealtimeMini: return "GPT-2.1 Mini (Ultra-Rápido)"
        case .openaiRealtime: return "GPT-2.1 Realtime (Pro)"
        case .xaiGrokVoice: return "Grok Voice 3.0 (xAI)"
        }
    }

    var shortLabel: String {
        switch self {
        case .openaiRealtimeMini: return "GPT-2.1 Mini"
        case .openaiRealtime: return "GPT-2.1"
        case .xaiGrokVoice: return "Grok Voice"
        }
    }

    var provider: VoiceKeychain.Provider {
        switch self {
        case .openaiRealtimeMini, .openaiRealtime: return .openai
        case .xaiGrokVoice: return .xai
        }
    }

    var endpointURL: URL {
        switch self {
        case .openaiRealtimeMini, .openaiRealtime:
            return URL(string: "wss://api.openai.com/v1/realtime?model=\(rawValue)")!
        case .xaiGrokVoice:
            return URL(string: "wss://api.x.ai/v1/realtime?model=grok-voice-latest")!
        }
    }
}

/// Turn-detection strategy: fast fixed silence (`server_vad`, 320ms) or meaning-aware (`semantic_vad`).
enum VoiceVADMode: String, CaseIterable, Identifiable {
    case fastServer = "server_vad"
    case semantic = "semantic_vad"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fastServer: return "Ultra-Rápido (320ms)"
        case .semantic: return "Semântico (inteligente)"
        }
    }
}

/// Unified persistent WebSocket client supporting BOTH OpenAI Realtime GA (`gpt-realtime-2.1-mini` / `gpt-realtime-2.1`)
/// and xAI Grok Voice 3.0 (`grok-voice-latest`) over a single low-latency audio/tool protocol.
final class RealtimeClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Event {
        case connected
        case sessionReady
        case speechStarted
        case speechStopped
        case responseStarted
        case audioDelta(Data)
        case transcriptDelta(String)
        case responseDone
        case functionCall(name: String, callID: String, arguments: String)
        case serverError(code: String, message: String)
        case disconnected(Error?)
    }

    var onEvent: ((Event) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "editroom.voicebridge.realtime-ws", qos: .userInteractive)
    private var isOpen = false
    private var isClosing = false
    private var pendingMessages: [String] = []
    private var sessionConfigJSON: String = ""
    private var currentModel: VoiceEngineModel = .openaiRealtimeMini

    static func toolDefinitions() -> [[String: Any]] {
        let getStateTool: [String: Any] = [
            "type": "function",
            "name": "get_state",
            "description": "Retorna o estado atualizado da timeline do Editroom (sequência, playhead, tracks, clipes com IDs/tempos, marcadores, legendas e mídia).",
            "parameters": [
                "type": "object",
                "properties": [String: Any](),
                "additionalProperties": false,
            ],
        ]

        let execEditTool: [String: Any] = [
            "type": "function",
            "name": "exec_edit",
            "description": "Executa edição imediata no enxame local do Editroom (pace 0.3 obrigatório, parâmetros dentro de 'args', cursores coloridos ao vivo). Use para qualquer edição direta ou rápida.",
            "parameters": [
                "type": "object",
                "properties": [
                    "payload": [
                        "type": "object",
                        "description": "Objeto JSON EditDSL com 'pace': 0.3 e 'lanes': [{agent, ops:[{tool, target?, args:{...}, id_field?, batch_ids?}]}].",
                        "properties": [
                            "pace": ["type": "number", "description": "Sempre 0.3."],
                            "lanes": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "agent": [
                                            "type": "string",
                                            "enum": ["Grok-Diretor", "Grok-Cortador", "Grok-Prints", "Grok-Titulos", "Grok-Colorista", "Grok-Audio"],
                                        ],
                                        "ops": [
                                            "type": "array",
                                            "items": [
                                                "type": "object",
                                                "properties": [
                                                    "tool": ["type": "string"],
                                                    "target": ["type": "string"],
                                                    "id_field": ["type": "string"],
                                                    "batch_ids": ["type": "boolean"],
                                                    "args": ["type": "object"],
                                                ],
                                                "required": ["tool", "args"],
                                            ],
                                        ],
                                    ],
                                    "required": ["agent", "ops"],
                                ],
                            ],
                        ],
                        "required": ["pace", "lanes"],
                    ],
                ],
                "required": ["payload"],
            ],
        ]

        let orchestrateTool: [String: Any] = [
            "type": "function",
            "name": "orchestrate_models",
            "description": "Delega uma edição complexa, criativa ou multi-frente para o time de modelos especialistas (Gemini 4, Claude Fable, Grok 4.7 e/ou OpenAI) planejarem em paralelo por especialidade e executarem sem colisão na timeline com cursores coloridos.",
            "parameters": [
                "type": "object",
                "properties": [
                    "goal": ["type": "string", "description": "Objetivo editorial completo pedido pelo usuário."],
                    "models": [
                        "type": "array",
                        "items": ["type": "string", "enum": ["openai", "claude", "gemini", "grok"]],
                        "description": "Opcional: modelos específicos pedidos pelo usuário (se omitido, usa os modelos ativos no painel Magic).",
                    ],
                ],
                "required": ["goal"],
            ],
        ]

        let rememberTool: [String: Any] = [
            "type": "function",
            "name": "remember_preference",
            "description": "Salva uma preferência de edição que o usuário expressou ('gostei disso', 'sempre faz assim', 'neste vídeo não usa zoom') para o editor aprender e se auto-aperfeiçoar.",
            "parameters": [
                "type": "object",
                "properties": [
                    "rule": ["type": "string", "description": "Regra curta e clara do gosto editorial do usuário."],
                    "category": ["type": "string", "enum": ["cut", "framing", "color", "audio", "titles", "captions", "style"]],
                    "scope": ["type": "string", "enum": ["global", "project"], "description": "'global' = sempre em todos os vídeos; 'project' = apenas neste vídeo."],
                ],
                "required": ["rule", "category", "scope"],
            ],
        ]

        let forgetTool: [String: Any] = [
            "type": "function",
            "name": "forget_preference",
            "description": "Remove uma preferência de edição salva anteriormente quando o usuário pedir para esquecer ou mudar de ideia.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Palavra-chave da preferência a remover."],
                ],
                "required": ["query"],
            ],
        ]

        return [getStateTool, execEditTool, orchestrateTool, rememberTool, forgetTool]
    }

    static func buildSessionUpdateJSON(model: VoiceEngineModel, instructions: String, vadMode: VoiceVADMode) -> String {
        let tools = toolDefinitions()
        let event: [String: Any]

        switch model.provider {
        case .openai:
            let turnDetection: [String: Any] = vadMode == .semantic
                ? ["type": "semantic_vad", "eagerness": "high", "interrupt_response": true]
                : ["type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 250, "silence_duration_ms": 320, "interrupt_response": true]
            event = [
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "model": model.rawValue,
                    "instructions": instructions,
                    "output_modalities": ["audio"],
                    "audio": [
                        "input": [
                            "format": ["type": "audio/pcm", "rate": 24000],
                            "turn_detection": turnDetection,
                        ],
                        "output": [
                            "format": ["type": "audio/pcm", "rate": 24000],
                            "voice": "cedar",
                        ],
                    ],
                    "tools": tools,
                    "tool_choice": "auto",
                ],
            ]

        case .xai:
            event = [
                "type": "session.update",
                "session": [
                    "voice": "Rex",
                    "instructions": instructions,
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 260,
                        "silence_duration_ms": 360,
                    ],
                    "audio": [
                        "input": [
                            "format": ["type": "audio/pcm", "rate": 24000],
                            "transcription": ["language_hint": "pt-BR"],
                        ],
                        "output": [
                            "format": ["type": "audio/pcm", "rate": 24000],
                        ],
                    ],
                    "tools": tools,
                    "tool_choice": "auto",
                ],
            ]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: event, options: []),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    var connected: Bool {
        queue.sync { isOpen && task != nil && !isClosing }
    }

    var activeModel: VoiceEngineModel {
        queue.sync { currentModel }
    }

    func connect(model: VoiceEngineModel, apiKey: String, instructions: String, vadMode: VoiceVADMode) {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownLocked(notify: false)
            self.isClosing = false
            self.currentModel = model
            self.sessionConfigJSON = Self.buildSessionUpdateJSON(model: model, instructions: instructions, vadMode: vadMode)

            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.waitsForConnectivity = false
            let opQueue = OperationQueue()
            opQueue.maxConcurrentOperationCount = 1
            let sess = URLSession(configuration: cfg, delegate: self, delegateQueue: opQueue)
            self.session = sess

            var req = URLRequest(url: model.endpointURL)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let ws = sess.webSocketTask(with: req)
            self.task = ws
            ws.resume()
            self.receiveNextLocked(ws)
            self.startPingLocked()
        }
    }

    /// Hot-updates ONLY the session instructions mid-connection (safe even after assistant audio has played,
    /// since OpenAI Realtime forbids re-sending `voice` once assistant audio exists in the conversation).
    func updateInstructions(_ instructions: String) {
        queue.async { [weak self] in
            guard let self, self.isOpen, let ws = self.task, !self.isClosing else { return }
            let sessionBody: [String: Any] = self.currentModel.provider == .openai
                ? ["type": "realtime", "instructions": instructions]
                : ["instructions": instructions]
            let event: [String: Any] = ["type": "session.update", "session": sessionBody]
            if let d = try? JSONSerialization.data(withJSONObject: event),
               let s = String(data: d, encoding: .utf8) {
                ws.send(.string(s)) { _ in }
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.teardownLocked(notify: false)
        }
    }

    func sendAudioChunk(_ pcmData: Data) {
        let b64 = pcmData.base64EncodedString()
        sendRawJSON("{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(b64)\"}", queueIfOpening: true)
    }

    func clearInputAudioBuffer() {
        sendRawJSON("{\"type\":\"input_audio_buffer.clear\"}", queueIfOpening: false)
    }

    func cancelResponse() {
        sendRawJSON("{\"type\":\"response.cancel\"}", queueIfOpening: false)
    }

    func sendFunctionOutput(callID: String, outputJSON: String) {
        let itemEvent: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": outputJSON,
            ],
        ]
        if let d = try? JSONSerialization.data(withJSONObject: itemEvent),
           let s = String(data: d, encoding: .utf8) {
            sendRawJSON(s, queueIfOpening: true)
        }
        sendRawJSON("{\"type\":\"response.create\"}", queueIfOpening: true)
    }

    private func sendRawJSON(_ text: String, queueIfOpening: Bool) {
        queue.async { [weak self] in
            guard let self, !self.isClosing else { return }
            guard self.isOpen, let ws = self.task else {
                if queueIfOpening {
                    if self.pendingMessages.count > 35 { self.pendingMessages.removeFirst() }
                    self.pendingMessages.append(text)
                }
                return
            }
            ws.send(.string(text)) { _ in }
        }
    }

    private func flushPendingLocked() {
        guard isOpen, let ws = task else { return }
        if !sessionConfigJSON.isEmpty {
            ws.send(.string(sessionConfigJSON)) { _ in }
        }
        let queued = pendingMessages
        pendingMessages.removeAll()
        for msg in queued {
            ws.send(.string(msg)) { _ in }
        }
    }

    private func startPingLocked() {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self, self.isOpen, let ws = self.task else { return }
            ws.sendPing { [weak self] err in
                if let err {
                    self?.queue.async { self?.teardownLocked(notify: true, error: err) }
                }
            }
        }
        t.resume()
        pingTimer = t
    }

    private func receiveNextLocked(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === ws, !self.isClosing else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleServerText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handleServerText(text) }
                    @unknown default: break
                    }
                    self.receiveNextLocked(ws)
                case .failure(let error):
                    self.teardownLocked(notify: true, error: error)
                }
            }
        }
    }

    private func handleServerText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "session.created", "session.updated":
            onEvent?(.sessionReady)
        case "input_audio_buffer.speech_started":
            onEvent?(.speechStarted)
        case "input_audio_buffer.speech_stopped":
            onEvent?(.speechStopped)
        case "response.created":
            onEvent?(.responseStarted)
        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64), !pcm.isEmpty {
                onEvent?(.audioDelta(pcm))
            }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = json["delta"] as? String {
                onEvent?(.transcriptDelta(delta))
            }
        case "response.done":
            onEvent?(.responseDone)
        case "response.function_call_arguments.done":
            let name = json["name"] as? String ?? ""
            let callID = json["call_id"] as? String ?? ""
            let args = json["arguments"] as? String ?? "{}"
            if !name.isEmpty && !callID.isEmpty {
                onEvent?(.functionCall(name: name, callID: callID, arguments: args))
            }
        case "error":
            let errObj = json["error"] as? [String: Any]
            let code = (errObj?["code"] as? String) ?? ""
            let msg = (errObj?["message"] as? String) ?? (json["message"] as? String) ?? "Erro na sessão de voz."
            onEvent?(.serverError(code: code, message: msg))
        default:
            break
        }
    }

    private func teardownLocked(notify: Bool, error: Error? = nil) {
        isClosing = true
        isOpen = false
        pingTimer?.cancel()
        pingTimer = nil
        pendingMessages.removeAll()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if notify { onEvent?(.disconnected(error)) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            guard let self, self.task === webSocketTask, !self.isClosing else { return }
            self.isOpen = true
            self.flushPendingLocked()
            self.onEvent?(.connected)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [weak self] in
            guard let self, self.task === webSocketTask, !self.isClosing else { return }
            let err = NSError(domain: "RealtimeClient", code: Int(closeCode.rawValue),
                              userInfo: [NSLocalizedDescriptionKey: "Conexão de voz encerrada (código \(closeCode.rawValue))."])
            self.teardownLocked(notify: true, error: err)
        }
    }
}
