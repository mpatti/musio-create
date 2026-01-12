import Foundation
import AVFoundation
import AudioToolbox
import Combine

// MARK: - Playback Engine

/// Coordinates audio and MIDI playback across all tracks
/// This is the central "brain" that schedules clips for playback
@MainActor
public final class PlaybackEngine: ObservableObject {
    
    // MARK: - Properties
    
    private let audioEngine: AudioEngine
    private weak var transportState: TransportState?
    
    // Track instruments - can be AU instruments or fallback samplers
    private var trackInstruments: [TrackID: TrackInstrument] = [:]
    
    // V-Rack instruments - multi-timbral instruments that receive MIDI from multiple tracks
    private var rackInstruments: [UUID: TrackInstrument] = [:]
    private var rackInstrumentMixers: [UUID: AVAudioMixerNode] = [:]
    
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
    
    /// Setup a MIDI track with an instrument (AU plugin or fallback sampler)
    public func setupMIDITrack(_ track: Track) async throws {
        guard track.type == .midi || track.type == .instrument else { return }
        
        // Skip if already set up
        if trackInstruments[track.id] != nil { return }
        
        // Create fallback sampler
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
        
        trackInstruments[track.id] = .sampler(sampler)
        print("[PlaybackEngine] Setup fallback sampler for track: \(track.name)")
    }
    
    // Mixer nodes used for sample rate conversion when loading AU instruments
    private var instrumentMixers: [TrackID: AVAudioMixerNode] = [:]
    
    /// Load an AU instrument plugin for a track
    public func loadInstrument(_ audioUnit: AVAudioUnit, for trackID: TrackID, pluginID: UUID) async throws {
        // Remove existing instrument if any
        removeInstrument(for: trackID)
        
        print("[PlaybackEngine] ========================================")
        print("[PlaybackEngine] Loading AU instrument: \(audioUnit.name)")
        print("[PlaybackEngine] Track ID: \(trackID.rawValue)")
        print("[PlaybackEngine] Audio Engine running: \(audioEngine.engine.isRunning)")
        
        // Stop the engine before making changes
        let wasRunning = audioEngine.engine.isRunning
        if wasRunning {
            audioEngine.engine.stop()
            print("[PlaybackEngine] Stopped engine for reconfiguration")
        }
        
        // Get the output format from the AU
        let auFormat = audioUnit.outputFormat(forBus: 0)
        print("[PlaybackEngine] AU native format: \(auFormat)")
        
        // Engine format
        let engineFormat = AVAudioFormat(standardFormatWithSampleRate: audioEngine.sampleRate, channels: 2)!
        print("[PlaybackEngine] Engine format: \(engineFormat)")
        
        // Attach the AU to the audio engine
        audioEngine.engine.attach(audioUnit)
        print("[PlaybackEngine] Attached AU to engine")
        
        // Create a mixer node to handle sample rate conversion
        // AVAudioMixerNode automatically converts between formats
        let converterMixer = AVAudioMixerNode()
        audioEngine.engine.attach(converterMixer)
        instrumentMixers[trackID] = converterMixer
        print("[PlaybackEngine] Created converter mixer for sample rate conversion")
        
        // Connect: AU (44100) -> converterMixer -> trackNode.inputMixer (48000)
        // The mixer node handles the sample rate conversion automatically
        audioEngine.engine.connect(audioUnit, to: converterMixer, format: auFormat)
        print("[PlaybackEngine] Connected AU -> converterMixer (AU format: \(auFormat.sampleRate) Hz)")
        
        // Connect to track input with engine format
        if let trackNode = audioEngine.trackNode(for: trackID) {
            audioEngine.engine.connect(converterMixer, to: trackNode.inputMixer, format: engineFormat)
            print("[PlaybackEngine] Connected converterMixer -> trackNode.inputMixer (engine format: \(engineFormat.sampleRate) Hz)")
            print("[PlaybackEngine] Track inputMixer volume: \(trackNode.inputMixer.outputVolume)")
            converterMixer.outputVolume = 1.0
            print("[PlaybackEngine] Converter mixer volume: \(converterMixer.outputVolume)")
        } else {
            print("[PlaybackEngine] ERROR: No track node for \(trackID.rawValue)")
            throw PlaybackError.trackNotFound(trackID)
        }
        
        // Restart the engine
        if wasRunning {
            do {
                try audioEngine.engine.start()
                print("[PlaybackEngine] ✓ Engine restarted")
            } catch {
                print("[PlaybackEngine] ⚠️ Failed to restart engine: \(error)")
            }
        }
        
        // Check the connections
        let auConnections = audioEngine.engine.outputConnectionPoints(for: audioUnit, outputBus: 0)
        let mixerConnections = audioEngine.engine.outputConnectionPoints(for: converterMixer, outputBus: 0)
        print("[PlaybackEngine] AU output connections: \(auConnections.count)")
        print("[PlaybackEngine] Converter mixer output connections: \(mixerConnections.count)")
        
        // Check if the AU is now rendering
        print("[PlaybackEngine] AU render resources allocated: \(audioUnit.auAudioUnit.renderResourcesAllocated)")
        
        trackInstruments[trackID] = .auInstrument(audioUnit, pluginID: pluginID)
        
        // Verify we can get the instrument back
        if let inst = trackInstruments[trackID] {
            print("[PlaybackEngine] Instrument stored successfully: \(inst)")
        }
        
        print("[PlaybackEngine] ========================================")
    }
    
    /// Remove the instrument from a track
    public func removeInstrument(for trackID: TrackID) {
        guard let instrument = trackInstruments[trackID] else { return }
        
        // Disconnect and detach the audio node
        audioEngine.engine.disconnectNodeOutput(instrument.audioNode)
        audioEngine.engine.detach(instrument.audioNode)
        
        // Also remove the converter mixer if it exists
        if let mixer = instrumentMixers[trackID] {
            audioEngine.engine.disconnectNodeOutput(mixer)
            audioEngine.engine.detach(mixer)
            instrumentMixers.removeValue(forKey: trackID)
        }
        
        trackInstruments.removeValue(forKey: trackID)
        print("[PlaybackEngine] Removed instrument from track: \(trackID.rawValue)")
    }
    
    /// Get the instrument for a track
    public func instrument(for trackID: TrackID) -> TrackInstrument? {
        trackInstruments[trackID]
    }
    
    /// Debug: list all loaded instruments
    public func debugInstrumentList() -> String {
        if trackInstruments.isEmpty {
            return "No instruments loaded"
        }
        return trackInstruments.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", ")
    }
    
    // MARK: - V-Rack Instrument Management
    
    /// Load an AU instrument plugin for the V-Rack
    public func loadRackInstrument(_ audioUnit: AVAudioUnit, rackID: UUID, pluginID: UUID) async throws {
        // Remove existing instrument if any
        removeRackInstrument(rackID: rackID)
        
        print("[PlaybackEngine] ========================================")
        print("[PlaybackEngine] Loading V-Rack AU instrument: \(audioUnit.name)")
        print("[PlaybackEngine] Rack ID: \(rackID)")
        
        // Stop the engine before making changes
        let wasRunning = audioEngine.engine.isRunning
        if wasRunning {
            audioEngine.engine.stop()
        }
        
        // Attach the audio unit to the engine
        audioEngine.engine.attach(audioUnit)
        
        // Create a mixer for sample rate conversion
        let converterMixer = AVAudioMixerNode()
        audioEngine.engine.attach(converterMixer)
        rackInstrumentMixers[rackID] = converterMixer
        
        // Get the AU's native output format
        let auFormat = audioUnit.outputFormat(forBus: 0)
        let engineFormat = audioEngine.engine.mainMixerNode.outputFormat(forBus: 0)
        
        print("[PlaybackEngine] AU output format: \(auFormat)")
        print("[PlaybackEngine] Engine format: \(engineFormat)")
        
        // Connect: AU -> converterMixer (using AU's format)
        audioEngine.engine.connect(audioUnit, to: converterMixer, format: auFormat)
        
        // Connect: converterMixer -> mainMixer (using engine's format)
        audioEngine.engine.connect(converterMixer, to: audioEngine.engine.mainMixerNode, format: engineFormat)
        
        // Allocate render resources
        try audioUnit.auAudioUnit.allocateRenderResources()
        
        // Restart engine if it was running
        if wasRunning {
            try audioEngine.engine.start()
        }
        
        // Store the instrument
        rackInstruments[rackID] = .auInstrument(audioUnit, pluginID: pluginID)
        
        print("[PlaybackEngine] V-Rack instrument loaded successfully: \(audioUnit.name)")
    }
    
    /// Remove a rack instrument
    public func removeRackInstrument(rackID: UUID) {
        guard let instrument = rackInstruments[rackID] else { return }
        
        // Disconnect and detach the audio node
        audioEngine.engine.disconnectNodeOutput(instrument.audioNode)
        audioEngine.engine.detach(instrument.audioNode)
        
        // Also remove the converter mixer if it exists
        if let mixer = rackInstrumentMixers[rackID] {
            audioEngine.engine.disconnectNodeOutput(mixer)
            audioEngine.engine.detach(mixer)
            rackInstrumentMixers.removeValue(forKey: rackID)
        }
        
        rackInstruments.removeValue(forKey: rackID)
        print("[PlaybackEngine] Removed V-Rack instrument: \(rackID)")
    }
    
    /// Get a rack instrument by ID
    public func rackInstrument(for rackID: UUID) -> TrackInstrument? {
        rackInstruments[rackID]
    }
    
    /// Send MIDI to a rack instrument on a specific channel
    public func sendMIDIToRackInstrument(rackID: UUID, note: UInt8, velocity: UInt8, channel: UInt8, isNoteOn: Bool) {
        guard let instrument = rackInstruments[rackID] else {
            print("[PlaybackEngine] No rack instrument found for ID: \(rackID)")
            return
        }
        
        if isNoteOn {
            instrument.startNote(note, velocity: velocity, channel: channel)
        } else {
            instrument.stopNote(note, channel: channel)
        }
    }

    /// Debug: Check audio engine state and play a test tone
    public func debugAudioPath(for trackID: TrackID) {
        print("[DEBUG] ========================================")
        print("[DEBUG] Audio Engine running: \(audioEngine.engine.isRunning)")
        print("[DEBUG] Audio Engine sample rate: \(audioEngine.sampleRate)")
        print("[DEBUG] Master volume: \(audioEngine.masterVolume)")
        
        if let trackNode = audioEngine.trackNode(for: trackID) {
            print("[DEBUG] Track node found")
            print("[DEBUG] Input mixer volume: \(trackNode.inputMixer.outputVolume)")
            print("[DEBUG] Gain node volume: \(trackNode.gainNode.outputVolume)")
            print("[DEBUG] Output mixer volume: \(trackNode.outputMixer.outputVolume)")
        } else {
            print("[DEBUG] No track node!")
        }
        
        if let instrument = trackInstruments[trackID] {
            print("[DEBUG] Instrument found: \(instrument)")
            
            // Check if AU is connected
            if case .auInstrument(let au, _) = instrument {
                print("[DEBUG] AU name: \(au.name)")
                print("[DEBUG] AU manufacturer: \(au.manufacturerName)")
                let connections = audioEngine.engine.outputConnectionPoints(for: au, outputBus: 0)
                print("[DEBUG] AU has \(connections.count) output connections")
                
                // Check scheduleMIDIEventBlock
                if au.auAudioUnit.scheduleMIDIEventBlock != nil {
                    print("[DEBUG] scheduleMIDIEventBlock is available")
                } else {
                    print("[DEBUG] scheduleMIDIEventBlock is NIL - using MusicDeviceMIDIEvent")
                }
            }
        } else {
            print("[DEBUG] No instrument for track!")
        }
        print("[DEBUG] ========================================")
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
        guard case .sampler(let sampler) = trackInstruments[trackID] else {
            throw PlaybackError.instrumentNotLoaded(trackID)
        }
        
        try sampler.loadSoundBankInstrument(
            at: url,
            program: program,
            bankMSB: 0x79,
            bankLSB: 0
        )
    }
    
    /// Get the sampler for a track (for external use like note preview)
    /// Returns nil if track uses an AU instrument instead of sampler
    public func sampler(for trackID: TrackID) -> AVAudioUnitSampler? {
        if case .sampler(let sampler) = trackInstruments[trackID] {
            return sampler
        }
        return nil
    }
    
    // MARK: - Playback Control
    
    public func startPlayback() {
        guard let transport = transportState else { return }

        isPlaying = true
        // Use the captured playback start beat for consistent MIDI timing
        lastProcessedBeat = playbackStartBeat

        print("[PlaybackEngine] ========================================")
        print("[PlaybackEngine] Starting playback at beat \(playbackStartBeat)")
        print("[PlaybackEngine] Scheduled MIDI events: \(scheduledMIDIEvents.count)")
        print("[PlaybackEngine] Loaded instruments: \(debugInstrumentList())")
        print("[PlaybackEngine] ========================================")
        
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
        hasLoggedPlaybackDebug = false

        // Clean up old audio player nodes first
        cleanupAudioPlayers()

        // IMPORTANT: Use the transport's captured start position
        // The transport captures this BEFORE the timer starts, ensuring perfect sync
        if let transport = transportState {
            playbackStartBeat = transport.playbackStartBeat
            print("[PlaybackEngine] Using transport's playbackStartBeat: \(playbackStartBeat)")
        }
        
        print("[PlaybackEngine] ========================================")
        print("[PlaybackEngine] Preparing playback for \(project.tracks.count) tracks")
        print("[PlaybackEngine] Loaded instruments: \(debugInstrumentList())")
        
        // List all track IDs for debugging
        for track in project.tracks {
            let hasInstrument = trackInstruments[track.id] != nil
            print("[PlaybackEngine] Track '\(track.name)' (ID: \(track.id.rawValue)) - instrument loaded: \(hasInstrument)")
        }
        print("[PlaybackEngine] ========================================")

        for track in project.tracks {
            // Skip muted tracks
            guard !track.isMuted else { continue }

            for clip in track.clips {
                guard !clip.isMuted else { continue }
                
                print("[PlaybackEngine] Processing clip '\(clip.name)' on track '\(track.name)' (ID: \(track.id.rawValue))")

                switch clip.content {
                case .midi(let midiData):
                    print("[PlaybackEngine] MIDI clip with \(midiData.events.count) events")
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
                event: event,
                midiOutput: track.midiOutput  // Capture the track's routing
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
        for i in 0..<scheduledMIDIEvents.count {
            // Skip already processed events
            guard !scheduledMIDIEvents[i].processed else { continue }
            
            // Skip events before the current window
            guard scheduledMIDIEvents[i].absoluteBeat >= lastProcessedBeat else { continue }

            // Stop if we're past the look-ahead window
            guard scheduledMIDIEvents[i].absoluteBeat < windowEnd else { break }

            // Process this event and mark as processed
            processEvent(scheduledMIDIEvents[i])
            scheduledMIDIEvents[i].processed = true
        }

        // Check for note-offs
        processNoteOffs(at: currentBeat)

        // Handle looping
        if transport.isLoopEnabled {
            let loopEndBeat = transport.loopEnd.beats(atTempo: transport.tempo.bpm)
            if currentBeat >= loopEndBeat {
                // Reset for loop - also reset processed flags
                lastProcessedBeat = transport.loopStart.beats(atTempo: transport.tempo.bpm)
                for i in 0..<scheduledMIDIEvents.count {
                    scheduledMIDIEvents[i].processed = false
                }
            }
        }

        lastProcessedBeat = currentBeat
    }
    
    private var hasLoggedPlaybackDebug = false
    
    private func processEvent(_ scheduled: ScheduledEvent) {
        // Determine the instrument and channel based on midiOutput routing
        let (instrument, channel): (TrackInstrument?, UInt8) = {
            switch scheduled.midiOutput {
            case .rackInstrument(let rackID, let ch):
                // Route to V-Rack instrument on specified channel (convert 1-16 to 0-15)
                return (rackInstruments[rackID], ch - 1)
            case .trackInstrument, .none:
                // Route to track's own instrument on channel 0
                return (trackInstruments[scheduled.trackID], 0)
            }
        }()
        
        guard let instrument = instrument else {
            if !hasLoggedPlaybackDebug {
                print("[PlaybackEngine] ⚠️ No instrument for track \(scheduled.trackID.rawValue)")
                print("[PlaybackEngine] Track instruments: \(debugInstrumentList())")
                print("[PlaybackEngine] Rack instruments: \(rackInstruments.count)")
                hasLoggedPlaybackDebug = true
            }
            return
        }
        
        switch scheduled.event.type {
        case .note(let noteData):
            // Play note on
            print("[PlaybackEngine] 🎵 Playing note \(noteData.pitch) vel:\(noteData.velocity) ch:\(channel) at beat \(scheduled.absoluteBeat)")
            instrument.startNote(noteData.pitch, velocity: noteData.velocity, channel: channel)
            
            // Schedule note off with routing info
            let noteEndBeat = scheduled.absoluteBeat + noteData.duration
            activeNotes.append(ActiveNote(
                trackID: scheduled.trackID,
                pitch: noteData.pitch,
                channel: channel,
                endBeat: noteEndBeat,
                midiOutput: scheduled.midiOutput
            ))
            
        case .controlChange(let controller, let value):
            instrument.sendController(controller, value: value, channel: channel)
            
        case .programChange(let program):
            instrument.sendProgramChange(program, channel: channel)
            
        case .pitchBend(let value):
            // Convert from signed to unsigned pitch bend
            let unsignedValue = UInt16(bitPattern: Int16(value + 8192))
            instrument.sendPitchBend(unsignedValue, channel: channel)
            
        default:
            break
        }
    }
    
    private func processNoteOffs(at currentBeat: Double) {
        let notesToStop = activeNotes.filter { $0.endBeat <= currentBeat }
        
        for note in notesToStop {
            // Use the same routing logic for note-offs
            let instrument: TrackInstrument? = {
                switch note.midiOutput {
                case .rackInstrument(let rackID, _):
                    return rackInstruments[rackID]
                case .trackInstrument, .none:
                    return trackInstruments[note.trackID]
                }
            }()
            
            if let instrument = instrument {
                instrument.stopNote(note.pitch, channel: note.channel)
            }
        }
        
        activeNotes.removeAll { $0.endBeat <= currentBeat }
    }
    
    private func stopAllNotes() {
        for (trackID, instrument) in trackInstruments {
            for note in activeNotes where note.trackID == trackID {
                instrument.stopNote(note.pitch, channel: note.channel)
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
        guard let instrument = trackInstruments[trackID] else { return }
        instrument.startNote(pitch, velocity: velocity, channel: 0)
    }
    
    /// Stop a preview note
    public func stopNotePreview(pitch: UInt8, on trackID: TrackID) {
        guard let instrument = trackInstruments[trackID] else { return }
        instrument.stopNote(pitch, channel: 0)
    }
    
    /// Play a test note to verify audio is working
    public func playTestNote(on trackID: TrackID) {
        guard let instrument = trackInstruments[trackID] else { return }
        
        // Middle C at medium velocity
        instrument.startNote(60, velocity: 100, channel: 0)
        
        // Stop after 0.5 seconds
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { [weak self] in
                self?.trackInstruments[trackID]?.stopNote(60, channel: 0)
            }
        }
    }
    
    // MARK: - Cleanup
    
    public func cleanup() {
        stopPlayback()
        
        // Detach all instruments
        for instrument in trackInstruments.values {
            audioEngine.engine.detach(instrument.audioNode)
        }
        trackInstruments.removeAll()
        
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
    let midiOutput: MIDIOutputDestination?  // Where to route this event
    var processed: Bool = false
}

private struct ActiveNote {
    let trackID: TrackID
    let pitch: UInt8
    let channel: UInt8
    let endBeat: Double
    let midiOutput: MIDIOutputDestination?  // For proper note-off routing
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
    case instrumentNotLoaded(TrackID)
    case soundBankLoadFailed(URL, Error)
    case audioFileLoadFailed(URL, Error)
    
    public var errorDescription: String? {
        switch self {
        case .trackNotFound(let id):
            return "Track not found: \(id.rawValue)"
        case .instrumentNotLoaded(let id):
            return "Instrument not loaded for track: \(id.rawValue)"
        case .soundBankLoadFailed(let url, let error):
            return "Failed to load sound bank at \(url): \(error.localizedDescription)"
        case .audioFileLoadFailed(let url, let error):
            return "Failed to load audio file at \(url): \(error.localizedDescription)"
        }
    }
}

// MARK: - Track Instrument

/// Represents an instrument on a track - either an AU instrument plugin or fallback sampler
public enum TrackInstrument {
    case auInstrument(AVAudioUnit, pluginID: UUID)
    case sampler(AVAudioUnitSampler)
    
    /// The underlying audio unit node
    public var audioNode: AVAudioNode {
        switch self {
        case .auInstrument(let au, _): return au
        case .sampler(let sampler): return sampler
        }
    }
    
    /// Send a MIDI note on event
    public func startNote(_ note: UInt8, velocity: UInt8, channel: UInt8) {
        switch self {
        case .auInstrument(let au, _):
            // Use MusicDeviceMIDIEvent - more universally compatible with AU instruments
            let status = UInt32(0x90 | (channel & 0x0F))
            let result = MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(note), UInt32(velocity), 0)
            if result == noErr {
                print("[TrackInstrument] Sent note ON via MusicDeviceMIDIEvent: \(note) vel:\(velocity)")
            } else {
                print("[TrackInstrument] MusicDeviceMIDIEvent failed (\(result)), trying scheduleMIDIEventBlock")
                // Fallback to scheduleMIDIEventBlock
                if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                    var noteOnData: [UInt8] = [0x90 | (channel & 0x0F), note, velocity]
                    noteOnData.withUnsafeMutableBufferPointer { buffer in
                        block(AUEventSampleTimeImmediate, 0, 3, buffer.baseAddress!)
                    }
                    print("[TrackInstrument] Sent note ON via scheduleMIDIEventBlock")
                }
            }
        case .sampler(let sampler):
            sampler.startNote(note, withVelocity: velocity, onChannel: channel)
            print("[TrackInstrument] Sent note ON via sampler")
        }
    }
    
    /// Send a MIDI note off event
    public func stopNote(_ note: UInt8, channel: UInt8) {
        switch self {
        case .auInstrument(let au, _):
            // Use MusicDeviceMIDIEvent - more universally compatible
            let status = UInt32(0x80 | (channel & 0x0F))
            let result = MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(note), 0, 0)
            if result != noErr {
                // Fallback to scheduleMIDIEventBlock
                if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                    var noteOffData: [UInt8] = [0x80 | (channel & 0x0F), note, 0]
                    noteOffData.withUnsafeMutableBufferPointer { buffer in
                        block(AUEventSampleTimeImmediate, 0, 3, buffer.baseAddress!)
                    }
                }
            }
        case .sampler(let sampler):
            sampler.stopNote(note, onChannel: channel)
        }
    }
    
    /// Send a control change
    public func sendController(_ controller: UInt8, value: UInt8, channel: UInt8) {
        switch self {
        case .auInstrument(let au, _):
            let status = UInt32(0xB0 | (channel & 0x0F))
            let result = MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(controller), UInt32(value), 0)
            if result != noErr {
                if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                    var ccData: [UInt8] = [0xB0 | (channel & 0x0F), controller, value]
                    ccData.withUnsafeMutableBufferPointer { buffer in
                        block(AUEventSampleTimeImmediate, 0, 3, buffer.baseAddress!)
                    }
                }
            }
        case .sampler(let sampler):
            sampler.sendController(controller, withValue: value, onChannel: channel)
        }
    }
    
    /// Send a program change
    public func sendProgramChange(_ program: UInt8, channel: UInt8) {
        switch self {
        case .auInstrument(let au, _):
            let status = UInt32(0xC0 | (channel & 0x0F))
            let result = MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(program), 0, 0)
            if result != noErr {
                if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                    var pgmData: [UInt8] = [0xC0 | (channel & 0x0F), program]
                    pgmData.withUnsafeMutableBufferPointer { buffer in
                        block(AUEventSampleTimeImmediate, 0, 2, buffer.baseAddress!)
                    }
                }
            }
        case .sampler(let sampler):
            sampler.sendProgramChange(program, onChannel: channel)
        }
    }

    /// Send pitch bend
    public func sendPitchBend(_ value: UInt16, channel: UInt8) {
        switch self {
        case .auInstrument(let au, _):
            let lsb = UInt8(value & 0x7F)
            let msb = UInt8((value >> 7) & 0x7F)
            let status = UInt32(0xE0 | (channel & 0x0F))
            let result = MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(lsb), UInt32(msb), 0)
            if result != noErr {
                if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                    var pbData: [UInt8] = [0xE0 | (channel & 0x0F), lsb, msb]
                    pbData.withUnsafeMutableBufferPointer { buffer in
                        block(AUEventSampleTimeImmediate, 0, 3, buffer.baseAddress!)
                    }
                }
            }
        case .sampler(let sampler):
            sampler.sendPitchBend(value, onChannel: channel)
        }
    }
}

