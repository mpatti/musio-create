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
    
    // Simple AVAudioPlayer-based playback for audio clips (fallback)
    private var audioPlayers: [ClipID: AVAudioPlayer] = [:]
    private var audioClipInfo: [ClipID: AudioClipPlaybackInfo] = [:]
    
    // Sample-accurate AVAudioPlayerNode instances for seamless looping
    private var sampleAccurateNodes: [TrackID: [AVAudioPlayerNode]] = [:]
    
    // Captured playback start position for sync
    private var playbackStartBeat: Double = 0
    private var playbackStartSample: Int64 = 0
    
    // Scheduled events for the current playback session
    private var scheduledMIDIEvents: [ScheduledEvent] = []
    private var activeNotes: [ActiveNote] = []
    
    // Last processed sample position (for tracking what's been played)
    private var lastProcessedSample: Int64 = 0
    
    // State
    @Published public private(set) var isPlaying: Bool = false
    
    // Thread-safe access to events (audio callback runs on audio thread)
    private let eventLock = NSLock()
    
    // Meter levels - published for UI consumption
    @Published public private(set) var trackMeterLevels: [TrackID: (left: Float, right: Float)] = [:]
    @Published public private(set) var masterMeterLevel: (left: Float, right: Float) = (0, 0)
    
    // Metering timer
    private var meteringTimer: Timer?
    private let meteringInterval: TimeInterval = 1.0 / 30.0  // 30fps meter updates
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        setupAudioCallback()
    }
    
    /// Set up the sample-accurate audio callback for MIDI timing
    private func setupAudioCallback() {
        // This callback is called from the audio thread every buffer
        // It's the ONLY place we should process time-critical MIDI events
        audioEngine.midiEventCallback = { [weak self] bufferStartSample, frameCount, tempo in
            self?.processAudioBuffer(startSample: bufferStartSample, frameCount: frameCount, tempo: tempo)
        }
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
        
        // Update audio engine tempo when transport tempo changes
        transportState.tempoSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tempo in
                self?.audioEngine.currentTempo = tempo.bpm
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
        
        // Calculate the starting sample position from beat position
        playbackStartBeat = transport.playbackStartBeat
        playbackStartSample = beatsToSamples(playbackStartBeat, tempo: transport.tempo.bpm)
        lastProcessedSample = playbackStartSample
        
        // Update audio engine tempo
        audioEngine.currentTempo = transport.tempo.bpm

        print("[PlaybackEngine] ========================================")
        print("[PlaybackEngine] Starting SAMPLE-ACCURATE playback")
        print("[PlaybackEngine] Start beat: \(playbackStartBeat)")
        print("[PlaybackEngine] Start sample: \(playbackStartSample)")
        print("[PlaybackEngine] Sample rate: \(audioEngine.sampleRate)")
        print("[PlaybackEngine] Buffer size: \(audioEngine.bufferSize) (~\(String(format: "%.1f", audioEngine.latencyMs))ms)")
        print("[PlaybackEngine] Scheduled MIDI events: \(scheduledMIDIEvents.count)")
        print("[PlaybackEngine] Loaded instruments: \(debugInstrumentList())")
        print("[PlaybackEngine] ========================================")
        
        // Start all scheduled audio player nodes
        startAllAudioPlayers()
        
        // Start metering (UI only, not timing-critical)
        startMetering()
        
        // Note: MIDI events are now processed in processAudioBuffer() 
        // which is called from the audio thread - no Timer needed!
    }
    
    /// Convert beats to samples
    private func beatsToSamples(_ beats: Double, tempo: Double) -> Int64 {
        let seconds = (beats / tempo) * 60.0
        return Int64(seconds * audioEngine.sampleRate)
    }
    
    /// Convert samples to beats
    private func samplesToBeats(_ samples: Int64, tempo: Double) -> Double {
        let seconds = Double(samples) / audioEngine.sampleRate
        return (seconds / 60.0) * tempo
    }
    
    /// Process MIDI events for the current audio buffer (called from audio thread)
    /// This is the heart of sample-accurate timing
    private func processAudioBuffer(startSample: Int64, frameCount: AVAudioFrameCount, tempo: Double) {
        guard isPlaying else { return }
        
        let bufferEndSample = startSample + Int64(frameCount)
        
        // Convert sample range to beat range
        let bufferStartBeat = samplesToBeats(startSample - playbackStartSample, tempo: tempo) + playbackStartBeat
        let bufferEndBeat = samplesToBeats(bufferEndSample - playbackStartSample, tempo: tempo) + playbackStartBeat
        
        // Process MIDI events that fall within this buffer's time window
        eventLock.lock()
        for i in 0..<scheduledMIDIEvents.count {
            guard !scheduledMIDIEvents[i].processed else { continue }
            
            let eventBeat = scheduledMIDIEvents[i].absoluteBeat
            
            // Skip events before our window
            guard eventBeat >= bufferStartBeat else { continue }
            
            // Stop if we're past the buffer window
            guard eventBeat < bufferEndBeat else { break }
            
            // Calculate the exact sample offset within this buffer
            let eventSampleOffset = beatsToSamples(eventBeat - bufferStartBeat, tempo: tempo)
            
            // Process the event
            processEventSampleAccurate(scheduledMIDIEvents[i], sampleOffset: eventSampleOffset)
            scheduledMIDIEvents[i].processed = true
        }
        eventLock.unlock()
        
        // Process note-offs
        processNoteOffsInBuffer(bufferStartBeat: bufferStartBeat, bufferEndBeat: bufferEndBeat, tempo: tempo)
        
        // Update last processed position
        lastProcessedSample = bufferEndSample
    }
    
    /// Process a single MIDI event with sample-accurate timing
    private func processEventSampleAccurate(_ scheduled: ScheduledEvent, sampleOffset: Int64) {
        // Determine the instrument and channel based on midiOutput routing
        let (instrument, channel): (TrackInstrument?, UInt8) = {
            switch scheduled.midiOutput {
            case .rackInstrument(let rackID, let ch):
                return (rackInstruments[rackID], ch - 1)
            case .trackInstrument, .none:
                return (trackInstruments[scheduled.trackID], 0)
            }
        }()
        
        guard let instrument = instrument else { return }
        
        switch scheduled.event.type {
        case .note(let noteData):
            // Send note with sample offset for precise timing
            instrument.startNoteSampleAccurate(
                noteData.pitch,
                velocity: noteData.velocity,
                channel: channel,
                sampleOffset: AUEventSampleTime(sampleOffset)
            )
            
            // Track active note for note-off
            let noteEndBeat = scheduled.absoluteBeat + noteData.duration
            eventLock.lock()
            activeNotes.append(ActiveNote(
                trackID: scheduled.trackID,
                pitch: noteData.pitch,
                channel: channel,
                endBeat: noteEndBeat,
                midiOutput: scheduled.midiOutput
            ))
            eventLock.unlock()
            
        case .controlChange(let controller, let value):
            instrument.sendController(controller, value: value, channel: channel)
            
        case .programChange(let program):
            instrument.sendProgramChange(program, channel: channel)
            
        case .pitchBend(let value):
            let unsignedValue = UInt16(bitPattern: Int16(value + 8192))
            instrument.sendPitchBend(unsignedValue, channel: channel)
            
        default:
            break
        }
    }
    
    /// Process note-offs that fall within the buffer
    private func processNoteOffsInBuffer(bufferStartBeat: Double, bufferEndBeat: Double, tempo: Double) {
        eventLock.lock()
        let notesToStop = activeNotes.filter { $0.endBeat >= bufferStartBeat && $0.endBeat < bufferEndBeat }
        eventLock.unlock()
        
        for note in notesToStop {
            let instrument: TrackInstrument? = {
                switch note.midiOutput {
                case .rackInstrument(let rackID, _):
                    return rackInstruments[rackID]
                case .trackInstrument, .none:
                    return trackInstruments[note.trackID]
                }
            }()
            
            if let instrument = instrument {
                // Calculate sample offset for the note-off
                let noteOffSampleOffset = beatsToSamples(note.endBeat - bufferStartBeat, tempo: tempo)
                instrument.stopNoteSampleAccurate(note.pitch, channel: note.channel, sampleOffset: AUEventSampleTime(noteOffSampleOffset))
            }
        }
        
        eventLock.lock()
        activeNotes.removeAll { $0.endBeat < bufferEndBeat }
        eventLock.unlock()
    }
    
    /// Start all audio clips using AVAudioPlayer with high-precision timing
    /// Uses a unified start approach to minimize gaps between clips
    private func startAllAudioPlayers() {
        guard let transport = transportState else { 
            print("[PlaybackEngine] No transport state")
            return 
        }
        
        // Use the captured start beat for consistent timing
        let currentBeat = playbackStartBeat
        let tempo = transport.tempo.bpm
        
        print("[PlaybackEngine] Starting audio players at beat \(currentBeat), \(audioPlayers.count) clips")
        
        // Calculate all clip start times relative to a common reference point
        var scheduledStarts: [(ClipID, AVAudioPlayer, TimeInterval, TimeInterval)] = []  // (id, player, delay, offset)
        
        for (clipID, player) in audioPlayers {
            guard let info = audioClipInfo[clipID] else { continue }
            
            if currentBeat >= info.clipStartBeat && currentBeat < info.clipEndBeat {
                // Playhead is within this clip - start immediately with offset
                let offsetBeats = currentBeat - info.clipStartBeat
                let offsetSeconds = offsetBeats * 60.0 / tempo
                scheduledStarts.append((clipID, player, 0, offsetSeconds))
                
            } else if currentBeat < info.clipStartBeat {
                // Clip starts in the future
                let delayBeats = info.clipStartBeat - currentBeat
                let delaySeconds = delayBeats * 60.0 / tempo
                scheduledStarts.append((clipID, player, delaySeconds, 0))
            }
        }
        
        // Sort by delay time so we process immediate clips first
        scheduledStarts.sort { $0.2 < $1.2 }
        
        // Start all clips - use simple play() for immediate, play(atTime:) for future
        for (clipID, player, delay, offset) in scheduledStarts {
            player.currentTime = offset
            
            if delay <= 0.01 {
                // Start immediately with simple play()
                player.play()
                print("[PlaybackEngine] Started clip \(clipID) immediately at offset \(offset)s")
            } else {
                // Schedule for future - capture device time right before scheduling
                let deviceTime = player.deviceCurrentTime
                player.play(atTime: deviceTime + delay)
                print("[PlaybackEngine] Scheduled clip \(clipID) to play in \(delay)s")
            }
        }
    }
    
    public func stopPlayback() {
        isPlaying = false

        // Stop metering
        stopMetering()

        // Stop all active notes
        stopAllNotes()

        // Stop all audio players
        stopAllAudioPlayers()

        // Clear scheduled events
        eventLock.lock()
        scheduledMIDIEvents.removeAll()
        activeNotes.removeAll()
        eventLock.unlock()
        
        print("[PlaybackEngine] Stopped playback at sample \(lastProcessedSample)")
    }
    
    public func pausePlayback() {
        isPlaying = false
        
        // Note: We don't stop notes on pause - they'll continue until their natural end
        // This matches DAW behavior where pausing doesn't cut notes off
    }
    
    // MARK: - Event Scheduling
    
    /// Prepare all clips for playback
    public func prepareForPlayback(project: Project) {
        eventLock.lock()
        scheduledMIDIEvents.removeAll()
        activeNotes.removeAll()
        eventLock.unlock()
        
        hasLoggedPlaybackDebug = false

        // Clean up old audio player nodes first
        cleanupAudioPlayers()

        // IMPORTANT: Use the transport's captured start position
        if let transport = transportState {
            playbackStartBeat = transport.playbackStartBeat
            playbackStartSample = beatsToSamples(playbackStartBeat, tempo: transport.tempo.bpm)
            lastProcessedSample = playbackStartSample
            print("[PlaybackEngine] Using transport's playbackStartBeat: \(playbackStartBeat) (sample: \(playbackStartSample))")
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
                    
                case .empty:
                    // Empty/placeholder clip - skip
                    break
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

        // Clean up sample-accurate player nodes
        for (_, nodes) in sampleAccurateNodes {
            for node in nodes {
                node.stop()
                if node.engine != nil {
                    audioEngine.engine.disconnectNodeOutput(node)
                    audioEngine.engine.detach(node)
                }
            }
        }
        sampleAccurateNodes.removeAll()

        // Clean up AVAudioPlayer instances (fallback)
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
            player.isMeteringEnabled = true  // Enable metering for level display
            
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
    
    // MARK: - Playback Processing (Legacy methods removed - now using sample-accurate audio callback)
    
    private var hasLoggedPlaybackDebug = false
    
    /// Stop audio clips that have passed their end beat
    private func processAudioClipEndings(at currentBeat: Double) {
        var clipsToStop: [ClipID] = []
        
        for (clipID, info) in audioClipInfo {
            // Check if playhead has passed the clip's end beat
            if currentBeat >= info.clipEndBeat {
                // Only stop if the player is still playing
                if let player = audioPlayers[clipID], player.isPlaying {
                    player.stop()
                    clipsToStop.append(clipID)
                    print("[PlaybackEngine] Stopped audio clip \(clipID) at beat \(currentBeat) (end beat: \(info.clipEndBeat))")
                }
            }
        }
        
        // Remove stopped clips from tracking
        for clipID in clipsToStop {
            audioPlayers.removeValue(forKey: clipID)
            audioClipInfo.removeValue(forKey: clipID)
        }
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
        
        // Stop sample-accurate player nodes
        for (_, nodes) in sampleAccurateNodes {
            for node in nodes {
                node.stop()
            }
        }
        
        // Stop AVAudioPlayer instances (fallback)
        for (clipID, player) in audioPlayers {
            player.stop()
            print("[PlaybackEngine] Stopped AVAudioPlayer for clip \(clipID)")
        }
    }
    
    // MARK: - Real-time Volume Control
    
    /// Update volume for all audio clips on a track in real-time
    public func updateTrackVolume(_ trackID: TrackID, volume: Float) {
        for (clipID, info) in audioClipInfo {
            if info.trackID == trackID {
                if let player = audioPlayers[clipID] {
                    player.volume = volume
                }
            }
        }
    }
    
    // MARK: - Metering
    
    private func startMetering() {
        meteringTimer?.invalidate()
        meteringTimer = Timer.scheduledTimer(withTimeInterval: meteringInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMeterLevels()
            }
        }
    }
    
    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        
        // Reset all levels to zero
        trackMeterLevels.removeAll()
        masterMeterLevel = (0, 0)
    }
    
    private func updateMeterLevels() {
        var newTrackLevels: [TrackID: (left: Float, right: Float)] = [:]
        var masterLeft: Float = 0
        var masterRight: Float = 0
        
        for (clipID, player) in audioPlayers {
            guard player.isPlaying else { continue }
            
            // Update meters
            player.updateMeters()
            
            // Get power levels (in dB, typically -160 to 0)
            let leftPower = player.averagePower(forChannel: 0)
            let rightPower = player.numberOfChannels > 1 ? player.averagePower(forChannel: 1) : leftPower
            
            // Convert dB to linear (0-1 range)
            let leftLevel = normalizedLevel(fromDecibels: leftPower)
            let rightLevel = normalizedLevel(fromDecibels: rightPower)
            
            // Get track ID for this clip
            if let info = audioClipInfo[clipID] {
                let trackID = info.trackID
                
                // Accumulate levels per track (take max if multiple clips)
                if let existing = newTrackLevels[trackID] {
                    newTrackLevels[trackID] = (
                        left: max(existing.left, leftLevel),
                        right: max(existing.right, rightLevel)
                    )
                } else {
                    newTrackLevels[trackID] = (left: leftLevel, right: rightLevel)
                }
                
                // Accumulate for master
                masterLeft = max(masterLeft, leftLevel)
                masterRight = max(masterRight, rightLevel)
            }
        }
        
        trackMeterLevels = newTrackLevels
        masterMeterLevel = (masterLeft, masterRight)
    }
    
    /// Convert decibels to normalized 0-1 level
    private func normalizedLevel(fromDecibels dB: Float) -> Float {
        // dB range is typically -160 to 0, map to 0-1
        // Use -60 dB as effective floor for display
        let minDB: Float = -60
        let maxDB: Float = 0
        
        if dB <= minDB { return 0 }
        if dB >= maxDB { return 1 }
        
        return (dB - minDB) / (maxDB - minDB)
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
    
    /// Send a MIDI note on event (immediate - for preview/live playing)
    public func startNote(_ note: UInt8, velocity: UInt8, channel: UInt8) {
        startNoteSampleAccurate(note, velocity: velocity, channel: channel, sampleOffset: AUEventSampleTimeImmediate)
    }
    
    /// Send a MIDI note on event with sample-accurate timing
    public func startNoteSampleAccurate(_ note: UInt8, velocity: UInt8, channel: UInt8, sampleOffset: AUEventSampleTime) {
        switch self {
        case .auInstrument(let au, _):
            // Prefer scheduleMIDIEventBlock for sample-accurate timing
            if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                var noteOnData: [UInt8] = [0x90 | (channel & 0x0F), note, velocity]
                noteOnData.withUnsafeMutableBufferPointer { buffer in
                    block(sampleOffset, 0, 3, buffer.baseAddress!)
                }
            } else {
                // Fallback to MusicDeviceMIDIEvent (not sample-accurate)
                let status = UInt32(0x90 | (channel & 0x0F))
                MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(note), UInt32(velocity), 0)
            }
        case .sampler(let sampler):
            sampler.startNote(note, withVelocity: velocity, onChannel: channel)
        }
    }
    
    /// Send a MIDI note off event (immediate)
    public func stopNote(_ note: UInt8, channel: UInt8) {
        stopNoteSampleAccurate(note, channel: channel, sampleOffset: AUEventSampleTimeImmediate)
    }
    
    /// Send a MIDI note off event with sample-accurate timing
    public func stopNoteSampleAccurate(_ note: UInt8, channel: UInt8, sampleOffset: AUEventSampleTime) {
        switch self {
        case .auInstrument(let au, _):
            // Prefer scheduleMIDIEventBlock for sample-accurate timing
            if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                var noteOffData: [UInt8] = [0x80 | (channel & 0x0F), note, 0]
                noteOffData.withUnsafeMutableBufferPointer { buffer in
                    block(sampleOffset, 0, 3, buffer.baseAddress!)
                }
            } else {
                // Fallback to MusicDeviceMIDIEvent (not sample-accurate)
                let status = UInt32(0x80 | (channel & 0x0F))
                MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(note), 0, 0)
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

