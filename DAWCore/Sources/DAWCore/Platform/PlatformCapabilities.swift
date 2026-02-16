import Foundation

/// Centralized platform capability flags for staged cross-platform work.
/// Current behavior on macOS remains unchanged; non-macOS paths are explicit TODOs.
public enum PlatformCapabilities {
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
}
