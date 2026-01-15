import SwiftUI
import DAWCore

// MARK: - Scroll Offset Tracking

/// PreferenceKey to track vertical scroll offset for synchronization
private struct VerticalScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// PreferenceKey to track horizontal scroll offset for synchronization
private struct HorizontalScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Track-Based Piano Roll View

/// A piano roll that shows ALL MIDI on a track, not tied to individual clips.
/// Auto-creates a master clip when the user draws notes on an empty track.
public struct TrackPianoRollView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    
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
    @State private var pencilPreviewStart: Double? = nil
    @State private var pencilPreviewPitch: Int? = nil
    @State private var pencilPreviewDuration: Double = 0

    // Editing state
    @State private var draggedNoteID: UUID? = nil
    @State private var dragMode: NoteDragMode = .none
    @State private var dragStartBeat: Double = 0
    @State private var dragStartPitch: Int = 0
    @State private var dragStartDuration: Double = 0
    
    // Current drag delta (for visual feedback during drag)
    @State private var currentDragBeatDelta: Double = 0
    @State private var currentDragPitchDelta: Int = 0

    // Multi-select drag state
    @State private var dragStartPositions: [UUID: (beat: Double, pitch: Int, duration: Double)] = [:]
    
    // Note audition during drag
    @State private var lastAuditionedPitch: Int? = nil
    
    // Modifier key states
    @State private var isCopyingNotes: Bool = false
    
    // Dialogs
    @State private var showQuantizeDialog: Bool = false
    @State private var showOffsetDialog: Bool = false

    // View state
    @State private var pixelsPerBeat: Double = 60
    @State private var noteHeight: CGFloat = 14
    @State private var visibleOctaveRange: ClosedRange<Int> = 2...7
    
    // Copied notes for paste
    @State private var copiedNotes: [MIDIEvent] = []
    
    // Playhead position
    @State private var currentPlayheadBeat: Double = 0
    
    // Track color for notes
    private var trackColor: Color {
        if let track = viewModel.project.track(withID: trackID) {
            return Color(hex: track.color.hex) ?? .accentColor
        }
        return .accentColor
    }
    
    private let pianoKeyWidth: CGFloat = 60
    private let velocityLaneHeight: CGFloat = 80
    private let ccLaneHeight: CGFloat = 80
    
    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }
    
    // MARK: - Computed Properties
    
    /// Get the current track
    private var currentTrack: Track? {
        viewModel.project.track(withID: trackID)
    }
    
    /// Get or create the master clip for this track
    private var masterClip: Clip? {
        guard let track = currentTrack else { return nil }
        // Return the first MIDI clip (acts as master)
        return track.clips.first(where: { $0.content.isMIDI })
    }
    
    /// All note events from all clips on this track (with absolute beat positions)
    private var noteEvents: [MIDIEvent] {
        guard let track = currentTrack else { return [] }
        
        var allNotes: [MIDIEvent] = []
        for clip in track.clips {
            if case .midi(let midiData) = clip.content {
                let clipStartBeat = clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                for event in midiData.events {
                    if case .note = event.type {
                        // Convert to absolute beat position
                        var absoluteEvent = event
                        absoluteEvent.beatPosition = clipStartBeat + event.beatPosition
                        allNotes.append(absoluteEvent)
                    }
                }
            }
        }
        return allNotes
    }
    
    /// All CC events from all clips on this track
    private var ccEvents: [MIDIEvent] {
        guard let track = currentTrack else { return [] }
        
        var allCC: [MIDIEvent] = []
        for clip in track.clips {
            if case .midi(let midiData) = clip.content {
                let clipStartBeat = clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                for event in midiData.events {
                    if case .controlChange(let controller, _) = event.type {
                        if controller == selectedCCType.rawValue {
                            var absoluteEvent = event
                            absoluteEvent.beatPosition = clipStartBeat + event.beatPosition
                            allCC.append(absoluteEvent)
                        }
                    }
                }
            }
        }
        return allCC
    }
    
    private var pitchOffset: Int {
        visibleOctaveRange.upperBound * 12 + 11
    }
    
    private var totalHeight: CGFloat {
        CGFloat((visibleOctaveRange.count) * 12) * noteHeight
    }
    
    private var totalWidth: CGFloat {
        // Show at least 32 bars worth
        let minBeats = 32.0 * 4.0
        let trackEndBeat = noteEvents.map { event -> Double in
            if case .note(let data) = event.type {
                return event.beatPosition + data.duration
            }
            return event.beatPosition
        }.max() ?? 0
        return CGFloat(max(minBeats, trackEndBeat + 16)) * pixelsPerBeat
    }
    
    private var playheadX: CGFloat {
        CGFloat(currentPlayheadBeat) * pixelsPerBeat
    }
    
    // MARK: - Body
    
    // Track scroll offsets for synchronization
    @State private var horizontalScrollOffset: CGFloat = 0
    
    public var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            
            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
            
            GeometryReader { geometry in
                let availableHeight = geometry.size.height - (showVelocityLane ? velocityLaneHeight : 0) - (showCCLane ? ccLaneHeight : 0) - 24
                let visibleWidth = geometry.size.width - pianoKeyWidth
                
                VStack(spacing: 0) {
                    // TOP ROW: Corner + Bar ruler (synced with note grid horizontal scroll)
                    HStack(spacing: 0) {
                        Color(nsColor: .windowBackgroundColor)
                            .frame(width: pianoKeyWidth, height: 24)
                        
                        // Bar ruler - offset to match note grid horizontal scroll
                        barRulerCanvas
                            .frame(width: totalWidth, height: 24)
                            .offset(x: horizontalScrollOffset)
                            .frame(width: visibleWidth, alignment: .leading)
                            .clipped()
                    }
                    .frame(height: 24)
                    
                    // MIDDLE ROW: Piano keys + Note grid (SAME vertical scroll)
                    ScrollView(.vertical, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            // Piano keys
                            pianoKeysCanvas
                                .frame(width: pianoKeyWidth, height: totalHeight)
                            
                            // Note grid (horizontal scroll inside) - tracks position
                            ScrollView(.horizontal, showsIndicators: true) {
                                noteGridCanvas
                                    .frame(width: totalWidth, height: totalHeight)
                                    .background(
                                        GeometryReader { innerGeo in
                                            Color.clear.preference(
                                                key: HorizontalScrollOffsetKey.self,
                                                value: innerGeo.frame(in: .named("noteGridHorizontalScroll")).minX
                                            )
                                        }
                                    )
                            }
                            .coordinateSpace(name: "noteGridHorizontalScroll")
                            .onPreferenceChange(HorizontalScrollOffsetKey.self) { offset in
                                horizontalScrollOffset = offset
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                    .frame(height: availableHeight)
                    .focusEffectDisabled()
                    
                    // BOTTOM ROW: Labels + Velocity/CC (synced with note grid horizontal scroll)
                    if showVelocityLane {
                        HStack(spacing: 0) {
                            Text("Vel")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: pianoKeyWidth, height: velocityLaneHeight)
                                .background(Color(nsColor: .windowBackgroundColor))
                            
                            // Velocity - offset to match note grid horizontal scroll
                            velocityCanvas
                                .frame(width: totalWidth, height: velocityLaneHeight)
                                .offset(x: horizontalScrollOffset)
                                .frame(width: visibleWidth, alignment: .leading)
                                .clipped()
                        }
                        .frame(height: velocityLaneHeight)
                    }
                    
                    if showCCLane {
                        HStack(spacing: 0) {
                            Text(selectedCCType.name)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: pianoKeyWidth, height: ccLaneHeight)
                                .background(Color(nsColor: .windowBackgroundColor))
                            
                            // CC - offset to match note grid horizontal scroll
                            ccCanvas
                                .frame(width: totalWidth, height: ccLaneHeight)
                                .offset(x: horizontalScrollOffset)
                                .frame(width: visibleWidth, alignment: .leading)
                                .clipped()
                        }
                        .frame(height: ccLaneHeight)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { keyPress in
            // CMD + Arrow keys for zoom
            if keyPress.modifiers.contains(.command) {
                switch keyPress.key {
                case .leftArrow:
                    zoomHorizontal(zoomIn: false)
                    return .handled
                case .rightArrow:
                    zoomHorizontal(zoomIn: true)
                    return .handled
                case .upArrow:
                    zoomVertical(zoomIn: true)
                    return .handled
                case .downArrow:
                    zoomVertical(zoomIn: false)
                    return .handled
                default:
                    break
                }
            }
            
            // Delete key - delete selected notes (backspace, delete, fn+delete)
            let isDeleteKey = keyPress.key == .delete || 
                              keyPress.key == .deleteForward ||
                              keyPress.characters == "\u{7F}" ||  // Backspace (ASCII 127)
                              keyPress.characters == "\u{08}"     // Backspace (ASCII 8)
            if isDeleteKey {
                if !selectedNoteIDs.isEmpty {
                    deleteSelectedNotes()
                    return .handled
                }
            }
            
            // Tool shortcuts (without modifiers)
            switch keyPress.characters.lowercased() {
            case "a": currentTool = .select; return .handled
            case "p": currentTool = .pencil; return .handled
            case "e": currentTool = .eraser; return .handled
            case "v": currentTool = .velocity; return .handled
            case "s": currentTool = .split; return .handled
            case "g": currentTool = .glue; return .handled
            case "m": currentTool = .mute; return .handled
            case "q":
                if !selectedNoteIDs.isEmpty { showQuantizeDialog = true }
                return .handled
            default: return .ignored
            }
        }
        .onAppear {
            visibleOctaveRange = 2...7
            currentPlayheadBeat = viewModel.transportState.playheadBeats
        }
        .onReceive(viewModel.transportState.$playheadBeats) { beats in
            currentPlayheadBeat = beats
        }
        .sheet(isPresented: $showQuantizeDialog) {
            QuantizeDialogView(
                noteCount: selectedNoteIDs.count,
                onQuantize: { grid in quantizeSelectedNotes(to: grid) },
                onCancel: { showQuantizeDialog = false }
            )
        }
        .sheet(isPresented: $showOffsetDialog) {
            OffsetDialogView(
                noteCount: selectedNoteIDs.count,
                tempo: viewModel.transportState.tempo.bpm,
                onApply: { ms in applyOffset(milliseconds: ms); showOffsetDialog = false },
                onCancel: { showOffsetDialog = false }
            )
        }
    }
    
    // MARK: - Toolbar
    
    private var editorToolbar: some View {
        HStack(spacing: 12) {
            Button(action: { viewModel.closePianoRoll() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            
            Divider().frame(height: 20)
            
            ForEach(MIDIEditorTool.allCases, id: \.self) { tool in
                Button(action: { currentTool = tool }) {
                    Image(systemName: tool.icon)
                        .foregroundColor(currentTool == tool ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
                .help("\(tool.rawValue) (\(tool.shortcutKey))")
            }
            
            Divider().frame(height: 20)
            
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
            
            Button("Quantize") { showQuantizeDialog = true }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(selectedNoteIDs.isEmpty)
            
            Button("Offset") { showOffsetDialog = true }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(selectedNoteIDs.isEmpty)
            
            Spacer()
            
            // Zoom controls
            HStack(spacing: 4) {
                Text("H:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: { zoomHorizontal(zoomIn: false) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom Out Horizontal (⌘←)")
                Button(action: { zoomHorizontal(zoomIn: true) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom In Horizontal (⌘→)")
            }
            
            HStack(spacing: 4) {
                Text("V:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: { zoomVertical(zoomIn: false) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom Out Vertical (⌘↓)")
                Button(action: { zoomVertical(zoomIn: true) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Zoom In Vertical (⌘↑)")
            }
            
            Divider().frame(height: 20)
            
            Toggle("Velocity", isOn: $showVelocityLane)
                .toggleStyle(.checkbox)
                .font(.caption)
            
            Toggle("CC", isOn: $showCCLane)
                .toggleStyle(.checkbox)
                .font(.caption)
            
            if showCCLane {
                Picker("", selection: $selectedCCType) {
                    ForEach(CCType.allCases) { cc in
                        Text(cc.name).tag(cc)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }
            
            // Track name
            if let track = currentTrack {
                Text(track.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Bar Ruler Canvas
    
    private var barRulerCanvas: some View {
        Canvas { context, size in
            let timeSignature = viewModel.transportState.timeSignature
            let beatsPerBar = timeSignature.beatsPerBar
            let totalBeats = Int(totalWidth / pixelsPerBeat) + 1
            
            for beat in 0...totalBeats {
                let x = Double(beat) * pixelsPerBeat
                let isBarLine = beat % beatsPerBar == 0
                
                let linePath = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                
                if isBarLine {
                    context.stroke(linePath, with: .color(Color.gray.opacity(0.5)), lineWidth: 1)
                    let barNumber = (beat / beatsPerBar) + 1
                    let barText = Text("\(barNumber)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                    context.draw(barText, at: CGPoint(x: x + 8, y: size.height / 2))
                } else {
                    context.stroke(linePath, with: .color(Color.gray.opacity(0.3)), lineWidth: 0.5)
                }
            }
            
            // Playhead
            let playheadPath = Path { path in
                path.move(to: CGPoint(x: playheadX, y: 0))
                path.addLine(to: CGPoint(x: playheadX, y: size.height))
            }
            context.stroke(playheadPath, with: .color(Color.accentColor), lineWidth: 1)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let beat = max(0, value.location.x / pixelsPerBeat)
                    viewModel.transportState.setPlayheadBeats(beat)
                    currentPlayheadBeat = beat
                }
        )
    }
    
    // MARK: - Note Grid Canvas
    
    /// Check if we're recording on this track
    private var isRecordingOnThisTrack: Bool {
        viewModel.isRecording && viewModel.recordingTrackID == trackID
    }
    
    /// Get live recorded events for display
    private var liveRecordedEvents: [MIDIEvent] {
        viewModel.midiRecorder.liveRecordedEvents
    }
    
    /// Get the beat position where recording started
    private var liveRecordingStartBeat: Double {
        viewModel.midiRecorder.liveRecordingStartBeat
    }
    
    private var noteGridCanvas: some View {
        Canvas { context, size in
            let timeSignature = viewModel.transportState.timeSignature
            let beatsPerBar = timeSignature.beatsPerBar
            let totalBeats = Int(totalWidth / pixelsPerBeat) + 1
            let pitchRange = visibleOctaveRange.lowerBound * 12...visibleOctaveRange.upperBound * 12 + 11
            
            // Horizontal lines (pitch rows)
            for (index, pitch) in pitchRange.reversed().enumerated() {
                let y = Double(index) * Double(noteHeight)
                let isBlackKey = [1, 3, 6, 8, 10].contains(pitch % 12)
                
                if isBlackKey {
                    let rect = CGRect(x: 0, y: y, width: size.width, height: Double(noteHeight))
                    context.fill(Path(rect), with: .color(Color.black.opacity(0.1)))
                }
                
                let linePath = Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(linePath, with: .color(Color.gray.opacity(pitch % 12 == 0 ? 0.3 : 0.1)), lineWidth: pitch % 12 == 0 ? 1 : 0.5)
            }
            
            // Vertical lines (beat/bar)
            for beat in 0...totalBeats {
                let x = Double(beat) * pixelsPerBeat
                let isBarLine = beat % beatsPerBar == 0
                
                let linePath = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(linePath, with: .color(Color.gray.opacity(isBarLine ? 0.5 : 0.2)), lineWidth: isBarLine ? 1 : 0.5)
            }
            
            // Draw existing notes (with drag offset for selected notes being dragged)
            for event in noteEvents {
                if case .note(let noteData) = event.type {
                    var noteX = event.beatPosition * pixelsPerBeat
                    var notePitch = Int(noteData.pitch)
                    let isSelected = selectedNoteIDs.contains(event.id)
                    let isDragging = draggedNoteID != nil && isSelected && dragStartPositions[event.id] != nil
                    
                    // Apply drag offset for selected notes during drag
                    if isDragging, let startPos = dragStartPositions[event.id] {
                        // Show at dragged position
                        let newBeat = max(0, startPos.beat + currentDragBeatDelta)
                        let newPitch = max(0, min(127, startPos.pitch + currentDragPitchDelta))
                        noteX = newBeat * pixelsPerBeat
                        notePitch = newPitch
                    }
                    
                    let noteY = Double(pitchOffset - notePitch) * Double(noteHeight)
                    let noteWidth = max(4, noteData.duration * pixelsPerBeat)
                    
                    let noteRect = CGRect(x: noteX, y: noteY + 1, width: noteWidth, height: Double(noteHeight) - 2)
                    let notePath = Path(roundedRect: noteRect, cornerRadius: 2)
                    
                    context.fill(notePath, with: .color(trackColor))
                    context.fill(notePath, with: .color(Color.white.opacity(Double(noteData.velocity) / 127.0 * 0.3)))
                    
                    if isSelected {
                        context.stroke(notePath, with: .color(Color.white), lineWidth: 1.5)
                    }
                }
            }
            
            // Draw LIVE recording notes (in real-time as they're played)
            if isRecordingOnThisTrack {
                let recordStartX = liveRecordingStartBeat * pixelsPerBeat
                
                for event in liveRecordedEvents {
                    if case .note(let noteData) = event.type {
                        // Live events have positions relative to recording start
                        let noteX = recordStartX + (event.beatPosition * pixelsPerBeat)
                        let noteY = Double(pitchOffset - Int(noteData.pitch)) * Double(noteHeight)
                        let noteWidth = max(4, noteData.duration * pixelsPerBeat)
                        
                        let noteRect = CGRect(x: noteX, y: noteY + 1, width: noteWidth, height: Double(noteHeight) - 2)
                        let notePath = Path(roundedRect: noteRect, cornerRadius: 2)
                        
                        // Live notes: brighter color
                        context.fill(notePath, with: .color(trackColor))
                        context.fill(notePath, with: .color(Color.white.opacity(0.4)))
                    }
                }
            }
            
            // Playhead
            let playheadPath = Path { path in
                path.move(to: CGPoint(x: playheadX, y: 0))
                path.addLine(to: CGPoint(x: playheadX, y: size.height))
            }
            context.stroke(playheadPath, with: .color(Color.accentColor), lineWidth: 1)
            
            // Draw selection rectangle (marquee)
            if isMarqueeSelecting, let rect = selectionRect {
                let selectionPath = Path(rect)
                context.fill(selectionPath, with: .color(Color.blue.opacity(0.2)))
                context.stroke(selectionPath, with: .color(Color.blue.opacity(0.8)), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .gesture(noteEditingGesture)
    }
    
    // MARK: - Velocity Canvas
    
    private var velocityCanvas: some View {
        Canvas { context, size in
            let timeSignature = viewModel.transportState.timeSignature
            let beatsPerBar = timeSignature.beatsPerBar
            let totalBeats = Int(totalWidth / pixelsPerBeat) + 1
            
            // Vertical lines
            for beat in 0...totalBeats {
                let x = Double(beat) * pixelsPerBeat
                let isBarLine = beat % beatsPerBar == 0
                
                let linePath = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(linePath, with: .color(Color.gray.opacity(isBarLine ? 0.5 : 0.2)), lineWidth: isBarLine ? 1 : 0.5)
            }
            
            // Velocity bars for existing notes
            for event in noteEvents {
                if case .note(let noteData) = event.type {
                    let barX = event.beatPosition * pixelsPerBeat
                    let barHeight = (Double(noteData.velocity) / 127.0) * (size.height - 4)
                    let barY = size.height - barHeight
                    let isSelected = selectedNoteIDs.contains(event.id)
                    
                    let barRect = CGRect(x: barX - 2, y: barY, width: 4, height: barHeight)
                    context.fill(Path(barRect), with: .color(isSelected ? Color.accentColor : trackColor))
                }
            }
            
            // Velocity bars for LIVE recording notes
            if isRecordingOnThisTrack {
                let recordStartX = liveRecordingStartBeat * pixelsPerBeat
                
                for event in liveRecordedEvents {
                    if case .note(let noteData) = event.type {
                        let barX = recordStartX + (event.beatPosition * pixelsPerBeat)
                        let barHeight = (Double(noteData.velocity) / 127.0) * (size.height - 4)
                        let barY = size.height - barHeight
                        
                        let barRect = CGRect(x: barX - 2, y: barY, width: 4, height: barHeight)
                        context.fill(Path(barRect), with: .color(trackColor))
                    }
                }
            }
            
            // Playhead
            let playheadPath = Path { path in
                path.move(to: CGPoint(x: playheadX, y: 0))
                path.addLine(to: CGPoint(x: playheadX, y: size.height))
            }
            context.stroke(playheadPath, with: .color(Color.accentColor), lineWidth: 1)
        }
        .background(Color.black.opacity(0.15))
    }
    
    // MARK: - CC Canvas
    
    private var ccCanvas: some View {
        Canvas { context, size in
            let timeSignature = viewModel.transportState.timeSignature
            let beatsPerBar = timeSignature.beatsPerBar
            let totalBeats = Int(totalWidth / pixelsPerBeat) + 1
            
            // Vertical lines
            for beat in 0...totalBeats {
                let x = Double(beat) * pixelsPerBeat
                let isBarLine = beat % beatsPerBar == 0
                
                let linePath = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(linePath, with: .color(Color.gray.opacity(isBarLine ? 0.5 : 0.2)), lineWidth: isBarLine ? 1 : 0.5)
            }
            
            // CC points
            let sortedEvents = ccEvents.sorted { $0.beatPosition < $1.beatPosition }
            var lastPoint: CGPoint? = nil
            
            for event in sortedEvents {
                if case .controlChange(_, let value) = event.type {
                    let x = event.beatPosition * pixelsPerBeat
                    let y = size.height - (Double(value) / 127.0) * size.height
                    let point = CGPoint(x: x, y: y)
                    
                    if let last = lastPoint {
                        let linePath = Path { path in
                            path.move(to: last)
                            path.addLine(to: point)
                        }
                        context.stroke(linePath, with: .color(Color.orange), lineWidth: 1)
                    }
                    
                    let pointRect = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: pointRect), with: .color(Color.orange))
                    lastPoint = point
                }
            }
            
            // Playhead
            let playheadPath = Path { path in
                path.move(to: CGPoint(x: playheadX, y: 0))
                path.addLine(to: CGPoint(x: playheadX, y: size.height))
            }
            context.stroke(playheadPath, with: .color(Color.accentColor), lineWidth: 1)
        }
        .background(Color.black.opacity(0.15))
    }
    
    // MARK: - Note Editing Gesture
    
    // Find note at a given position
    private func noteAt(x: CGFloat, y: CGFloat) -> MIDIEvent? {
        let clickBeat = x / pixelsPerBeat
        let clickPitch = pitchFromY(y)
        
        for event in noteEvents {
            if case .note(let noteData) = event.type {
                let noteStartBeat = event.beatPosition
                let noteEndBeat = noteStartBeat + noteData.duration
                let notePitch = Int(noteData.pitch)
                
                if clickBeat >= noteStartBeat && clickBeat <= noteEndBeat && clickPitch == notePitch {
                    return event
                }
            }
        }
        return nil
    }
    
    private var noteEditingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let beat = value.location.x / pixelsPerBeat
                let pitch = pitchFromY(value.location.y)

                switch currentTool {
                case .pencil:
                    if pencilPreviewStart == nil {
                        pencilPreviewStart = snapBeat(beat)
                        pencilPreviewPitch = pitch
                        pencilPreviewDuration = snapMode.division > 0 ? snapMode.division : 0.25
                        viewModel.playNotePreview(pitch: UInt8(pitch))
                    } else if let start = pencilPreviewStart {
                        pencilPreviewDuration = max(snapMode.division > 0 ? snapMode.division : 0.25, snapBeat(beat) - start)
                    }

                case .select:
                    // Check if we're starting a drag on an existing note
                    if draggedNoteID == nil && !isMarqueeSelecting {
                        if let clickedNote = noteAt(x: value.startLocation.x, y: value.startLocation.y) {
                            // Clicked on a note - select it and start dragging
                            if !selectedNoteIDs.contains(clickedNote.id) {
                                if !NSEvent.modifierFlags.contains(.shift) {
                                    selectedNoteIDs = [clickedNote.id]
                                } else {
                                    selectedNoteIDs.insert(clickedNote.id)
                                }
                            }
                            draggedNoteID = clickedNote.id
                            dragStartBeat = beat
                            dragStartPitch = pitch
                            
                            // Store initial positions of all selected notes
                            dragStartPositions.removeAll()
                            for event in noteEvents {
                                if selectedNoteIDs.contains(event.id) {
                                    if case .note(let data) = event.type {
                                        dragStartPositions[event.id] = (
                                            beat: event.beatPosition,
                                            pitch: Int(data.pitch),
                                            duration: data.duration
                                        )
                                    }
                                }
                            }
                        } else {
                            // Clicked on empty space - start marquee selection
                            isMarqueeSelecting = true
                            selectionRect = CGRect(origin: value.startLocation, size: .zero)
                        }
                    }
                    
                    // Handle ongoing drag
                    if draggedNoteID != nil {
                        let beatDelta = beat - dragStartBeat
                        let pitchDelta = pitch - dragStartPitch
                        
                        // Update drag delta for visual feedback
                        currentDragBeatDelta = beatDelta
                        currentDragPitchDelta = pitchDelta
                        
                        // Audition pitch change
                        if pitch != lastAuditionedPitch {
                            viewModel.playNotePreview(pitch: UInt8(max(0, min(127, pitch))))
                            lastAuditionedPitch = pitch
                        }
                    } else if isMarqueeSelecting {
                        let origin = CGPoint(
                            x: min(value.startLocation.x, value.location.x),
                            y: min(value.startLocation.y, value.location.y)
                        )
                        let size = CGSize(
                            width: abs(value.location.x - value.startLocation.x),
                            height: abs(value.location.y - value.startLocation.y)
                        )
                        selectionRect = CGRect(origin: origin, size: size)
                    }

                case .eraser:
                    eraseNoteAt(beat: beat, pitch: pitch)

                default:
                    break
                }
            }
            .onEnded { value in
                let beat = value.location.x / pixelsPerBeat
                let pitch = pitchFromY(value.location.y)

                switch currentTool {
                case .pencil:
                    if let start = pencilPreviewStart, let notePitch = pencilPreviewPitch {
                        createNote(at: start, pitch: notePitch, duration: pencilPreviewDuration)
                    }
                    pencilPreviewStart = nil
                    pencilPreviewPitch = nil
                    pencilPreviewDuration = 0

                case .select:
                    if draggedNoteID != nil {
                        // Finish dragging - commit the move
                        commitNotesMove(beatDelta: currentDragBeatDelta, pitchDelta: currentDragPitchDelta)
                        draggedNoteID = nil
                        dragStartPositions.removeAll()
                        lastAuditionedPitch = nil
                        currentDragBeatDelta = 0
                        currentDragPitchDelta = 0
                    } else if isMarqueeSelecting, let rect = selectionRect {
                        selectNotesInRect(rect)
                    }
                    isMarqueeSelecting = false
                    selectionRect = nil

                case .eraser:
                    eraseNoteAt(beat: beat, pitch: pitch)
                    
                default:
                    break
                }
            }
    }
    
    // MARK: - Piano Keyboard
    
    private var pianoKeyboard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach((visibleOctaveRange.lowerBound * 12...visibleOctaveRange.upperBound * 12 + 11).reversed(), id: \.self) { pitch in
                    AdvancedPianoKeyView(
                        pitch: UInt8(pitch),
                        noteHeight: noteHeight,
                        onPress: { viewModel.playNotePreview(pitch: UInt8(pitch)) },
                        onRelease: { }
                    )
                }
            }
        }
    }
    
    // MARK: - Piano Keys Canvas (for synchronized scrolling)
    
    private var pianoKeysCanvas: some View {
        Canvas { context, size in
            let pitchRange = visibleOctaveRange.lowerBound * 12...visibleOctaveRange.upperBound * 12 + 11
            
            for (index, pitch) in pitchRange.reversed().enumerated() {
                let y = Double(index) * Double(noteHeight)
                let isBlackKey = [1, 3, 6, 8, 10].contains(pitch % 12)
                let isC = pitch % 12 == 0
                
                // Key background (white keys = white, black keys = black)
                let keyRect = CGRect(x: 0, y: y, width: size.width, height: Double(noteHeight))
                
                if isBlackKey {
                    context.fill(Path(keyRect), with: .color(Color.black))
                } else {
                    context.fill(Path(keyRect), with: .color(Color.white.opacity(0.85)))
                }
                
                // Key border
                let borderPath = Path { path in
                    path.move(to: CGPoint(x: 0, y: y + Double(noteHeight)))
                    path.addLine(to: CGPoint(x: size.width, y: y + Double(noteHeight)))
                }
                context.stroke(borderPath, with: .color(Color.gray.opacity(0.5)), lineWidth: 0.5)
                
                // Note name for C notes (black text on white key)
                if isC {
                    let octave = pitch / 12 - 1
                    let noteText = Text("C\(octave)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.black)
                    context.draw(noteText, at: CGPoint(x: size.width - 18, y: y + Double(noteHeight) / 2))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let pitch = pitchFromY(value.location.y)
                    if pitch >= 0 && pitch <= 127 {
                        viewModel.playNotePreview(pitch: UInt8(pitch))
                    }
                }
        )
    }
    
    
    // MARK: - Helper Functions
    
    private func pitchFromY(_ y: CGFloat) -> Int {
        let index = Int(y / noteHeight)
        return pitchOffset - index
    }
    
    private func snapBeat(_ beat: Double) -> Double {
        if NSEvent.modifierFlags.contains(.command) {
            return beat
        }
        guard snapMode != .off, snapMode.division > 0 else { return beat }
        return round(beat / snapMode.division) * snapMode.division
    }
    
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
        var newSelection: Set<UUID> = NSEvent.modifierFlags.contains(.shift) ? selectedNoteIDs : []

        for event in noteEvents {
            if case .note(let noteData) = event.type {
                let x = event.beatPosition * pixelsPerBeat
                let y = Double(pitchOffset - Int(noteData.pitch)) * Double(noteHeight)
                let width = noteData.duration * pixelsPerBeat
                let noteRect = CGRect(x: x, y: y, width: width, height: Double(noteHeight))

                if rect.intersects(noteRect) {
                    newSelection.insert(event.id)
                }
            }
        }

        selectedNoteIDs = newSelection
    }
    
    // MARK: - Note Operations
    
    /// Move selected notes visually during drag (doesn't commit to model yet)
    private func moveSelectedNotes(beatDelta: Double, pitchDelta: Int) {
        // This is handled by recalculating positions in the Canvas draw
        // The actual positions are computed from dragStartPositions + deltas
    }
    
    /// Commit the note move to the data model
    private func commitNotesMove(beatDelta: Double, pitchDelta: Int) {
        guard var track = currentTrack else { return }
        guard !dragStartPositions.isEmpty else { return }
        
        let snappedBeatDelta = snapBeat(beatDelta) - snapBeat(0) // Apply snap to delta
        
        for clipIndex in 0..<track.clips.count {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                let clipStartBeat = track.clips[clipIndex].timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                var modified = false
                
                for i in 0..<midiData.events.count {
                    let eventID = midiData.events[i].id
                    if let startPos = dragStartPositions[eventID] {
                        if case .note(var noteData) = midiData.events[i].type {
                            // Calculate new position
                            let newBeat = max(0, startPos.beat + snappedBeatDelta)
                            let newPitch = max(0, min(127, startPos.pitch + pitchDelta))
                            
                            midiData.events[i].beatPosition = newBeat - clipStartBeat
                            noteData.pitch = UInt8(newPitch)
                            midiData.events[i].type = .note(noteData)
                            modified = true
                        }
                    }
                }
                
                if modified {
                    track.clips[clipIndex].content = .midi(midiData)
                }
            }
        }
        
        viewModel.updateTrack(track, description: "Move Notes")
    }

    private func createNote(at beat: Double, pitch: Int, duration: Double, velocity: UInt8 = 100) {
        guard var track = currentTrack else { return }
        
        // Get or create the master clip
        if let clipIndex = track.clips.firstIndex(where: { $0.content.isMIDI }) {
            // Add to existing clip
            if case .midi(var midiData) = track.clips[clipIndex].content {
                let clipStartBeat = track.clips[clipIndex].timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                let relativeBeat = beat - clipStartBeat
                
                let noteData = NoteData(pitch: UInt8(pitch), velocity: velocity, duration: duration)
                let noteEvent = MIDIEvent(beatPosition: max(0, relativeBeat), type: .note(noteData), channel: 0)
                midiData.events.append(noteEvent)
                
                track.clips[clipIndex].content = .midi(midiData)
                viewModel.updateTrack(track, description: "Add Note")
            }
        } else {
            // Create a new master clip starting at beat 0
            let tempo = viewModel.transportState.tempo.bpm
            let clipDuration = max(beat + duration + 4, 16.0) // At least 4 bars
            
            var midiData = MIDIClipData()
            let noteData = NoteData(pitch: UInt8(pitch), velocity: velocity, duration: duration)
            let noteEvent = MIDIEvent(beatPosition: beat, type: .note(noteData), channel: 0)
            midiData.events.append(noteEvent)
            
            let newClip = Clip(
                name: "MIDI",
                timeRange: TimeRange(
                    start: TimePosition(beats: 0, tempo: tempo),
                    duration: TimePosition(beats: clipDuration, tempo: tempo)
                ),
                content: .midi(midiData)
            )
            
            track.clips.append(newClip)
            viewModel.updateTrack(track, description: "Create MIDI")
        }
    }
    
    private func eraseNoteAt(beat: Double, pitch: Int) {
        guard var track = currentTrack else { return }
        var modified = false
        
        for clipIndex in 0..<track.clips.count {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                let clipStartBeat = track.clips[clipIndex].timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                
                let countBefore = midiData.events.count
                midiData.events.removeAll { event in
                    if case .note(let noteData) = event.type {
                        let absoluteBeat = clipStartBeat + event.beatPosition
                        let noteEnd = absoluteBeat + noteData.duration
                        return Int(noteData.pitch) == pitch &&
                               beat >= absoluteBeat &&
                               beat <= noteEnd
                    }
                    return false
                }
                
                if midiData.events.count != countBefore {
                    track.clips[clipIndex].content = .midi(midiData)
                    modified = true
                }
            }
        }
        
        if modified {
            viewModel.updateTrack(track, description: "Erase Note")
        }
    }
    
    private func deleteSelectedNotes() {
        guard var track = currentTrack else { return }
        guard !selectedNoteIDs.isEmpty else { return }
        
        var modified = false
        
        for clipIndex in 0..<track.clips.count {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                let countBefore = midiData.events.count
                midiData.events.removeAll { event in
                    selectedNoteIDs.contains(event.id)
                }
                
                if midiData.events.count != countBefore {
                    track.clips[clipIndex].content = .midi(midiData)
                    modified = true
                }
            }
        }
        
        if modified {
            viewModel.updateTrack(track, description: "Delete Notes")
            selectedNoteIDs.removeAll()
        }
    }
    
    private func updateNoteVelocity(_ id: UUID, velocity: UInt8) {
        guard var track = currentTrack else { return }
        
        for clipIndex in 0..<track.clips.count {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                if let eventIndex = midiData.events.firstIndex(where: { $0.id == id }) {
                    if case .note(var noteData) = midiData.events[eventIndex].type {
                        noteData.velocity = velocity
                        midiData.events[eventIndex].type = .note(noteData)
                        track.clips[clipIndex].content = .midi(midiData)
                        viewModel.updateTrack(track, description: "Edit Velocity")
                        return
                    }
                }
            }
        }
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
        
        isCopyingNotes = NSEvent.modifierFlags.contains(.option) && mode == .move

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
              var track = currentTrack
        else { return }

        let beatDelta = delta.width / pixelsPerBeat
        let pitchDelta = -Int(delta.height / noteHeight)
        let minDuration = snapMode.division > 0 ? snapMode.division : 0.0625

        switch dragMode {
        case .move:
            let newPitch = max(0, min(127, dragStartPitch + pitchDelta))
            if newPitch != lastAuditionedPitch {
                viewModel.playNotePreview(pitch: UInt8(newPitch))
                lastAuditionedPitch = newPitch
            }
            
            // Update notes in track
            for clipIndex in 0..<track.clips.count {
                if case .midi(var midiData) = track.clips[clipIndex].content {
                    let clipStartBeat = track.clips[clipIndex].timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                    var modified = false
                    
                    if !dragStartPositions.isEmpty {
                        for (id, startPos) in dragStartPositions {
                            if let index = midiData.events.firstIndex(where: { $0.id == id }),
                               case .note(var noteData) = midiData.events[index].type {
                                let newAbsoluteBeat = max(0, snapBeat(startPos.beat + beatDelta))
                                midiData.events[index].beatPosition = newAbsoluteBeat - clipStartBeat
                                noteData.pitch = UInt8(max(0, min(127, startPos.pitch + pitchDelta)))
                                midiData.events[index].type = .note(noteData)
                                modified = true
                            }
                        }
                    } else {
                        if let index = midiData.events.firstIndex(where: { $0.id == noteID }),
                           case .note(var noteData) = midiData.events[index].type {
                            let newAbsoluteBeat = max(0, snapBeat(dragStartBeat + beatDelta))
                            midiData.events[index].beatPosition = newAbsoluteBeat - clipStartBeat
                            noteData.pitch = UInt8(max(0, min(127, dragStartPitch + pitchDelta)))
                            midiData.events[index].type = .note(noteData)
                            modified = true
                        }
                    }
                    
                    if modified {
                        track.clips[clipIndex].content = .midi(midiData)
                    }
                }
            }
            viewModel.project.updateTrack(track)

        case .resizeStart, .resizeEnd:
            for clipIndex in 0..<track.clips.count {
                if case .midi(var midiData) = track.clips[clipIndex].content {
                    let clipStartBeat = track.clips[clipIndex].timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                    
                    if let index = midiData.events.firstIndex(where: { $0.id == noteID }),
                       case .note(var noteData) = midiData.events[index].type {
                        
                        if dragMode == .resizeEnd {
                            noteData.duration = max(minDuration, snapBeat(dragStartDuration + beatDelta))
                        } else {
                            let originalEnd = dragStartBeat + dragStartDuration
                            let newStart = snapBeat(dragStartBeat + beatDelta)
                            let newDuration = max(minDuration, originalEnd - newStart)
                            midiData.events[index].beatPosition = max(0, originalEnd - newDuration) - clipStartBeat
                            noteData.duration = newDuration
                        }
                        
                        midiData.events[index].type = .note(noteData)
                        track.clips[clipIndex].content = .midi(midiData)
                        viewModel.project.updateTrack(track)
                        return
                    }
                }
            }
            
        case .none:
            break
        }
    }
    
    private func endNoteDrag() {
        if draggedNoteID != nil {
            if let track = currentTrack {
                viewModel.updateTrack(track, description: "Edit MIDI")
            }
        }
        draggedNoteID = nil
        dragMode = .none
        dragStartPositions.removeAll()
        lastAuditionedPitch = nil
        isCopyingNotes = false
    }
    
    // MARK: - CC Operations
    
    private func addCCPoint(at beat: Double, value: UInt8) {
        guard var track = currentTrack else { return }
        
        if let clipIndex = track.clips.firstIndex(where: { $0.content.isMIDI }) {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                let clipStartBeat = track.clips[clipIndex].timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                let ccEvent = MIDIEvent.controlChange(at: beat - clipStartBeat, controller: UInt8(selectedCCType.rawValue), value: value)
                midiData.events.append(ccEvent)
                track.clips[clipIndex].content = .midi(midiData)
                viewModel.updateTrack(track, description: "Add CC")
            }
        }
    }
    
    private func updateCCPoint(_ id: UUID, value: UInt8) {
        guard var track = currentTrack else { return }
        
        for clipIndex in 0..<track.clips.count {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                if let index = midiData.events.firstIndex(where: { $0.id == id }) {
                    if case .controlChange(let controller, _) = midiData.events[index].type {
                        midiData.events[index].type = .controlChange(controller: controller, value: value)
                        track.clips[clipIndex].content = .midi(midiData)
                        viewModel.updateTrack(track, description: "Edit CC")
                        return
                    }
                }
            }
        }
    }
    
    // MARK: - Quantize & Offset
    
    private func quantizeSelectedNotes(to grid: QuantizeGrid) {
        guard var track = currentTrack else { return }
        guard !selectedNoteIDs.isEmpty else { return }
        
        let gridDivision = grid.division
        guard gridDivision > 0 else { return }
        
        for clipIndex in 0..<track.clips.count {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                let clipStartBeat = track.clips[clipIndex].timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                
                for i in 0..<midiData.events.count {
                    if selectedNoteIDs.contains(midiData.events[i].id) {
                        let absoluteBeat = clipStartBeat + midiData.events[i].beatPosition
                        let quantizedAbsolute = round(absoluteBeat / gridDivision) * gridDivision
                        midiData.events[i].beatPosition = quantizedAbsolute - clipStartBeat
                    }
                }
                
                track.clips[clipIndex].content = .midi(midiData)
            }
        }
        
        viewModel.updateTrack(track, description: "Quantize")
        showQuantizeDialog = false
    }
    
    private func applyOffset(milliseconds: Double) {
        guard var track = currentTrack else { return }
        guard !selectedNoteIDs.isEmpty else { return }

        let tempo = viewModel.transportState.tempo.bpm
        let beatOffset = (milliseconds / 1000.0) * (tempo / 60.0)

        for clipIndex in 0..<track.clips.count {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                for i in 0..<midiData.events.count {
                    if selectedNoteIDs.contains(midiData.events[i].id) {
                        midiData.events[i].beatPosition = max(0, midiData.events[i].beatPosition + beatOffset)
                    }
                }
                track.clips[clipIndex].content = .midi(midiData)
            }
        }

        viewModel.updateTrack(track, description: "Offset Notes")
    }
    
    // MARK: - Zoom Functions
    
    private func zoomHorizontal(zoomIn: Bool) {
        let zoomFactor = 1.25
        let minPixelsPerBeat: Double = 10
        let maxPixelsPerBeat: Double = 120  // Limited to prevent alignment issues
        
        if zoomIn {
            pixelsPerBeat = min(maxPixelsPerBeat, pixelsPerBeat * zoomFactor)
        } else {
            pixelsPerBeat = max(minPixelsPerBeat, pixelsPerBeat / zoomFactor)
        }
    }
    
    private func zoomVertical(zoomIn: Bool) {
        let zoomFactor: CGFloat = 1.25
        let minNoteHeight: CGFloat = 6
        let maxNoteHeight: CGFloat = 40
        
        if zoomIn {
            noteHeight = min(maxNoteHeight, noteHeight * zoomFactor)
        } else {
            noteHeight = max(minNoteHeight, noteHeight / zoomFactor)
        }
    }
}

// MARK: - Track Note View

struct TrackNoteView: View {
    let event: MIDIEvent
    let noteData: NoteData
    let isSelected: Bool
    let pixelsPerBeat: Double
    let noteHeight: CGFloat
    let pitchOffset: Int
    let noteColor: Color
    let onSelect: () -> Void
    let onDragStart: (NoteDragMode) -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void

    @State private var isDragging: Bool = false
    @State private var currentDragMode: NoteDragMode = .none
    @State private var hoverPosition: CGFloat = 0
    @State private var isHovering: Bool = false

    private let resizeHandleWidth: CGFloat = 6

    var body: some View {
        let x = CGFloat(event.beatPosition) * pixelsPerBeat
        let y = CGFloat(pitchOffset - Int(noteData.pitch)) * noteHeight
        let width = max(4, CGFloat(noteData.duration) * pixelsPerBeat)

        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(noteColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(Double(noteData.velocity) / 127 * 0.3))

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
        .offset(x: x, y: y + 1)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                isHovering = true
                hoverPosition = location.x
                updateCursor(at: location.x, width: width)
            case .ended:
                isHovering = false
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
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
                    if isHovering {
                        updateCursor(at: hoverPosition, width: width)
                    }
                }
        )
        .onTapGesture {
            onSelect()
        }
    }
    
    private func updateCursor(at localX: CGFloat, width: CGFloat) {
        if isSelected {
            if localX < resizeHandleWidth {
                NSCursor.resizeLeftRight.set()
            } else if localX > width - resizeHandleWidth {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }
}
