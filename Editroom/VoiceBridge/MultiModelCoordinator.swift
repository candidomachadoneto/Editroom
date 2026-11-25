import Foundation

/// Selectable specialist models that can plan alone OR together in parallel (Gemini + Claude + Grok + OpenAI).
enum SpecialistModel: String, CaseIterable, Identifiable, Codable {
    case openai
    case claude
    case gemini
    case grok

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .claude: return "Claude Fable"
        case .gemini: return "Gemini 4"
        case .grok: return "Grok 4.7"
        }
    }

    var roleSummary: String {
        switch self {
        case .openai: return "Coordenação, layout e áudio"
        case .claude: return "Cortes e ritmo editorial"
        case .gemini: return "Enquadramento, cards e cor"
        case .grok: return "Títulos, legendas e impacto"
        }
    }

    /// Assigned disjoint Swarm agent lane so multiple models NEVER collide on the same track.
    var primaryAgent: String {
        switch self {
        case .claude: return "Grok-Cortador"
        case .gemini: return "Grok-Prints"
        case .grok: return "Grok-Titulos"
        case .openai: return "Grok-Diretor"
        }
    }

    var trackDomain: String {
        switch self {
        case .claude: return "cortes, splits, trims e ritmo na V1/A1 (usando Grok-Cortador)"
        case .gemini: return "enquadramento (set_transform, set_crop, set_mask, set_background_removal), prints/cards na V2 (set_clip_style) e cor/grade (usando Grok-Prints e Grok-Colorista)"
        case .grok: return "títulos na V3 (add_title, set_title_style), lower thirds (set_lower_third), legendas (set_captions) e marcadores (usando Grok-Titulos)"
        case .openai: return "coordenação geral, criação de tracks/duplicação de clipes, áudio/fades/voice enhance na A1 (usando Grok-Diretor e Grok-Audio)"
        }
    }
}

/// Coordinates 1 or multiple AI models in parallel (e.g., Gemini + Claude + Grok + OpenAI),
/// enforces timeout + cancellation, automatically recovers via fast OpenAI GPT-4.1 if any CLI model
/// hits quota or times out, merges planned EditDSL lanes WITHOUT track collisions, and sends a single
/// transactional payload (`pace: 0.3`) to the local Swarm HTTP executor.
final class MultiModelCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcesses: [Process] = []
    private var cancelled = false

    private struct PlanResult: @unchecked Sendable {
        let model: SpecialistModel
        let lanes: [[String: Any]]
        let elapsedSeconds: Double
        let failureReason: String?
    }

    private static let allWarmAgents = [
        "Grok-Diretor",
        "Grok-Cortador",
        "Grok-Prints",
        "Grok-Titulos",
        "Grok-Colorista",
        "Grok-Audio",
    ]

    func cancelAll() {
        lock.lock()
        cancelled = true
        let procs = activeProcesses
        activeProcesses.removeAll()
        lock.unlock()
        for p in procs where p.isRunning { p.terminate() }
    }

    /// Plans across all selected specialist models concurrently, auto-recovers if any specialist fails/empties,
    /// merges non-conflicting lanes, and executes once on the warm local Swarm.
    func orchestrate(goal: String, models: [SpecialistModel], stateJSON: String,
                     tasteSummary: String, swarm: SwarmHTTPClient) async -> String {
        lock.lock()
        cancelled = false
        lock.unlock()

        let team = models.isEmpty ? [.openai] : models
        let multi = team.count > 1
        VoiceLog.info("Orchestrate START team=\(team.map(\.rawValue).joined(separator: "+")) goal=\(String(goal.prefix(160)))")

        // Run all selected models in parallel.
        let results: [PlanResult] = await withTaskGroup(of: PlanResult.self) { group in
            for m in team {
                group.addTask { [weak self] in
                    guard let self else { return PlanResult(model: m, lanes: [], elapsedSeconds: 0, failureReason: "cancelled") }
                    let prompt = Self.buildSpecialistPrompt(goal: goal, model: m, multiTeam: multi,
                                                            stateJSON: stateJSON, tasteSummary: tasteSummary)
                    return await self.planLanes(with: m, prompt: prompt)
                }
            }
            var collected: [PlanResult] = []
            for await r in group { collected.append(r) }
            return collected
        }

        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled {
            return "{\"status\":\"cancelled\",\"spoken_feedback\":\"Cancelado antes de aplicar.\"}"
        }

        var mergedLanes: [[String: Any]] = []
        var usedAgents = Set<String>()
        var contributors: [String] = []
        var failures: [String] = []

        for r in results {
            if let fail = r.failureReason {
                failures.append("\(r.model.label): \(fail)")
                VoiceLog.info("Specialist \(r.model.rawValue) FAILED in \(String(format: "%.2f", r.elapsedSeconds))s: \(fail)")
            } else {
                VoiceLog.info("Specialist \(r.model.rawValue) returned \(r.lanes.count) lanes in \(String(format: "%.2f", r.elapsedSeconds))s")
            }
            guard !r.lanes.isEmpty else { continue }
            contributors.append(r.model.label)
            for var lane in r.lanes {
                guard let ops = lane["ops"] as? [[String: Any]], !ops.isEmpty else { continue }
                let desired = (lane["agent"] as? String) ?? r.model.primaryAgent
                let agent = Self.pickAvailableAgent(desired: desired, fallback: r.model.primaryAgent, used: &usedAgents)
                lane["agent"] = agent
                lane["pace"] = SwarmHTTPClient.requiredPace
                mergedLanes.append(lane)
            }
        }

        // Rock-solid auto-recovery: if mergedLanes is empty (e.g. Claude hit quota, CLI timed out, or siloed models returned []),
        // immediately run a 1.3s full-scope multi-lane plan on OpenAI GPT-4.1 so the user's edit ALWAYS executes!
        if mergedLanes.isEmpty {
            VoiceLog.info("Orchestrate fallback -> running full-scope OpenAI GPT-4.1 planner (prior failures: \(failures.joined(separator: "; ")))")
            let recoveryPrompt = Self.buildSpecialistPrompt(
                goal: goal,
                model: .openai,
                multiTeam: false,
                stateJSON: stateJSON,
                tasteSummary: tasteSummary
            )
            let recovery = await planLanes(with: .openai, prompt: recoveryPrompt)
            VoiceLog.info("Fallback OpenAI returned \(recovery.lanes.count) lanes in \(String(format: "%.2f", recovery.elapsedSeconds))s (err=\(recovery.failureReason ?? "none"))")
            if !recovery.lanes.isEmpty {
                contributors = ["OpenAI GPT-4.1 (recuperação)"]
                for var lane in recovery.lanes {
                    guard let ops = lane["ops"] as? [[String: Any]], !ops.isEmpty else { continue }
                    let desired = (lane["agent"] as? String) ?? "Grok-Diretor"
                    let agent = Self.pickAvailableAgent(desired: desired, fallback: "Grok-Diretor", used: &usedAgents)
                    lane["agent"] = agent
                    lane["pace"] = SwarmHTTPClient.requiredPace
                    mergedLanes.append(lane)
                }
            }
        }

        guard !mergedLanes.isEmpty else {
            let reason = failures.isEmpty ? "nenhuma operação gerada" : failures.joined(separator: " | ")
            VoiceLog.info("Orchestrate EMPTY after recovery: \(reason)")
            return "{\"status\":\"error\",\"error\":\"Nenhum modelo retornou operações válidas (\(reason.replacingOccurrences(of: "\"", with: "'"))).\"}"
        }

        do {
            let execResult = try await swarm.execEdit(payload: [
                "pace": SwarmHTTPClient.requiredPace,
                "lanes": mergedLanes,
            ])
            VoiceLog.info("Orchestrate SWARM exec result: \(String(execResult.prefix(350)))")
            let modelsList = contributors.joined(separator: " + ")
            return "{\"status\":\"ok\",\"models\":[\"\(modelsList)\"],\"lanes_count\":\(mergedLanes.count),\"swarm\":\(execResult)}"
        } catch {
            let msg = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
            VoiceLog.info("Orchestrate SWARM exec ERROR: \(msg)")
            return "{\"status\":\"error\",\"error\":\"\(msg)\"}"
        }
    }

    private static func pickAvailableAgent(desired: String, fallback: String, used: inout Set<String>) -> String {
        if SwarmHTTPClient.allowedAgents.contains(desired) && !used.contains(desired) {
            used.insert(desired)
            return desired
        }
        if !used.contains(fallback) {
            used.insert(fallback)
            return fallback
        }
        if let free = allWarmAgents.first(where: { !used.contains($0) }) {
            used.insert(free)
            return free
        }
        return desired
    }

    /// Full, accurate Editroom-Pro EditDSL tool catalog shared by both full-scope and specialist planners.
    static let editDSLToolReference = """
    FERRAMENTAS MCP SUPORTADAS NO EDITROOM-PRO (todas funcionam via "tool" + "args"):
    - Estrutura & cortes:
      * add_track: args {kind: "video"|"audio"} (SEM target)
      * add_clip: args {asset_id: "...", start: SEG, track: "V2", source_start?: SEG, duration?: SEG} (SEM target; use save_v:"c2" para guardar ID do clipe criado e depois referenciar com clip_id:"$c2" na mesma lane!)
      * duplicate_clip: target ou clip_id, args {start?: SEG}
      * split_clip: target ou clip_id, args {at: SEGUNDOS}
      * trim_clip: target ou clip_id, args {start?: SEG, end?: SEG}
      * move_clip: target ou clip_id, args {start: SEG, track?: "V2"}
      * delete_clips: target + id_field:"clip_ids", args {ripple?: true|false}
      * remove_silences: args {threshold_db?: -34, min_silence?: 0.45, padding?: 0.08}
      * set_sequence: args {width: 1080, height: 1920, fps: 60} (SEM target)
    - Enquadramento, recorte, máscara e recorte IA (Editroom-Pro!):
      * set_transform: target ou clip_id, args {scale?: 0.05..10, x?: -1..1, y?: -1..1, rotation?: -360..360, opacity?: 0..1, flip_h?: bool, flip_v?: bool, crop_left?: 0..0.95, crop_right?: 0..0.95, crop_top?: 0..0.95, crop_bottom?: 0..0.95, mask_shape?: "none"|"roundedRect"|"ellipse"|"circle"}
        (Nota de coordenadas: x=0,y=0 é centro; y positivo = MAIS BAIXO no quadro; y negativo = MAIS ALTO no quadro; x positivo = direita; x negativo = esquerda.)
      * set_crop: target ou clip_id, args {left?: 0..0.95, right?: 0..0.95, top?: 0..0.95, bottom?: 0..0.95, reset?: bool}
      * set_mask: target ou clip_id, args {shape: "none"|"roundedRect"|"ellipse"|"circle", corner_radius?: 0..0.5, feather?: 0..0.25, reset?: bool}
      * set_background_removal: target ou clip_id, args {enabled: true|false, mode: "aiSubject"|"aiPerson"|"aiCard"|"chromaKey", tolerance?: 0..1, softness?: 0..1, edge_shift?: -1..1, blur_background?: 0..1}
      * set_clip_style: target ou clip_id, args {preset?: "cardPolish"|"none", shadow_opacity?: 0..1, shadow_radius?: 0..80, border_width?: 0..40, border_color?: "#FFFFFF", corner_radius?: 0..0.5}
      * set_animation: target ou clip_id, args {in?: "fade"|"pop"|"slideUp"|"slideDown"|"zoomIn", out?: ..., loop?: "kenBurns"|"float"}
      * set_highlighter: target ou clip_id, args {enabled: true, x: 0.5, y: 0.35, width: 0.7, height: 0.08, color: "#FDE047"}
      * set_privacy_blur: target ou clip_id, args {enabled: true, x: 0.5, y: 0.5, width: 0.25, height: 0.25, strength: 0.8, pixelate?: true}
      * set_lower_third: target ou clip_id, args {enabled: true, title: "...", subtitle?: "...", accent_color?: "#F5C542", y?: 0.82}
      * auto_reframe_face: target ou clip_id, args {}
    - Cor, títulos, legendas, áudio e macros:
      * set_grade: target + id_field:"clip_ids", args {look?: "Teal and orange", look_intensity?: 0.35, exposure?: ..., contrast?: ..., saturation?: ...}
      * add_title: args {text: "...", start: SEG, duration: SEG, track?: "V3"} (SEM target; use save_id:"t1" para estilizar na op seguinte!)
      * set_title_style: target ou clip_id, args {text?: "...", size?: 72, bold?: true, color?: "#FFFFFF", x?: 0.5, y?: 0.08}
      * set_captions: args {enabled: true, style?: ..., position?: 0.77} (SEM target)
      * set_audio: target ou clip_id, args {gain_db?: 2.0, fade_in?: 0.12, fade_out?: 0.12}
      * set_voice_enhance: target ou clip_id, args {enabled: true}
      * apply_news_reel_macro: args {} (SEM target)
      * playback: args {action: "play"|"pause"|"seek", time?: SEG} (SEM target)
      * history: args {action: "undo"|"redo"} (SEM target)
    RECEITA SPLIT-SCREEN (apresentador embaixo + prints/matéria em cima a partir de 1 vídeo horizontal 16:9 na V1):
    - Na lane Grok-Diretor (V1 apresentador embaixo): use set_crop + set_transform na V1 (ex.: se o apresentador está no canto direito da tela 16:9, crop_left ~0.58 para isolar só o apresentador, scale ~2.3, x ~-0.0, y ~0.27 para colocá-lo limpo na metade INFERIOR do quadro 9:16; ou no formato Kim padrão scale: 2.58, x: 0.87, y: 0.30).
    - Na lane Grok-Prints (V2 matéria/print em cima): se ainda não houver clipe na V2, faça add_track {kind:"video"}, depois add_clip com o MESMO asset_id da mídia principal (start: 0, track: "V2", save_v: "top_card") e em seguida clip_id: "$top_card" com set_crop {right: 0.38, top: 0.05, bottom: 0.08} + set_transform {scale: 1.55, x: 0.0, y: -0.24} + set_clip_style {preset: "cardPolish"} (e nunca use target em add_track ou add_clip!).
    - IMPORTANTE: Se uma lane cria V2 com add_track + add_clip, faça os ajustes desse novo clipe NA MESMA LANE usando save_v:"c2" e clip_id:"$c2", enquanto outra lane (ex. Grok-Diretor) ajusta a V1 em paralelo!
    """

    private static func buildSpecialistPrompt(goal: String, model: SpecialistModel, multiTeam: Bool,
                                              stateJSON: String, tasteSummary: String) -> String {
        let scopeNote = multiTeam
            ? "Você faz parte de uma equipe multi-modelo trabalhando em paralelo. Cuide APENAS da sua frente: \(model.trackDomain). Se o pedido não envolver sua frente, devolva {\"pace\": 0.3, \"lanes\": []}."
            : "Planeje TODAS as lanes necessárias (dividindo em 2 a 4 agentes paralelos quando fizer sentido, sem colidir na mesma track!) para cumprir o pedido completo do usuário de forma imediata e executável."
        return """
        Retorne APENAS um JSON puro no formato {"pace": 0.3, "lanes": [{"agent": "...", "ops": [{"tool": "...", "target": "...", "args": {...}}]}]} sem markdown e sem explicações.
        REGRAS OBRIGATÓRIAS:
        - "pace" SEMPRE 0.3.
        - Parâmetros de cada tool SEMPRE dentro de "args".
        - Agentes permitidos: Grok-Diretor, Grok-Cortador, Grok-Prints, Grok-Titulos, Grok-Colorista, Grok-Audio.
        - Seletores em "target": all_v1, all_v2, all_a1, all_video, all_audio, all_titles, track:V1, track:V2, track:V3, playhead, playhead:V1, at:SEGUNDOS:TRACK, range:INICIO-FIM:TRACK.
        - NUNCA coloque "target" em add_track, add_clip, add_title, add_solid, set_sequence, playback ou history!
        - Tools com clip_ids (set_grade, delete_clips, remove_silences): use "id_field": "clip_ids".
        - NUNCA invente asset_id ou clip_id: use os IDs REAIS do ESTADO ATUAL DA TIMELINE abaixo ou seletores válidos (all_v1, all_a1, etc.).
        \(editDSLToolReference)
        \(scopeNote)
        \(tasteSummary.isEmpty ? "" : tasteSummary + "\n")
        ESTADO ATUAL DA TIMELINE (JSON):
        \(String(stateJSON.prefix(6500)))

        PEDIDO DO USUÁRIO:
        \(goal)
        """
    }

    private func planLanes(with model: SpecialistModel, prompt: String) async -> PlanResult {
        let t0 = Date()
        let outcome: (text: String?, error: String?)
        switch model {
        case .openai:
            outcome = await callOpenAIJSON(prompt: prompt)
        case .claude:
            outcome = await runCLI(
                executable: resolveCLI("claude"),
                args: ["-p", prompt, "--model", "fable", "--tools", "", "--no-session-persistence", "--output-format", "text"],
                timeout: 15
            )
        case .gemini:
            outcome = await runCLI(
                executable: resolveCLI("agy"),
                args: ["-p", prompt, "--model", "gemini-4-neon-high", "--disable-slash-commands"],
                timeout: 16
            )
        case .grok:
            outcome = await runCLI(
                executable: resolveCLI("grok"),
                args: ["--no-auto-update", "-p", prompt],
                timeout: 16
            )
        }
        let elapsed = Date().timeIntervalSince(t0)
        if let err = outcome.error {
            return PlanResult(model: model, lanes: [], elapsedSeconds: elapsed, failureReason: err)
        }
        guard let rawText = outcome.text, !rawText.isEmpty else {
            return PlanResult(model: model, lanes: [], elapsedSeconds: elapsed, failureReason: "resposta vazia")
        }
        let lanes = Self.extractLanes(from: rawText)
        return PlanResult(model: model, lanes: lanes, elapsedSeconds: elapsed, failureReason: nil)
    }

    private func callOpenAIJSON(prompt: String) async -> (text: String?, error: String?) {
        guard let key = VoiceKeychain.loadAPIKey(for: .openai) else {
            return (nil, "OPENAI_API_KEY ausente")
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "gpt-4.1",
            "temperature": 0.1,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": "Você é um diretor técnico especialista em Editroom-Pro. Converta o pedido de edição em JSON EditDSL executável, preciso e sem erros."],
                ["role": "user", "content": prompt],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
                return (nil, "HTTP \(code): \(snippet)")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                return (nil, "JSON inesperado da OpenAI")
            }
            return (content, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func resolveCLI(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "\(home)/.grok/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runCLI(executable: String?, args: [String], timeout: Double) async -> (text: String?, error: String?) {
        guard let executable else { return (nil, "CLI não instalada") }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { cont.resume(returning: (nil, "cancelado")); return }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.grok/bin:\(NSHomeDirectory())/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                proc.environment = env

                self.lock.lock()
                if self.cancelled {
                    self.lock.unlock()
                    cont.resume(returning: (nil, "cancelado"))
                    return
                }
                self.activeProcesses.append(proc)
                self.lock.unlock()

                var timedOut = false
                let timer = DispatchSource.makeTimerSource()
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    timedOut = true
                    if proc.isRunning { proc.terminate() }
                }
                timer.resume()

                do {
                    try proc.run()
                    // Drain stderr asynchronously so pipes never deadlock on large output.
                    var errData = Data()
                    let errGroup = DispatchGroup()
                    errGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        errGroup.leave()
                    }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    errGroup.wait()
                    timer.cancel()

                    self.lock.lock()
                    self.activeProcesses.removeAll { $0 === proc }
                    self.lock.unlock()

                    let outStr = String(data: outData, encoding: .utf8) ?? ""
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    if timedOut {
                        cont.resume(returning: (nil, "timeout \(Int(timeout))s"))
                    } else if proc.terminationStatus != 0 {
                        let msg = (outStr.isEmpty ? errStr : outStr).trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(returning: (nil, "exit \(proc.terminationStatus): \(String(msg.prefix(140)))"))
                    } else {
                        cont.resume(returning: (outStr, nil))
                    }
                } catch {
                    timer.cancel()
                    cont.resume(returning: (nil, error.localizedDescription))
                }
            }
        }
    }

    /// Safely extracts `lanes` JSON array from raw model output (even if wrapped in markdown fences).
    static func extractLanes(from raw: String) -> [[String: Any]] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else { return [] }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let normalized = SwarmHTTPClient.normalizePayload(obj)
        return (normalized["lanes"] as? [[String: Any]]) ?? []
    }
}
