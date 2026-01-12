import Foundation

// MARK: - Track Identifier

/// Unique identifier for tracks
public struct TrackID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: UUID
    
    public init() {
        self.rawValue = UUID()
    }
    
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
    
    public init(stringLiteral value: String) {
        self.rawValue = UUID(uuidString: value) ?? UUID()
    }
}

// MARK: - Track Type

public enum TrackType: String, Codable, Sendable, CaseIterable {
    case audio
    case midi
    case instrument  // MIDI + virtual instrument
    case bus         // Submix/group track
    case master      // Master output track
}

// MARK: - Track

/// Represents a single track in the DAW timeline
public struct Track: Identifiable, Codable, Sendable {
    public var id: TrackID
    public var name: String
    public var type: TrackType
    public var color: TrackColor
    
    // Audio properties
    public var volume: Float       // 0.0 to 1.0 (linear), displayed as dB
    public var pan: Float          // -1.0 (left) to 1.0 (right)
    public var isMuted: Bool
    public var isSolo: Bool
    public var isArmed: Bool       // Record armed
    
    // Routing
    public var inputSource: InputSource?
    public var outputBus: TrackID?  // nil = master output
    
    // Content
    public var clips: [Clip]
    
    // Instrument (for MIDI/instrument tracks)
    public var instrumentSlot: PluginSlot?
    
    // MIDI Output Routing (for MIDI tracks)
    // Determines where MIDI is sent: track instrument or V-Rack
    public var midiOutput: MIDIOutputDestination?
    
    // Effect Plugins (insert effects)
    public var pluginSlots: [PluginSlot]
    
    // Automation
    public var automationLanes: [AutomationLane]
    public var isAutomationVisible: Bool
    
    // UI State (not persisted in project, but useful for runtime)
    public var height: Double
    public var isExpanded: Bool
    
    public init(
        id: TrackID = TrackID(),
        name: String = "New Track",
        type: TrackType = .audio,
        color: TrackColor = .blue
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.color = color
        self.volume = 0.7937  // -2 dB default
        self.pan = 0.0
        self.isMuted = false
        self.isSolo = false
        self.isArmed = false
        self.inputSource = nil
        self.outputBus = nil
        self.clips = []
        self.instrumentSlot = nil
        self.midiOutput = nil  // Default: use track instrument
        self.pluginSlots = []
        self.automationLanes = [
            AutomationLane(parameter: .volume),
            AutomationLane(parameter: .pan)
        ]
        self.isAutomationVisible = false
        self.height = 80.0
        self.isExpanded = true
    }
    
    // MARK: - Convenience
    
    /// Volume in decibels (-inf to +6 dB)
    public var volumeDB: Float {
        get { linearToDecibels(volume) }
        set { volume = decibelsToLinear(newValue) }
    }
    
    /// Clips sorted by start time
    public var sortedClips: [Clip] {
        clips.sorted { $0.timeRange.start < $1.timeRange.start }
    }
    
    /// Get clip at a specific position
    public func clip(at position: TimePosition) -> Clip? {
        clips.first { $0.timeRange.contains(position) }
    }
}

// MARK: - Input Source

public enum InputSource: Codable, Sendable, Hashable {
    case audioDevice(channelIndex: Int)
    case midiDevice(deviceID: String)
    case virtualMIDI
    case sidechain(trackID: TrackID)
    case none
}

// MARK: - Track Color

public enum TrackColor: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, cyan, blue, purple, pink, gray
    
    public var hex: String {
        switch self {
        case .red: return "#FF5A5A"
        case .orange: return "#FF9F43"
        case .yellow: return "#FECA57"
        case .green: return "#5AD45A"
        case .cyan: return "#48DBFB"
        case .blue: return "#54A0FF"
        case .purple: return "#A55EEA"
        case .pink: return "#FF6B9D"
        case .gray: return "#8395A7"
        }
    }
}

// MARK: - Plugin Slot

public struct PluginSlot: Identifiable, Codable, Sendable {
    public var id: UUID
    public var pluginID: PluginIdentifier?  // nil = empty slot
    public var isEnabled: Bool
    public var preset: PluginPreset?
    public var parameterValues: [String: Float]  // Parameter ID -> Value
    public var stateData: Data?  // Full AU state for save/restore
    
    public init(
        id: UUID = UUID(),
        pluginID: PluginIdentifier? = nil,
        isEnabled: Bool = true,
        stateData: Data? = nil
    ) {
        self.id = id
        self.pluginID = pluginID
        self.isEnabled = isEnabled
        self.preset = nil
        self.parameterValues = [:]
        self.stateData = stateData
    }
}

// MARK: - Plugin Identifier

public struct PluginIdentifier: Codable, Sendable, Hashable {
    public var type: PluginType
    public var manufacturer: String
    public var name: String
    public var uniqueID: String  // AU component subtype or VST3 class ID
    
    public init(type: PluginType, manufacturer: String, name: String, uniqueID: String) {
        self.type = type
        self.manufacturer = manufacturer
        self.name = name
        self.uniqueID = uniqueID
    }
}

public enum PluginType: String, Codable, Sendable {
    case audioUnitEffect
    case audioUnitInstrument
    case audioUnitMIDI
    case vst3Effect
    case vst3Instrument
}

// MARK: - Plugin Preset

public struct PluginPreset: Codable, Sendable {
    public var name: String
    public var data: Data  // Opaque plugin state
    
    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

// MARK: - Utility Functions

private func linearToDecibels(_ linear: Float) -> Float {
    if linear <= 0 { return -.infinity }
    return 20 * log10(linear)
}

private func decibelsToLinear(_ db: Float) -> Float {
    if db == -.infinity { return 0 }
    return pow(10, db / 20)
}
