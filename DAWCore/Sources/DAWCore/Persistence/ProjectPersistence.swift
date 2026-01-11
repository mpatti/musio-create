import Foundation

// MARK: - Project File Manager

/// Handles saving and loading DAW projects
public actor ProjectFileManager {
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - File Extension
    
    public static let projectExtension = "dawproj"
    public static let projectBundleExtension = "dawproject"
    
    // MARK: - Project Format
    
    /// Project file structure (JSON-based)
    private struct ProjectFile: Codable {
        var version: Int
        var project: Project
        var audioFileManifest: [AudioFileEntry]
        var pluginStates: [PluginStateEntry]
    }
    
    private struct AudioFileEntry: Codable {
        var fileID: UUID
        var relativePath: String
        var checksum: String?
    }
    
    private struct PluginStateEntry: Codable {
        var trackID: String
        var slotIndex: Int
        var pluginID: PluginIdentifier
        var stateData: Data
    }
    
    // MARK: - Saving
    
    /// Save project to a URL
    public func save(project: Project, to url: URL) async throws {
        // Create project bundle directory
        let bundleURL = url.appendingPathExtension(Self.projectBundleExtension)
        let fileManager = FileManager.default
        
        // Remove existing bundle if present
        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
        }
        
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        
        // Create subdirectories
        let audioDir = bundleURL.appendingPathComponent("Audio")
        let pluginsDir = bundleURL.appendingPathComponent("Plugins")
        
        try fileManager.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        
        // Build manifest
        let audioManifest = project.audioFiles.map { ref in
            AudioFileEntry(
                fileID: ref.fileID,
                relativePath: ref.relativePath,
                checksum: nil
            )
        }
        
        // Create project file
        let projectFile = ProjectFile(
            version: Project.currentFormatVersion,
            project: project,
            audioFileManifest: audioManifest,
            pluginStates: []  // Plugin states would be saved separately
        )
        
        // Encode and save
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(projectFile)
        let projectFileURL = bundleURL.appendingPathComponent("project.json")
        try data.write(to: projectFileURL)
        
        // Copy audio files
        for audioRef in project.audioFiles {
            let sourceURL = URL(fileURLWithPath: audioRef.originalPath)
            let destURL = audioDir.appendingPathComponent(audioRef.relativePath)
            
            // Create intermediate directories
            try fileManager.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            
            if fileManager.fileExists(atPath: sourceURL.path) {
                try fileManager.copyItem(at: sourceURL, to: destURL)
            }
        }
    }
    
    /// Save just the project JSON (for autosave)
    public func saveQuick(project: Project, to url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(project)
        try data.write(to: url)
    }
    
    // MARK: - Loading
    
    /// Load project from a URL
    public func load(from url: URL) async throws -> Project {
        let fileManager = FileManager.default
        
        // Check if it's a bundle or single file
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PersistenceError.fileNotFound(url)
        }
        
        let projectFileURL: URL
        if isDirectory.boolValue {
            // Project bundle
            projectFileURL = url.appendingPathComponent("project.json")
        } else {
            // Single JSON file
            projectFileURL = url
        }
        
        let data = try Data(contentsOf: projectFileURL)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        // Try loading as ProjectFile first
        do {
            let projectFile = try decoder.decode(ProjectFile.self, from: data)
            
            // Handle version migration if needed
            var project = projectFile.project
            project = try migrateIfNeeded(project, fromVersion: projectFile.version)
            
            return project
        } catch {
            // Try loading as plain Project
            return try decoder.decode(Project.self, from: data)
        }
    }
    
    /// Quick load for recent files check
    public func loadMetadata(from url: URL) async throws -> ProjectMetadataInfo {
        let data = try Data(contentsOf: url)
        
        // Only decode the metadata portion
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        // Create a minimal struct just for metadata
        struct MetadataOnly: Codable {
            var version: Int?
            var project: ProjectSummary
            
            struct ProjectSummary: Codable {
                var id: UUID
                var name: String
                var createdAt: Date
                var modifiedAt: Date
                var metadata: ProjectMetadata?
            }
        }
        
        let meta = try decoder.decode(MetadataOnly.self, from: data)
        
        return ProjectMetadataInfo(
            id: meta.project.id,
            name: meta.project.name,
            createdAt: meta.project.createdAt,
            modifiedAt: meta.project.modifiedAt,
            fileURL: url
        )
    }
    
    // MARK: - Migration
    
    private func migrateIfNeeded(_ project: Project, fromVersion: Int) throws -> Project {
        var migratedProject = project
        
        // Apply migrations in order
        if fromVersion < 1 {
            // Migration from version 0 to 1
            // (Example: add new required fields)
        }
        
        // Update format version
        migratedProject.formatVersion = Project.currentFormatVersion
        
        return migratedProject
    }
    
    // MARK: - Export
    
    /// Export project to a standard format
    public func export(
        project: Project,
        to url: URL,
        format: ExportFormat
    ) async throws {
        switch format {
        case .json:
            try await saveQuick(project: project, to: url)
            
        case .midi:
            try await exportAsMIDI(project: project, to: url)
        }
    }
    
    private func exportAsMIDI(project: Project, to url: URL) async throws {
        // Build a standard MIDI file from MIDI tracks
        // This is a simplified implementation
        
        var midiData = Data()
        
        // MIDI file header
        let headerChunk: [UInt8] = [
            0x4D, 0x54, 0x68, 0x64,  // "MThd"
            0x00, 0x00, 0x00, 0x06,  // Chunk length
            0x00, 0x01,              // Format type 1
            0x00, UInt8(project.tracks.count + 1),  // Number of tracks
            0x01, 0xE0               // 480 ticks per quarter note
        ]
        midiData.append(contentsOf: headerChunk)
        
        // Add track chunks for each MIDI track
        // (Full implementation would convert all MIDI events)
        
        try midiData.write(to: url)
    }
}

// MARK: - Errors

public enum PersistenceError: Error, LocalizedError {
    case fileNotFound(URL)
    case invalidFormat(String)
    case migrationFailed(from: Int, to: Int)
    case writeError(underlying: Error)
    case readError(underlying: Error)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .invalidFormat(let reason):
            return "Invalid project format: \(reason)"
        case .migrationFailed(let from, let to):
            return "Failed to migrate project from version \(from) to \(to)"
        case .writeError(let error):
            return "Failed to write file: \(error.localizedDescription)"
        case .readError(let error):
            return "Failed to read file: \(error.localizedDescription)"
        }
    }
}

// MARK: - Export Format

public enum ExportFormat {
    case json
    case midi
}

// MARK: - Project Metadata Info

public struct ProjectMetadataInfo: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let fileURL: URL
}

// MARK: - Autosave Manager

/// Manages periodic autosaving of projects
@MainActor
public final class AutosaveManager: ObservableObject {
    
    private var autosaveTimer: Timer?
    private let fileManager: ProjectFileManager
    private var projectURL: URL?
    
    @Published public var lastAutosaveDate: Date?
    @Published public var hasUnsavedChanges: Bool = false
    
    /// Autosave interval in seconds
    public var autosaveInterval: TimeInterval = 60
    
    public init() {
        self.fileManager = ProjectFileManager()
    }
    
    public func startAutosave(for projectURL: URL) {
        self.projectURL = projectURL
        
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(
            withTimeInterval: autosaveInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performAutosave()
            }
        }
    }
    
    public func stopAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }
    
    private func performAutosave() async {
        guard hasUnsavedChanges, let url = projectURL else { return }
        
        // Create autosave URL
        let autosaveURL = url.deletingPathExtension()
            .appendingPathExtension("autosave")
            .appendingPathExtension(ProjectFileManager.projectExtension)
        
        // Autosave would use the current project state
        // In a real implementation, this would access the shared project state
        
        lastAutosaveDate = Date()
        hasUnsavedChanges = false
    }
    
    public func recoverFromAutosave(originalURL: URL) async throws -> Project? {
        let autosaveURL = originalURL.deletingPathExtension()
            .appendingPathExtension("autosave")
            .appendingPathExtension(ProjectFileManager.projectExtension)
        
        let fm = FileManager.default
        guard fm.fileExists(atPath: autosaveURL.path) else {
            return nil
        }
        
        return try await fileManager.load(from: autosaveURL)
    }
    
    public func deleteAutosave(for originalURL: URL) {
        let autosaveURL = originalURL.deletingPathExtension()
            .appendingPathExtension("autosave")
            .appendingPathExtension(ProjectFileManager.projectExtension)
        
        try? FileManager.default.removeItem(at: autosaveURL)
    }
}

// MARK: - Recent Projects Manager

@MainActor
public final class RecentProjectsManager: ObservableObject {
    
    @Published public private(set) var recentProjects: [ProjectMetadataInfo] = []
    
    private let maxRecentProjects = 10
    private let userDefaultsKey = "DAWRecentProjects"
    
    public init() {
        loadRecentProjects()
    }
    
    public func addRecentProject(_ url: URL) {
        var urls = loadRecentURLs()
        
        // Remove if already exists
        urls.removeAll { $0 == url }
        
        // Add to front
        urls.insert(url, at: 0)
        
        // Limit count
        if urls.count > maxRecentProjects {
            urls = Array(urls.prefix(maxRecentProjects))
        }
        
        saveRecentURLs(urls)
        loadRecentProjects()
    }
    
    public func removeRecentProject(_ url: URL) {
        var urls = loadRecentURLs()
        urls.removeAll { $0 == url }
        saveRecentURLs(urls)
        loadRecentProjects()
    }
    
    public func clearRecentProjects() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        recentProjects = []
    }
    
    private func loadRecentProjects() {
        let urls = loadRecentURLs()
        
        Task {
            var projects: [ProjectMetadataInfo] = []
            let fileManager = ProjectFileManager()
            
            for url in urls {
                if let metadata = try? await fileManager.loadMetadata(from: url) {
                    projects.append(metadata)
                }
            }
            
            await MainActor.run {
                self.recentProjects = projects
            }
        }
    }
    
    private func loadRecentURLs() -> [URL] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let urls = try? JSONDecoder().decode([URL].self, from: data) else {
            return []
        }
        return urls
    }
    
    private func saveRecentURLs(_ urls: [URL]) {
        let data = try? JSONEncoder().encode(urls)
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
