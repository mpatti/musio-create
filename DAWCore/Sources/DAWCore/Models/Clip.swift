import Foundation

// MARK: - Clip Identifier

public struct ClipID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    
    public init() {
        self.rawValue = UUID()
    }
    
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

// MARK: - Clip

/// A clip represents a segment of audio or MIDI content on the timeline
public struct Clip: Identifiable, Codable, Sendable {
    public var id: ClipID
    public var name: String
    public var color: TrackColor?  // nil = inherit from track
    
    // Position on timeline
    public var timeRange: TimeRange
    
    // Content
    public var content: ClipContent
    
    // Gain/velocity adjustment
    public var gain: Float  // Linear multiplier (1.0 = unity)
    
    // Fade in/out (in samples)
    public var fadeInDuration: Int64
    public var fadeOutDuration: Int64
    public var fadeInCurve: FadeCurve
    public var fadeOutCurve: FadeCurve
    
    // Looping within clip
    public var isLooped: Bool
    public var loopLength: TimePosition?  // Length of one loop iteration
    
    // State
    public var isMuted: Bool
    public var isSelected: Bool
    
    public init(
        id: ClipID = ClipID(),
        name: String = "Clip",
        timeRange: TimeRange,
        content: ClipContent
    ) {
        self.id = id
        self.name = name
        self.color = nil
        self.timeRange = timeRange
        self.content = content
        self.gain = 1.0
        self.fadeInDuration = 0
        self.fadeOutDuration = 0
        self.fadeInCurve = .linear
        self.fadeOutCurve = .linear
        self.isLooped = false
        self.loopLength = nil
        self.isMuted = false
        self.isSelected = false
    }
}

// MARK: - Clip Content

public enum ClipContent: Codable, Sendable {
    case audio(AudioClipData)
    case midi(MIDIClipData)
    case empty  // Used for placeholder/invalid clips
    
    public var isAudio: Bool {
        if case .audio = self { return true }
        return false
    }
    
    public var isMIDI: Bool {
        if case .midi = self { return true }
        return false
    }
}

// MARK: - Audio Clip Data

public struct AudioClipData: Codable, Sendable {
    /// Reference to the audio file
    public var fileReference: AudioFileReference
    
    /// Start position within the source file (for trimming)
    public var sourceStartSample: Int64
    
    /// Length to play from source (for trimming)
    public var sourceLengthSamples: Int64
    
    /// Pitch shift in semitones
    public var pitchShift: Float
    
    /// Time stretch ratio (1.0 = original speed)
    public var timeStretch: Float
    
    /// Warp markers for time stretching
    public var warpMarkers: [WarpMarker]
    
    /// Whether to preserve pitch when time stretching
    public var preservePitch: Bool
    
    public init(
        fileReference: AudioFileReference,
        sourceStartSample: Int64 = 0,
        sourceLengthSamples: Int64 = 0
    ) {
        self.fileReference = fileReference
        self.sourceStartSample = sourceStartSample
        self.sourceLengthSamples = sourceLengthSamples
        self.pitchShift = 0
        self.timeStretch = 1.0
        self.warpMarkers = []
        self.preservePitch = true
    }
}

// MARK: - Audio File Reference

public struct AudioFileReference: Codable, Sendable, Hashable {
    public var fileID: UUID
    public var originalPath: String  // Original import path (for reference)
    public var relativePath: String  // Relative path within project
    public var sampleRate: Double
    public var channelCount: Int
    public var lengthInSamples: Int64
    public var bitDepth: Int
    
    public init(
        fileID: UUID = UUID(),
        originalPath: String,
        relativePath: String,
        sampleRate: Double,
        channelCount: Int,
        lengthInSamples: Int64,
        bitDepth: Int
    ) {
        self.fileID = fileID
        self.originalPath = originalPath
        self.relativePath = relativePath
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.lengthInSamples = lengthInSamples
        self.bitDepth = bitDepth
    }
    
    public var duration: TimeInterval {
        Double(lengthInSamples) / sampleRate
    }
}

// MARK: - Warp Marker

public struct WarpMarker: Codable, Sendable, Identifiable {
    public var id: UUID
    public var sourceSample: Int64      // Position in source audio
    public var targetPosition: Double   // Position in beats on timeline
    
    public init(id: UUID = UUID(), sourceSample: Int64, targetPosition: Double) {
        self.id = id
        self.sourceSample = sourceSample
        self.targetPosition = targetPosition
    }
}

// MARK: - MIDI Clip Data

public struct MIDIClipData: Codable, Sendable {
    /// MIDI events within this clip (times relative to clip start)
    public var events: [MIDIEvent]
    
    /// Original tempo the MIDI was recorded at (for tempo-relative playback)
    public var originalTempo: Double?
    
    public init(events: [MIDIEvent] = [], originalTempo: Double? = nil) {
        self.events = events
        self.originalTempo = originalTempo
    }
    
    /// Events sorted by time
    public var sortedEvents: [MIDIEvent] {
        events.sorted { $0.beatPosition < $1.beatPosition }
    }
    
    /// All note events
    public var noteEvents: [MIDIEvent] {
        events.filter { if case .note = $0.type { return true } else { return false } }
    }
    
    /// Get events within a beat range (relative to clip start)
    public func events(inBeatRange range: ClosedRange<Double>) -> [MIDIEvent] {
        events.filter { range.contains($0.beatPosition) }
    }
}

// MARK: - Fade Curve

public enum FadeCurve: String, Codable, Sendable, CaseIterable {
    case linear
    case logarithmic
    case exponential
    case sCurve
    
    /// Calculate fade multiplier at position t (0.0 to 1.0)
    public func value(at t: Float) -> Float {
        let clamped = max(0, min(1, t))
        switch self {
        case .linear:
            return clamped
        case .logarithmic:
            return log10(1 + 9 * clamped) // log curve
        case .exponential:
            return clamped * clamped
        case .sCurve:
            // Smooth step (3t² - 2t³)
            return clamped * clamped * (3 - 2 * clamped)
        }
    }
}
