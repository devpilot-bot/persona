import Foundation

extension Session {
    /// A Codex agent, by its agent or where it was read from (Android's `hasCodexIdentity`). TRAEX is not: only Codex's
    /// provenance defines the hierarchy below.
    nonisolated var hasCodexIdentity: Bool {
        agent == "codex" || (sourceKind?.hasPrefix("codex_") ?? false)
    }

    /// A Codex subagent (`thread_spawn`): the node says so, or names the chat or the conversation it hangs off
    /// (Android's `isCodexSubagent`).
    nonisolated var isCodexSubagent: Bool {
        guard hasCodexIdentity else { return false }
        if isSubagent == true { return true }
        if let parent = parentSessionID, !parent.isEmpty { return true }
        if let parent = parentThreadID, !parent.isEmpty { return true }
        if let root = rootSessionID, !root.isEmpty, root != sessionID { return true }
        return false
    }

    /// Another session started this one (the hub's `Session.IsSubtask`, Android's `isSubtask`): a runtime's session that
    /// says it is a subagent or names its parent (a Paseo agent another agent created, #4494), whichever agent runs it;
    /// from any other source, a Codex subagent. Terminal panes are never subtasks, whatever relationship they carry.
    nonisolated var isSubtask: Bool {
        guard sourceKind == "runtime" else { return isCodexSubagent }
        return isSubagent == true || !(parentSessionID ?? "").isEmpty
    }

    /// A subtask listed under its parent's Subtasks row and left out of every count (Android's `isNestedSubtask`). One
    /// that needs the user is not: it is a row of its own, in Needs You and counted (docs/design/DESIGN_SYSTEM.md 3.4)
    /// until it no longer needs them. One whose parent the list does not draw is a row of its own too
    /// (`CodexTasks.build`), still not counted.
    nonisolated var isNestedSubtask: Bool { state != .needsYou && isSubtask }
}

/// Subtasks under the session that started them: Codex subagents under their chat, as the Codex App's sidebar shows
/// them, and a runtime's sessions under the one that created them (a Paseo agent's, #4494), as Android's Agents list
/// (`CodexTaskForest`) does. The list lists and counts the others (`roots`), and a session's subtasks are behind its
/// Subtasks row (`children`). A subtask whose parent is not in the list (another page, another machine, archived) is a
/// root of its own; so is one in a cycle of corrupt parents, never every member of it.
nonisolated struct CodexTasks: Sendable {
    /// A subtask under a listed session, `depth` levels below the session's direct ones.
    struct Task: Hashable, Sendable, Identifiable {
        var session: Session
        var depth: Int
        var id: SessionKey { session.key }
    }

    var roots: [Session] = []
    var children: [SessionKey: [Session]] = [:]

    /// Hangs each `isNestedSubtask` under its parent, on its own hub and machine. A runtime's subtask: the session its
    /// parent session id names, whichever agent runs it, else the one its root session id names. A Codex subagent, among
    /// the Codex sessions: the one its parent session id names, else (naming none) the only one of its Codex home whose
    /// thread its parent thread id names, else the one its root session id names.
    ///
    /// `runs` says which rows the list of running sessions draws, where the list has one (Android's `runs`): a subtask it
    /// draws hangs under its parent only while it draws a row above the subtask too. A working agent whose creator was
    /// let go would be drawn nowhere, so it is a row of its own (#4494). One that list does not draw stays under its
    /// parent, as a finished Codex thread's subagents do. The rows in `ownRows` hang under nothing: rows of their own the
    /// user opened under a quick filter, which stay where they were while it is on (a subtask that needed the user and was
    /// answered, too).
    static func build(_ sessions: [Session], ownRows: Set<SessionKey> = [], runs: ((Session) -> Bool)? = nil) -> Self {
        guard sessions.contains(where: { $0.isNestedSubtask && !ownRows.contains($0.key) }) else { return Self(roots: sessions) }
        var bySession: [SessionKey: Session] = [:]
        for s in sessions where bySession[s.key] == nil { bySession[s.key] = s }
        struct Thread: Hashable { var machine: MachineRef; var instance: String?; var thread: String }
        var byThread: [Thread: [Session]] = [:]
        for s in sessions where s.hasCodexIdentity {
            guard let thread = s.sourceThreadID, !thread.isEmpty else { continue }
            byThread[Thread(machine: s.machineRef, instance: s.sourceInstanceID, thread: thread), default: []].append(s)
        }
        /// The session `id` names beside `s`; with `codex`, only a Codex one.
        func named(_ s: Session, _ id: String?, codex: Bool) -> Session? {
            guard let id, !id.isEmpty, let named = bySession[SessionKey(group: s.group, machineID: s.machineID, sessionID: id)],
                  !codex || named.hasCodexIdentity else { return nil }
            return named
        }
        var parents: [SessionKey: SessionKey] = [:]
        for s in sessions where s.isNestedSubtask && !ownRows.contains(s.key) {
            var parent: Session?
            if s.sourceKind == "runtime" {
                parent = named(s, s.parentSessionID, codex: false) ?? named(s, s.rootSessionID, codex: false)
            } else {
                parent = named(s, s.parentSessionID, codex: true)
                if parent == nil, s.parentSessionID?.isEmpty ?? true, let thread = s.parentThreadID, !thread.isEmpty,
                   let same = byThread[Thread(machine: s.machineRef, instance: s.sourceInstanceID, thread: thread)], same.count == 1 {
                    parent = same[0]
                }
                if parent == nil { parent = named(s, s.rootSessionID, codex: true) }
            }
            if let parent, parent.key != s.key { parents[s.key] = parent.key }
        }
        // A cycle keeps one member as a root, the same one every time: walking from each start in a fixed order, the
        // first member met twice loses its parent.
        for start in parents.keys.sorted(by: { order($0) < order($1) }) {
            var visited = Set<SessionKey>()
            var current: SessionKey? = start
            while let c = current, visited.insert(c).inserted { current = parents[c] }
            if let c = current { parents[c] = nil }
        }
        if let runs {
            var running = Set<SessionKey>()
            for s in sessions where runs(s) { running.insert(s.key) }
            // Decided on the whole tree first: one subtask let go does not let go of the ones under it.
            var loose: [SessionKey] = []
            for key in parents.keys where running.contains(key) {
                var above = parents[key]
                while let a = above, !running.contains(a) { above = parents[a] }
                if above == nil { loose.append(key) }
            }
            for key in loose { parents[key] = nil }
        }
        var children: [SessionKey: [Session]] = [:]
        for s in sessions { if let parent = parents[s.key] { children[parent, default: []].append(s) } }
        for (parent, members) in children {
            children[parent] = members.sorted {
                let a = $0.updatedAt ?? .distantPast, b = $1.updatedAt ?? .distantPast
                return a != b ? a > b : order($0.key) < order($1.key)
            }
        }
        return Self(roots: sessions.filter { parents[$0.key] == nil }, children: children)
    }

    private static func order(_ k: SessionKey) -> String { "\(k.hubGroup ?? "")/\(k.machineID)/\(k.sessionID)" }

    /// Every subtask under key, each followed by its own a level further in, newest first on each level.
    func flattened(under key: SessionKey) -> [Task] {
        var out: [Task] = []
        var seen: Set<SessionKey> = [key]
        func walk(_ parent: SessionKey, _ depth: Int) {
            for s in children[parent] ?? [] where seen.insert(s.key).inserted {
                out.append(Task(session: s, depth: depth))
                walk(s.key, depth + 1)
            }
        }
        walk(key, 0)
        return out
    }

    /// The ones of tasks (`flattened`) that pass, and the ones they hang off, in their order.
    static func kept(_ tasks: [Task], passing: (Session) -> Bool) -> [Task] {
        var keep = [Bool](repeating: false, count: tasks.count)
        // Walking back from a kept task, the first one shallower than it is its parent, and so on up: `above` is the
        // depth of the task kept last (-1: none yet, nothing to keep for).
        var above = -1
        for i in tasks.indices.reversed() where passing(tasks[i].session) || tasks[i].depth < above {
            keep[i] = true
            above = tasks[i].depth
        }
        return tasks.indices.filter { keep[$0] }.map { tasks[$0] }
    }
}
