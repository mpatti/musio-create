import SwiftUI
import DAWCore
import AVFoundation

// MARK: - Track Header View

struct TrackHeaderView: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    var onCreateClip: (() -> Void)? = nil
    
    @State private var isEditing = false
    @State private var editedName = ""
    @State private var showInstrumentBrowser = false
    
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
                    
                    // Instrument slot for MIDI/Instrument tracks
                    if track.type == .midi || track.type == .instrument {
                        HStack(spacing: 4) {
                            // MIDI Activity indicator
                            MIDIActivityIndicator(
                                isActive: viewModel.midiActivity && track.isArmed,
                                isArmed: track.isArmed
                            )
                            
                            InstrumentSlotButton(
                                track: track,
                                viewModel: viewModel,
                                showBrowser: $showInstrumentBrowser
                            )
                            
                            // MIDI Output selector (for routing to V-Rack)
                            MIDIOutputSelector(track: track, viewModel: viewModel)
                        }
                    } else {
                        // Track type icon for non-MIDI tracks
                        HStack(spacing: 2) {
                            Image(systemName: trackTypeIcon)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            Text(track.type.rawValue.capitalized)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
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
                        
                        // Volume meter - shows actual signal level
                        TrackMiniMeter(
                            level: viewModel.playbackEngine.trackMeterLevels[track.id]?.left ?? 0
                        )
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            
            Divider()
        }
        .sheet(isPresented: $showInstrumentBrowser) {
            InstrumentBrowserSheet(
                viewModel: viewModel,
                trackID: track.id,
                isPresented: $showInstrumentBrowser
            )
        }
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            // Instant selection with piano roll follow (no animation delay)
            withAnimation(.none) {
                viewModel.selectAndArmTrack(track.id)
            }
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
    let level: Float  // 0-1 normalized level
    
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<6, id: \.self) { i in
                Rectangle()
                    .fill(meterColor(for: i))
                    .frame(width: 3, height: CGFloat(6 + i * 2))
            }
        }
    }
    
    private func meterColor(for index: Int) -> Color {
        // Calculate threshold for this segment (0-5 maps to 0-1)
        let threshold = Float(index + 1) / 6.0
        
        // Check if level exceeds this segment's threshold
        let isActive = level >= (Float(index) / 6.0)
        
        if index < 4 {
            // Green zone
            return isActive ? .green.opacity(0.9) : .green.opacity(0.15)
        } else if index < 5 {
            // Yellow zone
            return isActive ? .yellow.opacity(0.9) : .yellow.opacity(0.15)
        } else {
            // Red zone
            return isActive ? .red.opacity(0.9) : .red.opacity(0.15)
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

// MARK: - Instrument Slot Button

struct InstrumentSlotButton: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    @Binding var showBrowser: Bool
    
    var body: some View {
        Button(action: {
            if track.instrumentSlot?.pluginID != nil {
                // Open instrument UI
                openInstrumentUI()
            } else {
                // Show browser to select instrument
                showBrowser = true
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "pianokeys")
                    .font(.system(size: 9))
                
                if let pluginID = track.instrumentSlot?.pluginID {
                    Text(pluginID.name)
                        .font(.system(size: 10))
                        .lineLimit(1)
                } else {
                    Text("No Instrument")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(track.instrumentSlot?.pluginID != nil ? Color.purple.opacity(0.3) : Color.gray.opacity(0.2))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if track.instrumentSlot?.pluginID != nil {
                Button("Open Instrument") { openInstrumentUI() }
                Divider()
                Button("Remove Instrument", role: .destructive) { removeInstrument() }
            } else {
                Button("Load Instrument...") { showBrowser = true }
            }
        }
    }
    
    private func openInstrumentUI() {
        guard let slot = track.instrumentSlot,
              let pluginID = slot.pluginID,
              let loadedPlugin = viewModel.pluginHost.loadedPlugins.values.first(where: { $0.identifier == pluginID }) else { return }
        
        PluginWindowManager.shared.openPluginWindow(for: loadedPlugin, trackName: track.name)
    }
    
    private func removeInstrument() {
        var updatedTrack = track
        updatedTrack.instrumentSlot = nil
        viewModel.updateTrack(updatedTrack, description: "Remove Instrument")
        viewModel.playbackEngine.removeInstrument(for: track.id)
    }
}

// MARK: - Instrument Browser Sheet

struct InstrumentBrowserSheet: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    @Binding var isPresented: Bool
    
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var isScanning = false
    @State private var instruments: [PluginDescription] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Instrument")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
            }
            .padding()
            
            Divider()
            
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search instruments...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading instrument...")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isScanning {
                VStack {
                    ProgressView()
                    Text("Scanning for plugins...")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if instruments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "pianokeys")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No instruments found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Make sure you have Audio Unit instruments installed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Scan for Plugins") {
                        scanForPlugins()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredInstruments) { plugin in
                        Button(action: { loadInstrument(plugin) }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(plugin.identifier.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(plugin.identifier.manufacturer)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
        .onAppear {
            // Always scan on appear
            scanForPlugins()
        }
    }
    
    private func scanForPlugins() {
        isScanning = true
        Task {
            await viewModel.pluginHost.scanForPlugins()
            await MainActor.run {
                instruments = viewModel.pluginHost.availableInstruments
                isScanning = false
                print("[InstrumentBrowser] Found \(instruments.count) instruments")
            }
        }
    }
    
    private var filteredInstruments: [PluginDescription] {
        instruments.filter { plugin in
            searchText.isEmpty || plugin.identifier.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private func loadInstrument(_ description: PluginDescription) {
        isLoading = true
        
        Task {
            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: viewModel.audioEngine.sampleRate, channels: 2)!
                let loadedPlugin = try await viewModel.pluginHost.loadPlugin(
                    identifier: description.identifier,
                    format: format
                )
                
                // Update track's instrument slot
                if var track = viewModel.project.track(withID: trackID) {
                    track.instrumentSlot = PluginSlot(pluginID: description.identifier, isEnabled: true)
                    
                    await MainActor.run {
                        viewModel.updateTrack(track, description: "Load Instrument")
                    }
                    
                    // Load instrument into playback engine
                    try await viewModel.playbackEngine.loadInstrument(
                        loadedPlugin.audioUnit,
                        for: trackID,
                        pluginID: loadedPlugin.id
                    )
                    
                    await MainActor.run {
                        // Open the instrument UI
                        PluginWindowManager.shared.openPluginWindow(for: loadedPlugin, trackName: track.name)
                        isPresented = false
                    }
                }
            } catch {
                print("Failed to load instrument: \(error)")
                await MainActor.run { isLoading = false }
            }
        }
    }
}

// MARK: - MIDI Activity Indicator

struct MIDIActivityIndicator: View {
    let isActive: Bool
    let isArmed: Bool
    
    var body: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.black.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: isActive ? .green : .clear, radius: 3)
            .animation(.easeOut(duration: 0.05), value: isActive)
            .help(isArmed ? "MIDI Activity (track armed)" : "Arm track to receive MIDI")
    }
    
    private var indicatorColor: Color {
        if isActive {
            return .green
        } else if isArmed {
            return .green.opacity(0.3)
        } else {
            return .gray.opacity(0.3)
        }
    }
}

// MARK: - MIDI Output Selector

/// Compact selector for MIDI output destination (track instrument or V-Rack)
struct MIDIOutputSelector: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    
    private var currentDestinationLabel: String {
        switch track.midiOutput {
        case .rackInstrument(let id, let channel):
            if let instrument = viewModel.project.vRack.instrument(withID: id) {
                return "\(instrument.name) Ch\(channel)"
            }
            return "Instrument Ch\(channel)"
        case .trackInstrument, .none:
            return "Track"
        }
    }
    
    var body: some View {
        Menu {
            // Track instrument option
            Button(action: {
                setMIDIOutput(.trackInstrument)
            }) {
                HStack {
                    Text("Track Instrument")
                    if case .trackInstrument = track.midiOutput {
                        Image(systemName: "checkmark")
                    } else if track.midiOutput == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Divider()
            
            // V-Rack instruments
            if viewModel.project.vRack.instruments.isEmpty {
                Text("No Instruments Loaded")
                    .foregroundColor(.secondary)
            } else {
                ForEach(viewModel.project.vRack.instruments) { instrument in
                    Menu(instrument.name) {
                        ForEach(1...16, id: \.self) { channel in
                            Button("Channel \(channel)") {
                                setMIDIOutput(.rackInstrument(id: instrument.id, channel: UInt8(channel)))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 8))
                Text(currentDestinationLabel)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    private func setMIDIOutput(_ destination: MIDIOutputDestination) {
        var updatedTrack = track
        updatedTrack.midiOutput = destination
        viewModel.updateTrack(updatedTrack, description: "Set MIDI Output")
    }
}
