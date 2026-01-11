import Foundation
import AVFoundation

// MARK: - Audio Clip Player

/// Handles playback of audio clips using AVAudioPlayerNode
@MainActor
public final class AudioClipPlayer {
    
    // MARK: - Properties
    
    private let audioEngine: AudioEngine
    private let fileManager: AudioFileManager
    
    // Player nodes per clip
    private var players: [ClipID: ClipPlayer] = [:]
    
    // Loaded audio files
    private var loadedFiles: [UUID: AVAudioFile] = [:]
    
    // MARK: - Initialization
    
    public init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        self.fileManager = AudioFileManager()
    }
    
    // MARK: - File Loading
    
    /// Pre-load an audio file for playback
    public func loadAudioFile(reference: AudioFileReference, projectDirectory: URL) async throws {
        if loadedFiles[reference.fileID] != nil { return }
        
        let file = try await fileManager.loadAndCache(reference: reference, projectDirectory: projectDirectory)
        loadedFiles[reference.fileID] = file
    }
    
    /// Load audio file from URL
    public func loadAudioFile(from url: URL) async throws -> AVAudioFile {
        try AVAudioFile(forReading: url)
    }
    
    // MARK: - Clip Scheduling
    
    /// Schedule an audio clip for playback
    public func scheduleClip(
        clip: Clip,
        audioData: AudioClipData,
        trackID: TrackID,
        startSample: Int64,
        projectDirectory: URL
    ) async throws {
        // Get or load the audio file
        guard let file = loadedFiles[audioData.fileReference.fileID] else {
            throw PlaybackError.audioFileLoadFailed(
                projectDirectory.appendingPathComponent(audioData.fileReference.relativePath),
                NSError(domain: "AudioClipPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "File not loaded"])
            )
        }
        
        // Get the track node
        guard let trackNode = audioEngine.trackNode(for: trackID) else {
            throw PlaybackError.trackNotFound(trackID)
        }
        
        // Create player node if needed
        let player: ClipPlayer
        if let existing = players[clip.id] {
            player = existing
        } else {
            let playerNode = AVAudioPlayerNode()
            audioEngine.engine.attach(playerNode)
            
            // Connect to track input
            audioEngine.engine.connect(playerNode, to: trackNode.inputMixer, format: file.processingFormat)
            
            player = ClipPlayer(node: playerNode, file: file)
            players[clip.id] = player
        }
        
        // Calculate source frames
        let sourceStart = AVAudioFramePosition(audioData.sourceStartSample)
        let sourceLength = audioData.sourceLengthSamples > 0
            ? AVAudioFrameCount(audioData.sourceLengthSamples)
            : AVAudioFrameCount(file.length - sourceStart)
        
        // Schedule the segment
        await player.node.scheduleSegment(
            file,
            startingFrame: sourceStart,
            frameCount: sourceLength,
            at: nil  // Play immediately when play() is called
        )
        
        // Apply gain
        player.node.volume = clip.gain
    }
    
    /// Schedule all audio clips in a project for playback from a given position
    public func scheduleAllClips(
        in project: Project,
        fromBeat: Double,
        projectDirectory: URL
    ) async throws {
        for track in project.tracks {
            guard track.type == .audio && !track.isMuted else { continue }
            
            for clip in track.clips {
                guard !clip.isMuted else { continue }
                guard case .audio(let audioData) = clip.content else { continue }
                
                let clipStartBeat = clip.timeRange.start.beats(atTempo: project.tempo.bpm)
                
                // Skip clips that end before our start position
                let clipEndBeat = clip.timeRange.end.beats(atTempo: project.tempo.bpm)
                if clipEndBeat <= fromBeat { continue }
                
                // Calculate the sample position within the clip
                let offsetBeat = max(0, fromBeat - clipStartBeat)
                let offsetSamples = Int64(TimePosition(beats: offsetBeat, tempo: project.tempo.bpm, sampleRate: project.sampleRate).samples)
                
                try await scheduleClip(
                    clip: clip,
                    audioData: audioData,
                    trackID: track.id,
                    startSample: offsetSamples,
                    projectDirectory: projectDirectory
                )
            }
        }
    }
    
    // MARK: - Playback Control
    
    /// Start playback of all scheduled clips
    public func play() {
        for player in players.values {
            player.node.play()
        }
    }
    
    /// Stop all clips
    public func stop() {
        for player in players.values {
            player.node.stop()
        }
    }
    
    /// Pause all clips
    public func pause() {
        for player in players.values {
            player.node.pause()
        }
    }
    
    /// Get current playback position of a clip in frames
    public func currentPosition(for clipID: ClipID) -> AVAudioFramePosition? {
        guard let player = players[clipID],
              let nodeTime = player.node.lastRenderTime,
              let playerTime = player.node.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return playerTime.sampleTime
    }
    
    // MARK: - Cleanup
    
    /// Remove a clip player
    public func removeClip(_ clipID: ClipID) {
        guard let player = players.removeValue(forKey: clipID) else { return }
        player.node.stop()
        audioEngine.engine.disconnectNodeOutput(player.node)
        audioEngine.engine.detach(player.node)
    }
    
    /// Remove all clip players
    public func removeAllClips() {
        for (clipID, _) in players {
            removeClip(clipID)
        }
    }
    
    /// Clear loaded files from memory
    public func clearCache() {
        loadedFiles.removeAll()
    }
}

// MARK: - Clip Player

private struct ClipPlayer {
    let node: AVAudioPlayerNode
    let file: AVAudioFile
}

// MARK: - Audio Region

/// Represents a region of audio to be played
public struct AudioRegion {
    public let fileURL: URL
    public let startFrame: AVAudioFramePosition
    public let frameCount: AVAudioFrameCount
    public let fadeInFrames: AVAudioFrameCount
    public let fadeOutFrames: AVAudioFrameCount
    
    public init(
        fileURL: URL,
        startFrame: AVAudioFramePosition = 0,
        frameCount: AVAudioFrameCount = 0,
        fadeInFrames: AVAudioFrameCount = 0,
        fadeOutFrames: AVAudioFrameCount = 0
    ) {
        self.fileURL = fileURL
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.fadeInFrames = fadeInFrames
        self.fadeOutFrames = fadeOutFrames
    }
}

// MARK: - Time Stretch Processor

/// Handles time stretching and pitch shifting for audio clips
public final class TimeStretchProcessor {
    
    /// Process audio with time stretch and pitch shift
    /// Note: For production use, you'd want to use a proper algorithm like
    /// Phase Vocoder, WSOLA, or a library like RubberBand
    public static func process(
        buffer: AVAudioPCMBuffer,
        stretchFactor: Float,
        pitchShift: Float,
        preservePitch: Bool
    ) -> AVAudioPCMBuffer {
        // This is a placeholder for time stretching
        // Real implementation would use:
        // 1. AVAudioUnitTimePitch for simple cases
        // 2. vDSP/Accelerate for custom algorithms
        // 3. RubberBand library for high-quality stretching
        
        // For now, just return the original buffer
        return buffer
    }
    
    /// Create an AVAudioUnitTimePitch for real-time processing
    public static func createTimePitchUnit(
        stretchFactor: Float,
        pitchShift: Float
    ) -> AVAudioUnitTimePitch {
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = stretchFactor
        timePitch.pitch = pitchShift * 100  // Cents
        return timePitch
    }
}
