import Foundation

// MARK: - MIDI Event

/// Represents a single MIDI event
public struct MIDIEvent: Identifiable, Codable, Sendable {
    public var id: UUID
    
    /// Position in beats (relative to clip start for clip events, or absolute for track events)
    public var beatPosition: Double
    
    /// The type of MIDI event
    public var type: MIDIEventType
    
    /// MIDI channel (0-15)
    public var channel: UInt8
    
    public init(
        id: UUID = UUID(),
        beatPosition: Double,
        type: MIDIEventType,
        channel: UInt8 = 0
    ) {
        self.id = id
        self.beatPosition = beatPosition
        self.type = type
        self.channel = min(15, channel)
    }
}

// MARK: - MIDI Event Type

public enum MIDIEventType: Codable, Sendable {
    case note(NoteData)
    case controlChange(controller: UInt8, value: UInt8)
    case programChange(program: UInt8)
    case pitchBend(value: Int16)  // -8192 to 8191
    case aftertouch(pressure: UInt8)
    case polyAftertouch(note: UInt8, pressure: UInt8)
    case sysex(data: Data)
}

// MARK: - Note Data

public struct NoteData: Codable, Sendable, Hashable {
    /// MIDI note number (0-127, middle C = 60)
    public var pitch: UInt8
    
    /// Note velocity (1-127, 0 = note off)
    public var velocity: UInt8
    
    /// Note duration in beats
    public var duration: Double
    
    /// Release velocity (optional)
    public var releaseVelocity: UInt8?
    
    public init(
        pitch: UInt8,
        velocity: UInt8 = 100,
        duration: Double = 0.25,
        releaseVelocity: UInt8? = nil
    ) {
        self.pitch = min(127, pitch)
        self.velocity = min(127, max(1, velocity))
        self.duration = max(0, duration)
        self.releaseVelocity = releaseVelocity
    }
    
    /// Note name (e.g., "C4", "F#5")
    public var noteName: String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = Int(pitch) / 12 - 1
        let noteName = noteNames[Int(pitch) % 12]
        return "\(noteName)\(octave)"
    }
    
    /// Create from note name (e.g., "C4" -> pitch 60)
    public static func pitch(from noteName: String) -> UInt8? {
        let noteValues: [String: Int] = [
            "C": 0, "C#": 1, "Db": 1,
            "D": 2, "D#": 3, "Eb": 3,
            "E": 4,
            "F": 5, "F#": 6, "Gb": 6,
            "G": 7, "G#": 8, "Ab": 8,
            "A": 9, "A#": 10, "Bb": 10,
            "B": 11
        ]
        
        // Parse note name and octave
        var name = ""
        var octaveStr = ""
        var isOctave = false
        
        for char in noteName {
            if char.isNumber || char == "-" {
                isOctave = true
            }
            if isOctave {
                octaveStr.append(char)
            } else {
                name.append(char)
            }
        }
        
        guard let noteValue = noteValues[name],
              let octave = Int(octaveStr) else {
            return nil
        }
        
        let midiNote = (octave + 1) * 12 + noteValue
        guard midiNote >= 0 && midiNote <= 127 else { return nil }
        return UInt8(midiNote)
    }
}

// MARK: - MIDI Note Helpers

extension MIDIEvent {
    /// Create a note event
    public static func note(
        at beatPosition: Double,
        pitch: UInt8,
        velocity: UInt8 = 100,
        duration: Double = 0.25,
        channel: UInt8 = 0
    ) -> MIDIEvent {
        MIDIEvent(
            beatPosition: beatPosition,
            type: .note(NoteData(pitch: pitch, velocity: velocity, duration: duration)),
            channel: channel
        )
    }
    
    /// Create a control change event
    public static func controlChange(
        at beatPosition: Double,
        controller: UInt8,
        value: UInt8,
        channel: UInt8 = 0
    ) -> MIDIEvent {
        MIDIEvent(
            beatPosition: beatPosition,
            type: .controlChange(controller: controller, value: value),
            channel: channel
        )
    }
    
    /// Create a pitch bend event
    public static func pitchBend(
        at beatPosition: Double,
        value: Int16,
        channel: UInt8 = 0
    ) -> MIDIEvent {
        MIDIEvent(
            beatPosition: beatPosition,
            type: .pitchBend(value: value),
            channel: channel
        )
    }
}

// MARK: - Common MIDI Controllers

public enum MIDIController: UInt8, CaseIterable, Sendable {
    case modWheel = 1
    case breath = 2
    case footController = 4
    case portamentoTime = 5
    case volume = 7
    case balance = 8
    case pan = 10
    case expression = 11
    case sustainPedal = 64
    case portamento = 65
    case sostenuto = 66
    case softPedal = 67
    case legato = 68
    case hold2 = 69
    case allSoundOff = 120
    case resetAllControllers = 121
    case allNotesOff = 123
    
    public var name: String {
        switch self {
        case .modWheel: return "Mod Wheel"
        case .breath: return "Breath"
        case .footController: return "Foot Controller"
        case .portamentoTime: return "Portamento Time"
        case .volume: return "Volume"
        case .balance: return "Balance"
        case .pan: return "Pan"
        case .expression: return "Expression"
        case .sustainPedal: return "Sustain"
        case .portamento: return "Portamento"
        case .sostenuto: return "Sostenuto"
        case .softPedal: return "Soft Pedal"
        case .legato: return "Legato"
        case .hold2: return "Hold 2"
        case .allSoundOff: return "All Sound Off"
        case .resetAllControllers: return "Reset Controllers"
        case .allNotesOff: return "All Notes Off"
        }
    }
}

// MARK: - MIDI Scale and Key

public enum MIDIScale: String, CaseIterable, Sendable {
    case major
    case naturalMinor
    case harmonicMinor
    case melodicMinor
    case pentatonicMajor
    case pentatonicMinor
    case blues
    case chromatic
    
    /// Intervals from root (in semitones)
    public var intervals: [Int] {
        switch self {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .naturalMinor: return [0, 2, 3, 5, 7, 8, 10]
        case .harmonicMinor: return [0, 2, 3, 5, 7, 8, 11]
        case .melodicMinor: return [0, 2, 3, 5, 7, 9, 11]
        case .pentatonicMajor: return [0, 2, 4, 7, 9]
        case .pentatonicMinor: return [0, 3, 5, 7, 10]
        case .blues: return [0, 3, 5, 6, 7, 10]
        case .chromatic: return Array(0...11)
        }
    }
    
    /// Check if a pitch belongs to this scale with given root
    public func contains(pitch: UInt8, root: UInt8) -> Bool {
        let interval = (Int(pitch) - Int(root)) %% 12
        return intervals.contains(interval)
    }
}

// Modulo that handles negative numbers correctly
infix operator %%
private func %% (lhs: Int, rhs: Int) -> Int {
    let result = lhs % rhs
    return result >= 0 ? result : result + rhs
}
