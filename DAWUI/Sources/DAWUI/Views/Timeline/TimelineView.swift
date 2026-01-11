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
                ClipView(
                    clip: clip,
                    track: track,
                    viewModel: viewModel,
                    height: height - 6,
                    onDoubleClick: { onDoubleClick?(clip) }
                )
                .offset(x: clipX(for: clip), y: 3)
                .frame(width: clipWidth(for: clip))
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
    var onDoubleClick: (() -> Void)? = nil
    
    @State private var isDragging = false
    @State private var dragOffset: CGSize = .zero
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Clip background
            RoundedRectangle(cornerRadius: 4)
                .fill(clipColor.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? Color.accentColor : clipColor, lineWidth: isSelected ? 2 : 1)
                )
            
            // Clip content
            VStack(alignment: .leading, spacing: 2) {
                // Clip name
                Text(clip.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                
                // Content preview
                clipContentPreview
                    .padding(.horizontal, 2)
            }
            
            // Muted overlay
            if clip.isMuted {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.5))
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation
                }
                .onEnded { value in
                    isDragging = false
                    dragOffset = .zero
                }
        )
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
    }
    
    private var clipColor: Color {
        Color(hex: (clip.color ?? track.color).hex) ?? .blue
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
                color: clipColor
            )
            .frame(maxHeight: height - 24)
            
        case .midi(let midiData):
            MIDINotePreview(events: midiData.noteEvents)
                .frame(maxHeight: height - 24)
        }
    }
}


// MARK: - MIDI Note Preview

struct MIDINotePreview: View {
    let events: [MIDIEvent]
    
    var body: some View {
        GeometryReader { geometry in
            let noteRange = noteRange
            let rangeSize = max(1, Int(noteRange.upperBound) - Int(noteRange.lowerBound) + 1)
            let noteHeight = max(2, geometry.size.height / CGFloat(rangeSize))
            
            ForEach(noteEvents, id: \.id) { event in
                if case .note(let noteData) = event.type {
                    let y = yPosition(for: noteData.pitch, in: geometry.size.height, range: noteRange)
                    let x = event.beatPosition * 10
                    let width = noteData.duration * 10
                    
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: max(2, width), height: max(2, noteHeight - 1))
                        .offset(x: x, y: y)
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
        
        return minNote...maxNote
    }
    
    private func yPosition(for pitch: UInt8, in height: CGFloat, range: ClosedRange<UInt8>) -> CGFloat {
        let rangeSize = CGFloat(range.upperBound - range.lowerBound) + 1
        let normalized = CGFloat(range.upperBound - pitch) / rangeSize
        return normalized * height
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
