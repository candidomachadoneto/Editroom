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
            out["lanes"] = rawLanes.map { lane -> [String: Any] in
                var l = lane
                l["agent"] = canonicalAgent(lane["agent"] as? String)
                l["pace"] = requiredPace
                if let ops = lane["ops"] as? [[String: Any]] {
                    l["ops"] = ops.map(normalizeOp)
                }
                return l
            }
        } else if let rawOps = input["ops"] as? [[String: Any]] {
            let agent = canonicalAgent(input["agent"] as? String)
            out["lanes"] = [[
                "agent": agent,
                "pace": requiredPace,
                "ops": rawOps.map(normalizeOp),
            ]]
            out.removeValue(forKey: "ops")
            out.removeValue(forKey: "agent")
        }
        return out
    }

    private static func normalizeOp(_ op: [String: Any]) -> [String: Any] {
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
