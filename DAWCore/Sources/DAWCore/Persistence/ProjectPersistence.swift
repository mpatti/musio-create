import Foundation

// MARK: - Project File Manager

/// Handles saving and loading DAW projects as packages
public actor ProjectFileManager {
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Constants
    
    public static let projectExtension = "dawproj"
    
    // Package subdirectories
    private static let audioFolderName = "Audio Files"
    private static let pluginStatesFolderName = "Plugin States"
    private static let projectFileName = "project.json"
    
    // MARK: - Project Package Structure
    
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
        var originalPath: String  // For reference only
        var checksum: String?
    }
    
    private struct PluginStateEntry: Codable {
        var trackID: String
        var slotIndex: Int
        var pluginID: PluginIdentifier
        var stateData: Data
    }
    
    // MARK: - Saving
    
    /// Save project to a URL (creates a .dawproj package)
    public func save(project: Project, to url: URL) async throws {
        let fm = FileManager.default
        
        // Ensure URL has correct extension
        var packageURL = url
        if packageURL.pathExtension != Self.projectExtension {
            packageURL = url.deletingPathExtension().appendingPathExtension(Self.projectExtension)
        }
        
        // Remove existing package if present
        if fm.fileExists(atPath: packageURL.path) {
            try fm.removeItem(at: packageURL)
        }
        
        // Create package directory
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        
        // Create subdirectories
        let audioDir = packageURL.appendingPathComponent(Self.audioFolderName)
        let pluginsDir = packageURL.appendingPathComponent(Self.pluginStatesFolderName)
        
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        
        // Copy audio files and build manifest
        var updatedProject = project
        var audioManifest: [AudioFileEntry] = []
        
        print("[ProjectFileManager] Project has \(project.audioFiles.count) audio files in audioFiles array")
        
        // Also check clips for audio references that might not be in audioFiles
        var clipAudioRefs: [AudioFileReference] = []
        for track in project.tracks {
            for clip in track.clips {
                if case .audio(let audioData) = clip.content {
                    clipAudioRefs.append(audioData.fileReference)
                    print("[ProjectFileManager] Found audio clip: \(clip.name) -> \(audioData.fileReference.originalPath)")
                }
            }
        }
        print("[ProjectFileManager] Found \(clipAudioRefs.count) audio references in clips")
        
        // Merge any missing audio references from clips into audioFiles
        for clipRef in clipAudioRefs {
            if !updatedProject.audioFiles.contains(where: { $0.fileID == clipRef.fileID }) {
                print("[ProjectFileManager] Adding missing audio ref from clip: \(clipRef.originalPath)")
                updatedProject.audioFiles.append(clipRef)
            }
        }
        
        print("[ProjectFileManager] After merge: \(updatedProject.audioFiles.count) audio files to save")
        
        for (index, audioRef) in updatedProject.audioFiles.enumerated() {
            let destFileName = "\(audioRef.fileID.uuidString).\(URL(fileURLWithPath: audioRef.originalPath).pathExtension.isEmpty ? "wav" : URL(fileURLWithPath: audioRef.originalPath).pathExtension)"
            let destURL = audioDir.appendingPathComponent(destFileName)
            let relativePath = "\(Self.audioFolderName)/\(destFileName)"
            
            // Try to find the source file
            let sourceURL = findAudioFile(for: audioRef)
            
            if let sourceURL = sourceURL, fm.fileExists(atPath: sourceURL.path) {
                // Copy the file
                try fm.copyItem(at: sourceURL, to: destURL)
                print("[ProjectFileManager] Copied audio: \(sourceURL.lastPathComponent) -> \(destFileName)")
            } else {
                print("[ProjectFileManager] Warning: Audio file not found: \(audioRef.originalPath)")
            }
            
            // Update the reference in project
            var updatedRef = audioRef
            updatedRef.relativePath = relativePath
            updatedProject.audioFiles[index] = updatedRef
            
            // Update clips that reference this file
            for trackIndex in 0..<updatedProject.tracks.count {
                for clipIndex in 0..<updatedProject.tracks[trackIndex].clips.count {
                    if case .audio(var audioData) = updatedProject.tracks[trackIndex].clips[clipIndex].content {
                        if audioData.fileReference.fileID == audioRef.fileID {
                            audioData.fileReference.relativePath = relativePath
                            updatedProject.tracks[trackIndex].clips[clipIndex].content = .audio(audioData)
                        }
                    }
                }
            }
            
            audioManifest.append(AudioFileEntry(
                fileID: audioRef.fileID,
                relativePath: relativePath,
                originalPath: audioRef.originalPath,
                checksum: nil
            ))
        }
        
        // Create project file
        let projectFile = ProjectFile(
            version: Project.currentFormatVersion,
            project: updatedProject,
            audioFileManifest: audioManifest,
            pluginStates: []  // Plugin states saved separately in future
        )
        
        // Encode and save
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(projectFile)
        let projectFileURL = packageURL.appendingPathComponent(Self.projectFileName)
        try data.write(to: projectFileURL)
        
        print("[ProjectFileManager] Saved project to: \(packageURL.path)")
    }
    
    /// Find the actual location of an audio file
    private func findAudioFile(for ref: AudioFileReference) -> URL? {
        let fm = FileManager.default
        
        print("[ProjectFileManager] Looking for audio file: \(ref.originalPath)")
        print("[ProjectFileManager]   relativePath: \(ref.relativePath)")
        
        // Try original path first (most common case)
        let originalURL = URL(fileURLWithPath: ref.originalPath)
        if fm.fileExists(atPath: originalURL.path) {
            print("[ProjectFileManager]   Found at original path")
            return originalURL
        }
        
        // Try with resolved symlinks (handles /var/folders vs /private/var/folders)
        let resolvedURL = originalURL.resolvingSymlinksInPath()
        if fm.fileExists(atPath: resolvedURL.path) {
            print("[ProjectFileManager]   Found at resolved path: \(resolvedURL.path)")
            return resolvedURL
        }
        
        // Get the filename for temp directory searches
        let filename = URL(fileURLWithPath: ref.originalPath).lastPathComponent
        
        // Try the standard temporary directory
        let tempURL = fm.temporaryDirectory.appendingPathComponent(filename)
        if fm.fileExists(atPath: tempURL.path) {
            print("[ProjectFileManager]   Found in temp directory: \(tempURL.path)")
            return tempURL
        }
        
        // Try the DAWRecordings subdirectory (where V-Rack recordings are stored)
        let dawRecordingsURL = fm.temporaryDirectory.appendingPathComponent("DAWRecordings").appendingPathComponent(filename)
        if fm.fileExists(atPath: dawRecordingsURL.path) {
            print("[ProjectFileManager]   Found in DAWRecordings: \(dawRecordingsURL.path)")
            return dawRecordingsURL
        }
        
        // Try Application Support (new permanent location for recordings)
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let musioRecordings = appSupport.appendingPathComponent("MusioCreate/Recordings").appendingPathComponent(filename)
            if fm.fileExists(atPath: musioRecordings.path) {
                print("[ProjectFileManager]   Found in MusioCreate/Recordings: \(musioRecordings.path)")
                return musioRecordings
            }
        }
        
        // Try NSTemporaryDirectory() which might resolve differently
        let nsTemp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
        if fm.fileExists(atPath: nsTemp.path) {
            print("[ProjectFileManager]   Found in NSTemporaryDirectory: \(nsTemp.path)")
            return nsTemp
        }
        
        // Try DAWRecordings in NSTemporaryDirectory
        let nsTempDAW = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DAWRecordings").appendingPathComponent(filename)
        if fm.fileExists(atPath: nsTempDAW.path) {
            print("[ProjectFileManager]   Found in NSTemporaryDirectory/DAWRecordings: \(nsTempDAW.path)")
            return nsTempDAW
        }
        
        // Try with /private prefix (macOS symlink resolution)
        if !ref.originalPath.hasPrefix("/private") && ref.originalPath.hasPrefix("/var") {
            let privatePath = "/private" + ref.originalPath
            if fm.fileExists(atPath: privatePath) {
                print("[ProjectFileManager]   Found with /private prefix: \(privatePath)")
                return URL(fileURLWithPath: privatePath)
            }
        }
        
        // Try without /private prefix
        if ref.originalPath.hasPrefix("/private/var") {
            let withoutPrivate = String(ref.originalPath.dropFirst("/private".count))
            if fm.fileExists(atPath: withoutPrivate) {
                print("[ProjectFileManager]   Found without /private prefix: \(withoutPrivate)")
                return URL(fileURLWithPath: withoutPrivate)
            }
        }
        
        // Try by filename in relative path
        let relFilename = URL(fileURLWithPath: ref.relativePath).lastPathComponent
        if relFilename != filename {
            let tempURL2 = fm.temporaryDirectory.appendingPathComponent(relFilename)
            if fm.fileExists(atPath: tempURL2.path) {
                print("[ProjectFileManager]   Found by relativePath filename: \(tempURL2.path)")
                return tempURL2
            }
            
            // Also try DAWRecordings with relative path filename
            let dawRecordingsURL2 = fm.temporaryDirectory.appendingPathComponent("DAWRecordings").appendingPathComponent(relFilename)
            if fm.fileExists(atPath: dawRecordingsURL2.path) {
                print("[ProjectFileManager]   Found by relativePath in DAWRecordings: \(dawRecordingsURL2.path)")
                return dawRecordingsURL2
            }
        }
        
        // Check if the original path contains a temp folder pattern and try to construct the actual path
        if ref.originalPath.contains("/T/") || ref.originalPath.contains("var/folders") {
            // The path is already a temp path, try to access it via URL(fileURLWithPath:)
            let tempPathURL = URL(fileURLWithPath: ref.originalPath)
            if fm.fileExists(atPath: tempPathURL.path) {
                print("[ProjectFileManager]   Found via temp path URL")
                return tempPathURL
            }
        }
        
        // Last resort: search DAWRecordings for any file matching the timestamp pattern
        if filename.contains("VRack_") {
            let dawRecordingsDir = fm.temporaryDirectory.appendingPathComponent("DAWRecordings")
            if let contents = try? fm.contentsOfDirectory(at: dawRecordingsDir, includingPropertiesForKeys: nil) {
                for file in contents where file.lastPathComponent == filename {
                    print("[ProjectFileManager]   Found by scanning DAWRecordings: \(file.path)")
                    return file
                }
            }
        }
        
        print("[ProjectFileManager]   NOT FOUND - audio file missing")
        return nil
    }
    
    /// Quick save - update project.json and copy any NEW audio files
    public func saveQuick(project: Project, to url: URL) async throws {
        let fm = FileManager.default
        
        var packageURL = url
        if packageURL.pathExtension != Self.projectExtension {
            packageURL = url.deletingPathExtension().appendingPathExtension(Self.projectExtension)
        }
        
        let projectFileURL = packageURL.appendingPathComponent(Self.projectFileName)
        let audioDir = packageURL.appendingPathComponent(Self.audioFolderName)
        
        // If package doesn't exist, do full save
        guard fm.fileExists(atPath: projectFileURL.path) else {
            try await save(project: project, to: packageURL)
            return
        }
        
        // Load existing manifest
        let existingData = try Data(contentsOf: projectFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let existingFile = try decoder.decode(ProjectFile.self, from: existingData)
        
        // Collect all audio references from clips
        var allAudioRefs: [AudioFileReference] = project.audioFiles
        for track in project.tracks {
            for clip in track.clips {
                if case .audio(let audioData) = clip.content {
                    if !allAudioRefs.contains(where: { $0.fileID == audioData.fileReference.fileID }) {
                        allAudioRefs.append(audioData.fileReference)
                    }
                }
            }
        }
        
        // Find NEW audio files that aren't in the existing manifest
        var updatedProject = project
        var updatedManifest = existingFile.audioFileManifest
        
        for audioRef in allAudioRefs {
            let alreadySaved = existingFile.audioFileManifest.contains { $0.fileID == audioRef.fileID }
            
            if !alreadySaved {
                // This is a NEW audio file - copy it
                let destFileName = "\(audioRef.fileID.uuidString).\(URL(fileURLWithPath: audioRef.originalPath).pathExtension.isEmpty ? "wav" : URL(fileURLWithPath: audioRef.originalPath).pathExtension)"
                let destURL = audioDir.appendingPathComponent(destFileName)
                let relativePath = "\(Self.audioFolderName)/\(destFileName)"
                
                // Try to find and copy the source file
                if let sourceURL = findAudioFile(for: audioRef), fm.fileExists(atPath: sourceURL.path) {
                    // Make sure audio directory exists
                    if !fm.fileExists(atPath: audioDir.path) {
                        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
                    }
                    
                    try fm.copyItem(at: sourceURL, to: destURL)
                    print("[ProjectFileManager] Quick save - copied NEW audio: \(sourceURL.lastPathComponent) -> \(destFileName)")
                    
                    // Add to manifest
                    updatedManifest.append(AudioFileEntry(
                        fileID: audioRef.fileID,
                        relativePath: relativePath,
                        originalPath: audioRef.originalPath,
                        checksum: nil
                    ))
                    
                    // Update or add the reference in project.audioFiles
                    if let index = updatedProject.audioFiles.firstIndex(where: { $0.fileID == audioRef.fileID }) {
                        updatedProject.audioFiles[index].relativePath = relativePath
                    } else {
                        // Add to audioFiles if not present
                        var newRef = audioRef
                        newRef.relativePath = relativePath
                        updatedProject.audioFiles.append(newRef)
                    }
                    
                    // Update clips that reference this file
                    for trackIndex in 0..<updatedProject.tracks.count {
                        for clipIndex in 0..<updatedProject.tracks[trackIndex].clips.count {
                            if case .audio(var audioData) = updatedProject.tracks[trackIndex].clips[clipIndex].content {
                                if audioData.fileReference.fileID == audioRef.fileID {
                                    audioData.fileReference.relativePath = relativePath
                                    updatedProject.tracks[trackIndex].clips[clipIndex].content = .audio(audioData)
                                }
                            }
                        }
                    }
                } else {
                    print("[ProjectFileManager] Quick save - WARNING: New audio file not found: \(audioRef.originalPath)")
                }
            }
        }
        
        // Create updated project file
        let projectFile = ProjectFile(
            version: Project.currentFormatVersion,
            project: updatedProject,
            audioFileManifest: updatedManifest,
            pluginStates: existingFile.pluginStates
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(projectFile)
        try data.write(to: projectFileURL)
        
        print("[ProjectFileManager] Quick save complete")
    }
    
    // MARK: - Loading
    
    /// Load project from a URL
    public func load(from url: URL) async throws -> Project {
        let fm = FileManager.default
        
        // Determine if it's a package or single file
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PersistenceError.fileNotFound(url)
        }
        
        let projectFileURL: URL
        let packageURL: URL
        
        if isDirectory.boolValue {
            // Project package
            packageURL = url
            projectFileURL = url.appendingPathComponent(Self.projectFileName)
        } else {
            // Single JSON file (legacy or exported)
            packageURL = url.deletingLastPathComponent()
            projectFileURL = url
        }
        
        guard fm.fileExists(atPath: projectFileURL.path) else {
            throw PersistenceError.fileNotFound(projectFileURL)
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
            
            print("[ProjectFileManager] Loading from package: \(packageURL.path)")
            print("[ProjectFileManager] Project has \(project.audioFiles.count) audio files")
            
            // Update audio file paths to be absolute (resolved against package)
            for i in 0..<project.audioFiles.count {
                let relativePath = project.audioFiles[i].relativePath
                let absolutePath = packageURL.appendingPathComponent(relativePath).path
                print("[ProjectFileManager] Audio file \(i): relative='\(relativePath)' -> absolute='\(absolutePath)'")
                print("[ProjectFileManager]   File exists: \(FileManager.default.fileExists(atPath: absolutePath))")
                project.audioFiles[i].originalPath = absolutePath
            }
            
            // Update clip references too
            for trackIndex in 0..<project.tracks.count {
                for clipIndex in 0..<project.tracks[trackIndex].clips.count {
                    if case .audio(var audioData) = project.tracks[trackIndex].clips[clipIndex].content {
                        let relativePath = audioData.fileReference.relativePath
                        let absolutePath = packageURL.appendingPathComponent(relativePath).path
                        print("[ProjectFileManager] Clip '\(project.tracks[trackIndex].clips[clipIndex].name)': relative='\(relativePath)'")
                        print("[ProjectFileManager]   -> absolute='\(absolutePath)'")
                        print("[ProjectFileManager]   File exists: \(FileManager.default.fileExists(atPath: absolutePath))")
                        audioData.fileReference.originalPath = absolutePath
                        project.tracks[trackIndex].clips[clipIndex].content = .audio(audioData)
                    }
                }
            }
            
            print("[ProjectFileManager] Loaded project from: \(url.path)")
            return project
            
        } catch {
            // Try loading as plain Project (legacy format)
            print("[ProjectFileManager] Trying legacy format...")
            return try decoder.decode(Project.self, from: data)
        }
    }
    
    /// Quick load for recent files check - just get metadata
    public func loadMetadata(from url: URL) async throws -> ProjectMetadataInfo {
        let fm = FileManager.default
        
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PersistenceError.fileNotFound(url)
        }
        
        let projectFileURL: URL
        if isDirectory.boolValue {
            projectFileURL = url.appendingPathComponent(Self.projectFileName)
        } else {
            projectFileURL = url
        }
        
        let data = try Data(contentsOf: projectFileURL)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        // Only decode the metadata portion
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            try data.write(to: url)
            
        case .midi:
            try await exportAsMIDI(project: project, to: url)
        }
    }
    
    private func exportAsMIDI(project: Project, to url: URL) async throws {
        // Build a standard MIDI file from MIDI tracks
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
    private var projectProvider: (() -> Project)?
    private var projectURL: URL?
    
    @Published public var lastAutosaveDate: Date?
    @Published public var hasUnsavedChanges: Bool = false
    
    /// Autosave interval in seconds
    public var autosaveInterval: TimeInterval = 60
    
    public init() {
        self.fileManager = ProjectFileManager()
    }
    
    public func configure(projectProvider: @escaping () -> Project) {
        self.projectProvider = projectProvider
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
        guard hasUnsavedChanges, 
              let url = projectURL,
              let project = projectProvider?() else { return }
        
        do {
            try await fileManager.saveQuick(project: project, to: url)
            lastAutosaveDate = Date()
            hasUnsavedChanges = false
            print("[Autosave] Saved at \(Date())")
        } catch {
            print("[Autosave] Failed: \(error)")
        }
    }
    
    public func markUnsavedChanges() {
        hasUnsavedChanges = true
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
