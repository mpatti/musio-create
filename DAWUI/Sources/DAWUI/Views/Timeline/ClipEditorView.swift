import SwiftUI
import DAWCore

// MARK: - Clip Editor View

/// Detailed editor for clip properties
public struct ClipEditorView: View {
    @Binding var clip: Clip
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    
    @State private var clipName: String = ""
    @State private var showColorPicker = false
    
    public init(clip: Binding<Clip>, viewModel: ProjectViewModel, trackID: TrackID) {
        self._clip = clip
        self.viewModel = viewModel
        self.trackID = trackID
        self._clipName = State(initialValue: clip.wrappedValue.name)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Clip Editor")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("Clip Name", text: $clipName, onCommit: updateName)
                    .textFieldStyle(.roundedBorder)
            }
            
            // Position and Duration
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(formatPosition(clip.timeRange.start))
                        .font(.body.monospaced())
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duration")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(formatPosition(clip.timeRange.duration))
                        .font(.body.monospaced())
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("End")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(formatPosition(clip.timeRange.end))
                        .font(.body.monospaced())
                }
            }
            
            Divider()
            
            // Gain
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Gain")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(formatGain(clip.gain))
                        .font(.caption.monospaced())
                }
                
                Slider(
                    value: Binding(
                        get: { Double(clip.gain) },
                        set: { clip.gain = Float($0) }
                    ),
                    in: 0...2
                )
            }
            
            // Fades
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fade In")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text(formatSamples(clip.fadeInDuration))
                            .font(.caption.monospaced())
                        Stepper("", 
                            onIncrement: { clip.fadeInDuration += Int64(viewModel.project.sampleRate / 100) },
                            onDecrement: { clip.fadeInDuration = max(0, clip.fadeInDuration - Int64(viewModel.project.sampleRate / 100)) }
                        )
                        .labelsHidden()
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fade Out")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text(formatSamples(clip.fadeOutDuration))
                            .font(.caption.monospaced())
                        Stepper("",
                            onIncrement: { clip.fadeOutDuration += Int64(viewModel.project.sampleRate / 100) },
                            onDecrement: { clip.fadeOutDuration = max(0, clip.fadeOutDuration - Int64(viewModel.project.sampleRate / 100)) }
                        )
                        .labelsHidden()
                    }
                }
            }
            
            // Fade curves
            HStack(spacing: 16) {
                Picker("Fade In Curve", selection: $clip.fadeInCurve) {
                    ForEach(FadeCurve.allCases, id: \.self) { curve in
                        Text(curve.rawValue.capitalized).tag(curve)
                    }
                }
                .frame(width: 100)
                
                Picker("Fade Out Curve", selection: $clip.fadeOutCurve) {
                    ForEach(FadeCurve.allCases, id: \.self) { curve in
                        Text(curve.rawValue.capitalized).tag(curve)
                    }
                }
                .frame(width: 100)
            }
            
            Divider()
            
            // Looping
            Toggle("Loop", isOn: $clip.isLooped)
            
            if clip.isLooped {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loop Length (beats)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Loop length input would go here
                }
            }
            
            Divider()
            
            // Color
            VStack(alignment: .leading, spacing: 4) {
                Text("Color")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 4) {
                    // Inherit from track
                    Button(action: { clip.color = nil }) {
                        Text("Track")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(clip.color == nil ? Color.accentColor : Color.gray.opacity(0.3))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    
                    ForEach(TrackColor.allCases, id: \.self) { color in
                        Circle()
                            .fill(Color(hex: color.hex) ?? .gray)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: clip.color == color ? 2 : 0)
                            )
                            .onTapGesture {
                                clip.color = color
                            }
                    }
                }
            }
            
            Divider()
            
            // Actions
            HStack(spacing: 12) {
                Button(action: duplicateClip) {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                
                Button(action: splitClip) {
                    Label("Split", systemImage: "scissors")
                }
                
                Button(role: .destructive, action: deleteClip) {
                    Label("Delete", systemImage: "trash")
                }
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 300)
        .onAppear {
            clipName = clip.name
        }
    }
    
    // MARK: - Formatting
    
    private func formatPosition(_ position: TimePosition) -> String {
        position.formatted(atTempo: viewModel.transportState.tempo.bpm, timeSignature: viewModel.transportState.timeSignature)
    }
    
    private func formatGain(_ gain: Float) -> String {
        let db = 20 * log10(gain)
        if db == -.infinity { return "-∞ dB" }
        return String(format: "%+.1f dB", db)
    }
    
    private func formatSamples(_ samples: Int64) -> String {
        let ms = Double(samples) / viewModel.project.sampleRate * 1000
        return String(format: "%.0f ms", ms)
    }
    
    // MARK: - Actions
    
    private func updateName() {
        guard !clipName.isEmpty, clipName != clip.name else { return }
        clip.name = clipName
    }
    
    private func duplicateClip() {
        var newClip = clip
        newClip.id = ClipID()
        newClip.name = "\(clip.name) Copy"
        // Offset position slightly
        let offsetBeats = clip.timeRange.duration.beats(atTempo: viewModel.transportState.tempo.bpm)
        newClip.timeRange = TimeRange(
            start: clip.timeRange.end,
            duration: clip.timeRange.duration
        )
        viewModel.addClip(newClip, to: trackID)
    }
    
    private func splitClip() {
        // Split at current playhead position
        let playheadBeat = viewModel.transportState.playheadBeats
        let clipStartBeat = clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
        let clipEndBeat = clip.timeRange.end.beats(atTempo: viewModel.transportState.tempo.bpm)
        
        guard playheadBeat > clipStartBeat && playheadBeat < clipEndBeat else { return }
        
        // Create two clips from the split
        // This would need proper implementation through the undo system
    }
    
    private func deleteClip() {
        viewModel.deleteClip(id: clip.id, from: trackID)
    }
}

// MARK: - Create Clip Dialog

public struct CreateClipDialog: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    let position: TimePosition
    @Binding var isPresented: Bool
    
    @State private var clipName = "New Clip"
    @State private var durationBeats: Double = 4.0
    @State private var clipType: ClipContentType = .midi
    
    public var body: some View {
        VStack(spacing: 16) {
            Text("Create Clip")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("Clip Name", text: $clipName)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Duration (beats)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Stepper(value: $durationBeats, in: 0.25...64, step: 0.25) {
                    Text(String(format: "%.2f", durationBeats))
                }
            }
            
            Picker("Type", selection: $clipType) {
                Text("MIDI").tag(ClipContentType.midi)
                Text("Audio").tag(ClipContentType.audio)
            }
            .pickerStyle(.segmented)
            
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Create") {
                    createClip()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }
    
    private func createClip() {
        let tempo = viewModel.transportState.tempo.bpm
        let sampleRate = viewModel.project.sampleRate
        
        let duration = TimePosition(beats: durationBeats, tempo: tempo, sampleRate: sampleRate)
        
        let content: ClipContent
        switch clipType {
        case .midi:
            content = .midi(MIDIClipData())
        case .audio:
            // Audio clips would need a file reference
            content = .midi(MIDIClipData())  // Fallback for now
        }
        
        let clip = Clip(
            name: clipName,
            timeRange: TimeRange(start: position, duration: duration),
            content: content
        )
        
        viewModel.addClip(clip, to: trackID)
    }
}

enum ClipContentType {
    case midi
    case audio
}

// MARK: - Clip Context Menu

struct ClipContextMenuModifier: ViewModifier {
    let clip: Clip
    let trackID: TrackID
    @ObservedObject var viewModel: ProjectViewModel
    
    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Rename") {
                // Would need to trigger rename UI
            }
            
            Button("Duplicate") {
                duplicateClip()
            }
            
            Button("Split at Playhead") {
                // Split functionality
            }
            
            Divider()
            
            Button("Mute") {
                toggleMute()
            }
            
            Divider()
            
            Menu("Color") {
                Button("Use Track Color") {
                    updateClipColor(nil)
                }
                
                Divider()
                
                ForEach(TrackColor.allCases, id: \.self) { color in
                    Button(color.rawValue.capitalized) {
                        updateClipColor(color)
                    }
                }
            }
            
            Divider()
            
            Button("Delete", role: .destructive) {
                viewModel.deleteClip(id: clip.id, from: trackID)
            }
        }
    }
    
    private func duplicateClip() {
        var newClip = clip
        newClip.id = ClipID()
        newClip.name = "\(clip.name) Copy"
        newClip.timeRange = TimeRange(
            start: clip.timeRange.end,
            duration: clip.timeRange.duration
        )
        viewModel.addClip(newClip, to: trackID)
    }
    
    private func toggleMute() {
        guard var track = viewModel.project.track(withID: trackID),
              let clipIndex = track.clips.firstIndex(where: { $0.id == clip.id }) else {
            return
        }
        track.clips[clipIndex].isMuted.toggle()
        viewModel.updateTrack(track, description: track.clips[clipIndex].isMuted ? "Mute Clip" : "Unmute Clip")
    }
    
    private func updateClipColor(_ color: TrackColor?) {
        guard var track = viewModel.project.track(withID: trackID),
              let clipIndex = track.clips.firstIndex(where: { $0.id == clip.id }) else {
            return
        }
        track.clips[clipIndex].color = color
        viewModel.updateTrack(track, description: "Change Clip Color")
    }
}

extension View {
    func clipContextMenu(clip: Clip, trackID: TrackID, viewModel: ProjectViewModel) -> some View {
        modifier(ClipContextMenuModifier(clip: clip, trackID: trackID, viewModel: viewModel))
    }
}

// MARK: - Drag and Drop Support

struct ClipDragData: Transferable, Codable {
    let clipID: UUID
    let trackID: UUID
    let originalBeat: Double
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: ClipDragData.self, contentType: .data)
    }
}
