import Foundation
import AVFoundation
import AudioToolbox
import Combine

// MARK: - Legacy AVAudioEngine Backend

/// Legacy backend that wraps the existing AudioEngine implementation
/// This provides backward compatibility while allowing migration to Core Audio
@MainActor
public final class LegacyAVAudioEngineBackend: AudioBackend {
    
    // MARK: - Properties
    
    /// The underlying AVAudioEngine
    private let engine: AVAudioEngine
    
    /// Track nodes for audio routing
    private var trackNodes: [TrackID: LegacyTrackNode] = [:]
    
    /// Instruments loaded on tracks
    private var trackInstruments: [TrackID: LegacyInstrument] = [:]
    
    /// Mixer nodes for sample rate conversion
    private var instrumentMixers: [TrackID: AVAudioMixerNode] = [:]
    
    /// Master mixer
    private let masterMixer: AVAudioMixerNode
    
    /// Scheduled MIDI events for playback
    private var scheduledMIDIEvents: [ScheduledMIDIEvent] = []
    
    /// Active notes (for note-off tracking)
    private var activeNotes: [(trackID: TrackID, pitch: UInt8, channel: UInt8, endSample: Int64)] = []
    
    /// Audio players for clips
    private var audioPlayers: [URL: AVAudioPlayer] = [:]
    
    /// Scheduled audio clips
    private var scheduledClips: [ScheduledAudioClip] = []
    
    /// Metronome
    private var metronomeEnabled: Bool = false
    private var metronomeVolumeValue: Float = 0.7
    private var metronomePlayer: AVAudioPlayerNode?
    private var clickBuffer: AVAudioPCMBuffer?
    private var accentBuffer: AVAudioPCMBuffer?
    private var scheduledClicks: [(samplePosition: Int64, isAccent: Bool)] = []
    
    /// MIDI processing queue
    private let midiProcessingQueue = DispatchQueue(label: "com.musio.legacy-midi", qos: .userInteractive)
    
    /// Timing tap installed
    private var timingTapInstalled = false
    
    /// State
    private var _isPlaying: Bool = false
    private var _currentSamplePosition: Int64 = 0
    private var playbackStartSample: Int64 = 0
    private var playbackStartHostTime: UInt64 = 0
    private var _masterVolume: Float = 1.0
    
    // MARK: - AudioBackend Protocol Properties
    
    public var isRunning: Bool {
        engine.isRunning
    }
    
    public var sampleRate: Double {
        engine.outputNode.outputFormat(forBus: 0).sampleRate
    }
    
    public var bufferSize: UInt32 {
        512 // Default, could be made configurable
    }
    
    public var currentSamplePosition: Int64 {
        _currentSamplePosition
    }
    
    public var isPlaying: Bool {
        _isPlaying
    }
    
    public var masterVolume: Float {
        get { _masterVolume }
    }
    
    // MARK: - Initialization
    
    public init() {
        self.engine = AVAudioEngine()
        self.masterMixer = engine.mainMixerNode
        
        setupEngine()
        setupMetronome()
    }
    
    private func setupEngine() {
        // Access input/output to prepare hardware
        _ = engine.inputNode
        _ = engine.outputNode
        engine.prepare()
        print("[LegacyBackend] Engine prepared, sample rate: \(sampleRate)")
    }
    
    private func setupMetronome() {
        metronomePlayer = AVAudioPlayerNode()
        if let player = metronomePlayer {
            engine.attach(player)
            engine.connect(player, to: masterMixer, format: nil)
        }
        
        // Generate click buffers
        clickBuffer = generateClickBuffer(frequency: 1000, duration: 0.02, volume: 0.8)
        accentBuffer = generateClickBuffer(frequency: 1500, duration: 0.03, volume: 1.0)
    }
    
    private func generateClickBuffer(frequency: Double, duration: Double, volume: Float) -> AVAudioPCMBuffer? {
        let sr: Double = 44100
        let frameCount = AVAudioFrameCount(sr * duration)
        
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        
        buffer.frameLength = frameCount
        
        guard let left = buffer.floatChannelData?[0],
              let right = buffer.floatChannelData?[1] else {
            return nil
        }
        
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sr
            let envelope = exp(-time * 50)
            let sample = Float(sin(2.0 * .pi * frequency * time) * envelope * Double(volume))
            left[frame] = sample
            right[frame] = sample
        }
        
        return buffer
    }
    
    // MARK: - Lifecycle
    
    public func start() throws {
        guard !engine.isRunning else { return }
        try engine.start()
        print("[LegacyBackend] Engine started")
    }
    
    public func stop() {
        engine.stop()
        _isPlaying = false
        print("[LegacyBackend] Engine stopped")
    }
    
    // MARK: - Track Management
    
    public func createTrack(id: TrackID) throws {
        guard trackNodes[id] == nil else { return }
        
        let trackNode = LegacyTrackNode(
            inputMixer: AVAudioMixerNode(),
            gainNode: AVAudioMixerNode(),
            pannerNode: AVAudioMixerNode(),
            outputMixer: AVAudioMixerNode()
        )
        
        // Attach nodes
        engine.attach(trackNode.inputMixer)
        engine.attach(trackNode.gainNode)
        engine.attach(trackNode.pannerNode)
        engine.attach(trackNode.outputMixer)
        
        // Connect chain
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.connect(trackNode.inputMixer, to: trackNode.gainNode, format: format)
        engine.connect(trackNode.gainNode, to: trackNode.pannerNode, format: format)
        engine.connect(trackNode.pannerNode, to: trackNode.outputMixer, format: format)
        engine.connect(trackNode.outputMixer, to: masterMixer, format: format)
        
        trackNodes[id] = trackNode
        print("[LegacyBackend] Created track node for \(id.rawValue)")
    }
    
    public func removeTrack(id: TrackID) {
        guard let trackNode = trackNodes[id] else { return }
        
        // Disconnect and detach
        engine.disconnectNodeOutput(trackNode.inputMixer)
        engine.disconnectNodeOutput(trackNode.gainNode)
        engine.disconnectNodeOutput(trackNode.pannerNode)
        engine.disconnectNodeOutput(trackNode.outputMixer)
        
        engine.detach(trackNode.inputMixer)
        engine.detach(trackNode.gainNode)
        engine.detach(trackNode.pannerNode)
        engine.detach(trackNode.outputMixer)
        
        trackNodes.removeValue(forKey: id)
        trackInstruments.removeValue(forKey: id)
        
        print("[LegacyBackend] Removed track \(id.rawValue)")
    }
    
    public func setTrackVolume(_ volume: Float, for trackID: TrackID) {
        trackNodes[trackID]?.outputMixer.outputVolume = volume
    }
    
    public func setTrackPan(_ pan: Float, for trackID: TrackID) {
        trackNodes[trackID]?.pannerNode.pan = pan
    }
    
    public func setTrackMute(_ muted: Bool, for trackID: TrackID) {
        if let node = trackNodes[trackID] {
            node.outputMixer.outputVolume = muted ? 0 : 1.0
        }
    }
    
    // MARK: - Plugin Hosting
    
    public func loadInstrument(
        _ description: AudioComponentDescription,
        for trackID: TrackID
    ) async throws -> AudioUnit {
        // Use AVAudioUnit for legacy compatibility
        let audioUnit = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAudioUnit, Error>) in
            AVAudioUnit.instantiate(with: description, options: []) { unit, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let unit = unit {
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(throwing: AudioBackendError.pluginLoadFailed("Unit is nil"))
                }
            }
        }
        
        // Attach and connect
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        
        engine.attach(audioUnit)
        
        // Create converter mixer for sample rate conversion
        let converterMixer = AVAudioMixerNode()
        engine.attach(converterMixer)
        instrumentMixers[trackID] = converterMixer
        
        let auFormat = audioUnit.outputFormat(forBus: 0)
        let engineFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        engine.connect(audioUnit, to: converterMixer, format: auFormat)
        
        if let trackNode = trackNodes[trackID] {
            engine.connect(converterMixer, to: trackNode.inputMixer, format: engineFormat)
        }
        
        if wasRunning { try? engine.start() }
        
        trackInstruments[trackID] = .avAudioUnit(audioUnit)
        
        print("[LegacyBackend] Loaded instrument for track \(trackID.rawValue)")
        return audioUnit.audioUnit
    }
    
    public func loadEffect(
        _ description: AudioComponentDescription,
        for trackID: TrackID,
        slot: Int
    ) async throws -> AudioUnit {
        // Similar to loadInstrument but for effects
        let audioUnit = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAudioUnit, Error>) in
            AVAudioUnit.instantiate(with: description, options: []) { unit, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let unit = unit {
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(throwing: AudioBackendError.pluginLoadFailed("Unit is nil"))
                }
            }
        }
        
        // For effects, we'd insert into the track's effect chain
        // This is simplified for now
        engine.attach(audioUnit)
        
        print("[LegacyBackend] Loaded effect at slot \(slot) for track \(trackID.rawValue)")
        return audioUnit.audioUnit
    }
    
    public func unloadPlugin(for trackID: TrackID, slot: Int) {
        // Remove the plugin from the track
        if let instrument = trackInstruments[trackID] {
            switch instrument {
            case .avAudioUnit(let unit):
                engine.disconnectNodeOutput(unit)
                engine.detach(unit)
            case .sampler(let sampler):
                engine.disconnectNodeOutput(sampler)
                engine.detach(sampler)
            }
            trackInstruments.removeValue(forKey: trackID)
        }
        
        if let mixer = instrumentMixers[trackID] {
            engine.disconnectNodeOutput(mixer)
            engine.detach(mixer)
            instrumentMixers.removeValue(forKey: trackID)
        }
    }
    
    public func getInstrumentAudioUnit(for trackID: TrackID) -> AudioUnit? {
        switch trackInstruments[trackID] {
        case .avAudioUnit(let unit):
            return unit.audioUnit
        case .sampler(let sampler):
            return sampler.audioUnit
        case .none:
            return nil
        }
    }
    
    // MARK: - MIDI
    
    public func scheduleMIDIEvent(_ event: ScheduledMIDIEvent) {
        scheduledMIDIEvents.append(event)
    }
    
    public func sendImmediateMIDI(status: UInt8, data1: UInt8, data2: UInt8, to trackID: TrackID) {
        guard let instrument = trackInstruments[trackID] else { return }
        
        let audioUnit: AudioUnit
        switch instrument {
        case .avAudioUnit(let unit):
            audioUnit = unit.audioUnit
        case .sampler(let sampler):
            audioUnit = sampler.audioUnit
        }
        
        MusicDeviceMIDIEvent(audioUnit, UInt32(status), UInt32(data1), UInt32(data2), 0)
    }
    
    public func clearScheduledMIDIEvents() {
        scheduledMIDIEvents.removeAll()
        activeNotes.removeAll()
    }
    
    // MARK: - Audio Clips
    
    public func scheduleAudioClip(
        url: URL,
        trackID: TrackID,
        startSample: Int64,
        offsetSample: Int64,
        endSample: Int64,
        volume: Float
    ) throws {
        scheduledClips.append(ScheduledAudioClip(
            url: url,
            trackID: trackID,
            startSample: startSample,
            offsetSample: offsetSample,
            endSample: endSample,
            volume: volume
        ))
    }
    
    public func clearAudioClips() {
        for player in audioPlayers.values {
            player.stop()
        }
        audioPlayers.removeAll()
        scheduledClips.removeAll()
    }
    
    // MARK: - Playback Control
    
    public func play(from samplePosition: Int64) {
        _isPlaying = true
        _currentSamplePosition = samplePosition
        playbackStartSample = samplePosition
        playbackStartHostTime = mach_absolute_time()
        
        installTimingTap()
        startAudioClips()
        
        if let player = metronomePlayer, !player.isPlaying {
            player.play()
        }
        
        print("[LegacyBackend] Started playback from sample \(samplePosition)")
    }
    
    public func pause() {
        _isPlaying = false
        print("[LegacyBackend] Paused playback")
    }
    
    public func stopPlayback() {
        _isPlaying = false
        
        // Stop all notes
        for note in activeNotes {
            sendImmediateMIDI(status: 0x80 | note.channel, data1: note.pitch, data2: 0, to: note.trackID)
        }
        activeNotes.removeAll()
        
        // Stop audio
        for player in audioPlayers.values {
            player.stop()
        }
        
        // Reset events
        for i in 0..<scheduledMIDIEvents.count {
            // Events will be reprocessed on next play
        }
        
        print("[LegacyBackend] Stopped playback")
    }
    
    public func seek(to samplePosition: Int64) {
        _currentSamplePosition = samplePosition
        playbackStartSample = samplePosition
        playbackStartHostTime = mach_absolute_time()
    }
    
    // MARK: - Timing Tap
    
    private func installTimingTap() {
        guard !timingTapInstalled else { return }
        
        let format = masterMixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        
        masterMixer.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, time in
            guard let self = self, self._isPlaying else { return }
            
            let currentHostTime = mach_absolute_time()
            let elapsedSamples = self.hostTimeToSamples(from: self.playbackStartHostTime, to: currentHostTime)
            let bufferStartSample = self.playbackStartSample + elapsedSamples
            
            // Process MIDI events on high-priority queue
            self.midiProcessingQueue.async {
                self.processBufferMIDI(startSample: bufferStartSample, frameCount: buffer.frameLength)
            }
            
            // Update position
            Task { @MainActor in
                self._currentSamplePosition = bufferStartSample + Int64(buffer.frameLength)
            }
        }
        
        timingTapInstalled = true
    }
    
    private func processBufferMIDI(startSample: Int64, frameCount: AVAudioFrameCount) {
        let endSample = startSample + Int64(frameCount)
        
        // Process scheduled events
        for event in scheduledMIDIEvents {
            guard event.samplePosition >= startSample && event.samplePosition < endSample else { continue }
            
            Task { @MainActor in
                self.sendImmediateMIDI(status: event.status, data1: event.data1, data2: event.data2, to: event.trackID)
            }
        }
    }
    
    private func hostTimeToSamples(from startTime: UInt64, to endTime: UInt64) -> Int64 {
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        
        let elapsed = endTime - startTime
        let nanos = Double(elapsed) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
        let seconds = nanos / 1_000_000_000.0
        
        return Int64(seconds * sampleRate)
    }
    
    private func startAudioClips() {
        // Start scheduled audio clips
        for clip in scheduledClips {
            do {
                let player = try AVAudioPlayer(contentsOf: clip.url)
                player.volume = clip.volume
                player.prepareToPlay()
                audioPlayers[clip.url] = player
                
                // Calculate delay
                let delaySamples = clip.startSample - playbackStartSample
                if delaySamples > 0 {
                    let delaySeconds = Double(delaySamples) / sampleRate
                    player.play(atTime: player.deviceCurrentTime + delaySeconds)
                } else {
                    let offsetSeconds = Double(-delaySamples) / sampleRate
                    player.currentTime = offsetSeconds
                    player.play()
                }
            } catch {
                print("[LegacyBackend] Failed to load audio clip: \(error)")
            }
        }
    }
    
    // MARK: - Metronome
    
    public func setMetronomeEnabled(_ enabled: Bool) {
        metronomeEnabled = enabled
    }
    
    public func setMetronomeVolume(_ volume: Float) {
        metronomeVolumeValue = volume
    }
    
    public func scheduleMetronomeClicks(
        from startBeat: Double,
        to endBeat: Double,
        tempo: Double,
        timeSignature: TimeSignature
    ) {
        scheduledClicks.removeAll()
        
        var beat = ceil(startBeat)
        while beat < endBeat {
            let samplePos = Int64((beat / tempo) * 60.0 * sampleRate)
            let isAccent = Int(beat) % timeSignature.beatsPerBar == 0
            scheduledClicks.append((samplePosition: samplePos, isAccent: isAccent))
            beat += 1
        }
    }
    
    // MARK: - Offline Bounce
    
    public func bounceOffline(
        from startSample: Int64,
        to endSample: Int64,
        outputURL: URL,
        progress: ((Double) -> Void)?
    ) async throws {
        // Legacy backend doesn't support offline bounce
        throw AudioBackendError.notImplemented("Offline bounce not supported in legacy backend. Use Core Audio backend.")
    }
    
    // MARK: - Configuration
    
    public func setBufferSize(_ size: UInt32) throws {
        // AVAudioEngine doesn't easily support buffer size changes
        print("[LegacyBackend] Buffer size change not fully supported in legacy backend")
    }
    
    public func setMasterVolume(_ volume: Float) {
        _masterVolume = volume
        masterMixer.outputVolume = volume
    }
}

// MARK: - Supporting Types

private struct LegacyTrackNode {
    let inputMixer: AVAudioMixerNode
    let gainNode: AVAudioMixerNode
    let pannerNode: AVAudioMixerNode
    let outputMixer: AVAudioMixerNode
}

private enum LegacyInstrument {
    case avAudioUnit(AVAudioUnit)
    case sampler(AVAudioUnitSampler)
}

private struct ScheduledAudioClip {
    let url: URL
    let trackID: TrackID
    let startSample: Int64
    let offsetSample: Int64
    let endSample: Int64
    let volume: Float
}
