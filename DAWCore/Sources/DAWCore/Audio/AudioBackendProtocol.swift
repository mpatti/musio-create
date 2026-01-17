import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Audio Backend Protocol

/// Protocol for audio backend implementations
/// Allows switching between AVAudioEngine (legacy) and Core Audio (professional) backends
public protocol AudioBackend: AnyObject {
    
    // MARK: - State Properties
    
    var isRunning: Bool { get }
    var sampleRate: Double { get }
    var bufferSize: UInt32 { get }
    var currentSamplePosition: Int64 { get }
    var isPlaying: Bool { get }
    
    // MARK: - Lifecycle
    
    func start() throws
    func stop()
    
    // MARK: - Track Management
    
    func createTrack(id: TrackID) throws
    func removeTrack(id: TrackID)
    func setTrackVolume(_ volume: Float, for trackID: TrackID)
    func setTrackPan(_ pan: Float, for trackID: TrackID)
    func setTrackMute(_ muted: Bool, for trackID: TrackID)
    
    // MARK: - Plugin Hosting
    
    /// Load an instrument plugin for a track
    func loadInstrument(
        _ description: AudioComponentDescription,
        for trackID: TrackID
    ) async throws -> AudioUnit
    
    /// Load an effect plugin at a slot on a track
    func loadEffect(
        _ description: AudioComponentDescription,
        for trackID: TrackID,
        slot: Int
    ) async throws -> AudioUnit
    
    /// Unload a plugin from a track slot
    func unloadPlugin(for trackID: TrackID, slot: Int)
    
    /// Get the AudioUnit for a track's instrument (for UI, parameter access)
    func getInstrumentAudioUnit(for trackID: TrackID) -> AudioUnit?
    
    // MARK: - MIDI
    
    /// Schedule a MIDI event for playback
    func scheduleMIDIEvent(_ event: ScheduledMIDIEvent)
    
    /// Send immediate MIDI (for live playing, not scheduled)
    func sendImmediateMIDI(status: UInt8, data1: UInt8, data2: UInt8, to trackID: TrackID)
    
    /// Clear all scheduled MIDI events
    func clearScheduledMIDIEvents()
    
    // MARK: - Audio Clips
    
    /// Schedule an audio clip for playback
    func scheduleAudioClip(
        url: URL,
        trackID: TrackID,
        startSample: Int64,
        offsetSample: Int64,
        endSample: Int64,
        volume: Float
    ) throws
    
    /// Clear all scheduled audio clips
    func clearAudioClips()
    
    // MARK: - Playback Control
    
    /// Start playback from a sample position
    func play(from samplePosition: Int64)
    
    /// Pause playback (keep position)
    func pause()
    
    /// Stop playback (reset position)
    func stopPlayback()
    
    /// Seek to a sample position
    func seek(to samplePosition: Int64)
    
    // MARK: - Metronome
    
    /// Enable or disable metronome
    func setMetronomeEnabled(_ enabled: Bool)
    
    /// Set metronome volume (0.0 - 1.0)
    func setMetronomeVolume(_ volume: Float)
    
    /// Schedule metronome clicks for a range
    func scheduleMetronomeClicks(
        from startBeat: Double,
        to endBeat: Double,
        tempo: Double,
        timeSignature: TimeSignature
    )
    
    // MARK: - Offline Bounce
    
    /// Render audio offline (non-realtime) to a file
    func bounceOffline(
        from startSample: Int64,
        to endSample: Int64,
        outputURL: URL,
        progress: ((Double) -> Void)?
    ) async throws
    
    // MARK: - Configuration
    
    /// Set the buffer size (may require restart)
    func setBufferSize(_ size: UInt32) throws
    
    /// Set master volume
    func setMasterVolume(_ volume: Float)
    
    /// Get master volume
    var masterVolume: Float { get }
}

// MARK: - Scheduled MIDI Event

/// A MIDI event scheduled for playback at a specific sample position
public struct ScheduledMIDIEvent: Comparable {
    public let trackID: TrackID
    public let samplePosition: Int64
    public let status: UInt8
    public let data1: UInt8
    public let data2: UInt8
    public let channel: UInt8
    
    public init(
        trackID: TrackID,
        samplePosition: Int64,
        status: UInt8,
        data1: UInt8,
        data2: UInt8,
        channel: UInt8 = 0
    ) {
        self.trackID = trackID
        self.samplePosition = samplePosition
        self.status = status
        self.data1 = data1
        self.data2 = data2
        self.channel = channel
    }
    
    /// Create a note-on event
    public static func noteOn(
        trackID: TrackID,
        samplePosition: Int64,
        note: UInt8,
        velocity: UInt8,
        channel: UInt8 = 0
    ) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(
            trackID: trackID,
            samplePosition: samplePosition,
            status: 0x90 | (channel & 0x0F),
            data1: note,
            data2: velocity,
            channel: channel
        )
    }
    
    /// Create a note-off event
    public static func noteOff(
        trackID: TrackID,
        samplePosition: Int64,
        note: UInt8,
        channel: UInt8 = 0
    ) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(
            trackID: trackID,
            samplePosition: samplePosition,
            status: 0x80 | (channel & 0x0F),
            data1: note,
            data2: 0,
            channel: channel
        )
    }
    
    /// Create a control change event
    public static func controlChange(
        trackID: TrackID,
        samplePosition: Int64,
        controller: UInt8,
        value: UInt8,
        channel: UInt8 = 0
    ) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(
            trackID: trackID,
            samplePosition: samplePosition,
            status: 0xB0 | (channel & 0x0F),
            data1: controller,
            data2: value,
            channel: channel
        )
    }
    
    // Comparable for sorting by sample position
    public static func < (lhs: ScheduledMIDIEvent, rhs: ScheduledMIDIEvent) -> Bool {
        lhs.samplePosition < rhs.samplePosition
    }
}

// MARK: - Audio Backend Error

public enum AudioBackendError: Error, LocalizedError {
    case failedToStart(String)
    case failedToStop(String)
    case trackNotFound(TrackID)
    case pluginLoadFailed(String)
    case audioFileLoadFailed(URL, String)
    case bounceError(String)
    case configurationError(String)
    case notImplemented(String)
    
    public var errorDescription: String? {
        switch self {
        case .failedToStart(let reason):
            return "Failed to start audio backend: \(reason)"
        case .failedToStop(let reason):
            return "Failed to stop audio backend: \(reason)"
        case .trackNotFound(let id):
            return "Track not found: \(id.rawValue)"
        case .pluginLoadFailed(let reason):
            return "Failed to load plugin: \(reason)"
        case .audioFileLoadFailed(let url, let reason):
            return "Failed to load audio file at \(url.path): \(reason)"
        case .bounceError(let reason):
            return "Bounce failed: \(reason)"
        case .configurationError(let reason):
            return "Configuration error: \(reason)"
        case .notImplemented(let feature):
            return "Feature not implemented: \(feature)"
        }
    }
}
