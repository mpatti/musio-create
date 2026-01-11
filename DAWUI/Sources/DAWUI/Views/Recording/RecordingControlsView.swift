import SwiftUI
import DAWCore

// MARK: - Recording Controls View

public struct RecordingControlsView: View {
    @ObservedObject var viewModel: ProjectViewModel
    @State private var showInputSettings = false
    @State private var selectedInputDevice: AudioInputDevice?
    @State private var availableInputs: [AudioInputDevice] = []
    @State private var availableMIDIInputs: [MIDIDevice] = []
    
    public init(viewModel: ProjectViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Recording")
                    .font(.headline)
                Spacer()
                
                Button(action: { showInputSettings.toggle() }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Audio Input Section
                    audioInputSection
                    
                    Divider()
                    
                    // MIDI Input Section
                    midiInputSection
                    
                    Divider()
                    
                    // Armed Tracks
                    armedTracksSection
                    
                    Divider()
                    
                    // Recording Status
                    recordingStatusSection
                }
                .padding()
            }
        }
        .onAppear {
            refreshDevices()
        }
        .sheet(isPresented: $showInputSettings) {
            InputSettingsSheet(viewModel: viewModel, isPresented: $showInputSettings)
        }
    }
    
    // MARK: - Audio Input Section
    
    private var audioInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "mic")
                    .foregroundColor(.accentColor)
                Text("Audio Input")
                    .font(.subheadline.bold())
                Spacer()
                Button("Refresh") {
                    refreshDevices()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            
            if availableInputs.isEmpty {
                Text("No audio inputs found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("Input Device", selection: $selectedInputDevice) {
                    Text("None").tag(nil as AudioInputDevice?)
                    ForEach(availableInputs) { device in
                        Text("\(device.name) (\(device.channelCount) ch)")
                            .tag(device as AudioInputDevice?)
                    }
                }
                .labelsHidden()
            }
            
            // Input level meter
            HStack {
                Text("Level:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                        
                        Rectangle()
                            .fill(levelColor)
                            .frame(width: geo.size.width * CGFloat(viewModel.audioRecorder.inputLevel))
                    }
                }
                .frame(height: 8)
                .cornerRadius(4)
            }
        }
    }
    
    private var levelColor: Color {
        let level = viewModel.audioRecorder.inputLevel
        if level > 0.9 {
            return .red
        } else if level > 0.7 {
            return .yellow
        }
        return .green
    }
    
    // MARK: - MIDI Input Section
    
    private var midiInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "pianokeys")
                    .foregroundColor(.accentColor)
                Text("MIDI Input")
                    .font(.subheadline.bold())
                Spacer()
                
                if viewModel.midiManager.isSetup {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if viewModel.midiManager.inputDevices.isEmpty {
                Text("No MIDI inputs found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button("Setup MIDI") {
                    Task {
                        await viewModel.setupMIDI()
                    }
                }
                .buttonStyle(.bordered)
            } else {
                ForEach(viewModel.midiManager.inputDevices) { device in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(device.name)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
            
            // MIDI activity indicator
            if viewModel.midiRecorder.recordedEventCount > 0 {
                HStack {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                    Text("\(viewModel.midiRecorder.recordedEventCount) events recorded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Armed Tracks Section
    
    private var armedTracksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "record.circle")
                    .foregroundColor(.red)
                Text("Armed Tracks")
                    .font(.subheadline.bold())
            }
            
            let armedTracks = viewModel.project.tracks.filter { $0.isArmed }
            
            if armedTracks.isEmpty {
                Text("No tracks armed for recording")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Click the record button (⊙) on a track to arm it")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                ForEach(armedTracks) { track in
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text(track.name)
                            .font(.caption)
                        Text("(\(track.type.rawValue))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
    
    // MARK: - Recording Status Section
    
    private var recordingStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if viewModel.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.red, lineWidth: 2)
                                .scaleEffect(1.5)
                                .opacity(0.5)
                        )
                    
                    Text("RECORDING")
                        .font(.subheadline.bold())
                        .foregroundColor(.red)
                    
                    Text(formatDuration(viewModel.audioRecorder.recordingDuration))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                } else {
                    Text("Ready to record")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            HStack(spacing: 12) {
                // Record button
                Button(action: {
                    if viewModel.isRecording {
                        viewModel.stopRecording()
                    } else {
                        viewModel.startRecording()
                    }
                }) {
                    HStack {
                        Circle()
                            .fill(viewModel.isRecording ? Color.gray : Color.red)
                            .frame(width: 20, height: 20)
                        Text(viewModel.isRecording ? "Stop" : "Record")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.project.tracks.filter({ $0.isArmed }).isEmpty)
                
                // Cancel button (only when recording)
                if viewModel.isRecording {
                    Button("Cancel") {
                        viewModel.cancelRecording()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func refreshDevices() {
        availableInputs = viewModel.audioRecorder.availableInputDevices()
        // MIDI devices are refreshed through the manager
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let milliseconds = Int((duration.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, milliseconds)
    }
}

// MARK: - Input Settings Sheet

struct InputSettingsSheet: View {
    @ObservedObject var viewModel: ProjectViewModel
    @Binding var isPresented: Bool
    
    @State private var sampleRate: Double = 44100
    @State private var bitDepth: Int = 24
    @State private var monitoringEnabled: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Input Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
            }
            .padding()
            
            Divider()
            
            Form {
                Section("Recording Format") {
                    Picker("Sample Rate", selection: $sampleRate) {
                        Text("44.1 kHz").tag(44100.0)
                        Text("48 kHz").tag(48000.0)
                        Text("96 kHz").tag(96000.0)
                    }
                    
                    Picker("Bit Depth", selection: $bitDepth) {
                        Text("16-bit").tag(16)
                        Text("24-bit").tag(24)
                        Text("32-bit float").tag(32)
                    }
                }
                
                Section("Monitoring") {
                    Toggle("Input Monitoring", isOn: $monitoringEnabled)
                    Text("⚠️ Use headphones to avoid feedback")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .frame(width: 400, height: 300)
        .onChange(of: sampleRate) { _, newValue in
            viewModel.audioRecorder.sampleRate = newValue
        }
        .onChange(of: bitDepth) { _, newValue in
            viewModel.audioRecorder.bitDepth = newValue
        }
        .onChange(of: monitoringEnabled) { _, newValue in
            viewModel.audioRecorder.setInputMonitoring(enabled: newValue)
        }
    }
}
