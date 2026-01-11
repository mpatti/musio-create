import SwiftUI
import AVFoundation
import DAWCore

// MARK: - Mixer View

/// Mixing console view with channel strips
public struct MixerView: View {
    @ObservedObject var viewModel: ProjectViewModel
    
    @State private var showPluginBrowser = false
    @State private var selectedPluginSlot: (TrackID, Int)?
    
    public init(viewModel: ProjectViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Mixer header
            HStack {
                Text("Mixer")
                    .font(.headline)
                
                Spacer()
                
                // View options
                Menu {
                    Button("Show Sends") {}
                    Button("Show Inserts") {}
                    Button("Show I/O") {}
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Channel strips - left aligned
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 0) {
                        // Track channels
                        ForEach(viewModel.project.tracks) { track in
                            ChannelStripView(
                                track: track,
                                viewModel: viewModel,
                                isPlaying: viewModel.transportState.isPlaying,
                                onPluginSlotClick: { slotIndex in
                                    selectedPluginSlot = (track.id, slotIndex)
                                    showPluginBrowser = true
                                }
                            )
                            
                            Divider()
                        }
                        
                        // Master channel
                        MasterChannelStripView(
                            track: viewModel.project.masterTrack,
                            viewModel: viewModel,
                            isPlaying: viewModel.transportState.isPlaying
                        )
                    }
                }
                
                Spacer() // Push channels to the left
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showPluginBrowser) {
            PluginBrowserView(
                viewModel: viewModel,
                onSelect: { pluginID in
                    if let (trackID, slotIndex) = selectedPluginSlot {
                        Task {
                            await loadPlugin(pluginID, to: trackID, slot: slotIndex)
                        }
                    }
                    showPluginBrowser = false
                }
            )
            .frame(minWidth: 400, minHeight: 500)
        }
    }
    
    private func loadPlugin(_ pluginID: PluginIdentifier, to trackID: TrackID, slot slotIndex: Int) async {
        do {
            // Get audio format from engine
            let format = AVAudioFormat(standardFormatWithSampleRate: viewModel.audioEngine.sampleRate, channels: 2)!
            
            // Load the plugin
            let loadedPlugin = try await viewModel.pluginHost.loadPlugin(
                identifier: pluginID,
                format: format
            )
            
            // Update track with plugin
            if var track = viewModel.project.track(withID: trackID) {
                // Ensure we have enough slots
                while track.pluginSlots.count <= slotIndex {
                    track.pluginSlots.append(PluginSlot())
                }
                
                track.pluginSlots[slotIndex].pluginID = pluginID
                track.pluginSlots[slotIndex].isEnabled = true
                
                viewModel.updateTrack(track, description: "Add Plugin")
                
                // Insert into audio chain
                try viewModel.audioEngine.insertPlugin(loadedPlugin.audioUnit, on: trackID, at: slotIndex)
            }
        } catch {
            print("Failed to load plugin: \(error)")
        }
    }
}

// MARK: - Channel Strip View

struct ChannelStripView: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    let isPlaying: Bool
    let onPluginSlotClick: (Int) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Track name with color indicator
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: track.color.hex) ?? .blue)
                    .frame(height: 4)
                
                Text(track.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            
            // Plugin slot
            let slot = track.pluginSlots.first
            PluginSlotView(
                slot: slot,
                onClick: { onPluginSlotClick(0) },
                onOpenEditor: slot?.pluginID != nil ? {
                    openPluginEditor(for: track.id, slot: slot!)
                } : nil
            )
            .padding(.vertical, 4)
            
            // Pan knob
            KnobView(
                value: Binding(
                    get: { Double(track.pan) },
                    set: { viewModel.setTrackPan(id: track.id, pan: Float($0)) }
                ),
                range: -1...1,
                label: ""
            )
            .frame(width: 36, height: 36)
            
            Spacer(minLength: 4)
            
            // Meter and fader side by side
            HStack(spacing: 2) {
                StereoMeterView(leftLevel: isPlaying ? 0.3 : 0, rightLevel: isPlaying ? 0.25 : 0)
                    .frame(width: 12, height: 80)
                
                FaderView(
                    value: Binding(
                        get: { Double(track.volume) },
                        set: { viewModel.setTrackVolume(id: track.id, volume: Float($0)) }
                    ),
                    range: 0...1.4
                )
                .frame(width: 18, height: 80)
            }
            
            Text(volumeText)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
            
            // Solo/Mute
            HStack(spacing: 4) {
                Button(action: { viewModel.toggleTrackSolo(id: track.id) }) {
                    Text("S")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(track.isSolo ? .black : .secondary)
                        .frame(width: 22, height: 18)
                        .background(track.isSolo ? Color.yellow : Color.gray.opacity(0.3))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.toggleTrackMute(id: track.id) }) {
                    Text("M")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(track.isMuted ? .black : .secondary)
                        .frame(width: 22, height: 18)
                        .background(track.isMuted ? Color.orange : Color.gray.opacity(0.3))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
        }
        .frame(width: 70, height: 260)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectTrack(track.id)
        }
    }
    
    private var isSelected: Bool {
        viewModel.selectedTrackID == track.id
    }
    
    private var volumeText: String {
        let db = 20 * log10(track.volume)
        if db == -.infinity { return "-∞" }
        return String(format: "%.1f", db)
    }
    
    private func openPluginEditor(for trackID: TrackID, slot: PluginSlot) {
        guard let pluginID = slot.pluginID,
              let loadedPlugin = viewModel.pluginHost.loadedPlugins.values.first(where: { $0.identifier == pluginID }) else {
            return
        }
        
        PluginWindowManager.shared.openPluginWindow(for: loadedPlugin, trackName: track.name)
    }
}

// MARK: - Master Channel Strip View

struct MasterChannelStripView: View {
    let track: Track
    @ObservedObject var viewModel: ProjectViewModel
    let isPlaying: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Master label
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(height: 4)
                
                Text("MASTER")
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            
            Spacer(minLength: 8)
            
            // Meter and fader
            HStack(spacing: 4) {
                StereoMeterView(leftLevel: isPlaying ? 0.4 : 0, rightLevel: isPlaying ? 0.35 : 0)
                    .frame(width: 16, height: 140)
                
                FaderView(
                    value: Binding(
                        get: { Double(viewModel.audioEngine.masterVolume) },
                        set: { viewModel.audioEngine.setMasterVolume(Float($0)) }
                    ),
                    range: 0...1.4
                )
                .frame(width: 24, height: 140)
            }
            
            Text(masterVolumeText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .frame(width: 80, height: 260)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        .cornerRadius(4)
    }
    
    private var masterVolumeText: String {
        let db = 20 * log10(viewModel.audioEngine.masterVolume)
        if db == -.infinity { return "-∞ dB" }
        return String(format: "%.1f dB", db)
    }
}

// MARK: - Plugin Slot View

struct PluginSlotView: View {
    let slot: PluginSlot?
    let onClick: () -> Void
    let onOpenEditor: (() -> Void)?
    
    init(slot: PluginSlot?, onClick: @escaping () -> Void, onOpenEditor: (() -> Void)? = nil) {
        self.slot = slot
        self.onClick = onClick
        self.onOpenEditor = onOpenEditor
    }
    
    var body: some View {
        Button(action: {
            if slot?.pluginID != nil, let openEditor = onOpenEditor {
                openEditor()
            } else {
                onClick()
            }
        }) {
            HStack {
                if let slot = slot, slot.pluginID != nil {
                    Circle()
                        .fill(slot.isEnabled ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    
                    Text(slot.pluginID?.name ?? "Plugin")
                        .font(.system(size: 8))
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(width: 70, height: 16)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if slot?.pluginID != nil {
                Button("Open Editor") { onOpenEditor?() }
                Divider()
                Button("Remove Plugin", role: .destructive) { onClick() }
            }
        }
    }
}

// MARK: - Fader View

struct FaderView: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 6)
                
                // Fill
                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 6, height: fillHeight(in: geometry.size.height))
                }
                
                // Handle
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .frame(width: 20, height: 12)
                    .shadow(radius: 1)
                    .offset(y: handleOffset(in: geometry.size.height))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let normalized = 1.0 - (gesture.location.y / geometry.size.height)
                        let clamped = max(0, min(1, normalized))
                        value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
    
    private func normalizedValue() -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    
    private func fillHeight(in totalHeight: CGFloat) -> CGFloat {
        CGFloat(normalizedValue()) * totalHeight
    }
    
    private func handleOffset(in totalHeight: CGFloat) -> CGFloat {
        let normalized = normalizedValue()
        return (1.0 - CGFloat(normalized)) * totalHeight - totalHeight / 2
    }
}

// MARK: - Knob View

struct KnobView: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // Knob background
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 30, height: 30)
                
                // Indicator
                Circle()
                    .trim(from: 0, to: 0.75)
                    .rotation(.degrees(135))
                    .stroke(Color.accentColor, lineWidth: 3)
                    .frame(width: 26, height: 26)
                
                // Position indicator
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 10)
                    .offset(y: -8)
                    .rotationEffect(.degrees(indicatorAngle))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let delta = -gesture.translation.height / 100
                        let normalized = normalizedValue() + delta
                        let clamped = max(0, min(1, normalized))
                        value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                    }
            )
            
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
    
    private func normalizedValue() -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    
    private var indicatorAngle: Double {
        -135 + normalizedValue() * 270
    }
}

// MARK: - Stereo Meter View

struct StereoMeterView: View {
    let leftLevel: Float
    let rightLevel: Float
    
    var body: some View {
        HStack(spacing: 2) {
            MeterChannelView(level: leftLevel)
            MeterChannelView(level: rightLevel)
        }
    }
}

struct MeterChannelView: View {
    let level: Float
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background
                Rectangle()
                    .fill(Color.black)
                
                // Meter segments
                VStack(spacing: 1) {
                    // Red zone (top 10%)
                    Rectangle()
                        .fill(level > 0.9 ? Color.red : Color.red.opacity(0.2))
                        .frame(height: geometry.size.height * 0.1)
                    
                    // Yellow zone (next 20%)
                    Rectangle()
                        .fill(level > 0.7 ? Color.yellow : Color.yellow.opacity(0.2))
                        .frame(height: geometry.size.height * 0.2)
                    
                    // Green zone (bottom 70%)
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.green.opacity(0.2))
                        
                        if level > 0 {
                            Rectangle()
                                .fill(Color.green)
                                .frame(height: max(0, CGFloat(min(level, 0.7)) / 0.7 * geometry.size.height * 0.7))
                        }
                    }
                    .frame(height: geometry.size.height * 0.7)
                }
            }
            .cornerRadius(2)
        }
    }
}

// MARK: - Plugin Browser View

struct PluginBrowserView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let onSelect: (PluginIdentifier) -> Void
    
    @State private var searchText = ""
    @State private var selectedCategory: PluginCategory = .all
    @State private var isScanning = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Plugins")
                    .font(.headline)
                
                Spacer()
                
                if isScanning {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                
                Button("Rescan") {
                    isScanning = true
                    Task {
                        await viewModel.pluginHost.scanForPlugins()
                        isScanning = false
                    }
                }
                .disabled(isScanning)
            }
            .padding()
            
            Divider()
            
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search plugins...", text: $searchText)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Category tabs
            Picker("Category", selection: $selectedCategory) {
                Text("All").tag(PluginCategory.all)
                Text("Effects").tag(PluginCategory.effects)
                Text("Instruments").tag(PluginCategory.instruments)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            
            Divider()
            
            // Plugin list
            if filteredEffects.isEmpty && filteredInstruments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("No plugins found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("Click Rescan to search for Audio Unit plugins")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("Scan for Plugins") {
                        isScanning = true
                        Task {
                            await viewModel.pluginHost.scanForPlugins()
                            isScanning = false
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    if (selectedCategory == .all || selectedCategory == .effects) && !filteredEffects.isEmpty {
                        Section("Effects (\(filteredEffects.count))") {
                            ForEach(filteredEffects) { plugin in
                                PluginRowView(plugin: plugin, isInstrument: false, onSelect: {
                                    onSelect(plugin.identifier)
                                })
                            }
                        }
                    }
                    
                    if (selectedCategory == .all || selectedCategory == .instruments) && !filteredInstruments.isEmpty {
                        Section("Instruments (\(filteredInstruments.count))") {
                            ForEach(filteredInstruments) { plugin in
                                PluginRowView(plugin: plugin, isInstrument: true, onSelect: {
                                    onSelect(plugin.identifier)
                                })
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if viewModel.pluginHost.availableEffects.isEmpty && viewModel.pluginHost.availableInstruments.isEmpty {
                isScanning = true
                Task {
                    await viewModel.pluginHost.scanForPlugins()
                    isScanning = false
                }
            }
        }
    }
    
    private var filteredEffects: [PluginDescription] {
        viewModel.pluginHost.availableEffects.filter { plugin in
            searchText.isEmpty || plugin.identifier.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private var filteredInstruments: [PluginDescription] {
        viewModel.pluginHost.availableInstruments.filter { plugin in
            searchText.isEmpty || plugin.identifier.name.localizedCaseInsensitiveContains(searchText)
        }
    }
}

enum PluginCategory {
    case all
    case effects
    case instruments
}

struct PluginRowView: View {
    let plugin: PluginDescription
    let isInstrument: Bool
    let onSelect: () -> Void
    
    init(plugin: PluginDescription, isInstrument: Bool = false, onSelect: @escaping () -> Void) {
        self.plugin = plugin
        self.isInstrument = isInstrument
        self.onSelect = onSelect
    }
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                // Plugin icon based on type
                Image(systemName: isInstrument ? "pianokeys" : "waveform")
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.identifier.name)
                        .font(.system(size: 12, weight: .medium))
                    
                    Text(plugin.identifier.manufacturer)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(plugin.version)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
