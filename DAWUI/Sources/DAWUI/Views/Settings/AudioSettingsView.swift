import SwiftUI
import DAWCore
import AVFoundation

// MARK: - Audio Settings View

public struct AudioSettingsView: View {
    @ObservedObject var audioEngine: AudioEngine
    @State private var showRestartAlert = false
    @Environment(\.dismiss) private var dismiss
    
    public init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "speaker.wave.3")
                    .font(.title2)
                Text("Audio Settings")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
            
            Divider()
            
            // Buffer Size
            VStack(alignment: .leading, spacing: 8) {
                Text("Buffer Size")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    Picker("Buffer Size", selection: Binding(
                        get: { audioEngine.bufferSize },
                        set: { audioEngine.setBufferSize($0) }
                    )) {
                        ForEach(AudioEngine.availableBufferSizes, id: \.self) { size in
                            Text("\(size) samples").tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
                    
                    Text("(\(String(format: "%.1f", audioEngine.latencyMs)) ms latency)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text("Lower values reduce latency but increase CPU usage. Use 64-256 for recording, 512-1024 for mixing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Divider()
            
            // Sample Rate (informational for now)
            VStack(alignment: .leading, spacing: 8) {
                Text("Sample Rate")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    Text("\(Int(audioEngine.sampleRate)) Hz")
                        .font(.system(.body, design: .monospaced))
                    
                    Spacer()
                    
                    Text("Set by audio device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Audio Engine Status
            VStack(alignment: .leading, spacing: 8) {
                Text("Engine Status")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    Circle()
                        .fill(audioEngine.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(audioEngine.isRunning ? "Running" : "Stopped")
                        .font(.caption)
                    
                    Spacer()
                    
                    if audioEngine.isRunning {
                        Text("Master: \(Int(audioEngine.masterVolume * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Divider()
            
            // Audio Backend Selection
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Audio Backend")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("Beta")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                
                Toggle(isOn: Binding(
                    get: { AudioBackendFactory.useCoreAudioBackend },
                    set: { newValue in
                        AudioBackendFactory.useCoreAudioBackend = newValue
                        showRestartAlert = true
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Core Audio Backend")
                            .font(.body)
                        Text("Professional-grade engine with sample-accurate timing")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                
                HStack(spacing: 8) {
                    Image(systemName: AudioBackendFactory.useCoreAudioBackend ? "waveform.badge.plus" : "waveform")
                        .foregroundColor(AudioBackendFactory.useCoreAudioBackend ? .blue : .secondary)
                    Text("Current: \(AudioBackendFactory.currentBackendName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if AudioBackendFactory.useCoreAudioBackend {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Sample-accurate MIDI timing")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Direct Core Audio render callback")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Offline bounce support")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            Divider()
            
            // Latency Information
            VStack(alignment: .leading, spacing: 4) {
                Text("Latency Guide")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 2) {
                    LatencyInfoRow(size: "64", latency: latencyString(64), use: "Live performance")
                    LatencyInfoRow(size: "128", latency: latencyString(128), use: "Recording")
                    LatencyInfoRow(size: "256", latency: latencyString(256), use: "General use")
                    LatencyInfoRow(size: "512", latency: latencyString(512), use: "Mixing (default)")
                    LatencyInfoRow(size: "1024", latency: latencyString(1024), use: "Heavy sessions")
                }
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 320)
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("OK") { }
        } message: {
            Text("The audio backend change will take effect after restarting the application.")
        }
    }
    
    private func latencyString(_ bufferSize: Int) -> String {
        let latency = Double(bufferSize) / audioEngine.sampleRate * 1000.0
        return String(format: "%.1f ms", latency)
    }
}

// MARK: - Latency Info Row

struct LatencyInfoRow: View {
    let size: String
    let latency: String
    let use: String
    
    var body: some View {
        HStack {
            Text(size)
                .font(.caption)
                .frame(width: 40, alignment: .trailing)
            Text(latency)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)
            Text(use)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: - Compact Buffer Size Picker (for toolbar)

public struct BufferSizePicker: View {
    @ObservedObject var audioEngine: AudioEngine
    
    public init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }
    
    public var body: some View {
        Menu {
            ForEach(AudioEngine.availableBufferSizes, id: \.self) { size in
                Button(action: { audioEngine.setBufferSize(size) }) {
                    HStack {
                        Text("\(size) samples")
                        if audioEngine.bufferSize == size {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.caption)
                Text("\(audioEngine.bufferSize)")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .help("Buffer Size: \(audioEngine.bufferSize) samples (\(String(format: "%.1f", audioEngine.latencyMs)) ms)")
    }
}

// MARK: - Preview

#if DEBUG
struct AudioSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AudioSettingsView(audioEngine: AudioEngine())
            .frame(width: 350, height: 500)
    }
}
#endif
