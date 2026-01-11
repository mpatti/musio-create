import SwiftUI
import DAWCore

// MARK: - MIDI Settings View

public struct MIDISettingsView: View {
    @ObservedObject var midiManager: MIDIManager
    
    public init(midiManager: MIDIManager) {
        self.midiManager = midiManager
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "pianokeys")
                    .font(.title2)
                Text("MIDI Settings")
                    .font(.headline)
                Spacer()
                
                Button(action: { midiManager.refreshDevices() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh MIDI devices")
            }
            
            Divider()
            
            // MIDI Input Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("MIDI Input Device")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if midiManager.inputDevices.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("No MIDI input devices found")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    Picker("Input Device", selection: $midiManager.selectedInputDeviceID) {
                        Text("All Devices").tag(nil as String?)
                        Divider()
                        ForEach(midiManager.inputDevices) { device in
                            HStack {
                                Text(device.name)
                                if !device.manufacturer.isEmpty && device.manufacturer != "Unknown" {
                                    Text("(\(device.manufacturer))")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .tag(device.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            
            // Connected status
            if let selected = midiManager.selectedInputDevice {
                HStack {
                    Circle()
                        .fill(midiManager.isConnected(selected) ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(midiManager.isConnected(selected) ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Device list (informational)
            VStack(alignment: .leading, spacing: 8) {
                Text("Available MIDI Devices")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if midiManager.inputDevices.isEmpty && midiManager.outputDevices.isEmpty {
                    Text("No MIDI devices detected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            // Inputs
                            if !midiManager.inputDevices.isEmpty {
                                Text("Inputs:")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                ForEach(midiManager.inputDevices) { device in
                                    MIDIDeviceRow(device: device, isConnected: midiManager.isConnected(device))
                                }
                            }
                            
                            // Outputs
                            if !midiManager.outputDevices.isEmpty {
                                Text("Outputs:")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .padding(.top, 8)
                                ForEach(midiManager.outputDevices) { device in
                                    MIDIDeviceRow(device: device, isConnected: false)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 300)
    }
}

// MARK: - MIDI Device Row

struct MIDIDeviceRow: View {
    let device: MIDIDevice
    let isConnected: Bool
    
    var body: some View {
        HStack {
            Image(systemName: device.isInput ? "arrow.right.circle" : "arrow.left.circle")
                .foregroundColor(device.isInput ? .blue : .green)
                .font(.caption)
            
            Text(device.name)
                .font(.caption)
            
            if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
            
            Spacer()
            
            if !device.manufacturer.isEmpty && device.manufacturer != "Unknown" {
                Text(device.manufacturer)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(isConnected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}

// MARK: - Compact MIDI Input Picker (for toolbar/track header)

public struct MIDIInputPicker: View {
    @ObservedObject var midiManager: MIDIManager
    
    public init(midiManager: MIDIManager) {
        self.midiManager = midiManager
    }
    
    public var body: some View {
        Menu {
            Button("All Devices") {
                midiManager.selectedInputDeviceID = nil
            }
            
            Divider()
            
            ForEach(midiManager.inputDevices) { device in
                Button(action: { midiManager.selectedInputDeviceID = device.id }) {
                    HStack {
                        Text(device.name)
                        if midiManager.selectedInputDeviceID == device.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            
            Divider()
            
            Button(action: { midiManager.refreshDevices() }) {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pianokeys")
                    .font(.caption)
                Text(selectedDeviceName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
    }
    
    private var selectedDeviceName: String {
        if let id = midiManager.selectedInputDeviceID,
           let device = midiManager.inputDevices.first(where: { $0.id == id }) {
            return device.name
        }
        return "All MIDI"
    }
}

// MARK: - Preview

#if DEBUG
struct MIDISettingsView_Previews: PreviewProvider {
    static var previews: some View {
        MIDISettingsView(midiManager: MIDIManager())
            .frame(width: 350, height: 400)
    }
}
#endif
