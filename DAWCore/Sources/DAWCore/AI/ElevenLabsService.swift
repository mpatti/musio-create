import Foundation

// MARK: - ElevenLabs API Error

public enum ElevenLabsError: Error, LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case networkError(Error)
    case audioProcessingError(String)
    
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "ElevenLabs API key is not configured"
        case .invalidResponse:
            return "Invalid response from ElevenLabs API"
        case .httpError(let statusCode, let message):
            return "HTTP error \(statusCode): \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .audioProcessingError(let message):
            return "Audio processing error: \(message)"
        }
    }
}

// MARK: - Generation Mode

public enum ElevenLabsGenerationMode: String, CaseIterable, Identifiable {
    case soundEffects = "Sound Effects"
    case music = "Music"
    
    public var id: String { rawValue }
    
    public var description: String {
        switch self {
        case .soundEffects:
            return "Short sounds, hits, textures, foley"
        case .music:
            return "Musical loops, melodies, compositions"
        }
    }
    
    public var icon: String {
        switch self {
        case .soundEffects:
            return "waveform"
        case .music:
            return "music.note"
        }
    }
}

// MARK: - Request/Response Models

public struct ElevenLabsSFXRequest: Encodable {
    public let text: String
    public let duration_seconds: Double?
    public let prompt_influence: Double
    
    public init(text: String, durationSeconds: Double?, promptInfluence: Double = 0.3) {
        self.text = text
        self.duration_seconds = durationSeconds
        self.prompt_influence = promptInfluence
    }
}

public struct ElevenLabsMusicRequest: Encodable {
    public let prompt: String
    public let music_length_ms: Int
    public let model_id: String
    public let force_instrumental: Bool
    
    public init(prompt: String, durationMs: Int, forceInstrumental: Bool = true) {
        self.prompt = prompt
        self.music_length_ms = durationMs
        self.model_id = "music_v1"
        self.force_instrumental = forceInstrumental
    }
}

public struct ElevenLabsGenerationResult {
    public let audioData: Data
    public let suggestedFilename: String
    public let mode: ElevenLabsGenerationMode
    
    public init(audioData: Data, suggestedFilename: String, mode: ElevenLabsGenerationMode) {
        self.audioData = audioData
        self.suggestedFilename = suggestedFilename
        self.mode = mode
    }
}

// Legacy alias for compatibility
public typealias ElevenLabsSFXResult = ElevenLabsGenerationResult

// MARK: - API Key Storage

public final class ElevenLabsAPIKeyStorage {
    private static let apiKeyKey = "com.dawapp.elevenlabs.apikey"
    private static let defaultAPIKey = "sk_d48c0db3ff30743d18f2f5fcf681a9ab7a669840eaeeed26"
    
    public static var apiKey: String? {
        get {
            // Return stored key or default
            UserDefaults.standard.string(forKey: apiKeyKey) ?? defaultAPIKey
        }
        set {
            if let key = newValue {
                UserDefaults.standard.set(key, forKey: apiKeyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: apiKeyKey)
            }
        }
    }
    
    public static var hasAPIKey: Bool {
        guard let key = apiKey else { return false }
        return !key.isEmpty
    }
}

// MARK: - ElevenLabs Service

/// Service for generating audio using ElevenLabs Sound Effects and Music APIs
public actor ElevenLabsService {
    
    private let sfxURL = "https://api.elevenlabs.io/v1/sound-generation"
    private let musicURL = "https://api.elevenlabs.io/v1/music"
    private let subscriptionURL = "https://api.elevenlabs.io/v1/user/subscription"
    private let session: URLSession
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120  // Music generation can take longer
        config.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: config)
    }
    
    /// Fetch the user's subscription info including remaining credits
    public func getSubscriptionInfo() async throws -> ElevenLabsSubscriptionInfo {
        guard let apiKey = ElevenLabsAPIKeyStorage.apiKey, !apiKey.isEmpty else {
            throw ElevenLabsError.missingAPIKey
        }
        
        var request = URLRequest(url: URL(string: subscriptionURL)!)
        request.httpMethod = "GET"
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ElevenLabsError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ElevenLabsError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ElevenLabsError.invalidResponse
        }
        
        let tier = json["tier"] as? String ?? "unknown"
        let characterCount = json["character_count"] as? Int ?? 0
        let characterLimit = json["character_limit"] as? Int ?? 0
        let status = json["status"] as? String ?? "unknown"
        
        var nextResetDate: Date? = nil
        if let resetUnix = json["next_character_count_reset_unix"] as? TimeInterval {
            nextResetDate = Date(timeIntervalSince1970: resetUnix)
        }
        
        return ElevenLabsSubscriptionInfo(
            tier: tier,
            characterCount: characterCount,
            characterLimit: characterLimit,
            nextResetDate: nextResetDate,
            status: status
        )
    }
    
    /// Generate audio from a text prompt using the specified mode
    /// - Parameters:
    ///   - prompt: The text description of the audio to generate
    ///   - durationSeconds: Duration in seconds
    ///   - mode: Sound Effects or Music generation mode
    ///   - promptInfluence: How closely to follow the prompt (0.0-1.0) - SFX only
    /// - Returns: The generated audio data
    public func generateAudio(
        prompt: String,
        durationSeconds: Double,
        mode: ElevenLabsGenerationMode,
        promptInfluence: Double = 0.3
    ) async throws -> ElevenLabsGenerationResult {
        guard let apiKey = ElevenLabsAPIKeyStorage.apiKey, !apiKey.isEmpty else {
            throw ElevenLabsError.missingAPIKey
        }
        
        let url: String
        let requestBody: Data
        
        switch mode {
        case .soundEffects:
            url = sfxURL
            let sfxRequest = ElevenLabsSFXRequest(
                text: prompt,
                durationSeconds: durationSeconds,
                promptInfluence: promptInfluence
            )
            requestBody = try JSONEncoder().encode(sfxRequest)
            print("[ElevenLabs] Generating SFX: \"\(prompt)\" duration: \(durationSeconds)s")
            
        case .music:
            url = musicURL
            // Music API uses milliseconds and has a minimum of 10 seconds
            let durationMs = max(10000, Int(durationSeconds * 1000))
            let musicRequest = ElevenLabsMusicRequest(
                prompt: prompt,
                durationMs: durationMs,
                forceInstrumental: true  // For DAW use, instrumental is usually preferred
            )
            requestBody = try JSONEncoder().encode(musicRequest)
            print("[ElevenLabs] Generating Music: \"\(prompt)\" duration: \(durationMs)ms")
        }
        
        // Build request
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = requestBody
        
        // Log request for debugging
        print("[ElevenLabs] Request URL: \(url)")
        if let bodyString = String(data: requestBody, encoding: .utf8) {
            print("[ElevenLabs] Request body: \(bodyString)")
        }
        
        // Make the request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ElevenLabsError.networkError(error)
        }
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            print("[ElevenLabs] ERROR: Invalid response type")
            throw ElevenLabsError.invalidResponse
        }
        
        print("[ElevenLabs] Response status: \(httpResponse.statusCode)")
        print("[ElevenLabs] Response headers: \(httpResponse.allHeaderFields)")
        
        // Log response body for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            print("[ElevenLabs] Response body (first 500 chars): \(String(responseString.prefix(500)))")
        }
        
        guard httpResponse.statusCode == 200 else {
            // Try to parse error message
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            NSLog("[ElevenLabs] ERROR: HTTP %d - %@", httpResponse.statusCode, errorMessage)
            
            // Provide more helpful error messages for common cases
            if httpResponse.statusCode == 402 {
                let modeMessage = mode == .music 
                    ? "Music generation requires an ElevenLabs subscription with music credits."
                    : "Sound effect generation requires credits in your ElevenLabs account."
                throw ElevenLabsError.httpError(statusCode: httpResponse.statusCode, message: modeMessage)
            }
            
            throw ElevenLabsError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // The API returns raw audio data (MP3 format)
        guard !data.isEmpty else {
            print("[ElevenLabs] ERROR: Empty response data")
            throw ElevenLabsError.invalidResponse
        }
        
        print("[ElevenLabs] Received \(data.count) bytes of audio data")
        
        // Generate a filename based on the prompt and mode
        let prefix = mode == .music ? "music" : "sfx"
        let sanitizedPrompt = prompt
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
            .prefix(30)
        let filename = "ai_\(prefix)_\(sanitizedPrompt)_\(UUID().uuidString.prefix(8)).mp3"
        
        return ElevenLabsGenerationResult(audioData: data, suggestedFilename: String(filename), mode: mode)
    }
    
    /// Legacy method for backward compatibility
    public func generateSoundEffect(
        prompt: String,
        durationSeconds: Double?,
        promptInfluence: Double = 0.3
    ) async throws -> ElevenLabsGenerationResult {
        try await generateAudio(
            prompt: prompt,
            durationSeconds: durationSeconds ?? 5.0,
            mode: .soundEffects,
            promptInfluence: promptInfluence
        )
    }
    
    /// Build an enriched prompt with tempo and context information
    /// - Parameters:
    ///   - userPrompt: The user's original prompt
    ///   - tempo: The project tempo in BPM
    ///   - beats: Number of beats to generate
    ///   - midiContext: Optional MIDI context information
    /// - Returns: An enriched prompt string
    public static func buildEnrichedPrompt(
        userPrompt: String,
        tempo: Double,
        beats: Int,
        midiContext: MIDIContext? = nil
    ) -> String {
        var components: [String] = [userPrompt]
        
        // Add tempo
        components.append("\(Int(tempo)) BPM")
        
        // Add duration context
        let bars = beats / 4  // Assuming 4/4 time
        if bars >= 1 {
            components.append("\(bars) bar\(bars > 1 ? "s" : "")")
        } else {
            components.append("\(beats) beat\(beats > 1 ? "s" : "")")
        }
        
        // Add MIDI context if available
        if let context = midiContext {
            if let key = context.keyEstimate {
                components.append("key of \(key)")
            }
            if let rhythm = context.rhythmDescription {
                components.append(rhythm)
            }
        }
        
        // Add audio quality hints
        components.append("stereo")
        components.append("seamless loop")
        
        return components.joined(separator: ", ")
    }
}

// MARK: - Subscription Info

/// Information about the user's ElevenLabs subscription and credits
public struct ElevenLabsSubscriptionInfo: Sendable {
    public let tier: String
    public let characterCount: Int
    public let characterLimit: Int
    public let nextResetDate: Date?
    public let status: String
    
    public var remainingCharacters: Int {
        max(0, characterLimit - characterCount)
    }
    
    public var usagePercentage: Double {
        guard characterLimit > 0 else { return 0 }
        return Double(characterCount) / Double(characterLimit)
    }
    
    public var remainingPercentage: Double {
        1.0 - usagePercentage
    }
    
    /// Formatted string for remaining credits
    public var remainingCreditsText: String {
        let remaining = remainingCharacters
        if remaining >= 1000 {
            return String(format: "%.1fK", Double(remaining) / 1000.0)
        }
        return "\(remaining)"
    }
}

// MARK: - MIDI Context

/// Context extracted from MIDI data to inform audio generation
public struct MIDIContext: Sendable {
    public let keyEstimate: String?
    public let chordProgression: String?
    public let rhythmDescription: String?
    public let noteRange: String?
    
    public init(
        keyEstimate: String? = nil,
        chordProgression: String? = nil,
        rhythmDescription: String? = nil,
        noteRange: String? = nil
    ) {
        self.keyEstimate = keyEstimate
        self.chordProgression = chordProgression
        self.rhythmDescription = rhythmDescription
        self.noteRange = noteRange
    }
    
    /// Returns a descriptive string for the context, or nil if empty
    public var description: String? {
        var parts: [String] = []
        if let key = keyEstimate { parts.append("key: \(key)") }
        if let chords = chordProgression { parts.append("chords: \(chords)") }
        if let rhythm = rhythmDescription { parts.append(rhythm) }
        if let range = noteRange { parts.append(range) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
