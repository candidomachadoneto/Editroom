import Foundation
import SQLite3

/// A learned editing taste preference with explicit scope, provenance, and confidence.
struct EditingPreference: Identifiable, Codable, Equatable {
    enum Scope: String, Codable {
        case global
        case project
    }

    enum Source: String, Codable {
        case explicit
        case pattern
    }

    let id: String
    var rule: String
    var category: String
    var scope: Scope
    var projectID: String
    var source: Source
    var confidence: Double
    var evidenceCount: Int
    var updatedAt: Double
}

/// Self-improving editing taste store backed by local SQLite (WAL mode, crash-safe)
/// with automatic human-readable JSON export and non-blocking async Supermemory sync.
///
/// Follows conservative anti-pollution rules:
/// - Explicit spoken preferences (`remember_preference`) apply immediately with scope (`global` vs `project`).
/// - Single `undo` events are logged in `interactions` and NEVER promoted directly to global rules.
/// - Recurring patterns (`>= 3` consistent observations) surface as candidate patterns with provenance.
/// - Every preference can be inspected or deleted instantly by voice or UI.
final class EditingTasteDB: @unchecked Sendable {
    static let shared = EditingTasteDB()

    private let queue = DispatchQueue(label: "editroom.voicebridge.taste-db", qos: .utility)
    private var db: OpaquePointer?
    private let dbURL: URL
    private let jsonExportURL: URL
    private let supermemoryURL = URL(string: "http://100.116.235.113:6767/v3/documents")!

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dbURL = dir.appendingPathComponent("editing_taste.sqlite")
        self.jsonExportURL = dir.appendingPathComponent("editing_taste.json")
        queue.sync {
            openAndMigrateLocked()
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Public API

    func allPreferences(projectID: String? = nil) -> [EditingPreference] {
        queue.sync {
            queryPreferencesLocked(projectID: projectID)
        }
    }

    /// Saves or reinforces a preference rule. Explicit voice rules immediately have confidence 1.0.
    @discardableResult
    func savePreference(rule: String, category: String = "style", scope: EditingPreference.Scope = .global,
                        projectID: String = "", source: EditingPreference.Source = .explicit) -> EditingPreference {
        let cleanRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCat = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date().timeIntervalSince1970
        let pref = queue.sync { () -> EditingPreference in
            // Deduplicate by normalized rule text within the same scope.
            let existing = queryPreferencesLocked(projectID: nil).first {
                $0.scope == scope && $0.rule.caseInsensitiveCompare(cleanRule) == .orderedSame
            }
            if var ex = existing {
                ex.evidenceCount += 1
                ex.confidence = source == .explicit ? 1.0 : min(0.95, ex.confidence + 0.15)
                ex.updatedAt = now
                upsertPreferenceLocked(ex)
                exportJSONLocked()
                return ex
            }
            let item = EditingPreference(
                id: UUID().uuidString,
                rule: cleanRule,
                category: cleanCat.isEmpty ? "style" : cleanCat,
                scope: scope,
                projectID: scope == .project ? projectID : "",
                source: source,
                confidence: source == .explicit ? 1.0 : 0.65,
                evidenceCount: 1,
                updatedAt: now
            )
            upsertPreferenceLocked(item)
            exportJSONLocked()
            return item
        }
        if source == .explicit && scope == .global {
            syncToSupermemoryAsync(pref)
        }
        return pref
    }

    /// Removes a preference by exact ID or fuzzy text match. Returns count deleted.
    @discardableResult
    func removePreference(matching query: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return 0 }
        return queue.sync {
            let all = queryPreferencesLocked(projectID: nil)
            let hits = all.filter { $0.id.lowercased() == q || $0.rule.lowercased().contains(q) }
            for h in hits {
                deletePreferenceLocked(id: h.id)
            }
            if !hits.isEmpty { exportJSONLocked() }
            return hits.count
        }
    }

    func deletePreference(id: String) {
        queue.sync {
            deletePreferenceLocked(id: id)
            exportJSONLocked()
        }
    }

    /// Logs an executed voice command in episodic history (used for recurring pattern detection).
    func logInteraction(projectID: String, summary: String, toolsSignature: String, outcome: String) {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "INSERT INTO interactions (id, ts, project_id, summary, tools_sig, undone, outcome) VALUES (?, ?, ?, ?, ?, 0, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let id = UUID().uuidString
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_text(stmt, 3, (projectID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (summary as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (toolsSignature as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (outcome as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            self.evaluateRecurringPatternsLocked(toolsSignature: toolsSignature, summary: summary)
        }
    }

    /// Marks the most recent interaction (within 25s) as undone.
    /// Per Conselho verdict: a single undo is NEVER promoted to a global taste rule; it only records evidence.
    func markRecentInteractionUndone() {
        let cutoff = Date().timeIntervalSince1970 - 25
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
            UPDATE interactions SET undone = 1
            WHERE id = (SELECT id FROM interactions WHERE ts >= ? AND undone = 0 ORDER BY ts DESC LIMIT 1);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
    }

    /// Compact bullet summary injected into the Realtime voice session prompt (bounded to top 14 rules so prompt stays fast).
    func promptSummary(projectID: String = "") -> String {
        let prefs = allPreferences(projectID: projectID)
            .filter { $0.confidence >= 0.7 }
            .prefix(14)
        guard !prefs.isEmpty else { return "" }
        let lines = prefs.map { p -> String in
            let tag = p.scope == .project ? "[este projeto]" : "[sempre]"
            return "- \(tag) (\(p.category)) \(p.rule)"
        }
        return "PREFERÊNCIAS APRENDIDAS DO MAFINHA (respeite sempre):\n" + lines.joined(separator: "\n")
    }

    // MARK: SQLite Internals

    private func openAndMigrateLocked() {
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else { return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
        let ddl = """
        CREATE TABLE IF NOT EXISTS preferences (
            id TEXT PRIMARY KEY,
            rule TEXT NOT NULL,
            category TEXT NOT NULL,
            scope TEXT NOT NULL,
            project_id TEXT NOT NULL,
            source TEXT NOT NULL,
            confidence REAL NOT NULL,
            evidence_count INTEGER NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS interactions (
            id TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            project_id TEXT NOT NULL,
            summary TEXT NOT NULL,
            tools_sig TEXT NOT NULL,
            undone INTEGER NOT NULL DEFAULT 0,
            outcome TEXT NOT NULL
        );
        """
        sqlite3_exec(db, ddl, nil, nil, nil)
    }

    private func upsertPreferenceLocked(_ p: EditingPreference) {
        guard let db else { return }
        let sql = """
        INSERT INTO preferences (id, rule, category, scope, project_id, source, confidence, evidence_count, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            rule=excluded.rule, category=excluded.category, scope=excluded.scope,
            project_id=excluded.project_id, source=excluded.source, confidence=excluded.confidence,
            evidence_count=excluded.evidence_count, updated_at=excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (p.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (p.rule as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (p.category as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (p.scope.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (p.projectID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (p.source.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 7, p.confidence)
        sqlite3_bind_int(stmt, 8, Int32(p.evidenceCount))
        sqlite3_bind_double(stmt, 9, p.updatedAt)
        sqlite3_step(stmt)
    }

    private func deletePreferenceLocked(id: String) {
        guard let db else { return }
        let sql = "DELETE FROM preferences WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    private func queryPreferencesLocked(projectID: String?) -> [EditingPreference] {
        guard let db else { return [] }
        let sql: String
        if let pid = projectID, !pid.isEmpty {
            sql = "SELECT id, rule, category, scope, project_id, source, confidence, evidence_count, updated_at FROM preferences WHERE scope = 'global' OR (scope = 'project' AND project_id = ?) ORDER BY confidence DESC, updated_at DESC;"
        } else {
            sql = "SELECT id, rule, category, scope, project_id, source, confidence, evidence_count, updated_at FROM preferences ORDER BY confidence DESC, updated_at DESC;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let pid = projectID, !pid.isEmpty {
            sqlite3_bind_text(stmt, 1, (pid as NSString).utf8String, -1, nil)
        }
        var out: [EditingPreference] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            out.append(EditingPreference(
                id: col(0),
                rule: col(1),
                category: col(2),
                scope: EditingPreference.Scope(rawValue: col(3)) ?? .global,
                projectID: col(4),
                source: EditingPreference.Source(rawValue: col(5)) ?? .explicit,
                confidence: sqlite3_column_double(stmt, 6),
                evidenceCount: Int(sqlite3_column_int(stmt, 7)),
                updatedAt: sqlite3_column_double(stmt, 8)
            ))
        }
        return out
    }

    /// Promotes a recurring non-undone editing pattern ONLY after >= 3 successful repetitions (no noisy promotions).
    private func evaluateRecurringPatternsLocked(toolsSignature: String, summary: String) {
        guard let db, !toolsSignature.isEmpty, toolsSignature != "history:undo", toolsSignature != "playback" else { return }
        let sql = "SELECT COUNT(*) FROM interactions WHERE tools_sig = ? AND undone = 0 AND outcome = 'ok';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (toolsSignature as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let count = Int(sqlite3_column_int(stmt, 0))
            if count == 3 {
                let rule = "Padrão frequente aprovado (\(count)x): \(summary)"
                let exists = queryPreferencesLocked(projectID: nil).contains { $0.rule.localizedCaseInsensitiveContains(summary) }
                if !exists {
                    let pref = EditingPreference(
                        id: UUID().uuidString,
                        rule: rule,
                        category: "pattern",
                        scope: .global,
                        projectID: "",
                        source: .pattern,
                        confidence: 0.78,
                        evidenceCount: count,
                        updatedAt: Date().timeIntervalSince1970
                    )
                    upsertPreferenceLocked(pref)
                    exportJSONLocked()
                }
            }
        }
    }

    private func exportJSONLocked() {
        let items = queryPreferencesLocked(projectID: nil)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(items) {
            try? data.write(to: jsonExportURL, options: .atomic)
        }
    }

    /// Fire-and-forget async sync to local Supermemory (never blocks editing, never sends raw media).
    private func syncToSupermemoryAsync(_ pref: EditingPreference) {
        var req = URLRequest(url: supermemoryURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "content": "[Editroom Taste · \(pref.category)] \(pref.rule)",
            "containerTags": ["editroom-taste", "global"],
            "metadata": ["source": pref.source.rawValue, "category": pref.category],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }
}
