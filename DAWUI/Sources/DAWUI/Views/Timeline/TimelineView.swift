import SwiftUI
import DAWCore

// MARK: - Timeline Grid View

struct TimelineGridView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackHeight: CGFloat
    let trackCount: Int
    
    var body: some View {
        Canvas { context, size in
            let pixelsPerBeat = viewModel.pixelsPerBeat
            let timeSignature = viewModel.transportState.timeSignature
            let totalBeats = Int(size.width / pixelsPerBeat) + 1
            
            // Horizontal track divider lines
            for i in 0...trackCount {
                let y = CGFloat(i) * trackHeight
                let linePath = Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(linePath, with: .color(Color.gray.opacity(0.3)), lineWidth: 1)
            }
            
            // Vertical beat lines
            for beat in 0..<totalBeats {
                let x = CGFloat(beat) * pixelsPerBeat
                let isBar = beat % timeSignature.beatsPerBar == 0
                
                let linePath = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                
                context.stroke(
                    linePath,
                    with: .color(isBar ? Color.gray.opacity(0.4) : Color.gray.opacity(0.15)),
                    lineWidth: isBar ? 1 : 0.5
                )
            }
        }
        .frame(height: CGFloat(trackCount) * trackHeight)
    }
}

// MARK: - Timeline Track Row

struct TimelineTrackRow: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    let height: CGFloat
    var onDoubleClick: ((Clip) -> Void)? = nil
    
    var body: some View {
        ZStack(alignment: .leading) {
            // Track background
            Rectangle()
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            
            // Clips
            ForEach(track.clips) { clip in
                let width = clipWidth(for: clip)
                ClipView(
                    clip: clip,
                    track: track,
                    viewModel: viewModel,
                    height: height - 6,
                    clipWidth: width,
                    onDoubleClick: { onDoubleClick?(clip) }
                )
                .offset(x: clipX(for: clip), y: 3)
                .frame(width: width)
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectTrack(track.id)
        }
        .contextMenu {
            if track.type == .midi || track.type == .instrument {
                Button("Create MIDI Clip") {
                    viewModel.createMIDIClip(on: track.id, at: TimePosition(), duration: 4.0)
                }
            }
        }
    }
    
    private var isSelected: Bool {
        viewModel.selectedTrackID == track.id
    }
    
    private func clipX(for clip: Clip) -> CGFloat {
        clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm) * viewModel.pixelsPerBeat
    }
    
    private func clipWidth(for clip: Clip) -> CGFloat {
        max(20, clip.timeRange.duration.beats(atTempo: viewModel.transportState.tempo.bpm) * viewModel.pixelsPerBeat)
    }
}

// MARK: - Clip View

struct ClipView: View {
    let clip: Clip
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    let height: CGFloat
    let clipWidth: CGFloat  // Added: actual width of the clip in pixels
    var onDoubleClick: (() -> Void)? = nil
    
    @State private var isDragging = false
    @State private var dragOffset: CGSize = .zero
    @State private var isCopying = false  // Option key held during drag
    
    private var isMIDIClip: Bool {
        if case .midi = clip.content { return true }
        return false
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Clip background - NO border for MIDI, filled for audio
            if !isMIDIClip {
                // Audio clips: filled background with border
                RoundedRectangle(cornerRadius: 4)
                    .fill(clipColor.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isSelected ? Color.accentColor : clipColor, lineWidth: isSelected ? 2 : 1)
                    )
            }
            
            // Clip content
            if isMIDIClip {
                // MIDI: just the notes, no border, no padding, no label
                clipContentPreview
            } else {
                // Audio: name + waveform
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                    
                    clipContentPreview
                        .padding(.horizontal, 2)
                }
            }
            
            // Muted overlay (audio only)
            if clip.isMuted && !isMIDIClip {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.5))
            }
            
            // Copy indicator when Option+dragging
            if isDragging && isCopying {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                            .padding(4)
                    }
                }
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .gesture(clipDragGesture)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    if case .midi = clip.content {
                        viewModel.openPianoRoll(for: clip.id)
                    }
                    onDoubleClick?()
                }
        )
        .simultaneousGesture(
            TapGesture(count: 1)
                .onEnded {
                    viewModel.selectClip(clip.id)
                }
        )
        .offset(dragOffset)
        .opacity(isDragging && isCopying ? 0.7 : 1.0)
    }
    
    // MARK: - Drag Gesture
    
    private var clipDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                isDragging = true
                // Direct assignment for smooth, immediate visual feedback
                dragOffset = CGSize(width: value.translation.width, height: 0)
                
                // Check for Option key (copy mode)
                isCopying = NSEvent.modifierFlags.contains(.option)
            }
            .onEnded { value in
                guard isDragging else { return }
                
                // Calculate new beat position
                let dragBeats = value.translation.width / viewModel.pixelsPerBeat
                let currentBeat = clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                var newBeat = currentBeat + dragBeats
                
                // Snap to grid unless Cmd is held
                let snapToGrid = !NSEvent.modifierFlags.contains(.command)
                if snapToGrid {
                    let snapResolution = 1.0  // 1 beat grid
                    newBeat = round(newBeat / snapResolution) * snapResolution
                }
                
                // Clamp to valid range
                newBeat = max(0, newBeat)
                
                // Reset visual state first
                isDragging = false
                dragOffset = .zero
                
                // Only move if position actually changed
                if abs(newBeat - currentBeat) > 0.01 {
                    if isCopying {
                        // Option+drag: duplicate the clip at new position
                        viewModel.duplicateClip(clip.id, on: track.id, toBeat: newBeat)
                    } else {
                        // Regular drag: move the clip
                        viewModel.moveClip(clip.id, on: track.id, toBeat: newBeat)
                    }
                }
                
                isCopying = false
            }
    }
    
    private var clipColor: Color {
        // Get current track from project to ensure color updates dynamically
        let currentTrack = viewModel.project.track(withID: track.id) ?? track
        return Color(hex: (clip.color ?? currentTrack.color).hex) ?? .blue
    }
    
    private var isSelected: Bool {
        viewModel.selectedClipIDs.contains(clip.id)
    }
    
    @ViewBuilder
    private var clipContentPreview: some View {
        switch clip.content {
        case .audio(let audioData):
            AudioWaveformView(
                audioFilePath: audioData.fileReference.originalPath,
                color: clipColor,
                sourceStartSample: audioData.sourceStartSample,
                sourceLengthSamples: audioData.sourceLengthSamples
            )
            .frame(maxHeight: height - 24)
            
        case .midi(let midiData):
            // Pass clip duration in beats and the pixel width for accurate positioning
            let clipDurationBeats = clip.timeRange.duration.beats(atTempo: viewModel.transportState.tempo.bpm)
            MIDINotePreview(
                events: midiData.noteEvents,
                clipDurationBeats: clipDurationBeats,
                clipWidth: clipWidth,
                noteColor: clipColor
            )
            .frame(height: height)
            
        case .empty:
            // Empty placeholder clip
            EmptyView()
        }
    }
}


// MARK: - MIDI Note Preview

struct MIDINotePreview: View {
    let events: [MIDIEvent]
    let clipDurationBeats: Double
    let clipWidth: CGFloat
    let noteColor: Color  // Track color for notes

    var body: some View {
        GeometryReader { geometry in
            let noteRange = noteRange
            let rangeSize = max(1, Int(noteRange.upperBound) - Int(noteRange.lowerBound) + 1)
            let noteHeight = max(2, (geometry.size.height - 4) / CGFloat(rangeSize))
            
            // Calculate pixels per beat based on clip width and duration
            let pixelsPerBeat = clipDurationBeats > 0 ? clipWidth / CGFloat(clipDurationBeats) : 20
            
            ForEach(noteEvents, id: \.id) { event in
                if case .note(let noteData) = event.type {
                    let y = yPosition(for: noteData.pitch, in: geometry.size.height - 4, range: noteRange)
                    let x = CGFloat(event.beatPosition) * pixelsPerBeat
                    let width = CGFloat(noteData.duration) * pixelsPerBeat
                    
                    RoundedRectangle(cornerRadius: 1)
                        .fill(velocityAdjustedColor(velocity: noteData.velocity))
                        .frame(width: max(2, width), height: max(2, noteHeight - 1))
                        .offset(x: x, y: y + 2)
                }
            }
        }
    }
    
    private var noteEvents: [MIDIEvent] {
        events.filter { if case .note = $0.type { return true } else { return false } }
    }
    
    private var noteRange: ClosedRange<UInt8> {
        var minNote: UInt8 = 127
        var maxNote: UInt8 = 0
        
        for event in events {
            if case .note(let noteData) = event.type {
                minNote = min(minNote, noteData.pitch)
                maxNote = max(maxNote, noteData.pitch)
            }
        }
        
        if minNote > maxNote {
            return 60...72
        }
        
        // Add a little padding around the note range
        let padding: UInt8 = 2
        let paddedMin = minNote > padding ? minNote - padding : 0
        let paddedMax = maxNote < (127 - padding) ? maxNote + padding : 127
        
        return paddedMin...paddedMax
    }
    
    private func yPosition(for pitch: UInt8, in height: CGFloat, range: ClosedRange<UInt8>) -> CGFloat {
        let rangeSize = CGFloat(range.upperBound - range.lowerBound) + 1
        let normalized = CGFloat(range.upperBound - pitch) / rangeSize
        return normalized * height
    }
    
    private func velocityAdjustedColor(velocity: UInt8) -> Color {
        // Vary color intensity based on velocity
        let intensity = Double(velocity) / 127.0
        return noteColor.opacity(0.6 + intensity * 0.4)
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
}
