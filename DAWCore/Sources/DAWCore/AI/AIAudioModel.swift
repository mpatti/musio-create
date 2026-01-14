import Foundation

// MARK: - AI Audio Model

/// Unified enum representing all available AI audio generation models
public enum AIAudioModel: String, CaseIterable, Identifiable, Codable {
    case elevenLabsSFX = "elevenlabs_sfx"
    case elevenLabsMusic = "elevenlabs_music"
    case miniMaxMusic = "minimax_music"
    
    public var id: String { rawValue }
    
    /// Display name for the UI
    public var displayName: String {
        switch self {
        case .elevenLabsSFX:
            return "ElevenLabs Sound Effects"
        case .elevenLabsMusic:
            return "ElevenLabs Music"
        case .miniMaxMusic:
            return "MiniMax Music"
        }
    }
    
    /// Short name for compact UI
    public var shortName: String {
        switch self {
        case .elevenLabsSFX:
            return "SFX"
        case .elevenLabsMusic:
            return "Music"
        case .miniMaxMusic:
            return "MiniMax"
        }
    }
    
    /// Description of what the model is good at
    public var description: String {
        switch self {
        case .elevenLabsSFX:
            return "Short sounds, hits, textures, foley"
        case .elevenLabsMusic:
            return "Musical loops, melodies, compositions"
        case .miniMaxMusic:
            return "Full songs with vocals & instruments"
        }
    }
    
    /// SF Symbol icon name
    public var icon: String {
        switch self {
        case .elevenLabsSFX:
            return "waveform"
        case .elevenLabsMusic:
            return "music.note"
        case .miniMaxMusic:
            return "music.mic"
        }
    }
    
    /// Provider name for grouping
    public var provider: String {
        switch self {
        case .elevenLabsSFX, .elevenLabsMusic:
            return "ElevenLabs"
        case .miniMaxMusic:
            return "MiniMax"
        }
    }
    
    /// Placeholder text for the prompt field
    public var promptPlaceholder: String {
        switch self {
        case .elevenLabsSFX:
            return "e.g., punchy drums, vinyl crackle, whoosh..."
        case .elevenLabsMusic:
            return "e.g., upbeat electronic dance loop, chill lo-fi beat..."
        case .miniMaxMusic:
            return "e.g., 80s synth-pop with energetic vocals about summer..."
        }
    }
    
    /// Accent color for the model button
    public var accentColorName: String {
        switch self {
        case .elevenLabsSFX:
            return "purple"
        case .elevenLabsMusic:
            return "pink"
        case .miniMaxMusic:
            return "blue"
        }
    }
    
    /// Maximum duration supported (in seconds)
    public var maxDurationSeconds: Double {
        switch self {
        case .elevenLabsSFX:
            return 22.0  // ElevenLabs SFX limit
        case .elevenLabsMusic:
            return 330.0  // ElevenLabs Music (5.5 min)
        case .miniMaxMusic:
            return 60.0  // MiniMax generates ~60s per call
        }
    }
    
    /// Minimum duration supported (in seconds)
    public var minDurationSeconds: Double {
        switch self {
        case .elevenLabsSFX:
            return 0.5
        case .elevenLabsMusic:
            return 10.0  // ElevenLabs Music minimum
        case .miniMaxMusic:
            return 5.0
        }
    }
    
    /// Check if API key is configured for this model
    public var hasAPIKey: Bool {
        switch self {
        case .elevenLabsSFX, .elevenLabsMusic:
            return ElevenLabsAPIKeyStorage.hasAPIKey
        case .miniMaxMusic:
            return MiniMaxAPIKeyStorage.hasAPIKey
        }
    }
    
    /// Convert from legacy ElevenLabsGenerationMode
    public static func from(elevenLabsMode: ElevenLabsGenerationMode) -> AIAudioModel {
        switch elevenLabsMode {
        case .soundEffects:
            return .elevenLabsSFX
        case .music:
            return .elevenLabsMusic
        }
    }
    
    /// Convert to ElevenLabsGenerationMode if applicable
    public var elevenLabsMode: ElevenLabsGenerationMode? {
        switch self {
        case .elevenLabsSFX:
            return .soundEffects
        case .elevenLabsMusic:
            return .music
        case .miniMaxMusic:
            return nil
        }
    }
}
