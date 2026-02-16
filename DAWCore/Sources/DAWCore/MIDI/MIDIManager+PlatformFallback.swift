#if !canImport(CoreMIDI)
import Foundation
import Combine

/// Placeholder typealiases to keep DAWCore API source-compatible on platforms
/// where CoreMIDI is not available (e.g. Windows preview builds).
public typealias MIDIEndpointRef = UInt64
public typealias MIDITimeStamp = UInt64

// MARK: - MIDI Manager Errors

public enum MIDIError: Error, LocalizedError {
    case clientCreationFailed(Int32)
    case portCreationFailed(Int32)
    case sourceNotFound
    case destinationNotFound
    case sendFailed(Int32)
    case platformNotSupported

    public var errorDescription: String? {
        switch self {
        case .clientCreationFailed(let status):
            return "Failed to create MIDI client: \(status)"
        case .portCreationFailed(let status):
            return "Failed to create MIDI port: \(status)"
        case .sourceNotFound:
            return "MIDI source not found"
        case .destinationNotFound:
            return "MIDI destination not found"
        case .sendFailed(let status):
            return "Failed to send MIDI: \(status)"
        case .platformNotSupported:
            // TODO(windows): Replace with a real Windows MIDI backend (WinMM/Windows MIDI Services).
            return "MIDI is not yet implemented on this platform"
        }
    }
}

// MARK: - MIDI Device

public struct MIDIDevice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let manufacturer: String
    public let isInput: Bool
    public let isOutput: Bool
    public let endpointRef: MIDIEndpointRef

    public init(
        id: String,
        name: String,
        manufacturer: String,
        isInput: Bool,
        isOutput: Bool,
        endpointRef: MIDIEndpointRef
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.isInput = isInput
        self.isOutput = isOutput
        self.endpointRef = endpointRef
    }
}

// MARK: - MIDI Manager (Fallback)

/// Non-CoreMIDI fallback used only for non-Apple builds.
/// Keeps runtime stable while Windows MIDI implementation is developed.
@MainActor
public final class MIDIManager: ObservableObject {

    @Published public private(set) var inputDevices: [MIDIDevice] = []
    @Published public private(set) var outputDevices: [MIDIDevice] = []
    @Published public private(set) var isSetup: Bool = false
    @Published public var selectedInputDeviceID: String? = nil

    public let midiEventSubject = PassthroughSubject<IncomingMIDIEvent, Never>()

    public init() {}

    public func setup() throws {
        // Keep app runtime alive without crashing hard on unsupported platforms.
        // TODO(windows): enumerate Windows MIDI input/output devices and set up callbacks.
        isSetup = true
        inputDevices = []
        outputDevices = []
    }

    public func teardown() {
        isSetup = false
        inputDevices = []
        outputDevices = []
    }

    public func refreshDevices() {
        // TODO(windows): refresh actual MIDI endpoints from platform backend.
        inputDevices = []
        outputDevices = []
    }

    public func connectInput(device: MIDIDevice) throws {}

    public func disconnectInput(device: MIDIDevice) {}

    public func connectAllInputs() throws {}

    public var selectedInputDevice: MIDIDevice? {
        guard let id = selectedInputDeviceID else { return nil }
        return inputDevices.first { $0.id == id }
    }

    public func reconnectSelectedInput() {}

    public func isConnected(_ device: MIDIDevice) -> Bool { false }

    public func send(event: MIDIEvent, to destination: MIDIEndpointRef) throws {
        throw MIDIError.platformNotSupported
    }

    public func sendNoteOn(note: UInt8, velocity: UInt8, channel: UInt8, to destination: MIDIEndpointRef) throws {
        throw MIDIError.platformNotSupported
    }

    public func sendNoteOff(note: UInt8, velocity: UInt8 = 0, channel: UInt8, to destination: MIDIEndpointRef) throws {
        throw MIDIError.platformNotSupported
    }
}

// MARK: - Incoming MIDI Event

public struct IncomingMIDIEvent: Sendable {
    public let type: MIDIEventType
    public let channel: UInt8
    public let timestamp: MIDITimeStamp
    public let hostTime: UInt64

    public func toMIDIEvent(beatPosition: Double) -> MIDIEvent {
        MIDIEvent(
            beatPosition: beatPosition,
            type: type,
            channel: channel
        )
    }
}
#endif
