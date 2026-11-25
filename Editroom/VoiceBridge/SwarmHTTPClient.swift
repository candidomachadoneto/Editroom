import Foundation

/// Persistent HTTP keep-alive client for the local Editroom Swarm daemon (`http://127.0.0.1:7842`).
/// Never invokes the Python CLI (`editroom-swarm`); talks directly to the warm HTTP daemon.
final class SwarmHTTPClient: @unchecked Sendable {
    static let baseURL = URL(string: "http://127.0.0.1:7842")!
    static let allowedAgents: Set<String> = [
        "Grok-Diretor",
        "Grok-Cortador",
        "Grok-Prints",
        "Grok-Titulos",
        "Grok-Colorista",
        "Grok-Audio",
    ]
    static let requiredPace: Double = 0.3

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "Connection": "keep-alive",
            "Accept": "application/json",
        ]
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    /// Checks `GET /health` to warm the keep-alive TCP socket and verify pre-warmed cursors.
    func health() async -> (ok: Bool, cursors: [String]) {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("health"))
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true else {
                return (false, [])
            }
            return (true, obj["warm_cursors"] as? [String] ?? [])
        } catch {
            return (false, [])
        }
    }

    /// Calls `GET /state` and returns the compact timeline JSON string for the voice model.
    func getState() async throws -> String {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("state"))
        req.httpMethod = "GET"
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? "{}"
        guard code == 200 else {
            throw SwarmClientError("Falha ao ler o estado da timeline (HTTP \(code)).")
        }
        return body
    }

    /// Normalizes the EditDSL payload (enforcing `pace: 0.3`, warm agent names, `$var` fixes,
    /// and automatic parallel multi-agent fan-out for independent ops) and posts directly to
    /// `POST http://127.0.0.1:7842/exec`.
    func execEdit(payload rawPayload: [String: Any]) async throws -> String {
        let normalized = Self.normalizePayload(rawPayload)
        let bodyData = try JSONSerialization.data(withJSONObject: normalized, options: [])

        var req = URLRequest(url: Self.baseURL.appendingPathComponent("exec"))
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? "{}"
        guard (200..<300).contains(code) else {
            throw SwarmClientError("O enxame retornou erro HTTP \(code): \(body)")
        }
        return body
    }

    /// Enforces protocol rules and automatically fans out independent property ops across the
    /// 6 pre-warmed specialist agents so multiple colored cursors always work in true parallel!
    static func normalizePayload(_ input: [String: Any]) -> [String: Any] {
        var out = input
        // Rule 1.3: pace 0.3 is mandatory; 0.0 is forbidden.
        out["pace"] = requiredPace

        var normalizedLanes: [[String: Any]] = []
        if let rawLanes = input["lanes"] as? [[String: Any]] {
            for lane in rawLanes {
                guard let ops = lane["ops"] as? [[String: Any]] else { continue }
                let cleanOps = normalizeLaneOps(ops)
                guard !cleanOps.isEmpty else { continue }
                var l = lane
                l["agent"] = canonicalAgent(lane["agent"] as? String)
                l["pace"] = requiredPace
                l["ops"] = cleanOps
                normalizedLanes.append(l)
            }
        } else if let rawOps = input["ops"] as? [[String: Any]] {
            let cleanOps = normalizeLaneOps(rawOps)
            if !cleanOps.isEmpty {
                let agent = canonicalAgent(input["agent"] as? String)
                normalizedLanes.append([
                    "agent": agent,
                    "pace": requiredPace,
                    "ops": cleanOps,
                ])
            }
            out.removeValue(forKey: "ops")
            out.removeValue(forKey: "agent")
        }

        out["lanes"] = fanOutParallelLanes(normalizedLanes)
        return out
    }

    /// Tools that never take a `clip_id` selector target; stripping an accidental `target` prevents the daemon from skipping them.
    private static let nonTargetTools: Set<String> = [
        "add_track", "add_clip", "add_title", "add_solid", "set_sequence", "set_track",
        "playback", "history", "save_project", "apply_news_reel_macro", "auto_edit",
        "snapshot_frame", "set_marker", "delete_markers", "set_captions", "set_in_out",
        "export", "list_looks",
    ]

    /// Tools whose MCP schema expects `clip_ids: [String]` rather than singular `clip_id`.
    private static let pluralClipIDTools: Set<String> = [
        "set_grade", "delete_clips", "remove_silences",
    ]

    /// Property-level tools that commute cleanly across specialist lanes when they don't depend on `$var`.
    private static let fanOutSafeTools: Set<String> = [
        "set_crop", "set_transform", "set_mask", "set_background_removal", "set_clip_style",
        "set_grade", "set_animation", "set_keyframes", "set_highlighter", "set_privacy_blur",
        "set_lower_third", "set_title_style", "set_audio", "set_voice_enhance", "set_transition",
        "auto_reframe_face", "set_solid_color",
    ]

    private static let saveKeys: Set<String> = [
        "save_v", "save_a", "save_id", "save_split_v", "save_split_a",
    ]

    /// Normalizes all ops inside a lane in order, lifting misplaced `save_*` keys out of `args`
    /// and auto-prefixing bare references (e.g. `"clip_id": "top_card"` -> `"$top_card"`).
    private static func normalizeLaneOps(_ ops: [[String: Any]]) -> [[String: Any]] {
        var declaredVars = Set<String>()
        var result: [[String: Any]] = []
        for op in ops {
            guard let clean = normalizeOp(op, declaredVars: &declaredVars) else { continue }
            result.append(clean)
        }
        return result
    }

    private static func normalizeOp(_ op: [String: Any], declaredVars: inout Set<String>) -> [String: Any]? {
        guard let tool = op["tool"] as? String, !tool.isEmpty else { return nil }
        let reserved: Set<String> = [
            "tool", "target", "args", "id_field", "batch_ids", "delay",
            "save_v", "save_a", "save_id", "save_split_v", "save_split_a",
        ]
        var normalized = op
        var args = (op["args"] as? [String: Any]) ?? [:]

        // Lift any `save_*` keys accidentally placed inside `args` up to op top-level so the daemon extracts IDs!
        for sk in saveKeys {
            if let v = args[sk] as? String, !v.isEmpty {
                if normalized[sk] == nil { normalized[sk] = v }
                args.removeValue(forKey: sk)
            }
            if let v = normalized[sk] as? String, !v.isEmpty {
                declaredVars.insert(v)
            }
        }

        // Rescue any stray tool parameters placed at the op top-level into "args".
        for (k, v) in op where !reserved.contains(k) {
            if args[k] == nil { args[k] = v }
            normalized.removeValue(forKey: k)
        }

        // Auto-prefix bare saved var references (e.g. clip_id: "top_card" -> "$top_card").
        if let cid = args["clip_id"] as? String, !cid.hasPrefix("$"), declaredVars.contains(cid) {
            args["clip_id"] = "$\(cid)"
        }
        if let cids = args["clip_ids"] as? [String] {
            args["clip_ids"] = cids.map { (!$0.hasPrefix("$") && declaredVars.contains($0)) ? "$\($0)" : $0 }
        }

        // Strip invalid/empty targets or targets placed on project/track-level tools so the daemon never silently skips them.
        if let target = normalized["target"] as? String {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "none" || trimmed == "null" || nonTargetTools.contains(tool) {
                normalized.removeValue(forKey: "target")
            } else if trimmed.hasPrefix("$") || declaredVars.contains(trimmed) {
                let ref = trimmed.hasPrefix("$") ? trimmed : "$\(trimmed)"
                if pluralClipIDTools.contains(tool) {
                    if args["clip_ids"] == nil { args["clip_ids"] = [ref] }
                } else if args["clip_id"] == nil {
                    args["clip_id"] = ref
                }
                normalized.removeValue(forKey: "target")
            } else if trimmed.range(of: #"^[VvAa]\d+$"#, options: .regularExpression) != nil {
                // Auto-upgrade bare track name ("V1", "V2", "A1") to valid selector ("track:V2").
                normalized["target"] = "track:\(trimmed.uppercased())"
            } else {
                normalized["target"] = trimmed
            }
        }
        // Auto-fix id_field for plural clip_ids tools when target is used.
        if normalized["target"] != nil && pluralClipIDTools.contains(tool) && normalized["id_field"] == nil {
            normalized["id_field"] = "clip_ids"
        }
        // If args already explicitly specifies clip_id or clip_ids (e.g. "$v2_clip"), don't overwrite it via target.
        if args["clip_id"] != nil || args["clip_ids"] != nil {
            normalized.removeValue(forKey: "target")
        }
        normalized["args"] = args
        if let d = normalized["delay"] as? Double, d <= 0 {
            normalized["delay"] = requiredPace
        }
        return normalized
    }

    /// Fans out independent property ops packed into 1-2 lanes across the 6 specialized warm agents
    /// (`Grok-Cortador`, `Grok-Diretor`, `Grok-Prints`, `Grok-Colorista`, `Grok-Titulos`, `Grok-Audio`)
    /// so parallel colored nano-bots execute simultaneously instead of serially under a single cursor!
    private static func fanOutParallelLanes(_ lanes: [[String: Any]]) -> [[String: Any]] {
        var buckets: [String: [[String: Any]]] = [:]
        var agentOrder: [String] = []
        var pinnedLanes: [[String: Any]] = []

        func appendOp(_ op: [String: Any], to agent: String) {
            if buckets[agent] == nil {
                buckets[agent] = []
                agentOrder.append(agent)
            }
            buckets[agent]?.append(op)
        }

        for lane in lanes {
            let origAgent = canonicalAgent(lane["agent"] as? String)
            let ops = (lane["ops"] as? [[String: Any]]) ?? []
            // Keep lanes that use `save_*` / `$var` chaining or structural ordering strictly atomic!
            let hasSequentialDep = ops.contains { op in
                let tool = (op["tool"] as? String) ?? ""
                if !fanOutSafeTools.contains(tool) { return true }
                if saveKeys.contains(where: { op[$0] != nil }) { return true }
                if opUsesVarRef(op) { return true }
                return false
            }
            if hasSequentialDep {
                pinnedLanes.append(lane)
                continue
            }
            for op in ops {
                let tool = (op["tool"] as? String) ?? ""
                let specialized = specialistAgent(forTool: tool, fallback: origAgent)
                appendOp(op, to: specialized)
            }
        }

        var result = pinnedLanes
        for agent in agentOrder {
            guard let ops = buckets[agent], !ops.isEmpty else { continue }
            result.append([
                "agent": agent,
                "pace": requiredPace,
                "ops": ops,
            ])
        }
        return result
    }

    private static func opUsesVarRef(_ op: [String: Any]) -> Bool {
        guard let args = op["args"] as? [String: Any] else { return false }
        for v in args.values {
            if let s = v as? String, s.hasPrefix("$") { return true }
            if let arr = v as? [String], arr.contains(where: { $0.hasPrefix("$") }) { return true }
        }
        return false
    }

    private static func specialistAgent(forTool tool: String, fallback: String) -> String {
        switch tool {
        case "set_crop", "split_clip", "trim_clip", "remove_silences":
            return "Grok-Cortador"
        case "set_transform", "auto_reframe_face":
            return "Grok-Diretor"
        case "set_background_removal", "set_clip_style", "set_mask", "set_highlighter", "set_privacy_blur":
            return "Grok-Prints"
        case "set_grade", "set_solid_color":
            return "Grok-Colorista"
        case "add_title", "set_title_style", "set_animation", "set_keyframes", "set_lower_third", "set_captions", "set_transition":
            return "Grok-Titulos"
        case "set_audio", "set_voice_enhance":
            return "Grok-Audio"
        default:
            return fallback
        }
    }

    private static func canonicalAgent(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Grok-Diretor" }
        if allowedAgents.contains(raw) { return raw }
        let s = raw.lowercased()
        if s.contains("cort") || s.contains("cut") || s.contains("split") || s.contains("trim") { return "Grok-Cortador" }
        if s.contains("print") || s.contains("card") { return "Grok-Prints" }
        if s.contains("titul") || s.contains("title") || s.contains("caption") || s.contains("legend") { return "Grok-Titulos" }
        if s.contains("color") || s.contains("grade") || s.contains("look") { return "Grok-Colorista" }
        if s.contains("audio") || s.contains("som") || s.contains("sound") || s.contains("voz") { return "Grok-Audio" }
        return "Grok-Diretor"
    }
}

struct SwarmClientError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
