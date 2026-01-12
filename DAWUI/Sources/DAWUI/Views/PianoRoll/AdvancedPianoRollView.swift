import SwiftUI
import DAWCore

// MARK: - MIDI Editor Tool

public enum MIDIEditorTool: String, CaseIterable {
    case select = "Select"
    case pencil = "Pencil"
    case eraser = "Eraser"
    case velocity = "Velocity"
    case split = "Split"
    case glue = "Glue"
    case mute = "Mute"
    
    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        case .velocity: return "chart.bar"
        case .split: return "scissors"
        case .glue: return "link"
        case .mute: return "speaker.slash"
        }
    }
    
    var cursor: NSCursor {
        switch self {
        case .select: return .arrow
        case .pencil: return .crosshair
        case .eraser: return .disappearingItem
        case .velocity: return .resizeUpDown
        case .split: return .crosshair
        case .glue: return .pointingHand
        case .mute: return .pointingHand
        }
    }
}

// MARK: - Snap Mode

public enum SnapMode: String, CaseIterable {
    case off = "Off"
    case bar = "Bar"
    case beat = "Beat"
    case eighth = "1/8"
    case sixteenth = "1/16"
    case thirtysecond = "1/32"
    case triplet = "Triplet"
    
    var division: Double {
        switch self {
        case .off: return 0
        case .bar: return 4.0
        case .beat: return 1.0
        case .eighth: return 0.5
        case .sixteenth: return 0.25
        case .thirtysecond: return 0.125
        case .triplet: return 1.0/3.0
        }
    }
}

// MARK: - CC Type

public enum CCType: Int, CaseIterable, Identifiable {
    case modulation = 1
    case breath = 2
    case volume = 7
    case pan = 10
    case expression = 11
    case sustain = 64
    case portamento = 65
    case sostenuto = 66
    case soft = 67
    case resonance = 71
    case release = 72
    case attack = 73
    case cutoff = 74
    case decay = 75
    case pitchBend = 128 // Special case
    
    public var id: Int { rawValue }
    
    var name: String {
        switch self {
        case .modulation: return "Modulation"
        case .breath: return "Breath"
        case .volume: return "Volume"
        case .pan: return "Pan"
        case .expression: return "Expression"
        case .sustain: return "Sustain"
        case .portamento: return "Portamento"
        case .sostenuto: return "Sostenuto"
        case .soft: return "Soft Pedal"
        case .resonance: return "Resonance"
        case .release: return "Release"
        case .attack: return "Attack"
        case .cutoff: return "Cutoff"
        case .decay: return "Decay"
        case .pitchBend: return "Pitch Bend"
        }
    }
}

// MARK: - Advanced Piano Roll View

public struct AdvancedPianoRollView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let clipID: ClipID
    
    // Editor state
    @State private var currentTool: MIDIEditorTool = .select
    @State private var snapMode: SnapMode = .sixteenth
    @State private var showVelocityLane: Bool = true
    @State private var showCCLane: Bool = false
    @State private var selectedCCType: CCType = .modulation
    
    // Selection state
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var selectionRect: CGRect? = nil
    @State private var isMarqueeSelecting: Bool = false
    
    // Pencil tool preview state
    @State private var pencilPreviewStart: Double? = nil  // Start beat (absolute)
    @State private var pencilPreviewPitch: Int? = nil
    @State private var pencilPreviewDuration: Double = 0

    // Editing state
    @State private var draggedNoteID: UUID? = nil
    @State private var dragMode: NoteDragMode = .none
    @State private var dragStartBeat: Double = 0
    @State private var dragStartPitch: Int = 0
    @State private var dragStartDuration: Double = 0
    
    // Multi-select drag state - stores initial positions of all selected notes
    @State private var dragStartPositions: [UUID: (beat: Double, pitch: Int, duration: Double)] = [:]
    
    // Quantize dialog
    @State private var showQuantizeDialog: Bool = false
    
    // View state
    @State private var pixelsPerBeat: Double = 60
    @State private var noteHeight: CGFloat = 14
    @State private var scrollOffset: CGPoint = .zero
    @State private var visibleOctaveRange: ClosedRange<Int> = 2...7
    
    // Copied notes for paste
    @State private var copiedNotes: [MIDIEvent] = []
    
    // Playhead position (updated in real-time)
    @State private var currentPlayheadBeat: Double = 0
    
    // Track color for notes
    private var trackColor: Color {
        // Find the track that contains this clip
        if let track = viewModel.project.tracks.first(where: { $0.clips.contains(where: { $0.id == clipID }) }) {
            return Color(hex: track.color.hex) ?? .accentColor
        }
        return .accentColor
    }
    
    private let pianoKeyWidth: CGFloat = 60
    private let velocityLaneHeight: CGFloat = 80
    private let ccLaneHeight: CGFloat = 80
    
    public init(viewModel: ProjectViewModel, clipID: ClipID) {
        self.viewModel = viewModel
        self.clipID = clipID
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            editorToolbar
            
            Divider()
            
            // Main content
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Bar ruler at top
                    HStack(spacing: 0) {
                        // Empty space for piano keyboard alignment
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: pianoKeyWidth)
                        
                        Divider()
                        
                        // Bar numbers ruler
                        barRuler
                            .frame(height: 24)
                    }
                    .frame(height: 24)
                    .background(Color(nsColor: .windowBackgroundColor))
                    
                    Divider()
                    
                    HStack(spacing: 0) {
                        // Piano keyboard
                        pianoKeyboard
                            .frame(width: pianoKeyWidth)
                        
                        Divider()
                        
                        // Note grid and lanes
                        VStack(spacing: 0) {
                            // Note editing area
                            noteEditingArea(geometry: geometry)
                            
                            // Velocity lane
                            if showVelocityLane {
                                Divider()
                                velocityLane
                                    .frame(height: velocityLaneHeight)
                            }
                            
                            // CC lane
                            if showCCLane {
                                Divider()
                                ccLane
                                    .frame(height: ccLaneHeight)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            setupInitialView()
            currentPlayheadBeat = viewModel.transportState.playheadBeats
        }
        .onReceive(viewModel.transportState.$playheadBeats) { beats in
            currentPlayheadBeat = beats
        }
        .sheet(isPresented: $showQuantizeDialog) {
            QuantizeDialogView(
                noteCount: selectedNoteIDs.count,
                onQuantize: { grid in
                    quantizeSelectedNotes(to: grid)
                },
                onCancel: {
                    showQuantizeDialog = false
                }
            )
        }
    }
    
    // MARK: - Toolbar
    
    private var editorToolbar: some View {
        HStack(spacing: 12) {
            // Close button
            Button(action: { viewModel.closePianoRoll() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            
            Divider().frame(height: 20)
            
            // Tool selection
            ForEach(MIDIEditorTool.allCases, id: \.self) { tool in
                Button(action: { currentTool = tool }) {
                    Image(systemName: tool.icon)
                        .foregroundColor(currentTool == tool ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
                .help(tool.rawValue)
            }
            
            Divider().frame(height: 20)
            
            // Snap mode
            HStack(spacing: 4) {
                Text("Snap:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("", selection: $snapMode) {
                    ForEach(SnapMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
            }
            
            Divider().frame(height: 20)
            
            // Quantize button
            Button(action: { showQuantizeDialog = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.path.ecg")
                    Text("Quantize")
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .disabled(selectedNoteIDs.isEmpty)
            .help("Quantize Selected Notes")
            
            // Edit actions
            HStack(spacing: 4) {
                Button(action: selectAll) {
                    Image(systemName: "checkmark.square")
                }
                .buttonStyle(.plain)
                .help("Select All (⌘A)")
                
                Button(action: deleteSelected) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(selectedNoteIDs.isEmpty)
                .help("Delete (⌫)")
                
                Button(action: copySelected) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(selectedNoteIDs.isEmpty)
                .help("Copy (⌘C)")
                
                Button(action: paste) {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .disabled(copiedNotes.isEmpty)
                .help("Paste (⌘V)")
                
                Button(action: duplicateSelected) {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.plain)
                .disabled(selectedNoteIDs.isEmpty)
                .help("Duplicate (⌘D)")
            }
            
            Divider().frame(height: 20)
            
            // Lane toggles
            Toggle(isOn: $showVelocityLane) {
                Text("Velocity")
                    .font(.caption)
            }
            .toggleStyle(.button)
            
            Toggle(isOn: $showCCLane) {
                Text("CC")
                    .font(.caption)
            }
            .toggleStyle(.button)
            
            if showCCLane {
                Picker("", selection: $selectedCCType) {
                    ForEach(CCType.allCases) { cc in
                        Text(cc.name).tag(cc)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }
            
            Spacer()
            
            // Zoom controls
            HStack(spacing: 4) {
                Button(action: { pixelsPerBeat = max(20, pixelsPerBeat - 10) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                
                Text("\(Int(pixelsPerBeat))px")
                    .font(.caption)
                    .frame(width: 40)
                
                Button(action: { pixelsPerBeat = min(200, pixelsPerBeat + 10) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
            }
            
            // Clip info
            if let clip = currentClip {
                Text(clip.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Piano Keyboard
    
    private var pianoKeyboard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(pitchRange.reversed(), id: \.self) { pitch in
                    AdvancedPianoKeyView(
                        pitch: UInt8(pitch),
                        noteHeight: noteHeight,
                        onPress: { viewModel.playNotePreview(pitch: UInt8(pitch)) },
                        onRelease: { viewModel.stopNotePreview(pitch: UInt8(pitch)) }
                    )
                }
            }
        }
    }
    
    private var pitchRange: [Int] {
        Array(visibleOctaveRange.lowerBound * 12...visibleOctaveRange.upperBound * 12 + 11)
    }
    
    // MARK: - Bar Ruler
    
    private var barRuler: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let timeSignature = viewModel.transportState.timeSignature
                    let beatsPerBar = Double(timeSignature.beatsPerBar)
                    let totalBars = Int(ceil(totalWidth / (pixelsPerBeat * beatsPerBar))) + 1
                    
                    for bar in 0..<totalBars {
                        let barBeat = Double(bar) * beatsPerBar
                        let x = barBeat * pixelsPerBeat
                        
                        // Bar number (1-indexed for display)
                        let barText = Text("\(bar + 1)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                        context.draw(barText, at: CGPoint(x: x + 8, y: size.height / 2))
                        
                        // Bar line
                        let linePath = Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        context.stroke(linePath, with: .color(Color.gray.opacity(0.5)), lineWidth: 1)
                        
                        // Beat subdivisions
                        for beat in 1..<Int(beatsPerBar) {
                            let beatX = x + Double(beat) * pixelsPerBeat
                            let beatPath = Path { path in
                                path.move(to: CGPoint(x: beatX, y: size.height * 0.6))
                                path.addLine(to: CGPoint(x: beatX, y: size.height))
                            }
                            context.stroke(beatPath, with: .color(Color.gray.opacity(0.3)), lineWidth: 0.5)
                        }
                    }
                }
                .frame(width: totalWidth, height: 24)
                
                // Click area for setting playhead
                Color.clear
                    .frame(width: totalWidth, height: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                setPlayheadFromClick(at: value.location.x)
                            }
                    )
            }
        }
    }
    
    /// Set playhead position from click location in bar ruler
    private func setPlayheadFromClick(at x: CGFloat) {
        let beat = max(0, Double(x) / pixelsPerBeat)
        viewModel.transportState.setPlayheadBeats(beat)
        currentPlayheadBeat = beat
    }

    // MARK: - Note Editing Area
    
    private func noteEditingArea(geometry: GeometryProxy) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                // Background grid
                noteGrid(geometry: geometry)

                // Notes (saved in clip)
                notesLayer
                
                // Live recording notes (real-time display during recording)
                liveRecordingNotesLayer
                
                // Pencil tool preview
                pencilPreviewLayer

                // Selection marquee
                if let rect = selectionRect, isMarqueeSelecting {
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 1)
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.origin.x, y: rect.origin.y)
                }

                // Playhead
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1)
                    .frame(height: totalHeight)
                    .offset(x: playheadX)
            }
            .frame(
                width: max(geometry.size.width - pianoKeyWidth, totalWidth),
                height: totalHeight
            )
            .contentShape(Rectangle())
            .gesture(editingGesture)
        }
    }
    
    private func noteGrid(geometry: GeometryProxy) -> some View {
        Canvas { context, size in
            let pitchRange = visibleOctaveRange.lowerBound * 12...visibleOctaveRange.upperBound * 12 + 11
            
            // Draw horizontal pitch lines
            for (index, pitch) in pitchRange.reversed().enumerated() {
                let y = CGFloat(index) * noteHeight
                let isBlackKey = [1, 3, 6, 8, 10].contains(pitch % 12)
                
                // Background color for black keys
                if isBlackKey {
                    let rect = CGRect(x: 0, y: y, width: size.width, height: noteHeight)
                    context.fill(Path(rect), with: .color(Color.black.opacity(0.15)))
                }
                
                // C note highlight
                if pitch % 12 == 0 {
                    let linePath = Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(linePath, with: .color(Color.gray.opacity(0.4)), lineWidth: 1)
                } else {
                    let linePath = Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(linePath, with: .color(Color.gray.opacity(0.15)), lineWidth: 0.5)
                }
            }
            
            // Draw vertical beat lines
            let totalBeats = Int(size.width / pixelsPerBeat) + 1
            let timeSignature = viewModel.transportState.timeSignature
            
            for beat in 0..<totalBeats {
                let x = CGFloat(beat) * pixelsPerBeat
                let isBar = beat % timeSignature.beatsPerBar == 0
                
                let linePath = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                
                context.stroke(
                    linePath,
                    with: .color(isBar ? Color.gray.opacity(0.5) : Color.gray.opacity(0.2)),
                    lineWidth: isBar ? 1 : 0.5
                )
                
                // Subdivision lines
                if snapMode == .sixteenth || snapMode == .thirtysecond {
                    for sub in 1..<4 {
                        let subX = x + (CGFloat(sub) * pixelsPerBeat / 4)
                        let subPath = Path { path in
                            path.move(to: CGPoint(x: subX, y: 0))
                            path.addLine(to: CGPoint(x: subX, y: size.height))
                        }
                        context.stroke(subPath, with: .color(Color.gray.opacity(0.1)), lineWidth: 0.5)
                    }
                }
            }
        }
    }
    
    private var notesLayer: some View {
        ForEach(noteEvents, id: \.id) { event in
            if case .note(let noteData) = event.type {
                AdvancedNoteView(
                    event: event,
                    noteData: noteData,
                    isSelected: selectedNoteIDs.contains(event.id),
                    pixelsPerBeat: pixelsPerBeat,
                    noteHeight: noteHeight,
                    pitchOffset: pitchOffset,
                    noteColor: trackColor,
                    clipStartBeat: clipStartBeat,  // Add absolute position offset
                    onSelect: { selectNote(event.id) },
                    onDragStart: { mode in startNoteDrag(event, mode: mode) },
                    onDrag: { delta in handleNoteDrag(delta) },
                    onDragEnd: { endNoteDrag() }
                )
            }
        }
    }
    
    /// Live recording notes - displayed in real-time during MIDI recording
    @ViewBuilder
    private var liveRecordingNotesLayer: some View {
        if viewModel.isRecording {
            let liveEvents = viewModel.midiRecorder.liveRecordedEvents
            let recordingStartBeat = viewModel.midiRecorder.liveRecordingStartBeat
            
            ForEach(liveEvents, id: \.id) { event in
                if case .note(let noteData) = event.type {
                    // Calculate absolute beat position for the live note
                    let absoluteBeat = recordingStartBeat + event.beatPosition
                    let x = CGFloat(absoluteBeat) * pixelsPerBeat
                    let y = CGFloat(pitchOffset - Int(noteData.pitch)) * noteHeight
                    let width = max(4, CGFloat(noteData.duration) * pixelsPerBeat)
                    
                    // Draw live note with slightly different style (pulsing/brighter)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.green.opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color.green, lineWidth: 1)
                        )
                        .frame(width: width, height: noteHeight - 1)
                        .offset(x: x, y: y)
                }
            }
        }
    }
    
    /// Pencil tool preview - shows note being drawn (matches actual note appearance)
    @ViewBuilder
    private var pencilPreviewLayer: some View {
        if let startBeat = pencilPreviewStart, let pitch = pencilPreviewPitch, pencilPreviewDuration > 0 {
            // Use same positioning as AdvancedNoteView for consistency
            let x = CGFloat(startBeat) * pixelsPerBeat
            let y = CGFloat(pitchOffset - pitch) * noteHeight
            let width = max(4, CGFloat(pencilPreviewDuration) * pixelsPerBeat)
            
            ZStack {
                // Match the actual note appearance
                RoundedRectangle(cornerRadius: 2)
                    .fill(trackColor)
                
                // Velocity indicator (default velocity brightness)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.3))
            }
            .frame(width: width, height: noteHeight - 2)
            .offset(x: x, y: y + 1)
        }
    }
    
    /// The absolute beat where the clip starts on the timeline
    private var clipStartBeat: Double {
        guard let clip = currentClip else { return 0 }
        return clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
    }
    
    // MARK: - Velocity Lane
    
    private var velocityLane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Velocity")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(nsColor: .windowBackgroundColor))
            
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .bottom) {
                        // Background
                        Rectangle()
                            .fill(Color.black.opacity(0.2))
                        
                        // Velocity bars (use absolute beat position)
                        ForEach(noteEvents, id: \.id) { event in
                            if case .note(let noteData) = event.type {
                                VelocityBar(
                                    beat: clipStartBeat + event.beatPosition,  // Absolute position
                                    velocity: noteData.velocity,
                                    isSelected: selectedNoteIDs.contains(event.id),
                                    pixelsPerBeat: pixelsPerBeat,
                                    height: geometry.size.height - 20,
                                    onVelocityChange: { newVelocity in
                                        updateNoteVelocity(event.id, velocity: newVelocity)
                                    }
                                )
                            }
                        }
                    }
                    .frame(width: totalWidth, height: geometry.size.height - 20)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - CC Lane
    
    private var ccLane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CC: \(selectedCCType.name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(nsColor: .windowBackgroundColor))
            
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    CCLaneEditor(
                        events: ccEvents,
                        ccType: selectedCCType,
                        pixelsPerBeat: pixelsPerBeat,
                        width: totalWidth,
                        height: geometry.size.height - 20,
                        onAddPoint: addCCPoint,
                        onUpdatePoint: updateCCPoint
                    )
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Gestures
    
    private var editingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch currentTool {
                case .select:
                    if !isMarqueeSelecting {
                        isMarqueeSelecting = true
                        selectionRect = CGRect(origin: value.startLocation, size: .zero)
                    }
                    let origin = CGPoint(
                        x: min(value.startLocation.x, value.location.x),
                        y: min(value.startLocation.y, value.location.y)
                    )
                    let size = CGSize(
                        width: abs(value.location.x - value.startLocation.x),
                        height: abs(value.location.y - value.startLocation.y)
                    )
                    selectionRect = CGRect(origin: origin, size: size)
                    
                case .pencil:
                    // Show live preview while drawing
                    let pitch = pitchAt(value.startLocation.y)
                    let clickBeat = snapBeat(value.startLocation.x / pixelsPerBeat)
                    let currentBeat = snapBeat(value.location.x / pixelsPerBeat)
                    let minDuration = snapMode.division > 0 ? snapMode.division : 0.25
                    
                    // Handle dragging left or right - note starts at leftmost position
                    let noteStart = min(clickBeat, currentBeat)
                    let noteEnd = max(clickBeat, currentBeat)
                    let duration = max(minDuration, noteEnd - noteStart)
                    
                    // Set preview state
                    pencilPreviewPitch = pitch
                    pencilPreviewStart = noteStart
                    pencilPreviewDuration = duration

                case .eraser:
                    // Erase notes under cursor
                    let pitch = pitchAt(value.location.y)
                    let beat = value.location.x / pixelsPerBeat
                    eraseNoteAt(beat: beat, pitch: pitch)
                    
                default:
                    break
                }
            }
            .onEnded { value in
                switch currentTool {
                case .select:
                    if let rect = selectionRect {
                        selectNotesInRect(rect)
                    }
                    isMarqueeSelecting = false
                    selectionRect = nil
                    
                case .pencil:
                    // Create note from preview
                    if let startBeat = pencilPreviewStart, let pitch = pencilPreviewPitch {
                        createNote(at: startBeat, pitch: pitch, duration: pencilPreviewDuration)
                    }
                    // Clear preview
                    pencilPreviewStart = nil
                    pencilPreviewPitch = nil
                    pencilPreviewDuration = 0
                    
                default:
                    break
                }
            }
    }
    
    // MARK: - Note Operations
    
    private func selectNote(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.shift) {
            if selectedNoteIDs.contains(id) {
                selectedNoteIDs.remove(id)
            } else {
                selectedNoteIDs.insert(id)
            }
        } else {
            selectedNoteIDs = [id]
        }
    }
    
    private func selectNotesInRect(_ rect: CGRect) {
        var newSelection: Set<UUID> = []
        
        for event in noteEvents {
            if case .note(let noteData) = event.type {
                let noteRect = noteRect(for: event, noteData: noteData)
                if rect.intersects(noteRect) {
                    newSelection.insert(event.id)
                }
            }
        }
        
        if NSEvent.modifierFlags.contains(.shift) {
            selectedNoteIDs.formUnion(newSelection)
        } else {
            selectedNoteIDs = newSelection
        }
    }
    
    private func selectAll() {
        selectedNoteIDs = Set(noteEvents.map { $0.id })
    }
    
    private func deleteSelected() {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        
        midiData.events.removeAll { selectedNoteIDs.contains($0.id) }
        clip.content = .midi(midiData)
        
        updateClip(clip)
        selectedNoteIDs.removeAll()
    }
    
    private func copySelected() {
        copiedNotes = noteEvents.filter { selectedNoteIDs.contains($0.id) }
    }
    
    private func paste() {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        
        let playheadBeat = viewModel.transportState.playheadBeats
        let clipStartBeat = clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
        let insertBeat = playheadBeat - clipStartBeat
        
        // Find the earliest note in copied selection
        let minBeat = copiedNotes.map { $0.beatPosition }.min() ?? 0
        
        var newSelection: Set<UUID> = []
        
        for note in copiedNotes {
            var newNote = note
            newNote.id = UUID()
            newNote.beatPosition = insertBeat + (note.beatPosition - minBeat)
            midiData.events.append(newNote)
            newSelection.insert(newNote.id)
        }
        
        clip.content = .midi(midiData)
        updateClip(clip)
        selectedNoteIDs = newSelection
    }
    
    private func duplicateSelected() {
        copySelected()
        paste()
    }
    
    /// Create a note at an absolute beat position
    private func createNote(at absoluteBeat: Double, pitch: Int, duration: Double, velocity: UInt8 = 100) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }

        // Convert absolute beat to relative beat within the clip
        let relativeBeat = absoluteBeat - clipStartBeat
        
        // Don't create notes before the clip starts
        guard relativeBeat >= 0 else { return }
        
        let newEvent = MIDIEvent.note(
            at: relativeBeat,  // Store as relative to clip start
            pitch: UInt8(pitch),
            velocity: velocity,
            duration: duration
        )

        midiData.events.append(newEvent)
        clip.content = .midi(midiData)

        updateClip(clip)
        selectedNoteIDs = [newEvent.id]
        
        // Play preview
        viewModel.playNotePreview(pitch: UInt8(pitch), velocity: velocity)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            viewModel.stopNotePreview(pitch: UInt8(pitch))
        }
    }
    
    /// Erase a note at an absolute beat position
    private func eraseNoteAt(beat absoluteBeat: Double, pitch: Int) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }

        // Convert absolute beat to relative for comparison with stored events
        let relativeBeat = absoluteBeat - clipStartBeat

        midiData.events.removeAll { event in
            if case .note(let noteData) = event.type {
                let noteStart = event.beatPosition
                let noteEnd = noteStart + noteData.duration
                return Int(noteData.pitch) == pitch && relativeBeat >= noteStart && relativeBeat <= noteEnd
            }
            return false
        }

        clip.content = .midi(midiData)
        updateClip(clip)
    }
    
    private func updateNoteVelocity(_ id: UUID, velocity: UInt8) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        
        if let index = midiData.events.firstIndex(where: { $0.id == id }) {
            if case .note(var noteData) = midiData.events[index].type {
                noteData.velocity = velocity
                midiData.events[index].type = .note(noteData)
            }
        }
        
        clip.content = .midi(midiData)
        updateClip(clip)
    }
    
    private func quantizeSelectedNotes(to grid: QuantizeGrid) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        guard !selectedNoteIDs.isEmpty else { return }
        
        let gridDivision = grid.division
        guard gridDivision > 0 else { return }
        
        for i in 0..<midiData.events.count {
            if selectedNoteIDs.contains(midiData.events[i].id) {
                // Quantize note start position to the selected grid
                let currentBeat = midiData.events[i].beatPosition
                let quantizedBeat = round(currentBeat / gridDivision) * gridDivision
                midiData.events[i].beatPosition = quantizedBeat
            }
        }
        
        clip.content = .midi(midiData)
        updateClip(clip)
        showQuantizeDialog = false
    }
    
    // MARK: - Note Dragging
    
    private func startNoteDrag(_ event: MIDIEvent, mode: NoteDragMode) {
        draggedNoteID = event.id
        dragMode = mode
        dragStartBeat = event.beatPosition
        if case .note(let noteData) = event.type {
            dragStartPitch = Int(noteData.pitch)
            dragStartDuration = noteData.duration
        }
        
        // If the dragged note is selected and we're moving, capture all selected note positions
        if mode == .move && selectedNoteIDs.contains(event.id) {
            dragStartPositions.removeAll()
            for noteEvent in noteEvents {
                if selectedNoteIDs.contains(noteEvent.id) {
                    if case .note(let data) = noteEvent.type {
                        dragStartPositions[noteEvent.id] = (
                            beat: noteEvent.beatPosition,
                            pitch: Int(data.pitch),
                            duration: data.duration
                        )
                    }
                }
            }
        } else {
            dragStartPositions.removeAll()
        }
    }
    
    private func handleNoteDrag(_ delta: CGSize) {
        guard let noteID = draggedNoteID,
              var clip = currentClip,
              case .midi(var midiData) = clip.content
        else { return }
        
        let beatDelta = delta.width / pixelsPerBeat
        let pitchDelta = -Int(delta.height / noteHeight)
        let minDuration = snapMode.division > 0 ? snapMode.division : 0.0625  // 1/16th note minimum
        
        switch dragMode {
        case .move:
            // Check if we're moving multiple selected notes
            if !dragStartPositions.isEmpty {
                // Move all selected notes together
                for (id, startPos) in dragStartPositions {
                    guard let index = midiData.events.firstIndex(where: { $0.id == id }),
                          case .note(var noteData) = midiData.events[index].type else { continue }
                    
                    let newBeat = max(0, snapBeat(startPos.beat + beatDelta))
                    midiData.events[index].beatPosition = newBeat
                    noteData.pitch = UInt8(max(0, min(127, startPos.pitch + pitchDelta)))
                    midiData.events[index].type = .note(noteData)
                }
            } else {
                // Move single note (the dragged one)
                guard let index = midiData.events.firstIndex(where: { $0.id == noteID }),
                      case .note(var noteData) = midiData.events[index].type else { return }
                
                let newBeat = max(0, snapBeat(dragStartBeat + beatDelta))
                midiData.events[index].beatPosition = newBeat
                noteData.pitch = UInt8(max(0, min(127, dragStartPitch + pitchDelta)))
                midiData.events[index].type = .note(noteData)
            }
            
        case .resizeStart:
            // Resize from start: move start position, adjust duration to keep end fixed
            guard let index = midiData.events.firstIndex(where: { $0.id == noteID }),
                  case .note(var noteData) = midiData.events[index].type else { return }
            
            let originalEnd = dragStartBeat + dragStartDuration
            let newStart = snapBeat(dragStartBeat + beatDelta)
            let newDuration = max(minDuration, originalEnd - newStart)
            midiData.events[index].beatPosition = max(0, originalEnd - newDuration)
            noteData.duration = newDuration
            midiData.events[index].type = .note(noteData)
            
        case .resizeEnd:
            // Resize from end: just change duration
            guard let index = midiData.events.firstIndex(where: { $0.id == noteID }),
                  case .note(var noteData) = midiData.events[index].type else { return }
            
            let newDuration = max(minDuration, snapBeat(dragStartDuration + beatDelta))
            noteData.duration = newDuration
            midiData.events[index].type = .note(noteData)
            
        case .none:
            break
        }
        
        clip.content = .midi(midiData)
        
        // Update without registering undo during drag
        if let trackID = viewModel.selectedTrackID,
           var track = viewModel.project.track(withID: trackID),
           let clipIndex = track.clips.firstIndex(where: { $0.id == clipID }) {
            track.clips[clipIndex] = clip
            viewModel.project.updateTrack(track)
        }
    }
    
    private func endNoteDrag() {
        if draggedNoteID != nil {
            // Register the final state with undo
            if let clip = currentClip {
                updateClip(clip)
            }
        }
        draggedNoteID = nil
        dragMode = .none
        dragStartPositions.removeAll()
    }
    
    // MARK: - CC Operations
    
    private func addCCPoint(at beat: Double, value: UInt8) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        
        let ccEvent = MIDIEvent.controlChange(
            at: beat,
            controller: UInt8(selectedCCType.rawValue),
            value: value
        )
        
        midiData.events.append(ccEvent)
        clip.content = .midi(midiData)
        updateClip(clip)
    }
    
    private func updateCCPoint(_ id: UUID, value: UInt8) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        
        if let index = midiData.events.firstIndex(where: { $0.id == id }) {
            if case .controlChange(_, _) = midiData.events[index].type {
                midiData.events[index].type = .controlChange(controller: UInt8(selectedCCType.rawValue), value: value)
            }
        }
        
        clip.content = .midi(midiData)
        updateClip(clip)
    }
    
    // MARK: - Helpers
    
    private var currentClip: Clip? {
        guard let trackID = viewModel.selectedTrackID,
              let track = viewModel.project.track(withID: trackID) else { return nil }
        return track.clips.first { $0.id == clipID }
    }
    
    private var noteEvents: [MIDIEvent] {
        guard let clip = currentClip, case .midi(let midiData) = clip.content else { return [] }
        return midiData.events.filter { if case .note = $0.type { return true } else { return false } }
    }
    
    private var ccEvents: [MIDIEvent] {
        guard let clip = currentClip, case .midi(let midiData) = clip.content else { return [] }
        return midiData.events.filter {
            if case .controlChange(let controller, _) = $0.type {
                return controller == selectedCCType.rawValue
            }
            return false
        }
    }
    
    private var totalHeight: CGFloat {
        CGFloat((visibleOctaveRange.upperBound - visibleOctaveRange.lowerBound + 1) * 12) * noteHeight
    }
    
    private var totalWidth: CGFloat {
        guard let clip = currentClip else { return 800 }
        // Show from bar 1 (beat 0) to the end of the clip plus some extra space
        let clipEndBeat = clipStartBeat + clip.timeRange.duration.beats(atTempo: viewModel.transportState.tempo.bpm)
        // Ensure we show at least 8 bars and extend past the clip
        let minBeats = max(32, clipEndBeat + 8)
        return max(800, CGFloat(minBeats) * pixelsPerBeat)
    }

    private var pitchOffset: Int {
        visibleOctaveRange.upperBound * 12 + 11
    }

    private var playheadX: CGFloat {
        // Use absolute beat position for the playhead
        return CGFloat(currentPlayheadBeat) * pixelsPerBeat
    }
    
    private func pitchAt(_ y: CGFloat) -> Int {
        let index = Int(y / noteHeight)
        return pitchOffset - index
    }
    
    private func snapBeat(_ beat: Double) -> Double {
        guard snapMode != .off, snapMode.division > 0 else { return beat }
        return round(beat / snapMode.division) * snapMode.division
    }
    
    private func noteRect(for event: MIDIEvent, noteData: NoteData) -> CGRect {
        // Use absolute beat position for selection rectangles
        let absoluteBeat = clipStartBeat + event.beatPosition
        let x = CGFloat(absoluteBeat) * pixelsPerBeat
        let y = CGFloat(pitchOffset - Int(noteData.pitch)) * noteHeight
        let width = CGFloat(noteData.duration) * pixelsPerBeat
        return CGRect(x: x, y: y, width: width, height: noteHeight)
    }
    
    private func updateClip(_ clip: Clip) {
        guard let trackID = viewModel.selectedTrackID,
              var track = viewModel.project.track(withID: trackID),
              let clipIndex = track.clips.firstIndex(where: { $0.id == clipID }) else { return }
        
        track.clips[clipIndex] = clip
        viewModel.updateTrack(track, description: "Edit MIDI")
    }
    
    private func setupInitialView() {
        // Center on middle octaves
        visibleOctaveRange = 2...7
    }
}

// MARK: - Note Drag Mode

enum NoteDragMode {
    case none
    case move
    case resizeStart
    case resizeEnd
}

// MARK: - Advanced Piano Key View

struct AdvancedPianoKeyView: View {
    let pitch: UInt8
    let noteHeight: CGFloat
    let onPress: () -> Void
    let onRelease: () -> Void
    
    @State private var isPressed = false
    
    private var isBlackKey: Bool {
        [1, 3, 6, 8, 10].contains(Int(pitch) % 12)
    }
    
    private var noteName: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = Int(pitch) / 12 - 1
        let name = names[Int(pitch) % 12]
        return pitch % 12 == 0 ? "\(name)\(octave)" : ""
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(isBlackKey ? Color.gray.opacity(0.4) : Color.white.opacity(0.1))
                .overlay(
                    Rectangle()
                        .fill(isPressed ? Color.accentColor.opacity(0.5) : Color.clear)
                )
            
            if !noteName.isEmpty {
                Text(noteName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 1)
                .offset(y: noteHeight / 2 - 0.5)
        }
        .frame(height: noteHeight)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        onPress()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    onRelease()
                }
        )
    }
}

// MARK: - Advanced Note View

struct AdvancedNoteView: View {
    let event: MIDIEvent
    let noteData: NoteData
    let isSelected: Bool
    let pixelsPerBeat: Double
    let noteHeight: CGFloat
    let pitchOffset: Int
    let noteColor: Color
    let clipStartBeat: Double  // Absolute beat where clip starts
    let onSelect: () -> Void
    let onDragStart: (NoteDragMode) -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void

    @State private var isDragging: Bool = false
    @State private var currentDragMode: NoteDragMode = .none

    private let resizeHandleWidth: CGFloat = 6

    var body: some View {
        // Calculate absolute position: clip start + note's relative position
        let absoluteBeat = clipStartBeat + event.beatPosition
        let x = CGFloat(absoluteBeat) * pixelsPerBeat
        let y = CGFloat(pitchOffset - Int(noteData.pitch)) * noteHeight
        let width = max(4, CGFloat(noteData.duration) * pixelsPerBeat)
        
        ZStack {
            // Note body
            RoundedRectangle(cornerRadius: 2)
                .fill(noteColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1)
                )
            
            // Velocity indicator (brightness)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(Double(noteData.velocity) / 127 * 0.3))
            
            // Resize handles (visible when selected)
            if isSelected {
                HStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: resizeHandleWidth)
                    Spacer()
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: resizeHandleWidth)
                }
            }
        }
        .frame(width: width, height: noteHeight - 2)
        .offset(x: x, y: y + 1)  // Position based on actual note data, no drag offset
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    // Only determine drag mode once at the start
                    if !isDragging {
                        isDragging = true
                        let localX = value.startLocation.x
                        if localX < resizeHandleWidth && isSelected {
                            currentDragMode = .resizeStart
                        } else if localX > width - resizeHandleWidth && isSelected {
                            currentDragMode = .resizeEnd
                        } else {
                            currentDragMode = .move
                        }
                        onDragStart(currentDragMode)
                    }
                    onDrag(value.translation)
                }
                .onEnded { _ in
                    isDragging = false
                    currentDragMode = .none
                    onDragEnd()
                }
        )
        .onTapGesture {
            onSelect()
        }
    }
}

// MARK: - Velocity Bar

struct VelocityBar: View {
    let beat: Double
    let velocity: UInt8
    let isSelected: Bool
    let pixelsPerBeat: Double
    let height: CGFloat
    let onVelocityChange: (UInt8) -> Void
    
    @State private var isDragging = false
    
    var body: some View {
        let x = CGFloat(beat) * pixelsPerBeat
        let barHeight = CGFloat(velocity) / 127 * height
        
        Rectangle()
            .fill(isSelected ? Color.accentColor : Color.blue)
            .frame(width: 4, height: barHeight)
            .offset(x: x, y: height - barHeight)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        let newHeight = height - value.location.y
                        let newVelocity = UInt8(max(1, min(127, Int(newHeight / height * 127))))
                        onVelocityChange(newVelocity)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

// MARK: - CC Lane Editor

struct CCLaneEditor: View {
    let events: [MIDIEvent]
    let ccType: CCType
    let pixelsPerBeat: Double
    let width: CGFloat
    let height: CGFloat
    let onAddPoint: (Double, UInt8) -> Void
    let onUpdatePoint: (UUID, UInt8) -> Void
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background
            Rectangle()
                .fill(Color.black.opacity(0.2))
            
            // CC curve
            Path { path in
                var lastPoint: CGPoint?
                
                let sortedEvents = events.sorted { $0.beatPosition < $1.beatPosition }
                
                for event in sortedEvents {
                    if case .controlChange(_, let value) = event.type {
                        let x = CGFloat(event.beatPosition) * pixelsPerBeat
                        let y = height - (CGFloat(value) / 127 * height)
                        
                        if let last = lastPoint {
                            path.move(to: last)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        lastPoint = CGPoint(x: x, y: y)
                    }
                }
            }
            .stroke(Color.orange, lineWidth: 2)
            
            // CC points
            ForEach(events, id: \.id) { event in
                if case .controlChange(_, let value) = event.type {
                    let x = CGFloat(event.beatPosition) * pixelsPerBeat
                    let y = height - (CGFloat(value) / 127 * height)
                    
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .offset(x: x - 4, y: y - 4)
                        .gesture(
                            DragGesture()
                                .onChanged { drag in
                                    let newY = min(height, max(0, drag.location.y))
                                    let newValue = UInt8(max(0, min(127, Int((1 - newY / height) * 127))))
                                    onUpdatePoint(event.id, newValue)
                                }
                        )
                }
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture { location in
            let beat = Double(location.x) / pixelsPerBeat
            let value = UInt8(max(0, min(127, Int((1 - location.y / height) * 127))))
            onAddPoint(beat, value)
        }
    }
}

// MARK: - Quantize Grid

enum QuantizeGrid: String, CaseIterable, Identifiable {
    case wholeNote = "1/1"
    case halfNote = "1/2"
    case quarterNote = "1/4"
    case eighthNote = "1/8"
    case sixteenthNote = "1/16"
    case thirtySecondNote = "1/32"
    case tripletQuarter = "1/4T"
    case tripletEighth = "1/8T"
    case tripletSixteenth = "1/16T"
    
    var id: String { rawValue }
    
    var division: Double {
        switch self {
        case .wholeNote: return 4.0
        case .halfNote: return 2.0
        case .quarterNote: return 1.0
        case .eighthNote: return 0.5
        case .sixteenthNote: return 0.25
        case .thirtySecondNote: return 0.125
        case .tripletQuarter: return 1.0 / 3.0 * 2
        case .tripletEighth: return 1.0 / 3.0
        case .tripletSixteenth: return 1.0 / 6.0
        }
    }
    
    var displayName: String {
        switch self {
        case .wholeNote: return "Whole Note"
        case .halfNote: return "Half Note"
        case .quarterNote: return "Quarter Note"
        case .eighthNote: return "Eighth Note"
        case .sixteenthNote: return "Sixteenth Note"
        case .thirtySecondNote: return "Thirty-Second Note"
        case .tripletQuarter: return "Quarter Triplet"
        case .tripletEighth: return "Eighth Triplet"
        case .tripletSixteenth: return "Sixteenth Triplet"
        }
    }
}

// MARK: - Quantize Dialog View

struct QuantizeDialogView: View {
    let noteCount: Int
    let onQuantize: (QuantizeGrid) -> Void
    let onCancel: () -> Void
    
    @State private var selectedGrid: QuantizeGrid = .sixteenthNote
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                
                Text("Quantize")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Content
            VStack(alignment: .leading, spacing: 16) {
                Text("\(noteCount) note\(noteCount == 1 ? "" : "s") selected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quantize to Grid:")
                        .font(.headline)
                    
                    // Grid options
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(QuantizeGrid.allCases) { grid in
                            Button(action: { selectedGrid = grid }) {
                                VStack(spacing: 4) {
                                    Text(grid.rawValue)
                                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                                    Text(grid.displayName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedGrid == grid ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(selectedGrid == grid ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
            
            Divider()
            
            // Footer buttons
            HStack {
                Spacer()
                
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Quantize") {
                    onQuantize(selectedGrid)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
