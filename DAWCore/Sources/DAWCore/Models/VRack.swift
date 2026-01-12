import Foundation

// MARK: - Rack Instrument

/// A virtual instrument hosted in the V-Rack
/// Can receive MIDI from multiple tracks on different channels
public struct RackInstrument: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var pluginSlot: PluginSlot
    public var volume: Float       // 0.0 to 1.0 (linear)
    public var isMuted: Bool
    
    public init(
        id: UUID = UUID(),
        name: String = "New Instrument",
        pluginSlot: PluginSlot = PluginSlot(),
        volume: Float = 0.7937,  // -2 dB
        isMuted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.pluginSlot = pluginSlot
        self.volume = volume
        self.isMuted = isMuted
    }
    
    /// Volume in decibels
    public var volumeDB: Float {
        get {
            if volume <= 0 { return -.infinity }
            return 20 * log10(volume)
        }
        set {
            if newValue == -.infinity {
                volume = 0
            } else {
                volume = pow(10, newValue / 20)
            }
        }
    }
}

// MARK: - V-Rack

/// The V-Rack holds multi-timbral instruments that can receive MIDI from multiple tracks
/// Similar to Digital Performer's V-Rack concept
public struct VRack: Codable, Sendable {
    public var instruments: [RackInstrument]
    
    public init(instruments: [RackInstrument] = []) {
        self.instruments = instruments
    }
    
    /// Get a rack instrument by ID
    public func instrument(withID id: UUID) -> RackInstrument? {
        instruments.first { $0.id == id }
    }
    
    /// Get index of instrument by ID
    public func indexOfInstrument(withID id: UUID) -> Int? {
        instruments.firstIndex { $0.id == id }
    }
    
    /// Update an instrument in the rack
    public mutating func updateInstrument(_ instrument: RackInstrument) {
        if let index = indexOfInstrument(withID: instrument.id) {
            instruments[index] = instrument
        }
    }
    
    /// Add a new instrument to the rack
    public mutating func addInstrument(_ instrument: RackInstrument) {
        instruments.append(instrument)
    }
    
    /// Remove an instrument from the rack
    public mutating func removeInstrument(withID id: UUID) {
        instruments.removeAll { $0.id == id }
    }
}

// MARK: - MIDI Output Destination

/// Defines where a MIDI track sends its output
public enum MIDIOutputDestination: Codable, Sendable, Hashable {
    /// Use the track's own instrument slot (default behavior)
    case trackInstrument
    
    /// Route to a V-Rack instrument on a specific MIDI channel (1-16)
    case rackInstrument(id: UUID, channel: UInt8)
    
    /// Display name for the destination
    public func displayName(in vRack: VRack) -> String {
        switch self {
        case .trackInstrument:
            return "Track Instrument"
        case .rackInstrument(let id, let channel):
            if let instrument = vRack.instrument(withID: id) {
                return "\(instrument.name) Ch \(channel)"
            }
            return "Unknown Ch \(channel)"
        }
    }
}
