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
    
    @Published public var project: Project {
        didSet {
            isModified = true
            // Note: Don't set project.modifiedAt here - it causes infinite recursion
            // The modifiedAt is updated in Project.swift when tracks are modified
            // Pass the project object so AppState can sync
            NotificationCenter.default.post(name: .projectDidChange, object: project)
        }
    }
    @Published public private(set) var selectedTrackID: TrackID?
    @Published public private(set) var selectedClipIDs: Set<ClipID> = []
    @Published public private(set) var isModified: Bool = false
    
    // Timeline state
    @Published public var zoomLevel: Double = 1.0
    @Published public var scrollOffset: CGPoint = .zero
    @Published public var pixelsPerBeat: Double = 40.0
    
    // UI state
    @Published public var showMixer: Bool = false
    @Published public var showInspector: Bool = false
    @Published public var showPianoRoll: Bool = true
    @Published public var showAIAssistant: Bool = true
    @Published public var editingClipID: ClipID?
    @Published public var editingTrackID: TrackID?

    // Recording state
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var recordingTrackID: TrackID?
    @Published public private(set) var recordingStartBeat: Double = 0
    
    // V-Rack recording state
    private var isRecordingVRack: Bool = false
    private var vRackRecordingTrackID: TrackID?
    
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
    // Note: Metronome is now handled by AudioEngine/PlaybackEngine - removed standalone Metronome to prevent duplicate clicks
    
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
        self.audioRecorder = AudioRecorder(audioEngine: audioEngine)
        self.midiRecorder = MIDIRecorderManager(midiManager: midiManager)
        self.selectionManager = SelectionManager()
        
        // Apply DAW state from project
        self.zoomLevel = project.dawState.zoomLevel
        self.pixelsPerBeat = 40.0 * project.dawState.zoomLevel
        
        setupBindings()
        setupAudioEngine()
        
        // Setup MIDI asynchronously
        Task {
            await setupMIDI()
        }
        
        // Apply playhead position from saved state
        if project.dawState.playheadPosition > 0 {
            transportState.setPlayheadBeats(project.dawState.playheadPosition)
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
        // Note: Metronome is handled by PlaybackEngine - no separate binding needed
        
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
    
    public func prepareForPlayback() {
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
    
    /// Reorder a track from one index to another
    public func reorderTrack(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < project.tracks.count,
              destinationIndex >= 0, destinationIndex <= project.tracks.count else {
            return
        }
        
        var tracks = project.tracks
        let track = tracks.remove(at: sourceIndex)
        let adjustedDestination = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        tracks.insert(track, at: min(adjustedDestination, tracks.count))
        
        var updatedProject = project
        updatedProject.tracks = tracks
        project = updatedProject
        
        print("[Tracks] Reordered track from index \(sourceIndex) to \(destinationIndex)")
    }
    
    /// Reorder a track by ID to a new index
    public func reorderTrack(trackID: TrackID, toIndex destinationIndex: Int) {
        guard let sourceIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else {
            return
        }
        reorderTrack(from: sourceIndex, to: destinationIndex)
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
        // Only update tracks that actually need changing to minimize UI updates
        guard let selectedID = id else { return }
        
        for i in 0..<project.tracks.count {
            let track = project.tracks[i]
            if track.type == .midi || track.type == .instrument {
                let shouldBeArmed = track.id == selectedID
                if track.isArmed != shouldBeArmed {
                    project.tracks[i].isArmed = shouldBeArmed
                }
            }
        }
    }
    
    /// Select and arm a track in one action (convenience for click handling)
    public func selectAndArmTrack(_ id: TrackID) {
        selectTrack(id)
        // The selectTrack method already auto-arms MIDI/Instrument tracks
        
        // If piano roll is visible and this is a MIDI track, switch to it
        if showPianoRoll, let track = project.track(withID: id), track.type == .midi {
            // Update the editing track to this MIDI track
            editingTrackID = id
            // Find the first MIDI clip on this track (if any)
            if let firstMIDIClip = track.clips.first(where: { $0.content.isMIDI }) {
                editingClipID = firstMIDIClip.id
            } else {
                editingClipID = nil
            }
        }
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
            updateAudioInputMonitoring()
        }
    }
    
    /// Update audio input monitoring based on which tracks are armed
    private func updateAudioInputMonitoring() {
        // Check for armed audio tracks with different input types
        let armedAudioTracks = project.tracks.filter { $0.type == .audio && $0.isArmed }
        
        // Check if any armed tracks use V-Rack input
        let hasArmedVRackInput = armedAudioTracks.contains { $0.inputSource == .vRackSum }
        
        // Check if any armed tracks use hardware input
        let hasArmedHardwareInput = armedAudioTracks.contains { track in
            if case .audioDevice = track.inputSource { return true }
            return track.inputSource == nil || track.inputSource == .none
        }
        
        // Manage V-Rack input monitoring
        if hasArmedVRackInput {
            playbackEngine.startVRackInputMonitoring()
        } else {
            playbackEngine.stopVRackInputMonitoring()
        }
        
        // Manage hardware input monitoring
        if hasArmedHardwareInput {
            audioRecorder.startInputMonitoring()
        } else {
            audioRecorder.stopInputMonitoring()
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
    /// Scroll position for piano roll when it opens
    @Published public var pianoRollInitialBeat: Double = 0
    
    public func openPianoRollForTrack(_ trackID: TrackID, atBeat beat: Double? = nil) {
        guard let track = project.track(withID: trackID) else { return }

        // Find the first MIDI clip on this track, or one that contains the clicked beat
        if let beat = beat,
           let clipAtBeat = track.clips.first(where: { clip in
               guard clip.content.isMIDI else { return false }
               let clipStart = clip.timeRange.start.beats(atTempo: transportState.tempo.bpm)
               let clipEnd = clipStart + clip.timeRange.duration.beats(atTempo: transportState.tempo.bpm)
               return beat >= clipStart && beat < clipEnd
           }) {
            editingClipID = clipAtBeat.id
        } else if let firstMIDIClip = track.clips.first(where: { $0.content.isMIDI }) {
            editingClipID = firstMIDIClip.id
        } else {
            // No clips yet - we could create a temporary editing context
            // For now, just set the track as selected for editing
            editingClipID = nil
        }

        // Store the track ID for the piano roll to reference
        editingTrackID = trackID
        pianoRollInitialBeat = beat ?? 0
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
        // If recording, stop recording and pause (keep playhead where it is)
        if isRecording {
            stopRecording()
            // Just pause, don't reset playhead position
            transportState.pause()
            playbackEngine.stopPlayback()
            return
        }
        
        transportState.togglePlayPause()
    }
    
    /// Seek to a beat position, continuing playback if already playing
    public func seekTo(beat: Double) {
        let wasPlaying = transportState.isPlaying
        
        if wasPlaying {
            // Pause both engine and transport state
            playbackEngine.stopPlayback()
            transportState.pause()
        }
        
        // Move playhead
        transportState.setPlayheadBeats(beat)
        
        if wasPlaying {
            // Use transportState.play() to properly reset playback start position
            // This triggers prepareForPlayback + startPlayback via event handler
            transportState.play()
        }
    }
    
    public func setTempo(_ bpm: Double) {
        let action = ChangeTempoAction(from: project.tempo, to: Tempo(bpm: bpm))
        undoManager.registerAction(action, project: &project)
        transportState.tempo = project.tempo
    }
    
    public func setTimeSignature(numerator: Int, denominator: Int) {
        let newTimeSignature = TimeSignature(numerator: numerator, denominator: denominator)
        project.timeSignature = newTimeSignature
        transportState.timeSignature = newTimeSignature
    }
    
    // MARK: - Time Range Operations
    
    /// Delete a time range and shift subsequent content (ripple delete)
    public func deleteTimeRange(startBeat: Double, endBeat: Double) {
        guard endBeat > startBeat else { return }
        
        let deleteDuration = endBeat - startBeat
        
        for (index, var track) in project.tracks.enumerated() {
            var modifiedClips: [Clip] = []
            
            for var clip in track.clips {
                let clipStart = clip.timeRange.start.beats(atTempo: project.tempo.bpm)
                let clipEnd = clipStart + clip.timeRange.duration.beats(atTempo: project.tempo.bpm)
                
                // Clip is entirely before the deleted range - keep as is
                if clipEnd <= startBeat {
                    modifiedClips.append(clip)
                }
                // Clip is entirely after the deleted range - shift it earlier
                else if clipStart >= endBeat {
                    let newStart = clipStart - deleteDuration
                    clip.timeRange = TimeRange(
                        start: TimePosition(beats: newStart, tempo: project.tempo.bpm),
                        duration: clip.timeRange.duration
                    )
                    modifiedClips.append(clip)
                }
                // Clip starts before and ends within or after - trim the end
                else if clipStart < startBeat && clipEnd > startBeat {
                    let newDuration = startBeat - clipStart
                    if newDuration > 0 {
                        clip.timeRange = TimeRange(
                            start: clip.timeRange.start,
                            duration: TimePosition(beats: newDuration, tempo: project.tempo.bpm)
                        )
                        modifiedClips.append(clip)
                    }
                }
                // Clip is entirely within the deleted range - remove it (don't add to modifiedClips)
                // Clip starts within the range and ends after - trim the start and shift
                else if clipStart >= startBeat && clipStart < endBeat && clipEnd > endBeat {
                    let trimAmount = endBeat - clipStart
                    let newDuration = clip.timeRange.duration.beats(atTempo: project.tempo.bpm) - trimAmount
                    if newDuration > 0 {
                        clip.timeRange = TimeRange(
                            start: TimePosition(beats: startBeat, tempo: project.tempo.bpm),
                            duration: TimePosition(beats: newDuration, tempo: project.tempo.bpm)
                        )
                        modifiedClips.append(clip)
                    }
                }
            }
            
            track.clips = modifiedClips
            project.tracks[index] = track
        }
    }
    
    /// Insert empty time at a position, shifting subsequent content
    public func insertSilence(atBeat: Double, durationBeats: Double) {
        guard durationBeats > 0 else { return }
        
        for (index, var track) in project.tracks.enumerated() {
            for (clipIndex, var clip) in track.clips.enumerated() {
                let clipStart = clip.timeRange.start.beats(atTempo: project.tempo.bpm)
                
                // Shift clips that start at or after the insert point
                if clipStart >= atBeat {
                    let newStart = clipStart + durationBeats
                    clip.timeRange = TimeRange(
                        start: TimePosition(beats: newStart, tempo: project.tempo.bpm),
                        duration: clip.timeRange.duration
                    )
                    track.clips[clipIndex] = clip
                }
            }
            
            project.tracks[index] = track
        }
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
              instrument.pluginSlot.pluginID != nil else {
            print("[V-Rack] Cannot open UI - no instrument or plugin not set for rack \(rackID)")
            return
        }
        
        // Look up by slot ID (the key used when loading the plugin)
        guard let loadedPlugin = pluginHost.loadedPlugins[instrument.pluginSlot.id] else {
            print("[V-Rack] Cannot open UI - plugin not loaded for \(instrument.name)")
            print("[V-Rack] Loaded plugins: \(pluginHost.loadedPlugins.keys)")
            print("[V-Rack] Looking for slot ID: \(instrument.pluginSlot.id)")
            return
        }

        PluginWindowManager.shared.openPluginWindow(for: loadedPlugin, trackName: instrument.name)
    }
    
    // MARK: - Plugin State Management
    
    /// Save all loaded plugin states to project before saving
    public func saveAllPluginStates() {
        print("[PluginState] ========================================")
        print("[PluginState] SAVING ALL PLUGIN STATES")
        print("[PluginState] Rack instruments count: \(project.vRack.instruments.count)")
        print("[PluginState] Loaded plugins count: \(pluginHost.loadedPlugins.count)")
        print("[PluginState] Loaded plugin IDs: \(pluginHost.loadedPlugins.keys.map { $0.uuidString.prefix(8) })")
        
        // Save rack instrument plugin states
        for (index, instrument) in project.vRack.instruments.enumerated() {
            print("[PluginState] Processing: \(instrument.name) (slot: \(instrument.pluginSlot.id.uuidString.prefix(8)))")
            
            guard let pluginID = instrument.pluginSlot.pluginID else {
                print("[PluginState]   No pluginID set, skipping")
                continue
            }
            
            print("[PluginState]   Plugin: \(pluginID.name)")
            print("[PluginState]   Looking for loaded plugin with slot ID: \(instrument.pluginSlot.id)")
            
            // Check if plugin is loaded
            if pluginHost.loadedPlugins[instrument.pluginSlot.id] == nil {
                print("[PluginState]   ❌ Plugin not in loadedPlugins!")
                continue
            }
            
            do {
                let stateData = try pluginHost.savePreset(pluginID: instrument.pluginSlot.id)
                project.vRack.instruments[index].pluginSlot.stateData = stateData
                print("[PluginState]   ✅ Saved \(stateData.count) bytes")
            } catch {
                print("[PluginState]   ❌ Failed to save: \(error)")
            }
        }
        
        print("[PluginState] ========================================")
    }
    
    /// Restore all plugin states after loading a project
    public func restoreAllPluginStates() async {
        print("[PluginState] Restoring all plugin states...")
        print("[PluginState] Found \(project.vRack.instruments.count) rack instruments to restore")
        
        // First scan for plugins so we have them available
        await pluginHost.scanForPlugins()
        
        // Restore rack instrument plugin states
        for instrument in project.vRack.instruments {
            guard let pluginID = instrument.pluginSlot.pluginID else { 
                print("[PluginState] No pluginID for: \(instrument.name)")
                continue 
            }
            
            print("[PluginState] Restoring: \(instrument.name) (slot: \(instrument.pluginSlot.id))")
            print("[PluginState]   Plugin: \(pluginID.name) by \(pluginID.manufacturer)")
            
            // First, load the plugin
            await loadRackInstrumentPlugin(instrument.id, pluginID: pluginID)
            
            // Check if it loaded
            guard let loaded = pluginHost.loadedPlugins[instrument.pluginSlot.id] else {
                print("[PluginState]   ❌ Plugin failed to load")
                continue
            }
            
            print("[PluginState]   ✅ Plugin loaded: \(loaded.name)")
            
            // Give the plugin time to fully initialize before restoring state
            // Some plugins (like Musio) need this to properly accept state
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            
            // Then restore its state if we have it
            if let stateData = instrument.pluginSlot.stateData {
                do {
                    try pluginHost.loadPreset(pluginID: instrument.pluginSlot.id, data: stateData)
                    print("[PluginState]   ✅ State restored (\(stateData.count) bytes)")
                    
                    // Give the plugin time to apply the state
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                } catch {
                    print("[PluginState]   ⚠️ Failed to restore state: \(error)")
                }
            } else {
                print("[PluginState]   No state data to restore")
            }
        }
        
        print("[PluginState] Restore complete. Loaded plugins: \(pluginHost.loadedPlugins.count)")
    }
    
    /// Clear all loaded plugins and reset the session
    public func clearAllPlugins() {
        print("[PluginState] Clearing all plugins...")
        
        // Stop playback first
        playbackEngine.stopPlayback()
        transportState.stop()
        
        // Close all plugin windows and clear caches
        PluginWindowManager.shared.clearAllCaches()
        
        // Remove all rack instruments from audio engine
        for instrument in project.vRack.instruments {
            playbackEngine.removeRackInstrument(rackID: instrument.id)
        }
        
        // Remove all track instruments from audio engine
        for track in project.tracks {
            playbackEngine.removeInstrument(for: track.id)
        }
        
        // Unload all plugins from host
        pluginHost.unloadAllPlugins()
        
        print("[PluginState] All plugins cleared")
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
        
        // Cancel V-Rack recording if in progress
        if isRecordingVRack {
            _ = playbackEngine.stopVRackRecording()  // Discard result
            isRecordingVRack = false
            vRackRecordingTrackID = nil
        }
        
        // Cancel MIDI recording if in progress
        midiRecorder.cancelRecording()
        
        isRecording = false
        recordingTrackID = nil
        
        // Stop transport
        transportState.stop()
    }
    
    private func startAudioRecording(on track: Track) {
        print("startAudioRecording called for track: \(track.name)")
        
        // Check if this track is set to record from V-Rack
        if track.inputSource == .vRackSum {
            startVRackRecording(on: track)
            return
        }
        
        // Start recording from hardware input
        do {
            let url = try audioRecorder.startRecording(trackID: track.id, filename: "Recording_\(track.name)_\(Int(Date().timeIntervalSince1970))")
            print("Started audio recording to: \(url)")
        } catch {
            print("Failed to start audio recording: \(error)")
            isRecording = false
            recordingTrackID = nil
        }
    }
    
    private func startVRackRecording(on track: Track) {
        print("startVRackRecording called for track: \(track.name)")
        
        // Create a unique filename for the recording
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "VRack_\(track.name)_\(timestamp).wav"
        
        // Use Application Support directory for recordings (more permanent than temp)
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let audioDir = appSupport.appendingPathComponent("MusioCreate/Recordings")
        try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        
        print("[V-Rack Recording] Saving to: \(audioDir.path)")
        
        let fileURL = audioDir.appendingPathComponent(filename)
        
        // Start recording on the PlaybackEngine's V-Rack sum mixer
        if playbackEngine.startVRackRecording(to: fileURL) {
            isRecordingVRack = true
            vRackRecordingTrackID = track.id
            print("Started V-Rack recording to: \(fileURL)")
        } else {
            print("Failed to start V-Rack recording")
            isRecording = false
            recordingTrackID = nil
        }
    }
    
    private func finishAudioRecording(on track: Track) {
        print("finishAudioRecording called for track: \(track.name)")
        
        // Check if this was a V-Rack recording
        if isRecordingVRack && vRackRecordingTrackID == track.id {
            finishVRackRecording(on: track)
            return
        }
        
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
    
    private func finishVRackRecording(on track: Track) {
        print("finishVRackRecording called for track: \(track.name)")
        
        guard let result = playbackEngine.stopVRackRecording() else {
            print("No V-Rack recording result returned")
            isRecordingVRack = false
            vRackRecordingTrackID = nil
            return
        }
        
        let durationSeconds = Double(result.durationInSamples) / result.sampleRate
        print("V-Rack recording finished: \(result.fileURL), duration: \(durationSeconds)s")
        
        // Don't create clip if recording was empty
        guard result.durationInSamples > 0 && durationSeconds > 0.1 else {
            print("V-Rack recording too short, not creating clip")
            isRecordingVRack = false
            vRackRecordingTrackID = nil
            return
        }
        
        let tempo = transportState.tempo.bpm
        let sampleRate = result.sampleRate
        
        // The recording tap captures audio that was rendered ~1 buffer before the tap fires.
        // This means the recorded audio contains sound from BEFORE the recording start beat.
        // To compensate, we shift the clip LATER by the buffer latency amount.
        let bufferLatencySeconds = playbackEngine.bufferLatencySeconds
        let bufferLatencyBeats = bufferLatencySeconds * (tempo / 60.0)
        let compensatedStartBeat = result.startBeat + bufferLatencyBeats
        
        print("[V-Rack Recording] Start beat: \(result.startBeat), Buffer latency: \(bufferLatencySeconds * 1000)ms (\(bufferLatencyBeats) beats)")
        print("[V-Rack Recording] Compensated start beat: \(compensatedStartBeat) (shifted LATER)")
        
        let clipStart = TimePosition(beats: compensatedStartBeat, tempo: tempo, sampleRate: sampleRate)
        let clipDuration = TimePosition(seconds: durationSeconds, sampleRate: sampleRate)
        
        // Create file reference
        let fileRef = AudioFileReference(
            originalPath: result.fileURL.path,
            relativePath: "Audio/\(result.fileURL.lastPathComponent)",
            sampleRate: result.sampleRate,
            channelCount: 2, // V-Rack sum is stereo
            lengthInSamples: result.durationInSamples,
            bitDepth: 24
        )
        
        // Create clip
        let clip = Clip(
            name: "V-Rack \(Date().formatted(date: .omitted, time: .shortened))",
            timeRange: TimeRange(start: clipStart, duration: clipDuration),
            content: .audio(AudioClipData(fileReference: fileRef))
        )
        
        print("Created V-Rack clip: \(clip.name), timeRange: \(clip.timeRange)")
        
        // Add to track
        addClip(clip, to: track.id)
        
        // Add file reference to project
        var updatedProject = project
        updatedProject.audioFiles.append(fileRef)
        project = updatedProject
        
        // Reset V-Rack recording state
        isRecordingVRack = false
        vRackRecordingTrackID = nil
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

    private let elevenLabsService = ElevenLabsService()
    private let miniMaxService = MiniMaxService()

    /// Generate AI audio from a prompt
    /// - Parameters:
    ///   - prompt: User's description of the desired sound
    ///   - beats: Number of beats to generate
    ///   - model: The AI model to use for generation
    ///   - continuationContext: Optional context for continuing from a previous generation
    /// - Returns: URL to the generated audio file
    public func generateAIAudio(prompt: String, beats: Int, model: AIAudioModel = .elevenLabsSFX, continuationContext: ContinuationContext? = nil) async throws -> URL {
        // Calculate duration based on tempo
        let tempo = transportState.tempo.bpm
        let durationSeconds = (Double(beats) / tempo) * 60.0

        // Get MIDI context for the target beat range
        let startBeat = transportState.playheadBeats
        let endBeat = startBeat + Double(beats)
        let midiContext = MIDIContextAnalyzer.analyzeProject(project, beatRange: startBeat...endBeat)

        // Build enriched prompt with optional continuation context
        let enrichedPrompt = ElevenLabsService.buildEnrichedPrompt(
            userPrompt: prompt,
            tempo: tempo,
            beats: beats,
            midiContext: midiContext,
            continuationContext: continuationContext
        )

        print("[AI Generate] Model: \(model.displayName)")
        if continuationContext != nil {
            print("[AI Generate] CONTINUATION MODE - continuing from previous clip")
        }
        print("[AI Generate] Enriched prompt: \(enrichedPrompt)")
        print("[AI Generate] Duration: \(durationSeconds)s (\(beats) beats at \(tempo) BPM)")

        // Route to the appropriate service based on model
        let audioData: Data
        let suggestedFilename: String
        
        switch model {
        case .elevenLabsSFX:
            let result = try await elevenLabsService.generateAudio(
                prompt: enrichedPrompt,
                durationSeconds: durationSeconds,
                mode: .soundEffects,
                promptInfluence: 0.3
            )
            audioData = result.audioData
            suggestedFilename = result.suggestedFilename
            
        case .elevenLabsMusic:
            let result = try await elevenLabsService.generateAudio(
                prompt: enrichedPrompt,
                durationSeconds: durationSeconds,
                mode: .music,
                promptInfluence: 0.3
            )
            audioData = result.audioData
            suggestedFilename = result.suggestedFilename
            
        case .miniMaxMusic:
            let result = try await miniMaxService.generateMusic(
                prompt: enrichedPrompt,
                durationSeconds: durationSeconds
            )
            audioData = result.audioData
            suggestedFilename = result.suggestedFilename
        }
        
        // Save to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(suggestedFilename)
        
        try audioData.write(to: fileURL)
        
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
            
            // Add clip to track AND file reference to project
            if let trackIndex = project.tracks.firstIndex(where: { $0.id == audioTrack.id }) {
                var updatedProject = project
                updatedProject.tracks[trackIndex].clips.append(clip)
                updatedProject.audioFiles.append(fileReference)  // Important: add to audioFiles for saving!
                project = updatedProject
                print("[AI Generate] Added clip '\(clip.name)' to track: \(audioTrack.name) at beat \(atBeat)")
                print("[AI Generate] Clip timeRange.start.samples = \(clip.timeRange.start.samples)")
                print("[AI Generate] Added fileReference to project.audioFiles (total: \(project.audioFiles.count))")
            }
            
        } catch {
            print("[AI Generate] Failed to import audio: \(error)")
        }
    }
    
    /// Import an external audio file (drag & drop) and place it on the timeline
    /// - Parameters:
    ///   - url: URL to the audio file
    ///   - atBeat: Beat position to place the clip
    ///   - trackID: Track ID to place the audio on
    public func importAudioFile(from url: URL, atBeat: Double, onTrack trackID: TrackID) {
        // Validate the track exists and is an audio track
        guard let track = project.tracks.first(where: { $0.id == trackID && $0.type == .audio }) else {
            print("[Import Audio] Track not found or not an audio track: \(trackID)")
            return
        }
        
        // Validate file extension
        let supportedExtensions = ["wav", "aif", "aiff", "mp3", "m4a", "caf", "flac"]
        let fileExtension = url.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            print("[Import Audio] Unsupported file format: \(fileExtension)")
            return
        }
        
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
            
            print("[Import Audio] File: \(url.lastPathComponent)")
            print("[Import Audio] Duration: \(actualDurationBeats) beats (\(actualDurationSeconds)s)")
            
            let audioData = AudioClipData(
                fileReference: fileReference,
                sourceStartSample: 0,
                sourceLengthSamples: audioFile.length
            )
            
            let startPosition = TimePosition(beats: atBeat, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
            let durationPosition = TimePosition(beats: actualDurationBeats, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
            
            let timeRange = TimeRange(
                start: startPosition,
                duration: durationPosition
            )
            
            // Use the filename (without extension) as the clip name
            let clipName = url.deletingPathExtension().lastPathComponent
            
            let clip = Clip(
                name: clipName,
                timeRange: timeRange,
                content: .audio(audioData)
            )
            
            // Add clip to track AND file reference to project
            if let trackIndex = project.tracks.firstIndex(where: { $0.id == track.id }) {
                var updatedProject = project
                updatedProject.tracks[trackIndex].clips.append(clip)
                updatedProject.audioFiles.append(fileReference)
                project = updatedProject
                print("[Import Audio] Added clip '\(clip.name)' to track: \(track.name) at beat \(atBeat)")
            }
            
        } catch {
            print("[Import Audio] Failed to import audio: \(error)")
        }
    }
    
    // MARK: - AI MIDI Generation
    
    private let claudeService = ClaudeService()
    
    /// Generate or edit MIDI notes from a text prompt using Claude
    public func generateOrEditMIDI(
        prompt: String,
        beatCount: Int,
        atBeat: Double,
        onTrackID: TrackID?,
        isEditMode: Bool
    ) async throws -> [GeneratedMIDINote] {
        let tempo = transportState.tempo.bpm
        let timeSignature = (transportState.timeSignature.numerator, transportState.timeSignature.denominator)
        let endBeat = atBeat + Double(beatCount)
        
        print("[MIDI Generate] \(isEditMode ? "EDITING" : "GENERATING") for prompt: \"\(prompt)\"")
        print("[MIDI Generate] Beat range: \(atBeat) to \(endBeat), Tempo: \(tempo)")
        
        // Extract notes from the target track (for editing) or other tracks (for context)
        var currentTrackNotes: [GeneratedMIDINote] = []
        var otherTrackNotes: [(trackName: String, notes: [GeneratedMIDINote])] = []
        
        for track in project.tracks {
            guard track.type == .midi || track.type == .instrument else { continue }
            
            var trackNotes: [GeneratedMIDINote] = []
            
            for clip in track.clips {
                guard case .midi(let midiData) = clip.content else { continue }
                
                let clipStartBeat = clip.timeRange.start.beats(atTempo: tempo)
                
                for event in midiData.events {
                    if case .note(let noteData) = event.type {
                        let absoluteBeat = clipStartBeat + event.beatPosition
                        
                        // Check if note overlaps with our target range
                        let noteEnd = absoluteBeat + noteData.duration
                        if absoluteBeat < endBeat && noteEnd > atBeat {
                            // Convert to relative beat position (0 = start of selection)
                            let relativeBeat = absoluteBeat - atBeat
                            trackNotes.append(GeneratedMIDINote(
                                pitch: Int(noteData.pitch),
                                start: max(0, relativeBeat),
                                duration: noteData.duration,
                                velocity: Int(noteData.velocity)
                            ))
                        }
                    }
                }
            }
            
            if !trackNotes.isEmpty {
                let sortedNotes = trackNotes.sorted { $0.start < $1.start }
                if track.id == onTrackID {
                    currentTrackNotes = sortedNotes
                    print("[MIDI Generate] Found \(trackNotes.count) notes to edit on target track")
                } else {
                    otherTrackNotes.append((track.name, sortedNotes))
                    print("[MIDI Generate] Found \(trackNotes.count) notes on track '\(track.name)'")
                }
            }
        }
        
        let result: MIDIGenerationResult
        
        if isEditMode && !currentTrackNotes.isEmpty {
            // Edit mode - pass current notes to be modified
            result = try await claudeService.editMIDI(
                prompt: prompt,
                currentNotes: currentTrackNotes,
                beatCount: beatCount,
                tempo: tempo,
                timeSignature: timeSignature,
                otherTrackNotes: otherTrackNotes
            )
        } else {
            // Generate mode - create new notes
            result = try await claudeService.generateMIDIWithContext(
                prompt: prompt,
                beatCount: beatCount,
                tempo: tempo,
                timeSignature: timeSignature,
                otherTrackNotes: otherTrackNotes
            )
        }
        
        print("[MIDI Generate] Generated \(result.notes.count) notes")
        
        return result.notes
    }
    
    /// Replace existing MIDI in a range with new generated notes
    public func replaceGeneratedMIDI(
        notes: [GeneratedMIDINote],
        atBeat: Double,
        beatCount: Int,
        onTrack trackID: TrackID?,
        promptLabel: String?
    ) {
        guard let trackID = trackID,
              let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else {
            print("[MIDI Replace] No valid track")
            return
        }
        
        var updatedProject = project
        let tempo = transportState.tempo.bpm
        let endBeat = atBeat + Double(beatCount)
        
        // Remove or trim existing clips that overlap with the selection
        var clipsToKeep: [Clip] = []
        
        for clip in updatedProject.tracks[trackIndex].clips {
            guard case .midi(var midiData) = clip.content else {
                clipsToKeep.append(clip)
                continue
            }
            
            let clipStartBeat = clip.timeRange.start.beats(atTempo: tempo)
            let clipEndBeat = clipStartBeat + clip.timeRange.duration.beats(atTempo: tempo)
            
            // Check if clip overlaps with selection
            if clipEndBeat <= atBeat || clipStartBeat >= endBeat {
                // No overlap - keep as is
                clipsToKeep.append(clip)
            } else {
                // Clip overlaps - filter out notes in the selection range
                var filteredEvents: [MIDIEvent] = []
                for event in midiData.events {
                    let absoluteBeat = clipStartBeat + event.beatPosition
                    if case .note(let noteData) = event.type {
                        let noteEnd = absoluteBeat + noteData.duration
                        // Keep note if it doesn't overlap with selection
                        if noteEnd <= atBeat || absoluteBeat >= endBeat {
                            filteredEvents.append(event)
                        }
                    } else {
                        // Keep non-note events
                        filteredEvents.append(event)
                    }
                }
                
                if !filteredEvents.isEmpty {
                    midiData.events = filteredEvents
                    var updatedClip = clip
                    updatedClip.content = .midi(midiData)
                    clipsToKeep.append(updatedClip)
                }
                // If no events remain, clip is effectively deleted
            }
        }
        
        // Update track with filtered clips using undo system
        var updatedTrack = updatedProject.tracks[trackIndex]
        updatedTrack.clips = clipsToKeep
        updateTrack(updatedTrack, description: "Replace MIDI (clear)")
        
        // Now insert the new notes (this also registers with undo)
        insertGeneratedMIDI(notes: notes, atBeat: atBeat, onTrack: trackID, promptLabel: promptLabel)
    }
    
    /// Insert generated MIDI notes into a clip on the timeline
    public func insertGeneratedMIDI(
        notes: [GeneratedMIDINote],
        atBeat: Double,
        onTrack trackID: TrackID?,
        promptLabel: String?
    ) {
        // Find the target track
        var midiTrack: Track
        
        if let trackID = trackID, let specifiedTrack = project.tracks.first(where: { $0.id == trackID && ($0.type == .midi || $0.type == .instrument) }) {
            midiTrack = specifiedTrack
        } else if let existingMidiTrack = project.tracks.first(where: { $0.type == .midi || $0.type == .instrument }) {
            midiTrack = existingMidiTrack
        } else {
            print("[MIDI Generate] No MIDI track found")
            return
        }
        
        // Calculate the duration in beats from the notes
        let maxEndBeat = notes.map { $0.start + $0.duration }.max() ?? 4.0
        let durationBeats = ceil(maxEndBeat)  // Round up to nearest beat
        
        // Convert GeneratedMIDINote to MIDIEvent
        var midiEvents: [MIDIEvent] = []
        for note in notes {
            let noteData = NoteData(
                pitch: UInt8(clamping: note.pitch),
                velocity: UInt8(clamping: note.velocity),
                duration: note.duration
            )
            let event = MIDIEvent(
                beatPosition: note.start,
                type: .note(noteData),
                channel: 0
            )
            midiEvents.append(event)
        }
        
        // Create MIDI clip data
        let midiData = MIDIClipData(events: midiEvents, originalTempo: transportState.tempo.bpm)
        
        // Create time positions
        let startPosition = TimePosition(beats: atBeat, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
        let durationPosition = TimePosition(beats: durationBeats, tempo: transportState.tempo.bpm, sampleRate: transportState.sampleRate)
        
        let timeRange = TimeRange(
            start: startPosition,
            duration: durationPosition
        )
        
        // Create a descriptive clip name from the prompt
        let clipName: String
        if let prompt = promptLabel, !prompt.isEmpty {
            let maxLength = 30
            let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count > maxLength {
                clipName = String(cleaned.prefix(maxLength)) + "..."
            } else {
                clipName = cleaned
            }
        } else {
            clipName = "Generated MIDI"
        }
        
        let clip = Clip(
            name: clipName,
            timeRange: timeRange,
            content: .midi(midiData)
        )
        
        // Add clip to track using undo system
        if let trackIndex = project.tracks.firstIndex(where: { $0.id == midiTrack.id }) {
            var updatedTrack = project.tracks[trackIndex]
            updatedTrack.clips.append(clip)
            updateTrack(updatedTrack, description: "Generate MIDI")
            print("[MIDI Generate] Added clip '\(clip.name)' with \(midiEvents.count) notes to track: \(midiTrack.name) at beat \(atBeat)")
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
