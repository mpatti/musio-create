import Foundation
import CoreMIDI
import Combine

// MARK: - MIDI Manager Errors

public enum MIDIError: Error, LocalizedError {
    case clientCreationFailed(OSStatus)
    case portCreationFailed(OSStatus)
    case sourceNotFound
    case destinationNotFound
    case sendFailed(OSStatus)
    
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

// MARK: - MIDI Manager

/// Manages CoreMIDI input/output and device discovery
@MainActor
public final class MIDIManager: ObservableObject {
    
    // MARK: - Properties
    
    private var midiClient: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var virtualSource: MIDIEndpointRef = 0
    private var virtualDestination: MIDIEndpointRef = 0
    
    @Published public private(set) var inputDevices: [MIDIDevice] = []
    @Published public private(set) var outputDevices: [MIDIDevice] = []
    @Published public private(set) var isSetup: Bool = false
    
    /// Currently selected input device (nil = all devices)
    @Published public var selectedInputDeviceID: String? = nil {
        didSet {
            if isSetup {
                reconnectSelectedInput()
            }
        }
    }
    
    /// Publisher for incoming MIDI events
    public let midiEventSubject = PassthroughSubject<IncomingMIDIEvent, Never>()
    
    // Connected devices
    private var connectedInputs: Set<MIDIEndpointRef> = []
    
    // MARK: - Initialization
    
    public init() {}
    
    deinit {
        // Cleanup MIDI resources directly in deinit
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
        }
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
        }
        if virtualSource != 0 {
            MIDIEndpointDispose(virtualSource)
        }
        if virtualDestination != 0 {
            MIDIEndpointDispose(virtualDestination)
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
        }
    }
    
    // MARK: - Setup
    
    public func setup() throws {
        guard !isSetup else { return }
        
        // Create MIDI client
        var status = MIDIClientCreateWithBlock("MusioCreate" as CFString, &midiClient) { [weak self] notification in
            Task { @MainActor in
                self?.handleMIDINotification(notification)
            }
        }
        
        guard status == noErr else {
            throw MIDIError.clientCreationFailed(status)
        }
        
        // Create input port
        status = MIDIInputPortCreateWithProtocol(
            midiClient,
            "Input" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventList, srcConnRefCon in
            self?.handleMIDIInput(eventList: eventList)
        }
        
        guard status == noErr else {
            throw MIDIError.portCreationFailed(status)
        }
        
        // Create output port
        status = MIDIOutputPortCreate(
            midiClient,
            "Output" as CFString,
            &outputPort
        )
        
        guard status == noErr else {
            throw MIDIError.portCreationFailed(status)
        }
        
        // Create virtual source (for sending MIDI to other apps)
        status = MIDISourceCreateWithProtocol(
            midiClient,
            "Musio Create Out" as CFString,
            ._1_0,
            &virtualSource
        )
        
        // Create virtual destination (for receiving MIDI from other apps)
        status = MIDIDestinationCreateWithProtocol(
            midiClient,
            "Musio Create In" as CFString,
            ._1_0,
            &virtualDestination
        ) { [weak self] eventList, srcConnRefCon in
            self?.handleMIDIInput(eventList: eventList)
        }
        
        isSetup = true
        refreshDevices()
    }
    
    public func teardown() {
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
            inputPort = 0
        }
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
            outputPort = 0
        }
        if virtualSource != 0 {
            MIDIEndpointDispose(virtualSource)
            virtualSource = 0
        }
        if virtualDestination != 0 {
            MIDIEndpointDispose(virtualDestination)
            virtualDestination = 0
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
            midiClient = 0
        }
        isSetup = false
    }
    
    // MARK: - Device Discovery
    
    public func refreshDevices() {
        var inputs: [MIDIDevice] = []
        var outputs: [MIDIDevice] = []
        
        // Get sources (inputs)
        let sourceCount = MIDIGetNumberOfSources()
        for i in 0..<sourceCount {
            let endpoint = MIDIGetSource(i)
            if let device = createDevice(from: endpoint, isInput: true) {
                inputs.append(device)
            }
        }
        
        // Get destinations (outputs)
        let destCount = MIDIGetNumberOfDestinations()
        for i in 0..<destCount {
            let endpoint = MIDIGetDestination(i)
            if let device = createDevice(from: endpoint, isInput: false) {
                outputs.append(device)
            }
        }
        
        inputDevices = inputs
        outputDevices = outputs
    }
    
    private func createDevice(from endpoint: MIDIEndpointRef, isInput: Bool) -> MIDIDevice? {
        guard endpoint != 0 else { return nil }
        
        var name: Unmanaged<CFString>?
        var manufacturer: Unmanaged<CFString>?
        var uniqueID: Int32 = 0
        
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyManufacturer, &manufacturer)
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
        
        let deviceName = name?.takeRetainedValue() as String? ?? "Unknown"
        let deviceManufacturer = manufacturer?.takeRetainedValue() as String? ?? "Unknown"
        
        return MIDIDevice(
            id: "\(uniqueID)",
            name: deviceName,
            manufacturer: deviceManufacturer,
            isInput: isInput,
            isOutput: !isInput,
            endpointRef: endpoint
        )
    }
    
    // MARK: - Connection
    
    public func connectInput(device: MIDIDevice) throws {
        guard device.isInput else { return }
        
        let status = MIDIPortConnectSource(inputPort, device.endpointRef, nil)
        guard status == noErr else {
            throw MIDIError.portCreationFailed(status)
        }
        
        connectedInputs.insert(device.endpointRef)
    }
    
    public func disconnectInput(device: MIDIDevice) {
        MIDIPortDisconnectSource(inputPort, device.endpointRef)
        connectedInputs.remove(device.endpointRef)
    }
    
    public func connectAllInputs() throws {
        for device in inputDevices {
            try connectInput(device: device)
        }
    }
    
    /// Get the currently selected input device
    public var selectedInputDevice: MIDIDevice? {
        guard let id = selectedInputDeviceID else { return nil }
        return inputDevices.first { $0.id == id }
    }
    
    /// Reconnect to the selected input device (or all if none selected)
    public func reconnectSelectedInput() {
        // Disconnect all current inputs
        for endpoint in connectedInputs {
            MIDIPortDisconnectSource(inputPort, endpoint)
        }
        connectedInputs.removeAll()
        
        // Connect to selected device or all devices
        if let selectedID = selectedInputDeviceID,
           let device = inputDevices.first(where: { $0.id == selectedID }) {
            do {
                try connectInput(device: device)
                print("[MIDI] Connected to: \(device.name)")
            } catch {
                print("[MIDI] Failed to connect to \(device.name): \(error)")
            }
        } else {
            // Connect to all inputs
            do {
                try connectAllInputs()
                print("[MIDI] Connected to all \(inputDevices.count) input devices")
            } catch {
                print("[MIDI] Failed to connect to all inputs: \(error)")
            }
        }
    }
    
    /// Check if a device is currently connected
    public func isConnected(_ device: MIDIDevice) -> Bool {
        connectedInputs.contains(device.endpointRef)
    }
    
    // MARK: - MIDI Input Handling
    
    private func handleMIDIInput(eventList: UnsafePointer<MIDIEventList>) {
        // CRITICAL: Capture host time IMMEDIATELY at callback time
        // This is the most accurate timestamp we can get
        let callbackHostTime = mach_absolute_time()
        
        let eventList = eventList.pointee
        
        withUnsafePointer(to: eventList.packet) { firstPacket in
            var packet = firstPacket
            
            for _ in 0..<eventList.numPackets {
                let wordCount = Int(packet.pointee.wordCount)
                
                // Parse MIDI 1.0 channel voice messages (in UMP format)
                if wordCount >= 1 {
                    withUnsafeBytes(of: packet.pointee.words) { wordsBuffer in
                        let words = wordsBuffer.bindMemory(to: UInt32.self)
                        
                        for i in 0..<wordCount {
                            let word = words[i]
                            
                            // Extract message type and group from UMP
                            let messageType = (word >> 28) & 0x0F
                            
                            // MIDI 1.0 channel voice message (type 2)
                            if messageType == 2 {
                                let status = UInt8((word >> 16) & 0xFF)
                                let data1 = UInt8((word >> 8) & 0xFF)
                                let data2 = UInt8(word & 0xFF)
                                
                                let event = parseMIDI1Message(
                                    status: status,
                                    data1: data1,
                                    data2: data2,
                                    timestamp: packet.pointee.timeStamp,
                                    hostTime: callbackHostTime
                                )
                                
                                if let event = event {
                                    Task { @MainActor in
                                        self.midiEventSubject.send(event)
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Move to next packet
                packet = UnsafePointer(MIDIEventPacketNext(packet))
            }
        }
    }
    
    private func parseMIDI1Message(
        status: UInt8,
        data1: UInt8,
        data2: UInt8,
        timestamp: MIDITimeStamp,
        hostTime: UInt64
    ) -> IncomingMIDIEvent? {
        let messageType = status & 0xF0
        let channel = status & 0x0F
        
        let eventType: MIDIEventType?
        
        switch messageType {
        case 0x90:  // Note On
            if data2 == 0 {
                // Velocity 0 = Note Off
                eventType = .note(NoteData(pitch: data1, velocity: 0, duration: 0))
            } else {
                eventType = .note(NoteData(pitch: data1, velocity: data2, duration: 0))
            }
            
        case 0x80:  // Note Off
            eventType = .note(NoteData(pitch: data1, velocity: 0, duration: 0, releaseVelocity: data2))
            
        case 0xB0:  // Control Change
            eventType = .controlChange(controller: data1, value: data2)
            
        case 0xC0:  // Program Change
            eventType = .programChange(program: data1)
            
        case 0xE0:  // Pitch Bend
            let value = Int16(data1) | (Int16(data2) << 7) - 8192
            eventType = .pitchBend(value: value)
            
        case 0xA0:  // Poly Aftertouch
            eventType = .polyAftertouch(note: data1, pressure: data2)
            
        case 0xD0:  // Channel Aftertouch
            eventType = .aftertouch(pressure: data1)
            
        default:
            eventType = nil
        }
        
        guard let type = eventType else { return nil }
        
        return IncomingMIDIEvent(
            type: type,
            channel: channel,
            timestamp: timestamp,
            hostTime: hostTime
        )
    }
    
    // MARK: - MIDI Output
    
    /// Send a MIDI event to a destination
    public func send(
        event: MIDIEvent,
        to destination: MIDIEndpointRef
    ) throws {
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        
        let bytes = eventToBytes(event)
        packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, bytes)
        
        let status = MIDISend(outputPort, destination, &packetList)
        guard status == noErr else {
            throw MIDIError.sendFailed(status)
        }
    }
    
    /// Send a note on message
    public func sendNoteOn(
        note: UInt8,
        velocity: UInt8,
        channel: UInt8,
        to destination: MIDIEndpointRef
    ) throws {
        let bytes: [UInt8] = [0x90 | (channel & 0x0F), note & 0x7F, velocity & 0x7F]
        try sendBytes(bytes, to: destination)
    }
    
    /// Send a note off message
    public func sendNoteOff(
        note: UInt8,
        velocity: UInt8 = 0,
        channel: UInt8,
        to destination: MIDIEndpointRef
    ) throws {
        let bytes: [UInt8] = [0x80 | (channel & 0x0F), note & 0x7F, velocity & 0x7F]
        try sendBytes(bytes, to: destination)
    }
    
    private func sendBytes(_ bytes: [UInt8], to destination: MIDIEndpointRef) throws {
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, bytes)
        
        let status = MIDISend(outputPort, destination, &packetList)
        guard status == noErr else {
            throw MIDIError.sendFailed(status)
        }
    }
    
    private func eventToBytes(_ event: MIDIEvent) -> [UInt8] {
        let channel = event.channel & 0x0F
        
        switch event.type {
        case .note(let data):
            if data.velocity == 0 {
                return [0x80 | channel, data.pitch & 0x7F, data.releaseVelocity ?? 0]
            } else {
                return [0x90 | channel, data.pitch & 0x7F, data.velocity & 0x7F]
            }
            
        case .controlChange(let controller, let value):
            return [0xB0 | channel, controller & 0x7F, value & 0x7F]
            
        case .programChange(let program):
            return [0xC0 | channel, program & 0x7F]
            
        case .pitchBend(let value):
            let adjusted = UInt16(bitPattern: Int16(value + 8192))
            return [0xE0 | channel, UInt8(adjusted & 0x7F), UInt8((adjusted >> 7) & 0x7F)]
            
        case .aftertouch(let pressure):
            return [0xD0 | channel, pressure & 0x7F]
            
        case .polyAftertouch(let note, let pressure):
            return [0xA0 | channel, note & 0x7F, pressure & 0x7F]
            
        case .sysex(let data):
            return Array(data)
        }
    }
    
    // MARK: - Notifications
    
    private func handleMIDINotification(_ notification: UnsafePointer<MIDINotification>) {
        switch notification.pointee.messageID {
        case .msgSetupChanged:
            refreshDevices()
        case .msgObjectAdded, .msgObjectRemoved:
            refreshDevices()
        default:
            break
        }
    }
}

// MARK: - Incoming MIDI Event

public struct IncomingMIDIEvent: Sendable {
    public let type: MIDIEventType
    public let channel: UInt8
    public let timestamp: MIDITimeStamp
    /// Host time captured at the moment of MIDI callback (mach_absolute_time)
    public let hostTime: UInt64
    
    /// Convert to a standard MIDIEvent with beat position
    public func toMIDIEvent(beatPosition: Double) -> MIDIEvent {
        MIDIEvent(
            beatPosition: beatPosition,
            type: type,
            channel: channel
        )
    }
}
