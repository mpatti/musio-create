import SwiftUI
import DAWCore

// MARK: - Transport View

/// Transport control bar with play/stop, tempo, time display
public struct TransportView: View {
    @ObservedObject var viewModel: ProjectViewModel
    
    @State private var isEditingTempo = false
    @State private var tempoText = ""
    
    // Local state for real-time updates
    @State private var currentBeats: Double = 0
    @State private var currentSeconds: Double = 0
    
    public init(viewModel: ProjectViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        HStack(spacing: 16) {
            // Return to zero
            Button(action: { viewModel.transportState.returnToZero() }) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Return to Zero")
            
            // Rewind
            Button(action: {}) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Rewind")
            
            // Play/Pause (no separate Stop button - modern DAW style)
            Button(action: { viewModel.togglePlayPause() }) {
                Image(systemName: viewModel.transportState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(viewModel.transportState.isPlaying ? "Pause" : "Play")
            
            // Record
            Button(action: {
                if viewModel.isRecording {
                    viewModel.stopRecording()
                } else {
                    viewModel.startRecording()
                }
            }) {
                Image(systemName: "record.circle")
                    .font(.system(size: 16))
                    .foregroundColor(viewModel.isRecording ? .red : .primary)
                    .symbolEffect(.pulse, isActive: viewModel.isRecording)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(viewModel.isRecording ? "Stop Recording" : "Record")
            
            // Fast forward
            Button(action: {}) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Fast Forward")
            
            Divider()
                .frame(height: 24)
            
            // Position display - BARS | BEATS | TIME
            HStack(spacing: 8) {
                // Bars.Beats.Ticks display
                VStack(spacing: 1) {
                    Text("BARS")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(barsDisplay)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(minWidth: 80)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.4))
                .cornerRadius(4)
                
                // Time display (MM:SS:FF)
                VStack(spacing: 1) {
                    Text("TIME")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(timeDisplay)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(minWidth: 90)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.4))
                .cornerRadius(4)
            }
            
            Divider()
                .frame(height: 24)
            
            // Tempo control with +/- buttons
            HStack(spacing: 4) {
                Button(action: { viewModel.transportState.nudgeTempo(by: -1) }) {
                    Image(systemName: "minus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Decrease tempo")
                
                VStack(spacing: 1) {
                    Text("BPM")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    if isEditingTempo {
                        TextField("", text: $tempoText, onCommit: commitTempo)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .frame(width: 55)
                            .multilineTextAlignment(.center)
                            .onAppear { tempoText = String(format: "%.1f", viewModel.transportState.tempo.bpm) }
                    } else {
                        Text(String(format: "%.1f", viewModel.transportState.tempo.bpm))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
                            .onTapGesture(count: 2) {
                                tempoText = String(format: "%.1f", viewModel.transportState.tempo.bpm)
                                isEditingTempo = true
                            }
                    }
                }
                .frame(width: 55)
                .padding(.horizontal, 4)
                .background(Color.black.opacity(0.3))
                .cornerRadius(4)
                
                Button(action: { viewModel.transportState.nudgeTempo(by: 1) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Increase tempo")
            }
            
            // Time signature
            VStack(spacing: 1) {
                Text("SIG")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(.secondary)
                
                Text("\(viewModel.transportState.timeSignature.numerator)/\(viewModel.transportState.timeSignature.denominator)")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
            .frame(width: 35)
            .padding(.horizontal, 4)
            .background(Color.black.opacity(0.3))
            .cornerRadius(4)
            
            Divider()
                .frame(height: 24)
            
            // Loop toggle
            Button(action: { viewModel.transportState.toggleLoop() }) {
                Image(systemName: "repeat")
                    .font(.system(size: 14))
                    .foregroundColor(viewModel.transportState.isLoopEnabled ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Loop")
            
            // Metronome toggle
            Button(action: { viewModel.transportState.isMetronomeEnabled.toggle() }) {
                Image(systemName: "metronome")
                    .font(.system(size: 14))
                    .foregroundColor(viewModel.transportState.isMetronomeEnabled ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Metronome")
            
            Divider()
                .frame(height: 24)
            
            // MIDI Input selector
            MIDIInputPicker(midiManager: viewModel.midiManager)
                .help("Select MIDI Input Device")
            
            Spacer()
            
            // CPU meter (placeholder)
            HStack(spacing: 4) {
                Text("CPU")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                
                ProgressView(value: 0.15)
                    .progressViewStyle(.linear)
                    .frame(width: 40)
            }
            
            // Undo/Redo
            HStack(spacing: 4) {
                Button(action: { viewModel.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.undoManager.canUndo)
                .help("Undo \(viewModel.undoManager.undoActionName)")
                
                Button(action: { viewModel.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.undoManager.canRedo)
                .help("Redo \(viewModel.undoManager.redoActionName)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        // Real-time playhead updates
        .onReceive(viewModel.transportState.$playheadBeats) { beats in
            currentBeats = beats
        }
        .onReceive(viewModel.transportState.$playheadPosition) { position in
            currentSeconds = position.seconds
        }
        .onAppear {
            currentBeats = viewModel.transportState.playheadBeats
            currentSeconds = viewModel.transportState.playheadPosition.seconds
        }
    }
    
    // Bars display - uses local state for real-time updates
    private var barsDisplay: String {
        let beats = currentBeats
        let timeSig = viewModel.transportState.timeSignature
        let bar = Int(beats / Double(timeSig.beatsPerBar)) + 1
        let beatInBar = Int(beats.truncatingRemainder(dividingBy: Double(timeSig.beatsPerBar))) + 1
        let tick = Int((beats.truncatingRemainder(dividingBy: 1.0)) * 100)
        return String(format: "%d.%d.%02d", bar, beatInBar, tick)
    }
    
    // Time display - MM:SS:FF format (frames at 100fps for smooth display)
    private var timeDisplay: String {
        let totalSeconds = currentSeconds
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let frames = Int((totalSeconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d:%02d", minutes, seconds, frames)
    }
    
    private func commitTempo() {
        isEditingTempo = false
        if let bpm = Double(tempoText) {
            viewModel.setTempo(bpm)
        }
    }
}

// MARK: - Transport Mini View

/// Compact transport for embedding in other views
public struct TransportMiniView: View {
    @ObservedObject var transportState: TransportState
    
    public init(transportState: TransportState) {
        self.transportState = transportState
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            Button(action: { transportState.togglePlayPause() }) {
                Image(systemName: transportState.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            
            Text(transportState.formattedPosition)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - Tempo Tap Button

public struct TapTempoButton: View {
    @ObservedObject var transportState: TransportState
    
    @State private var tapTimes: [Date] = []
    @State private var lastTapTime: Date?
    
    public init(transportState: TransportState) {
        self.transportState = transportState
    }
    
    public var body: some View {
        Button(action: handleTap) {
            Text("TAP")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary, lineWidth: 1)
        )
        .help("Tap to set tempo")
    }
    
    private func handleTap() {
        let now = Date()
        
        // Reset if too much time passed
        if let lastTime = lastTapTime, now.timeIntervalSince(lastTime) > 2.0 {
            tapTimes.removeAll()
        }
        
        tapTimes.append(now)
        lastTapTime = now
        
        // Keep only last 8 taps
        if tapTimes.count > 8 {
            tapTimes.removeFirst()
        }
        
        // Need at least 2 taps
        if tapTimes.count >= 2 {
            transportState.tapTempo(tapTimes: tapTimes)
        }
    }
}
