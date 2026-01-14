import Foundation

// MARK: - MiniMax API Error

public enum MiniMaxError: Error, LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case networkError(Error)
    case audioDecodingError(String)
    
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "MiniMax API key is not configured"
        case .invalidResponse:
            return "Invalid response from MiniMax API"
        case .httpError(let statusCode, let message):
            return "HTTP error \(statusCode): \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .audioDecodingError(let message):
            return "Audio decoding error: \(message)"
        }
    }
}

// MARK: - API Key Storage

public final class MiniMaxAPIKeyStorage {
    private static let apiKeyKey = "com.dawapp.minimax.apikey"
    private static let defaultAPIKey = "sk-api-2-PLohL42RZu1wMBqKF_okt7zcpZzx30xjUVG5RQkgCTc73SFRzFIHi5vkEN32pM9cnh_dJ0LSCEyTUsE52kVtR4v5KM9G_BNqxV6DEF8XcFhTkmIzdnYXY"
    
    public static var apiKey: String? {
        get {
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

// MARK: - Generation Result

public struct MiniMaxResult {
    public let audioData: Data
    public let suggestedFilename: String
    
    public init(audioData: Data, suggestedFilename: String) {
        self.audioData = audioData
        self.suggestedFilename = suggestedFilename
    }
}

// MARK: - MiniMax Service

/// Service for generating music using MiniMax's Music API
public actor MiniMaxService {
    
    private let apiURL = "https://api.minimax.io/v1/music_generation"
    private let session: URLSession
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }
    
    /// Generate music from a text prompt
    /// - Parameters:
    ///   - prompt: The text description of the desired music
    ///   - durationSeconds: Approximate duration (MiniMax generates up to ~60s per call)
    /// - Returns: The generated audio data
    public func generateMusic(
        prompt: String,
        durationSeconds: Double
    ) async throws -> MiniMaxResult {
        guard let apiKey = MiniMaxAPIKeyStorage.apiKey, !apiKey.isEmpty else {
            throw MiniMaxError.missingAPIKey
        }
        
        print("[MiniMax] Generating music: \"\(prompt)\"")
        
        // MiniMax requires both prompt (style description) and lyrics
        // If the prompt contains lyrics-like content, use it; otherwise create instrumental
        let (stylePrompt, lyrics) = parsePromptAndLyrics(prompt)
        
        print("[MiniMax] Style: \(stylePrompt)")
        print("[MiniMax] Lyrics: \(lyrics)")
        
        // Build request body per official API docs
        let requestBody: [String: Any] = [
            "model": "music-2.0",
            "prompt": stylePrompt,
            "lyrics": lyrics,
            "output_format": "hex",
            "audio_setting": [
                "sample_rate": 44100,
                "bitrate": 256000,
                "format": "mp3"
            ]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Build request
        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        print("[MiniMax] Request URL: \(apiURL)")
        print("[MiniMax] Request body: \(String(data: jsonData, encoding: .utf8) ?? "")")
        
        // Make the request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MiniMaxError.networkError(error)
        }
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            print("[MiniMax] ERROR: Invalid response type")
            throw MiniMaxError.invalidResponse
        }
        
        print("[MiniMax] Response status: \(httpResponse.statusCode)")
        
        // Parse response (MiniMax returns 200 even for errors, check base_resp)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[MiniMax] ERROR: Could not parse JSON response")
            print("[MiniMax] Raw response: \(String(data: data, encoding: .utf8) ?? "non-utf8")")
            
            if httpResponse.statusCode != 200 {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw MiniMaxError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            throw MiniMaxError.invalidResponse
        }
        
        print("[MiniMax] Response: \(json)")
        
        // Check for API-level errors in base_resp
        if let baseResp = json["base_resp"] as? [String: Any],
           let statusCode = baseResp["status_code"] as? Int,
           statusCode != 0 {
            let statusMsg = baseResp["status_msg"] as? String ?? "Unknown error"
            print("[MiniMax] API Error: \(statusCode) - \(statusMsg)")
            
            switch statusCode {
            case 1002:
                throw MiniMaxError.httpError(statusCode: statusCode, message: "Invalid API key. Please check your MiniMax API key.")
            case 1008:
                throw MiniMaxError.httpError(statusCode: statusCode, message: "Insufficient balance. Please add credits to your MiniMax account at platform.minimax.io")
            case 1009:
                throw MiniMaxError.httpError(statusCode: statusCode, message: "Rate limit exceeded. Please try again later.")
            default:
                throw MiniMaxError.httpError(statusCode: statusCode, message: statusMsg)
            }
        }
        
        // Extract audio data - MiniMax returns hex-encoded audio in data.audio
        if let dataObj = json["data"] as? [String: Any],
           let audioHex = dataObj["audio"] as? String {
            
            // Convert hex string to Data
            guard let audioData = Data(hexString: audioHex) else {
                throw MiniMaxError.audioDecodingError("Failed to decode hex audio data")
            }
            
            print("[MiniMax] Decoded \(audioData.count) bytes of audio")
            
            let sanitizedPrompt = prompt
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined(separator: "_")
                .prefix(30)
            let filename = "minimax_\(sanitizedPrompt)_\(UUID().uuidString.prefix(8)).mp3"
            
            return MiniMaxResult(audioData: audioData, suggestedFilename: String(filename))
        }
        
        // Try alternative response formats
        if let audioURL = json["audio_url"] as? String ?? json["url"] as? String {
            print("[MiniMax] Downloading audio from URL: \(audioURL)")
            
            guard let url = URL(string: audioURL) else {
                throw MiniMaxError.invalidResponse
            }
            
            let (audioData, _) = try await session.data(from: url)
            
            let sanitizedPrompt = prompt
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined(separator: "_")
                .prefix(30)
            let filename = "minimax_\(sanitizedPrompt)_\(UUID().uuidString.prefix(8)).mp3"
            
            return MiniMaxResult(audioData: audioData, suggestedFilename: String(filename))
        }
        
        print("[MiniMax] ERROR: Could not find audio in response")
        print("[MiniMax] Full response: \(json)")
        throw MiniMaxError.invalidResponse
    }
    
    /// Parse the user prompt to extract style description and lyrics
    /// MiniMax requires both - if no lyrics provided, generate instrumental sections
    private func parsePromptAndLyrics(_ input: String) -> (style: String, lyrics: String) {
        // Check if the input contains lyrics markers like [verse], [chorus], etc.
        let lyricsMarkers = ["[verse]", "[chorus]", "[intro]", "[bridge]", "[outro]", "[hook]", "[inst]", "[solo]"]
        let lowercased = input.lowercased()
        
        let hasLyricsMarkers = lyricsMarkers.contains { lowercased.contains($0) }
        
        if hasLyricsMarkers {
            // Input already contains structured lyrics - try to separate style from lyrics
            // Look for the first marker to split
            var splitIndex = input.count
            for marker in lyricsMarkers {
                if let range = lowercased.range(of: marker) {
                    let index = input.distance(from: input.startIndex, to: range.lowerBound)
                    splitIndex = min(splitIndex, index)
                }
            }
            
            if splitIndex > 0 && splitIndex < input.count {
                let style = String(input.prefix(splitIndex)).trimmingCharacters(in: .whitespacesAndNewlines)
                let lyrics = String(input.suffix(from: input.index(input.startIndex, offsetBy: splitIndex)))
                
                // Ensure style meets minimum length (10 chars)
                let finalStyle = style.count >= 10 ? style : "Modern music, \(style)"
                return (finalStyle, lyrics)
            } else {
                // All lyrics, use generic style
                return ("Modern pop music, catchy melody, professional production", input)
            }
        }
        
        // No lyrics markers - treat entire input as style description
        // Generate instrumental-style lyrics
        let instrumentalLyrics = """
        [Intro]
        (instrumental)
        [Verse]
        (melodic instrumental passage)
        [Chorus]
        (main instrumental theme)
        [Bridge]
        (instrumental bridge)
        [Outro]
        (fade out)
        """
        
        // Ensure style meets minimum length
        let finalStyle = input.count >= 10 ? input : "Music style: \(input), professional production quality"
        
        return (finalStyle, instrumentalLyrics)
    }
}

// MARK: - Data Hex Extension

extension Data {
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0 else { return nil }
        
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
}
