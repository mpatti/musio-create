import Foundation

/// Centralized platform capability flags for staged cross-platform work.
/// Current behavior on macOS remains unchanged; non-macOS paths are explicit scaffolding.
public enum PlatformCapabilities {
    public enum PluginFormat: String, CaseIterable, Sendable {
        case audioUnit = "AudioUnit"
        case vst3 = "VST3"
    }

    public enum AudioBackend: String, Sendable {
        case coreAudio = "CoreAudio"
        case wasapi = "WASAPI"
        case unavailable = "Unavailable"
    }

    public static var supportsAudioUnitHosting: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    public static var supportsAppKitPluginWindows: Bool {
        #if canImport(AppKit)
        true
        #else
        false
        #endif
    }

    public static var supportsCoreAudioBackend: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Whether this runtime should prefer VST3 as the primary plugin format.
    /// On Windows this is expected to be the baseline format for parity work.
    public static var prefersVST3PluginHosting: Bool {
        #if os(Windows)
        true
        #else
        false
        #endif
    }

    /// Ordered by runtime preference.
    public static var supportedPluginFormats: [PluginFormat] {
        #if os(macOS)
        [.audioUnit]
        #elseif os(Windows)
        [.vst3]
        #else
        []
        #endif
    }

    public static var preferredPluginFormat: PluginFormat? {
        supportedPluginFormats.first
    }

    public static var defaultAudioBackend: AudioBackend {
        #if os(macOS)
        .coreAudio
        #elseif os(Windows)
        .wasapi
        #else
        .unavailable
        #endif
    }

    /// Human-readable summary for diagnostics/logging.
    public static var runtimeSummary: String {
        let formats = supportedPluginFormats.map(\.rawValue).joined(separator: ", ")
        let pluginFormats = formats.isEmpty ? "none" : formats
        return "audioBackend=\(defaultAudioBackend.rawValue), pluginFormats=\(pluginFormats), appKitPluginWindows=\(supportsAppKitPluginWindows)"
    }
}
