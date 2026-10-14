import Foundation
import os

/// Pure (non-UI) logic for overriding one of ChatGPT's keyboard commands through its keymap
/// file, `$CODEX_HOME/keybindings.json` (default `~/.codex/keybindings.json`).
///
/// ChatGPT's loader (app.asar, `src-*.js`: `oK = z.array(z.object({command: z.string(),
/// key: z.string().nullable()}))`) behaves like this, and this type mirrors it:
/// - Missing or whitespace-only file → no overrides. Invalid JSON or any entry failing
///   the schema → the whole file is ignored (warning logged), so we refuse to edit it.
/// - Several entries per command are allowed (several accelerators). If ANY entry for a
///   command has `key: null`, the command is unbound (`ZG()`).
/// - Legacy aliases (e.g. `focusQuickChat` → `openAvatarOverlay`) are dropped if an entry
///   for the current command id exists (`AK()`), so we leave those entries alone.
/// - The file is only read at launch (and when changed from ChatGPT's own UI).
///
/// Apply: move every existing entry for the command into a persisted backup and put our
/// marker `{"command":<id>,"key":<key or null>}` in their place.
/// Restore: only if the marker is still the sole entry for the command, swap the
/// backed-up entries back in; delete the file if we created it and it is empty again.
///
/// Several overrides (for different commands) can share the keymap file; each only
/// touches its own command's entries and keeps its own state file.
struct KeymapOverride {
    struct Target {
        /// ChatGPT command id, e.g. `openAvatarOverlay`.
        var commandID: String
        /// Older id ChatGPT still maps to `commandID` when no entry for it exists.
        var legacyCommandID: String?
        /// Electron accelerator to bind (e.g. `Alt+Space`), or nil to unbind the command.
        var key: String?
        /// Human-readable name for logs, e.g. "Show Mini".
        var displayName: String
        /// Basename of the state file in Application Support/ChatGPTCompanion.
        var stateName: String
    }

    let target: Target
    /// Keymap file we edit when applying.
    let keymapURL: URL
    /// Sidecar holding the backup and the write log (survives SIGKILL).
    let stateURL: URL
    var log: Logger
    var now: () -> Date = Date.init
    /// Whether `keymapURL` was given explicitly (tests); only default paths are re-resolved.
    private let pinnedKeymapURL: Bool

    init(target: Target, keymapURL: URL? = nil, stateURL: URL? = nil) {
        self.target = target
        self.pinnedKeymapURL = keymapURL != nil
        self.keymapURL = keymapURL ?? Self.defaultKeymapURL()
        self.stateURL = stateURL ?? Self.defaultStateURL(name: target.stateName)
        self.log = Log.make(target.stateName)
    }

    /// Same target and state file, default keymap path re-resolved (CODEX_HOME may have changed).
    func reresolved() -> KeymapOverride {
        guard !pinnedKeymapURL else { return self }
        var copy = KeymapOverride(target: target, stateURL: stateURL)
        copy.now = now
        return copy
    }

    var marker: OrderedJSON {
        .object([
            .init(key: "command", value: .string(target.commandID)),
            .init(key: "key", value: target.key.map(OrderedJSON.string) ?? .null),
        ])
    }

    // MARK: Paths

    /// Mirrors ChatGPT's `process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex")`
    /// (an empty CODEX_HOME is treated as unset here).
    static func defaultKeymapURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home: URL
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            home = URL(fileURLWithPath: codexHome, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        return home.appendingPathComponent("keybindings.json")
    }

    static func defaultStateURL(name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ChatGPTCompanion/\(name).json") // pre-rename folder; holds keymap backups, keep
    }

    // MARK: Persisted state

    struct Backup: Codable, Equatable {
        var keymapPath: String
        var fileExisted: Bool
        /// Exact original contents when the file existed but held no entries (blank or `[]`).
        var originalTextIfEmpty: String?
        var directoryCreated: Bool
        /// Prior entries for the command (compact JSON), in file order.
        var priorEntries: [String]
        var createdAt: Date
    }

    struct WriteRecord: Codable, Equatable {
        var date: Date
        /// Whether the override was in effect according to the file before / after.
        /// (Field names predate the generalisation; kept so existing state files decode.)
        var appliedBefore: Bool
        var appliedAfter: Bool

        enum CodingKeys: String, CodingKey {
            case date
            case appliedBefore = "disabledBefore"
            case appliedAfter = "disabledAfter"
        }
    }

    struct State: Codable, Equatable {
        var backup: Backup?
        var writes: [WriteRecord] = []
    }

    func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL) else { return State() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(State.self, from: data)
        } catch {
            log.error("Ignoring unreadable state file: \(error.localizedDescription, privacy: .public)")
            return State()
        }
    }

    func saveState(_ state: State) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    // MARK: Reading the keymap

    enum KeymapError: LocalizedError {
        case malformed(path: String, detail: String)
        case invalidSchema(path: String, detail: String)
        case io(path: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .malformed(let path, _): "\(path) is not valid JSON, so it was left untouched."
            case .invalidSchema(let path, _): "\(path) is not in the format ChatGPT expects, so it was left untouched."
            case .io(let path, let detail): "Couldn't access \(path): \(detail)"
            }
        }

        var detail: String {
            switch self {
            case .malformed(_, let d), .invalidSchema(_, let d), .io(_, let d): d
            }
        }

        var featureError: FeatureError {
            switch self {
            case .malformed, .invalidSchema:
                FeatureError(errorDescription ?? "", recoverySuggestion:
                    "ChatGPT currently ignores this file entirely (\(detail)). Fix or delete it, then try again.")
            case .io:
                FeatureError(errorDescription ?? "")
            }
        }
    }

    struct Snapshot {
        var exists: Bool
        var text: String?
        var entries: [OrderedJSON]
    }

    /// Follow a symlinked keymap (e.g. dotfiles) so the atomic rename replaces the target.
    private func resolved(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

    func read(_ url: URL) throws -> Snapshot {
        let url = resolved(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Snapshot(exists: false, text: nil, entries: [])
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw KeymapError.io(path: url.path, detail: error.localizedDescription)
        }
        // Node's readFile(..., "utf8") keeps a BOM and JSON.parse then fails, so ChatGPT ignores such a file.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            throw KeymapError.malformed(path: url.path, detail: "file starts with a UTF-8 BOM")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeymapError.malformed(path: url.path, detail: "file is not valid UTF-8")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Snapshot(exists: true, text: text, entries: [])
        }
        let value: OrderedJSON
        do {
            value = try OrderedJSON.parse(text)
        } catch {
            throw KeymapError.malformed(path: url.path, detail: String(describing: error))
        }
        guard case .array(let items) = value else {
            throw KeymapError.invalidSchema(path: url.path, detail: "top level is not an array")
        }
        for (i, item) in items.enumerated() {
            guard case .string = item["command"] ?? .null else {
                throw KeymapError.invalidSchema(path: url.path, detail: "entry \(i) has no string \"command\"")
            }
            switch item["key"] {
            case .string?, .null?: break
            default: throw KeymapError.invalidSchema(path: url.path, detail: "entry \(i) \"key\" must be a string or null")
            }
        }
        return Snapshot(exists: true, text: text, entries: items)
    }

    /// Current entries of the keymap file (nil if it can't be read or parsed).
    func currentEntries() -> [OrderedJSON]? { try? read(keymapURL).entries }

    static func command(of entry: OrderedJSON) -> String? {
        if case .string(let s)? = entry["command"] { return s }
        return nil
    }

    func isOurs(_ entry: OrderedJSON) -> Bool {
        guard case .object(let members) = entry, members.count == 2 else { return false }
        return Self.command(of: entry) == target.commandID && entry["key"] == marker["key"]
    }

    /// Entries ChatGPT uses for `commandID` (falls back to the legacy alias when there are none).
    static func effectiveEntries(for commandID: String, legacy: String? = nil, in entries: [OrderedJSON]) -> [OrderedJSON] {
        var relevant = entries.filter { command(of: $0) == commandID }
        if relevant.isEmpty, let legacy { relevant = entries.filter { command(of: $0) == legacy } }
        return relevant
    }

    /// Whether ChatGPT would apply this override given the file's entries: unbound when
    /// targeting nil, otherwise bound (not unbound) and including the target key.
    func isApplied(_ entries: [OrderedJSON]) -> Bool {
        let relevant = Self.effectiveEntries(for: target.commandID, legacy: target.legacyCommandID, in: entries)
        let unbound = relevant.contains { $0["key"] == .null }
        guard let key = target.key else { return unbound }
        return !unbound && relevant.contains { $0["key"] == .string(key) }
    }

    private func write(_ entries: [OrderedJSON], to url: URL) throws {
        let url = resolved(url)
        let text = OrderedJSON.array(entries).stringified() + "\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw KeymapError.io(path: url.path, detail: error.localizedDescription)
        }
    }

    private func record(_ state: inout State, before: Bool, after: Bool) {
        state.writes.append(WriteRecord(date: now(), appliedBefore: before, appliedAfter: after))
        if state.writes.count > 20 { state.writes.removeFirst(state.writes.count - 20) }
    }

    // MARK: Apply / restore

    enum ApplyOutcome: Equatable { case wrote, alreadyApplied }

    /// Writes the override. Throws `KeymapError` without touching the file if it can't be parsed.
    @discardableResult
    func apply() throws -> ApplyOutcome {
        var state = loadState()
        let id = target.commandID

        // Leftover backup from a run that never restored (crash/SIGKILL).
        if let backup = state.backup {
            if backup.keymapPath != keymapURL.path {
                log.info("Restoring leftover backup for a different keymap path first")
                try restore()
                state = loadState()
            } else {
                let snap = try read(keymapURL)
                let ours = snap.entries.filter { Self.command(of: $0) == id }
                if ours.count == 1, isOurs(ours[0]) {
                    log.info("Marker already present from a previous run; reusing its backup")
                    return .alreadyApplied
                }
                log.notice("Discarding stale backup: keymap no longer contains our marker")
                state.backup = nil
            }
        }

        let dir = resolved(keymapURL).deletingLastPathComponent()
        let directoryExisted = FileManager.default.fileExists(atPath: dir.path)
        let snap = try read(keymapURL)
        let prior = snap.entries.filter { Self.command(of: $0) == id }
        let insertAt = snap.entries.firstIndex { Self.command(of: $0) == id } ?? snap.entries.count
        var updated = snap.entries.filter { Self.command(of: $0) != id }
        updated.insert(marker, at: min(insertAt, updated.count))

        // Persist the backup BEFORE touching the keymap, so a kill in between is recoverable.
        state.backup = Backup(keymapPath: keymapURL.path,
                              fileExisted: snap.exists,
                              originalTextIfEmpty: snap.exists && snap.entries.isEmpty ? snap.text : nil,
                              directoryCreated: !directoryExisted,
                              priorEntries: prior.map(\.compact),
                              createdAt: now())
        try saveState(state)

        let before = isApplied(snap.entries)
        try write(updated, to: keymapURL)
        record(&state, before: before, after: true)
        try saveState(state)
        log.info("Wrote \(target.displayName, privacy: .public) override to \(keymapURL.path, privacy: .public) (prior entries: \(prior.count))")
        return .wrote
    }

    enum RestoreOutcome: Equatable { case nothingToRestore, restored, deletedFile, userChangedEntry }

    /// Undoes `apply()`. Idempotent. Only touches this command's entries and only if the
    /// marker is still exactly ours.
    @discardableResult
    func restore() throws -> RestoreOutcome {
        var state = loadState()
        guard let backup = state.backup else { return .nothingToRestore }
        let url = URL(fileURLWithPath: backup.keymapPath)
        let snap = try read(url) // malformed now → throw and keep the backup for a later attempt

        let current = snap.entries.filter { Self.command(of: $0) == target.commandID }
        guard snap.exists, current.count == 1, isOurs(current[0]) else {
            log.notice("\(target.commandID, privacy: .public) entry was changed outside Quick Chat; leaving keymap as is")
            state.backup = nil
            try saveState(state)
            return .userChangedEntry
        }

        let prior = try backup.priorEntries.map { try OrderedJSON.parse($0) }
        var updated = snap.entries
        let idx = updated.firstIndex(where: isOurs)!
        updated.replaceSubrange(idx...idx, with: prior)
        let before = isApplied(snap.entries)
        let after = isApplied(updated)

        var outcome = RestoreOutcome.restored
        let resolvedURL = resolved(url)
        if updated.isEmpty && !backup.fileExisted {
            do {
                try FileManager.default.removeItem(at: resolvedURL)
            } catch {
                throw KeymapError.io(path: resolvedURL.path, detail: error.localizedDescription)
            }
            if backup.directoryCreated {
                let dir = resolvedURL.deletingLastPathComponent()
                if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
            outcome = .deletedFile
        } else if updated.isEmpty, let original = backup.originalTextIfEmpty {
            do {
                try Data(original.utf8).write(to: resolvedURL, options: .atomic)
            } catch {
                throw KeymapError.io(path: resolvedURL.path, detail: error.localizedDescription)
            }
        } else {
            try write(updated, to: url)
        }

        state.backup = nil
        record(&state, before: before, after: after)
        try saveState(state)
        log.info("Restored \(target.displayName, privacy: .public) keymap entry (\(String(describing: outcome), privacy: .public))")
        return outcome
    }

    var hasBackup: Bool { loadState().backup != nil }

    // MARK: Restart awareness

    /// Whether the ChatGPT instance launched at `launchDate` disagrees with the current
    /// file about this override (it only reads the keymap at launch). Nil launchDate = unknown.
    func restartPending(launchDate: Date?) -> Bool {
        let writes = loadState().writes
        guard let last = writes.last, let launchDate else { return false }
        guard launchDate < last.date else { return false }
        let seen = writes.last(where: { $0.date <= launchDate })?.appliedAfter ?? writes[0].appliedBefore
        return seen != last.appliedAfter
    }
}
