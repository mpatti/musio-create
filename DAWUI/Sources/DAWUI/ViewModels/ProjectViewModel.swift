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
        let trackName = name ?? "\(type.rawValue.capitalized) \(project.tracks.count + 1)"
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
    }
    
    public func setTrackVolume(id: TrackID, volume: Float) {
        guard var track = project.track(withID: id) else { return }
        track.volume = volume
        updateTrack(track, description: "Change Volume")
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
    
    public func closePianoRoll() {
        editingClipID = nil
        showPianoRoll = false
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
