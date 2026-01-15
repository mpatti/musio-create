import SwiftUI
import DAWCore

// MARK: - V-Rack Sidebar View

/// Sidebar panel for managing V-Rack instruments
public struct VRackView: View {
    @ObservedObject var viewModel: ProjectViewModel
    @State private var showPluginBrowser = false
    @State private var selectedRackInstrumentID: UUID?
    
    public init(viewModel: ProjectViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Instruments")
                    .font(.headline)
                Spacer()
                Button(action: { viewModel.addRackInstrument() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add Rack Instrument")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Instrument List
            if viewModel.project.vRack.instruments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pianokeys")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No Instruments")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Click + to add a multi-timbral instrument")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.project.vRack.instruments) { instrument in
                            RackInstrumentRow(
                                instrument: instrument,
                                viewModel: viewModel,
                                isSelected: selectedRackInstrumentID == instrument.id,
                                onSelect: { selectedRackInstrumentID = instrument.id },
                                onShowBrowser: {
                                    selectedRackInstrumentID = instrument.id
                                    showPluginBrowser = true
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 200)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showPluginBrowser) {
            if let rackID = selectedRackInstrumentID {
                RackPluginBrowserSheet(
                    viewModel: viewModel,
                    rackInstrumentID: rackID,
                    isPresented: $showPluginBrowser
                )
            }
        }
    }
}

// MARK: - Rack Instrument Row

struct RackInstrumentRow: View {
    let instrument: RackInstrument
    @ObservedObject var viewModel: ProjectViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onShowBrowser: () -> Void
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Instrument icon/button
                Button(action: {
                    if instrument.pluginSlot.pluginID != nil {
                        viewModel.openRackInstrumentUI(instrument.id)
                    } else {
                        onShowBrowser()
                    }
                }) {
                    Image(systemName: "pianokeys")
                        .font(.system(size: 14))
                        .foregroundColor(instrument.pluginSlot.pluginID != nil ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                
                VStack(alignment: .leading, spacing: 2) {
                    // Instrument name
                    Text(instrument.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    
                    // Plugin name or "Empty"
                    Text(instrument.pluginSlot.pluginID?.name ?? "Empty - Click to load")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Mute button
                Button(action: {
                    viewModel.toggleRackInstrumentMute(instrument.id)
                }) {
                    Text("M")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(instrument.isMuted ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 18, height: 18)
                .background(instrument.isMuted ? Color.orange.opacity(0.2) : Color.clear)
                .cornerRadius(3)
                
                // Delete button
                Button(action: {
                    viewModel.removeRackInstrument(instrument.id)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}

// MARK: - Plugin Browser Sheet for V-Rack

struct RackPluginBrowserSheet: View {
    @ObservedObject var viewModel: ProjectViewModel
    let rackInstrumentID: UUID
    @Binding var isPresented: Bool
    
    @State private var isScanning = false
    @State private var searchText = ""
    
    private var filteredPlugins: [PluginIdentifier] {
        if searchText.isEmpty {
            return viewModel.availableInstrumentPlugins
        }
        return viewModel.availableInstrumentPlugins.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.manufacturer.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Instrument")
                    .font(.headline)
                Spacer()
                if isScanning {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Button("Cancel") {
                    isPresented = false
                }
            }
            .padding()
            
            // Search field
            TextField("Search instruments...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)
            
            Divider()
            
            // Plugin list
            if isScanning {
                VStack {
                    Spacer()
                    ProgressView("Scanning for instruments...")
                    Spacer()
                }
            } else if filteredPlugins.isEmpty {
                VStack {
                    Spacer()
                    Text("No instruments found")
                        .foregroundColor(.secondary)
                    Text("Make sure you have AU instruments installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredPlugins, id: \.uniqueID) { plugin in
                            Button(action: {
                                // Log to file
                                let msg = "[VRACK] Loading plugin: \(plugin.name)\n"
                                try? msg.write(toFile: "/tmp/musio_vrack.log", atomically: true, encoding: .utf8)
                                print(msg)
                                
                                Task {
                                    do {
                                        try? "Starting loadRackInstrumentPlugin...\n".write(toFile: "/tmp/musio_vrack.log", atomically: false, encoding: .utf8)
                                        await viewModel.loadRackInstrumentPlugin(rackInstrumentID, pluginID: plugin)
                                        try? "loadRackInstrumentPlugin completed\n".write(toFile: "/tmp/musio_vrack.log", atomically: false, encoding: .utf8)
                                    }
                                }
                                isPresented = false
                            }) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(plugin.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Text(plugin.manufacturer)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
        .onAppear {
            // Scan for plugins if not already done
            if viewModel.pluginHost.availableInstruments.isEmpty {
                isScanning = true
                Task {
                    await viewModel.pluginHost.scanForPlugins()
                    await MainActor.run {
                        isScanning = false
                    }
                }
            }
        }
    }
}
