import Foundation

// MARK: - Claude API Error

public enum ClaudeError: Error, LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case networkError(Error)
    case parsingError(String)
    
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key is not configured"
        case .invalidResponse:
            return "Invalid response from Claude API"
        case .httpError(let statusCode, let message):
            return "HTTP error \(statusCode): \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parsingError(let message):
            return "Failed to parse MIDI data: \(message)"
        }
    }
}

// MARK: - API Key Storage

public final class ClaudeAPIKeyStorage {
    private static let apiKeyKey = "com.dawapp.claude.apikey"
    
    public static var apiKey: String? {
        get {
            UserDefaults.standard.string(forKey: apiKeyKey)
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

// MARK: - Generated MIDI Note

public struct GeneratedMIDINote: Codable {
    public let pitch: Int      // MIDI note number (0-127)
    public let start: Double   // Start time in beats
    public let duration: Double // Duration in beats
    public let velocity: Int   // Velocity (0-127)
    
    public init(pitch: Int, start: Double, duration: Double, velocity: Int) {
        self.pitch = pitch
        self.start = start
        self.duration = duration
        self.velocity = velocity
    }
}

// MARK: - MIDI Generation Result

public struct MIDIGenerationResult {
    public let notes: [GeneratedMIDINote]
    public let suggestedName: String
    
    public init(notes: [GeneratedMIDINote], suggestedName: String) {
        self.notes = notes
        self.suggestedName = suggestedName
    }
}

// MARK: - MIDI Generation Type

public enum MIDIGenerationType: String, CaseIterable, Identifiable {
    case melody = "melody"
    case chords = "chords"
    case drums = "drums"
    case freeform = "freeform"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .melody: return "Melody"
        case .chords: return "Chords"
        case .drums: return "Drums"
        case .freeform: return "Freeform"
        }
    }
    
    public var description: String {
        switch self {
        case .melody: return "Single note melodic lines"
        case .chords: return "Chord progressions & harmony"
        case .drums: return "Drum & percussion patterns"
        case .freeform: return "AI decides based on prompt"
        }
    }
    
    public var icon: String {
        switch self {
        case .melody: return "music.note"
        case .chords: return "pianokeys"
        case .drums: return "drum.fill"
        case .freeform: return "wand.and.stars"
        }
    }
}

// MARK: - Musical Key

public enum MusicalKey: String, CaseIterable, Identifiable {
    case cMajor = "C Major"
    case cMinor = "C Minor"
    case dMajor = "D Major"
    case dMinor = "D Minor"
    case eMajor = "E Major"
    case eMinor = "E Minor"
    case fMajor = "F Major"
    case fMinor = "F Minor"
    case gMajor = "G Major"
    case gMinor = "G Minor"
    case aMajor = "A Major"
    case aMinor = "A Minor"
    case bMajor = "B Major"
    case bMinor = "B Minor"
    
    public var id: String { rawValue }
    public var displayName: String { rawValue }
}

// MARK: - Claude Service

public actor ClaudeService {
    
    private let apiURL = "https://api.anthropic.com/v1/messages"
    private let session: URLSession
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }
    
    /// Edit existing MIDI notes based on a prompt
    public func editMIDI(
        prompt: String,
        currentNotes: [GeneratedMIDINote],
        beatCount: Int,
        tempo: Double,
        timeSignature: (Int, Int),
        otherTrackNotes: [(trackName: String, notes: [GeneratedMIDINote])]
    ) async throws -> MIDIGenerationResult {
        guard let apiKey = ClaudeAPIKeyStorage.apiKey, !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }
        
        print("[Claude] Editing MIDI: \"\(prompt)\"")
        print("[Claude] Current notes: \(currentNotes.count), Tempo: \(tempo) BPM")
        
        // Build the system prompt for editing
        let systemPrompt = buildEditSystemPrompt(
            currentNotes: currentNotes,
            beatCount: beatCount,
            tempo: tempo,
            timeSignature: timeSignature,
            otherTrackNotes: otherTrackNotes
        )
        
        // Build request body
        let requestBody: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Build request
        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        print("[Claude] Sending edit request...")
        
        // Make the request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeError.networkError(error)
        }
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }
        
        print("[Claude] Response status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[Claude] ERROR: \(errorMessage)")
            throw ClaudeError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            print("[Claude] ERROR: Could not parse response")
            throw ClaudeError.invalidResponse
        }
        
        print("[Claude] Response text: \(text.prefix(500))...")
        
        // Extract JSON from response
        let notes = try parseNotesFromResponse(text)
        
        print("[Claude] Parsed \(notes.count) edited notes")
        
        let suggestedName = "Edited: \(prompt.prefix(15))"
        
        return MIDIGenerationResult(notes: notes, suggestedName: suggestedName)
    }
    
    /// Generate MIDI notes with full context from other tracks
    public func generateMIDIWithContext(
        prompt: String,
        beatCount: Int,
        tempo: Double,
        timeSignature: (Int, Int),
        otherTrackNotes: [(trackName: String, notes: [GeneratedMIDINote])]
    ) async throws -> MIDIGenerationResult {
        guard let apiKey = ClaudeAPIKeyStorage.apiKey, !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }
        
        print("[Claude] Generating MIDI: \"\(prompt)\"")
        print("[Claude] Beats: \(beatCount), Tempo: \(tempo) BPM")
        print("[Claude] Context from \(otherTrackNotes.count) other tracks")
        
        // Build the system prompt with actual note data
        let systemPrompt = buildContextAwareSystemPrompt(
            beatCount: beatCount,
            tempo: tempo,
            timeSignature: timeSignature,
            otherTrackNotes: otherTrackNotes
        )
        
        // Build request body
        let requestBody: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Build request
        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        print("[Claude] Sending request...")
        
        // Make the request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeError.networkError(error)
        }
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }
        
        print("[Claude] Response status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[Claude] ERROR: \(errorMessage)")
            throw ClaudeError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            print("[Claude] ERROR: Could not parse response")
            throw ClaudeError.invalidResponse
        }
        
        print("[Claude] Response text: \(text.prefix(500))...")
        
        // Extract JSON from response
        let notes = try parseNotesFromResponse(text)
        
        print("[Claude] Parsed \(notes.count) notes")
        
        // Generate suggested name
        let suggestedName = prompt.prefix(20).description
        
        return MIDIGenerationResult(notes: notes, suggestedName: suggestedName)
    }
    
    /// Generate MIDI notes from a text prompt (legacy method)
    public func generateMIDI(
        prompt: String,
        type: MIDIGenerationType,
        bars: Int,
        tempo: Double,
        key: MusicalKey,
        timeSignature: (Int, Int) = (4, 4),
        existingContext: MIDIContext? = nil
    ) async throws -> MIDIGenerationResult {
        guard let apiKey = ClaudeAPIKeyStorage.apiKey, !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }
        
        let beatsPerBar = timeSignature.0
        let totalBeats = bars * beatsPerBar
        
        print("[Claude] Generating \(type.displayName) MIDI: \"\(prompt)\"")
        print("[Claude] Bars: \(bars), Tempo: \(tempo) BPM, Key: \(key.displayName)")
        if let ctx = existingContext?.description {
            print("[Claude] Existing context: \(ctx)")
        }
        
        // Build the system prompt
        let systemPrompt = buildSystemPrompt(type: type, bars: bars, totalBeats: totalBeats, tempo: tempo, key: key, timeSignature: timeSignature, existingContext: existingContext)
        
        // Build request body
        let requestBody: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Build request
        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        print("[Claude] Sending request...")
        
        // Make the request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeError.networkError(error)
        }
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }
        
        print("[Claude] Response status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[Claude] ERROR: \(errorMessage)")
            throw ClaudeError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            print("[Claude] ERROR: Could not parse response")
            throw ClaudeError.invalidResponse
        }
        
        print("[Claude] Response text: \(text.prefix(500))...")
        
        // Extract JSON from response
        let notes = try parseNotesFromResponse(text)
        
        print("[Claude] Parsed \(notes.count) notes")
        
        // Generate suggested name
        let suggestedName = "\(type.displayName) - \(prompt.prefix(20))"
        
        return MIDIGenerationResult(notes: notes, suggestedName: suggestedName)
    }
    
    private func buildSystemPrompt(
        type: MIDIGenerationType,
        bars: Int,
        totalBeats: Int,
        tempo: Double,
        key: MusicalKey,
        timeSignature: (Int, Int),
        existingContext: MIDIContext? = nil
    ) -> String {
        let typeInstructions: String
        switch type {
        case .melody:
            typeInstructions = """
            Generate a melodic line with single notes. Use notes that fit the key signature.
            Typical range: MIDI notes 60-84 (C4 to C6).
            Vary rhythm with a mix of quarter notes (1.0 beats), eighth notes (0.5 beats), and occasional longer notes.
            """
        case .chords:
            typeInstructions = """
            Generate chord progressions. Each chord should have 3-4 notes played simultaneously (same start time).
            Use common chord progressions that fit the key.
            Typical range: MIDI notes 48-72 (C3 to C5).
            Chords typically last 2-4 beats each.
            """
        case .drums:
            typeInstructions = """
            Generate a drum pattern using General MIDI drum mapping:
            - Kick drum: 36
            - Snare: 38
            - Closed hi-hat: 42
            - Open hi-hat: 46
            - Crash cymbal: 49
            - Ride cymbal: 51
            - Low tom: 45
            - Mid tom: 47
            - High tom: 50
            Create a rhythmic pattern with kick on beats 1 and 3, snare on 2 and 4, and hi-hats for rhythm.
            """
        case .freeform:
            typeInstructions = """
            Generate MIDI notes based on the user's description. You decide whether to create melody, chords, drums, or a combination.
            Be creative but musically coherent.
            """
        }
        
        // Build context section if we have existing MIDI
        var contextSection = ""
        if let context = existingContext {
            var contextParts: [String] = []
            
            if let detectedKey = context.keyEstimate {
                contextParts.append("- Detected key from existing MIDI: \(detectedKey)")
            }
            if let rhythm = context.rhythmDescription {
                contextParts.append("- Existing rhythm feel: \(rhythm)")
            }
            if let range = context.noteRange {
                contextParts.append("- Existing note range: \(range)")
            }
            if let chords = context.chordProgression {
                contextParts.append("- Chord progression: \(chords)")
            }
            
            if !contextParts.isEmpty {
                contextSection = """
                
                EXISTING MUSICAL CONTEXT (match this style):
                \(contextParts.joined(separator: "\n"))
                
                IMPORTANT: Your generated MIDI should complement and harmonize with the existing content.
                - If there's an existing key, use notes from that key (or the user-selected key if different)
                - Match the rhythmic density and feel
                - Choose a complementary register (different range to avoid clashing)
                - Create musical interest through counterpoint or harmonic support
                
                """
            }
        }
        
        return """
        You are a MIDI composition assistant. Generate MIDI note data based on the user's request.
        
        Musical Context:
        - Key: \(key.displayName)
        - Tempo: \(tempo) BPM
        - Time Signature: \(timeSignature.0)/\(timeSignature.1)
        - Duration: \(bars) bars (\(totalBeats) beats total)
        - Beat range: 0.0 to \(totalBeats).0
        \(contextSection)
        \(typeInstructions)
        
        IMPORTANT: You MUST respond with ONLY a valid JSON object in this exact format, no other text:
        {
          "notes": [
            {"pitch": 60, "start": 0.0, "duration": 1.0, "velocity": 100},
            {"pitch": 64, "start": 1.0, "duration": 0.5, "velocity": 90}
          ]
        }
        
        Rules:
        - pitch: MIDI note number 0-127 (60 = C4, 62 = D4, 64 = E4, etc.)
        - start: Beat position (0.0 = start, must be less than \(totalBeats))
        - duration: Length in beats (0.25 = sixteenth, 0.5 = eighth, 1.0 = quarter, 2.0 = half)
        - velocity: Note velocity 1-127 (typical: 80-110)
        
        Generate musically interesting content that matches the user's description.
        Respond with ONLY the JSON, no explanation or markdown.
        """
    }
    
    private func buildContextAwareSystemPrompt(
        beatCount: Int,
        tempo: Double,
        timeSignature: (Int, Int),
        otherTrackNotes: [(trackName: String, notes: [GeneratedMIDINote])]
    ) -> String {
        // Build the existing notes section
        var existingNotesSection = ""
        
        if !otherTrackNotes.isEmpty {
            var trackDescriptions: [String] = []
            
            for (trackName, notes) in otherTrackNotes {
                // Convert notes to a readable format
                let noteDescriptions = notes.prefix(50).map { note -> String in
                    let noteName = noteNameFromPitch(note.pitch)
                    return "  - \(noteName) at beat \(String(format: "%.2f", note.start)), duration \(String(format: "%.2f", note.duration))"
                }
                
                let noteList = noteDescriptions.joined(separator: "\n")
                let moreNote = notes.count > 50 ? "\n  ... and \(notes.count - 50) more notes" : ""
                
                trackDescriptions.append("""
                \(trackName):
                \(noteList)\(moreNote)
                """)
            }
            
            existingNotesSection = """
            
            EXISTING MIDI ON OTHER TRACKS (you MUST compose to complement this):
            \(trackDescriptions.joined(separator: "\n\n"))
            
            CRITICAL COMPOSITION RULES:
            1. Analyze the existing notes to determine the key/scale being used
            2. Your new notes MUST be in the same key and harmonize with the existing content
            3. Choose a complementary register - if existing content is in mid range, consider bass or high range
            4. Match the rhythmic feel - if existing content is sparse, don't be too busy; if it's dense, match the energy
            5. Create musical interest through counterpoint, harmony, or rhythmic interplay
            6. Avoid playing the exact same notes at the same time (unless doubling for effect)
            
            """
        } else {
            existingNotesSection = """
            
            This is the first MIDI track - you have creative freedom to establish the musical foundation.
            
            """
        }
        
        return """
        You are a professional MIDI composer. Generate MIDI note data that works musically with existing content.
        
        Musical Context:
        - Tempo: \(tempo) BPM
        - Time Signature: \(timeSignature.0)/\(timeSignature.1)
        - Duration: \(beatCount) beats (beat 0.0 to \(beatCount).0)
        \(existingNotesSection)
        IMPORTANT: You MUST respond with ONLY a valid JSON object in this exact format, no other text:
        {
          "notes": [
            {"pitch": 60, "start": 0.0, "duration": 1.0, "velocity": 100},
            {"pitch": 64, "start": 1.0, "duration": 0.5, "velocity": 90}
          ]
        }
        
        Rules:
        - pitch: MIDI note number 0-127 (60 = C4/Middle C, 62 = D4, 64 = E4, etc.)
        - start: Beat position from 0.0 to \(beatCount - 1).99
        - duration: Length in beats (0.25 = 16th, 0.5 = 8th, 1.0 = quarter, 2.0 = half)
        - velocity: 1-127 (typical: 80-110)
        
        For drums, use General MIDI mapping: Kick=36, Snare=38, Hi-hat=42, etc.
        
        Respond with ONLY the JSON, no explanation or markdown.
        """
    }
    
    private func noteNameFromPitch(_ pitch: Int) -> String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (pitch / 12) - 1
        let noteName = noteNames[pitch % 12]
        return "\(noteName)\(octave)"
    }
    
    private func buildEditSystemPrompt(
        currentNotes: [GeneratedMIDINote],
        beatCount: Int,
        tempo: Double,
        timeSignature: (Int, Int),
        otherTrackNotes: [(trackName: String, notes: [GeneratedMIDINote])]
    ) -> String {
        // Format current notes
        let currentNoteDescriptions = currentNotes.map { note -> String in
            let noteName = noteNameFromPitch(note.pitch)
            return "  {\"pitch\": \(note.pitch), \"start\": \(String(format: "%.2f", note.start)), \"duration\": \(String(format: "%.2f", note.duration)), \"velocity\": \(note.velocity)}  // \(noteName)"
        }
        
        let currentNotesJSON = "[\n\(currentNoteDescriptions.joined(separator: ",\n"))\n  ]"
        
        // Format other track notes
        var otherTracksSection = ""
        if !otherTrackNotes.isEmpty {
            var trackDescriptions: [String] = []
            for (trackName, notes) in otherTrackNotes {
                let noteDescriptions = notes.prefix(30).map { note -> String in
                    let noteName = noteNameFromPitch(note.pitch)
                    return "    \(noteName) at beat \(String(format: "%.2f", note.start))"
                }
                trackDescriptions.append("\(trackName):\n\(noteDescriptions.joined(separator: "\n"))")
            }
            otherTracksSection = """
            
            OTHER TRACKS (for harmonic context):
            \(trackDescriptions.joined(separator: "\n\n"))
            
            """
        }
        
        return """
        You are a MIDI editor. Modify the existing MIDI notes based on the user's instructions.
        
        Musical Context:
        - Tempo: \(tempo) BPM
        - Time Signature: \(timeSignature.0)/\(timeSignature.1)
        - Duration: \(beatCount) beats (beat 0.0 to \(beatCount).0)
        
        CURRENT NOTES TO EDIT:
        \(currentNotesJSON)
        \(otherTracksSection)
        EDITING INSTRUCTIONS:
        Based on the user's request, modify the notes above. Common operations:
        - "transpose up/down" - add/subtract from pitch values
        - "make faster/slower" - multiply/divide durations
        - "add variations" - introduce slight pitch/timing changes
        - "make louder/softer" - adjust velocities
        - "arpeggiate" - spread chord notes across time
        - "simplify" - remove some notes
        - "double" - add octave copies
        - "humanize" - add slight random timing/velocity variations
        
        IMPORTANT: You MUST respond with ONLY a valid JSON object containing the MODIFIED notes:
        {
          "notes": [
            {"pitch": 60, "start": 0.0, "duration": 1.0, "velocity": 100},
            ...
          ]
        }
        
        Rules:
        - pitch: MIDI note number 0-127
        - start: Beat position from 0.0 to \(beatCount - 1).99
        - duration: Length in beats
        - velocity: 1-127
        
        Respond with ONLY the JSON, no explanation.
        """
    }

    private func parseNotesFromResponse(_ text: String) throws -> [GeneratedMIDINote] {
        // Try to find JSON in the response
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code blocks if present
        if jsonString.hasPrefix("```json") {
            jsonString = String(jsonString.dropFirst(7))
        } else if jsonString.hasPrefix("```") {
            jsonString = String(jsonString.dropFirst(3))
        }
        if jsonString.hasSuffix("```") {
            jsonString = String(jsonString.dropLast(3))
        }
        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Try to find JSON object boundaries
        if let startIndex = jsonString.firstIndex(of: "{"),
           let endIndex = jsonString.lastIndex(of: "}") {
            jsonString = String(jsonString[startIndex...endIndex])
        }
        
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw ClaudeError.parsingError("Could not convert response to data")
        }
        
        // Parse JSON
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let notesArray = json["notes"] as? [[String: Any]] else {
            throw ClaudeError.parsingError("Invalid JSON structure")
        }
        
        // Convert to GeneratedMIDINote objects
        var notes: [GeneratedMIDINote] = []
        for noteDict in notesArray {
            guard let pitch = noteDict["pitch"] as? Int ?? (noteDict["pitch"] as? Double).map({ Int($0) }),
                  let start = noteDict["start"] as? Double ?? (noteDict["start"] as? Int).map({ Double($0) }),
                  let duration = noteDict["duration"] as? Double ?? (noteDict["duration"] as? Int).map({ Double($0) }),
                  let velocity = noteDict["velocity"] as? Int ?? (noteDict["velocity"] as? Double).map({ Int($0) }) else {
                continue
            }
            
            // Validate ranges
            let validPitch = max(0, min(127, pitch))
            let validVelocity = max(1, min(127, velocity))
            let validDuration = max(0.0625, duration) // Minimum 64th note
            let validStart = max(0, start)
            
            notes.append(GeneratedMIDINote(
                pitch: validPitch,
                start: validStart,
                duration: validDuration,
                velocity: validVelocity
            ))
        }
        
        if notes.isEmpty {
            throw ClaudeError.parsingError("No valid notes found in response")
        }
        
        return notes
    }
}
