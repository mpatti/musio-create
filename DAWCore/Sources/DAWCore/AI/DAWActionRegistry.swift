import Foundation

// MARK: - Action Parameter Types

public struct ActionParameter: Codable, Sendable {
    public let name: String
    public let type: ParameterType
    public let description: String
    public let required: Bool
    public let enumValues: [String]?
    
    public init(name: String, type: ParameterType, description: String, required: Bool = true, enumValues: [String]? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.enumValues = enumValues
    }
    
    public enum ParameterType: String, Codable, Sendable {
        case string
        case number
        case integer
        case boolean
    }
}

// MARK: - Action Result

public struct ActionResult: Codable, Sendable {
    public let success: Bool
    public let message: String
    public let data: [String: String]?
    
    public init(success: Bool, message: String, data: [String: String]? = nil) {
        self.success = success
        self.message = message
        self.data = data
    }
    
    public static func success(_ message: String, data: [String: String]? = nil) -> ActionResult {
        ActionResult(success: true, message: message, data: data)
    }
    
    public static func failure(_ message: String) -> ActionResult {
        ActionResult(success: false, message: message, data: nil)
    }
}

// MARK: - Tool Call

public struct ToolCall: Codable, Sendable {
    public let id: String
    public let name: String
    public let arguments: [String: AnyCodable]
    
    public init(id: String, name: String, arguments: [String: AnyCodable]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
    
    public func getString(_ key: String) -> String? {
        arguments[key]?.value as? String
    }
    
    public func getDouble(_ key: String) -> Double? {
        if let num = arguments[key]?.value as? Double {
            return num
        }
        if let num = arguments[key]?.value as? Int {
            return Double(num)
        }
        return nil
    }
    
    public func getInt(_ key: String) -> Int? {
        if let num = arguments[key]?.value as? Int {
            return num
        }
        if let num = arguments[key]?.value as? Double {
            return Int(num)
        }
        return nil
    }
    
    public func getBool(_ key: String) -> Bool? {
        arguments[key]?.value as? Bool
    }
}

// MARK: - AnyCodable Helper

public struct AnyCodable: Codable, Sendable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - DAW Action Definition

public struct DAWAction: Sendable {
    public let name: String
    public let description: String
    public let parameters: [ActionParameter]
    
    public init(name: String, description: String, parameters: [ActionParameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
    
    /// Convert to Claude tool format
    public func toClaudeTool() -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        
        for param in parameters {
            var propDef: [String: Any] = [
                "type": param.type.rawValue,
                "description": param.description
            ]
            if let enumVals = param.enumValues {
                propDef["enum"] = enumVals
            }
            properties[param.name] = propDef
            
            if param.required {
                required.append(param.name)
            }
        }
        
        return [
            "name": name,
            "description": description,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": required
            ]
        ]
    }
}

// MARK: - DAW Action Registry

public final class DAWActionRegistry: Sendable {
    public static let shared = DAWActionRegistry()
    
    public let actions: [DAWAction]
    
    private init() {
        self.actions = Self.buildActions()
    }
    
    public func getAction(named name: String) -> DAWAction? {
        actions.first { $0.name == name }
    }
    
    /// Get all actions as Claude tools format
    public func getAllToolsForClaude() -> [[String: Any]] {
        actions.map { $0.toClaudeTool() }
    }
    
    /// Get all actions as Claude tools format with cache control for prompt caching
    /// The cache_control marker goes on the last tool to cache all tools
    public func getAllToolsForClaudeWithCache() -> [[String: Any]] {
        var tools = actions.map { $0.toClaudeTool() }
        
        // Add cache_control to the last tool to enable caching of all tools
        if var lastTool = tools.last {
            lastTool["cache_control"] = ["type": "ephemeral"]
            tools[tools.count - 1] = lastTool
        }
        
        return tools
    }
    
    // MARK: - Action Definitions
    
    private static func buildActions() -> [DAWAction] {
        return [
            // MARK: Track Management
            DAWAction(
                name: "add_track",
                description: "Add a new track to the project",
                parameters: [
                    ActionParameter(name: "type", type: .string, description: "Type of track to create", enumValues: ["midi", "audio", "instrument"]),
                    ActionParameter(name: "name", type: .string, description: "Name for the new track", required: false)
                ]
            ),
            
            DAWAction(
                name: "delete_track",
                description: "Delete a track from the project",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track to delete")
                ]
            ),
            
            DAWAction(
                name: "rename_track",
                description: "Rename an existing track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Current name of the track"),
                    ActionParameter(name: "new_name", type: .string, description: "New name for the track")
                ]
            ),
            
            DAWAction(
                name: "select_track",
                description: "Select a track by name",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track to select")
                ]
            ),
            
            DAWAction(
                name: "reorder_track",
                description: "Move a track to a different position in the track list",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track to move"),
                    ActionParameter(name: "position", type: .integer, description: "New position (1-based index)")
                ]
            ),
            
            // MARK: Track Properties
            DAWAction(
                name: "set_track_volume",
                description: "Set the volume level of a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track"),
                    ActionParameter(name: "volume", type: .number, description: "Volume level from 0.0 to 1.0")
                ]
            ),
            
            DAWAction(
                name: "set_track_pan",
                description: "Set the pan position of a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track"),
                    ActionParameter(name: "pan", type: .number, description: "Pan position from -1.0 (left) to 1.0 (right)")
                ]
            ),
            
            DAWAction(
                name: "mute_track",
                description: "Mute or unmute a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track"),
                    ActionParameter(name: "muted", type: .boolean, description: "True to mute, false to unmute")
                ]
            ),
            
            DAWAction(
                name: "solo_track",
                description: "Solo or unsolo a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track"),
                    ActionParameter(name: "solo", type: .boolean, description: "True to solo, false to unsolo")
                ]
            ),
            
            DAWAction(
                name: "arm_track",
                description: "Arm or disarm a track for recording",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track"),
                    ActionParameter(name: "armed", type: .boolean, description: "True to arm, false to disarm")
                ]
            ),
            
            // MARK: Transport
            DAWAction(
                name: "play",
                description: "Start playback",
                parameters: []
            ),
            
            DAWAction(
                name: "stop",
                description: "Stop playback and return to start",
                parameters: []
            ),
            
            DAWAction(
                name: "pause",
                description: "Pause playback at current position",
                parameters: []
            ),
            
            DAWAction(
                name: "record",
                description: "Start recording on the armed track",
                parameters: []
            ),
            
            DAWAction(
                name: "stop_recording",
                description: "Stop recording",
                parameters: []
            ),
            
            DAWAction(
                name: "seek_to_bar",
                description: "Move the playhead to a specific bar",
                parameters: [
                    ActionParameter(name: "bar", type: .integer, description: "Bar number (1-based)")
                ]
            ),
            
            DAWAction(
                name: "seek_to_beat",
                description: "Move the playhead to a specific beat position",
                parameters: [
                    ActionParameter(name: "beat", type: .number, description: "Beat position (0-based)")
                ]
            ),
            
            // MARK: Tempo and Time Signature
            DAWAction(
                name: "set_tempo",
                description: "Set the project tempo in BPM",
                parameters: [
                    ActionParameter(name: "bpm", type: .number, description: "Tempo in beats per minute")
                ]
            ),
            
            DAWAction(
                name: "set_time_signature",
                description: "Set the time signature",
                parameters: [
                    ActionParameter(name: "numerator", type: .integer, description: "Beats per bar (top number)"),
                    ActionParameter(name: "denominator", type: .integer, description: "Beat value (bottom number)")
                ]
            ),
            
            // MARK: Clip Operations
            DAWAction(
                name: "create_midi_clip",
                description: "Create a new empty MIDI clip on a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the MIDI track"),
                    ActionParameter(name: "start_bar", type: .integer, description: "Starting bar (1-based)"),
                    ActionParameter(name: "length_bars", type: .number, description: "Length in bars")
                ]
            ),
            
            DAWAction(
                name: "delete_clip",
                description: "Delete a clip from a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track"),
                    ActionParameter(name: "clip_index", type: .integer, description: "Index of the clip on the track (0-based)", required: false)
                ]
            ),
            
            DAWAction(
                name: "move_clip",
                description: "Move a clip to a different position",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track"),
                    ActionParameter(name: "clip_index", type: .integer, description: "Index of the clip (0-based)"),
                    ActionParameter(name: "to_bar", type: .integer, description: "Destination bar (1-based)")
                ]
            ),
            
            DAWAction(
                name: "duplicate_clip",
                description: "Duplicate a clip to a new position",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track"),
                    ActionParameter(name: "clip_index", type: .integer, description: "Index of the clip (0-based)"),
                    ActionParameter(name: "to_bar", type: .integer, description: "Destination bar (1-based)")
                ]
            ),
            
            // MARK: Selection Operations
            DAWAction(
                name: "select_all_clips",
                description: "Select all clips on a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track")
                ]
            ),
            
            DAWAction(
                name: "deselect_all",
                description: "Deselect all clips",
                parameters: []
            ),
            
            DAWAction(
                name: "delete_selected",
                description: "Delete all selected clips",
                parameters: []
            ),
            
            DAWAction(
                name: "copy_selected",
                description: "Copy selected clips to clipboard",
                parameters: []
            ),
            
            DAWAction(
                name: "cut_selected",
                description: "Cut selected clips to clipboard",
                parameters: []
            ),
            
            DAWAction(
                name: "paste",
                description: "Paste clips from clipboard at current position",
                parameters: []
            ),
            
            DAWAction(
                name: "duplicate_selected",
                description: "Duplicate selected clips",
                parameters: []
            ),
            
            // MARK: Time Range Operations
            DAWAction(
                name: "delete_time_range",
                description: "Delete a time range and shift subsequent content (ripple delete)",
                parameters: [
                    ActionParameter(name: "start_bar", type: .integer, description: "Start bar (1-based)"),
                    ActionParameter(name: "end_bar", type: .integer, description: "End bar (1-based, exclusive)")
                ]
            ),
            
            DAWAction(
                name: "insert_silence",
                description: "Insert empty time at a position, shifting subsequent content",
                parameters: [
                    ActionParameter(name: "at_bar", type: .integer, description: "Bar position to insert at (1-based)"),
                    ActionParameter(name: "length_bars", type: .number, description: "Number of bars to insert")
                ]
            ),
            
            // MARK: MIDI Operations
            DAWAction(
                name: "generate_midi",
                description: "Generate MIDI content using AI based on a description",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the MIDI track"),
                    ActionParameter(name: "prompt", type: .string, description: "Description of the MIDI content to generate"),
                    ActionParameter(name: "start_bar", type: .integer, description: "Starting bar (1-based)"),
                    ActionParameter(name: "length_bars", type: .integer, description: "Length in bars")
                ]
            ),
            
            DAWAction(
                name: "quantize_midi",
                description: "Quantize MIDI notes on a track to the grid",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the MIDI track"),
                    ActionParameter(name: "grid", type: .string, description: "Grid resolution", enumValues: ["1/4", "1/8", "1/16", "1/32"])
                ]
            ),
            
            // MARK: View Operations
            DAWAction(
                name: "show_mixer",
                description: "Show or hide the mixer panel",
                parameters: [
                    ActionParameter(name: "visible", type: .boolean, description: "True to show, false to hide")
                ]
            ),
            
            DAWAction(
                name: "show_piano_roll",
                description: "Show or hide the piano roll/MIDI editor",
                parameters: [
                    ActionParameter(name: "visible", type: .boolean, description: "True to show, false to hide")
                ]
            ),
            
            DAWAction(
                name: "open_piano_roll_for_track",
                description: "Open the piano roll for a specific track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the MIDI track")
                ]
            ),
            
            DAWAction(
                name: "zoom_to_fit",
                description: "Zoom the timeline to fit all content",
                parameters: []
            ),
            
            DAWAction(
                name: "set_zoom",
                description: "Set the timeline zoom level",
                parameters: [
                    ActionParameter(name: "level", type: .number, description: "Zoom level (0.25 to 4.0, where 1.0 is default)")
                ]
            ),
            
            // MARK: Project Operations
            DAWAction(
                name: "undo",
                description: "Undo the last action",
                parameters: []
            ),
            
            DAWAction(
                name: "redo",
                description: "Redo the last undone action",
                parameters: []
            ),
            
            DAWAction(
                name: "get_project_info",
                description: "Get information about the current project state",
                parameters: []
            ),
            
            DAWAction(
                name: "list_tracks",
                description: "List all tracks in the project with their properties",
                parameters: []
            ),
            
            // MARK: MIDI Routing
            DAWAction(
                name: "set_track_midi_output",
                description: "Set the MIDI output destination for a track (route to track instrument or V-Rack)",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the MIDI track"),
                    ActionParameter(name: "destination", type: .string, description: "Output destination: 'track' for track instrument, or rack instrument name"),
                    ActionParameter(name: "channel", type: .integer, description: "MIDI channel (1-16) when routing to V-Rack", required: false)
                ]
            ),
            
            DAWAction(
                name: "list_rack_instruments",
                description: "List all instruments in the V-Rack with their names and IDs",
                parameters: []
            ),
            
            // MARK: Instrument Management
            DAWAction(
                name: "add_rack_instrument",
                description: "Add a new empty instrument slot to the V-Rack",
                parameters: [
                    ActionParameter(name: "name", type: .string, description: "Name for the new rack instrument", required: false)
                ]
            ),
            
            DAWAction(
                name: "remove_rack_instrument",
                description: "Remove an instrument from the V-Rack",
                parameters: [
                    ActionParameter(name: "name", type: .string, description: "Name of the rack instrument to remove")
                ]
            ),
            
            DAWAction(
                name: "list_available_plugins",
                description: "List all available instrument plugins that can be loaded",
                parameters: []
            ),
            
            DAWAction(
                name: "load_rack_instrument_plugin",
                description: "Load a plugin into a V-Rack instrument slot",
                parameters: [
                    ActionParameter(name: "rack_name", type: .string, description: "Name of the rack instrument slot"),
                    ActionParameter(name: "plugin_name", type: .string, description: "Name of the plugin to load")
                ]
            ),
            
            // MARK: Track Settings
            DAWAction(
                name: "set_track_color",
                description: "Set the color of a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the track"),
                    ActionParameter(name: "color", type: .string, description: "Color name", enumValues: ["red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"])
                ]
            ),
            
            // MARK: Transport Extras
            DAWAction(
                name: "toggle_loop",
                description: "Enable or disable loop playback",
                parameters: [
                    ActionParameter(name: "enabled", type: .boolean, description: "True to enable loop, false to disable")
                ]
            ),
            
            DAWAction(
                name: "set_loop_region",
                description: "Set the loop region start and end points",
                parameters: [
                    ActionParameter(name: "start_bar", type: .integer, description: "Loop start bar (1-based)"),
                    ActionParameter(name: "end_bar", type: .integer, description: "Loop end bar (1-based)")
                ]
            ),
            
            DAWAction(
                name: "toggle_metronome",
                description: "Enable or disable the metronome/click track",
                parameters: [
                    ActionParameter(name: "enabled", type: .boolean, description: "True to enable metronome, false to disable")
                ]
            ),
            
            // MARK: Clip Editing
            DAWAction(
                name: "split_clip_at_playhead",
                description: "Split the selected clip at the current playhead position",
                parameters: []
            ),
            
            DAWAction(
                name: "trim_clips_to_grid",
                description: "Snap selected clip edges to the nearest grid line",
                parameters: [
                    ActionParameter(name: "resolution", type: .string, description: "Grid resolution", enumValues: ["1/4", "1/2", "1", "2", "4"])
                ]
            ),
            
            DAWAction(
                name: "nudge_clips",
                description: "Move selected clips by a specified amount",
                parameters: [
                    ActionParameter(name: "beats", type: .number, description: "Number of beats to nudge (negative for left, positive for right)")
                ]
            ),
            
            // MARK: Markers
            DAWAction(
                name: "add_marker",
                description: "Add a marker at a specific position",
                parameters: [
                    ActionParameter(name: "bar", type: .integer, description: "Bar position for the marker (1-based)"),
                    ActionParameter(name: "name", type: .string, description: "Name/label for the marker", required: false)
                ]
            ),
            
            DAWAction(
                name: "delete_marker",
                description: "Delete a marker by name or position",
                parameters: [
                    ActionParameter(name: "name", type: .string, description: "Name of the marker to delete", required: false),
                    ActionParameter(name: "bar", type: .integer, description: "Bar position of marker to delete", required: false)
                ]
            ),
            
            DAWAction(
                name: "goto_marker",
                description: "Move the playhead to a marker",
                parameters: [
                    ActionParameter(name: "name", type: .string, description: "Name of the marker to go to")
                ]
            ),
            
            DAWAction(
                name: "list_markers",
                description: "List all markers in the project",
                parameters: []
            ),
            
            // MARK: Audio Operations
            DAWAction(
                name: "import_audio",
                description: "Import an audio file to a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the audio track"),
                    ActionParameter(name: "file_path", type: .string, description: "Path to the audio file"),
                    ActionParameter(name: "start_bar", type: .integer, description: "Bar position to place the audio (1-based)")
                ]
            ),
            
            // MARK: MIDI Note Operations
            DAWAction(
                name: "add_midi_note",
                description: "Add a MIDI note to a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the MIDI track"),
                    ActionParameter(name: "pitch", type: .integer, description: "MIDI note number (0-127, middle C is 60)"),
                    ActionParameter(name: "start_beat", type: .number, description: "Start position in beats"),
                    ActionParameter(name: "duration", type: .number, description: "Duration in beats"),
                    ActionParameter(name: "velocity", type: .integer, description: "Note velocity (1-127)", required: false)
                ]
            ),
            
            DAWAction(
                name: "transpose_track",
                description: "Transpose all MIDI notes on a track by semitones",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the MIDI track"),
                    ActionParameter(name: "semitones", type: .integer, description: "Number of semitones to transpose (negative for down, positive for up)")
                ]
            ),
            
            DAWAction(
                name: "set_track_velocity",
                description: "Set velocity for all notes on a track",
                parameters: [
                    ActionParameter(name: "track_name", type: .string, description: "Name of the MIDI track"),
                    ActionParameter(name: "velocity", type: .integer, description: "Velocity value (1-127)")
                ]
            )
        ]
    }
}
