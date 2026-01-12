import SwiftUI
import DAWCore

// MARK: - AI Settings View

/// Settings view for AI audio generation configuration
public struct AISettingsView: View {
    @State private var apiKey: String = ""
    @State private var showAPIKey: Bool = false
    @State private var isSaved: Bool = false
    
    public init() {
        _apiKey = State(initialValue: ElevenLabsAPIKeyStorage.apiKey ?? "")
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("AI Audio Settings")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            // ElevenLabs API Key
            VStack(alignment: .leading, spacing: 8) {
                Text("ElevenLabs API Key")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("Get your API key from elevenlabs.io/app/settings/api-keys")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    if showAPIKey {
                        TextField("Enter API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("Enter API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    Button(action: { showAPIKey.toggle() }) {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showAPIKey ? "Hide API key" : "Show API key")
                }
                
                HStack {
                    Button("Save API Key") {
                        saveAPIKey()
                    }
                    .disabled(apiKey.isEmpty)
                    
                    if isSaved {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Saved")
                                .foregroundColor(.green)
                        }
                        .font(.caption)
                    }
                    
                    Spacer()
                    
                    if ElevenLabsAPIKeyStorage.hasAPIKey {
                        Button("Clear") {
                            clearAPIKey()
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            
            Divider()
            
            // Status
            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    Circle()
                        .fill(ElevenLabsAPIKeyStorage.hasAPIKey ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(ElevenLabsAPIKeyStorage.hasAPIKey ? "API key configured" : "API key required")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Info
            VStack(alignment: .leading, spacing: 8) {
                Text("About AI Audio Generation")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("This feature uses ElevenLabs Sound Effects API to generate audio from text descriptions. Generated audio is placed directly on your timeline.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("Usage is billed through your ElevenLabs account. Check elevenlabs.io for pricing details.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }
    
    private func saveAPIKey() {
        ElevenLabsAPIKeyStorage.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaved = true
        
        // Reset saved indicator after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isSaved = false
        }
    }
    
    private func clearAPIKey() {
        ElevenLabsAPIKeyStorage.apiKey = nil
        apiKey = ""
        isSaved = false
    }
}

// MARK: - Compact API Key Status (for AI panel)

public struct AIAPIKeyStatus: View {
    @State private var showSettings: Bool = false
    
    public init() {}
    
    public var body: some View {
        Button(action: { showSettings = true }) {
            HStack(spacing: 4) {
                Image(systemName: ElevenLabsAPIKeyStorage.hasAPIKey ? "key.fill" : "key")
                    .foregroundColor(ElevenLabsAPIKeyStorage.hasAPIKey ? .green : .orange)
                Text(ElevenLabsAPIKeyStorage.hasAPIKey ? "API Key Set" : "Configure API Key")
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSettings) {
            AISettingsView()
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AISettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AISettingsView()
    }
}
#endif
