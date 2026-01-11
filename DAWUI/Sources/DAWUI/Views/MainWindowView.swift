import SwiftUI
import CoreAudio
import DAWCore

// MARK: - Main Window View

public struct MainWindowView: View {
    @StateObject private var viewModel: ProjectViewModel
    
    // Observe transportState directly to get playhead updates
    @State private var playheadPosition: Double = 0
    
    @State private var mixerHeight: CGFloat = 280
    @State private var pianoRollHeight: CGFloat = 350
    @State private var showCreateClipDialog: Bool = false
    @State private var createClipTrackID: TrackID?
    @State private var horizontalScrollOffset: CGFloat = 0
    
    private let trackHeight: CGFloat = 80
    private let rulerHeight: CGFloat = 30
    private let trackHeaderWidth: CGFloat = 200
    
    public init(project: Project = ProjectFactory.createNewProject()) {
        _viewModel = StateObject(wrappedValue: ProjectViewModel(project: project))
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            TransportView(viewModel: viewModel)
            Divider()
            
            HStack(spacing: 0) {
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
        .handleKeyboardShortcuts(viewModel: viewModel)
        .overlay(alignment: .center) {
            if !viewModel.isEngineReady {
                loadingOverlay
            }
        }
        .onAppear { setupInitialState() }
        .onReceive(viewModel.transportState.$playheadBeats) { beats in
            playheadPosition = beats
        }
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
                    
                    // SINGLE playhead line spanning entire height
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                        .offset(x: playheadPosition * viewModel.pixelsPerBeat)
                }
                .frame(width: max(1200, viewModel.pixelsPerBeat * 64))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let beat = max(0, value.location.x / viewModel.pixelsPerBeat)
                            viewModel.transportState.setPlayheadBeats(beat)
                        }
                )
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
            Toggle(isOn: $viewModel.showMixer) {
                Image(systemName: "slider.horizontal.3")
            }
            Toggle(isOn: $viewModel.showInspector) {
                Image(systemName: "sidebar.right")
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
    }
}

// MARK: - Track Lane View (just the timeline content, no header)

struct TrackLaneView: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    let height: CGFloat
    
    var body: some View {
        ZStack(alignment: .leading) {
            // Grid
            TrackGridView(viewModel: viewModel, height: height)
            
            // Clips
            ForEach(track.clips) { clip in
                ClipView(
                    clip: clip,
                    track: track,
                    viewModel: viewModel,
                    height: height - 6
                )
                .offset(x: clipX(for: clip), y: 3)
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
        }
        .frame(height: height)
        .background(viewModel.selectedTrackID == track.id ? Color.accentColor.opacity(0.05) : Color.clear)
    }
    
    private func clipX(for clip: Clip) -> CGFloat {
        clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm) * viewModel.pixelsPerBeat
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
