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

    /// Normalizes the EditDSL payload (enforcing `pace: 0.3` and warm agent names)
    /// and posts directly to `POST http://127.0.0.1:7842/exec`.
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

    /// Enforces protocol rules from Part 2:
    /// - `pace` is ALWAYS `0.3` (never `0.0`).
    /// - Only pre-warmed agent names are used (`Grok-Diretor`, `Grok-Cortador`, `Grok-Prints`, `Grok-Titulos`, `Grok-Colorista`, `Grok-Audio`).
    /// - Ensures every op puts its parameters inside `"args"`.
    static func normalizePayload(_ input: [String: Any]) -> [String: Any] {
        var out = input
        // Rule 1.3: pace 0.3 is mandatory; 0.0 is forbidden.
        out["pace"] = requiredPace

        if let rawLanes = input["lanes"] as? [[String: Any]] {
            out["lanes"] = rawLanes.compactMap { lane -> [String: Any]? in
                guard let ops = lane["ops"] as? [[String: Any]] else { return nil }
                let cleanOps = ops.compactMap(normalizeOp)
                guard !cleanOps.isEmpty else { return nil }
                var l = lane
                l["agent"] = canonicalAgent(lane["agent"] as? String)
                l["pace"] = requiredPace
                l["ops"] = cleanOps
                return l
            }
        } else if let rawOps = input["ops"] as? [[String: Any]] {
            let cleanOps = rawOps.compactMap(normalizeOp)
            if !cleanOps.isEmpty {
                let agent = canonicalAgent(input["agent"] as? String)
                out["lanes"] = [[
                    "agent": agent,
                    "pace": requiredPace,
                    "ops": cleanOps,
                ]]
            } else {
                out["lanes"] = []
            }
            out.removeValue(forKey: "ops")
            out.removeValue(forKey: "agent")
        }
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

    private static func normalizeOp(_ op: [String: Any]) -> [String: Any]? {
        guard let tool = op["tool"] as? String, !tool.isEmpty else { return nil }
        let reserved: Set<String> = [
            "tool", "target", "args", "id_field", "batch_ids", "delay",
            "save_v", "save_a", "save_id", "save_split_v", "save_split_a",
        ]
        var normalized = op
        var args = (op["args"] as? [String: Any]) ?? [:]
        // Rescue any stray tool parameters placed at the op top-level into "args".
        for (k, v) in op where !reserved.contains(k) {
            if args[k] == nil { args[k] = v }
            normalized.removeValue(forKey: k)
        }
        // Strip invalid/empty targets or targets placed on project/track-level tools so the daemon never silently skips them.
        if let target = normalized["target"] as? String {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "none" || trimmed == "null" || nonTargetTools.contains(tool) {
                normalized.removeValue(forKey: "target")
            } else if trimmed.hasPrefix("$") {
                // Saved variable reference from an earlier op in the same lane: pass via args, not snapshot target.
                if pluralClipIDTools.contains(tool) {
                    if args["clip_ids"] == nil { args["clip_ids"] = [trimmed] }
                } else if args["clip_id"] == nil {
                    args["clip_id"] = trimmed
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
