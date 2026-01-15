import SwiftUI
import AppKit
import AVFoundation
import CoreAudioKit
import DAWCore

// MARK: - Plugin Window Manager

@MainActor
public final class PluginWindowManager: ObservableObject {
    public static let shared = PluginWindowManager()
    
    @Published public var openWindows: [UUID: PluginWindowInfo] = [:]
    
    private var windowControllers: [UUID: NSWindowController] = [:]
    
    // Cache view controllers so we can reuse them
    private var cachedViewControllers: [UUID: NSViewController] = [:]
    
    private init() {}
    
    public func openPluginWindow(for plugin: LoadedPlugin, trackName: String) {
        // Check if window already exists and is still valid
        if let existingController = windowControllers[plugin.id],
           let window = existingController.window,
           window.isVisible || window.isMiniaturized {
            // Window still exists and is valid - just bring it to front
            window.makeKeyAndOrderFront(nil)
            print("[PluginWindow] Bringing existing window to front for \(plugin.name)")
            return
        }
        
        // Clean up any stale window controller entry (but keep cached view controller)
        if windowControllers[plugin.id] != nil {
            print("[PluginWindow] Cleaning up stale window controller for \(plugin.name)")
            windowControllers.removeValue(forKey: plugin.id)
            openWindows.removeValue(forKey: plugin.id)
        }
        
        print("[PluginWindow] Creating new window for \(plugin.name)")
        
        // Check if we have a cached view controller
        if let cachedVC = cachedViewControllers[plugin.id] {
            print("[PluginWindow] Using cached view controller for \(plugin.name)")
            createPluginWindow(
                for: plugin,
                trackName: trackName,
                nativeViewController: cachedVC
            )
            return
        }
        
        // Request native view controller
        print("[PluginWindow] Requesting view controller from AU for \(plugin.name)")
        plugin.audioUnit.auAudioUnit.requestViewController { [weak self] viewController in
            Task { @MainActor in
                // Cache the view controller for future use
                if let vc = viewController {
                    self?.cachedViewControllers[plugin.id] = vc
                    print("[PluginWindow] Cached view controller for \(plugin.name)")
                } else {
                    print("[PluginWindow] WARNING: requestViewController returned nil for \(plugin.name)")
                }
                
                self?.createPluginWindow(
                    for: plugin,
                    trackName: trackName,
                    nativeViewController: viewController
                )
            }
        }
    }
    
    private func createPluginWindow(
        for plugin: LoadedPlugin,
        trackName: String,
        nativeViewController: NSViewController?
    ) {
        // Determine window size based on plugin view
        var windowSize = NSSize(width: 800, height: 600)
        let headerHeight: CGFloat = 50
        
        if let vc = nativeViewController {
            // Force layout to get accurate size
            vc.view.layoutSubtreeIfNeeded()
            
            // Try multiple methods to get the plugin UI size
            let preferredSize = vc.preferredContentSize
            let viewFrame = vc.view.frame
            let viewBounds = vc.view.bounds
            let fittingSize = vc.view.fittingSize
            
            print("[PluginWindow] View sizes - preferred: \(preferredSize), frame: \(viewFrame.size), bounds: \(viewBounds.size), fitting: \(fittingSize)")
            
            // Use the best available size
            if preferredSize.width > 100 && preferredSize.height > 100 {
                windowSize = preferredSize
            } else if viewFrame.width > 100 && viewFrame.height > 100 {
                windowSize = viewFrame.size
            } else if viewBounds.width > 100 && viewBounds.height > 100 {
                windowSize = viewBounds.size
            } else if fittingSize.width > 100 && fittingSize.height > 100 {
                windowSize = fittingSize
            }
            
            // Ensure minimum size
            windowSize.width = max(windowSize.width, 400)
            windowSize.height = max(windowSize.height, 300)
        }
        
        // Add header height
        let totalHeight = windowSize.height + headerHeight
        
        print("[PluginWindow] Creating window with size: \(windowSize.width) x \(totalHeight)")
        
        // Create new window with appropriate size
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowSize.width, height: totalHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "\(plugin.identifier.name) - \(trackName)"
        window.center()
        window.isReleasedWhenClosed = false
        
        // Create the content view with native VC if available
        let contentView = PluginWindowContentView(
            plugin: plugin,
            initialNativeViewController: nativeViewController,
            onClose: { [weak self] in
                self?.closePluginWindow(id: plugin.id)
            }
        )
        
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
        
        let controller = NSWindowController(window: window)
        windowControllers[plugin.id] = controller
        
        openWindows[plugin.id] = PluginWindowInfo(
            pluginID: plugin.id,
            pluginName: plugin.identifier.name,
            trackName: trackName
        )
        
        controller.showWindow(nil)
        
        // After showing, resize window to fit content if needed
        if let vc = nativeViewController {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let actualSize = vc.view.frame.size
                if actualSize.width > 100 && actualSize.height > 100 {
                    let newSize = NSSize(width: actualSize.width, height: actualSize.height + headerHeight)
                    window.setContentSize(newSize)
                    window.center()
                }
            }
        }
        
        // Handle window closing
        let pluginID = plugin.id
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePluginWindow(id: pluginID)
            }
        }
    }
    
    public func closePluginWindow(id: UUID) {
        print("[PluginWindow] Closing window for plugin \(id.uuidString.prefix(8))")
        if let controller = windowControllers[id] {
            controller.window?.orderOut(nil)  // Hide first
            controller.close()
        }
        windowControllers.removeValue(forKey: id)
        openWindows.removeValue(forKey: id)
        // Keep cachedViewControllers - we'll reuse them if the window is reopened
        print("[PluginWindow] Window closed. Open windows: \(windowControllers.count)")
    }
    
    public func closeAllWindows() {
        for id in windowControllers.keys {
            closePluginWindow(id: id)
        }
    }
    
    /// Clear all cached data for a plugin (call when plugin is unloaded)
    public func clearPluginCache(id: UUID) {
        closePluginWindow(id: id)
        cachedViewControllers.removeValue(forKey: id)
        print("[PluginWindow] Cleared cache for plugin \(id.uuidString.prefix(8))")
    }
    
    /// Clear all caches (call when project is closed)
    public func clearAllCaches() {
        closeAllWindows()
        cachedViewControllers.removeAll()
        print("[PluginWindow] Cleared all caches")
    }
}

// MARK: - Plugin Window Info

public struct PluginWindowInfo: Identifiable {
    public let id: UUID
    public let pluginID: UUID
    public let pluginName: String
    public let trackName: String
    
    init(pluginID: UUID, pluginName: String, trackName: String) {
        self.id = pluginID
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.trackName = trackName
    }
}

// MARK: - Plugin Window Content View

struct PluginWindowContentView: View {
    let plugin: LoadedPlugin
    var initialNativeViewController: NSViewController?
    let onClose: () -> Void
    
    @State private var bypassEnabled: Bool = false
    @State private var showNativeUI: Bool = true  // Default to showing native UI
    @State private var nativeViewController: NSViewController?
    @State private var isLoadingNativeUI: Bool = false
    
    init(plugin: LoadedPlugin, initialNativeViewController: NSViewController? = nil, onClose: @escaping () -> Void) {
        self.plugin = plugin
        self.initialNativeViewController = initialNativeViewController
        self.onClose = onClose
    }
    
    var body: some View {
        Group {
            // If we have native UI, show it directly without any header
            if showNativeUI, let vc = nativeViewController {
                NativePluginView(viewController: vc)
            } else {
                // Fallback: show header + generic parameter view
                VStack(spacing: 0) {
                    headerView
                    Divider()
                    GenericPluginParameterView(
                        plugin: plugin,
                        onRequestNativeUI: loadNativeUI
                    )
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            // Use pre-loaded native view controller if available
            if let vc = initialNativeViewController {
                nativeViewController = vc
                showNativeUI = true
            } else {
                // Try to load native UI
                loadNativeUI()
            }
        }
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(plugin.identifier.name)
                    .font(.headline)
                Text(plugin.identifier.manufacturer)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if nativeViewController != nil {
                Button(showNativeUI ? "Show Parameters" : "Show Plugin UI") {
                    showNativeUI.toggle()
                }
                .buttonStyle(.bordered)
            }
            
            if isLoadingNativeUI {
                ProgressView()
                    .scaleEffect(0.7)
            }
            
            Toggle("Bypass", isOn: $bypassEnabled)
                .toggleStyle(.switch)
                .onChange(of: bypassEnabled) { _, newValue in
                    plugin.audioUnit.auAudioUnit.shouldBypassEffect = newValue
                }
            
            Button("Close") {
                onClose()
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private func loadNativeUI() {
        guard !isLoadingNativeUI else { return }
        isLoadingNativeUI = true
        
        plugin.audioUnit.auAudioUnit.requestViewController { vc in
            DispatchQueue.main.async {
                isLoadingNativeUI = false
                if let viewController = vc {
                    nativeViewController = viewController
                    showNativeUI = true
                }
            }
        }
    }
}

// MARK: - Native Plugin View

/// Wraps a plugin's NSViewController using NSViewControllerRepresentable
/// Uses a wrapper controller to prevent SwiftUI from deallocating the plugin's view controller
struct NativePluginView: NSViewControllerRepresentable {
    let viewController: NSViewController
    
    /// A wrapper that contains the plugin view controller as a child
    class WrapperViewController: NSViewController {
        var pluginViewController: NSViewController?
        
        override func loadView() {
            self.view = NSView()
        }
        
        func embedPluginViewController(_ vc: NSViewController) {
            // Remove any existing child
            for child in children {
                child.view.removeFromSuperview()
                child.removeFromParent()
            }
            
            pluginViewController = vc
            addChild(vc)
            
            let pluginView = vc.view
            pluginView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(pluginView)
            
            NSLayoutConstraint.activate([
                pluginView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                pluginView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                pluginView.topAnchor.constraint(equalTo: view.topAnchor),
                pluginView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        
        deinit {
            // Don't deallocate the plugin view controller - just remove from parent
            if let pvc = pluginViewController {
                pvc.view.removeFromSuperview()
                pvc.removeFromParent()
            }
        }
    }
    
    func makeNSViewController(context: Context) -> WrapperViewController {
        let wrapper = WrapperViewController()
        wrapper.embedPluginViewController(viewController)
        return wrapper
    }
    
    func updateNSViewController(_ wrapper: WrapperViewController, context: Context) {
        // If the plugin view controller changed, re-embed it
        if wrapper.pluginViewController !== viewController {
            wrapper.embedPluginViewController(viewController)
        }
    }
}

// MARK: - Generic Plugin Parameter View

struct GenericPluginParameterView: View {
    let plugin: LoadedPlugin
    var onRequestNativeUI: (() -> Void)?
    
    @State private var parameters: [AUParameter] = []
    @State private var parameterValues: [AUParameterAddress: Float] = [:]
    @State private var isLoading: Bool = true
    @State private var retryCount: Int = 0
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Parameters")
                        .font(.headline)
                    
                    Spacer()
                    
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    
                    Button(action: { loadParameters() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh parameters")
                }
                .padding(.bottom, 8)
                
                if parameters.isEmpty && !isLoading {
                    VStack(spacing: 16) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        
                        Text("No parameters exposed")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("This plugin may have its own interface.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 12) {
                            Button("Load Plugin UI") {
                                onRequestNativeUI?()
                            }
                            .buttonStyle(.borderedProminent)
                            
                            Button("Retry Parameters") {
                                retryCount = 0
                                isLoading = true
                                loadParameters()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 50)
                } else if !parameters.isEmpty {
                    Text("\(parameters.count) parameters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(parameters, id: \.address) { param in
                            ParameterSliderView(
                                parameter: param,
                                value: Binding(
                                    get: { parameterValues[param.address] ?? param.value },
                                    set: { newValue in
                                        parameterValues[param.address] = newValue
                                        param.value = newValue
                                    }
                                )
                            )
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear {
            loadParameters()
            
            // Retry with delays
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if parameters.isEmpty { loadParameters() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if parameters.isEmpty { 
                    loadParameters()
                    isLoading = false
                }
            }
        }
    }
    
    private func loadParameters() {
        if let parameterTree = plugin.audioUnit.auAudioUnit.parameterTree {
            let allParams = parameterTree.allParameters
            if !allParams.isEmpty {
                parameters = allParams
                for param in parameters {
                    parameterValues[param.address] = param.value
                }
                isLoading = false
                return
            }
        }
        
        retryCount += 1
        if retryCount > 3 {
            isLoading = false
        }
    }
}

struct ParameterSliderView: View {
    let parameter: AUParameter
    @Binding var value: Float
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parameter.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text(formattedValue)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: Double(parameter.minValue)...Double(max(parameter.minValue + 0.001, parameter.maxValue))
            )
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }
    
    private var formattedValue: String {
        if let valueStrings = parameter.valueStrings,
           let index = Int(exactly: value),
           index >= 0 && index < valueStrings.count {
            return valueStrings[index]
        }
        
        let unit = parameter.unitName ?? ""
        
        if abs(parameter.maxValue - parameter.minValue) <= 1.0 {
            return String(format: "%.2f %@", value, unit).trimmingCharacters(in: .whitespaces)
        } else if parameter.maxValue > 1000 {
            return String(format: "%.0f %@", value, unit).trimmingCharacters(in: .whitespaces)
        } else {
            return String(format: "%.1f %@", value, unit).trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Plugin List View (for Mixer integration)

public struct PluginListView: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    
    @State private var showPluginBrowser = false
    @State private var selectedSlotIndex: Int = 0
    
    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }
    
    public var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { slotIndex in
                PluginSlotButton(
                    slot: slotAt(slotIndex),
                    slotIndex: slotIndex,
                    onAdd: {
                        selectedSlotIndex = slotIndex
                        showPluginBrowser = true
                    },
                    onOpen: {
                        openPlugin(at: slotIndex)
                    },
                    onRemove: {
                        removePlugin(at: slotIndex)
                    },
                    onToggle: {
                        togglePlugin(at: slotIndex)
                    }
                )
            }
        }
        .sheet(isPresented: $showPluginBrowser) {
            PluginBrowserSheet(
                viewModel: viewModel,
                trackID: trackID,
                slotIndex: selectedSlotIndex,
                isPresented: $showPluginBrowser
            )
        }
    }
    
    private func slotAt(_ index: Int) -> PluginSlot? {
        guard let track = viewModel.project.track(withID: trackID),
              track.pluginSlots.indices.contains(index) else { return nil }
        return track.pluginSlots[index]
    }
    
    private func openPlugin(at index: Int) {
        guard let slot = slotAt(index),
              let pluginID = slot.pluginID,
              let loadedPlugin = viewModel.pluginHost.loadedPlugins.values.first(where: { $0.identifier == pluginID }),
              let track = viewModel.project.track(withID: trackID) else { return }
        
        PluginWindowManager.shared.openPluginWindow(for: loadedPlugin, trackName: track.name)
    }
    
    private func removePlugin(at index: Int) {
        guard var track = viewModel.project.track(withID: trackID),
              track.pluginSlots.indices.contains(index) else { return }
        
        track.pluginSlots[index] = PluginSlot()
        viewModel.updateTrack(track, description: "Remove Plugin")
        
        do {
            try viewModel.audioEngine.removePlugin(at: index, from: trackID)
        } catch {
            print("Failed to remove plugin: \(error)")
        }
    }
    
    private func togglePlugin(at index: Int) {
        guard var track = viewModel.project.track(withID: trackID),
              track.pluginSlots.indices.contains(index) else { return }
        
        track.pluginSlots[index].isEnabled.toggle()
        viewModel.updateTrack(track, description: "Toggle Plugin")
    }
}

// MARK: - Plugin Slot Button

struct PluginSlotButton: View {
    let slot: PluginSlot?
    let slotIndex: Int
    let onAdd: () -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: {
            if slot?.pluginID != nil {
                onOpen()
            } else {
                onAdd()
            }
        }) {
            HStack(spacing: 4) {
                if let slot = slot, slot.pluginID != nil {
                    Circle()
                        .fill(slot.isEnabled ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                        .onTapGesture { onToggle() }
                    
                    Text(slot.pluginID?.name ?? "Plugin")
                        .font(.system(size: 9))
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(height: 18)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if slot?.pluginID != nil {
                Button("Open Editor") { onOpen() }
                Button(slot?.isEnabled == true ? "Bypass" : "Enable") { onToggle() }
                Divider()
                Button("Remove", role: .destructive) { onRemove() }
            } else {
                Button("Add Plugin...") { onAdd() }
            }
        }
    }
}

// MARK: - Plugin Browser Sheet

struct PluginBrowserSheet: View {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID
    let slotIndex: Int
    @Binding var isPresented: Bool
    
    @State private var searchText = ""
    @State private var selectedCategory: PluginCategoryFilter = .all
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Plugin")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
            }
            .padding()
            
            Divider()
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search plugins...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Picker("", selection: $selectedCategory) {
                Text("All").tag(PluginCategoryFilter.all)
                Text("Effects").tag(PluginCategoryFilter.effects)
                Text("Instruments").tag(PluginCategoryFilter.instruments)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            
            Divider()
            
            if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading plugin...")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if selectedCategory == .all || selectedCategory == .effects {
                        Section("Effects") {
                            ForEach(filteredEffects) { plugin in
                                PluginListRow(plugin: plugin) { loadPlugin(plugin) }
                            }
                        }
                    }
                    
                    if selectedCategory == .all || selectedCategory == .instruments {
                        Section("Instruments") {
                            ForEach(filteredInstruments) { plugin in
                                PluginListRow(plugin: plugin) { loadPlugin(plugin) }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
        .onAppear {
            if viewModel.pluginHost.availableEffects.isEmpty {
                Task { await viewModel.pluginHost.scanForPlugins() }
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
    
    private func loadPlugin(_ description: PluginDescription) {
        isLoading = true
        
        Task {
            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: viewModel.audioEngine.sampleRate, channels: 2)!
                let loadedPlugin = try await viewModel.pluginHost.loadPlugin(
                    identifier: description.identifier,
                    format: format
                )
                
                if var track = viewModel.project.track(withID: trackID) {
                    while track.pluginSlots.count <= slotIndex {
                        track.pluginSlots.append(PluginSlot())
                    }
                    
                    track.pluginSlots[slotIndex].pluginID = description.identifier
                    track.pluginSlots[slotIndex].isEnabled = true
                    
                    await MainActor.run {
                        viewModel.updateTrack(track, description: "Add Plugin")
                    }
                    
                    try viewModel.audioEngine.insertPlugin(loadedPlugin.audioUnit, on: trackID, at: slotIndex)
                    
                    await MainActor.run {
                        PluginWindowManager.shared.openPluginWindow(for: loadedPlugin, trackName: track.name)
                        isPresented = false
                    }
                }
            } catch {
                print("Failed to load plugin: \(error)")
                await MainActor.run { isLoading = false }
            }
        }
    }
}

enum PluginCategoryFilter {
    case all, effects, instruments
}

struct PluginListRow: View {
    let plugin: PluginDescription
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading) {
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
        }
        .buttonStyle(.plain)
    }
}
