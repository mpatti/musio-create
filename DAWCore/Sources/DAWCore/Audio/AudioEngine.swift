import Foundation
import AVFoundation
import Combine

// MARK: - Audio Engine Errors

public enum AudioEngineError: Error, LocalizedError {
    case engineNotRunning
    case failedToStart(underlying: Error)
    case failedToConnect(from: String, to: String)
    case invalidFormat
    case bufferAllocationFailed
    case nodeNotFound(TrackID)
    case fileLoadFailed(URL, Error)
    
    public var errorDescription: String? {
        switch self {
        case .engineNotRunning:
            return "Audio engine is not running"
        case .failedToStart(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .failedToConnect(let from, let to):
            return "Failed to connect \(from) to \(to)"
        case .invalidFormat:
            return "Invalid audio format"
        case .bufferAllocationFailed:
            return "Failed to allocate audio buffer"
        case .nodeNotFound(let id):
            return "Audio node not found for track: \(id.rawValue)"
        case .fileLoadFailed(let url, let error):
            return "Failed to load audio file at \(url): \(error.localizedDescription)"
        }
    }
}

// MARK: - Audio Engine

/// Main audio engine wrapping AVAudioEngine with track management
@MainActor
public final class AudioEngine: ObservableObject {
    // MARK: - Properties
    
    /// The underlying AVAudioEngine - exposed for advanced node attachment
    public let engine: AVAudioEngine
    private var trackNodes: [TrackID: TrackAudioNode] = [:]
    private var masterMixer: AVAudioMixerNode
    
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var sampleRate: Double = 44100
    @Published public private(set) var bufferSize: AVAudioFrameCount = 512
    
    // Available options for UI
    public static let availableBufferSizes: [AVAudioFrameCount] = [64, 128, 256, 512, 1024, 2048]
    public static let availableSampleRates: [Double] = [44100, 48000, 88200, 96000]
    
    // Current playback position in samples - THIS IS THE MASTER CLOCK
    @Published public private(set) var currentSamplePosition: Int64 = 0
    private var playbackStartSamplePosition: Int64 = 0
    private var playbackStartHostTime: UInt64 = 0
    public private(set) var isPlaying: Bool = false
    
    // Combine publishers for sample-accurate timing
    public let samplePositionSubject = PassthroughSubject<Int64, Never>()
    
    // MIDI event callback - called from audio thread with sample-accurate timing
    // Parameters: (bufferStartSample, bufferFrameCount, tempo)
    public var midiEventCallback: ((Int64, AVAudioFrameCount, Double) -> Void)?
    
    // Current tempo for timing calculations (set by transport)
    public var currentTempo: Double = 120.0
    
    // Timing tap installed flag
    private var timingTapInstalled = false
    
    // Metronome
    private var metronomeNode: MetronomeNode?
    
    // MARK: - Initialization
    
    public init() {
        self.engine = AVAudioEngine()
        self.masterMixer = engine.mainMixerNode
        
        // Get sample rate from output
        sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        
        setupNotifications()
        
        // Prepare the engine for input/output
        prepareEngine()
    }
    
    private func prepareEngine() {
        // Access input node to ensure it's initialized
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        print("Audio Engine: Input format = \(inputFormat)")
        
        // Access output node
        let outputNode = engine.outputNode
        let outputFormat = outputNode.outputFormat(forBus: 0)
        print("Audio Engine: Output format = \(outputFormat)")
        
        // Make sure input is connected to output (for monitoring capability)
        // Note: We don't actually connect them directly to avoid feedback,
        // but accessing them prepares the hardware
        
        // Prepare the engine
        engine.prepare()
        print("Audio Engine: Prepared")
    }
    
    /// Ensure the engine is running (call this before any audio operations)
    public func ensureRunning() throws {
        if !engine.isRunning {
            try start()
        }
    }
    
    deinit {
        engine.stop()
    }
    
    // MARK: - Engine Control
    
    public func start() throws {
        guard !engine.isRunning else { return }
        
        do {
            try engine.start()
            isRunning = true
        } catch {
            throw AudioEngineError.failedToStart(underlying: error)
        }
    }
    
    public func stop() {
        engine.stop()
        isRunning = false
        isPlaying = false
    }
    
    public func pause() {
        engine.pause()
        isPlaying = false
    }
    
    // MARK: - Track Management
    
    /// Create audio nodes for a track
    public func createTrackNode(for track: Track) throws {
        guard trackNodes[track.id] == nil else { return }
        
        let trackNode = TrackAudioNode(
            trackID: track.id,
            channelCount: 2,
            sampleRate: sampleRate
        )
        
        // Attach nodes to engine
        engine.attach(trackNode.inputMixer)
        engine.attach(trackNode.gainNode)
        engine.attach(trackNode.pannerNode)
        engine.attach(trackNode.outputMixer)
        
        // Connect: input -> plugins -> gain -> panner -> output
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!
        
        engine.connect(trackNode.inputMixer, to: trackNode.gainNode, format: format)
        engine.connect(trackNode.gainNode, to: trackNode.pannerNode, format: format)
        engine.connect(trackNode.pannerNode, to: trackNode.outputMixer, format: format)
        engine.connect(trackNode.outputMixer, to: masterMixer, format: format)
        
        // Set initial values
        trackNode.setVolume(track.volume)
        trackNode.setPan(track.pan)
        trackNode.setMuted(track.isMuted)
        
        trackNodes[track.id] = trackNode
    }
    
    /// Remove audio nodes for a track
    public func removeTrackNode(for trackID: TrackID) {
        guard let trackNode = trackNodes[trackID] else { return }
        
        // Disconnect and detach all nodes
        engine.disconnectNodeOutput(trackNode.inputMixer)
        engine.disconnectNodeOutput(trackNode.gainNode)
        engine.disconnectNodeOutput(trackNode.pannerNode)
        engine.disconnectNodeOutput(trackNode.outputMixer)
        
        engine.detach(trackNode.inputMixer)
        engine.detach(trackNode.gainNode)
        engine.detach(trackNode.pannerNode)
        engine.detach(trackNode.outputMixer)
        
        // Detach plugin nodes
        for auNode in trackNode.pluginNodes {
            engine.disconnectNodeOutput(auNode)
            engine.detach(auNode)
        }
        
        trackNodes.removeValue(forKey: trackID)
    }
    
    /// Update track parameters (volume, pan, mute)
    public func updateTrackParameters(for track: Track) {
        guard let trackNode = trackNodes[track.id] else { return }
        
        trackNode.setVolume(track.volume)
        trackNode.setPan(track.pan)
        trackNode.setMuted(track.isMuted)
    }
    
    /// Get track node for external access
    public func trackNode(for trackID: TrackID) -> TrackAudioNode? {
        trackNodes[trackID]
    }
    
    // MARK: - Solo Management
    
    public func updateSoloState(tracks: [Track]) {
        let hasSoloedTracks = tracks.contains { $0.isSolo }
        
        for track in tracks {
            guard let trackNode = trackNodes[track.id] else { continue }
            
            if hasSoloedTracks {
                // Mute all non-soloed tracks
                trackNode.setMuted(!track.isSolo)
            } else {
                // Respect individual mute states
                trackNode.setMuted(track.isMuted)
            }
        }
    }
    
    // MARK: - Plugin Management
    
    /// Insert an Audio Unit at a slot in a track
    public func insertPlugin(
        _ audioUnit: AVAudioUnit,
        on trackID: TrackID,
        at slotIndex: Int
    ) throws {
        try insertPlugin(audioUnit, at: slotIndex, in: trackID)
    }
    
    /// Insert an Audio Unit at a slot in a track (alternate signature)
    public func insertPlugin(
        _ audioUnit: AVAudioUnit,
        at slotIndex: Int,
        in trackID: TrackID
    ) throws {
        guard let trackNode = trackNodes[trackID] else {
            throw AudioEngineError.nodeNotFound(trackID)
        }
        
        // Attach the audio unit to the engine
        engine.attach(audioUnit)
        
        // Rebuild the plugin chain
        try rebuildPluginChain(for: trackNode, inserting: audioUnit, at: slotIndex)
    }
    
    /// Remove a plugin from a track
    public func removePlugin(at slotIndex: Int, from trackID: TrackID) throws {
        guard let trackNode = trackNodes[trackID] else {
            throw AudioEngineError.nodeNotFound(trackID)
        }
        
        guard slotIndex < trackNode.pluginNodes.count else { return }
        
        let auNode = trackNode.pluginNodes[slotIndex]
        
        // Disconnect and detach
        engine.disconnectNodeOutput(auNode)
        engine.detach(auNode)
        
        // Rebuild chain without this plugin
        trackNode.pluginNodes.remove(at: slotIndex)
        try rebuildPluginChain(for: trackNode)
    }
    
    private func rebuildPluginChain(
        for trackNode: TrackAudioNode,
        inserting newPlugin: AVAudioUnit? = nil,
        at insertIndex: Int? = nil
    ) throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!
        
        // Insert new plugin if provided
        if let plugin = newPlugin, let index = insertIndex {
            trackNode.pluginNodes.insert(plugin, at: min(index, trackNode.pluginNodes.count))
        }
        
        // Disconnect existing chain
        engine.disconnectNodeOutput(trackNode.inputMixer)
        for auNode in trackNode.pluginNodes {
            engine.disconnectNodeOutput(auNode)
        }
        
        // Rebuild chain: input -> [plugins] -> gain -> panner -> output
        var previousNode: AVAudioNode = trackNode.inputMixer
        
        for auNode in trackNode.pluginNodes {
            engine.connect(previousNode, to: auNode, format: format)
            previousNode = auNode
        }
        
        engine.connect(previousNode, to: trackNode.gainNode, format: format)
        engine.connect(trackNode.gainNode, to: trackNode.pannerNode, format: format)
        engine.connect(trackNode.pannerNode, to: trackNode.outputMixer, format: format)
    }
    
    // MARK: - Audio Playback
    
    /// Schedule audio file playback on a track
    public func scheduleAudioFile(
        _ file: AVAudioFile,
        on trackID: TrackID,
        at sampleTime: Int64,
        startingFrame: AVAudioFramePosition = 0,
        frameCount: AVAudioFrameCount? = nil
    ) throws {
        guard let trackNode = trackNodes[trackID] else {
            throw AudioEngineError.nodeNotFound(trackID)
        }
        
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        
        let format = file.processingFormat
        engine.connect(playerNode, to: trackNode.inputMixer, format: format)
        
        // Calculate frames to play
        let totalFrames = AVAudioFrameCount(file.length - startingFrame)
        let framesToPlay = frameCount ?? totalFrames
        
        // Schedule the file
        playerNode.scheduleSegment(
            file,
            startingFrame: startingFrame,
            frameCount: framesToPlay,
            at: nil
        )
        
        trackNode.playerNodes.append(playerNode)
    }
    
    /// Start playback from a specific sample position
    public func startPlayback(from samplePosition: Int64) {
        playbackStartSamplePosition = samplePosition
        currentSamplePosition = samplePosition
        playbackStartHostTime = mach_absolute_time()
        isPlaying = true
        
        // Install timing tap if not already installed
        installTimingTap()
        
        // Start all player nodes
        for trackNode in trackNodes.values {
            for playerNode in trackNode.playerNodes {
                playerNode.play()
            }
        }
        
        print("[AudioEngine] Started playback from sample \(samplePosition)")
    }
    
    /// Stop playback
    public func stopPlayback() {
        isPlaying = false
        
        // Stop all player nodes
        for trackNode in trackNodes.values {
            for playerNode in trackNode.playerNodes {
                playerNode.stop()
            }
            trackNode.playerNodes.removeAll()
        }
        
        print("[AudioEngine] Stopped playback at sample \(currentSamplePosition)")
    }
    
    /// Set the current sample position (for seeking)
    public func setSamplePosition(_ position: Int64) {
        currentSamplePosition = position
        playbackStartSamplePosition = position
        playbackStartHostTime = mach_absolute_time()
        samplePositionSubject.send(position)
    }
    
    // MARK: - Timing Tap
    
    /// Install a tap on the main mixer to track sample position and trigger MIDI events
    private func installTimingTap() {
        guard !timingTapInstalled else { return }
        
        let format = masterMixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            print("[AudioEngine] Cannot install timing tap - invalid format")
            return
        }
        
        // Update our sample rate
        sampleRate = format.sampleRate
        
        // Install tap on main mixer - this fires every buffer
        // This is the MASTER CLOCK for all timing-critical operations
        masterMixer.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            guard let self = self, self.isPlaying else { return }
            
            // Calculate current sample position based on elapsed time
            let currentHostTime = mach_absolute_time()
            let elapsedSamples = self.hostTimeToSamples(from: self.playbackStartHostTime, to: currentHostTime)
            let bufferStartSample = self.playbackStartSamplePosition + elapsedSamples
            
            // Call MIDI event callback with sample-accurate timing
            // This processes MIDI events that fall within this buffer window
            self.midiEventCallback?(bufferStartSample, buffer.frameLength, self.currentTempo)
            
            // Update position on main thread (for UI only, not for timing)
            let newPosition = bufferStartSample + Int64(buffer.frameLength)
            Task { @MainActor in
                self.currentSamplePosition = newPosition
                self.samplePositionSubject.send(newPosition)
            }
        }
        
        timingTapInstalled = true
        print("[AudioEngine] Timing tap installed, sample rate: \(sampleRate), buffer size: \(bufferSize)")
    }
    
    /// Set the buffer size (requires engine restart)
    public func setBufferSize(_ newSize: AVAudioFrameCount) {
        guard Self.availableBufferSizes.contains(newSize) else {
            print("[AudioEngine] Invalid buffer size: \(newSize)")
            return
        }
        
        let wasRunning = isRunning
        let wasPlaying = isPlaying
        
        // Stop everything
        if wasPlaying { stopPlayback() }
        if wasRunning { stop() }
        
        // Remove existing tap
        removeTimingTap()
        
        // Update buffer size
        bufferSize = newSize
        
        // Restart
        if wasRunning {
            try? start()
        }
        if wasPlaying {
            startPlayback(from: currentSamplePosition)
        }
        
        print("[AudioEngine] Buffer size changed to \(newSize) samples (~\(String(format: "%.1f", Double(newSize) / sampleRate * 1000))ms latency)")
    }
    
    /// Get the current latency in milliseconds
    public var latencyMs: Double {
        Double(bufferSize) / sampleRate * 1000.0
    }
    
    /// Get supported sample rates from the audio device
    public func getSupportedSampleRates() -> [Double] {
        // For now return common rates - could query hardware in future
        return Self.availableSampleRates.filter { $0 <= 96000 }
    }
    
    /// Remove the timing tap
    public func removeTimingTap() {
        guard timingTapInstalled else { return }
        masterMixer.removeTap(onBus: 0)
        timingTapInstalled = false
    }
    
    /// Convert host time difference to samples
    private func hostTimeToSamples(from startTime: UInt64, to endTime: UInt64) -> Int64 {
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        
        let elapsedHostTime = endTime - startTime
        let elapsedNanos = Double(elapsedHostTime) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
        let elapsedSeconds = elapsedNanos / 1_000_000_000.0
        
        return Int64(elapsedSeconds * sampleRate)
    }
    
    /// Convert a host time to sample position relative to playback start
    public func hostTimeToSamplePosition(_ hostTime: UInt64) -> Int64 {
        guard hostTime >= playbackStartHostTime else {
            return playbackStartSamplePosition
        }
        let elapsedSamples = hostTimeToSamples(from: playbackStartHostTime, to: hostTime)
        return playbackStartSamplePosition + elapsedSamples
    }
    
    /// Get the current sample position (thread-safe read)
    public func getCurrentSamplePosition() -> Int64 {
        return currentSamplePosition
    }
    
    // MARK: - Master Output
    
    public var masterVolume: Float {
        get { masterMixer.outputVolume }
        set { masterMixer.outputVolume = newValue }
    }
    
    public func setMasterVolume(_ volume: Float) {
        masterMixer.outputVolume = volume
    }
    
    // MARK: - Notifications
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }
    
    @objc private func handleConfigurationChange(_ notification: Notification) {
        // Handle audio configuration changes (e.g., sample rate change)
        Task { @MainActor in
            sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            
            if isRunning {
                try? start()
            }
        }
    }
    
    // MARK: - Metering
    
    /// Install a tap on the master output for metering
    public func installMasterMeter(
        bufferSize: AVAudioFrameCount = 1024,
        handler: @escaping (Float, Float) -> Void  // (leftPeak, rightPeak)
    ) {
        let format = masterMixer.outputFormat(forBus: 0)
        
        masterMixer.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: format
        ) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            
            var leftPeak: Float = 0
            var rightPeak: Float = 0
            
            if channelCount >= 1 {
                for i in 0..<frameLength {
                    leftPeak = max(leftPeak, abs(channelData[0][i]))
                }
            }
            
            if channelCount >= 2 {
                for i in 0..<frameLength {
                    rightPeak = max(rightPeak, abs(channelData[1][i]))
                }
            } else {
                rightPeak = leftPeak
            }
            
            handler(leftPeak, rightPeak)
        }
    }
    
    public func removeMasterMeter() {
        masterMixer.removeTap(onBus: 0)
    }
}

// MARK: - Track Audio Node

/// Represents the audio node chain for a single track
public final class TrackAudioNode {
    public let trackID: TrackID
    
    // Node chain: input -> [plugins] -> gain -> panner -> output
    public let inputMixer: AVAudioMixerNode
    public let gainNode: AVAudioMixerNode
    public let pannerNode: AVAudioMixerNode
    public let outputMixer: AVAudioMixerNode
    
    // Plugin chain (Audio Units)
    public var pluginNodes: [AVAudioUnit] = []
    
    // Player nodes for audio clips
    public var playerNodes: [AVAudioPlayerNode] = []
    
    // Sampler for MIDI playback
    public var samplerNode: AVAudioUnitSampler?
    
    private var isMuted: Bool = false
    private var volume: Float = 1.0
    
    public init(trackID: TrackID, channelCount: Int, sampleRate: Double) {
        self.trackID = trackID
        self.inputMixer = AVAudioMixerNode()
        self.gainNode = AVAudioMixerNode()
        self.pannerNode = AVAudioMixerNode()
        self.outputMixer = AVAudioMixerNode()
    }
    
    public func setVolume(_ volume: Float) {
        self.volume = volume
        updateOutputVolume()
    }
    
    public func setPan(_ pan: Float) {
        pannerNode.pan = pan
    }
    
    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
        updateOutputVolume()
    }
    
    private func updateOutputVolume() {
        outputMixer.outputVolume = isMuted ? 0.0 : volume
    }
}

// MARK: - Metronome Node

/// Simple metronome using an oscillator
public final class MetronomeNode {
    private let sampleRate: Double
    private var phase: Double = 0
    
    public var volume: Float = 0.7
    public var isEnabled: Bool = false
    
    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }
    
    /// Generate a click at the current sample position
    public func generateClick(
        buffer: AVAudioPCMBuffer,
        isDownbeat: Bool
    ) {
        guard isEnabled else { return }
        
        let frequency = isDownbeat ? 1200.0 : 800.0
        let duration = 0.02  // 20ms click
        let samples = Int(duration * sampleRate)
        
        guard let channelData = buffer.floatChannelData else { return }
        
        for i in 0..<min(samples, Int(buffer.frameLength)) {
            let envelope = 1.0 - (Double(i) / Double(samples))  // Linear decay
            let sample = Float(sin(2.0 * .pi * frequency * phase) * envelope * Double(volume))
            
            channelData[0][i] += sample
            if buffer.format.channelCount > 1 {
                channelData[1][i] += sample
            }
            
            phase += 1.0 / sampleRate
        }
        
        phase = 0
    }
}
