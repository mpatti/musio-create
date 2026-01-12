import SwiftUI
import CoreAudio
import DAWCore

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
    @State private var showAIPromptDialog: Bool = false
    @State private var aiPromptText: String = ""
    @State private var isAIGenerating: Bool = false
    @State private var aiGenerationMode: ElevenLabsGenerationMode = .soundEffects
    @State private var aiErrorMessage: String? = nil
    @State private var showAIError: Bool = false
    
    // ElevenLabs credits
    @State private var elevenLabsCredits: ElevenLabsSubscriptionInfo? = nil
    private let elevenLabsService = ElevenLabsService()
    
    // Bar jump mode state
    @State private var isBarJumpMode: Bool = false
    @State private var barJumpInput: String = ""

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

                if viewModel.showInspector {
                    Divider()
                    InspectorView(viewModel: viewModel)
                        .frame(width: 250)  // Fixed width
                }
            }
            
            if viewModel.showMixer || viewModel.showPianoRoll {
                // Draggable resize handle
                ResizeHandle(height: viewModel.showPianoRoll ? $pianoRollHeight : $mixerHeight)
                
                bottomPanel
                    .frame(height: viewModel.showPianoRoll ? pianoRollHeight : mixerHeight)
            }
        }
        .frame(minWidth: 1200, minHeight: 700)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAIPromptDialog) {
            AIPromptDialogView(
                prompt: $aiPromptText,
                selectedMode: $aiGenerationMode,
                isPresented: $showAIPromptDialog,
                beatCount: aiSelectedBeatCount,
                onGenerate: { prompt, mode in
                    generateAIAudioForSelection(prompt: prompt, mode: mode)
                }
            )
        }
        .onChange(of: showAIPromptDialog) { _, isOpen in
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
                
                // Track headers (scrollable vertically)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(viewModel.project.tracks) { track in
                            TrackHeaderView(track: track, viewModel: viewModel)
                                .frame(width: trackHeaderWidth, height: trackHeight)
                                .background(viewModel.selectedTrackID == track.id ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                        }
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
        if viewModel.showPianoRoll, let clipID = viewModel.editingClipID {
            AdvancedPianoRollView(viewModel: viewModel, clipID: clipID)
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
            
            Toggle(isOn: $isAIGenerationMode) {
                Image(systemName: "wand.and.stars")
            }
            .toggleStyle(.button)
            .tint(isAIGenerationMode ? .purple : nil)
            .help(isAIGenerationMode ? "Exit Generative Fill mode" : "Generative Fill - click and drag on audio track to select range")
            
            Toggle(isOn: $showVRack) {
                Image(systemName: "pianokeys")
            }
            .help("Toggle Instruments Panel")
            
            Toggle(isOn: $viewModel.showMixer) {
                Image(systemName: "slider.horizontal.3")
            }
            Toggle(isOn: $viewModel.showInspector) {
                Image(systemName: "sidebar.right")
            }
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
                            
                            // Only allow selection on audio tracks
                            guard trackIndex >= 0 && trackIndex < tracks.count,
                                  tracks[trackIndex].type == .audio else {
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
                            // Ensure we have at least 1 beat selected and we're on an audio track
                            if aiSelectedBeatCount >= 1 && aiSelectionTrackID != nil {
                                // Show the prompt dialog
                                aiPromptText = ""
                                showAIPromptDialog = true
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
    }
    
    /// Generate AI audio for the selected range
    private func generateAIAudioForSelection(prompt: String, mode: ElevenLabsGenerationMode) {
        let startBeat = aiSelectionStartBeat
        let beatCount = aiSelectedBeatCount
        
        // Capture selection values before any state changes
        let selStart = aiSelectionStart
        let selEnd = aiSelectionEnd
        let selTrackY = aiSelectionTrackY
        let selTrackID = aiSelectionTrackID
        
        print("[Generative Fill] Starting generation - mode: \(mode.rawValue), track: \(selTrackID?.rawValue.uuidString ?? "nil")")
        
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
                // Generate the audio with selected mode
                print("[AI Generate] Calling \(mode.rawValue) API...")
                let audioURL = try await viewModel.generateAIAudio(prompt: prompt, beats: beatCount, mode: mode)
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
    @Binding var selectedMode: ElevenLabsGenerationMode
    @Binding var isPresented: Bool
    let beatCount: Int
    let onGenerate: (String, ElevenLabsGenerationMode) -> Void
    
    @FocusState private var isPromptFocused: Bool
    @State private var subscriptionInfo: ElevenLabsSubscriptionInfo?
    @State private var isLoadingCredits: Bool = false
    
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
            
            // Mode selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Generation Mode")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 10) {
                    ForEach(ElevenLabsGenerationMode.allCases) { mode in
                        Button {
                            selectedMode = mode
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: mode.icon)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text(mode.description)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedMode == mode ? Color.purple.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        selectedMode == mode ? Color.purple : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(selectedMode == mode ? .purple : .primary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            
            // Prompt input area
            VStack(alignment: .leading, spacing: 12) {
                Text("Describe the sound")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextField(selectedMode == .music 
                    ? "e.g., upbeat electronic dance loop, chill lo-fi beat..." 
                    : "e.g., punchy drums, vinyl crackle, whoosh...", 
                    text: $prompt
                )
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
                    onGenerate(prompt, selectedMode)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selectedMode == .music ? "music.note" : "sparkles")
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
                                    colors: selectedMode == .music ? [.pink, .orange] : [.purple, .blue],
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
        .onTapGesture(count: 2) {
            // Double-click: select, arm, and open piano roll for MIDI tracks
            withAnimation(.none) {
                viewModel.selectAndArmTrack(track.id)
                if isMIDITrack {
                    viewModel.openPianoRollForTrack(track.id)
                }
            }
        }
        .onTapGesture(count: 1) {
            // Single click: select and arm the track (instant, no animation)
            withAnimation(.none) {
                viewModel.selectAndArmTrack(track.id)
            }
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
