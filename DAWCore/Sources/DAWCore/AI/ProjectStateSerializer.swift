import Foundation

// MARK: - Project State Serializer

/// Converts project state to a concise text format for AI context
public struct ProjectStateSerializer {
    
    /// Serialize the full project state to text
    public static func serialize(
        project: Project,
        selectedTrackID: TrackID?,
        selectedClipIDs: Set<ClipID>,
        isPlaying: Bool,
        isRecording: Bool,
        playheadBeat: Double
    ) -> String {
        var lines: [String] = []
        
        // Project header
        lines.append("# Project State")
        lines.append("")
        lines.append("**Project:** \(project.name)")
        lines.append("**Tempo:** \(Int(project.tempo.bpm)) BPM")
        lines.append("**Time Signature:** \(project.timeSignature.beatsPerBar)/\(project.timeSignature.denominator)")
        
        // Transport state
        let bar = Int(playheadBeat / Double(project.timeSignature.beatsPerBar)) + 1
        let beat = Int(playheadBeat.truncatingRemainder(dividingBy: Double(project.timeSignature.beatsPerBar))) + 1
        lines.append("**Playhead:** Bar \(bar), Beat \(beat) (beat \(String(format: "%.1f", playheadBeat)))")
        
        var transportStatus: [String] = []
        if isPlaying { transportStatus.append("Playing") }
        if isRecording { transportStatus.append("Recording") }
        if transportStatus.isEmpty { transportStatus.append("Stopped") }
        lines.append("**Transport:** \(transportStatus.joined(separator: ", "))")
        
        // Loop region
        if project.isLoopEnabled, let loop = project.loopRegion {
            let loopStartBar = Int(loop.start.beats(atTempo: project.tempo.bpm) / Double(project.timeSignature.beatsPerBar)) + 1
            let loopEndBar = Int((loop.start.beats(atTempo: project.tempo.bpm) + loop.duration.beats(atTempo: project.tempo.bpm)) / Double(project.timeSignature.beatsPerBar)) + 1
            lines.append("**Loop:** Bars \(loopStartBar) - \(loopEndBar)")
        }
        
        lines.append("")
        
        // Tracks
        lines.append("## Tracks (\(project.tracks.count) total)")
        lines.append("")
        
        for (index, track) in project.tracks.enumerated() {
            let trackLine = formatTrack(
                track: track,
                index: index + 1,
                isSelected: track.id == selectedTrackID,
                selectedClipIDs: selectedClipIDs,
                tempo: project.tempo.bpm
            )
            lines.append(trackLine)
        }
        
        // Selected clips summary
        if !selectedClipIDs.isEmpty {
            lines.append("")
            lines.append("**Selected Clips:** \(selectedClipIDs.count)")
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Format a single track as a text line
    private static func formatTrack(
        track: Track,
        index: Int,
        isSelected: Bool,
        selectedClipIDs: Set<ClipID>,
        tempo: Double
    ) -> String {
        var parts: [String] = []
        
        // Index and name
        let selectedMarker = isSelected ? " [SELECTED]" : ""
        parts.append("\(index). **\(track.name)**\(selectedMarker)")
        
        // Type
        parts.append("(\(track.type.rawValue.capitalized))")
        
        // Instrument if present
        if let instrument = track.instrumentSlot, let pluginID = instrument.pluginID {
            parts.append("[\(pluginID.name)]")
        }
        
        // Clip count and info
        let clipCount = track.clips.count
        if clipCount > 0 {
            let selectedOnTrack = track.clips.filter { selectedClipIDs.contains($0.id) }.count
            var clipInfo = "\(clipCount) clip\(clipCount == 1 ? "" : "s")"
            if selectedOnTrack > 0 {
                clipInfo += " (\(selectedOnTrack) selected)"
            }
            parts.append("- \(clipInfo)")
        } else {
            parts.append("- empty")
        }
        
        // Status flags
        var flags: [String] = []
        if track.isMuted { flags.append("muted") }
        if track.isSolo { flags.append("solo") }
        if track.isArmed { flags.append("armed") }
        
        if !flags.isEmpty {
            parts.append("[\(flags.joined(separator: ", "))]")
        }
        
        // Volume if not default
        let volumeDb = 20 * log10(track.volume)
        if abs(volumeDb - (-2)) > 0.5 {  // Not close to default -2dB
            parts.append(String(format: "%.1fdB", volumeDb))
        }
        
        return parts.joined(separator: " ")
    }
    
    /// Serialize just the track list (for quick reference)
    public static func serializeTrackList(project: Project) -> String {
        var lines: [String] = ["Tracks:"]
        
        for (index, track) in project.tracks.enumerated() {
            var status: [String] = []
            if track.isMuted { status.append("M") }
            if track.isSolo { status.append("S") }
            if track.isArmed { status.append("R") }
            
            let statusStr = status.isEmpty ? "" : " [\(status.joined())]"
            lines.append("  \(index + 1). \(track.name) (\(track.type.rawValue))\(statusStr)")
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Serialize clip details for a specific track
    public static func serializeTrackClips(track: Track, tempo: Double, beatsPerBar: Int) -> String {
        guard !track.clips.isEmpty else {
            return "Track '\(track.name)' has no clips."
        }
        
        var lines: [String] = ["Clips on '\(track.name)':"]
        
        for (index, clip) in track.clips.enumerated() {
            let startBeat = clip.timeRange.start.beats(atTempo: tempo)
            let startBar = Int(startBeat / Double(beatsPerBar)) + 1
            let durationBeats = clip.timeRange.duration.beats(atTempo: tempo)
            let durationBars = durationBeats / Double(beatsPerBar)
            
            var typeInfo = ""
            switch clip.content {
            case .midi(let data):
                let noteCount = data.events.filter { if case .note = $0.type { return true }; return false }.count
                typeInfo = "MIDI, \(noteCount) notes"
            case .audio:
                typeInfo = "Audio"
            case .empty:
                typeInfo = "Empty"
            }
            
            lines.append("  \(index). '\(clip.name)' - Bar \(startBar), \(String(format: "%.1f", durationBars)) bars (\(typeInfo))")
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Convert volume (0-1) to dB string
    public static func volumeToDbString(_ volume: Float) -> String {
        if volume <= 0 { return "-∞ dB" }
        let db = 20 * log10(volume)
        return String(format: "%.1f dB", db)
    }
    
    /// Convert dB to linear volume (0-1)
    public static func dbToVolume(_ db: Float) -> Float {
        return pow(10, db / 20)
    }
}

// MARK: - Convenience Extensions

extension Project {
    /// Get a track by name (case-insensitive)
    public func trackByName(_ name: String) -> Track? {
        tracks.first { $0.name.lowercased() == name.lowercased() }
    }
    
    /// Get track index by name
    public func trackIndexByName(_ name: String) -> Int? {
        tracks.firstIndex { $0.name.lowercased() == name.lowercased() }
    }
}
