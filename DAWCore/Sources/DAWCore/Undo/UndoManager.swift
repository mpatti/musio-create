import Foundation
import Combine

// MARK: - DAW Undo Action

/// Represents a single undoable action in the DAW
public protocol DAWUndoAction: Sendable {
    /// Human-readable name for this action
    var actionName: String { get }
    
    /// Perform the action
    func perform(on project: inout Project)
    
    /// Undo the action (restore previous state)
    func undo(on project: inout Project)
    
    /// Optionally merge with another action of the same type
    func merge(with other: DAWUndoAction) -> DAWUndoAction?
}

// Default implementation - no merging
extension DAWUndoAction {
    public func merge(with other: DAWUndoAction) -> DAWUndoAction? {
        nil
    }
}

// MARK: - DAW Undo Manager

/// Custom undo manager for DAW operations with grouping and coalescing support
@MainActor
public final class DAWUndoManager: ObservableObject {
    
    // MARK: - Properties
    
    private var undoStack: [UndoGroup] = []
    private var redoStack: [UndoGroup] = []
    private var currentGroup: UndoGroup?
    private var groupingLevel: Int = 0
    
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var canRedo: Bool = false
    @Published public private(set) var undoActionName: String = ""
    @Published public private(set) var redoActionName: String = ""
    
    /// Maximum number of undo levels
    public var maxUndoLevels: Int = 100
    
    /// Time window for coalescing similar actions (in seconds)
    public var coalesceTimeWindow: TimeInterval = 0.5
    
    private var lastActionTime: Date?
    
    /// Publisher for state changes
    public let stateDidChange = PassthroughSubject<Void, Never>()
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Registration
    
    /// Register an action that can be undone
    public func registerAction(
        _ action: DAWUndoAction,
        project: inout Project
    ) {
        // Perform the action first
        action.perform(on: &project)
        
        // Clear redo stack when new action is performed
        redoStack.removeAll()
        
        let now = Date()
        
        // Check if we should coalesce with previous action
        if let lastTime = lastActionTime,
           now.timeIntervalSince(lastTime) < coalesceTimeWindow,
           let lastGroup = undoStack.last,
           lastGroup.actions.count == 1,
           let lastAction = lastGroup.actions.first,
           let merged = lastAction.merge(with: action) {
            // Replace last action with merged version
            undoStack[undoStack.count - 1] = UndoGroup(actions: [merged], name: merged.actionName)
        } else if groupingLevel > 0 {
            // Add to current group
            if currentGroup == nil {
                currentGroup = UndoGroup(actions: [], name: action.actionName)
            }
            currentGroup?.actions.append(action)
        } else {
            // Create new undo entry
            let group = UndoGroup(actions: [action], name: action.actionName)
            undoStack.append(group)
            
            // Limit undo levels
            if undoStack.count > maxUndoLevels {
                undoStack.removeFirst()
            }
        }
        
        lastActionTime = now
        updateState()
    }
    
    // MARK: - Grouping
    
    /// Begin a group of actions that will be undone together
    public func beginGrouping(name: String? = nil) {
        groupingLevel += 1
        
        if groupingLevel == 1 {
            currentGroup = UndoGroup(actions: [], name: name ?? "Multiple Changes")
        }
    }
    
    /// End the current action group
    public func endGrouping() {
        guard groupingLevel > 0 else { return }
        
        groupingLevel -= 1
        
        if groupingLevel == 0, let group = currentGroup, !group.actions.isEmpty {
            undoStack.append(group)
            
            if undoStack.count > maxUndoLevels {
                undoStack.removeFirst()
            }
            
            currentGroup = nil
            updateState()
        }
    }
    
    // MARK: - Undo/Redo
    
    /// Undo the last action(s)
    public func undo(project: inout Project) {
        guard let group = undoStack.popLast() else { return }
        
        // Undo actions in reverse order
        for action in group.actions.reversed() {
            action.undo(on: &project)
        }
        
        redoStack.append(group)
        updateState()
        stateDidChange.send()
    }
    
    /// Redo the last undone action(s)
    public func redo(project: inout Project) {
        guard let group = redoStack.popLast() else { return }
        
        // Redo actions in original order
        for action in group.actions {
            action.perform(on: &project)
        }
        
        undoStack.append(group)
        updateState()
        stateDidChange.send()
    }
    
    /// Clear all undo/redo history
    public func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        currentGroup = nil
        groupingLevel = 0
        updateState()
    }
    
    // MARK: - State
    
    private func updateState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoActionName = undoStack.last?.name ?? ""
        redoActionName = redoStack.last?.name ?? ""
    }
}

// MARK: - Undo Group

private struct UndoGroup {
    var actions: [DAWUndoAction]
    var name: String
}

// MARK: - Common Undo Actions

/// Action for adding a track
public struct AddTrackAction: DAWUndoAction {
    public let track: Track
    public let index: Int?
    
    public var actionName: String { "Add Track" }
    
    public init(track: Track, at index: Int? = nil) {
        self.track = track
        self.index = index
    }
    
    public func perform(on project: inout Project) {
        if let index = index, index < project.tracks.count {
            project.tracks.insert(track, at: index)
        } else {
            project.tracks.append(track)
        }
    }
    
    public func undo(on project: inout Project) {
        project.tracks.removeAll { $0.id == track.id }
    }
}

/// Action for removing a track
public struct RemoveTrackAction: DAWUndoAction {
    public let trackID: TrackID
    private let track: Track
    private let index: Int
    
    public var actionName: String { "Delete Track" }
    
    public init(from project: Project, trackID: TrackID) {
        self.trackID = trackID
        self.track = project.tracks.first { $0.id == trackID }!
        self.index = project.tracks.firstIndex { $0.id == trackID }!
    }
    
    public func perform(on project: inout Project) {
        project.tracks.removeAll { $0.id == trackID }
    }
    
    public func undo(on project: inout Project) {
        project.tracks.insert(track, at: min(index, project.tracks.count))
    }
}

/// Action for modifying a track
public struct ModifyTrackAction: DAWUndoAction {
    private let trackID: TrackID
    private let oldTrack: Track
    private let newTrack: Track
    public let description: String
    
    public var actionName: String { description }
    
    public init(trackID: TrackID, old: Track, new: Track, description: String = "Modify Track") {
        self.trackID = trackID
        self.oldTrack = old
        self.newTrack = new
        self.description = description
    }
    
    public func perform(on project: inout Project) {
        if let index = project.tracks.firstIndex(where: { $0.id == trackID }) {
            project.tracks[index] = newTrack
        }
    }
    
    public func undo(on project: inout Project) {
        if let index = project.tracks.firstIndex(where: { $0.id == trackID }) {
            project.tracks[index] = oldTrack
        }
    }
    
    public func merge(with other: DAWUndoAction) -> DAWUndoAction? {
        guard let otherModify = other as? ModifyTrackAction,
              otherModify.trackID == trackID else {
            return nil
        }
        
        return ModifyTrackAction(
            trackID: trackID,
            old: oldTrack,
            new: otherModify.newTrack,
            description: description
        )
    }
}

/// Action for adding a clip
public struct AddClipAction: DAWUndoAction {
    private let trackID: TrackID
    private let clip: Clip
    
    public var actionName: String { "Add Clip" }
    
    public init(trackID: TrackID, clip: Clip) {
        self.trackID = trackID
        self.clip = clip
    }
    
    public func perform(on project: inout Project) {
        if let index = project.tracks.firstIndex(where: { $0.id == trackID }) {
            project.tracks[index].clips.append(clip)
        }
    }
    
    public func undo(on project: inout Project) {
        if let index = project.tracks.firstIndex(where: { $0.id == trackID }) {
            project.tracks[index].clips.removeAll { $0.id == clip.id }
        }
    }
}

/// Action for removing a clip
public struct RemoveClipAction: DAWUndoAction {
    private let trackID: TrackID
    private let clip: Clip
    private let clipIndex: Int
    
    public var actionName: String { "Delete Clip" }
    
    public init(from project: Project, trackID: TrackID, clipID: ClipID) {
        self.trackID = trackID
        let track = project.tracks.first { $0.id == trackID }!
        self.clip = track.clips.first { $0.id == clipID }!
        self.clipIndex = track.clips.firstIndex { $0.id == clipID }!
    }
    
    public func perform(on project: inout Project) {
        if let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) {
            project.tracks[trackIndex].clips.removeAll { $0.id == clip.id }
        }
    }
    
    public func undo(on project: inout Project) {
        if let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) {
            project.tracks[trackIndex].clips.insert(clip, at: min(clipIndex, project.tracks[trackIndex].clips.count))
        }
    }
}

/// Action for moving a clip
public struct MoveClipAction: DAWUndoAction {
    private let trackID: TrackID
    private let clipID: ClipID
    private let oldPosition: TimePosition
    private let newPosition: TimePosition
    
    public var actionName: String { "Move Clip" }
    
    public init(trackID: TrackID, clipID: ClipID, from oldPosition: TimePosition, to newPosition: TimePosition) {
        self.trackID = trackID
        self.clipID = clipID
        self.oldPosition = oldPosition
        self.newPosition = newPosition
    }
    
    public func perform(on project: inout Project) {
        updateClipPosition(in: &project, to: newPosition)
    }
    
    public func undo(on project: inout Project) {
        updateClipPosition(in: &project, to: oldPosition)
    }
    
    private func updateClipPosition(in project: inout Project, to position: TimePosition) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }),
              let clipIndex = project.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            return
        }
        
        var clip = project.tracks[trackIndex].clips[clipIndex]
        let duration = clip.timeRange.duration
        clip.timeRange = TimeRange(start: position, duration: duration)
        project.tracks[trackIndex].clips[clipIndex] = clip
    }
    
    public func merge(with other: DAWUndoAction) -> DAWUndoAction? {
        guard let otherMove = other as? MoveClipAction,
              otherMove.trackID == trackID,
              otherMove.clipID == clipID else {
            return nil
        }
        
        return MoveClipAction(
            trackID: trackID,
            clipID: clipID,
            from: oldPosition,
            to: otherMove.newPosition
        )
    }
}

/// Action for modifying MIDI events
public struct ModifyMIDIEventsAction: DAWUndoAction {
    private let trackID: TrackID
    private let clipID: ClipID
    private let oldEvents: [MIDIEvent]
    private let newEvents: [MIDIEvent]
    public let description: String
    
    public var actionName: String { description }
    
    public init(trackID: TrackID, clipID: ClipID, oldEvents: [MIDIEvent], newEvents: [MIDIEvent], description: String = "Edit MIDI") {
        self.trackID = trackID
        self.clipID = clipID
        self.oldEvents = oldEvents
        self.newEvents = newEvents
        self.description = description
    }
    
    public func perform(on project: inout Project) {
        updateEvents(in: &project, events: newEvents)
    }
    
    public func undo(on project: inout Project) {
        updateEvents(in: &project, events: oldEvents)
    }
    
    private func updateEvents(in project: inout Project, events: [MIDIEvent]) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }),
              let clipIndex = project.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }),
              case .midi(var midiData) = project.tracks[trackIndex].clips[clipIndex].content else {
            return
        }
        
        midiData.events = events
        project.tracks[trackIndex].clips[clipIndex].content = .midi(midiData)
    }
}

/// Action for modifying automation
public struct ModifyAutomationAction: DAWUndoAction {
    private let trackID: TrackID
    private let laneID: UUID
    private let oldPoints: [AutomationPoint]
    private let newPoints: [AutomationPoint]
    
    public var actionName: String { "Edit Automation" }
    
    public init(trackID: TrackID, laneID: UUID, oldPoints: [AutomationPoint], newPoints: [AutomationPoint]) {
        self.trackID = trackID
        self.laneID = laneID
        self.oldPoints = oldPoints
        self.newPoints = newPoints
    }
    
    public func perform(on project: inout Project) {
        updatePoints(in: &project, points: newPoints)
    }
    
    public func undo(on project: inout Project) {
        updatePoints(in: &project, points: oldPoints)
    }
    
    private func updatePoints(in project: inout Project, points: [AutomationPoint]) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }),
              let laneIndex = project.tracks[trackIndex].automationLanes.firstIndex(where: { $0.id == laneID }) else {
            return
        }
        
        project.tracks[trackIndex].automationLanes[laneIndex].points = points
    }
}

/// Action for changing tempo
public struct ChangeTempoAction: DAWUndoAction {
    private let oldTempo: Tempo
    private let newTempo: Tempo
    
    public var actionName: String { "Change Tempo" }
    
    public init(from oldTempo: Tempo, to newTempo: Tempo) {
        self.oldTempo = oldTempo
        self.newTempo = newTempo
    }
    
    public func perform(on project: inout Project) {
        project.tempo = newTempo
    }
    
    public func undo(on project: inout Project) {
        project.tempo = oldTempo
    }
    
    public func merge(with other: DAWUndoAction) -> DAWUndoAction? {
        guard let otherTempo = other as? ChangeTempoAction else { return nil }
        return ChangeTempoAction(from: oldTempo, to: otherTempo.newTempo)
    }
}
