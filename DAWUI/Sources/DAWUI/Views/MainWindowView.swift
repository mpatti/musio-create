import SwiftUI
import CoreAudio
import DAWCore
import UniformTypeIdentifiers

// MARK: - Main Window View

public struct MainWindowView: View {
    @StateObject private var viewModel: ProjectViewModel
    
    // Global key monitor for keyboard shortcuts
    @State private var keyMonitor = GlobalKeyMonitor()

    // Observe transportState directly to get playhead updates
    @State private var playheadPosition: Double = 0

    @State private var mixerHeight: CGFloat = 280
    @State private var pianoRollHeight: CGFloat = 500
    @State private var showCreateClipDialog: Bool = false
    @State private var createClipTrackID: TrackID?
    @State private var horizontalScrollOffset: CGFloat = 0
    @State private var showVRack: Bool = false
    
    // AI Generation Mode (Generative Fill)
    @State private var isAIGenerationMode: Bool = false
    @State private var aiSelectionStart: CGFloat? = nil
    @State private var aiSelectionEnd: CGFloat? = nil
    @State private var aiSelectionTrackY: CGFloat? = nil  // Y position of the selected track
    @State private var aiSelectionTrackID: TrackID? = nil  // ID of the selected track
    @State private var showAIPromptDialog: Bool = false  // Audio generation dialog
    @State private var showMIDIPromptDialog: Bool = false  // MIDI generation dialog
    @State private var aiPromptText: String = ""
    @State private var isAIGenerating: Bool = false
    @State private var aiGenerationMode: AIAudioModel = .elevenLabsSFX
    @State private var aiErrorMessage: String? = nil
    @State private var midiSelectionHasExistingContent: Bool = false
    @State private var midiSelectionNoteCount: Int = 0
    @State private var showAIError: Bool = false
    
    // ElevenLabs credits
    @State private var elevenLabsCredits: ElevenLabsSubscriptionInfo? = nil
    private let elevenLabsService = ElevenLabsService()
    
    // Bar jump mode state
    @State private var isBarJumpMode: Bool = false
    @State private var barJumpInput: String = ""
    
    // Track drag & drop reordering
    @State private var draggedTrackID: TrackID? = nil
    @State private var dropTargetIndex: Int? = nil

    private let trackHeight: CGFloat = 80
    private let rulerHeight: CGFloat = 30
    private let trackHeaderWidth: CGFloat = 200
    
    public init(project: Project = ProjectFactory.createNewProject()) {
        _viewModel = StateObject(wrappedValue: ProjectViewModel(project: project))
        // Initialize UI state from project's dawState
        _showVRack = State(initialValue: project.dawState.showVRack)
        _horizontalScrollOffset = State(initialValue: CGFloat(project.dawState.horizontalScrollOffset))
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            TransportView(viewModel: viewModel)
            Divider()
            
            HStack(spacing: 0) {
                // V-Rack sidebar (left side)
                if showVRack {
                    VRackView(viewModel: viewModel)
                        .frame(width: 220)
                    Divider()
                }
                
                arrangeView
                    .simultaneousGesture(
                        TapGesture().onEnded { _ in
                            // Clear focus from text fields when clicking in arrange area
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    )

                if viewModel.showInspector {
                    Divider()
                    InspectorView(viewModel: viewModel)
                        .frame(width: 250)  // Fixed width
                }
                
                if viewModel.showAIAssistant {
                    Divider()
                    AIAssistantView(viewModel: viewModel, isGenerativeFillMode: $isAIGenerationMode)
                        .frame(width: 320)  // Fixed width for AI panel
                }
            }
            
                if viewModel.showMixer || viewModel.showPianoRoll {
                // Draggable resize handle
                ResizeHandle(height: viewModel.showPianoRoll ? $pianoRollHeight : $mixerHeight)
                
                bottomPanel
                    .frame(height: viewModel.showPianoRoll ? pianoRollHeight : mixerHeight)
                    .simultaneousGesture(
                        TapGesture().onEnded { _ in
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    )
            }
        }
        .frame(minWidth: 1200, minHeight: 700)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAIPromptDialog) {
            AIPromptDialogView(
                prompt: $aiPromptText,
                selectedModel: $aiGenerationMode,
                isPresented: $showAIPromptDialog,
                beatCount: aiSelectedBeatCount,
                previousClip: findPreviousAIClip(),
                tempo: viewModel.transportState.tempo.bpm,
                onGenerate: { prompt, model, continuationContext in
                    generateAIAudioForSelection(prompt: prompt, model: model, continuationContext: continuationContext)
                }
            )
        }
        .sheet(isPresented: $showMIDIPromptDialog) {
            MIDIPromptDialogView(
                prompt: $aiPromptText,
                isPresented: $showMIDIPromptDialog,
                beatCount: aiSelectedBeatCount,
                trackName: aiSelectionTrackID.flatMap { id in viewModel.project.tracks.first { $0.id == id }?.name } ?? "MIDI Track",
                hasExistingMIDI: midiSelectionHasExistingContent,
                existingNoteCount: midiSelectionNoteCount,
                onGenerate: { prompt in
                    generateMIDIForSelection(prompt: prompt)
                }
            )
        }
        .onChange(of: showAIPromptDialog) { _, isOpen in
            keyMonitor.isDisabled = isOpen
            // Don't clear selection when dialog closes - we might be generating
        }
        .onChange(of: showMIDIPromptDialog) { _, isOpen in
            keyMonitor.isDisabled = isOpen
            // Don't clear selection when dialog closes - we might be generating
        }
        .alert("AI Generation Error", isPresented: $showAIError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(aiErrorMessage ?? "An unknown error occurred")
        }
        .onChange(of: isAIGenerationMode) { _, isActive in
            // Only clear selection if we're exiting AI mode AND not currently generating
            if !isActive && !isAIGenerating {
                clearAISelection()
            }
        }
        .handleKeyboardShortcuts(viewModel: viewModel)
        .overlay(alignment: .center) {
            if !viewModel.isEngineReady {
                loadingOverlay
            }
        }
        .overlay(alignment: .top) {
            if isBarJumpMode {
                barJumpOverlay
            }
        }
        .onAppear { 
            setupInitialState() 
        }
        .onDisappear {
            // Stop keyboard monitor when view disappears (e.g., project reload)
            keyMonitor.stop()
        }
        .onReceive(viewModel.transportState.$playheadBeats) { beats in
            playheadPosition = beats
        }
        .onChange(of: showVRack) { _, newValue in
            syncDAWState()
        }
        // Handle plugin state notifications
        .onReceive(NotificationCenter.default.publisher(for: .savePluginStates)) { _ in
            syncDAWState()
            viewModel.saveAllPluginStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearAllPlugins)) { _ in
            viewModel.clearAllPlugins()
        }
        .onReceive(NotificationCenter.default.publisher(for: .restorePluginStates)) { _ in
            Task {
                await viewModel.restoreAllPluginStates()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestProjectForSave)) { _ in
            // Send current project back for saving
            NotificationCenter.default.post(name: .projectDataForSave, object: viewModel.project)
        }
    }
    
    /// Sync current UI state to project.dawState for persistence
    private func syncDAWState() {
        viewModel.project.dawState.showVRack = showVRack
        viewModel.project.dawState.horizontalScrollOffset = Double(horizontalScrollOffset)
        viewModel.project.dawState.zoomLevel = viewModel.zoomLevel
        viewModel.project.dawState.selectedTrackID = viewModel.selectedTrack?.id
        viewModel.project.dawState.playheadPosition = viewModel.transportState.playheadBeats
    }
    
    // MARK: - Arrange View (Track List + Timeline)
    
    private var arrangeView: some View {
        HStack(spacing: 0) {
            // Left side: Track headers (fixed)
            VStack(spacing: 0) {
                // Tracks label header
                HStack {
                    Text("Tracks")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Menu {
                        Button("Audio Track") { viewModel.addTrack(type: .audio) }
                        Button("MIDI Track") { viewModel.addTrack(type: .midi) }
                        Button("Instrument Track") { viewModel.addTrack(type: .instrument) }
                    } label: {
                        Image(systemName: "plus").font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
                .frame(height: rulerHeight)
                .padding(.horizontal, 8)
                .background(Color(nsColor: .windowBackgroundColor))
                
                Divider()
                
                // Track headers (scrollable vertically) with drag & drop reordering
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.project.tracks.enumerated()), id: \.element.id) { index, track in
                            VStack(spacing: 0) {
                                // Drop indicator line above track
                                if dropTargetIndex == index && draggedTrackID != nil && draggedTrackID != track.id {
                                    Rectangle()
                                        .fill(Color.accentColor)
                                        .frame(height: 3)
                                }
                                
                                TrackHeaderView(track: track, viewModel: viewModel)
                                    .frame(width: trackHeaderWidth, height: trackHeight)
                                    .background(viewModel.selectedTrackID == track.id ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                                    .opacity(draggedTrackID == track.id ? 0.5 : 1.0)
                                    .onDrag {
                                        draggedTrackID = track.id
                                        return NSItemProvider(object: track.id.rawValue.uuidString as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: TrackDropDelegate(
                                        trackIndex: index,
                                        draggedTrackID: $draggedTrackID,
                                        dropTargetIndex: $dropTargetIndex,
                                        viewModel: viewModel
                                    ))
                            }
                        }
                        
                        // Drop zone at bottom (for dropping at end of track list)
                        VStack(spacing: 0) {
                            // Drop indicator line
                            if dropTargetIndex == viewModel.project.tracks.count && draggedTrackID != nil {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 3)
                            }
                            
                            // Spacer to provide drop target area
                            Spacer(minLength: trackHeight)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onDrop(of: [.text], delegate: TrackDropDelegate(
                            trackIndex: viewModel.project.tracks.count,
                            draggedTrackID: $draggedTrackID,
                            dropTargetIndex: $dropTargetIndex,
                            viewModel: viewModel
                        ))
                    }
                }
            }
            .frame(width: trackHeaderWidth)
            
            Divider()
            
            // Right side: Timeline (ruler + tracks with ONE playhead)
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        // Ruler
                        TimelineRulerContent(viewModel: viewModel)
                            .frame(height: rulerHeight)
                        
                        Divider()
                        
                        // Track lanes (scrollable vertically)
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 0) {
                                ForEach(viewModel.project.tracks) { track in
                                    TrackLaneView(
                                        track: track,
                                        viewModel: viewModel,
                                        height: trackHeight
                                    )
                                }
                            }
                        }
                    }
                    
                    // AI Selection overlay (when in AI generation mode) - only on the audio track
                    if isAIGenerationMode || isAIGenerating,
                       let start = aiSelectionStart,
                       let end = aiSelectionEnd,
                       let trackY = aiSelectionTrackY {
                        let minX = min(start, end)
                        let maxX = max(start, end)
                        
                        AISelectionOverlay(
                            width: maxX - minX,
                            height: trackHeight,
                            isGenerating: isAIGenerating
                        )
                        .offset(x: minX, y: rulerHeight + trackY)
                        .allowsHitTesting(false)
                    }
                    
                    // SINGLE playhead line spanning entire height (non-interactive)
                    PlayheadView(position: playheadPosition, pixelsPerBeat: viewModel.pixelsPerBeat)
                        .allowsHitTesting(false)
                    
                    // AI Generation mode drag overlay
                    if isAIGenerationMode {
                        aiSelectionDragOverlay
                    }
                }
                .frame(width: max(1200, viewModel.pixelsPerBeat * 64))
            }
        }
    }
    
    // MARK: - Bottom Panel
    
    @ViewBuilder
    private var bottomPanel: some View {
        if viewModel.showPianoRoll {
            // Piano roll panel - show track-based MIDI editor
            if let trackID = viewModel.selectedTrackID,
               let track = viewModel.project.track(withID: trackID),
               (track.type == .midi || track.type == .instrument) {
                // MIDI track selected - show track-based piano roll (all MIDI on track)
                TrackPianoRollView(viewModel: viewModel, trackID: trackID)
            } else {
                // No MIDI track selected - show placeholder
                PianoRollPlaceholderView()
            }
        } else if viewModel.showMixer {
            MixerView(viewModel: viewModel)
        }
    }
    
    private var loadingOverlay: some View {
        VStack {
            ProgressView()
            Text("Initializing audio engine...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }
    
    private var barJumpOverlay: some View {
        HStack(spacing: 8) {
            Text("Go to bar:")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            
            Text(barJumpInput.isEmpty ? "_" : barJumpInput)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.accentColor)
                .frame(minWidth: 60)
            
            Text("↵")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.2), radius: 10)
        .padding(.top, 80)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeOut(duration: 0.15), value: isBarJumpMode)
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: { viewModel.undo() }) {
                Image(systemName: "arrow.uturn.backward")
            }.disabled(!viewModel.undoManager.canUndo)
            
            Button(action: { viewModel.redo() }) {
                Image(systemName: "arrow.uturn.forward")
            }.disabled(!viewModel.undoManager.canRedo)
        }
        
        ToolbarItemGroup(placement: .principal) {
            HStack(spacing: 4) {
                Button(action: { viewModel.zoomOut() }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                Text("\(Int(viewModel.zoomLevel * 100))%")
                    .font(.caption).frame(width: 40)
                Button(action: { viewModel.zoomIn() }) {
                    Image(systemName: "plus.magnifyingglass")
                }
            }
        }
        
        ToolbarItemGroup(placement: .primaryAction) {
            // ElevenLabs credits display (only show if we have credits info)
            if let credits = elevenLabsCredits {
                ElevenLabsCreditsView(info: credits)
            }
            
            Toggle(isOn: $viewModel.showAIAssistant) {
                Image(systemName: "sparkles")
            }
            .toggleStyle(.button)
            .tint(viewModel.showAIAssistant ? .purple : nil)
            .help("Toggle AI Assistant")
            
            Toggle(isOn: $showVRack) {
                Image(systemName: "pianokeys")
            }
            .help("Toggle Instruments Panel")

            Toggle(isOn: $viewModel.showPianoRoll) {
                Image(systemName: "rectangle.split.3x1")
            }
            .help("Toggle MIDI Editor Panel")
            
            Toggle(isOn: $viewModel.showMixer) {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Toggle Mixer Panel")
            
            Toggle(isOn: $viewModel.showInspector) {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle Inspector Panel")
        }
    }
    
    private func fetchElevenLabsCredits() {
        Task {
            do {
                let info = try await elevenLabsService.getSubscriptionInfo()
                await MainActor.run {
                    elevenLabsCredits = info
                }
            } catch {
                // If we get a 401 error, the API key likely doesn't have user_read permission
                // This is fine - credits display is optional
                print("[MainWindow] Could not fetch ElevenLabs credits (API key may need 'user_read' permission)")
            }
        }
    }
    
    private func setupInitialState() {
        if let firstTrack = viewModel.project.tracks.first {
            viewModel.selectTrack(firstTrack.id)
        }
        if let midiTrack = viewModel.project.tracks.first(where: { $0.type == .midi }) {
            if midiTrack.clips.isEmpty {
                viewModel.createMIDIClip(on: midiTrack.id, at: TimePosition(), duration: 4.0)
            }
        }

        // Setup MIDI
        Task {
            await viewModel.setupMIDI()
        }
        
        // Setup global keyboard shortcuts
        keyMonitor.viewModel = viewModel
        keyMonitor.onBarJumpModeChanged = { isActive, input in
            isBarJumpMode = isActive
            barJumpInput = input
        }
        keyMonitor.start()
        
        // Fetch ElevenLabs credits (optional - requires API key with user_read permission)
        fetchElevenLabsCredits()
    }
    
    // MARK: - AI Generation Mode
    
    /// Computed property for the number of beats selected
    private var aiSelectedBeatCount: Int {
        guard let start = aiSelectionStart, let end = aiSelectionEnd else { return 0 }
        let minX = min(start, end)
        let maxX = max(start, end)
        let beats = (maxX - minX) / viewModel.pixelsPerBeat
        return max(1, Int(round(beats)))
    }
    
    /// Computed property for the start beat of the selection
    private var aiSelectionStartBeat: Double {
        guard let start = aiSelectionStart, let end = aiSelectionEnd else { return 0 }
        let minX = min(start, end)
        return minX / viewModel.pixelsPerBeat
    }
    
    /// Drag overlay for AI selection - only works on audio tracks
    private var aiSelectionDragOverlay: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            // Calculate which track the drag started on
                            let trackIndex = Int(value.startLocation.y / trackHeight)
                            let tracks = viewModel.project.tracks

                            // Only allow selection on audio, MIDI, and instrument tracks
                            guard trackIndex >= 0 && trackIndex < tracks.count,
                                  tracks[trackIndex].type == .audio || 
                                  tracks[trackIndex].type == .midi || 
                                  tracks[trackIndex].type == .instrument else {
                                clearAISelection()
                                return
                            }
                            
                            // Set the track Y position and track ID
                            aiSelectionTrackY = CGFloat(trackIndex) * trackHeight
                            aiSelectionTrackID = tracks[trackIndex].id
                            
                            // Snap start position to beat grid
                            let startBeat = floor(value.startLocation.x / viewModel.pixelsPerBeat)
                            aiSelectionStart = startBeat * viewModel.pixelsPerBeat
                            
                            // Snap end position to beat grid
                            let endBeat = round(value.location.x / viewModel.pixelsPerBeat)
                            aiSelectionEnd = endBeat * viewModel.pixelsPerBeat
                        }
                        .onEnded { value in
                            // Ensure we have at least 1 beat selected and a valid track
                            if aiSelectedBeatCount >= 1, let trackID = aiSelectionTrackID {
                                // Determine track type and show appropriate dialog
                                if let track = viewModel.project.tracks.first(where: { $0.id == trackID }) {
                                    aiPromptText = ""
                                    if track.type == .midi || track.type == .instrument {
                                        // Check for existing MIDI in selection
                                        let (hasContent, noteCount) = checkForExistingMIDI(
                                            track: track,
                                            startBeat: aiSelectionStartBeat,
                                            endBeat: aiSelectionStartBeat + Double(aiSelectedBeatCount)
                                        )
                                        midiSelectionHasExistingContent = hasContent
                                        midiSelectionNoteCount = noteCount
                                        
                                        // MIDI track - show MIDI generation dialog
                                        showMIDIPromptDialog = true
                                    } else if track.type == .audio {
                                        // Audio track - show audio generation dialog
                                        showAIPromptDialog = true
                                    } else {
                                        clearAISelection()
                                    }
                                } else {
                                    clearAISelection()
                                }
                            } else {
                                clearAISelection()
                            }
                        }
                )
        }
        .offset(y: rulerHeight) // Start below the ruler
    }
    
    /// Clear the AI selection
    private func clearAISelection() {
        aiSelectionStart = nil
        aiSelectionEnd = nil
        aiSelectionTrackY = nil
        aiSelectionTrackID = nil
        isAIGenerating = false
        midiSelectionHasExistingContent = false
        midiSelectionNoteCount = 0
    }
    
    /// Check if there's existing MIDI content in the selection
    private func checkForExistingMIDI(track: Track, startBeat: Double, endBeat: Double) -> (hasContent: Bool, noteCount: Int) {
        var noteCount = 0
        let tempo = viewModel.transportState.tempo.bpm
        
        for clip in track.clips {
            guard case .midi(let midiData) = clip.content else { continue }
            
            let clipStartBeat = clip.timeRange.start.beats(atTempo: tempo)
            
            for event in midiData.events {
                if case .note(let noteData) = event.type {
                    let absoluteBeat = clipStartBeat + event.beatPosition
                    let noteEnd = absoluteBeat + noteData.duration
                    
                    // Check if note overlaps with selection
                    if absoluteBeat < endBeat && noteEnd > startBeat {
                        noteCount += 1
                    }
                }
            }
        }
        
        return (noteCount > 0, noteCount)
    }
    
    /// Generate AI audio for the selected range
    private func generateAIAudioForSelection(prompt: String, model: AIAudioModel, continuationContext: ContinuationContext? = nil) {
        let startBeat = aiSelectionStartBeat
        let beatCount = aiSelectedBeatCount
        
        // Capture selection values before any state changes
        let selStart = aiSelectionStart
        let selEnd = aiSelectionEnd
        let selTrackY = aiSelectionTrackY
        let selTrackID = aiSelectionTrackID
        
        print("[Generative Fill] Starting generation - model: \(model.displayName), track: \(selTrackID?.rawValue.uuidString ?? "nil")")
        if continuationContext != nil {
            print("[Generative Fill] CONTINUATION MODE enabled")
        }
        
        // IMPORTANT: Set isAIGenerating FIRST so the onChange doesn't clear selection
        isAIGenerating = true
        isAIGenerationMode = false
        
        // Ensure selection values are preserved
        aiSelectionStart = selStart
        aiSelectionEnd = selEnd
        aiSelectionTrackY = selTrackY
        aiSelectionTrackID = selTrackID
        
        Task {
            do {
                // Generate the audio with selected model and optional continuation context
                print("[AI Generate] Calling \(model.displayName) API...")
                let audioURL = try await viewModel.generateAIAudio(prompt: prompt, beats: beatCount, model: model, continuationContext: continuationContext)
                print("[AI Generate] API returned, importing audio...")
                
                // Import it at the selected position on the selected track
                await MainActor.run {
                    viewModel.importGeneratedAudio(from: audioURL, atBeat: startBeat, durationBeats: Double(beatCount), onTrack: selTrackID, promptLabel: prompt)
                    // Clear the selection after import
                    print("[AI Generate] Import complete, clearing selection")
                    clearAISelection()
                    // Refresh credits after generation
                    fetchElevenLabsCredits()
                }
            } catch {
                print("[AI Generate] Error: \(error)")
                await MainActor.run {
                    clearAISelection()
                    aiErrorMessage = error.localizedDescription
                    showAIError = true
                }
            }
        }
    }
    
    /// Generate MIDI for the selected range
    private func generateMIDIForSelection(prompt: String) {
        let startBeat = aiSelectionStartBeat
        let beatCount = aiSelectedBeatCount
        let isEditMode = midiSelectionHasExistingContent
        
        // Capture selection values before any state changes
        let selStart = aiSelectionStart
        let selEnd = aiSelectionEnd
        let selTrackY = aiSelectionTrackY
        let selTrackID = aiSelectionTrackID
        
        print("[MIDI Generate] \(isEditMode ? "EDIT MODE" : "CREATE MODE") for: \"\(prompt)\"")
        print("[MIDI Generate] Beat range: \(startBeat) to \(startBeat + Double(beatCount))")
        
        // IMPORTANT: Set isAIGenerating FIRST so the onChange doesn't clear selection
        isAIGenerating = true
        isAIGenerationMode = false
        
        // Ensure selection values are preserved
        aiSelectionStart = selStart
        aiSelectionEnd = selEnd
        aiSelectionTrackY = selTrackY
        aiSelectionTrackID = selTrackID
        
        Task {
            do {
                // Generate the MIDI notes
                print("[MIDI Generate] Calling Claude API...")
                let notes = try await viewModel.generateOrEditMIDI(
                    prompt: prompt,
                    beatCount: beatCount,
                    atBeat: startBeat,
                    onTrackID: selTrackID,
                    isEditMode: isEditMode
                )
                print("[MIDI Generate] API returned \(notes.count) notes")
                
                // Insert/replace notes at the selected position on the selected track
                await MainActor.run {
                    if isEditMode {
                        // Remove existing MIDI in selection range, then add new
                        viewModel.replaceGeneratedMIDI(
                            notes: notes,
                            atBeat: startBeat,
                            beatCount: beatCount,
                            onTrack: selTrackID,
                            promptLabel: prompt
                        )
                    } else {
                        viewModel.insertGeneratedMIDI(
                            notes: notes,
                            atBeat: startBeat,
                            onTrack: selTrackID,
                            promptLabel: prompt
                        )
                    }
                    // Clear the selection after import
                    print("[MIDI Generate] \(isEditMode ? "Replace" : "Insert") complete, clearing selection")
                    clearAISelection()
                }
            } catch {
                print("[MIDI Generate] Error: \(error)")
                await MainActor.run {
                    clearAISelection()
                    aiErrorMessage = error.localizedDescription
                    showAIError = true
                }
            }
        }
    }
    
    /// Find the most recent AI-generated clip on the first audio track
    private func findPreviousAIClip() -> Clip? {
        // Look for the first audio track
        guard let audioTrack = viewModel.project.tracks.first(where: { $0.type == .audio }) else {
            return nil
        }
        
        // Find AI-generated clips (clips whose name suggests AI generation)
        let aiClips = audioTrack.clips.filter { clip in
            // Check if it's an audio clip
            guard case .audio = clip.content else { return false }
            
            let name = clip.name.lowercased()
            
            // Heuristics for AI-generated content:
            // Contains common audio generation keywords or isn't a standard file name
            let aiKeywords = ["loop", "drum", "beat", "pad", "ambient", "sfx", "percussion", 
                             "cinematic", "riser", "hit", "texture", "drone", "bass", "synth",
                             "piano", "strings", "brass", "guitar", "vocal", "choir", "epic",
                             "trailer", "electronic", "chill", "upbeat", "dark", "bright"]
            
            let containsKeyword = aiKeywords.contains { name.contains($0) }
            let isLikelyAI = containsKeyword || 
                            (!name.hasSuffix(".wav") && 
                             !name.hasSuffix(".mp3") && 
                             !name.hasSuffix(".aif") &&
                             clip.name != "Generated Audio")
            
            return isLikelyAI
        }
        
        // Return the most recent clip (by position on timeline)
        return aiClips.max(by: { $0.timeRange.start.samples < $1.timeRange.start.samples })
    }
}

// MARK: - Generative Fill Selection Overlay with Glow Effect

struct AISelectionOverlay: View {
    let width: CGFloat
    let height: CGFloat
    let isGenerating: Bool
    
    @State private var gradientRotation: Double = 0
    @State private var pulseOpacity: Double = 0.3
    @State private var shimmerOffset: CGFloat = -0.5
    
    var body: some View {
        ZStack {
            if isGenerating {
                // Outer glow layers (multiple for intensity) - centered behind main rect
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.purple.opacity(0.2))
                    .frame(width: width, height: height)
                    .blur(radius: 20)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.cyan.opacity(0.15))
                    .frame(width: width, height: height)
                    .blur(radius: 25)
                    .opacity(pulseOpacity * 2)
                
                // Main container - all elements share exact same frame
                ZStack {
                    // Inner fill
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.purple.opacity(0.35),
                                    Color.blue.opacity(0.25),
                                    Color.purple.opacity(0.35)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    // Shimmer effect - full width sweep
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    .white.opacity(0.4),
                                    .white.opacity(0.5),
                                    .white.opacity(0.4),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width * 0.4)
                        .offset(x: shimmerOffset * width)
                    
                    // Animated gradient border
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            AngularGradient(
                                colors: [.purple, .pink, .cyan, .blue, .purple],
                                center: .center,
                                angle: .degrees(gradientRotation)
                            ),
                            lineWidth: 3
                        )
                        .shadow(color: .purple.opacity(0.9), radius: 10)
                        .shadow(color: .cyan.opacity(0.7), radius: 15)
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                
            } else {
                // Static selection rectangle (before generation)
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.purple.opacity(0.25),
                                    Color.blue.opacity(0.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.purple.opacity(0.7), lineWidth: 2)
                }
                .frame(width: width, height: height)
            }
        }
        .onAppear {
            if isGenerating {
                startAnimations()
            }
        }
        .onChange(of: isGenerating) { _, generating in
            if generating {
                startAnimations()
            }
        }
    }
    
    private func startAnimations() {
        // Rotating gradient border
        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
            gradientRotation = 360
        }
        
        // Pulsing glow
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.8
        }
        
        // Shimmer sweep - full width travel
        shimmerOffset = -0.5
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            shimmerOffset = 1.0
        }
    }
}

// MARK: - AI Prompt Dialog View

struct AIPromptDialogView: View {
    @Binding var prompt: String
    @Binding var selectedModel: AIAudioModel
    @Binding var isPresented: Bool
    let beatCount: Int
    let previousClip: Clip?  // Previous AI-generated clip for continuation
    let tempo: Double  // Project tempo for calculating beats
    let onGenerate: (String, AIAudioModel, ContinuationContext?) -> Void
    
    @FocusState private var isPromptFocused: Bool
    @State private var subscriptionInfo: ElevenLabsSubscriptionInfo?
    @State private var isLoadingCredits: Bool = false
    @State private var continueFromPrevious: Bool = false
    
    private let elevenLabsService = ElevenLabsService()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with gradient
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "wand.and.stars")
                        .font(.title2)
                        .foregroundStyle(
                            LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    
                    Text("Generative Fill")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    // Beat count badge
                    Text("\(beatCount) beat\(beatCount == 1 ? "" : "s")")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.purple.opacity(0.2))
                        )
                        .foregroundColor(.purple)
                }
                
                // Credits display row
                HStack {
                    Spacer()
                    if isLoadingCredits {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.5)
                            Text("Loading credits...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else if let info = subscriptionInfo {
                        creditsView(info: info)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            
            Divider()
                .opacity(0.5)
            
            // Model selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(spacing: 6) {
                    ForEach(AIAudioModel.allCases) { model in
                        Button {
                            selectedModel = model
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: model.icon)
                                    .font(.system(size: 14))
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text(model.description)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if selectedModel == model {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedModel == model ? modelAccentColor(model).opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        selectedModel == model ? modelAccentColor(model) : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(selectedModel == model ? modelAccentColor(model) : .primary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            
            // Continuation toggle (only show if there's a previous AI clip)
            if let prevClip = previousClip {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $continueFromPrevious) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(continueFromPrevious ? .purple : .secondary)
                            Text("Continue from previous")
                                .font(.subheadline)
                        }
                    }
                    .toggleStyle(.checkbox)
                    
                    if continueFromPrevious {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Continuing: \"\(prevClip.name)\"")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 22)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            
            // Prompt input area
            VStack(alignment: .leading, spacing: 12) {
                Text("Describe the sound")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextField(selectedModel.promptPlaceholder, text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: isPromptFocused ? [.purple.opacity(0.8), .blue.opacity(0.6)] : [.gray.opacity(0.3)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: isPromptFocused ? 2 : 1
                                    )
                            )
                    )
                    .focused($isPromptFocused)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            
            // Action buttons
            HStack(spacing: 12) {
                Button {
                    isPresented = false
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .keyboardShortcut(.cancelAction)
                
                Button {
                    guard !prompt.isEmpty else { return }
                    isPresented = false
                    
                    // Build continuation context if enabled
                    var continuationContext: ContinuationContext? = nil
                    if continueFromPrevious, let prevClip = previousClip {
                        let previousBeats = Int(prevClip.timeRange.duration.beats(atTempo: tempo))
                        continuationContext = ContinuationContext(
                            previousPrompt: prevClip.name,
                            previousBeats: previousBeats,
                            previousClipName: prevClip.name
                        )
                    }
                    
                    onGenerate(prompt, selectedModel, continuationContext)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selectedModel.icon)
                        Text("Generate")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .foregroundColor(.white)
                .background(
                    Group {
                        if prompt.isEmpty {
                            RoundedRectangle(cornerRadius: 8).fill(Color.gray)
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(
                                LinearGradient(
                                    colors: generateButtonColors(for: selectedModel),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        }
                    }
                )
                .disabled(prompt.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    LinearGradient(
                        colors: [.purple.opacity(0.3), .blue.opacity(0.2), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 20)
        .onAppear {
            isPromptFocused = true
            fetchCredits()
        }
    }
    
    @ViewBuilder
    private func creditsView(info: ElevenLabsSubscriptionInfo) -> some View {
        HStack(spacing: 4) {
            // Credit icon
            Image(systemName: creditIcon(for: info))
                .font(.caption2)
                .foregroundColor(creditColor(for: info))
            
            // Remaining credits
            Text("\(info.remainingCreditsText) credits")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(creditColor(for: info))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(creditColor(for: info).opacity(0.15))
        )
        .help("ElevenLabs credits remaining: \(info.remainingCharacters) / \(info.characterLimit)")
    }
    
    private func creditIcon(for info: ElevenLabsSubscriptionInfo) -> String {
        if info.remainingPercentage < 0.1 {
            return "exclamationmark.triangle.fill"
        } else if info.remainingPercentage < 0.3 {
            return "chart.bar.fill"
        } else {
            return "sparkles"
        }
    }
    
    private func creditColor(for info: ElevenLabsSubscriptionInfo) -> Color {
        if info.remainingPercentage < 0.1 {
            return .red
        } else if info.remainingPercentage < 0.3 {
            return .orange
        } else {
            return .green
        }
    }
    
    private func modelAccentColor(_ model: AIAudioModel) -> Color {
        switch model {
        case .elevenLabsSFX:
            return .purple
        case .elevenLabsMusic:
            return .pink
        case .miniMaxMusic:
            return .blue
        }
    }
    
    private func generateButtonColors(for model: AIAudioModel) -> [Color] {
        switch model {
        case .elevenLabsSFX:
            return [.purple, .blue]
        case .elevenLabsMusic:
            return [.pink, .orange]
        case .miniMaxMusic:
            return [.blue, .cyan]
        }
    }

    private func fetchCredits() {
        print("[AIPromptDialog] Starting credit fetch...")
        isLoadingCredits = true
        Task {
            do {
                let info = try await elevenLabsService.getSubscriptionInfo()
                print("[AIPromptDialog] Credits fetched: \(info.remainingCharacters) / \(info.characterLimit)")
                await MainActor.run {
                    subscriptionInfo = info
                    isLoadingCredits = false
                }
            } catch {
                print("[AIPromptDialog] Failed to fetch credits: \(error)")
                await MainActor.run {
                    isLoadingCredits = false
                }
            }
        }
    }
}

// MARK: - MIDI Prompt Dialog View

struct MIDIPromptDialogView: View {
    @Binding var prompt: String
    @Binding var isPresented: Bool
    let beatCount: Int
    let trackName: String
    let hasExistingMIDI: Bool
    let existingNoteCount: Int
    let onGenerate: (String) -> Void
    
    @FocusState private var isPromptFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with gradient
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: hasExistingMIDI ? "pencil.and.outline" : "pianokeys")
                        .font(.title2)
                        .foregroundStyle(
                            LinearGradient(
                                colors: hasExistingMIDI ? [.orange, .yellow] : [.cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    Text(hasExistingMIDI ? "Edit MIDI" : "Generate MIDI")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    // Beat count badge
                    Text("\(beatCount) beats")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(hasExistingMIDI ? Color.orange.opacity(0.2) : Color.cyan.opacity(0.2))
                        )
                        .foregroundColor(hasExistingMIDI ? .orange : .cyan)
                }
                
                // Track indicator
                HStack {
                    Text("on \(trackName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if hasExistingMIDI {
                        Text("• \(existingNoteCount) notes selected")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            
            Divider()
                .opacity(0.5)
            
            // Prompt input area
            VStack(alignment: .leading, spacing: 12) {
                Text(hasExistingMIDI ? "How do you want to change it?" : "What do you want to create?")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextField(placeholderText, text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: isPromptFocused 
                                                ? (hasExistingMIDI ? [.orange.opacity(0.8), .yellow.opacity(0.6)] : [.cyan.opacity(0.8), .blue.opacity(0.6)]) 
                                                : [.gray.opacity(0.3)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: isPromptFocused ? 2 : 1
                                    )
                            )
                    )
                    .focused($isPromptFocused)
                
                Text(hasExistingMIDI 
                    ? "AI will modify the existing notes based on your instructions" 
                    : "AI will analyze existing MIDI and create complementary content")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            
            // Action buttons
            HStack(spacing: 12) {
                Button {
                    isPresented = false
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .keyboardShortcut(.cancelAction)
                
                Button {
                    guard !prompt.isEmpty else { return }
                    isPresented = false
                    onGenerate(prompt)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: hasExistingMIDI ? "wand.and.rays" : "wand.and.stars")
                        Text(hasExistingMIDI ? "Apply" : "Generate")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .foregroundColor(.white)
                .background(
                    Group {
                        if prompt.isEmpty {
                            RoundedRectangle(cornerRadius: 8).fill(Color.gray)
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(
                                LinearGradient(
                                    colors: hasExistingMIDI ? [.orange, .yellow] : [.cyan, .blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        }
                    }
                )
                .disabled(prompt.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    LinearGradient(
                        colors: hasExistingMIDI 
                            ? [.orange.opacity(0.3), .yellow.opacity(0.2), .clear]
                            : [.cyan.opacity(0.3), .blue.opacity(0.2), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 20)
        .onAppear {
            isPromptFocused = true
        }
    }
    
    private var placeholderText: String {
        if hasExistingMIDI {
            return "e.g., make it more energetic, transpose up an octave, add variations..."
        } else {
            return "e.g., strings, bass line, piano chords, drums..."
        }
    }
}

// MARK: - ElevenLabs Credits View (Toolbar)

struct ElevenLabsCreditsView: View {
    let info: ElevenLabsSubscriptionInfo
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: creditIcon)
                .font(.caption2)
                .foregroundColor(creditColor)
            
            Text("\(info.remainingCreditsText)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(creditColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(creditColor.opacity(0.15))
        )
        .help("ElevenLabs credits: \(info.remainingCharacters) / \(info.characterLimit) remaining")
    }
    
    private var creditIcon: String {
        if info.remainingPercentage < 0.1 {
            return "exclamationmark.triangle.fill"
        } else if info.remainingPercentage < 0.3 {
            return "chart.bar.fill"
        } else {
            return "sparkles"
        }
    }
    
    private var creditColor: Color {
        if info.remainingPercentage < 0.1 {
            return .red
        } else if info.remainingPercentage < 0.3 {
            return .orange
        } else {
            return .green
        }
    }
}

// MARK: - Track Grid View (grid lines for a single track row)

struct TrackGridView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let height: CGFloat
    
    var body: some View {
        Canvas { context, size in
            let pixelsPerBeat = viewModel.pixelsPerBeat
            let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
            let totalBeats = Int(size.width / pixelsPerBeat) + 1
            
            // Vertical beat lines
            for beat in 0..<totalBeats {
                let x = CGFloat(beat) * pixelsPerBeat
                let isBar = beat % beatsPerBar == 0
                
                let path = Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }
                
                context.stroke(
                    path,
                    with: .color(isBar ? Color.gray.opacity(0.4) : Color.gray.opacity(0.15)),
                    lineWidth: isBar ? 1 : 0.5
                )
            }
            
            // Bottom border
            let bottomPath = Path { p in
                p.move(to: CGPoint(x: 0, y: size.height))
                p.addLine(to: CGPoint(x: size.width, y: size.height))
            }
            context.stroke(bottomPath, with: .color(Color.gray.opacity(0.3)), lineWidth: 1)
        }
        .frame(height: height)
    }
}

// MARK: - Timeline Ruler Content (no scroll, used inside shared ScrollView)

struct TimelineRulerContent: View {
    @ObservedObject var viewModel: ProjectViewModel
    @State private var isDragging: Bool = false
    @State private var wasPlayingBeforeDrag: Bool = false
    
    var body: some View {
        Canvas { context, size in
            let pixelsPerBeat = viewModel.pixelsPerBeat
            let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
            let totalBeats = Int(size.width / pixelsPerBeat) + 1
            
            for beat in 0..<totalBeats {
                let x = CGFloat(beat) * pixelsPerBeat
                let isBar = beat % beatsPerBar == 0
                
                let tickHeight: CGFloat = isBar ? 15 : 8
                let path = Path { p in
                    p.move(to: CGPoint(x: x, y: size.height - tickHeight))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(path, with: .color(isBar ? .primary : .secondary.opacity(0.5)), lineWidth: isBar ? 1 : 0.5)
                
                if isBar {
                    let barNum = beat / beatsPerBar + 1
                    let text = Text("\(barNum)").font(.system(size: 10, weight: .medium))
                    context.draw(text, at: CGPoint(x: x + 4, y: 8))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let beat = max(0, value.location.x / viewModel.pixelsPerBeat)
                    
                    if !isDragging {
                        // First event - capture state and stop playback temporarily
                        isDragging = true
                        wasPlayingBeforeDrag = viewModel.transportState.isPlaying
                        if wasPlayingBeforeDrag {
                            // Pause both engine and transport state
                            viewModel.playbackEngine.stopPlayback()
                            viewModel.transportState.pause()
                        }
                    }
                    
                    // Update playhead position visually
                    viewModel.transportState.setPlayheadBeats(beat)
                }
                .onEnded { value in
                    let beat = max(0, value.location.x / viewModel.pixelsPerBeat)
                    viewModel.transportState.setPlayheadBeats(beat)
                    
                    // Resume playback from new position if we were playing
                    if wasPlayingBeforeDrag {
                        // Use transportState.play() which triggers prepareForPlayback + startPlayback
                        viewModel.transportState.play()
                    }
                    
                    isDragging = false
                    wasPlayingBeforeDrag = false
                }
        )
    }
}

// MARK: - Track Lane View (just the timeline content, no header)

struct TrackLaneView: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    let height: CGFloat
    
    private var isMIDITrack: Bool {
        track.type == .midi || track.type == .instrument
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            // Grid
            TrackGridView(viewModel: viewModel, height: height)
            
            // Clips
            ForEach(track.clips) { clip in
                let width = clipWidth(for: clip)
                ClipView(
                    clip: clip,
                    track: track,
                    viewModel: viewModel,
                    height: height - 6,
                    clipWidth: width
                )
                .offset(x: clipX(for: clip), y: 3)
                .frame(width: width)
                // For MIDI tracks, let clicks pass through to the track lane
                .allowsHitTesting(!isMIDITrack)
            }
            
            // Live recording waveform overlay (for audio tracks)
            if track.type == .audio {
                RecordingWaveformOverlay(
                    viewModel: viewModel,
                    track: track,
                    pixelsPerBeat: viewModel.pixelsPerBeat,
                    height: height
                )
            }
            
            // Live MIDI recording overlay (for MIDI/instrument tracks)
            if isMIDITrack && viewModel.isRecording && viewModel.recordingTrackID == track.id {
                // Get current track color from project for dynamic updates
                let currentTrack = viewModel.project.track(withID: track.id) ?? track
                LiveMIDIRecordingOverlay(
                    viewModel: viewModel,
                    height: height - 6,
                    trackColor: Color(hex: currentTrack.color.hex) ?? .green
                )
            }
        }
        .frame(height: height)
        .background(viewModel.selectedTrackID == track.id ? Color.accentColor.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        // Single click: select track instantly (no double-click delay)
        .onTapGesture {
            withAnimation(.none) {
                viewModel.selectAndArmTrack(track.id)
            }
        }
        // Drag and drop audio files (only for audio tracks)
        .dropDestination(for: URL.self) { urls, location in
            // Only accept drops on audio tracks
            guard track.type == .audio else { return false }
            
            // Filter to audio files only
            let supportedExtensions = ["wav", "aif", "aiff", "mp3", "m4a", "caf", "flac"]
            let audioURLs = urls.filter { url in
                supportedExtensions.contains(url.pathExtension.lowercased())
            }
            
            guard let firstURL = audioURLs.first else { return false }
            
            // Calculate beat position from drop location
            let beatPosition = max(0, location.x / viewModel.pixelsPerBeat)
            
            print("[Drop] Importing audio file at beat \(beatPosition): \(firstURL.lastPathComponent)")
            
            // Import the audio file
            viewModel.importAudioFile(from: firstURL, atBeat: beatPosition, onTrack: track.id)
            
            return true
        } isTargeted: { isTargeted in
            // Could add visual feedback here when dragging over
        }
    }
    
    private func clipX(for clip: Clip) -> CGFloat {
        clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm) * viewModel.pixelsPerBeat
    }

    private func clipWidth(for clip: Clip) -> CGFloat {
        let durationBeats = clip.timeRange.duration.beats(atTempo: viewModel.transportState.tempo.bpm)
        return max(10, durationBeats * viewModel.pixelsPerBeat)
    }
}

// MARK: - Inspector View

struct InspectorView: View {
    @ObservedObject var viewModel: ProjectViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector").font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let track = viewModel.selectedTrack {
                        TrackInspectorSection(track: track, viewModel: viewModel, audioRecorder: viewModel.audioRecorder)
                    } else {
                        Text("Select a track")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
                .padding()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Track Inspector Section

struct TrackInspectorSection: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    @ObservedObject var audioRecorder: AudioRecorder
    @State private var trackName: String = ""
    @State private var availableInputs: [AudioInputDevice] = []
    @State private var selectedInputID: AudioDeviceID = 0
    @State private var selectedChannelID: String = "default-stereo"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundColor(.secondary)
                TextField("Track Name", text: $trackName, onCommit: updateTrackName)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Type").font(.caption).foregroundColor(.secondary)
                Text(track.type.rawValue.capitalized)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Volume").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text(volumeText).font(.caption.monospaced())
                }
                Slider(value: Binding(
                    get: { Double(track.volume) },
                    set: { viewModel.setTrackVolume(id: track.id, volume: Float($0)) }
                ), in: 0...1.4)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pan").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text(panText).font(.caption.monospaced())
                }
                Slider(value: Binding(
                    get: { Double(track.pan) },
                    set: { viewModel.setTrackPan(id: track.id, pan: Float($0)) }
                ), in: -1...1)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Color").font(.caption).foregroundColor(.secondary)
                HStack(spacing: 4) {
                    ForEach(TrackColor.allCases, id: \.self) { color in
                        Circle()
                            .fill(Color(hex: color.hex) ?? .gray)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.white, lineWidth: track.color == color ? 2 : 0))
                            .onTapGesture { setTrackColor(color) }
                    }
                }
            }
            
            // MIDI Output section (only for MIDI/instrument tracks)
            if track.type == .midi || track.type == .instrument {
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("MIDI Output").font(.caption.bold()).foregroundColor(.secondary)
                    
                    // Destination picker
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Destination").font(.caption2).foregroundColor(.secondary)
                        Picker("Destination", selection: Binding(
                            get: { midiOutputBinding },
                            set: { setMIDIOutput($0) }
                        )) {
                            Text("Track Instrument").tag(MIDIOutputBinding.trackInstrument)
                            
                            if !viewModel.project.vRack.instruments.isEmpty {
                                Divider()
                                ForEach(viewModel.project.vRack.instruments) { instrument in
                                    Text(instrument.name).tag(MIDIOutputBinding.rackInstrument(id: instrument.id))
                                }
                            }
                        }
                        .labelsHidden()
                    }
                    
                    // Channel picker (only for rack instruments)
                    if case .rackInstrument(_, let channel) = track.midiOutput {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MIDI Channel").font(.caption2).foregroundColor(.secondary)
                            Picker("Channel", selection: Binding(
                                get: { Int(channel) },
                                set: { updateMIDIChannel(UInt8($0)) }
                            )) {
                                ForEach(1...16, id: \.self) { ch in
                                    Text("Channel \(ch)").tag(ch)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
            }
            
            // Audio Input section (only for audio tracks)
            if track.type == .audio {
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Audio Input").font(.caption.bold()).foregroundColor(.secondary)
                        Spacer()
                        Button(action: refreshInputs) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh audio devices")
                    }
                    
                    // Device selection
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device").font(.caption2).foregroundColor(.secondary)
                        Picker("Device", selection: $selectedInputID) {
                            Text("System Default").tag(AudioDeviceID(0))
                            ForEach(availableInputs) { input in
                                Text(input.name).tag(input.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedInputID) { _, _ in
                            selectedChannelID = ""  // Reset channel when device changes
                        }
                    }
                    
                    // Channel selection (only if a device is selected)
                    if let selectedDevice = availableInputs.first(where: { $0.id == selectedInputID }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input Channel").font(.caption2).foregroundColor(.secondary)
                            Picker("Channel", selection: $selectedChannelID) {
                                Text("Select Input...").tag("")
                                ForEach(selectedDevice.channels) { channel in
                                    Text(channel.name).tag(channel.id)
                                }
                            }
                            .labelsHidden()
                        }
                    } else if selectedInputID == 0 {
                        // System default - show simple mono/stereo choice
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input Channel").font(.caption2).foregroundColor(.secondary)
                            Picker("Channel", selection: $selectedChannelID) {
                                Text("Input 1-2 (Stereo)").tag("default-stereo")
                                Text("Input 1 (Mono)").tag("default-mono-1")
                                Text("Input 2 (Mono)").tag("default-mono-2")
                            }
                            .labelsHidden()
                        }
                    }
                    
                    // Input level meter
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Input Level").font(.caption2).foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.gray.opacity(0.3))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(inputLevelColor)
                                        .frame(width: geo.size.width * CGFloat(audioRecorder.inputLevel))
                                }
                            }
                            .frame(height: 10)
                            
                            Text(levelText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 35, alignment: .trailing)
                        }
                    }
                    
                    // Arm button
                    Button(action: { toggleArm() }) {
                        HStack {
                            Circle()
                                .fill(track.isArmed ? Color.red : Color.gray)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle()
                                        .stroke(Color.red, lineWidth: track.isArmed ? 2 : 0)
                                        .scaleEffect(1.5)
                                        .opacity(track.isArmed ? 0.5 : 0)
                                )
                            Text(track.isArmed ? "Armed for Recording" : "Arm Track for Recording")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(track.isArmed ? Color.red.opacity(0.2) : Color.gray.opacity(0.15))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Output").font(.caption).foregroundColor(.secondary)
                Picker("Output", selection: .constant(0)) {
                    Text("Master").tag(0)
                }.labelsHidden()
            }
            
            Spacer()
        }
        .onAppear {
            trackName = track.name
            refreshInputs()
        }
        .onChange(of: track.id) { _, _ in
            trackName = track.name
            refreshInputs()
        }
    }
    
    private var inputLevelColor: Color {
        let level = audioRecorder.inputLevel
        if level > 0.9 { return .red }
        if level > 0.7 { return .yellow }
        return .green
    }
    
    private var levelText: String {
        let level = audioRecorder.inputLevel
        if level < 0.001 { return "-∞ dB" }
        let db = 20 * log10(level)
        return String(format: "%.0f dB", db)
    }
    
    private func refreshInputs() {
        availableInputs = viewModel.audioRecorder.availableInputDevices()
    }
    
    private func toggleArm() {
        viewModel.toggleTrackArm(id: track.id)
    }
    
    private var volumeText: String {
        let db = 20 * log10(track.volume)
        return db == -.infinity ? "-∞ dB" : String(format: "%.1f dB", db)
    }
    
    private var panText: String {
        if abs(track.pan) < 0.01 { return "C" }
        return track.pan < 0 ? String(format: "%.0fL", -track.pan * 100) : String(format: "%.0fR", track.pan * 100)
    }
    
    private func updateTrackName() {
        guard !trackName.isEmpty, trackName != track.name else { return }
        var t = track; t.name = trackName
        viewModel.updateTrack(t, description: "Rename Track")
    }
    
    private func setTrackColor(_ color: TrackColor) {
        var t = track; t.color = color
        viewModel.updateTrack(t, description: "Change Track Color")
    }
    
    // MARK: - MIDI Output Helpers
    
    /// Binding type for the MIDI output picker
    private enum MIDIOutputBinding: Hashable {
        case trackInstrument
        case rackInstrument(id: UUID)
    }
    
    private var midiOutputBinding: MIDIOutputBinding {
        switch track.midiOutput {
        case .rackInstrument(let id, _):
            return .rackInstrument(id: id)
        case .trackInstrument, .none:
            return .trackInstrument
        }
    }
    
    private func setMIDIOutput(_ binding: MIDIOutputBinding) {
        var t = track
        switch binding {
        case .trackInstrument:
            t.midiOutput = .trackInstrument
        case .rackInstrument(let id):
            // Default to channel 1 when first selecting a rack instrument
            t.midiOutput = .rackInstrument(id: id, channel: 1)
        }
        viewModel.updateTrack(t, description: "Set MIDI Output")
    }
    
    private func updateMIDIChannel(_ channel: UInt8) {
        guard case .rackInstrument(let id, _) = track.midiOutput else { return }
        var t = track
        t.midiOutput = .rackInstrument(id: id, channel: channel)
        viewModel.updateTrack(t, description: "Set MIDI Channel")
    }
}

// MARK: - Resize Handle

struct ResizeHandle: View {
    @Binding var height: CGFloat
    @State private var isDragging = false
    @State private var isHovering = false
    
    private let minHeight: CGFloat = 150
    private let maxHeight: CGFloat = 600
    
    var body: some View {
        VStack(spacing: 0) {
            // Top border line
            Rectangle()
                .fill(Color.gray.opacity(0.5))
                .frame(height: 1)
            
            // Main handle area
            ZStack {
                // Background
                Rectangle()
                    .fill(isDragging ? Color.accentColor.opacity(0.3) : (isHovering ? Color.gray.opacity(0.2) : Color(nsColor: .separatorColor).opacity(0.5)))
                
                // Grip indicator - always visible
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { _ in
                        Circle()
                            .fill(isDragging ? Color.accentColor : Color.gray)
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .frame(height: 8)
            
            // Bottom border line
            Rectangle()
                .fill(Color.gray.opacity(0.5))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    isDragging = true
                    // Dragging up (negative y) increases height
                    let newHeight = height - value.translation.height
                    height = min(maxHeight, max(minHeight, newHeight))
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}

// MARK: - Optimized Playhead View

/// A dedicated view for the playhead that uses efficient rendering
private struct PlayheadView: View {
    let position: Double
    let pixelsPerBeat: CGFloat
    
    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: geometry.size.height)
                .position(x: position * pixelsPerBeat + 1, y: geometry.size.height / 2)
        }
        .drawingGroup() // Use Metal for rendering - much smoother
    }
}

// MARK: - Track Drop Delegate

struct TrackDropDelegate: DropDelegate {
    let trackIndex: Int
    @Binding var draggedTrackID: TrackID?
    @Binding var dropTargetIndex: Int?
    let viewModel: ProjectViewModel
    
    func dropEntered(info: DropInfo) {
        dropTargetIndex = trackIndex
    }
    
    func dropExited(info: DropInfo) {
        // Only clear if we're still the target
        if dropTargetIndex == trackIndex {
            dropTargetIndex = nil
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropTargetIndex = trackIndex
        return DropProposal(operation: .move)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = draggedTrackID else { return false }
        
        viewModel.reorderTrack(trackID: draggedID, toIndex: trackIndex)
        
        // Reset state
        draggedTrackID = nil
        dropTargetIndex = nil
        
        return true
    }
    
    func validateDrop(info: DropInfo) -> Bool {
        return draggedTrackID != nil
    }
}
