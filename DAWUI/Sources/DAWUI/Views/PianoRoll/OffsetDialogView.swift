import SwiftUI
import DAWCore

// MARK: - Offset Presets

struct OffsetPreset: Identifiable {
    let id = UUID()
    let name: String
    let milliseconds: Double
    let description: String
}

let offsetPresets: [OffsetPreset] = [
    OffsetPreset(name: "0ms", milliseconds: 0, description: "Tight percussion, keys, plucks"),
    OffsetPreset(name: "-5ms", milliseconds: -5, description: "Short attacks"),
    OffsetPreset(name: "-10ms", milliseconds: -10, description: "Short strings, brass, winds"),
    OffsetPreset(name: "-20ms", milliseconds: -20, description: "Sustains, longs"),
    OffsetPreset(name: "-30ms", milliseconds: -30, description: "Slow pads, sound design"),
]

// MARK: - Offset Dialog View

struct OffsetDialogView: View {
    let noteCount: Int
    let tempo: Double
    let onApply: (Double) -> Void
    let onCancel: () -> Void
    
    @State private var offsetMilliseconds: Double = 0
    @State private var offsetText: String = "0"
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.left.and.right")
                    .font(.title2)
                    .foregroundColor(.orange)
                
                Text("Note Offset")
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
                
                // Preset buttons
                VStack(alignment: .leading, spacing: 8) {
                    Text("Presets:")
                        .font(.headline)
                    
                    VStack(spacing: 6) {
                        ForEach(offsetPresets) { preset in
                            Button(action: {
                                offsetMilliseconds = preset.milliseconds
                                offsetText = String(format: "%.0f", preset.milliseconds)
                            }) {
                                HStack {
                                    Text(preset.name)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .frame(width: 50, alignment: .leading)
                                    
                                    Text(preset.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    Spacer()
                                    
                                    if abs(offsetMilliseconds - preset.milliseconds) < 0.01 {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(abs(offsetMilliseconds - preset.milliseconds) < 0.01
                                              ? Color.accentColor.opacity(0.15)
                                              : Color(nsColor: .controlBackgroundColor))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                Divider()
                
                // Custom value input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom Offset (ms):")
                        .font(.headline)
                    
                    HStack {
                        TextField("0", text: $offsetText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .onChange(of: offsetText) { _, newValue in
                                if let value = Double(newValue) {
                                    offsetMilliseconds = value
                                }
                            }
                        
                        Text("milliseconds")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        // Quick adjust buttons
                        HStack(spacing: 4) {
                            Button("-10") {
                                offsetMilliseconds -= 10
                                offsetText = String(format: "%.0f", offsetMilliseconds)
                            }
                            .buttonStyle(.bordered)
                            
                            Button("-1") {
                                offsetMilliseconds -= 1
                                offsetText = String(format: "%.0f", offsetMilliseconds)
                            }
                            .buttonStyle(.bordered)
                            
                            Button("+1") {
                                offsetMilliseconds += 1
                                offsetText = String(format: "%.0f", offsetMilliseconds)
                            }
                            .buttonStyle(.bordered)
                            
                            Button("+10") {
                                offsetMilliseconds += 10
                                offsetText = String(format: "%.0f", offsetMilliseconds)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    // Beat equivalent display
                    let beatOffset = millisecondsToBeats(offsetMilliseconds)
                    Text("= \(String(format: "%.4f", beatOffset)) beats at \(String(format: "%.0f", tempo)) BPM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            
            Divider()
            
            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Apply Offset") {
                    onApply(offsetMilliseconds)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 450)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private func millisecondsToBeats(_ ms: Double) -> Double {
        // beats = (ms / 1000) * (tempo / 60)
        return (ms / 1000.0) * (tempo / 60.0)
    }
}
