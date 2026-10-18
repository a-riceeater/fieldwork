import Foundation
import DrillTiming

/// What happened in one committed change; observers use it for the recovery
/// journal, onboarding progress and view refresh.
public struct CommitEvent: Hashable, Codable, Sendable {
    public enum Action: String, Codable, Sendable { case perform, undo, redo }
    public var revision: Int
    public var action: Action
    public var command: DrillCommand
    public var name: String
}

/// Sole mutable owner of a show. Commands are validated against a copy and
/// commit atomically with one undo unit each; selection and view state live
/// elsewhere.
public final class DocumentSession {
    struct Entry {
        var command: DrillCommand
        var before: Show
        var beforeState: UUID
        var after: Show
        var afterState: UUID
    }

    public private(set) var show: Show
    /// Increases on every committed change, including undo and redo.
    public private(set) var revision = 0
    public let undoLimit: Int

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var stateID = UUID()
    private var savedStateID: UUID
    private var mapCache: [MovementID: (revision: Int, map: TimingMap)] = [:]
    private var observers: [UUID: (CommitEvent) -> Void] = [:]

    public init(show: Show, undoLimit: Int = 500) throws {
        try show.validate()
        self.show = show
        self.undoLimit = undoLimit
        savedStateID = stateID
    }

    public var isDirty: Bool { stateID != savedStateID }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.command.name }
    public var redoName: String? { redoStack.last?.command.name }

    /// Records that the current state has been written to disk.
    public func markSaved() { savedStateID = stateID }
    /// Marks the session as differing from disk (for example after crash recovery).
    public func markUnsaved() { savedStateID = UUID() }

    @discardableResult
    public func observe(_ handler: @escaping (CommitEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) { observers[token] = nil }

    /// Validates and commits a command as one undoable transaction.
    @discardableResult
    public func perform(_ command: DrillCommand) throws -> CommitEvent {
        let next = try command.applied(to: show)
        try next.validate()
        let newState = UUID()
        undoStack.append(Entry(command: command, before: show, beforeState: stateID, after: next, afterState: newState))
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
        redoStack.removeAll()
        show = next
        stateID = newState
        return commit(.perform, command)
    }

    @discardableResult
    public func undo() -> CommitEvent? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(entry)
        show = entry.before
        stateID = entry.beforeState
        return commit(.undo, entry.command)
    }

    @discardableResult
    public func redo() -> CommitEvent? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(entry)
        show = entry.after
        stateID = entry.afterState
        return commit(.redo, entry.command)
    }

    /// Re-applies a journaled event during recovery.
    public func replay(_ event: CommitEvent) throws {
        switch event.action {
        case .perform: try perform(event.command)
        case .undo: guard undo() != nil else { throw DrillError("Recovery journal is inconsistent (nothing to undo).") }
        case .redo: guard redo() != nil else { throw DrillError("Recovery journal is inconsistent (nothing to redo).") }
        }
    }

    private func commit(_ action: CommitEvent.Action, _ command: DrillCommand) -> CommitEvent {
        revision += 1
        let event = CommitEvent(revision: revision, action: action, command: command, name: command.name)
        for handler in observers.values { handler(event) }
        return event
    }

    /// Cached compiled timing map for a movement at the current revision.
    public func timingMap(for movementID: MovementID) throws -> TimingMap {
        if let cached = mapCache[movementID], cached.revision == revision { return cached.map }
        let map = try show.timingMap(for: movementID)
        mapCache[movementID] = (revision, map)
        return map
    }
}
