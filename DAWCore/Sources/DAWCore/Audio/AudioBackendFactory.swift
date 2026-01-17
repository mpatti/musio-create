import Foundation

// MARK: - Audio Backend Factory

/// Factory for creating audio backends based on user preference
public enum AudioBackendFactory {
    
    // MARK: - Feature Flag
    
    /// User preference for which audio backend to use
    /// Stored in UserDefaults, defaults to false (legacy AVAudioEngine)
    public static var useCoreAudioBackend: Bool {
        get { UserDefaults.standard.bool(forKey: "useCoreAudioBackend") }
        set { UserDefaults.standard.set(newValue, forKey: "useCoreAudioBackend") }
    }
    
    // MARK: - Backend Creation
    
    /// Create the appropriate backend based on the feature flag
    /// - Returns: An AudioBackend implementation
    @MainActor
    public static func createBackend() -> AudioBackend {
        if useCoreAudioBackend {
            print("[AudioBackendFactory] Creating Core Audio backend")
            return CoreAudioBackend()
        } else {
            print("[AudioBackendFactory] Creating Legacy AVAudioEngine backend")
            return LegacyAVAudioEngineBackend()
        }
    }
    
    /// Check if Core Audio backend is available
    /// Can be used to hide the toggle on unsupported systems
    public static var isCoreAudioBackendAvailable: Bool {
        // Core Audio is available on all macOS versions we support
        return true
    }
    
    /// Get a human-readable name for the current backend
    public static var currentBackendName: String {
        useCoreAudioBackend ? "Core Audio (Professional)" : "AVAudioEngine (Legacy)"
    }
    
    /// Get a description of the current backend
    public static var currentBackendDescription: String {
        if useCoreAudioBackend {
            return "Professional-grade audio engine with sample-accurate timing, direct AudioUnit hosting, and offline bounce support."
        } else {
            return "Standard audio engine using Apple's AVAudioEngine framework. Good for general use."
        }
    }
}
