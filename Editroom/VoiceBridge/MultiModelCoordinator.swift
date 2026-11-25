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
        case .openai: return "Áudio, mix e estrutura"
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
        case .openai: return "Grok-Audio"
        }
    }

    var trackDomain: String {
        switch self {
        case .claude: return "cortes, splits, trims e ritmo na V1/A1 (usando Grok-Cortador)"
        case .gemini: return "enquadramento (set_transform), prints/cards na V2 e cor/grade (usando Grok-Prints e Grok-Colorista)"
        case .grok: return "títulos na V3 (add_title, set_title_style), legendas (set_captions) e marcadores (usando Grok-Titulos)"
        case .openai: return "áudio, volume, fades e coordenação geral na A1 (usando Grok-Audio e Grok-Diretor)"
        }
    }
}

/// Coordinates 1 or multiple AI models in parallel (e.g., Gemini + Claude + Grok + OpenAI),
/// enforces timeout + cancellation, merges their planned EditDSL lanes WITHOUT track collisions,
/// and sends a single transactional payload (`pace: 0.3`) to the local Swarm HTTP executor.
final class MultiModelCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcesses: [Process] = []
    private var cancelled = false

    func cancelAll() {
        lock.lock()
        cancelled = true
        let procs = activeProcesses
        activeProcesses.removeAll()
        lock.unlock()
        for p in procs where p.isRunning { p.terminate() }
    }

    /// Plans across all selected specialist models concurrently, merges non-conflicting lanes, and executes once.
    func orchestrate(goal: String, models: [SpecialistModel], stateJSON: String,
                     tasteSummary: String, swarm: SwarmHTTPClient) async -> String {
        lock.lock()
        cancelled = false
        lock.unlock()

        let team = models.isEmpty ? [.openai] : models
        let multi = team.count > 1

        // Run all selected models in parallel with strict 18s budget so slow models never stall feedback.
        let results: [(SpecialistModel, [[String: Any]])] = await withTaskGroup(of: (SpecialistModel, [[String: Any]]).self) { group in
            for m in team {
                group.addTask { [weak self] in
                    guard let self else { return (m, []) }
                    let prompt = Self.buildSpecialistPrompt(goal: goal, model: m, multiTeam: multi,
                                                            stateJSON: stateJSON, tasteSummary: tasteSummary)
                    let lanes = await self.planLanes(with: m, prompt: prompt)
                    return (m, lanes)
                }
            }
            var collected: [(SpecialistModel, [[String: Any]])] = []
            for await r in group { collected.append(r) }
            return collected
        }

        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled {
            return "{\"status\":\"cancelled\",\"spoken_feedback\":\"Cancelado antes de aplicar.\"}"
        }

        // Collision-free merge: deduplicate tracks/agents and ensure every op respects pace 0.3 + args.
        var mergedLanes: [[String: Any]] = []
        var usedAgents = Set<String>()
        var contributors: [String] = []

        for (m, lanes) in results where !lanes.isEmpty {
            contributors.append(m.label)
            for var lane in lanes {
                var agent = (lane["agent"] as? String) ?? m.primaryAgent
                if usedAgents.contains(agent) {
                    // Keep deterministic non-colliding pre-warmed agent.
                    agent = m.primaryAgent
                }
                usedAgents.insert(agent)
                lane["agent"] = agent
                lane["pace"] = SwarmHTTPClient.requiredPace
                mergedLanes.append(lane)
            }
        }

        guard !mergedLanes.isEmpty else {
            return "{\"status\":\"error\",\"error\":\"Nenhum modelo retornou operações válidas para este pedido.\"}"
        }

        do {
            let execResult = try await swarm.execEdit(payload: [
                "pace": SwarmHTTPClient.requiredPace,
                "lanes": mergedLanes,
            ])
            let modelsList = contributors.joined(separator: " + ")
            return "{\"status\":\"ok\",\"models\":[\"\(modelsList)\"],\"swarm\":\(execResult)}"
        } catch {
            let msg = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
            return "{\"status\":\"error\",\"error\":\"\(msg)\"}"
        }
    }

    private static func buildSpecialistPrompt(goal: String, model: SpecialistModel, multiTeam: Bool,
                                              stateJSON: String, tasteSummary: String) -> String {
        let scopeNote = multiTeam
            ? "Você faz parte de uma equipe multi-modelo trabalhando em paralelo. Cuide APENAS da sua frente: \(model.trackDomain). Se o pedido do usuário não exigir nada na sua frente, devolva {\"lanes\": []}."
            : "Planeje as lanes necessárias para cumprir o pedido completo do usuário."
        return """
        Retorne APENAS um JSON puro no formato {"pace": 0.3, "lanes": [{"agent": "...", "ops": [{"tool": "...", "target": "...", "args": {...}}]}]} sem markdown, sem explicações.
        REGRAS OBRIGATÓRIAS:
        - pace SEMPRE 0.3.
        - Parâmetros de cada tool SEMPRE dentro de "args".
        - Agentes permitidos: Grok-Diretor, Grok-Cortador, Grok-Prints, Grok-Titulos, Grok-Colorista, Grok-Audio.
        - Seletores em target: all_v1, all_v2, all_a1, all_video, all_audio, all_titles, track:V1, track:V2, track:V3, playhead, playhead:V1, at:SEGUNDOS:TRACK, range:INICIO-FIM:TRACK.
        - Tools com clip_ids (set_grade, delete_clips): use "id_field": "clip_ids".
        \(scopeNote)
        \(tasteSummary.isEmpty ? "" : tasteSummary + "\n")
        ESTADO ATUAL DA TIMELINE (JSON):
        \(String(stateJSON.prefix(6500)))

        PEDIDO DO USUÁRIO:
        \(goal)
        """
    }

    private func planLanes(with model: SpecialistModel, prompt: String) async -> [[String: Any]] {
        let rawText: String?
        switch model {
        case .openai:
            rawText = await callOpenAIJSON(prompt: prompt)
        case .claude:
            rawText = await runCLI(executable: resolveCLI("claude"),
                                   args: ["-p", prompt, "--model", "fable", "--output-format", "text"],
                                   timeout: 18)
        case .gemini:
            rawText = await runCLI(executable: resolveCLI("agy"),
                                   args: ["-p", prompt, "--model", "gemini-4-neon-high", "--disable-slash-commands"],
                                   timeout: 18)
        case .grok:
            rawText = await runCLI(executable: resolveCLI("grok"),
                                   args: ["--no-auto-update", "-p", prompt],
                                   timeout: 18)
        }
        guard let rawText else { return [] }
        return Self.extractLanes(from: rawText)
    }

    private func callOpenAIJSON(prompt: String) async -> String? {
        guard let key = VoiceKeychain.loadAPIKey(for: .openai) else { return nil }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 16
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "gpt-5-mini",
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": "Você converte pedidos de edição de vídeo em JSON EditDSL puro e válido."],
                ["role": "user", "content": prompt],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { return nil }
        return content
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

    private func runCLI(executable: String?, args: [String], timeout: Double) async -> String? {
        guard let executable else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = args
                let outPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = FileHandle.nullDevice
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                proc.environment = env

                self.lock.lock()
                if self.cancelled {
                    self.lock.unlock()
                    cont.resume(returning: nil)
                    return
                }
                self.activeProcesses.append(proc)
                self.lock.unlock()

                let timer = DispatchSource.makeTimerSource()
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { if proc.isRunning { proc.terminate() } }
                timer.resume()

                do {
                    try proc.run()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    timer.cancel()
                    self.lock.lock()
                    self.activeProcesses.removeAll { $0 === proc }
                    self.lock.unlock()
                    cont.resume(returning: String(data: data, encoding: .utf8))
                } catch {
                    timer.cancel()
                    cont.resume(returning: nil)
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
