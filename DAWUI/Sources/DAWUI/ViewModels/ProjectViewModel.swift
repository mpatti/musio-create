import Foundation
import SwiftUI
import Combine
import AVFoundation
import DAWCore

// MARK: - Project View Model

/// Main view model coordinating all DAW state and operations
@MainActor
public final class ProjectViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published public var project: Project
    @Published public private(set) var selectedTrackID: TrackID?
    @Published public private(set) var selectedClipIDs: Set<ClipID> = []
    @Published public private(set) var isModified: Bool = false
    
    // Timeline state
    @Published public var zoomLevel: Double = 1.0
    @Published public var scrollOffset: CGPoint = .zero
    @Published public var pixelsPerBeat: Double = 40.0
    
    // UI state
    @Published public var showMixer: Bool = true
    @Published public var showInspector: Bool = true
    @Published public var showPianoRoll: Bool = false
    @Published public var editingClipID: ClipID?
    @Published public var editingTrackID: TrackID?

    // Recording state
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var recordingTrackID: TrackID?
    @Published public private(set) var recordingStartBeat: Double = 0
    
    // Playback state
    @Published public private(set) var isEngineReady: Bool = false
    
    // MARK: - Subsystems
    
    public let transportState: TransportState
    public let audioEngine: AudioEngine
    public let playbackEngine: PlaybackEngine
    public let midiManager: MIDIManager
    public let midiSequencer: MIDISequencer
    public let pluginHost: PluginHost
    public let undoManager: DAWUndoManager
    public let audioRecorder: AudioRecorder
    public let midiRecorder: MIDIRecorderManager
    public let selectionManager: SelectionManager
    public let metronome: Metronome
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    private var projectURL: URL?
    
    // MARK: - Initialization
    
    public init(project: Project = ProjectFactory.createNewProject()) {
        self.project = project
        self.transportState = TransportState()
        self.audioEngine = AudioEngine()
        self.playbackEngine = PlaybackEngine(audioEngine: audioEngine)
        self.midiManager = MIDIManager()
        self.midiSequencer = MIDISequencer(audioEngine: audioEngine)
        self.pluginHost = PluginHost()
        self.undoManager = DAWUndoManager()
        self.metronome = Metronome()
        self.audioRecorder = AudioRecorder(audioEngine: audioEngine)
        self.midiRecorder = MIDIRecorderManager(midiManager: midiManager)
        self.selectionManager = SelectionManager()
        
        setupBindings()
        setupAudioEngine()
        
        // Setup MIDI asynchronously
        Task {
            await setupMIDI()
        }
    }
    
    // MARK: - Setup
    
    private func setupBindings() {
        // Sync transport sample rate with project
        transportState.sampleRate = project.sampleRate
        transportState.tempo = project.tempo
        transportState.timeSignature = project.timeSignature
        
        // CRITICAL: Bind transport to audio engine for sample-accurate timing
        transportState.bind(to: audioEngine)
        
        // Bind other subsystems to transport
        midiSequencer.bind(to: transportState)
        playbackEngine.bind(to: transportState)
        midiRecorder.bind(to: transportState)
        metronome.bind(to: transportState)
        
        // Track project modifications
        $project
            .dropFirst()
            .sink { [weak self] _ in
                self?.isModified = true
            }
            .store(in: &cancellables)
        
        // Listen for undo state changes
        undoManager.stateDidChange
            .sink { [weak self] in
                self?.isModified = self?.undoManager.canUndo ?? false
            }
            .store(in: &cancellables)
        
        // Listen for transport record start
        transportState.transportEventSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleTransportEvent(event)
            }
            .store(in: &cancellables)
        
        // Setup live MIDI playthrough to armed track instruments
        setupLiveMIDIPlaythrough()
    }
    
    // MARK: - Live MIDI Playthrough
    
    /// MIDI activity indicator - pulses when MIDI is received
    @Published public var midiActivity: Bool = false
    private var midiActivityTimer: Timer?
    
    private func setupLiveMIDIPlaythrough() {
        midiManager.midiEventSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleLiveMIDIEvent(event)
            }
            .store(in: &cancellables)
    }
    
    private func handleLiveMIDIEvent(_ event: IncomingMIDIEvent) {
        // Show MIDI activity
        midiActivity = true
        midiActivityTimer?.invalidate()
        midiActivityTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.midiActivity = false
            }
        }
        
        // Find armed MIDI/instrument tracks and send MIDI to their instruments
        let armedTracks = project.tracks.filter { $0.isArmed && ($0.type == .midi || $0.type == .instrument) }
        
        if armedTracks.isEmpty {
            print("[MIDI] No armed MIDI tracks found")
        }
        
        for track in armedTracks {
            print("[MIDI] Routing to track: \(track.name), has instrument slot: \(track.instrumentSlot != nil)")
            routeMIDIToInstrument(event, trackID: track.id)
        }
    }
    
    private var hasLoggedDebug = false
    
    private func routeMIDIToInstrument(_ event: IncomingMIDIEvent, trackID: TrackID) {
        guard let track = project.track(withID: trackID) else { return }
        
        // Determine the MIDI destination and channel
        let (instrument, channel): (TrackInstrument?, UInt8) = {
            switch track.midiOutput {
            case .rackInstrument(let rackID, let ch):
                // Route to V-Rack instrument on specified channel
                return (playbackEngine.rackInstrument(for: rackID), ch - 1)  // Convert 1-16 to 0-15
            case .trackInstrument, .none:
                // Route to track's own instrument on channel 0
                return (playbackEngine.instrument(for: trackID), 0)
            }
        }()
        
        guard let instrument = instrument else {
            print("[MIDI Playthrough] No instrument loaded for track \(track.name)")
            return
        }
        
        // Log audio path debug info once
        if !hasLoggedDebug {
            playbackEngine.debugAudioPath(for: trackID)
            hasLoggedDebug = true
        }
        
        switch event.type {
        case .note(let noteData):
            // Note: Some keyboards send velocity=1 for note-off instead of 0
            let isNoteOff = noteData.velocity == 0 || noteData.velocity == 1
            
            if !isNoteOff {
                instrument.startNote(noteData.pitch, velocity: noteData.velocity, channel: channel)
                print("[MIDI Playthrough] ✓ Note ON sent: \(noteData.pitch) vel:\(noteData.velocity) ch:\(channel)")
            } else {
                instrument.stopNote(noteData.pitch, channel: channel)
                print("[MIDI Playthrough] ✓ Note OFF sent: \(noteData.pitch) ch:\(channel)")
            }
            
        case .controlChange(let controller, let value):
            instrument.sendController(controller, value: value, channel: channel)
            print("[MIDI Playthrough] CC \(controller) = \(value) ch:\(channel)")
            
        case .programChange(let program):
            instrument.sendProgramChange(program, channel: channel)
            
        case .pitchBend(let value):
            let unsignedValue = UInt16(bitPattern: Int16(value + 8192))
            instrument.sendPitchBend(unsignedValue, channel: channel)
            
        default:
            break
        }
    }
    
    private func setupAudioEngine() {
        Task {
            do {
                print("Starting audio engine...")
                try audioEngine.start()
                print("Audio engine started successfully. Running: \(audioEngine.engine.isRunning)")
                print("Sample rate: \(audioEngine.sampleRate)")
                
                // Create audio nodes for existing tracks
                for track in project.tracks {
                    try audioEngine.createTrackNode(for: track)
                    print("Created audio node for track: \(track.name)")
                    
                    // Setup samplers for MIDI tracks
                    if track.type == .midi || track.type == .instrument {
                        try await playbackEngine.setupMIDITrack(track)
                    }
                }
                
                isEngineReady = true
                print("Audio engine setup complete")
            } catch {
                print("Failed to start audio engine: \(error)")
            }
        }
    }
    
    public func setupMIDI() async {
        do {
            try midiManager.setup()
            midiManager.reconnectSelectedInput()
            print("MIDI setup complete. \(midiManager.inputDevices.count) input devices found.")
            for device in midiManager.inputDevices {
                print("  - \(device.name) (\(device.manufacturer))")
            }
        } catch {
            print("Failed to setup MIDI: \(error)")
        }
    }
    
    private func handleTransportEvent(_ event: TransportEvent) {
        switch event {
        case .record:
            startRecording()
        case .stopRecording:
            stopRecording()
        case .play:
            prepareForPlayback()
            playbackEngine.startPlayback()
        case .stop:
            playbackEngine.stopPlayback()
            // Also stop recording if in progress
            if isRecording {
                stopRecording()
            }
        case .pause:
            playbackEngine.stopPlayback()
        default:
            break
        }
    }
    
    // MARK: - Playback Preparation
    
    private func prepareForPlayback() {
        playbackEngine.prepareForPlayback(project: project)
    }
    
    // MARK: - Track Operations
    
    public func addTrack(type: TrackType, name: String? = nil) {
        // Count existing tracks of the same type to determine the number
        let sameTypeCount = project.tracks.filter { $0.type == type }.count
        let trackName = name ?? "\(type.rawValue.capitalized) \(sameTypeCount + 1)"
        var track = Track(name: trackName, type: type)
        
        // Assign a color
        let colors = TrackColor.allCases
        track.color = colors[project.tracks.count % colors.count]
        
        let action = AddTrackAction(track: track)
        undoManager.registerAction(action, project: &project)
        
        // Create audio node
        do {
            try audioEngine.createTrackNode(for: track)
        } catch {
            print("Failed to create track node: \(error)")
        }
        
        selectedTrackID = track.id
    }
    
    // MARK: - Clip Management
    
    /// Create a new MIDI clip on a track
    public func createMIDIClip(on trackID: TrackID, at position: TimePosition, duration: Double) {
        guard var track = project.track(withID: trackID) else { return }
        
        let clipNumber = track.clips.count + 1
        let endPosition = TimePosition(
            samples: position.samples + Int64(duration * project.sampleRate),
            sampleRate: project.sampleRate
        )
        
        let midiData = MIDIClipData(events: [], originalTempo: project.tempo.bpm)
        
        var clip = Clip(
            name: "MIDI \(clipNumber)",
            timeRange: TimeRange(start: position, end: endPosition),
            content: .midi(midiData)
        )
        clip.color = track.color
        
        track.clips.append(clip)
        updateTrack(track, description: "Create MIDI Clip")
        
        // Select the new clip
        selectedClipIDs = [clip.id]
    }
    
    /// Create a new audio clip on a track  
    public func createAudioClip(on trackID: TrackID, at position: TimePosition, audioFileRef: AudioFileReference) {
        guard var track = project.track(withID: trackID) else { return }
        
        let endPosition = TimePosition(
            samples: position.samples + audioFileRef.lengthInSamples,
            sampleRate: project.sampleRate
        )
        
        let audioData = AudioClipData(
            fileReference: audioFileRef,
            sourceStartSample: 0,
            sourceLengthSamples: audioFileRef.lengthInSamples
        )
        
        var clip = Clip(
            name: audioFileRef.originalPath.components(separatedBy: "/").last ?? "Audio",
            timeRange: TimeRange(start: position, end: endPosition),
            content: .audio(audioData)
        )
        clip.color = track.color
        
        track.clips.append(clip)
        updateTrack(track, description: "Create Audio Clip")
        
        selectedClipIDs = [clip.id]
    }
    
    public func deleteTrack(id: TrackID) {
        guard project.tracks.contains(where: { $0.id == id }) else { return }
        
        let action = RemoveTrackAction(from: project, trackID: id)
        undoManager.registerAction(action, project: &project)
        
        audioEngine.removeTrackNode(for: id)
        
        if selectedTrackID == id {
            selectedTrackID = project.tracks.first?.id
        }
    }
    
    public func updateTrack(_ track: Track, description: String = "Modify Track") {
        guard let oldTrack = project.track(withID: track.id) else { return }
        
        let action = ModifyTrackAction(
            trackID: track.id,
            old: oldTrack,
            new: track,
            description: description
        )
        undoManager.registerAction(action, project: &project)
        
        // Update audio engine
        audioEngine.updateTrackParameters(for: track)
    }
    
    public func selectTrack(_ id: TrackID?) {
        selectedTrackID = id
        
        // Auto-arm MIDI/Instrument tracks when selected (and disarm others)
        if let selectedID = id {
            for track in project.tracks {
                if track.type == .midi || track.type == .instrument {
                    var updatedTrack = track
                    let shouldBeArmed = track.id == selectedID
                    if updatedTrack.isArmed != shouldBeArmed {
                        updatedTrack.isArmed = shouldBeArmed
                        // Update without undo (just UI state)
                        if let index = project.tracks.firstIndex(where: { $0.id == track.id }) {
                            project.tracks[index] = updatedTrack
                        }
                    }
                }
            }
        }
    }
    
    /// Select and arm a track in one action (convenience for click handling)
    public func selectAndArmTrack(_ id: TrackID) {
        selectTrack(id)
        // The selectTrack method already auto-arms MIDI/Instrument tracks
    }
    
    public func setTrackVolume(id: TrackID, volume: Float) {
        guard var track = project.track(withID: id) else { return }
        track.volume = volume
        updateTrack(track, description: "Change Volume")
        
        // Update playing audio clips in real-time
        playbackEngine.updateTrackVolume(id, volume: volume)
    }
    
    public func setTrackPan(id: TrackID, pan: Float) {
        guard var track = project.track(withID: id) else { return }
        track.pan = pan
        updateTrack(track, description: "Change Pan")
    }
    
    public func toggleTrackMute(id: TrackID) {
        guard var track = project.track(withID: id) else { return }
        track.isMuted.toggle()
        updateTrack(track, description: track.isMuted ? "Mute Track" : "Unmute Track")
    }
    
    public func toggleTrackSolo(id: TrackID) {
        guard var track = project.track(withID: id) else { return }
        track.isSolo.toggle()
        updateTrack(track, description: track.isSolo ? "Solo Track" : "Unsolo Track")
    }
    
    public func toggleTrackArm(id: TrackID) {
        guard var track = project.track(withID: id) else { return }
        track.isArmed.toggle()
        updateTrack(track, description: track.isArmed ? "Arm Track" : "Disarm Track")
        
        // Start or stop input monitoring based on arm state
        if track.type == .audio {
            if track.isArmed {
                audioRecorder.startInputMonitoring()
            } else {
                // Only stop if no other audio tracks are armed
                let otherArmedAudioTracks = project.tracks.filter { $0.id != id && $0.type == .audio && $0.isArmed }
                if otherArmedAudioTracks.isEmpty {
                    audioRecorder.stopInputMonitoring()
                }
            }
        }
    }
    
    public func setTrackInput(_ trackID: TrackID, input: AudioInputDevice) {
        // Store the selected input device for this track
        // For now, we'll use the system default but this could be extended
        // to support per-track input selection
        print("Setting track \(trackID) input to: \(input.name)")
        
        // Update solo state in audio engine
        audioEngine.updateSoloState(tracks: project.tracks)
    }
    
    // MARK: - Clip Operations
    
    public func addClip(_ clip: Clip, to trackID: TrackID) {
        let action = AddClipAction(trackID: trackID, clip: clip)
        undoManager.registerAction(action, project: &project)
    }
    
    public func deleteClip(id: ClipID, from trackID: TrackID) {
        let action = RemoveClipAction(from: project, trackID: trackID, clipID: id)
        undoManager.registerAction(action, project: &project)
        
        selectedClipIDs.remove(id)
        
        if editingClipID == id {
            editingClipID = nil
            showPianoRoll = false
        }
    }
    
    public func selectClip(_ id: ClipID, addToSelection: Bool = false) {
        if addToSelection {
            selectedClipIDs.insert(id)
        } else {
            selectedClipIDs = [id]
        }
    }
    
    public func deselectAllClips() {
        selectedClipIDs.removeAll()
    }
    
    public func openPianoRoll(for clipID: ClipID) {
        editingClipID = clipID
        showPianoRoll = true
    }
    
    /// Open piano roll for a track - uses first MIDI clip or creates context for empty track
    public func openPianoRollForTrack(_ trackID: TrackID) {
        guard let track = project.track(withID: trackID) else { return }
        
        // Find the first MIDI clip on this track
        if let firstMIDIClip = track.clips.first(where: { $0.content.isMIDI }) {
            editingClipID = firstMIDIClip.id
        } else {
            // No clips yet - we could create a temporary editing context
            // For now, just set the track as selected for editing
            editingClipID = nil
        }
        
        // Store the track ID for the piano roll to reference
        editingTrackID = trackID
        showPianoRoll = true
    }

    public func closePianoRoll() {
        editingClipID = nil
        editingTrackID = nil
        showPianoRoll = false
    }
    
    // MARK: - Clip Movement & Duplication
    
    /// Move a clip to a new beat position
    public func moveClip(_ clipID: ClipID, on trackID: TrackID, toBeat: Double) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }),
              let clipIndex = project.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            return
        }
        
        let clip = project.tracks[trackIndex].clips[clipIndex]
        let duration = clip.timeRange.duration
        
        let newStart = TimePosition(beats: toBeat, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
        let newEnd = TimePosition(
            samples: newStart.samples + duration.samples,
            sampleRate: transportState.sampleRate
        )
        
        project.tracks[trackIndex].clips[clipIndex].timeRange = TimeRange(start: newStart, end: newEnd)
        print("[Edit] Moved clip '\(clip.name)' to beat \(toBeat)")
    }
    
    /// Duplicate a clip at a new beat position
    public func duplicateClip(_ clipID: ClipID, on trackID: TrackID, toBeat: Double) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }),
              let clip = project.tracks[trackIndex].clips.first(where: { $0.id == clipID }) else {
            return
        }

        let duration = clip.timeRange.duration
        let newStart = TimePosition(beats: toBeat, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
        let newEnd = TimePosition(
            samples: newStart.samples + duration.samples,
            sampleRate: transportState.sampleRate
        )

        var newClip = clip
        newClip.id = ClipID()
        newClip.name = "\(clip.name) Copy"
        newClip.timeRange = TimeRange(start: newStart, end: newEnd)

        project.tracks[trackIndex].clips.append(newClip)
        selectedClipIDs = [newClip.id]
        print("[Edit] Duplicated clip '\(clip.name)' to beat \(toBeat)")
    }
    
    // MARK: - Clipboard Operations
    
    private var clipboardClips: [Clip] = []
    private var clipboardSourceTrackID: TrackID?
    
    /// Copy selected clips to clipboard
    public func copySelectedClips() {
        guard let trackID = selectedTrackID,
              let track = project.track(withID: trackID) else { return }
        
        clipboardClips = track.clips.filter { selectedClipIDs.contains($0.id) }
        clipboardSourceTrackID = trackID
        
        if !clipboardClips.isEmpty {
            print("[Edit] Copied \(clipboardClips.count) clip(s) to clipboard")
        }
    }
    
    /// Cut selected clips (copy + delete)
    public func cutSelectedClips() {
        copySelectedClips()
        deleteSelectedClips()
        print("[Edit] Cut \(clipboardClips.count) clip(s)")
    }
    
    /// Paste clips from clipboard at playhead position
    public func pasteClips() {
        guard !clipboardClips.isEmpty else { return }
        
        // Determine target track - use selected track or original source track
        let targetTrackID = selectedTrackID ?? clipboardSourceTrackID
        guard let trackID = targetTrackID,
              let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        let playheadBeat = transportState.playheadBeats
        
        // Find the earliest clip in clipboard to calculate offset
        let earliestBeat = clipboardClips.map { 
            $0.timeRange.start.beats(atTempo: transportState.tempo.bpm) 
        }.min() ?? 0
        
        var newClipIDs: [ClipID] = []
        
        for clip in clipboardClips {
            let clipBeat = clip.timeRange.start.beats(atTempo: transportState.tempo.bpm)
            let offsetFromEarliest = clipBeat - earliestBeat
            let newBeat = playheadBeat + offsetFromEarliest
            
            let duration = clip.timeRange.duration
            let newStart = TimePosition(beats: newBeat, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
            let newEnd = TimePosition(
                samples: newStart.samples + duration.samples,
                sampleRate: transportState.sampleRate
            )
            
            var newClip = clip
            newClip.id = ClipID()
            newClip.timeRange = TimeRange(start: newStart, end: newEnd)
            
            project.tracks[trackIndex].clips.append(newClip)
            newClipIDs.append(newClip.id)
        }
        
        selectedClipIDs = Set(newClipIDs)
        print("[Edit] Pasted \(clipboardClips.count) clip(s) at beat \(playheadBeat)")
    }
    
    /// Duplicate selected clips in place (offset by 1 beat)
    public func duplicateSelectedClips() {
        guard let trackID = selectedTrackID,
              let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        let track = project.tracks[trackIndex]
        let clipsTodup = track.clips.filter { selectedClipIDs.contains($0.id) }
        
        guard !clipsTodup.isEmpty else { return }
        
        var newClipIDs: [ClipID] = []
        
        for clip in clipsTodup {
            // Place duplicate right after the original
            let endBeat = clip.timeRange.end.beats(atTempo: transportState.tempo.bpm)
            let duration = clip.timeRange.duration
            
            let newStart = TimePosition(beats: endBeat, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
            let newEnd = TimePosition(
                samples: newStart.samples + duration.samples,
                sampleRate: transportState.sampleRate
            )
            
            var newClip = clip
            newClip.id = ClipID()
            newClip.name = "\(clip.name) Copy"
            newClip.timeRange = TimeRange(start: newStart, end: newEnd)
            
            project.tracks[trackIndex].clips.append(newClip)
            newClipIDs.append(newClip.id)
        }
        
        selectedClipIDs = Set(newClipIDs)
        print("[Edit] Duplicated \(clipsTodup.count) clip(s)")
    }
    
    /// Delete all selected clips
    public func deleteSelectedClips() {
        let clipIDsToDelete = selectedClipIDs
        
        for clipID in clipIDsToDelete {
            // Find which track contains this clip
            for track in project.tracks {
                if track.clips.contains(where: { $0.id == clipID }) {
                    deleteClip(id: clipID, from: track.id)
                    break
                }
            }
        }
    }
    
    /// Select all clips on the selected track
    public func selectAllClipsOnTrack() {
        guard let trackID = selectedTrackID,
              let track = project.track(withID: trackID) else { return }
        
        selectedClipIDs = Set(track.clips.map { $0.id })
    }
    
    /// Split clip at playhead position
    public func splitClipAtPlayhead() {
        guard let trackID = selectedTrackID,
              let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        let playheadBeat = transportState.playheadBeats
        let track = project.tracks[trackIndex]
        
        // Find clip under playhead
        for (clipIndex, clip) in track.clips.enumerated() {
            let clipStartBeat = clip.timeRange.start.beats(atTempo: transportState.tempo.bpm)
            let clipEndBeat = clip.timeRange.end.beats(atTempo: transportState.tempo.bpm)
            
            if playheadBeat > clipStartBeat && playheadBeat < clipEndBeat {
                // Split this clip
                let splitPoint = TimePosition(beats: playheadBeat, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
                
                // Modify original clip to end at split point
                project.tracks[trackIndex].clips[clipIndex].timeRange = TimeRange(
                    start: clip.timeRange.start,
                    end: splitPoint
                )
                
                // Create new clip from split point to original end
                var newClip = clip
                newClip.id = ClipID()
                newClip.name = "\(clip.name) (split)"
                newClip.timeRange = TimeRange(start: splitPoint, end: clip.timeRange.end)
                
                // For MIDI clips, filter events to only those in the new range
                if case .midi(var midiData) = newClip.content {
                    let splitBeatRelative = playheadBeat - clipStartBeat
                    midiData.events = midiData.events.filter { $0.beatPosition >= splitBeatRelative }
                    // Adjust event positions to be relative to new clip start
                    midiData.events = midiData.events.map { event in
                        var e = event
                        e.beatPosition -= splitBeatRelative
                        return e
                    }
                    newClip.content = .midi(midiData)
                    
                    // Also trim original clip's events
                    if case .midi(var originalMidi) = project.tracks[trackIndex].clips[clipIndex].content {
                        originalMidi.events = originalMidi.events.filter { $0.beatPosition < splitBeatRelative }
                        project.tracks[trackIndex].clips[clipIndex].content = .midi(originalMidi)
                    }
                }
                
                project.tracks[trackIndex].clips.append(newClip)
                print("[Edit] Split clip '\(clip.name)' at beat \(playheadBeat)")
                break
            }
        }
    }
    
    /// Trim selected clips to exact beat boundaries
    /// This ensures clips are exactly N beats long for seamless looping
    public func trimSelectedClipsToGrid(beatResolution: Double = 1.0) {
        guard let trackID = selectedTrackID,
              let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        for clipID in selectedClipIDs {
            guard let clipIndex = project.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else { continue }
            
            var clip = project.tracks[trackIndex].clips[clipIndex]
            let startBeat = clip.timeRange.start.beats(atTempo: transportState.tempo.bpm)
            let endBeat = clip.timeRange.end.beats(atTempo: transportState.tempo.bpm)
            let durationBeats = endBeat - startBeat
            
            // Round start to grid
            let snappedStart = round(startBeat / beatResolution) * beatResolution
            
            // Round duration to grid (minimum 1 beat)
            let snappedDuration = max(beatResolution, round(durationBeats / beatResolution) * beatResolution)
            
            let newStart = TimePosition(beats: snappedStart, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
            let newEnd = TimePosition(beats: snappedStart + snappedDuration, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
            
            project.tracks[trackIndex].clips[clipIndex].timeRange = TimeRange(start: newStart, end: newEnd)
            
            print("[Edit] Trimmed clip '\(clip.name)' to \(snappedDuration) beats")
        }
    }
    
    /// Nudge selected clips by a beat amount
    public func nudgeSelectedClips(byBeats: Double) {
        guard let trackID = selectedTrackID,
              let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        for clipID in selectedClipIDs {
            guard let clipIndex = project.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else { continue }
            
            let clip = project.tracks[trackIndex].clips[clipIndex]
            let currentStart = clip.timeRange.start.beats(atTempo: transportState.tempo.bpm)
            let newStart = max(0, currentStart + byBeats)
            
            let duration = clip.timeRange.duration
            let newStartPos = TimePosition(beats: newStart, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
            let newEndPos = TimePosition(
                samples: newStartPos.samples + duration.samples,
                sampleRate: transportState.sampleRate
            )
            
            project.tracks[trackIndex].clips[clipIndex].timeRange = TimeRange(start: newStartPos, end: newEndPos)
        }
    }
    
    // MARK: - Transport Operations
    
    public func play() {
        print("ProjectViewModel.play() called")
        transportState.play()
        print("TransportState.isPlaying = \(transportState.isPlaying)")
    }
    
    public func stop() {
        // Stop recording first if in progress
        if isRecording {
            stopRecording()
        }
        transportState.stop()
        playbackEngine.stopPlayback()
    }
    
    public func togglePlayPause() {
        print("togglePlayPause called, isPlaying was: \(transportState.isPlaying)")
        transportState.togglePlayPause()
        print("togglePlayPause done, isPlaying now: \(transportState.isPlaying)")
    }
    
    public func setTempo(_ bpm: Double) {
        let action = ChangeTempoAction(from: project.tempo, to: Tempo(bpm: bpm))
        undoManager.registerAction(action, project: &project)
        transportState.tempo = project.tempo
    }
    
    // MARK: - V-Rack Management
    
    /// Available instrument plugins for loading
    public var availableInstrumentPlugins: [PluginIdentifier] {
        pluginHost.availableInstruments.map { $0.identifier }
    }
    
    /// Add a new empty rack instrument
    public func addRackInstrument() {
        let number = project.vRack.instruments.count + 1
        let instrument = RackInstrument(name: "Rack \(number)")
        project.vRack.addInstrument(instrument)
    }
    
    /// Remove a rack instrument
    public func removeRackInstrument(_ id: UUID) {
        // First, update any tracks that were routing to this instrument
        for i in 0..<project.tracks.count {
            if case .rackInstrument(let rackID, _) = project.tracks[i].midiOutput, rackID == id {
                project.tracks[i].midiOutput = .trackInstrument
            }
        }
        
        // Remove from audio engine
        playbackEngine.removeRackInstrument(rackID: id)
        
        // Remove from project
        project.vRack.removeInstrument(withID: id)
    }
    
    /// Toggle mute on a rack instrument
    public func toggleRackInstrumentMute(_ id: UUID) {
        guard var instrument = project.vRack.instrument(withID: id) else { return }
        instrument.isMuted = !instrument.isMuted
        project.vRack.updateInstrument(instrument)
    }
    
    /// Load a plugin into a rack instrument
    public func loadRackInstrumentPlugin(_ rackID: UUID, pluginID: PluginIdentifier) async {
        guard var instrument = project.vRack.instrument(withID: rackID) else { return }
        
        // Find the plugin description
        guard let pluginDesc = pluginHost.availableInstruments.first(where: {
            $0.identifier == pluginID
        }) else {
            print("[V-Rack] Plugin not found: \(pluginID.name)")
            return
        }
        
        do {
            // Load the AU using the same method as track instruments
            let format = AVAudioFormat(standardFormatWithSampleRate: audioEngine.sampleRate, channels: 2)!
            let loadedPlugin = try await pluginHost.loadPlugin(
                identifier: pluginID,
                format: format,
                instanceID: instrument.pluginSlot.id
            )
            
            // Load into engine
            try await playbackEngine.loadRackInstrument(loadedPlugin.audioUnit, rackID: rackID, pluginID: instrument.pluginSlot.id)
            
            // Update the rack instrument
            instrument.pluginSlot.pluginID = pluginID
            instrument.name = pluginID.name
            project.vRack.updateInstrument(instrument)
            
            print("[V-Rack] Loaded plugin: \(pluginID.name)")
        } catch {
            print("[V-Rack] Failed to load plugin: \(error)")
        }
    }
    
    /// Open the plugin UI for a rack instrument
    public func openRackInstrumentUI(_ rackID: UUID) {
        guard let instrument = project.vRack.instrument(withID: rackID),
              let pluginID = instrument.pluginSlot.pluginID,
              let loadedPlugin = pluginHost.loadedPlugins.values.first(where: { $0.identifier == pluginID }) else {
            return
        }

        PluginWindowManager.shared.openPluginWindow(for: loadedPlugin, trackName: instrument.name)
    }

    // MARK: - Undo/Redo
    
    public func undo() {
        undoManager.undo(project: &project)
    }
    
    public func redo() {
        undoManager.redo(project: &project)
    }
    
    // MARK: - Recording
    
    public func startRecording() {
        // Find armed tracks
        let armedTracks = project.tracks.filter { $0.isArmed }
        
        guard let firstArmedTrack = armedTracks.first else {
            print("No tracks armed for recording")
            return
        }
        
        isRecording = true
        recordingTrackID = firstArmedTrack.id
        
        // Start transport if not already playing
        if !transportState.isPlaying {
            transportState.play()
        }
        
        // Use the transport's captured start beat for perfect sync
        // This is captured BEFORE the timer starts
        recordingStartBeat = transportState.playbackStartBeat
        
        switch firstArmedTrack.type {
        case .audio:
            startAudioRecording(on: firstArmedTrack)
        case .midi, .instrument:
            startMIDIRecording(on: firstArmedTrack)
        default:
            break
        }
    }
    
    public func stopRecording() {
        guard isRecording, let trackID = recordingTrackID else { return }
        
        guard let track = project.track(withID: trackID) else {
            isRecording = false
            recordingTrackID = nil
            return
        }
        
        switch track.type {
        case .audio:
            finishAudioRecording(on: track)
        case .midi, .instrument:
            finishMIDIRecording(on: track)
        default:
            break
        }
        
        isRecording = false
        recordingTrackID = nil
    }
    
    public func cancelRecording() {
        guard isRecording else { return }
        
        // Cancel audio recording if in progress
        audioRecorder.cancelRecording()
        
        // Cancel MIDI recording if in progress
        midiRecorder.cancelRecording()
        
        isRecording = false
        recordingTrackID = nil
        
        // Stop transport
        transportState.stop()
    }
    
    private func startAudioRecording(on track: Track) {
        print("startAudioRecording called for track: \(track.name)")
        
        // Start recording directly since we've already requested permission during monitoring
        do {
            let url = try audioRecorder.startRecording(trackID: track.id, filename: "Recording_\(track.name)_\(Int(Date().timeIntervalSince1970))")
            print("Started audio recording to: \(url)")
        } catch {
            print("Failed to start audio recording: \(error)")
            isRecording = false
            recordingTrackID = nil
        }
    }
    
    private func finishAudioRecording(on track: Track) {
        print("finishAudioRecording called for track: \(track.name)")
        guard let result = audioRecorder.stopRecording() else {
            print("No recording result returned")
            return
        }
        print("Recording finished: \(result.fileURL), duration: \(result.duration)s, samples: \(result.sampleCount)")
        
        // Don't create clip if recording was empty
        guard result.sampleCount > 0 && result.duration > 0.1 else {
            print("Recording too short, not creating clip")
            return
        }
        
        // Create audio clip from recording
        let tempo = transportState.tempo.bpm
        let sampleRate = result.sampleRate  // Use the recording's sample rate
        
        // Use the stored recording start beat
        let clipStart = TimePosition(beats: recordingStartBeat, tempo: tempo, sampleRate: sampleRate)
        let clipDuration = TimePosition(seconds: result.duration, sampleRate: sampleRate)
        
        // Write debug to file
        let debugInfo = """
        === CLIP CREATION DEBUG ===
          Recording start beat: \(recordingStartBeat)
          Duration: \(result.duration) seconds
          Tempo: \(tempo) BPM
          Sample rate: \(sampleRate)
          clipStart samples: \(clipStart.samples)
          clipStart beats (verify): \(clipStart.beats(atTempo: tempo))
          clipDuration samples: \(clipDuration.samples)
          clipDuration beats: \(clipDuration.beats(atTempo: tempo))
        === END CLIP CREATION DEBUG ===
        
        """
        try? debugInfo.write(toFile: "/tmp/daw_debug.log", atomically: true, encoding: .utf8)
        print(debugInfo)
        
        // Create file reference
        let fileRef = AudioFileReference(
            originalPath: result.fileURL.path,
            relativePath: "Audio/\(result.fileURL.lastPathComponent)",
            sampleRate: result.sampleRate,
            channelCount: result.channelCount,
            lengthInSamples: result.sampleCount,
            bitDepth: 24
        )
        
        // Create clip
        let clip = Clip(
            name: "Recording \(Date().formatted(date: .omitted, time: .shortened))",
            timeRange: TimeRange(start: clipStart, duration: clipDuration),
            content: .audio(AudioClipData(fileReference: fileRef))
        )
        
        print("Created clip: \(clip.name), timeRange: \(clip.timeRange)")
        
        // Add to track
        addClip(clip, to: track.id)
        
        // Add file reference to project
        var updatedProject = project
        updatedProject.audioFiles.append(fileRef)
        project = updatedProject
    }
    
    private func startMIDIRecording(on track: Track) {
        midiRecorder.startRecording()
        print("Started MIDI recording on track: \(track.name)")
    }
    
    private func finishMIDIRecording(on track: Track) {
        let events = midiRecorder.stopRecording()
        
        guard !events.isEmpty else {
            print("No MIDI events recorded")
            return
        }
        
        // Create clip from recorded events
        if let clip = midiRecorder.createClip(
            from: events,
            name: "Recorded MIDI",
            quantize: false
        ) {
            addClip(clip, to: track.id)
        }
    }
    
    // MARK: - Note Preview
    
    /// Play a note for preview (e.g., from piano roll or keyboard)
    public func playNotePreview(pitch: UInt8, velocity: UInt8 = 100) {
        guard let trackID = selectedTrackID else { return }
        playbackEngine.playNotePreview(pitch: pitch, velocity: velocity, on: trackID)
    }
    
    /// Stop a preview note
    public func stopNotePreview(pitch: UInt8) {
        guard let trackID = selectedTrackID else { return }
        playbackEngine.stopNotePreview(pitch: pitch, on: trackID)
    }
    
    /// Play a test note to verify audio is working
    public func playTestNote() {
        guard let trackID = selectedTrackID else {
            // Use first MIDI track
            if let midiTrack = project.tracks.first(where: { $0.type == .midi || $0.type == .instrument }) {
                playbackEngine.playTestNote(on: midiTrack.id)
            }
            return
        }
        playbackEngine.playTestNote(on: trackID)
    }
    
    // MARK: - AI Audio Generation
    
    private let aiService = ElevenLabsService()
    
    /// Generate AI audio from a prompt
    /// - Parameters:
    ///   - prompt: User's description of the desired sound
    ///   - beats: Number of beats to generate
    /// - Returns: URL to the generated audio file
    public func generateAIAudio(prompt: String, beats: Int, mode: ElevenLabsGenerationMode = .soundEffects) async throws -> URL {
        // Calculate duration based on tempo
        let tempo = transportState.tempo.bpm
        let durationSeconds = (Double(beats) / tempo) * 60.0

        // Get MIDI context for the target beat range
        let startBeat = transportState.playheadBeats
        let endBeat = startBeat + Double(beats)
        let midiContext = MIDIContextAnalyzer.analyzeProject(project, beatRange: startBeat...endBeat)

        // Build enriched prompt
        let enrichedPrompt = ElevenLabsService.buildEnrichedPrompt(
            userPrompt: prompt,
            tempo: tempo,
            beats: beats,
            midiContext: midiContext
        )

        print("[AI Generate] Mode: \(mode.rawValue)")
        print("[AI Generate] Enriched prompt: \(enrichedPrompt)")
        print("[AI Generate] Duration: \(durationSeconds)s (\(beats) beats at \(tempo) BPM)")

        // Generate audio via ElevenLabs with selected mode
        let result = try await aiService.generateAudio(
            prompt: enrichedPrompt,
            durationSeconds: durationSeconds,
            mode: mode,
            promptInfluence: 0.3
        )
        
        // Save to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(result.suggestedFilename)
        
        try result.audioData.write(to: fileURL)
        
        print("[AI Generate] Saved to: \(fileURL.path)")
        
        return fileURL
    }
    
    /// Import generated audio and place it on the timeline
    /// - Parameters:
    ///   - url: URL to the audio file
    ///   - atBeat: Beat position to place the clip
    ///   - durationBeats: Duration in beats
    ///   - onTrack: Optional track ID to place the audio on (defaults to first audio track)
    ///   - promptLabel: Optional label from the generation prompt
    public func importGeneratedAudio(from url: URL, atBeat: Double, durationBeats: Double, onTrack trackID: TrackID? = nil, promptLabel: String? = nil) {
        // Find the target track
        var audioTrack: Track
        
        if let trackID = trackID, let specifiedTrack = project.tracks.first(where: { $0.id == trackID && $0.type == .audio }) {
            // Use the specified track
            audioTrack = specifiedTrack
        } else if let existingAudioTrack = project.tracks.first(where: { $0.type == .audio }) {
            // Fall back to first audio track
            audioTrack = existingAudioTrack
        } else {
            // Create a new audio track
            addTrack(type: .audio, name: "Audio")
            guard let newTrack = project.tracks.first(where: { $0.type == .audio }) else {
                print("[Generative Fill] Failed to create audio track")
                return
            }
            audioTrack = newTrack
        }
        
        // Copy file to project audio folder (in a real app)
        // For now, we'll reference it directly
        
        do {
            let audioFile = try AVAudioFile(forReading: url)
            
            let fileReference = AudioFileReference(
                originalPath: url.path,
                relativePath: url.lastPathComponent,
                sampleRate: audioFile.processingFormat.sampleRate,
                channelCount: Int(audioFile.processingFormat.channelCount),
                lengthInSamples: audioFile.length,
                bitDepth: 16
            )
            
            // Calculate the actual duration from the audio file
            let actualSampleRate = audioFile.processingFormat.sampleRate
            let actualDurationSeconds = Double(audioFile.length) / actualSampleRate
            let actualDurationBeats = (actualDurationSeconds * transportState.tempo.bpm) / 60.0
            
            print("[AI Generate] Requested \(durationBeats) beats, file is \(actualDurationBeats) beats (\(actualDurationSeconds)s)")
            
            // Use requested beats for the clip - we'll trim the audio to fit exactly
            // This ensures loops are seamless at beat boundaries
            let targetSamples = Int64((Double(durationBeats) / transportState.tempo.bpm) * 60.0 * actualSampleRate)
            
            let audioData = AudioClipData(
                fileReference: fileReference,
                sourceStartSample: 0,
                sourceLengthSamples: min(audioFile.length, targetSamples)  // Trim to target if longer
            )
            
            let startPosition = TimePosition(beats: atBeat, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
            let durationPosition = TimePosition(beats: durationBeats, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
            
            print("[AI Generate] Creating clip at beat \(atBeat)")
            print("[AI Generate] Start position samples: \(startPosition.samples), seconds: \(startPosition.seconds)")
            print("[AI Generate] Start position beats (verify): \(startPosition.beats(atTempo: transportState.tempo.bpm))")
            
            let timeRange = TimeRange(
                start: startPosition,
                duration: durationPosition
            )
            
            // Create a descriptive clip name from the prompt
            let clipName: String
            if let prompt = promptLabel, !prompt.isEmpty {
                // Truncate long prompts and clean up
                let maxLength = 30
                let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.count > maxLength {
                    clipName = String(cleaned.prefix(maxLength)) + "..."
                } else {
                    clipName = cleaned
                }
            } else {
                clipName = "Generated Audio"
            }
            
            let clip = Clip(
                name: clipName,
                timeRange: timeRange,
                content: .audio(audioData)
            )
            
            // Add clip to track
            if let trackIndex = project.tracks.firstIndex(where: { $0.id == audioTrack.id }) {
                project.tracks[trackIndex].clips.append(clip)
                print("[AI Generate] Added clip '\(clip.name)' to track: \(audioTrack.name) at beat \(atBeat)")
                print("[AI Generate] Clip timeRange.start.samples = \(clip.timeRange.start.samples)")
            }
            
        } catch {
            print("[AI Generate] Failed to import audio: \(error)")
        }
    }
    
    // MARK: - Zoom
    
    public func zoomIn() {
        zoomLevel = min(zoomLevel * 1.5, 10.0)
        pixelsPerBeat = 40.0 * zoomLevel
    }
    
    public func zoomOut() {
        zoomLevel = max(zoomLevel / 1.5, 0.1)
        pixelsPerBeat = 40.0 * zoomLevel
    }
    
    public func zoomToFit() {
        // Calculate zoom to fit entire project
        let projectBeats = project.durationInBeats
        // This would need the actual view width
    }
    
    // MARK: - Selection Helpers
    
    public var selectedTrack: Track? {
        guard let id = selectedTrackID else { return nil }
        return project.track(withID: id)
    }
    
    public var editingClip: Clip? {
        guard let clipID = editingClipID,
              let trackID = selectedTrackID,
              let track = project.track(withID: trackID) else {
            return nil
        }
        return track.clips.first { $0.id == clipID }
    }
}

// MARK: - Timeline State

/// State for the timeline view
public struct TimelineState {
    public var pixelsPerBeat: Double = 40.0
    public var trackHeight: Double = 80.0
    public var scrollPosition: CGPoint = .zero
    public var visibleBeatRange: ClosedRange<Double> = 0...16
    
    public func beatToX(_ beat: Double) -> Double {
        beat * pixelsPerBeat
    }
    
    public func xToBeat(_ x: Double) -> Double {
        x / pixelsPerBeat
    }
}
