import Foundation
import VST3BridgeCpp

// MARK: - VST3 Plugin Info

/// Swift-friendly wrapper for VST3 plugin information
public struct VST3PluginDescription: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let vendor: String
    public let version: String
    public let category: String
    public let classID: String
    public let hasEditor: Bool
    public let isSynth: Bool
    public let numAudioInputs: Int
    public let numAudioOutputs: Int
    
    init(from info: VST3PluginInfo) {
        self.name = String(cString: withUnsafePointer(to: info.name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { $0 } })
        self.vendor = String(cString: withUnsafePointer(to: info.vendor) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { $0 } })
        self.version = String(cString: withUnsafePointer(to: info.version) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { $0 } })
        self.category = String(cString: withUnsafePointer(to: info.category) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { $0 } })
        self.classID = String(cString: withUnsafePointer(to: info.classID) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { $0 } })
        self.id = classID
        self.hasEditor = info.hasEditor
        self.isSynth = info.isSynth
        self.numAudioInputs = Int(info.numAudioInputs)
        self.numAudioOutputs = Int(info.numAudioOutputs)
    }
}

// MARK: - VST3 Parameter

public struct VST3Parameter: Identifiable, Sendable {
    public let id: UInt32
    public let name: String
    public let shortName: String
    public let units: String
    public let defaultValue: Double
    public let minValue: Double
    public let maxValue: Double
    public let stepCount: Int
    public let canAutomate: Bool
    
    init(from info: VST3ParameterInfo) {
        self.id = info.id
        self.name = String(cString: withUnsafePointer(to: info.name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { $0 } })
        self.shortName = String(cString: withUnsafePointer(to: info.shortName) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { $0 } })
        self.units = String(cString: withUnsafePointer(to: info.units) { $0.withMemoryRebound(to: CChar.self, capacity: 32) { $0 } })
        self.defaultValue = info.defaultValue
        self.minValue = info.minValue
        self.maxValue = info.maxValue
        self.stepCount = Int(info.stepCount)
        self.canAutomate = info.canAutomate
    }
}

// MARK: - VST3 Module

/// Represents a loaded VST3 module (bundle)
public final class VST3Module {
    private let moduleRef: VST3ModuleRef
    public let path: String
    
    public private(set) var plugins: [VST3PluginDescription] = []
    
    public init?(path: String) {
        guard let ref = VST3ModuleLoad(path) else {
            return nil
        }
        self.moduleRef = ref
        self.path = path
        
        loadPluginInfo()
    }
    
    deinit {
        VST3ModuleUnload(moduleRef)
    }
    
    private func loadPluginInfo() {
        let count = VST3ModuleGetPluginCount(moduleRef)
        
        for i in 0..<count {
            var info = VST3PluginInfo()
            if VST3ModuleGetPluginInfo(moduleRef, i, &info) {
                plugins.append(VST3PluginDescription(from: info))
            }
        }
    }
    
    /// Create an instance of a plugin
    public func createInstance(pluginIndex: Int) -> VST3Instance? {
        guard let ref = VST3InstanceCreate(moduleRef, Int32(pluginIndex)) else {
            return nil
        }
        return VST3Instance(instanceRef: ref)
    }
    
    /// Create an instance by class ID
    public func createInstance(classID: String) -> VST3Instance? {
        guard let ref = VST3InstanceCreateByID(moduleRef, classID) else {
            return nil
        }
        return VST3Instance(instanceRef: ref)
    }
}

// MARK: - VST3 Instance

/// Represents an active VST3 plugin instance
public final class VST3Instance {
    private let instanceRef: VST3InstanceRef
    
    public private(set) var parameters: [VST3Parameter] = []
    public private(set) var isSetUp: Bool = false
    public private(set) var isActive: Bool = false
    
    init(instanceRef: VST3InstanceRef) {
        self.instanceRef = instanceRef
        loadParameters()
    }
    
    deinit {
        VST3InstanceDestroy(instanceRef)
    }
    
    // MARK: - Setup
    
    private func loadParameters() {
        let count = VST3InstanceGetParameterCount(instanceRef)
        
        for i in 0..<count {
            var info = VST3ParameterInfo()
            if VST3InstanceGetParameterInfo(instanceRef, i, &info) {
                parameters.append(VST3Parameter(from: info))
            }
        }
    }
    
    /// Set up audio processing
    public func setup(sampleRate: Int, maxBlockSize: Int, numChannels: Int = 2) -> Bool {
        var setup = VST3ProcessSetup()
        setup.sampleRate = Int32(sampleRate)
        setup.maxBlockSize = Int32(maxBlockSize)
        setup.numChannels = Int32(numChannels)
        setup.is64Bit = false
        
        isSetUp = VST3InstanceSetup(instanceRef, &setup)
        return isSetUp
    }
    
    /// Activate the plugin
    public func activate() -> Bool {
        isActive = VST3InstanceActivate(instanceRef)
        return isActive
    }
    
    /// Deactivate the plugin
    public func deactivate() -> Bool {
        let result = VST3InstanceDeactivate(instanceRef)
        if result {
            isActive = false
        }
        return result
    }
    
    // MARK: - Processing
    
    /// Process audio buffers
    public func process(
        inputs: [[Float]],
        outputs: inout [[Float]],
        midiEvents: [VST3MIDIEventData] = []
    ) -> Bool {
        let numSamples = inputs.first?.count ?? outputs.first?.count ?? 0
        guard numSamples > 0 else { return false }
        
        // For a real VST3 implementation, you would need proper buffer management
        // This is a simplified stub that just returns success
        // The actual C++ bridge handles the audio processing
        
        var buffers = VST3AudioBuffers()
        buffers.numSamples = Int32(numSamples)
        buffers.numInputChannels = Int32(inputs.count)
        buffers.numOutputChannels = Int32(outputs.count)
        buffers.inputs = nil
        buffers.outputs = nil
        
        // Process with C bridge (stub - actual implementation requires VST3 SDK)
        if midiEvents.isEmpty {
            return VST3InstanceProcess(instanceRef, &buffers, nil, 0)
        } else {
            var cEvents = midiEvents.map { event in
                VST3MIDIEvent(
                    sampleOffset: Int32(event.sampleOffset),
                    status: event.status,
                    data1: event.data1,
                    data2: event.data2,
                    channel: event.channel
                )
            }
            return cEvents.withUnsafeMutableBufferPointer { eventBuf in
                VST3InstanceProcess(instanceRef, &buffers, eventBuf.baseAddress, Int32(midiEvents.count))
            }
        }
    }
    
    // MARK: - Parameters
    
    /// Get parameter value
    public func getParameter(_ id: UInt32) -> Double {
        VST3InstanceGetParameter(instanceRef, id)
    }
    
    /// Set parameter value
    public func setParameter(_ id: UInt32, value: Double) {
        _ = VST3InstanceSetParameter(instanceRef, id, value)
    }
    
    /// Begin parameter edit gesture
    public func beginEdit(_ id: UInt32) {
        VST3InstanceBeginEdit(instanceRef, id)
    }
    
    /// End parameter edit gesture
    public func endEdit(_ id: UInt32) {
        VST3InstanceEndEdit(instanceRef, id)
    }
    
    // MARK: - State
    
    /// Save plugin state
    public func saveState() -> Data? {
        let size = VST3InstanceGetStateSize(instanceRef)
        guard size > 0 else { return nil }
        
        var buffer = [UInt8](repeating: 0, count: Int(size))
        let written = VST3InstanceSaveState(instanceRef, &buffer, size)
        
        guard written > 0 else { return nil }
        return Data(buffer.prefix(Int(written)))
    }
    
    /// Load plugin state
    public func loadState(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return VST3InstanceLoadState(instanceRef, pointer, Int32(data.count))
        }
    }
    
    // MARK: - Editor
    
    /// Check if plugin has editor
    public var hasEditor: Bool {
        VST3InstanceHasEditor(instanceRef)
    }
    
    /// Get preferred editor size
    public func getEditorSize() -> (width: Int, height: Int)? {
        var width: Int32 = 0
        var height: Int32 = 0
        
        guard VST3InstanceGetEditorSize(instanceRef, &width, &height) else {
            return nil
        }
        
        return (Int(width), Int(height))
    }
    
    /// Open editor in a parent view
    public func openEditor(in parentView: AnyObject) -> Bool {
        let pointer = Unmanaged.passUnretained(parentView).toOpaque()
        return VST3InstanceOpenEditor(instanceRef, pointer)
    }
    
    /// Close editor
    public func closeEditor() {
        VST3InstanceCloseEditor(instanceRef)
    }
}

// MARK: - VST3 MIDI Event Data

public struct VST3MIDIEventData {
    public var sampleOffset: Int
    public var status: UInt8
    public var data1: UInt8
    public var data2: UInt8
    public var channel: UInt8
    
    public init(sampleOffset: Int, status: UInt8, data1: UInt8, data2: UInt8, channel: UInt8 = 0) {
        self.sampleOffset = sampleOffset
        self.status = status
        self.data1 = data1
        self.data2 = data2
        self.channel = channel
    }
    
    /// Create a note on event
    public static func noteOn(sampleOffset: Int, note: UInt8, velocity: UInt8, channel: UInt8 = 0) -> VST3MIDIEventData {
        VST3MIDIEventData(sampleOffset: sampleOffset, status: 0x90 | channel, data1: note, data2: velocity, channel: channel)
    }
    
    /// Create a note off event
    public static func noteOff(sampleOffset: Int, note: UInt8, velocity: UInt8 = 0, channel: UInt8 = 0) -> VST3MIDIEventData {
        VST3MIDIEventData(sampleOffset: sampleOffset, status: 0x80 | channel, data1: note, data2: velocity, channel: channel)
    }
}

// MARK: - VST3 Scanner

/// Scans for VST3 plugins on the system
public final class VST3Scanner {
    
    /// Default VST3 plugin locations on macOS
    public static var defaultSearchPaths: [String] {
        var paths: [String] = []
        
        // User plugins
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            paths.append("\(home)/Library/Audio/Plug-Ins/VST3")
        }
        
        // System plugins
        paths.append("/Library/Audio/Plug-Ins/VST3")
        paths.append("/Network/Library/Audio/Plug-Ins/VST3")
        
        return paths
    }
    
    /// Scan all default locations
    public static func scanDefaultLocations() -> [VST3PluginDescription] {
        var allPlugins: [VST3PluginDescription] = []
        
        for path in defaultSearchPaths {
            if let plugins = scanDirectory(path) {
                allPlugins.append(contentsOf: plugins)
            }
        }
        
        return allPlugins
    }
    
    /// Scan a specific directory
    public static func scanDirectory(_ path: String) -> [VST3PluginDescription]? {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }
        
        var plugins: [VST3PluginDescription] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            
            for item in contents where item.hasSuffix(".vst3") {
                let pluginPath = (path as NSString).appendingPathComponent(item)
                
                if let module = VST3Module(path: pluginPath) {
                    plugins.append(contentsOf: module.plugins)
                }
            }
        } catch {
            return nil
        }
        
        return plugins
    }
    
    /// Get last error from VST3 bridge
    public static var lastError: String {
        String(cString: VST3GetLastError())
    }
    
    /// Get VST3 SDK version
    public static var sdkVersion: String {
        String(cString: VST3GetSDKVersion())
    }
}
