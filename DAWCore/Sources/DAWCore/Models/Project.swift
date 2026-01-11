import Foundation

// MARK: - Project

/// The root model representing an entire DAW project
public struct Project: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    
    // Tempo and time signature
    public var tempo: Tempo
    public var timeSignature: TimeSignature
    public var tempoChanges: [TempoChange]
    public var timeSignatureChanges: [TimeSignatureChange]
    
    // Sample rate
    public var sampleRate: Double
    
    // Tracks
    public var tracks: [Track]
    public var masterTrack: Track
    
    // Markers
    public var markers: [Marker]
    
    // Loop region
    public var loopRegion: TimeRange?
    public var isLoopEnabled: Bool
    
    // Audio files referenced by this project
    public var audioFiles: [AudioFileReference]
    
    // Project metadata
    public var metadata: ProjectMetadata
    
    // Version for migration
    public var formatVersion: Int
    
    public static let currentFormatVersion = 1
    
    public init(
        id: UUID = UUID(),
        name: String = "Untitled Project",
        sampleRate: Double = 44100
    ) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.tempo = Tempo(bpm: 120)
        self.timeSignature = .common
        self.tempoChanges = []
        self.timeSignatureChanges = []
        self.sampleRate = sampleRate
        self.tracks = []
        self.masterTrack = Track(
            name: "Master",
            type: .master,
            color: .gray
        )
        self.markers = []
        self.loopRegion = nil
        self.isLoopEnabled = false
        self.audioFiles = []
        self.metadata = ProjectMetadata()
        self.formatVersion = Self.currentFormatVersion
    }
    
    // MARK: - Track Management
    
    public mutating func addTrack(_ track: Track) {
        tracks.append(track)
        modifiedAt = Date()
    }
    
    public mutating func removeTrack(id: TrackID) {
        tracks.removeAll { $0.id == id }
        modifiedAt = Date()
    }
    
    public mutating func moveTrack(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0 && sourceIndex < tracks.count,
              destinationIndex >= 0 && destinationIndex <= tracks.count else {
            return
        }
        let track = tracks.remove(at: sourceIndex)
        let adjustedIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        tracks.insert(track, at: adjustedIndex)
        modifiedAt = Date()
    }
    
    public func track(withID id: TrackID) -> Track? {
        tracks.first { $0.id == id }
    }
    
    public mutating func updateTrack(_ track: Track) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index] = track
            modifiedAt = Date()
        }
    }
    
    // MARK: - Tempo at Position
    
    /// Get tempo at a specific beat position (accounts for tempo changes)
    public func tempo(atBeat beat: Double) -> Double {
        let sorted = tempoChanges.sorted { $0.beatPosition < $1.beatPosition }
        
        // Find the last tempo change before this position
        for change in sorted.reversed() {
            if change.beatPosition <= beat {
                return change.tempo.bpm
            }
        }
        
        return tempo.bpm
    }
    
    /// Get time signature at a specific beat position
    public func timeSignature(atBeat beat: Double) -> TimeSignature {
        let sorted = timeSignatureChanges.sorted { $0.beatPosition < $1.beatPosition }
        
        for change in sorted.reversed() {
            if change.beatPosition <= beat {
                return change.timeSignature
            }
        }
        
        return timeSignature
    }
    
    // MARK: - Project Duration
    
    /// Total project duration based on content
    public var duration: TimePosition {
        var maxEnd = TimePosition(samples: 0, sampleRate: sampleRate)
        
        for track in tracks {
            for clip in track.clips {
                if clip.timeRange.end > maxEnd {
                    maxEnd = clip.timeRange.end
                }
            }
        }
        
        return maxEnd
    }
    
    /// Duration in beats
    public var durationInBeats: Double {
        duration.beats(atTempo: tempo.bpm)
    }
}

// MARK: - Tempo Change

public struct TempoChange: Identifiable, Codable, Sendable {
    public var id: UUID
    public var beatPosition: Double
    public var tempo: Tempo
    public var curveType: AutomationCurve  // For gradual tempo changes
    
    public init(
        id: UUID = UUID(),
        beatPosition: Double,
        tempo: Tempo,
        curveType: AutomationCurve = .step
    ) {
        self.id = id
        self.beatPosition = beatPosition
        self.tempo = tempo
        self.curveType = curveType
    }
}

// MARK: - Time Signature Change

public struct TimeSignatureChange: Identifiable, Codable, Sendable {
    public var id: UUID
    public var beatPosition: Double  // Must align to bar boundary
    public var timeSignature: TimeSignature
    
    public init(
        id: UUID = UUID(),
        beatPosition: Double,
        timeSignature: TimeSignature
    ) {
        self.id = id
        self.beatPosition = beatPosition
        self.timeSignature = timeSignature
    }
}

// MARK: - Marker

public struct Marker: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var beatPosition: Double
    public var color: TrackColor
    public var type: MarkerType
    
    public init(
        id: UUID = UUID(),
        name: String,
        beatPosition: Double,
        color: TrackColor = .blue,
        type: MarkerType = .generic
    ) {
        self.id = id
        self.name = name
        self.beatPosition = beatPosition
        self.color = color
        self.type = type
    }
}

public enum MarkerType: String, Codable, Sendable {
    case generic
    case verse
    case chorus
    case bridge
    case intro
    case outro
    case drop
    case breakdown
    case cuePoint
}

// MARK: - Project Metadata

public struct ProjectMetadata: Codable, Sendable {
    public var artist: String
    public var album: String
    public var genre: String
    public var comments: String
    public var copyright: String
    
    public init(
        artist: String = "",
        album: String = "",
        genre: String = "",
        comments: String = "",
        copyright: String = ""
    ) {
        self.artist = artist
        self.album = album
        self.genre = genre
        self.comments = comments
        self.copyright = copyright
    }
}

// MARK: - Project Factory

public enum ProjectFactory {
    /// Create a new empty project with default tracks
    public static func createNewProject(
        name: String = "Untitled Project",
        sampleRate: Double = 44100,
        includeDefaultTracks: Bool = true
    ) -> Project {
        var project = Project(name: name, sampleRate: sampleRate)
        
        if includeDefaultTracks {
            // Add one audio and one MIDI track by default
            project.addTrack(Track(
                name: "Audio 1",
                type: .audio,
                color: .blue
            ))
            
            project.addTrack(Track(
                name: "MIDI 1",
                type: .midi,
                color: .green
            ))
        }
        
        return project
    }
}
