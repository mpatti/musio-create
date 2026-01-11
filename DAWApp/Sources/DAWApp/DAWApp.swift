import SwiftUI
import DAWCore
import DAWUI

// MARK: - Main App

@main
struct DAWApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        // Main document window
        WindowGroup {
            MainWindowView(project: appState.currentProject)
                .environmentObject(appState)
        }
        .commands {
            // File commands
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    appState.newProject()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            
            CommandGroup(after: .newItem) {
                Button("Open...") {
                    appState.openProject()
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Menu("Open Recent") {
                    ForEach(appState.recentProjectsManager.recentProjects) { project in
                        Button(project.name) {
                            Task {
                                await appState.openProject(at: project.fileURL)
                            }
                        }
                    }
                    
                    if !appState.recentProjectsManager.recentProjects.isEmpty {
                        Divider()
                        Button("Clear Recent") {
                            appState.recentProjectsManager.clearRecentProjects()
                        }
                    }
                }
                
                Divider()
                
                Button("Save") {
                    appState.saveProject()
                }
                .keyboardShortcut("s", modifiers: .command)
                
                Button("Save As...") {
                    appState.saveProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            
            // Edit commands
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .performUndo, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)
                
                Button("Redo") {
                    NotificationCenter.default.post(name: .performRedo, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            
            // Transport commands
            CommandMenu("Transport") {
                Button("Play/Pause") {
                    NotificationCenter.default.post(name: .togglePlayPause, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [])
                
                Button("Stop") {
                    NotificationCenter.default.post(name: .stop, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [])
                
                Button("Return to Zero") {
                    NotificationCenter.default.post(name: .returnToZero, object: nil)
                }
                .keyboardShortcut(.home, modifiers: [])
                
                Divider()
                
                Button("Toggle Loop") {
                    NotificationCenter.default.post(name: .toggleLoop, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                
                Button("Toggle Metronome") {
                    NotificationCenter.default.post(name: .toggleMetronome, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            
            // Track commands
            CommandMenu("Track") {
                Button("New Audio Track") {
                    NotificationCenter.default.post(name: .newAudioTrack, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                
                Button("New MIDI Track") {
                    NotificationCenter.default.post(name: .newMIDITrack, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Delete Selected Track") {
                    NotificationCenter.default.post(name: .deleteSelectedTrack, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            
            // View commands
            CommandGroup(after: .toolbar) {
                Button("Toggle Mixer") {
                    NotificationCenter.default.post(name: .toggleMixer, object: nil)
                }
                .keyboardShortcut("m", modifiers: .command)
                
                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .toggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
                
                Divider()
                
                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("=", modifiers: .command)
                
                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
            }
        }
        
        // Settings window
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    @Published var currentProject: Project
    @Published var currentProjectURL: URL?
    @Published var hasUnsavedChanges: Bool = false
    
    let recentProjectsManager = RecentProjectsManager()
    private let fileManager = ProjectFileManager()
    
    init() {
        self.currentProject = ProjectFactory.createNewProject()
    }
    
    // MARK: - Project Management
    
    func newProject() {
        // Prompt to save if needed
        currentProject = ProjectFactory.createNewProject()
        currentProjectURL = nil
        hasUnsavedChanges = false
    }
    
    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: ProjectFileManager.projectExtension)!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await self?.openProject(at: url)
            }
        }
    }
    
    func openProject(at url: URL) async {
        do {
            currentProject = try await fileManager.load(from: url)
            currentProjectURL = url
            hasUnsavedChanges = false
            recentProjectsManager.addRecentProject(url)
        } catch {
            print("Failed to open project: \(error)")
            // Show alert
        }
    }
    
    func saveProject() {
        if let url = currentProjectURL {
            Task {
                try? await fileManager.saveQuick(project: currentProject, to: url)
                hasUnsavedChanges = false
            }
        } else {
            saveProjectAs()
        }
    }
    
    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: ProjectFileManager.projectExtension)!]
        panel.nameFieldStringValue = currentProject.name
        
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            
            Task {
                do {
                    try await self.fileManager.save(project: self.currentProject, to: url)
                    await MainActor.run {
                        self.currentProjectURL = url
                        self.hasUnsavedChanges = false
                        self.recentProjectsManager.addRecentProject(url)
                    }
                } catch {
                    print("Failed to save project: \(error)")
                }
            }
        }
    }
}

// Notification names are defined in DAWUI/Views/Shared/KeyboardShortcuts.swift

// MARK: - Settings View

struct SettingsView: View {
    @State private var selectedTab = SettingsTab.audio
    
    var body: some View {
        TabView(selection: $selectedTab) {
            AudioSettingsView()
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.3")
                }
                .tag(SettingsTab.audio)
            
            MIDISettingsView()
                .tabItem {
                    Label("MIDI", systemImage: "pianokeys")
                }
                .tag(SettingsTab.midi)
            
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
        }
        .frame(width: 500, height: 400)
    }
}

enum SettingsTab {
    case audio
    case midi
    case general
}

struct AudioSettingsView: View {
    @State private var selectedInputDevice = 0
    @State private var selectedOutputDevice = 0
    @State private var sampleRate = 44100
    @State private var bufferSize = 512
    
    var body: some View {
        Form {
            Section("Audio Device") {
                Picker("Input Device", selection: $selectedInputDevice) {
                    Text("Built-in Microphone").tag(0)
                    Text("External Interface").tag(1)
                }
                
                Picker("Output Device", selection: $selectedOutputDevice) {
                    Text("Built-in Output").tag(0)
                    Text("External Interface").tag(1)
                }
            }
            
            Section("Audio Settings") {
                Picker("Sample Rate", selection: $sampleRate) {
                    Text("44.1 kHz").tag(44100)
                    Text("48 kHz").tag(48000)
                    Text("88.2 kHz").tag(88200)
                    Text("96 kHz").tag(96000)
                }
                
                Picker("Buffer Size", selection: $bufferSize) {
                    Text("64 samples").tag(64)
                    Text("128 samples").tag(128)
                    Text("256 samples").tag(256)
                    Text("512 samples").tag(512)
                    Text("1024 samples").tag(1024)
                }
                
                let latency = Double(bufferSize) / Double(sampleRate) * 1000
                Text("Latency: \(String(format: "%.1f", latency)) ms")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct MIDISettingsView: View {
    @State private var selectedMIDIInput = 0
    @State private var selectedMIDIOutput = 0
    
    var body: some View {
        Form {
            Section("MIDI Devices") {
                Picker("MIDI Input", selection: $selectedMIDIInput) {
                    Text("All Inputs").tag(0)
                    Text("Virtual MIDI").tag(1)
                }
                
                Picker("MIDI Output", selection: $selectedMIDIOutput) {
                    Text("None").tag(0)
                    Text("Virtual MIDI").tag(1)
                }
            }
            
            Section("MIDI Settings") {
                Toggle("Echo MIDI Input", isOn: .constant(false))
                Toggle("Record CC Data", isOn: .constant(true))
            }
        }
        .padding()
    }
}

struct GeneralSettingsView: View {
    @State private var autosaveInterval = 60
    @State private var showWelcomeScreen = true
    
    var body: some View {
        Form {
            Section("Autosave") {
                Toggle("Enable Autosave", isOn: .constant(true))
                
                Picker("Autosave Interval", selection: $autosaveInterval) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
            }
            
            Section("Startup") {
                Toggle("Show Welcome Screen", isOn: $showWelcomeScreen)
            }
        }
        .padding()
    }
}
