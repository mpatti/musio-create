import Foundation
import AVFoundation
import Combine

// MARK: - Playback Engine

/// Coordinates audio and MIDI playback across all tracks
/// This is the central "brain" that schedules clips for playback
@MainActor
public final class PlaybackEngine: ObservableObject {
    
    // MARK: - Properties
    
    private let audioEngine: AudioEngine
    private weak var transportState: TransportState?
    
    // Track samplers for MIDI playback
    private var trackSamplers: [TrackID: AVAudioUnitSampler] = [:]
    
    // Track player nodes for audio playback (legacy)
    private var trackPlayers: [TrackID: [ClipID: AVAudioPlayerNode]] = [:]
    
    // Track which clips have audio successfully scheduled
    private var scheduledClips: Set<ClipID> = []
    
    // Simple AVAudioPlayer-based playback for audio clips (more reliable)
    private var audioPlayers: [ClipID: AVAudioPlayer] = [:]
    private var audioClipInfo: [ClipID: AudioClipPlaybackInfo] = [:]
    
    // Captured playback start position for sync
    private var playbackStartBeat: Double = 0
    private var playbackStartTime: Date?
    
    // Scheduled events for the current playback session
    private var scheduledMIDIEvents: [ScheduledEvent] = []
    private var activeNotes: [ActiveNote] = []
    
    // Playback timer
    private var playbackTimer: Timer?
    private let timerInterval: TimeInterval = 0.005  // 5ms update interval
    private var lastProcessedBeat: Double = 0
    private let lookAheadBeats: Double = 0.1  // Schedule events this far ahead
    
    // State
    @Published public private(set) var isPlaying: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }
    
    // MARK: - Setup
    
    public func bind(to transportState: TransportState) {
        self.transportState = transportState
        
        transportState.transportEventSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleTransportEvent(event)
            }
            .store(in: &cancellables)
    }
    
    private func handleTransportEvent(_ event: TransportEvent) {
        switch event {
        case .play:
            startPlayback()
        case .stop:
            stopPlayback()
        case .pause:
            pausePlayback()
        default:
            break
        }
    }
    
    // MARK: - Track Setup
    
    /// Setup a MIDI track with a sampler
    public func setupMIDITrack(_ track: Track) async throws {
        guard track.type == .midi || track.type == .instrument else { return }
        
        // Create sampler if needed
        if trackSamplers[track.id] == nil {
            let sampler = AVAudioUnitSampler()
            
            // Attach to audio engine
            audioEngine.engine.attach(sampler)
            
            // Connect to track input
            if let trackNode = audioEngine.trackNode(for: track.id) {
                let format = AVAudioFormat(standardFormatWithSampleRate: audioEngine.sampleRate, channels: 2)!
                audioEngine.engine.connect(sampler, to: trackNode.inputMixer, format: format)
            }
            
            // Load default sound (built-in piano)
            try await loadDefaultSound(for: sampler)
            
            trackSamplers[track.id] = sampler
        }
    }
    
    /// Load a SoundFont or default instrument into a sampler
    private func loadDefaultSound(for sampler: AVAudioUnitSampler) async throws {
        // Try to load the built-in piano sound from the system
        // This uses the DLS (Downloadable Sounds) format built into macOS
        
        // Path to the built-in Grand Piano
        let soundBankURL = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        
        if FileManager.default.fileExists(atPath: soundBankURL.path) {
            try sampler.loadSoundBankInstrument(
                at: soundBankURL,
                program: 0,        // Piano
                bankMSB: 0x79,     // Melodic bank
                bankLSB: 0
            )
        } else {
            // Fallback: Use a simple sine wave instrument
            // The sampler will produce a basic sound without a sound bank
            print("Warning: Could not load system sound bank, using basic synthesis")
        }
    }
    
    /// Load a custom SoundFont for a track
    public func loadSoundFont(url: URL, for trackID: TrackID, program: UInt8 = 0) async throws {
        guard let sampler = trackSamplers[trackID] else {
            throw PlaybackError.trackNotFound(trackID)
        }
        
        try sampler.loadSoundBankInstrument(
            at: url,
            program: program,
            bankMSB: 0x79,
            bankLSB: 0
        )
    }
    
    /// Get the sampler for a track (for external use like note preview)
    public func sampler(for trackID: TrackID) -> AVAudioUnitSampler? {
        trackSamplers[trackID]
    }
    
    // MARK: - Playback Control
    
    public func startPlayback() {
        guard let transport = transportState else { return }
        
        isPlaying = true
        // Use the captured playback start beat for consistent MIDI timing
        lastProcessedBeat = playbackStartBeat
        
        print("[PlaybackEngine] Starting playback at beat \(playbackStartBeat) (captured, current transport: \(transport.playheadBeats))")
        
        // Start all scheduled audio player nodes
        startAllAudioPlayers()
        
        // Start the playback timer for MIDI events
        playbackTimer = Timer.scheduledTimer(
            withTimeInterval: timerInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.processPlayback()
            }
        }
        
        RunLoop.main.add(playbackTimer!, forMode: .common)
    }
    
    /// Start all AVAudioPlayers based on captured playback start position
    private func startAllAudioPlayers() {
        guard let transport = transportState else { 
            print("[PlaybackEngine] No transport state")
            return 
        }
        
        // Use the captured start beat for consistent timing
        let currentBeat = playbackStartBeat
        let tempo = transport.tempo.bpm
        
        // Record the exact time we're starting playback
        playbackStartTime = Date()
        
        print("[PlaybackEngine] Starting audio players at beat \(currentBeat) (captured), \(audioPlayers.count) clips prepared")
        
        for (clipID, player) in audioPlayers {
            guard let info = audioClipInfo[clipID] else { continue }
            
            if currentBeat >= info.clipStartBeat && currentBeat < info.clipEndBeat {
                // Playhead is within this clip - start from offset
                let offsetBeats = currentBeat - info.clipStartBeat
                let offsetSeconds = offsetBeats * 60.0 / tempo
                
                player.currentTime = offsetSeconds
                player.play()
                
                let playDebug = """
                === PLAYBACK START DEBUG ===
                  Current beat: \(currentBeat)
                  Clip start beat: \(info.clipStartBeat)
                  Offset beats: \(offsetBeats)
                  Offset seconds: \(offsetSeconds)
                  Player currentTime set to: \(offsetSeconds)
                === END PLAYBACK START DEBUG ===
                
                """
                if let existing = try? String(contentsOfFile: "/tmp/daw_debug.log", encoding: .utf8) {
                    try? (existing + playDebug).write(toFile: "/tmp/daw_debug.log", atomically: true, encoding: .utf8)
                }
                print("[PlaybackEngine] Started clip \(clipID) from offset \(offsetSeconds)s (clip starts at beat \(info.clipStartBeat))")
                
            } else if currentBeat < info.clipStartBeat {
                // Clip starts in the future - schedule it
                let delayBeats = info.clipStartBeat - currentBeat
                let delaySeconds = delayBeats * 60.0 / tempo
                
                print("[PlaybackEngine] Scheduling clip \(clipID) to start in \(delaySeconds)s (at beat \(info.clipStartBeat))")
                
                // Use a timer to start the clip at the right time
                DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self, weak player] in
                    guard let self = self, let player = player, self.isPlaying else { return }
                    player.currentTime = 0
                    player.play()
                    print("[PlaybackEngine] Started delayed clip \(clipID)")
                }
            } else {
                print("[PlaybackEngine] Clip \(clipID) already passed (ends at beat \(info.clipEndBeat), current \(currentBeat))")
            }
        }
    }
    
    public func stopPlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        
        // Stop all active notes
        stopAllNotes()
        
        // Stop all audio players
        stopAllAudioPlayers()
        
        // Clear scheduled events
        scheduledMIDIEvents.removeAll()
    }
    
    public func pausePlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        
        // Note: We don't stop notes on pause - they'll continue until their natural end
        // This matches DAW behavior where pausing doesn't cut notes off
    }
    
    // MARK: - Event Scheduling
    
    /// Prepare all clips for playback
    public func prepareForPlayback(project: Project) {
        scheduledMIDIEvents.removeAll()
        
        // Clean up old audio player nodes first
        cleanupAudioPlayers()
        
        // IMPORTANT: Use the transport's captured start position
        // The transport captures this BEFORE the timer starts, ensuring perfect sync
        if let transport = transportState {
            playbackStartBeat = transport.playbackStartBeat
            print("[PlaybackEngine] Using transport's playbackStartBeat: \(playbackStartBeat)")
        }
        
        for track in project.tracks {
            // Skip muted tracks
            guard !track.isMuted else { continue }
            
            for clip in track.clips {
                guard !clip.isMuted else { continue }
                
                switch clip.content {
                case .midi(let midiData):
                    scheduleMIDIClip(midiData, clip: clip, track: track, project: project)
                    
                case .audio(let audioData):
                    // Use simple AVAudioPlayer for reliable playback
                    prepareAudioClipWithAVAudioPlayer(audioData, clip: clip, track: track, project: project)
                }
            }
        }
        
        // Sort by beat position for efficient processing
        scheduledMIDIEvents.sort { $0.absoluteBeat < $1.absoluteBeat }
    }
    
    /// Clean up existing audio player nodes and AVAudioPlayers
    private func cleanupAudioPlayers() {
        // Clean up legacy AVAudioPlayerNode instances
        for (_, players) in trackPlayers {
            for (_, player) in players {
                player.stop()
                if player.engine != nil {
                    audioEngine.engine.disconnectNodeOutput(player)
                    audioEngine.engine.detach(player)
                }
            }
        }
        trackPlayers.removeAll()
        scheduledClips.removeAll()
        
        // Clean up AVAudioPlayer instances
        for (_, player) in audioPlayers {
            player.stop()
        }
        audioPlayers.removeAll()
        audioClipInfo.removeAll()
    }
    
    /// Prepare an audio clip for playback using AVAudioPlayer (simple & reliable)
    private func prepareAudioClipWithAVAudioPlayer(
        _ audioData: AudioClipData,
        clip: Clip,
        track: Track,
        project: Project
    ) {
        let fileURL = URL(fileURLWithPath: audioData.fileReference.originalPath)
        
        print("[PlaybackEngine] Preparing audio clip '\(clip.name)' with AVAudioPlayer from: \(fileURL.path)")
        
        // Check file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[PlaybackEngine] ERROR: Audio file not found: \(fileURL.path)")
            return
        }
        
        do {
            // Create AVAudioPlayer
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.prepareToPlay()
            player.volume = track.volume * clip.gain
            
            // Store player and clip info
            audioPlayers[clip.id] = player
            
            let clipStartBeat = clip.timeRange.start.beats(atTempo: project.tempo.bpm)
            let clipEndBeat = clip.timeRange.end.beats(atTempo: project.tempo.bpm)
            
            audioClipInfo[clip.id] = AudioClipPlaybackInfo(
                clipID: clip.id,
                trackID: track.id,
                clipStartBeat: clipStartBeat,
                clipEndBeat: clipEndBeat,
                fileURL: fileURL,
                volume: track.volume * clip.gain
            )
            
            let debugInfo = """
            === PLAYBACK PREP DEBUG ===
              Clip '\(clip.name)'
              File duration: \(player.duration)s
              Clip start beat: \(clipStartBeat)
              Clip end beat: \(clipEndBeat)
              Clip timeRange.start samples: \(clip.timeRange.start.samples)
              Clip timeRange.start.seconds: \(clip.timeRange.start.seconds)
              Project tempo: \(project.tempo.bpm)
              Playback start beat (captured): \(self.playbackStartBeat)
            === END PLAYBACK PREP DEBUG ===
            
            """
            // Append to debug log
            if let existing = try? String(contentsOfFile: "/tmp/daw_debug.log", encoding: .utf8) {
                try? (existing + debugInfo).write(toFile: "/tmp/daw_debug.log", atomically: true, encoding: .utf8)
            } else {
                try? debugInfo.write(toFile: "/tmp/daw_debug.log", atomically: true, encoding: .utf8)
            }
            print(debugInfo)
            
        } catch {
            print("[PlaybackEngine] ERROR creating AVAudioPlayer: \(error)")
        }
    }
    
    private func scheduleMIDIClip(
        _ midiData: MIDIClipData,
        clip: Clip,
        track: Track,
        project: Project
    ) {
        let clipStartBeat = clip.timeRange.start.beats(atTempo: project.tempo.bpm)
        let clipEndBeat = clip.timeRange.end.beats(atTempo: project.tempo.bpm)
        
        for event in midiData.events {
            let absoluteBeat = clipStartBeat + event.beatPosition
            
            // Skip events outside clip bounds
            guard absoluteBeat >= clipStartBeat && absoluteBeat < clipEndBeat else { continue }
            
            let scheduled = ScheduledEvent(
                trackID: track.id,
                clipID: clip.id,
                absoluteBeat: absoluteBeat,
                event: event
            )
            
            scheduledMIDIEvents.append(scheduled)
        }
    }
    
    /// Synchronous version of audio clip scheduling for reliable playback
    private func scheduleAudioClipSync(
        _ audioData: AudioClipData,
        clip: Clip,
        track: Track,
        project: Project
    ) {
        do {
            // Load the audio file - use original path (absolute) or fallback
            let fileURL = URL(fileURLWithPath: audioData.fileReference.originalPath)
            
            print("[PlaybackEngine] Scheduling audio clip '\(clip.name)' from: \(fileURL.path)")
            
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                print("[PlaybackEngine] ERROR: Audio file not found: \(fileURL.path)")
                return
            }
            
            let audioFile = try AVAudioFile(forReading: fileURL)
            
            // Validate the audio file has actual content
            guard audioFile.length > 0 else {
                print("[PlaybackEngine] ERROR: Audio file is empty: \(fileURL.path)")
                return
            }
            
            print("[PlaybackEngine] Loaded audio file: \(audioFile.length) frames, \(audioFile.fileFormat.sampleRate) Hz, \(audioFile.fileFormat.channelCount) channels")
            
            // Make sure the audio engine is running before attaching nodes
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            
            // Create player node
            let playerNode = AVAudioPlayerNode()
            audioEngine.engine.attach(playerNode)
            
            // Connect to track
            guard let trackNode = audioEngine.trackNode(for: track.id) else {
                print("[PlaybackEngine] ERROR: Track node not found for track \(track.id)")
                audioEngine.engine.detach(playerNode)
                return
            }
            
            // Use a standard format for connection to avoid format mismatches
            let format = audioFile.processingFormat
            audioEngine.engine.connect(playerNode, to: trackNode.inputMixer, format: format)
            print("[PlaybackEngine] Connected player to track '\(track.name)'")
            
            // Calculate timing
            guard let transport = transportState else {
                print("[PlaybackEngine] ERROR: No transport state")
                audioEngine.engine.detach(playerNode)
                return
            }
            
            let clipStartBeat = clip.timeRange.start.beats(atTempo: transport.tempo.bpm)
            let currentBeat = transport.playheadBeats
            
            print("[PlaybackEngine] Clip starts at beat \(clipStartBeat), playhead at \(currentBeat)")
            
            // Schedule and immediately start playback
            // Using play() + scheduleSegment/scheduleFile with at:nil together
            
            if clipStartBeat <= currentBeat {
                // Clip starts before or at current position - calculate offset
                let offsetBeats = currentBeat - clipStartBeat
                let offsetSeconds = offsetBeats * 60.0 / transport.tempo.bpm
                let offsetFrames = AVAudioFramePosition(offsetSeconds * audioFile.fileFormat.sampleRate)
                
                if offsetFrames < audioFile.length {
                    let remainingFrames = AVAudioFrameCount(audioFile.length - offsetFrames)
                    
                    // Validate we have frames to play
                    guard remainingFrames > 0 else {
                        print("[PlaybackEngine] No frames remaining to play")
                        audioEngine.engine.detach(playerNode)
                        return
                    }
                    
                    // Start the player FIRST, then schedule
                    // This is the correct order for AVAudioPlayerNode
                    playerNode.play()
                    
                    playerNode.scheduleSegment(
                        audioFile,
                        startingFrame: offsetFrames,
                        frameCount: remainingFrames,
                        at: nil
                    )
                    
                    print("[PlaybackEngine] Started and scheduled segment from frame \(offsetFrames), \(remainingFrames) frames")
                    
                    // Store for later cleanup
                    if trackPlayers[track.id] == nil {
                        trackPlayers[track.id] = [:]
                    }
                    trackPlayers[track.id]?[clip.id] = playerNode
                    scheduledClips.insert(clip.id)
                    
                } else {
                    print("[PlaybackEngine] Clip already finished at current position")
                    audioEngine.engine.detach(playerNode)
                    return
                }
            } else {
                // Clip starts in the future - we'll handle this with a timer
                // For now, just store it
                print("[PlaybackEngine] Clip starts in the future (beat \(clipStartBeat)), skipping for now")
                audioEngine.engine.detach(playerNode)
            }
            
        } catch {
            print("[PlaybackEngine] ERROR scheduling audio clip: \(error)")
        }
    }
    
    private func scheduleAudioClip(
        _ audioData: AudioClipData,
        clip: Clip,
        track: Track,
        project: Project
    ) {
        // Call the synchronous version
        scheduleAudioClipSync(audioData, clip: clip, track: track, project: project)
    }
    
    // MARK: - Playback Processing
    
    private func processPlayback() {
        guard isPlaying, let transport = transportState else { return }
        
        let currentBeat = transport.playheadBeats
        let windowEnd = currentBeat + lookAheadBeats
        
        // Process MIDI events in the current window
        for scheduled in scheduledMIDIEvents {
            // Skip already processed events
            guard scheduled.absoluteBeat >= lastProcessedBeat else { continue }
            
            // Stop if we're past the look-ahead window
            guard scheduled.absoluteBeat < windowEnd else { break }
            
            // Process this event
            processEvent(scheduled)
        }
        
        // Check for note-offs
        processNoteOffs(at: currentBeat)
        
        // Handle looping
        if transport.isLoopEnabled {
            let loopEndBeat = transport.loopEnd.beats(atTempo: transport.tempo.bpm)
            if currentBeat >= loopEndBeat {
                // Reset for loop
                lastProcessedBeat = transport.loopStart.beats(atTempo: transport.tempo.bpm)
            }
        }
        
        lastProcessedBeat = currentBeat
    }
    
    private func processEvent(_ scheduled: ScheduledEvent) {
        guard let sampler = trackSamplers[scheduled.trackID] else { return }
        
        switch scheduled.event.type {
        case .note(let noteData):
            // Play note on
            sampler.startNote(noteData.pitch, withVelocity: noteData.velocity, onChannel: scheduled.event.channel)
            
            // Schedule note off
            let noteEndBeat = scheduled.absoluteBeat + noteData.duration
            activeNotes.append(ActiveNote(
                trackID: scheduled.trackID,
                pitch: noteData.pitch,
                channel: scheduled.event.channel,
                endBeat: noteEndBeat
            ))
            
        case .controlChange(let controller, let value):
            sampler.sendController(controller, withValue: value, onChannel: scheduled.event.channel)
            
        case .programChange(let program):
            sampler.sendProgramChange(program, onChannel: scheduled.event.channel)
            
        case .pitchBend(let value):
            // Convert from signed to unsigned pitch bend
            let unsignedValue = UInt16(bitPattern: Int16(value + 8192))
            sampler.sendPitchBend(unsignedValue, onChannel: scheduled.event.channel)
            
        default:
            break
        }
    }
    
    private func processNoteOffs(at currentBeat: Double) {
        let notesToStop = activeNotes.filter { $0.endBeat <= currentBeat }
        
        for note in notesToStop {
            if let sampler = trackSamplers[note.trackID] {
                sampler.stopNote(note.pitch, onChannel: note.channel)
            }
        }
        
        activeNotes.removeAll { $0.endBeat <= currentBeat }
    }
    
    private func stopAllNotes() {
        for (trackID, sampler) in trackSamplers {
            for note in activeNotes where note.trackID == trackID {
                sampler.stopNote(note.pitch, onChannel: note.channel)
            }
        }
        activeNotes.removeAll()
    }
    
    private func stopAllAudioPlayers() {
        print("[PlaybackEngine] Stopping all audio players")
        
        // Stop legacy AVAudioPlayerNode instances
        for (_, players) in trackPlayers {
            for (clipID, player) in players {
                player.stop()
                print("[PlaybackEngine] Stopped AVAudioPlayerNode for clip \(clipID)")
            }
        }
        
        // Stop AVAudioPlayer instances
        for (clipID, player) in audioPlayers {
            player.stop()
            print("[PlaybackEngine] Stopped AVAudioPlayer for clip \(clipID)")
        }
    }
    
    // MARK: - Note Preview
    
    /// Play a note immediately for preview (piano roll, keyboard)
    public func playNotePreview(pitch: UInt8, velocity: UInt8, on trackID: TrackID) {
        guard let sampler = trackSamplers[trackID] else { return }
        sampler.startNote(pitch, withVelocity: velocity, onChannel: 0)
    }
    
    /// Stop a preview note
    public func stopNotePreview(pitch: UInt8, on trackID: TrackID) {
        guard let sampler = trackSamplers[trackID] else { return }
        sampler.stopNote(pitch, onChannel: 0)
    }
    
    /// Play a test note to verify audio is working
    public func playTestNote(on trackID: TrackID) {
        guard let sampler = trackSamplers[trackID] else { return }
        
        // Middle C at medium velocity
        sampler.startNote(60, withVelocity: 100, onChannel: 0)
        
        // Stop after 0.5 seconds
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                sampler.stopNote(60, onChannel: 0)
            }
        }
    }
    
    // MARK: - Cleanup
    
    public func cleanup() {
        stopPlayback()
        
        // Detach all samplers
        for sampler in trackSamplers.values {
            audioEngine.engine.detach(sampler)
        }
        trackSamplers.removeAll()
        
        // Detach all players
        for players in trackPlayers.values {
            for player in players.values {
                audioEngine.engine.detach(player)
            }
        }
        trackPlayers.removeAll()
    }
}

// MARK: - Supporting Types

private struct ScheduledEvent {
    let trackID: TrackID
    let clipID: ClipID
    let absoluteBeat: Double
    let event: MIDIEvent
}

private struct ActiveNote {
    let trackID: TrackID
    let pitch: UInt8
    let channel: UInt8
    let endBeat: Double
}

/// Info about an audio clip for playback timing
private struct AudioClipPlaybackInfo {
    let clipID: ClipID
    let trackID: TrackID
    let clipStartBeat: Double
    let clipEndBeat: Double
    let fileURL: URL
    let volume: Float
}

// MARK: - Errors

public enum PlaybackError: Error, LocalizedError {
    case trackNotFound(TrackID)
    case samplerNotLoaded(TrackID)
    case soundBankLoadFailed(URL, Error)
    case audioFileLoadFailed(URL, Error)
    
    public var errorDescription: String? {
        switch self {
        case .trackNotFound(let id):
            return "Track not found: \(id.rawValue)"
        case .samplerNotLoaded(let id):
            return "Sampler not loaded for track: \(id.rawValue)"
        case .soundBankLoadFailed(let url, let error):
            return "Failed to load sound bank at \(url): \(error.localizedDescription)"
        case .audioFileLoadFailed(let url, let error):
            return "Failed to load audio file at \(url): \(error.localizedDescription)"
        }
    }
}

