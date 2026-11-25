import Foundation

/// Persistent WebSocket client for xAI Grok Voice 3.0 (`grok-voice-latest`) Realtime API.
/// Follows the official schema verified on `docs.x.ai`:
/// - Endpoint: `wss://api.x.ai/v1/realtime?model=grok-voice-latest`
/// - `session.update` with `voice`, `instructions`, `turn_detection: server_vad`,
///   `audio.input.format: {type: "audio/pcm", rate: 24000}` + `language_hint: "pt-BR"`,
///   `audio.output.format: {type: "audio/pcm", rate: 24000}`, and `tools` (`get_state`, `exec_edit`).
final class XAIRealtimeClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    static let endpointURL = URL(string: "wss://api.x.ai/v1/realtime?model=grok-voice-latest")!

    enum Event {
        case connected
        case sessionReady
        case speechStarted
        case speechStopped
        case audioDelta(Data)
        case transcriptDelta(String)
        case responseDone
        case functionCall(name: String, callID: String, arguments: String)
        case serverError(String)
        case disconnected(Error?)
    }

    var onEvent: ((Event) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "editroom.voicebridge.xai-ws", qos: .userInteractive)
    private var isOpen = false
    private var isClosing = false
    private var pendingMessages: [String] = []
    private var sessionConfigJSON: String = ""

    /// Builds the official `session.update` JSON payload for Grok Voice 3.0.
    static func buildSessionUpdateJSON(instructions: String, voice: String = "Rex") -> String {
        let getStateTool: [String: Any] = [
            "type": "function",
            "name": "get_state",
            "description": "Retorna o estado atual da timeline do Editroom (sequência, playhead, tracks, clipes com IDs/tempos, marcadores, legendas e mídia). Sempre consulte antes de assumir tempos ou IDs.",
            "parameters": [
                "type": "object",
                "properties": [String: Any](),
                "additionalProperties": false,
            ],
        ]

        let execEditTool: [String: Any] = [
            "type": "function",
            "name": "exec_edit",
            "description": "Envia um comando EditDSL JSON ao enxame local do Editroom (com pace 0.3 obrigatório e cursores coloridos ao vivo). Retorna spoken_feedback e eventuais erros por lane.",
            "parameters": [
                "type": "object",
                "properties": [
                    "payload": [
                        "type": "object",
                        "description": "Objeto JSON EditDSL com 'pace': 0.3 (obrigatório) e 'lanes': lista de {agent, ops:[{tool, target?, args:{...}, id_field?, batch_ids?, save_v?, save_a?, save_id?, save_split_v?}]}.",
                        "properties": [
                            "pace": [
                                "type": "number",
                                "description": "Sempre 0.3 para ver os cursores trabalhando ao vivo. Nunca 0.0.",
                            ],
                            "lanes": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "agent": [
                                            "type": "string",
                                            "enum": [
                                                "Grok-Diretor",
                                                "Grok-Cortador",
                                                "Grok-Prints",
                                                "Grok-Titulos",
                                                "Grok-Colorista",
                                                "Grok-Audio",
                                            ],
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

        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "voice": voice,
                "instructions": instructions,
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 450,
                ],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000,
                        ],
                        "transcription": [
                            "language_hint": "pt-BR",
                        ],
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000,
                        ],
                    ],
                ],
                "tools": [getStateTool, execEditTool],
                "tool_choice": "auto",
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: []),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    var connected: Bool {
        queue.sync { isOpen && task != nil && !isClosing }
    }

    func connect(apiKey: String, instructions: String, voice: String = "Rex") {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownLocked(notify: false)
            self.isClosing = false
            self.sessionConfigJSON = Self.buildSessionUpdateJSON(instructions: instructions, voice: voice)

            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.waitsForConnectivity = false
            let opQueue = OperationQueue()
            opQueue.maxConcurrentOperationCount = 1
            let sess = URLSession(configuration: cfg, delegate: self, delegateQueue: opQueue)
            self.session = sess

            var req = URLRequest(url: Self.endpointURL)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let ws = sess.webSocketTask(with: req)
            self.task = ws
            ws.resume()
            self.receiveNextLocked(ws)
            self.startPingLocked()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.teardownLocked(notify: false)
        }
    }

    /// Streams raw PCM16 24kHz mono audio chunk immediately (`input_audio_buffer.append`).
    func sendAudioChunk(_ pcmData: Data) {
        let b64 = pcmData.base64EncodedString()
        let msg = "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(b64)\"}"
        sendRawJSON(msg, queueIfOpening: true)
    }

    /// Discards any buffered un-committed mic audio when stopping listening.
    func clearInputAudioBuffer() {
        sendRawJSON("{\"type\":\"input_audio_buffer.clear\"}", queueIfOpening: false)
    }

    /// Cancels an active model response (used on barge-in interruption or manual stop).
    func cancelResponse() {
        sendRawJSON("{\"type\":\"response.cancel\"}", queueIfOpening: false)
    }

    /// Sends function call output back to Grok Voice 3.0 and triggers spoken continuation.
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
                    // Cap pre-open audio buffer to ~1.5s (~35 chunks) so memory stays bounded.
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
                    case .string(let text):
                        self.handleServerText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleServerText(text)
                        }
                    @unknown default:
                        break
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
        case "session.created":
            onEvent?(.sessionReady)
        case "session.updated":
            onEvent?(.sessionReady)
        case "input_audio_buffer.speech_started":
            onEvent?(.speechStarted)
        case "input_audio_buffer.speech_stopped":
            onEvent?(.speechStopped)
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
            let msg = (errObj?["message"] as? String) ?? (json["message"] as? String) ?? "Erro na sessão de voz xAI."
            onEvent?(.serverError(msg))
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
        if notify {
            onEvent?(.disconnected(error))
        }
    }

    // MARK: URLSessionWebSocketDelegate

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
            let err = NSError(domain: "XAIRealtimeClient", code: Int(closeCode.rawValue),
                              userInfo: [NSLocalizedDescriptionKey: "Conexão de voz encerrada (código \(closeCode.rawValue))."])
            self.teardownLocked(notify: true, error: err)
        }
    }
}
