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
        case .select: return "arrow.up.left.and.arrow.down.right"
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
    
    // Editing state
    @State private var draggedNoteID: UUID? = nil
    @State private var dragMode: NoteDragMode = .none
    @State private var dragStartBeat: Double = 0
    @State private var dragStartPitch: Int = 0
    
    // View state
    @State private var pixelsPerBeat: Double = 60
    @State private var noteHeight: CGFloat = 14
    @State private var scrollOffset: CGPoint = .zero
    @State private var visibleOctaveRange: ClosedRange<Int> = 2...7
    
    // Copied notes for paste
    @State private var copiedNotes: [MIDIEvent] = []
    
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
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            setupInitialView()
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
            
            // Quantize
            Button(action: quantizeSelectedNotes) {
                Image(systemName: "waveform.path.ecg")
            }
            .buttonStyle(.plain)
            .help("Quantize Selection")
            
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
    
    // MARK: - Note Editing Area
    
    private func noteEditingArea(geometry: GeometryProxy) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                // Background grid
                noteGrid(geometry: geometry)
                
                // Notes
                notesLayer
                
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
                    onSelect: { selectNote(event.id) },
                    onDragStart: { mode in startNoteDrag(event, mode: mode) },
                    onDrag: { delta in handleNoteDrag(delta) },
                    onDragEnd: { endNoteDrag() }
                )
            }
        }
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
                        
                        // Velocity bars
                        ForEach(noteEvents, id: \.id) { event in
                            if case .note(let noteData) = event.type {
                                VelocityBar(
                                    beat: event.beatPosition,
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
                    // Draw new note on release
                    break
                    
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
                    let pitch = pitchAt(value.startLocation.y)
                    let startBeat = snapBeat(value.startLocation.x / pixelsPerBeat)
                    let endBeat = snapBeat(value.location.x / pixelsPerBeat)
                    let duration = max(snapMode.division > 0 ? snapMode.division : 0.25, abs(endBeat - startBeat))
                    createNote(at: startBeat, pitch: pitch, duration: duration)
                    
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
    
    private func createNote(at beat: Double, pitch: Int, duration: Double, velocity: UInt8 = 100) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        
        let newEvent = MIDIEvent.note(
            at: beat,
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
    
    private func eraseNoteAt(beat: Double, pitch: Int) {
        guard var clip = currentClip, case .midi(var midiData) = clip.content else { return }
        
        midiData.events.removeAll { event in
            if case .note(let noteData) = event.type {
                let noteStart = event.beatPosition
                let noteEnd = noteStart + noteData.duration
                return Int(noteData.pitch) == pitch && beat >= noteStart && beat <= noteEnd
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
    
    private func quantizeSelectedNotes() {
        guard var clip = currentClip, case .midi(var midiData) = clip.content, snapMode != .off else { return }
        
        for i in 0..<midiData.events.count {
            if selectedNoteIDs.contains(midiData.events[i].id) {
                midiData.events[i].beatPosition = snapBeat(midiData.events[i].beatPosition)
            }
        }
        
        clip.content = .midi(midiData)
        updateClip(clip)
    }
    
    // MARK: - Note Dragging
    
    private func startNoteDrag(_ event: MIDIEvent, mode: NoteDragMode) {
        draggedNoteID = event.id
        dragMode = mode
        dragStartBeat = event.beatPosition
        if case .note(let noteData) = event.type {
            dragStartPitch = Int(noteData.pitch)
        }
    }
    
    private func handleNoteDrag(_ delta: CGSize) {
        guard let noteID = draggedNoteID,
              var clip = currentClip,
              case .midi(var midiData) = clip.content,
              let index = midiData.events.firstIndex(where: { $0.id == noteID }),
              case .note(var noteData) = midiData.events[index].type
        else { return }
        
        let beatDelta = delta.width / pixelsPerBeat
        let pitchDelta = -Int(delta.height / noteHeight)
        
        switch dragMode {
        case .move:
            midiData.events[index].beatPosition = snapBeat(dragStartBeat + beatDelta)
            noteData.pitch = UInt8(max(0, min(127, dragStartPitch + pitchDelta)))
            
        case .resizeStart:
            let newStart = snapBeat(dragStartBeat + beatDelta)
            let originalEnd = dragStartBeat + noteData.duration
            noteData.duration = max(snapMode.division > 0 ? snapMode.division : 0.1, originalEnd - newStart)
            midiData.events[index].beatPosition = newStart
            
        case .resizeEnd:
            noteData.duration = max(snapMode.division > 0 ? snapMode.division : 0.1, snapBeat(noteData.duration + beatDelta))
            
        case .none:
            break
        }
        
        midiData.events[index].type = .note(noteData)
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
        let clipBeats = clip.timeRange.duration.beats(atTempo: viewModel.transportState.tempo.bpm)
        return max(800, CGFloat(clipBeats + 4) * pixelsPerBeat)
    }
    
    private var pitchOffset: Int {
        visibleOctaveRange.upperBound * 12 + 11
    }
    
    private var playheadX: CGFloat {
        guard let clip = currentClip else { return 0 }
        let clipStartBeat = clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
        let currentBeat = viewModel.transportState.playheadBeats
        return CGFloat(currentBeat - clipStartBeat) * pixelsPerBeat
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
        let x = CGFloat(event.beatPosition) * pixelsPerBeat
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
    let onSelect: () -> Void
    let onDragStart: (NoteDragMode) -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void
    
    @State private var dragOffset: CGSize = .zero
    
    private let resizeHandleWidth: CGFloat = 6
    
    var body: some View {
        let x = CGFloat(event.beatPosition) * pixelsPerBeat
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
        .offset(x: x + dragOffset.width, y: y + dragOffset.height + 1)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Determine drag mode based on where the drag started
                    let localX = value.startLocation.x
                    if localX < resizeHandleWidth && isSelected {
                        onDragStart(.resizeStart)
                    } else if localX > width - resizeHandleWidth && isSelected {
                        onDragStart(.resizeEnd)
                    } else {
                        onDragStart(.move)
                    }
                    dragOffset = value.translation
                    onDrag(value.translation)
                }
                .onEnded { _ in
                    dragOffset = .zero
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
