import Foundation
import AVFoundation
import Combine

// MARK: - MIDI Sequencer

/// Handles MIDI playback scheduling and real-time event processing
@MainActor
public final class MIDISequencer: ObservableObject {
    
    // MARK: - Properties
    
    private let audioEngine: AudioEngine
    private weak var transportState: TransportState?
    
    // Playback state
    private var isPlaying: Bool = false
    private var currentBeat: Double = 0
    private var lastUpdateTime: Date?
    
    // Scheduled events
    private var scheduledEvents: [ScheduledMIDIEvent] = []
    private var activeNotes: [ActiveNote] = []
    
    // Timer for sequencer updates
    private var updateTimer: Timer?
    private let updateInterval: TimeInterval = 0.005  // 5ms resolution
    
    // Look-ahead for scheduling (in seconds)
    private let lookAheadTime: TimeInterval = 0.1
    
    // Combine
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }
    
    // MARK: - Transport Binding
    
    public func bind(to transportState: TransportState) {
        self.transportState = transportState
        
        // Subscribe to transport events
        transportState.transportEventSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                Task { @MainActor in
                    self?.handleTransportEvent(event)
                }
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
    
    // MARK: - Playback Control
    
    public func startPlayback() {
        guard let transport = transportState else { return }
        
        isPlaying = true
        currentBeat = transport.playheadBeats
        lastUpdateTime = Date()
        
        // Start update timer
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: updateInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateSequencer()
            }
        }
        
        RunLoop.main.add(updateTimer!, forMode: .common)
    }
    
    public func stopPlayback() {
        isPlaying = false
        updateTimer?.invalidate()
        updateTimer = nil
        
        // Stop all active notes
        stopAllNotes()
        
        // Clear scheduled events
        scheduledEvents.removeAll()
    }
    
    public func pausePlayback() {
        isPlaying = false
        updateTimer?.invalidate()
        updateTimer = nil
        
        // Keep active notes sounding (will be stopped on full stop)
    }
    
    // MARK: - Event Scheduling
    
    /// Schedule MIDI events for playback
    public func scheduleEvents(
        from clips: [Clip],
        trackSamplers: [TrackID: AVAudioUnitSampler]
    ) {
        scheduledEvents.removeAll()
        
        for clip in clips {
            guard case .midi(let midiData) = clip.content else { continue }
            guard !clip.isMuted else { continue }
            
            let clipStartBeat = clip.timeRange.start.beats(
                atTempo: transportState?.tempo.bpm ?? 120
            )
            
            for event in midiData.events {
                // Calculate absolute beat position
                let absoluteBeat = clipStartBeat + event.beatPosition
                
                // Get the track's sampler (we'll need track ID from somewhere)
                // For now, use first available sampler
                
                let scheduled = ScheduledMIDIEvent(
                    event: event,
                    absoluteBeat: absoluteBeat,
                    clipID: clip.id
                )
                
                scheduledEvents.append(scheduled)
            }
        }
        
        // Sort by beat position
        scheduledEvents.sort { $0.absoluteBeat < $1.absoluteBeat }
    }
    
    /// Schedule events for a specific track
    public func scheduleTrackEvents(
        track: Track,
        sampler: AVAudioUnitSampler
    ) {
        for clip in track.clips {
            guard case .midi(let midiData) = clip.content else { continue }
            guard !clip.isMuted else { continue }
            
            let clipStartBeat = clip.timeRange.start.beats(
                atTempo: transportState?.tempo.bpm ?? 120
            )
            
            for event in midiData.events {
                let absoluteBeat = clipStartBeat + event.beatPosition
                
                let scheduled = ScheduledMIDIEvent(
                    event: event,
                    absoluteBeat: absoluteBeat,
                    clipID: clip.id,
                    trackID: track.id,
                    sampler: sampler
                )
                
                scheduledEvents.append(scheduled)
            }
        }
        
        scheduledEvents.sort { $0.absoluteBeat < $1.absoluteBeat }
    }
    
    // MARK: - Sequencer Update
    
    private func updateSequencer() {
        guard isPlaying, let transport = transportState else { return }
        
        let now = Date()
        guard let lastTime = lastUpdateTime else {
            lastUpdateTime = now
            return
        }
        
        // Calculate elapsed time and advance playhead
        let elapsedSeconds = now.timeIntervalSince(lastTime)
        let elapsedBeats = (elapsedSeconds / 60.0) * transport.tempo.bpm
        
        let previousBeat = currentBeat
        currentBeat += elapsedBeats
        
        // Handle looping
        if transport.isLoopEnabled {
            let loopEndBeat = transport.loopEnd.beats(atTempo: transport.tempo.bpm)
            let loopStartBeat = transport.loopStart.beats(atTempo: transport.tempo.bpm)
            
            if currentBeat >= loopEndBeat {
                currentBeat = loopStartBeat + (currentBeat - loopEndBeat)
                // Re-schedule events for next loop iteration
            }
        }
        
        // Update transport
        transport.setPlayheadBeats(currentBeat)
        
        // Calculate look-ahead window
        let lookAheadBeats = (lookAheadTime / 60.0) * transport.tempo.bpm
        let windowEnd = currentBeat + lookAheadBeats
        
        // Process events in window
        processEvents(from: previousBeat, to: windowEnd)
        
        // Update active notes (check for note-offs)
        updateActiveNotes()
        
        lastUpdateTime = now
    }
    
    private func processEvents(from startBeat: Double, to endBeat: Double) {
        for scheduled in scheduledEvents {
            guard scheduled.absoluteBeat >= startBeat && scheduled.absoluteBeat < endBeat else {
                continue
            }
            
            guard !scheduled.processed else { continue }
            
            playEvent(scheduled)
        }
    }
    
    private func playEvent(_ scheduled: ScheduledMIDIEvent) {
        guard let sampler = scheduled.sampler else { return }
        
        switch scheduled.event.type {
        case .note(let noteData):
            // Play note on
            sampler.startNote(
                noteData.pitch,
                withVelocity: noteData.velocity,
                onChannel: scheduled.event.channel
            )
            
            // Track active note for note-off
            let noteEndBeat = scheduled.absoluteBeat + noteData.duration
            activeNotes.append(ActiveNote(
                pitch: noteData.pitch,
                channel: scheduled.event.channel,
                endBeat: noteEndBeat,
                sampler: sampler
            ))
            
        case .controlChange(let controller, let value):
            sampler.sendController(controller, withValue: value, onChannel: scheduled.event.channel)
            
        case .programChange(let program):
            sampler.sendProgramChange(program, onChannel: scheduled.event.channel)
            
        case .pitchBend(let value):
            let normalizedValue = UInt8(((Int(value) + 8192) >> 7) & 0x7F)
            sampler.sendPitchBend(UInt16(normalizedValue) << 7, onChannel: scheduled.event.channel)
            
        default:
            break
        }
        
        // Mark as processed (for non-looping scenarios)
        // In a real implementation, we'd handle this differently for loops
    }
    
    private func updateActiveNotes() {
        let now = currentBeat
        
        // Find notes that need to be stopped
        let notesToStop = activeNotes.filter { $0.endBeat <= now }
        
        for note in notesToStop {
            note.sampler.stopNote(note.pitch, onChannel: note.channel)
        }
        
        // Remove stopped notes
        activeNotes.removeAll { $0.endBeat <= now }
    }
    
    private func stopAllNotes() {
        for note in activeNotes {
            note.sampler.stopNote(note.pitch, onChannel: note.channel)
        }
        activeNotes.removeAll()
    }
    
    // MARK: - Real-time Playback
    
    /// Play a note immediately (for preview/input)
    public func playNoteNow(
        pitch: UInt8,
        velocity: UInt8,
        channel: UInt8 = 0,
        sampler: AVAudioUnitSampler
    ) {
        sampler.startNote(pitch, withVelocity: velocity, onChannel: channel)
    }
    
    /// Stop a note immediately
    public func stopNoteNow(
        pitch: UInt8,
        channel: UInt8 = 0,
        sampler: AVAudioUnitSampler
    ) {
        sampler.stopNote(pitch, onChannel: channel)
    }
    
    /// Play a test note (for debugging/testing)
    public func playTestNote(sampler: AVAudioUnitSampler) {
        // Middle C, medium velocity
        sampler.startNote(60, withVelocity: 100, onChannel: 0)
        
        // Stop after 0.5 seconds
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                sampler.stopNote(60, onChannel: 0)
            }
        }
    }
}

// MARK: - Scheduled MIDI Event

private struct ScheduledMIDIEvent {
    let event: MIDIEvent
    let absoluteBeat: Double
    let clipID: ClipID
    var trackID: TrackID?
    var sampler: AVAudioUnitSampler?
    var processed: Bool = false
}

// MARK: - Active Note

private struct ActiveNote {
    let pitch: UInt8
    let channel: UInt8
    let endBeat: Double
    let sampler: AVAudioUnitSampler
}

// MARK: - MIDI Recording

/// Handles recording incoming MIDI events
public final class MIDIRecorder {
    
    // MARK: - Properties
    
    private var isRecording: Bool = false
    private var recordedEvents: [MIDIEvent] = []
    private var recordStartBeat: Double = 0
    private var pendingNotes: [UInt8: (startBeat: Double, velocity: UInt8)] = [:]  // Note -> (start, velocity)
    
    // MARK: - Recording Control
    
    public func startRecording(at beat: Double) {
        isRecording = true
        recordStartBeat = beat
        recordedEvents.removeAll()
        pendingNotes.removeAll()
    }
    
    public func stopRecording() -> [MIDIEvent] {
        isRecording = false
        
        // Close any pending notes
        // (This would need the current beat position)
        
        let events = recordedEvents
        recordedEvents.removeAll()
        pendingNotes.removeAll()
        
        return events
    }
    
    public func recordEvent(_ event: IncomingMIDIEvent, currentBeat: Double) {
        guard isRecording else { return }
        
        let relativeBeat = currentBeat - recordStartBeat
        
        switch event.type {
        case .note(let noteData):
            if noteData.velocity > 0 {
                // Note on - store pending note
                pendingNotes[noteData.pitch] = (startBeat: relativeBeat, velocity: noteData.velocity)
            } else {
                // Note off - create completed note event
                if let pending = pendingNotes.removeValue(forKey: noteData.pitch) {
                    let duration = relativeBeat - pending.startBeat
                    let completedNote = MIDIEvent.note(
                        at: pending.startBeat,
                        pitch: noteData.pitch,
                        velocity: pending.velocity,
                        duration: max(0.01, duration),
                        channel: event.channel
                    )
                    recordedEvents.append(completedNote)
                }
            }
            
        default:
            // Record other events directly
            let midiEvent = event.toMIDIEvent(beatPosition: relativeBeat)
            recordedEvents.append(midiEvent)
        }
    }
}
