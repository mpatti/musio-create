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
                    } else if track.type == .audio {
                        // Audio track with input selector
                        HStack(spacing: 4) {
                            Image(systemName: trackTypeIcon)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            AudioInputSelector(track: track, viewModel: viewModel)
                        }
                    } else {
                        // Track type icon for other track types (bus, master)
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
                        
                        // Volume meter - shows input level for armed V-Rack tracks, otherwise output level
                        TrackMiniMeter(
                            level: meterLevel,
                            isInputMeter: showInputMeter
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
    
    /// Whether to show input meter (for armed audio tracks with V-Rack input)
    private var showInputMeter: Bool {
        track.type == .audio && track.isArmed && track.inputSource == .vRackSum
    }
    
    /// Meter level - shows V-Rack input when armed with V-Rack input, otherwise track output
    private var meterLevel: Float {
        if showInputMeter {
            // Show V-Rack input level
            return (viewModel.playbackEngine.vRackInputLevel.left + viewModel.playbackEngine.vRackInputLevel.right) / 2
        } else {
            // Show track output level
            return viewModel.playbackEngine.trackMeterLevels[track.id]?.left ?? 0
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
    var isInputMeter: Bool = false  // True for input metering (uses cyan color scheme)
    
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
        // Check if level exceeds this segment's threshold
        let isActive = level >= (Float(index) / 6.0)
        
        if isInputMeter {
            // Input meter uses cyan/blue color scheme
            if index < 4 {
                // Cyan zone
                return isActive ? .cyan.opacity(0.9) : .cyan.opacity(0.15)
            } else if index < 5 {
                // Orange zone (getting hot)
                return isActive ? .orange.opacity(0.9) : .orange.opacity(0.15)
            } else {
                // Red zone (clipping)
                return isActive ? .red.opacity(0.9) : .red.opacity(0.15)
            }
        } else {
            // Output meter uses green color scheme
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
    @State private var loadError: String?
    
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
            
            // Show error if present
            if let error = loadError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { loadError = nil }
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1))
            }
            
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredInstruments) { plugin in
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
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let clickMsg = "TAP: \(plugin.identifier.name)\n"
                                try? clickMsg.write(toFile: "/tmp/musio_click.log", atomically: true, encoding: .utf8)
                                loadInstrument(plugin)
                            }
                            
                            Divider()
                        }
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
    
    private func log(_ message: String) {
        let logPath = "/tmp/musio_instrument_load.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let fullMessage = "[\(timestamp)] \(message)\n"
        if let data = fullMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
        print(message)  // Also print for good measure
    }
    
    private func loadInstrument(_ description: PluginDescription) {
        isLoading = true
        loadError = nil
        
        // Clear log file
        try? "".write(toFile: "/tmp/musio_instrument_load.log", atomically: true, encoding: .utf8)
        
        log("========================================")
        log("Starting to load: \(description.identifier.name)")
        log("Manufacturer: \(description.identifier.manufacturer)")
        log("Track ID: \(trackID)")
        
        Task {
            do {
                log("Step 1: Creating audio format...")
                let format = AVAudioFormat(standardFormatWithSampleRate: viewModel.audioEngine.sampleRate, channels: 2)!
                log("Format: \(format)")
                
                log("Step 2: Loading plugin from host...")
                let loadedPlugin = try await viewModel.pluginHost.loadPlugin(
                    identifier: description.identifier,
                    format: format
                )
                log("Step 2 DONE: Plugin loaded: \(loadedPlugin.name)")
                
                // Update track's instrument slot
                if var track = viewModel.project.track(withID: trackID) {
                    log("Step 3: Updating track slot...")
                    track.instrumentSlot = PluginSlot(pluginID: description.identifier, isEnabled: true)
                    
                    await MainActor.run {
                        viewModel.updateTrack(track, description: "Load Instrument")
                    }
                    log("Step 3 DONE: Track updated")
                    
                    // Load instrument into playback engine
                    log("Step 4: Loading into playback engine...")
                    try await viewModel.playbackEngine.loadInstrument(
                        loadedPlugin.audioUnit,
                        for: trackID,
                        pluginID: loadedPlugin.id
                    )
                    log("Step 4 DONE: Playback engine loaded")
                    
                    await MainActor.run {
                        log("Step 5: Opening plugin window...")
                        // Open the instrument UI
                        PluginWindowManager.shared.openPluginWindow(for: loadedPlugin, trackName: track.name)
                        isPresented = false
                        log("Step 5 DONE: Window opened, closing browser")
                    }
                } else {
                    log("ERROR: Track not found for ID: \(trackID)")
                }
            } catch {
                log("❌ ERROR loading instrument: \(error)")
                log("Error type: \(type(of: error))")
                log("Error description: \(error.localizedDescription)")
                await MainActor.run { 
                    isLoading = false 
                    loadError = error.localizedDescription
                }
            }
            log("========================================")
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

// MARK: - Audio Input Selector

/// Compact selector for audio input source (hardware input or V-Rack sum)
struct AudioInputSelector: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    
    private var currentInputLabel: String {
        guard let inputSource = track.inputSource else {
            return "None"
        }
        return inputSource.displayName
    }
    
    var body: some View {
        Menu {
            // None option
            Button(action: {
                setInputSource(.none)
            }) {
                HStack {
                    Text("None")
                    if track.inputSource == nil || track.inputSource == .none {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Divider()
            
            // V-Rack Sum option
            Button(action: {
                setInputSource(.vRackSum)
            }) {
                HStack {
                    Text("V-Rack Sum")
                    if track.inputSource == .vRackSum {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Divider()
            
            // Hardware input options
            Text("Hardware Inputs")
                .foregroundColor(.secondary)
            
            ForEach(0..<8, id: \.self) { channel in
                Button(action: {
                    setInputSource(.audioDevice(channelIndex: channel))
                }) {
                    HStack {
                        Text("Input \(channel + 1)")
                        if case .audioDevice(let idx) = track.inputSource, idx == channel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: inputSourceIcon)
                    .font(.system(size: 9))
                Text(currentInputLabel)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(inputSourceBackground)
            .cornerRadius(3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    private var inputSourceIcon: String {
        switch track.inputSource {
        case .vRackSum:
            return "square.stack.3d.up.fill"
        case .audioDevice:
            return "mic.fill"
        default:
            return "waveform"
        }
    }
    
    private var inputSourceBackground: Color {
        switch track.inputSource {
        case .vRackSum:
            return Color.purple.opacity(0.3)
        case .audioDevice:
            return Color.green.opacity(0.3)
        default:
            return Color.secondary.opacity(0.1)
        }
    }
    
    private func setInputSource(_ source: InputSource) {
        var updatedTrack = track
        updatedTrack.inputSource = source
        viewModel.updateTrack(updatedTrack, description: "Set Audio Input")
    }
}
