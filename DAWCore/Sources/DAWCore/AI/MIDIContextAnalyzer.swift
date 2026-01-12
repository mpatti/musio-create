import Foundation

// MARK: - MIDI Context Analyzer

/// Analyzes MIDI data to extract musical context for AI audio generation
public struct MIDIContextAnalyzer {
    
    // MARK: - Note Names
    
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    
    // MARK: - Key Profiles (Krumhansl-Schmuckler)
    
    /// Major key profile weights
    private static let majorProfile: [Double] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88
    ]
    
    /// Minor key profile weights
    private static let minorProfile: [Double] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17
    ]
    
    // MARK: - Public Methods
    
    /// Analyze MIDI events and extract musical context
    /// - Parameters:
    ///   - events: Array of MIDI events to analyze
    ///   - beatRange: Optional beat range to limit analysis
    /// - Returns: Extracted MIDI context
    public static func analyze(events: [MIDIEvent], inBeatRange beatRange: ClosedRange<Double>? = nil) -> MIDIContext {
        // Filter events to beat range if specified
        let filteredEvents: [MIDIEvent]
        if let range = beatRange {
            filteredEvents = events.filter { range.contains($0.beatPosition) }
        } else {
            filteredEvents = events
        }
        
        // Extract note events only
        let noteEvents = filteredEvents.compactMap { event -> (pitch: UInt8, velocity: UInt8, duration: Double)? in
            if case .note(let noteData) = event.type {
                return (noteData.pitch, noteData.velocity, noteData.duration)
            }
            return nil
        }
        
        guard !noteEvents.isEmpty else {
            return MIDIContext()
        }
        
        // Analyze key
        let keyEstimate = estimateKey(from: noteEvents)
        
        // Analyze rhythm
        let rhythmDescription = analyzeRhythm(events: filteredEvents, noteCount: noteEvents.count)
        
        // Analyze note range
        let noteRange = analyzeNoteRange(notes: noteEvents)
        
        // Chord analysis is complex, skip for now (would need beat-aligned analysis)
        
        return MIDIContext(
            keyEstimate: keyEstimate,
            chordProgression: nil,
            rhythmDescription: rhythmDescription,
            noteRange: noteRange
        )
    }
    
    // MARK: - Key Estimation
    
    /// Estimate the key of the MIDI notes using Krumhansl-Schmuckler algorithm
    private static func estimateKey(from notes: [(pitch: UInt8, velocity: UInt8, duration: Double)]) -> String? {
        guard !notes.isEmpty else { return nil }
        
        // Build pitch class histogram (weighted by duration and velocity)
        var histogram = [Double](repeating: 0, count: 12)
        for note in notes {
            let pitchClass = Int(note.pitch) % 12
            let weight = Double(note.velocity) / 127.0 * max(note.duration, 0.1)
            histogram[pitchClass] += weight
        }
        
        // Normalize histogram
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }
        histogram = histogram.map { $0 / total }
        
        // Find best matching key
        var bestKey = ""
        var bestCorrelation = -Double.infinity
        
        for root in 0..<12 {
            // Check major key
            let majorCorr = correlate(histogram: histogram, profile: majorProfile, rotation: root)
            if majorCorr > bestCorrelation {
                bestCorrelation = majorCorr
                bestKey = "\(noteNames[root]) major"
            }
            
            // Check minor key
            let minorCorr = correlate(histogram: histogram, profile: minorProfile, rotation: root)
            if minorCorr > bestCorrelation {
                bestCorrelation = minorCorr
                bestKey = "\(noteNames[root]) minor"
            }
        }
        
        // Only return if correlation is reasonably strong
        return bestCorrelation > 0.5 ? bestKey : nil
    }
    
    /// Calculate correlation between histogram and rotated profile
    private static func correlate(histogram: [Double], profile: [Double], rotation: Int) -> Double {
        var sum = 0.0
        var histMean = 0.0
        var profMean = 0.0
        
        for i in 0..<12 {
            histMean += histogram[i]
            profMean += profile[i]
        }
        histMean /= 12.0
        profMean /= 12.0
        
        var numerator = 0.0
        var histVar = 0.0
        var profVar = 0.0
        
        for i in 0..<12 {
            let rotatedIndex = (i + rotation) % 12
            let histDiff = histogram[rotatedIndex] - histMean
            let profDiff = profile[i] - profMean
            
            numerator += histDiff * profDiff
            histVar += histDiff * histDiff
            profVar += profDiff * profDiff
        }
        
        let denominator = sqrt(histVar * profVar)
        return denominator > 0 ? numerator / denominator : 0
    }
    
    // MARK: - Rhythm Analysis
    
    /// Analyze the rhythmic density of the MIDI events
    private static func analyzeRhythm(events: [MIDIEvent], noteCount: Int) -> String? {
        guard noteCount > 0 else { return nil }
        
        // Get beat range
        let beats = events.map { $0.beatPosition }
        guard let minBeat = beats.min(), let maxBeat = beats.max() else { return nil }
        
        let duration = maxBeat - minBeat
        guard duration > 0 else { return nil }
        
        // Calculate notes per beat
        let notesPerBeat = Double(noteCount) / duration
        
        if notesPerBeat > 4 {
            return "driving 16th notes"
        } else if notesPerBeat > 2 {
            return "active 8th note rhythm"
        } else if notesPerBeat > 1 {
            return "steady quarter note pulse"
        } else if notesPerBeat > 0.5 {
            return "sparse half note rhythm"
        } else {
            return "very sparse, sustained"
        }
    }
    
    // MARK: - Note Range Analysis
    
    /// Analyze the pitch range of the notes
    private static func analyzeNoteRange(notes: [(pitch: UInt8, velocity: UInt8, duration: Double)]) -> String? {
        guard !notes.isEmpty else { return nil }
        
        let pitches = notes.map { $0.pitch }
        guard let minPitch = pitches.min(), let maxPitch = pitches.max() else { return nil }
        
        let avgPitch = Double(pitches.reduce(0, { $0 + Int($1) })) / Double(pitches.count)
        
        // Categorize by average pitch
        if avgPitch < 48 {
            return "bass range"
        } else if avgPitch < 60 {
            return "low-mid range"
        } else if avgPitch < 72 {
            return "mid range"
        } else if avgPitch < 84 {
            return "high-mid range"
        } else {
            return "high range"
        }
    }
    
    // MARK: - Helper: Analyze Project Context
    
    /// Analyze all MIDI tracks in a project within a beat range
    public static func analyzeProject(_ project: Project, beatRange: ClosedRange<Double>) -> MIDIContext {
        var allEvents: [MIDIEvent] = []
        
        for track in project.tracks {
            guard track.type == .midi || track.type == .instrument else { continue }
            
            for clip in track.clips {
                guard case .midi(let midiData) = clip.content else { continue }
                
                // Convert clip-relative positions to absolute
                let clipStartBeat = clip.timeRange.start.beats(atTempo: 120) // Use default tempo for position
                
                for event in midiData.events {
                    let absoluteBeat = clipStartBeat + event.beatPosition
                    if beatRange.contains(absoluteBeat) {
                        // Create event with absolute position
                        var absoluteEvent = event
                        absoluteEvent.beatPosition = absoluteBeat
                        allEvents.append(absoluteEvent)
                    }
                }
            }
        }
        
        return analyze(events: allEvents, inBeatRange: beatRange)
    }
}
