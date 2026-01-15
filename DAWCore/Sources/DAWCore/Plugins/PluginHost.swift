import Foundation
import AVFoundation
import AudioToolbox
import Combine

// MARK: - Plugin Host Error

public enum PluginHostError: Error, LocalizedError {
    case pluginNotFound(PluginIdentifier)
    case instantiationFailed(String)
    case presetLoadFailed(String)
    case presetSaveFailed(String)
    case parameterNotFound(String)
    case invalidPluginType
    
    public var errorDescription: String? {
        switch self {
        case .pluginNotFound(let id):
            return "Plugin not found: \(id.name) by \(id.manufacturer)"
        case .instantiationFailed(let reason):
            return "Failed to instantiate plugin: \(reason)"
        case .presetLoadFailed(let reason):
            return "Failed to load preset: \(reason)"
        case .presetSaveFailed(let reason):
            return "Failed to save preset: \(reason)"
        case .parameterNotFound(let name):
            return "Parameter not found: \(name)"
        case .invalidPluginType:
            return "Invalid plugin type for this operation"
        }
    }
}

// MARK: - Plugin Description

public struct PluginDescription: Identifiable, Sendable {
    public let id: String
    public let identifier: PluginIdentifier
    public let version: String
    public let hasCustomView: Bool
    public let audioComponentDescription: AudioComponentDescription
    
    public init(
        identifier: PluginIdentifier,
        version: String = "1.0",
        hasCustomView: Bool = true,
        audioComponentDescription: AudioComponentDescription
    ) {
        self.id = identifier.uniqueID
        self.identifier = identifier
        self.version = version
        self.hasCustomView = hasCustomView
        self.audioComponentDescription = audioComponentDescription
    }
}

// MARK: - Plugin Host

/// Manages discovery, loading, and control of audio plugins
@MainActor
public final class PluginHost: ObservableObject {
    
    // MARK: - Properties
    
    @Published public private(set) var availableEffects: [PluginDescription] = []
    @Published public private(set) var availableInstruments: [PluginDescription] = []
    @Published public private(set) var isScanning: Bool = false
    
    public private(set) var loadedPlugins: [UUID: LoadedPlugin] = [:]
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Plugin Discovery
    
    /// Scan for available Audio Units
    public func scanForPlugins() async {
        isScanning = true
        defer { isScanning = false }
        
        // Scan for effects
        let effects = await scanForAudioUnits(type: kAudioUnitType_Effect)
        let mfxEffects = await scanForAudioUnits(type: kAudioUnitType_MusicEffect)
        
        // Scan for instruments
        let instruments = await scanForAudioUnits(type: kAudioUnitType_MusicDevice)
        
        availableEffects = effects + mfxEffects
        availableInstruments = instruments
    }
    
    private func scanForAudioUnits(type: OSType) async -> [PluginDescription] {
        var descriptions: [PluginDescription] = []
        
        var componentDescription = AudioComponentDescription(
            componentType: type,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        var component: AudioComponent? = nil
        
        repeat {
            component = AudioComponentFindNext(component, &componentDescription)
            
            if let component = component {
                var name: Unmanaged<CFString>?
                AudioComponentCopyName(component, &name)
                
                var desc = AudioComponentDescription()
                AudioComponentGetDescription(component, &desc)
                
                let pluginName = name?.takeRetainedValue() as String? ?? "Unknown"
                let (manufacturer, subtype) = extractStrings(from: desc)
                
                let pluginType: PluginType = {
                    switch desc.componentType {
                    case kAudioUnitType_Effect, kAudioUnitType_MusicEffect:
                        return .audioUnitEffect
                    case kAudioUnitType_MusicDevice:
                        return .audioUnitInstrument
                    case kAudioUnitType_MIDIProcessor:
                        return .audioUnitMIDI
                    default:
                        return .audioUnitEffect
                    }
                }()
                
                let identifier = PluginIdentifier(
                    type: pluginType,
                    manufacturer: manufacturer,
                    name: pluginName,
                    uniqueID: "\(desc.componentType)-\(desc.componentSubType)-\(desc.componentManufacturer)"
                )
                
                let description = PluginDescription(
                    identifier: identifier,
                    audioComponentDescription: desc
                )
                
                descriptions.append(description)
            }
        } while component != nil
        
        return descriptions.sorted { $0.identifier.name < $1.identifier.name }
    }
    
    private func extractStrings(from desc: AudioComponentDescription) -> (manufacturer: String, subtype: String) {
        let manufacturer = fourCharCode(desc.componentManufacturer)
        let subtype = fourCharCode(desc.componentSubType)
        return (manufacturer, subtype)
    }
    
    private func fourCharCode(_ code: OSType) -> String {
        let chars = [
            Character(UnicodeScalar((code >> 24) & 0xFF)!),
            Character(UnicodeScalar((code >> 16) & 0xFF)!),
            Character(UnicodeScalar((code >> 8) & 0xFF)!),
            Character(UnicodeScalar(code & 0xFF)!)
        ]
        return String(chars)
    }
    
    // MARK: - Plugin Loading
    
    /// Load a plugin and return the AVAudioUnit
    public func loadPlugin(
        _ description: PluginDescription,
        format: AVAudioFormat
    ) async throws -> AVAudioUnit {
        // First try in-process loading (better performance)
        // If that fails, try out-of-process loading (better compatibility)
        
        print("[PluginHost] Attempting to load plugin: \(description.identifier.name)")
        
        // Try in-process first
        do {
            let audioUnit = try await loadPluginWithOptions(description, options: [])
            print("[PluginHost] Successfully loaded plugin in-process: \(audioUnit.name)")
            return audioUnit
        } catch {
            print("[PluginHost] In-process loading failed: \(error)")
            print("[PluginHost] Trying out-of-process loading...")
        }
        
        // Fallback to out-of-process loading
        do {
            let audioUnit = try await loadPluginWithOptions(description, options: .loadOutOfProcess)
            print("[PluginHost] Successfully loaded plugin out-of-process: \(audioUnit.name)")
            return audioUnit
        } catch {
            print("[PluginHost] Out-of-process loading also failed: \(error)")
            throw PluginHostError.instantiationFailed(error.localizedDescription)
        }
    }
    
    private func loadPluginWithOptions(
        _ description: PluginDescription,
        options: AudioComponentInstantiationOptions
    ) async throws -> AVAudioUnit {
        return try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(
                with: description.audioComponentDescription,
                options: options
            ) { audioUnit, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let audioUnit = audioUnit else {
                    continuation.resume(throwing: PluginHostError.instantiationFailed("Audio unit is nil"))
                    return
                }
                
                continuation.resume(returning: audioUnit)
            }
        }
    }
    
    /// Load a plugin for a specific track slot
    public func loadPlugin(
        identifier: PluginIdentifier,
        format: AVAudioFormat,
        instanceID: UUID = UUID()
    ) async throws -> LoadedPlugin {
        // Find the plugin description
        let allPlugins = availableEffects + availableInstruments
        guard let description = allPlugins.first(where: { $0.identifier == identifier }) else {
            throw PluginHostError.pluginNotFound(identifier)
        }
        
        let audioUnit = try await loadPlugin(description, format: format)
        
        // Extract parameters
        let parameters = extractParameters(from: audioUnit)
        
        let loadedPlugin = LoadedPlugin(
            id: instanceID,
            identifier: identifier,
            audioUnit: audioUnit,
            parameters: parameters
        )
        
        loadedPlugins[instanceID] = loadedPlugin
        
        return loadedPlugin
    }
    
    // MARK: - Parameter Management
    
    private func extractParameters(from audioUnit: AVAudioUnit) -> [PluginParameter] {
        var parameters: [PluginParameter] = []
        
        guard let parameterTree = audioUnit.auAudioUnit.parameterTree else {
            return parameters
        }
        
        for param in parameterTree.allParameters {
            let pluginParam = PluginParameter(
                id: String(param.address),
                name: param.displayName,
                minValue: param.minValue,
                maxValue: param.maxValue,
                defaultValue: param.value,
                unit: mapParameterUnit(param.unit)
            )
            parameters.append(pluginParam)
        }
        
        return parameters
    }
    
    private func mapParameterUnit(_ unit: AudioUnitParameterUnit) -> PluginParameterUnit {
        switch unit {
        case .generic, .indexed: return .generic
        case .boolean: return .boolean
        case .percent: return .percent
        case .seconds, .milliseconds: return .time
        case .hertz: return .frequency
        case .decibels: return .decibels
        case .pan: return .pan
        default: return .generic
        }
    }
    
    /// Get parameter value
    public func getParameterValue(
        pluginID: UUID,
        parameterID: String
    ) -> Float? {
        guard let loaded = loadedPlugins[pluginID],
              let parameterTree = loaded.audioUnit.auAudioUnit.parameterTree,
              let address = AUParameterAddress(parameterID),
              let param = parameterTree.parameter(withAddress: address) else {
            return nil
        }
        
        return param.value
    }
    
    /// Set parameter value
    public func setParameterValue(
        pluginID: UUID,
        parameterID: String,
        value: Float
    ) {
        guard let loaded = loadedPlugins[pluginID],
              let parameterTree = loaded.audioUnit.auAudioUnit.parameterTree,
              let address = AUParameterAddress(parameterID),
              let param = parameterTree.parameter(withAddress: address) else {
            return
        }
        
        param.value = value
    }
    
    // MARK: - Preset Management
    
    /// Save plugin state as preset data (uses fullStateForDocument for complete state)
    public func savePreset(pluginID: UUID) throws -> Data {
        guard let loaded = loadedPlugins[pluginID] else {
            throw PluginHostError.presetSaveFailed("Plugin not found: \(pluginID)")
        }
        
        let auUnit = loaded.audioUnit.auAudioUnit
        
        print("[PluginHost] ====== SAVING STATE FOR \(loaded.name) ======")
        
        // Try fullStateForDocument first (most complete for saving to documents)
        // Then fall back to fullState
        var stateDict: [String: Any]?
        
        if let docState = auUnit.fullStateForDocument {
            stateDict = docState
            print("[PluginHost] Using fullStateForDocument")
        } else if let fullState = auUnit.fullState {
            stateDict = fullState
            print("[PluginHost] Using fullState (fullStateForDocument not available)")
        }
        
        guard let state = stateDict else {
            throw PluginHostError.presetSaveFailed("No state available for \(loaded.name)")
        }
        
        // Log state details for debugging
        print("[PluginHost] State keys: \(state.keys.sorted())")
        for (key, value) in state {
            let valueType = type(of: value)
            if let data = value as? Data {
                print("[PluginHost]   \(key): Data (\(data.count) bytes)")
            } else if let str = value as? String {
                print("[PluginHost]   \(key): String = \(str.prefix(50))")
            } else if let num = value as? NSNumber {
                print("[PluginHost]   \(key): Number = \(num)")
            } else {
                print("[PluginHost]   \(key): \(valueType)")
            }
        }
        
        // Use PropertyListSerialization instead of NSKeyedArchiver for better compatibility
        let data = try PropertyListSerialization.data(
            fromPropertyList: state,
            format: .binary,
            options: 0
        )
        
        print("[PluginHost] Saved \(data.count) bytes for \(loaded.name)")
        print("[PluginHost] ====== END SAVE ======")
        return data
    }
    
    /// Load plugin state from preset data
    public func loadPreset(pluginID: UUID, data: Data) throws {
        guard let loaded = loadedPlugins[pluginID] else {
            throw PluginHostError.presetLoadFailed("Plugin not found: \(pluginID)")
        }
        
        print("[PluginHost] ====== LOADING STATE FOR \(loaded.name) ======")
        print("[PluginHost] Data size: \(data.count) bytes")
        
        // Use PropertyListSerialization to decode
        guard let state = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw PluginHostError.presetLoadFailed("Invalid preset data for \(loaded.name)")
        }
        
        print("[PluginHost] State keys to restore: \(state.keys.sorted())")
        for (key, value) in state {
            let valueType = type(of: value)
            if let data = value as? Data {
                print("[PluginHost]   \(key): Data (\(data.count) bytes)")
            } else {
                print("[PluginHost]   \(key): \(valueType)")
            }
        }
        
        let auUnit = loaded.audioUnit.auAudioUnit
        
        // Set fullStateForDocument (this is what DAWs typically use)
        print("[PluginHost] Setting fullStateForDocument...")
        auUnit.fullStateForDocument = state
        
        // Also set fullState as fallback
        print("[PluginHost] Setting fullState...")
        auUnit.fullState = state
        
        // Verify it took
        if let verifyState = auUnit.fullState {
            print("[PluginHost] Verify - fullState keys after restore: \(verifyState.keys.sorted())")
        } else {
            print("[PluginHost] WARNING: fullState is nil after restore!")
        }
        
        print("[PluginHost] ====== END LOAD ======")
    }
    
    /// Get factory presets
    public func getFactoryPresets(pluginID: UUID) -> [AUAudioUnitPreset] {
        guard let loaded = loadedPlugins[pluginID] else {
            return []
        }
        
        return loaded.audioUnit.auAudioUnit.factoryPresets ?? []
    }
    
    /// Load factory preset
    public func loadFactoryPreset(pluginID: UUID, preset: AUAudioUnitPreset) {
        guard let loaded = loadedPlugins[pluginID] else { return }
        loaded.audioUnit.auAudioUnit.currentPreset = preset
    }
    
    // MARK: - Plugin Unloading
    
    public func unloadPlugin(id: UUID) {
        loadedPlugins.removeValue(forKey: id)
    }
    
    public func unloadAllPlugins() {
        loadedPlugins.removeAll()
    }
}

// MARK: - Loaded Plugin

public struct LoadedPlugin: Identifiable {
    public let id: UUID
    public let identifier: PluginIdentifier
    public let audioUnit: AVAudioUnit
    public let parameters: [PluginParameter]
    
    public var name: String { identifier.name }
    public var manufacturer: String { identifier.manufacturer }
}

// MARK: - Plugin Parameter

public struct PluginParameter: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let minValue: Float
    public let maxValue: Float
    public let defaultValue: Float
    public let unit: PluginParameterUnit
    
    public func normalizedValue(_ value: Float) -> Float {
        (value - minValue) / (maxValue - minValue)
    }
    
    public func denormalizedValue(_ normalized: Float) -> Float {
        minValue + normalized * (maxValue - minValue)
    }
}

public enum PluginParameterUnit: String, Sendable {
    case generic
    case boolean
    case percent
    case time
    case frequency
    case decibels
    case pan
}

// MARK: - Plugin View Provider

#if canImport(CoreAudioKit)
import CoreAudioKit
import AppKit

/// Provides the UI for a plugin (either custom AU view or generic)
@MainActor
public final class PluginViewProvider {
    
    /// Request the custom view for a plugin (AppKit NSViewController)
    public static func requestView(
        for audioUnit: AVAudioUnit,
        preferredSize: CGSize = CGSize(width: 800, height: 500)
    ) async throws -> NSViewController? {
        return try await withCheckedThrowingContinuation { continuation in
            audioUnit.auAudioUnit.requestViewController { viewController in
                continuation.resume(returning: viewController as? NSViewController)
            }
        }
    }
}
#endif
