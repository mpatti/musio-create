import SwiftUI
import DAWCore

// MARK: - Track Header View

struct TrackHeaderView: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    var onCreateClip: (() -> Void)? = nil
    
    @State private var isEditing = false
    @State private var editedName = ""
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Track color indicator
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: track.color.hex) ?? .blue)
                    .frame(width: 4, height: 60)
                
                VStack(alignment: .leading, spacing: 4) {
                    // Track name
                    if isEditing {
                        TextField("Track Name", text: $editedName, onCommit: {
                            commitNameEdit()
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                    } else {
                        Text(track.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                startEditing()
                            }
                    }
                    
                    // Track type icon
                    HStack(spacing: 2) {
                        Image(systemName: trackTypeIcon)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        Text(track.type.rawValue.capitalized)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    
                    // Controls
                    HStack(spacing: 4) {
                        // Record arm
                        Button(action: { toggleArmed() }) {
                            Image(systemName: track.isArmed ? "record.circle.fill" : "record.circle")
                                .font(.system(size: 11))
                                .foregroundColor(track.isArmed ? .red : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(track.isArmed ? "Disarm Track" : "Arm Track for Recording")
                        
                        // Mute
                        Button(action: { viewModel.toggleTrackMute(id: track.id) }) {
                            Text("M")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(track.isMuted ? .orange : .secondary)
                        }
                        .buttonStyle(.plain)
                        
                        // Solo
                        Button(action: { viewModel.toggleTrackSolo(id: track.id) }) {
                            Text("S")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(track.isSolo ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                        
                        // Volume meter - shows signal only when playing
                        TrackMiniMeter(isPlaying: viewModel.transportState.isPlaying)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            
            Divider()
        }
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectTrack(track.id)
        }
        .contextMenu {
            Button("Rename") { startEditing() }
            Button("Duplicate") { duplicateTrack() }
            
            Divider()
            
            if track.type == .midi || track.type == .instrument {
                Button("Create MIDI Clip") {
                    viewModel.createMIDIClip(on: track.id, at: TimePosition(), duration: 4.0)
                }
            } else if track.type == .audio {
                Button("Create Audio Clip...") {
                    onCreateClip?()
                }
            }
            
            Divider()
            
            Button("Delete", role: .destructive) {
                viewModel.deleteTrack(id: track.id)
            }
        }
    }
    
    private var isSelected: Bool {
        viewModel.selectedTrackID == track.id
    }
    
    private var trackTypeIcon: String {
        switch track.type {
        case .audio: return "waveform"
        case .midi: return "pianokeys"
        case .instrument: return "pianokeys.inverse"
        case .bus: return "arrow.triangle.merge"
        case .master: return "speaker.wave.3"
        }
    }
    
    private func startEditing() {
        editedName = track.name
        isEditing = true
    }
    
    private func commitNameEdit() {
        isEditing = false
        if !editedName.isEmpty && editedName != track.name {
            var updatedTrack = track
            updatedTrack.name = editedName
            viewModel.updateTrack(updatedTrack, description: "Rename Track")
        }
    }
    
    private func toggleArmed() {
        var updatedTrack = track
        updatedTrack.isArmed.toggle()
        viewModel.updateTrack(updatedTrack, description: updatedTrack.isArmed ? "Arm Track" : "Disarm Track")
    }
    
    private func duplicateTrack() {
        var newTrack = track
        newTrack.id = TrackID()
        newTrack.name = "\(track.name) Copy"
        viewModel.addTrack(type: track.type, name: newTrack.name)
    }
}

// MARK: - Track Mini Meter

struct TrackMiniMeter: View {
    let isPlaying: Bool
    
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<6, id: \.self) { i in
                Rectangle()
                    .fill(meterColor(for: i, isPlaying: isPlaying))
                    .frame(width: 3, height: CGFloat(6 + i * 2))
            }
        }
    }
    
    private func meterColor(for index: Int, isPlaying: Bool) -> Color {
        // Show empty (dim) meters when not playing
        guard isPlaying else {
            return Color.gray.opacity(0.2)
        }
        
        // When playing, show signal level colors
        if index < 4 {
            return .green.opacity(0.8)
        } else if index < 5 {
            return .yellow.opacity(0.8)
        } else {
            return .red.opacity(0.4)
        }
    }
}

// MARK: - Track Controls View

struct TrackControlsView: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    
    var body: some View {
        VStack(spacing: 8) {
            // Volume fader
            VStack(spacing: 2) {
                Text(volumeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Slider(
                    value: Binding(
                        get: { Double(track.volume) },
                        set: { viewModel.setTrackVolume(id: track.id, volume: Float($0)) }
                    ),
                    in: 0...1
                )
                .frame(width: 60)
            }
            
            // Pan knob (simplified as slider)
            VStack(spacing: 2) {
                Text(panText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Slider(
                    value: Binding(
                        get: { Double(track.pan) },
                        set: { viewModel.setTrackPan(id: track.id, pan: Float($0)) }
                    ),
                    in: -1...1
                )
                .frame(width: 60)
            }
        }
    }
    
    private var volumeText: String {
        let db = 20 * log10(track.volume)
        if db == -.infinity { return "-∞ dB" }
        return String(format: "%.1f dB", db)
    }
    
    private var panText: String {
        if abs(track.pan) < 0.01 { return "C" }
        if track.pan < 0 { return String(format: "%.0fL", -track.pan * 100) }
        return String(format: "%.0fR", track.pan * 100)
    }
}
