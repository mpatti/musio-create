import Foundation
import DAWCore

// MARK: - Action Executor

/// Executes tool calls from the AI by mapping them to ProjectViewModel functions
@MainActor
public final class ActionExecutor {
    
    private weak var viewModel: ProjectViewModel?
    
    public init(viewModel: ProjectViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - Execute Tool Calls
    
    public func execute(toolCalls: [ToolCall]) async -> [ToolResult] {
        var results: [ToolResult] = []
        
        for toolCall in toolCalls {
            let result = await executeAction(toolCall)
            results.append(ToolResult(toolCallId: toolCall.id, result: result))
        }
        
        return results
    }
    
    // MARK: - Execute Single Action
    
    private func executeAction(_ toolCall: ToolCall) async -> ActionResult {
        guard let viewModel = viewModel else {
            return .failure("ViewModel not available")
        }
        
        let actionName = toolCall.name
        
        print("[ActionExecutor] Executing: \(actionName)")
        
        do {
            switch actionName {
            // MARK: Track Management
            case "add_track":
                return try executeAddTrack(toolCall, viewModel: viewModel)
                
            case "delete_track":
                return try executeDeleteTrack(toolCall, viewModel: viewModel)
                
            case "rename_track":
                return try executeRenameTrack(toolCall, viewModel: viewModel)
                
            case "select_track":
                return try executeSelectTrack(toolCall, viewModel: viewModel)
                
            case "reorder_track":
                return try executeReorderTrack(toolCall, viewModel: viewModel)
                
            // MARK: Track Properties
            case "set_track_volume":
                return try executeSetTrackVolume(toolCall, viewModel: viewModel)
                
            case "set_track_pan":
                return try executeSetTrackPan(toolCall, viewModel: viewModel)
                
            case "mute_track":
                return try executeMuteTrack(toolCall, viewModel: viewModel)
                
            case "solo_track":
                return try executeSoloTrack(toolCall, viewModel: viewModel)
                
            case "arm_track":
                return try executeArmTrack(toolCall, viewModel: viewModel)
                
            // MARK: Transport
            case "play":
                viewModel.play()
                return .success("Playback started")
                
            case "stop":
                viewModel.stop()
                return .success("Playback stopped")
                
            case "pause":
                viewModel.togglePlayPause()
                return .success("Playback paused")
                
            case "record":
                viewModel.startRecording()
                return .success("Recording started")
                
            case "stop_recording":
                viewModel.stopRecording()
                return .success("Recording stopped")
                
            case "seek_to_bar":
                return try executeSeekToBar(toolCall, viewModel: viewModel)
                
            case "seek_to_beat":
                return try executeSeekToBeat(toolCall, viewModel: viewModel)
                
            // MARK: Tempo and Time Signature
            case "set_tempo":
                return try executeSetTempo(toolCall, viewModel: viewModel)
                
            case "set_time_signature":
                return try executeSetTimeSignature(toolCall, viewModel: viewModel)
                
            // MARK: Clip Operations
            case "create_midi_clip":
                return try executeCreateMIDIClip(toolCall, viewModel: viewModel)
                
            case "delete_clip":
                return try executeDeleteClip(toolCall, viewModel: viewModel)
                
            case "move_clip":
                return try executeMoveClip(toolCall, viewModel: viewModel)
                
            case "duplicate_clip":
                return try executeDuplicateClip(toolCall, viewModel: viewModel)
                
            // MARK: Selection Operations
            case "select_all_clips":
                return try executeSelectAllClips(toolCall, viewModel: viewModel)
                
            case "deselect_all":
                viewModel.deselectAllClips()
                return .success("All clips deselected")
                
            case "delete_selected":
                viewModel.deleteSelectedClips()
                return .success("Selected clips deleted")
                
            case "copy_selected":
                viewModel.copySelectedClips()
                return .success("Selected clips copied to clipboard")
                
            case "cut_selected":
                viewModel.cutSelectedClips()
                return .success("Selected clips cut to clipboard")
                
            case "paste":
                viewModel.pasteClips()
                return .success("Clips pasted from clipboard")
                
            case "duplicate_selected":
                viewModel.duplicateSelectedClips()
                return .success("Selected clips duplicated")
                
            // MARK: Time Range Operations
            case "delete_time_range":
                return try executeDeleteTimeRange(toolCall, viewModel: viewModel)
                
            case "insert_silence":
                return try executeInsertSilence(toolCall, viewModel: viewModel)
                
            // MARK: View Operations
            case "show_mixer":
                if let visible = toolCall.getBool("visible") {
                    viewModel.showMixer = visible
                    return .success(visible ? "Mixer panel shown" : "Mixer panel hidden")
                }
                return .failure("Missing 'visible' parameter")
                
            case "show_piano_roll":
                if let visible = toolCall.getBool("visible") {
                    viewModel.showPianoRoll = visible
                    return .success(visible ? "Piano roll shown" : "Piano roll hidden")
                }
                return .failure("Missing 'visible' parameter")
                
            case "open_piano_roll_for_track":
                return try executeOpenPianoRollForTrack(toolCall, viewModel: viewModel)
                
            case "set_zoom":
                if let level = toolCall.getDouble("level") {
                    viewModel.zoomLevel = max(0.25, min(4.0, level))
                    return .success("Zoom level set to \(viewModel.zoomLevel)")
                }
                return .failure("Missing 'level' parameter")
                
            // MARK: Project Operations
            case "undo":
                viewModel.undo()
                return .success("Undo performed")
                
            case "redo":
                viewModel.redo()
                return .success("Redo performed")
                
            case "get_project_info":
                return executeGetProjectInfo(viewModel: viewModel)
                
            case "list_tracks":
                return executeListTracks(viewModel: viewModel)
                
            // MARK: MIDI Routing
            case "set_track_midi_output":
                return try executeSetTrackMIDIOutput(toolCall, viewModel: viewModel)
                
            case "list_rack_instruments":
                return executeListRackInstruments(viewModel: viewModel)
                
            // MARK: Instrument Management
            case "add_rack_instrument":
                let name = toolCall.getString("name")
                viewModel.addRackInstrument()
                return .success("Added new rack instrument\(name.map { " '\($0)'" } ?? "")")
                
            case "remove_rack_instrument":
                return try executeRemoveRackInstrument(toolCall, viewModel: viewModel)
                
            case "list_available_plugins":
                return executeListAvailablePlugins(viewModel: viewModel)
                
            case "load_rack_instrument_plugin":
                return await executeLoadRackInstrumentPlugin(toolCall, viewModel: viewModel)
                
            // MARK: Track Settings
            case "set_track_color":
                return try executeSetTrackColor(toolCall, viewModel: viewModel)
                
            // MARK: Transport Extras
            case "toggle_loop":
                if let enabled = toolCall.getBool("enabled") {
                    viewModel.project.isLoopEnabled = enabled
                    return .success(enabled ? "Loop enabled" : "Loop disabled")
                }
                return .failure("Missing 'enabled' parameter")
                
            case "set_loop_region":
                return try executeSetLoopRegion(toolCall, viewModel: viewModel)
                
            case "toggle_metronome":
                if let enabled = toolCall.getBool("enabled") {
                    viewModel.transportState.isMetronomeEnabled = enabled
                    return .success(enabled ? "Metronome enabled" : "Metronome disabled")
                }
                return .failure("Missing 'enabled' parameter")
                
            // MARK: Clip Editing
            case "split_clip_at_playhead":
                viewModel.splitClipAtPlayhead()
                return .success("Split clip at playhead")
                
            case "trim_clips_to_grid":
                return try executeTrimClipsToGrid(toolCall, viewModel: viewModel)
                
            case "nudge_clips":
                if let beats = toolCall.getDouble("beats") {
                    viewModel.nudgeSelectedClips(byBeats: beats)
                    return .success("Nudged clips by \(beats) beats")
                }
                return .failure("Missing 'beats' parameter")
                
            // MARK: Markers
            case "add_marker":
                return try executeAddMarker(toolCall, viewModel: viewModel)
                
            case "delete_marker":
                return try executeDeleteMarker(toolCall, viewModel: viewModel)
                
            case "goto_marker":
                return try executeGotoMarker(toolCall, viewModel: viewModel)
                
            case "list_markers":
                return executeListMarkers(viewModel: viewModel)
                
            // MARK: Audio Operations
            case "import_audio":
                return try executeImportAudio(toolCall, viewModel: viewModel)
                
            // MARK: MIDI Note Operations
            case "add_midi_note":
                return try executeAddMIDINote(toolCall, viewModel: viewModel)
                
            case "transpose_track":
                return try executeTransposeTrack(toolCall, viewModel: viewModel)
                
            case "set_track_velocity":
                return try executeSetTrackVelocity(toolCall, viewModel: viewModel)
                
            default:
                return .failure("Unknown action: \(actionName)")
            }
        } catch {
            return .failure("Error executing \(actionName): \(error.localizedDescription)")
        }
    }
    
    // MARK: - Track Management Implementations
    
    private func executeAddTrack(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let typeStr = toolCall.getString("type") else {
            return .failure("Missing 'type' parameter")
        }
        
        let trackType: TrackType
        switch typeStr.lowercased() {
        case "midi": trackType = .midi
        case "audio": trackType = .audio
        case "instrument": trackType = .instrument
        default: return .failure("Invalid track type: \(typeStr)")
        }
        
        let name = toolCall.getString("name")
        viewModel.addTrack(type: trackType, name: name)
        
        let trackName = name ?? "\(trackType.rawValue.capitalized)"
        return .success("Added \(trackType.rawValue) track '\(trackName)'")
    }
    
    private func executeDeleteTrack(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name") else {
            return .failure("Missing 'track_name' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        viewModel.deleteTrack(id: track.id)
        return .success("Deleted track '\(track.name)'")
    }
    
    private func executeRenameTrack(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let newName = toolCall.getString("new_name") else {
            return .failure("Missing 'track_name' or 'new_name' parameter")
        }
        
        guard var track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        let oldName = track.name
        track.name = newName
        viewModel.updateTrack(track, description: "Rename Track")
        return .success("Renamed track '\(oldName)' to '\(newName)'")
    }
    
    private func executeSelectTrack(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name") else {
            return .failure("Missing 'track_name' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        viewModel.selectTrack(track.id)
        return .success("Selected track '\(track.name)'")
    }
    
    private func executeReorderTrack(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let position = toolCall.getInt("position") else {
            return .failure("Missing 'track_name' or 'position' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        let targetIndex = max(0, min(viewModel.project.tracks.count - 1, position - 1))
        viewModel.reorderTrack(trackID: track.id, toIndex: targetIndex)
        return .success("Moved track '\(track.name)' to position \(targetIndex + 1)")
    }
    
    // MARK: - Track Properties Implementations
    
    private func executeSetTrackVolume(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let volume = toolCall.getDouble("volume") else {
            return .failure("Missing 'track_name' or 'volume' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        let clampedVolume = Float(max(0, min(1, volume)))
        viewModel.setTrackVolume(id: track.id, volume: clampedVolume)
        
        let db = ProjectStateSerializer.volumeToDbString(clampedVolume)
        return .success("Set volume of '\(track.name)' to \(db)")
    }
    
    private func executeSetTrackPan(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let pan = toolCall.getDouble("pan") else {
            return .failure("Missing 'track_name' or 'pan' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        let clampedPan = Float(max(-1, min(1, pan)))
        viewModel.setTrackPan(id: track.id, pan: clampedPan)
        
        let panStr = clampedPan == 0 ? "center" : (clampedPan < 0 ? "\(Int(abs(clampedPan) * 100))% left" : "\(Int(clampedPan * 100))% right")
        return .success("Set pan of '\(track.name)' to \(panStr)")
    }
    
    private func executeMuteTrack(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let muted = toolCall.getBool("muted") else {
            return .failure("Missing 'track_name' or 'muted' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        if track.isMuted != muted {
            viewModel.toggleTrackMute(id: track.id)
        }
        return .success(muted ? "Muted '\(track.name)'" : "Unmuted '\(track.name)'")
    }
    
    private func executeSoloTrack(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let solo = toolCall.getBool("solo") else {
            return .failure("Missing 'track_name' or 'solo' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        if track.isSolo != solo {
            viewModel.toggleTrackSolo(id: track.id)
        }
        return .success(solo ? "Soloed '\(track.name)'" : "Unsoloed '\(track.name)'")
    }
    
    private func executeArmTrack(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let armed = toolCall.getBool("armed") else {
            return .failure("Missing 'track_name' or 'armed' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        if track.isArmed != armed {
            viewModel.toggleTrackArm(id: track.id)
        }
        return .success(armed ? "Armed '\(track.name)' for recording" : "Disarmed '\(track.name)'")
    }
    
    // MARK: - Transport Implementations
    
    private func executeSeekToBar(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let bar = toolCall.getInt("bar") else {
            return .failure("Missing 'bar' parameter")
        }
        
        let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
        let beat = Double((bar - 1) * beatsPerBar)
        viewModel.seekTo(beat: max(0, beat))
        return .success("Moved playhead to bar \(bar)")
    }
    
    private func executeSeekToBeat(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let beat = toolCall.getDouble("beat") else {
            return .failure("Missing 'beat' parameter")
        }
        
        viewModel.seekTo(beat: max(0, beat))
        return .success("Moved playhead to beat \(beat)")
    }
    
    // MARK: - Tempo and Time Signature
    
    private func executeSetTempo(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let bpm = toolCall.getDouble("bpm") else {
            return .failure("Missing 'bpm' parameter")
        }
        
        let clampedBpm = max(20, min(999, bpm))
        viewModel.setTempo(clampedBpm)
        return .success("Set tempo to \(Int(clampedBpm)) BPM")
    }
    
    private func executeSetTimeSignature(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let numerator = toolCall.getInt("numerator"),
              let denominator = toolCall.getInt("denominator") else {
            return .failure("Missing 'numerator' or 'denominator' parameter")
        }
        
        viewModel.setTimeSignature(numerator: numerator, denominator: denominator)
        return .success("Set time signature to \(numerator)/\(denominator)")
    }
    
    // MARK: - Clip Operations
    
    private func executeCreateMIDIClip(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let startBar = toolCall.getInt("start_bar"),
              let lengthBars = toolCall.getDouble("length_bars") else {
            return .failure("Missing required parameters")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        guard track.type == .midi || track.type == .instrument else {
            return .failure("Track '\(trackName)' is not a MIDI track")
        }
        
        let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
        let startBeat = Double((startBar - 1) * beatsPerBar)
        let durationBeats = lengthBars * Double(beatsPerBar)
        
        let position = TimePosition(beats: startBeat, tempo: viewModel.transportState.tempo.bpm)
        viewModel.createMIDIClip(on: track.id, at: position, duration: durationBeats)
        
        return .success("Created MIDI clip on '\(track.name)' at bar \(startBar), length \(lengthBars) bars")
    }
    
    private func executeDeleteClip(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name") else {
            return .failure("Missing 'track_name' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        let clipIndex = toolCall.getInt("clip_index") ?? 0
        
        guard clipIndex >= 0 && clipIndex < track.clips.count else {
            return .failure("Clip index \(clipIndex) out of range (track has \(track.clips.count) clips)")
        }
        
        let clip = track.clips[clipIndex]
        viewModel.deleteClip(id: clip.id, from: track.id)
        return .success("Deleted clip '\(clip.name)' from '\(track.name)'")
    }
    
    private func executeMoveClip(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let clipIndex = toolCall.getInt("clip_index"),
              let toBar = toolCall.getInt("to_bar") else {
            return .failure("Missing required parameters")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        guard clipIndex >= 0 && clipIndex < track.clips.count else {
            return .failure("Clip index \(clipIndex) out of range")
        }
        
        let clip = track.clips[clipIndex]
        let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
        let toBeat = Double((toBar - 1) * beatsPerBar)
        
        viewModel.moveClip(clip.id, on: track.id, toBeat: toBeat)
        return .success("Moved clip to bar \(toBar)")
    }
    
    private func executeDuplicateClip(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let clipIndex = toolCall.getInt("clip_index"),
              let toBar = toolCall.getInt("to_bar") else {
            return .failure("Missing required parameters")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        guard clipIndex >= 0 && clipIndex < track.clips.count else {
            return .failure("Clip index \(clipIndex) out of range")
        }
        
        let clip = track.clips[clipIndex]
        let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
        let toBeat = Double((toBar - 1) * beatsPerBar)
        
        viewModel.duplicateClip(clip.id, on: track.id, toBeat: toBeat)
        return .success("Duplicated clip to bar \(toBar)")
    }
    
    // MARK: - Selection Operations
    
    private func executeSelectAllClips(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name") else {
            return .failure("Missing 'track_name' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        viewModel.selectTrack(track.id)
        viewModel.selectAllClipsOnTrack()
        return .success("Selected all \(track.clips.count) clips on '\(track.name)'")
    }
    
    // MARK: - Time Range Operations
    
    private func executeDeleteTimeRange(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let startBar = toolCall.getInt("start_bar"),
              let endBar = toolCall.getInt("end_bar") else {
            return .failure("Missing 'start_bar' or 'end_bar' parameter")
        }
        
        let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
        let startBeat = Double((startBar - 1) * beatsPerBar)
        let endBeat = Double((endBar - 1) * beatsPerBar)
        
        viewModel.deleteTimeRange(startBeat: startBeat, endBeat: endBeat)
        return .success("Deleted bars \(startBar) to \(endBar)")
    }
    
    private func executeInsertSilence(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let atBar = toolCall.getInt("at_bar"),
              let lengthBars = toolCall.getDouble("length_bars") else {
            return .failure("Missing 'at_bar' or 'length_bars' parameter")
        }
        
        let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
        let atBeat = Double((atBar - 1) * beatsPerBar)
        let durationBeats = lengthBars * Double(beatsPerBar)
        
        viewModel.insertSilence(atBeat: atBeat, durationBeats: durationBeats)
        return .success("Inserted \(lengthBars) bars of silence at bar \(atBar)")
    }
    
    // MARK: - View Operations
    
    private func executeOpenPianoRollForTrack(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name") else {
            return .failure("Missing 'track_name' parameter")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        guard track.type == .midi || track.type == .instrument else {
            return .failure("Track '\(trackName)' is not a MIDI track")
        }
        
        viewModel.selectTrack(track.id)
        viewModel.showPianoRoll = true
        return .success("Opened piano roll for '\(track.name)'")
    }
    
    // MARK: - Project Info
    
    private func executeGetProjectInfo(viewModel: ProjectViewModel) -> ActionResult {
        let info = ProjectStateSerializer.serialize(
            project: viewModel.project,
            selectedTrackID: viewModel.selectedTrackID,
            selectedClipIDs: viewModel.selectedClipIDs,
            isPlaying: viewModel.transportState.isPlaying,
            isRecording: viewModel.isRecording,
            playheadBeat: viewModel.transportState.playheadBeats
        )
        return .success(info)
    }
    
    private func executeListTracks(viewModel: ProjectViewModel) -> ActionResult {
        let list = ProjectStateSerializer.serializeTrackList(project: viewModel.project)
        return .success(list)
    }
    
    // MARK: - MIDI Routing
    
    private func executeSetTrackMIDIOutput(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let destination = toolCall.getString("destination") else {
            return .failure("Missing 'track_name' or 'destination' parameter")
        }
        
        guard let trackIndex = viewModel.project.trackIndexByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        var track = viewModel.project.tracks[trackIndex]
        
        guard track.type == .midi || track.type == .instrument else {
            return .failure("Track '\(trackName)' is not a MIDI track")
        }
        
        if destination.lowercased() == "track" || destination.lowercased() == "track instrument" {
            track.midiOutput = .trackInstrument
            viewModel.project.tracks[trackIndex] = track
            return .success("Set '\(track.name)' MIDI output to track instrument")
        } else {
            // Look for rack instrument by name
            guard let rackInstrument = viewModel.project.vRack.instruments.first(where: {
                $0.name.lowercased() == destination.lowercased()
            }) else {
                return .failure("Rack instrument '\(destination)' not found. Use 'list_rack_instruments' to see available options.")
            }
            
            let channel = UInt8(toolCall.getInt("channel") ?? 1)
            track.midiOutput = .rackInstrument(id: rackInstrument.id, channel: channel)
            viewModel.project.tracks[trackIndex] = track
            return .success("Set '\(track.name)' MIDI output to '\(rackInstrument.name)' channel \(channel)")
        }
    }
    
    private func executeListRackInstruments(viewModel: ProjectViewModel) -> ActionResult {
        let instruments = viewModel.project.vRack.instruments
        if instruments.isEmpty {
            return .success("V-Rack is empty. Use 'add_rack_instrument' to add one.")
        }
        
        var lines = ["V-Rack Instruments:"]
        for (index, inst) in instruments.enumerated() {
            let pluginName = inst.pluginSlot.pluginID?.name ?? "Empty"
            let muted = inst.isMuted ? " [muted]" : ""
            lines.append("  \(index + 1). \(inst.name) - \(pluginName)\(muted)")
        }
        return .success(lines.joined(separator: "\n"))
    }
    
    // MARK: - Instrument Management
    
    private func executeRemoveRackInstrument(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let name = toolCall.getString("name") else {
            return .failure("Missing 'name' parameter")
        }
        
        guard let instrument = viewModel.project.vRack.instruments.first(where: {
            $0.name.lowercased() == name.lowercased()
        }) else {
            return .failure("Rack instrument '\(name)' not found")
        }
        
        viewModel.removeRackInstrument(instrument.id)
        return .success("Removed rack instrument '\(instrument.name)'")
    }
    
    private func executeListAvailablePlugins(viewModel: ProjectViewModel) -> ActionResult {
        let plugins = viewModel.availableInstrumentPlugins
        if plugins.isEmpty {
            return .success("No instrument plugins available")
        }
        
        var lines = ["Available Instrument Plugins:"]
        for plugin in plugins {
            lines.append("  - \(plugin.name) (\(plugin.manufacturer))")
        }
        return .success(lines.joined(separator: "\n"))
    }
    
    private func executeLoadRackInstrumentPlugin(_ toolCall: ToolCall, viewModel: ProjectViewModel) async -> ActionResult {
        guard let rackName = toolCall.getString("rack_name"),
              let pluginName = toolCall.getString("plugin_name") else {
            return .failure("Missing 'rack_name' or 'plugin_name' parameter")
        }
        
        guard let rackInstrument = viewModel.project.vRack.instruments.first(where: {
            $0.name.lowercased() == rackName.lowercased()
        }) else {
            return .failure("Rack instrument '\(rackName)' not found")
        }
        
        guard let pluginID = viewModel.availableInstrumentPlugins.first(where: {
            $0.name.lowercased().contains(pluginName.lowercased())
        }) else {
            return .failure("Plugin '\(pluginName)' not found. Use 'list_available_plugins' to see options.")
        }
        
        await viewModel.loadRackInstrumentPlugin(rackInstrument.id, pluginID: pluginID)
        return .success("Loaded '\(pluginID.name)' into '\(rackInstrument.name)'")
    }
    
    // MARK: - Track Settings
    
    private func executeSetTrackColor(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let colorName = toolCall.getString("color") else {
            return .failure("Missing 'track_name' or 'color' parameter")
        }
        
        guard let trackIndex = viewModel.project.trackIndexByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        let color: TrackColor
        switch colorName.lowercased() {
        case "red": color = .red
        case "orange": color = .orange
        case "yellow": color = .yellow
        case "green": color = .green
        case "blue": color = .blue
        case "purple": color = .purple
        case "pink": color = .pink
        case "gray", "grey": color = .gray
        default: return .failure("Invalid color '\(colorName)'. Use: red, orange, yellow, green, blue, purple, pink, gray")
        }
        
        var track = viewModel.project.tracks[trackIndex]
        track.color = color
        viewModel.project.tracks[trackIndex] = track
        return .success("Set '\(track.name)' color to \(colorName)")
    }
    
    // MARK: - Loop Region
    
    private func executeSetLoopRegion(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let startBar = toolCall.getInt("start_bar"),
              let endBar = toolCall.getInt("end_bar") else {
            return .failure("Missing 'start_bar' or 'end_bar' parameter")
        }
        
        let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
        let startBeat = Double((startBar - 1) * beatsPerBar)
        let endBeat = Double((endBar - 1) * beatsPerBar)
        
        let startPos = TimePosition(beats: startBeat, tempo: viewModel.transportState.tempo.bpm)
        let durationPos = TimePosition(beats: endBeat - startBeat, tempo: viewModel.transportState.tempo.bpm)
        
        viewModel.project.loopRegion = TimeRange(start: startPos, duration: durationPos)
        viewModel.project.isLoopEnabled = true
        
        return .success("Set loop region from bar \(startBar) to bar \(endBar)")
    }
    
    // MARK: - Clip Editing
    
    private func executeTrimClipsToGrid(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        let resolution = toolCall.getString("resolution") ?? "1"
        
        let beatResolution: Double
        switch resolution {
        case "1/4": beatResolution = 0.25
        case "1/2": beatResolution = 0.5
        case "1": beatResolution = 1.0
        case "2": beatResolution = 2.0
        case "4": beatResolution = 4.0
        default: beatResolution = 1.0
        }
        
        viewModel.trimSelectedClipsToGrid(beatResolution: beatResolution)
        return .success("Trimmed clips to \(resolution) beat grid")
    }
    
    // MARK: - Markers
    
    private func executeAddMarker(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let bar = toolCall.getInt("bar") else {
            return .failure("Missing 'bar' parameter")
        }
        
        let name = toolCall.getString("name") ?? "Marker"
        let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
        let beat = Double((bar - 1) * beatsPerBar)
        
        let marker = Marker(
            name: name,
            beatPosition: beat,
            color: .blue
        )
        viewModel.project.markers.append(marker)
        
        return .success("Added marker '\(name)' at bar \(bar)")
    }
    
    private func executeDeleteMarker(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        if let name = toolCall.getString("name") {
            if let index = viewModel.project.markers.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                let removed = viewModel.project.markers.remove(at: index)
                return .success("Deleted marker '\(removed.name)'")
            }
            return .failure("Marker '\(name)' not found")
        } else if let bar = toolCall.getInt("bar") {
            let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
            let beat = Double((bar - 1) * beatsPerBar)
            
            if let index = viewModel.project.markers.firstIndex(where: { abs($0.beatPosition - beat) < 0.1 }) {
                let removed = viewModel.project.markers.remove(at: index)
                return .success("Deleted marker '\(removed.name)' at bar \(bar)")
            }
            return .failure("No marker found at bar \(bar)")
        }
        return .failure("Provide either 'name' or 'bar' parameter")
    }
    
    private func executeGotoMarker(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let name = toolCall.getString("name") else {
            return .failure("Missing 'name' parameter")
        }
        
        guard let marker = viewModel.project.markers.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            return .failure("Marker '\(name)' not found")
        }
        
        viewModel.seekTo(beat: marker.beatPosition)
        return .success("Moved playhead to marker '\(marker.name)'")
    }
    
    private func executeListMarkers(viewModel: ProjectViewModel) -> ActionResult {
        let markers = viewModel.project.markers.sorted { $0.beatPosition < $1.beatPosition }
        if markers.isEmpty {
            return .success("No markers in project")
        }
        
        let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
        var lines = ["Markers:"]
        for marker in markers {
            let bar = Int(marker.beatPosition / Double(beatsPerBar)) + 1
            lines.append("  - '\(marker.name)' at bar \(bar)")
        }
        return .success(lines.joined(separator: "\n"))
    }
    
    // MARK: - Audio Import
    
    private func executeImportAudio(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let filePath = toolCall.getString("file_path"),
              let startBar = toolCall.getInt("start_bar") else {
            return .failure("Missing required parameters")
        }
        
        guard let track = viewModel.project.trackByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        guard track.type == .audio else {
            return .failure("Track '\(trackName)' is not an audio track")
        }
        
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            return .failure("File not found: \(filePath)")
        }
        
        let beatsPerBar = viewModel.transportState.timeSignature.beatsPerBar
        let startBeat = Double((startBar - 1) * beatsPerBar)
        
        viewModel.importAudioFile(from: url, atBeat: startBeat, onTrack: track.id)
        return .success("Imported audio to '\(track.name)' at bar \(startBar)")
    }
    
    // MARK: - MIDI Note Operations
    
    private func executeAddMIDINote(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let pitch = toolCall.getInt("pitch"),
              let startBeat = toolCall.getDouble("start_beat"),
              let duration = toolCall.getDouble("duration") else {
            return .failure("Missing required parameters")
        }
        
        guard let trackIndex = viewModel.project.trackIndexByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        var track = viewModel.project.tracks[trackIndex]
        guard track.type == .midi || track.type == .instrument else {
            return .failure("Track '\(trackName)' is not a MIDI track")
        }
        
        let velocity = UInt8(toolCall.getInt("velocity") ?? 100)
        let clampedPitch = UInt8(max(0, min(127, pitch)))
        let clampedVelocity = max(1, min(127, velocity))
        
        // Find or create a clip that contains this beat
        let clipIndex = track.clips.firstIndex { clip in
            let clipStart = clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
            let clipEnd = clipStart + clip.timeRange.duration.beats(atTempo: viewModel.transportState.tempo.bpm)
            return startBeat >= clipStart && startBeat < clipEnd
        }
        
        if let index = clipIndex {
            // Add note to existing clip
            var clip = track.clips[index]
            if case .midi(var midiData) = clip.content {
                let clipStart = clip.timeRange.start.beats(atTempo: viewModel.transportState.tempo.bpm)
                let relativeStart = startBeat - clipStart
                
                let noteEvent = MIDIEvent(
                    beatPosition: relativeStart,
                    type: .note(NoteData(pitch: clampedPitch, velocity: clampedVelocity, duration: duration)),
                    channel: 0
                )
                midiData.events.append(noteEvent)
                clip.content = .midi(midiData)
                track.clips[index] = clip
                viewModel.project.tracks[trackIndex] = track
                return .success("Added note (pitch \(pitch)) at beat \(startBeat)")
            }
        }
        
        return .failure("No MIDI clip found at beat \(startBeat). Create a clip first.")
    }
    
    private func executeTransposeTrack(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let semitones = toolCall.getInt("semitones") else {
            return .failure("Missing 'track_name' or 'semitones' parameter")
        }
        
        guard let trackIndex = viewModel.project.trackIndexByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        var track = viewModel.project.tracks[trackIndex]
        var transposedCount = 0
        
        for clipIndex in track.clips.indices {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                for eventIndex in midiData.events.indices {
                    if case .note(var noteData) = midiData.events[eventIndex].type {
                        let newPitch = Int(noteData.pitch) + semitones
                        noteData.pitch = UInt8(max(0, min(127, newPitch)))
                        midiData.events[eventIndex].type = .note(noteData)
                        transposedCount += 1
                    }
                }
                track.clips[clipIndex].content = .midi(midiData)
            }
        }
        
        viewModel.project.tracks[trackIndex] = track
        let direction = semitones > 0 ? "up" : "down"
        return .success("Transposed \(transposedCount) notes \(direction) by \(abs(semitones)) semitones")
    }
    
    private func executeSetTrackVelocity(_ toolCall: ToolCall, viewModel: ProjectViewModel) throws -> ActionResult {
        guard let trackName = toolCall.getString("track_name"),
              let velocity = toolCall.getInt("velocity") else {
            return .failure("Missing 'track_name' or 'velocity' parameter")
        }
        
        guard let trackIndex = viewModel.project.trackIndexByName(trackName) else {
            return .failure("Track '\(trackName)' not found")
        }
        
        let clampedVelocity = UInt8(max(1, min(127, velocity)))
        var track = viewModel.project.tracks[trackIndex]
        var modifiedCount = 0
        
        for clipIndex in track.clips.indices {
            if case .midi(var midiData) = track.clips[clipIndex].content {
                for eventIndex in midiData.events.indices {
                    if case .note(var noteData) = midiData.events[eventIndex].type {
                        noteData.velocity = clampedVelocity
                        midiData.events[eventIndex].type = .note(noteData)
                        modifiedCount += 1
                    }
                }
                track.clips[clipIndex].content = .midi(midiData)
            }
        }
        
        viewModel.project.tracks[trackIndex] = track
        return .success("Set velocity to \(clampedVelocity) for \(modifiedCount) notes")
    }
}
