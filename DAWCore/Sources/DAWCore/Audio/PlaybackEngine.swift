import Foundation
import AVFoundation
import AudioToolbox
import Combine

// MARK: - Playback Engine

/// Coordinates audio and MIDI playback across all tracks
/// This is the central "brain" that schedules clips for playback
@MainActor
public final class PlaybackEngine: ObservableObject {
    
    // MARK: - Properties
    
    private let audioEngine: AudioEngine
    private weak var transportState: TransportState?
    
    // MARK: - Core Audio Backend (Optional)
    
    /// The Core Audio backend (when enabled via feature flag)
    private var coreAudioBackend: AudioBackend?
    
    /// Whether we're using the Core Audio backend
    private var useCoreAudioBackend: Bool {
        coreAudioBackend != nil
    }
    
    // Track instruments - can be AU instruments or fallback samplers
    private var trackInstruments: [TrackID: TrackInstrument] = [:]
    
    // V-Rack instruments - multi-timbral instruments that receive MIDI from multiple tracks
    private var rackInstruments: [UUID: TrackInstrument] = [:]
    private var rackInstrumentMixers: [UUID: AVAudioMixerNode] = [:]
    
    // V-Rack sum mixer - all rack instruments route through this for recording/monitoring
    private var vRackSumMixer: AVAudioMixerNode?
    private var vRackSumMixerConnected: Bool = false
    
    // V-Rack recording state
    private var vRackRecordingFile: AVAudioFile?
    private var vRackRecordingURL: URL?
    private var vRackRecordingStartBeat: Double = 0
    @Published public private(set) var isRecordingVRack: Bool = false
    @Published public private(set) var vRackRecordingLevel: Float = 0
    
    // V-Rack input monitoring (for armed tracks)
    private var isMonitoringVRackInput: Bool = false
    @Published public private(set) var vRackInputLevel: (left: Float, right: Float) = (0, 0)
    
    // V-Rack recording waveform visualization
    @Published public private(set) var vRackWaveformSamples: [Float] = []
    private var vRackWaveformBuffer: [Float] = []
    private let maxWaveformSamples = 4000  // Keep last N samples for display
    
    // Track player nodes for audio playback (legacy)
    private var trackPlayers: [TrackID: [ClipID: AVAudioPlayerNode]] = [:]
    
    // Track which clips have audio successfully scheduled
    private var scheduledClips: Set<ClipID> = []
    
    // AVAudioPlayerNode-based playback for audio clips (synced with V-Rack through same engine)
    private var audioPlayerNodes: [ClipID: AVAudioPlayerNode] = [:]
    private var audioClipFiles: [ClipID: AVAudioFile] = [:]  // Store files for scheduling
    private var audioClipInfo: [ClipID: AudioClipPlaybackInfo] = [:]
    
    // Sample-accurate AVAudioPlayerNode instances for seamless looping
    private var sampleAccurateNodes: [TrackID: [AVAudioPlayerNode]] = [:]
    
    // Captured playback start position for sync
    private var playbackStartBeat: Double = 0
    private var playbackStartSample: Int64 = 0
    
    // Scheduled events for the current playback session
    private var scheduledMIDIEvents: [ScheduledEvent] = []
    private var activeNotes: [ActiveNote] = []
    
    // Last processed sample position (for tracking what's been played)
    private var lastProcessedSample: Int64 = 0
    
    // State
    @Published public private(set) var isPlaying: Bool = false
    
    // High-priority queue for MIDI processing (avoids blocking audio thread)
    private let midiProcessingQueue = DispatchQueue(label: "com.musio.midi-processing", qos: .userInteractive)
    
    // Timer for processing V-Rack MIDI events in hybrid mode
    // (When Core Audio backend is active, AVAudioEngine's timing tap may not fire)
    private var hybridMIDITimer: DispatchSourceTimer?
    private var hybridPlaybackStartTime: UInt64 = 0
    private var lastMetronomeBeat: Int = -1  // Track last metronome click beat
    private var wasMetronomeEnabled: Bool = false  // Track previous state to detect toggle-on
    
    // Meter levels - published for UI consumption
    @Published public private(set) var trackMeterLevels: [TrackID: (left: Float, right: Float)] = [:]
    @Published public private(set) var masterMeterLevel: (left: Float, right: Float) = (0, 0)
    
    // Metering timer
    private var meteringTimer: Timer?
    private let meteringInterval: TimeInterval = 1.0 / 30.0  // 30fps meter updates
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        
        // Setup V-Rack sum mixer for internal recording
        setupVRackSumMixer()
        
        // Check if Core Audio backend should be used
        if AudioBackendFactory.useCoreAudioBackend {
            print("[PlaybackEngine] ✓ Initializing with Core Audio backend")
            self.coreAudioBackend = CoreAudioBackend()
            setupCoreAudioBackend()
        } else {
            print("[PlaybackEngine] Using legacy AVAudioEngine backend")
            self.coreAudioBackend = nil
            setupLegacyAudioCallback()
        }
    }
    
    /// Setup the V-Rack sum mixer for routing all rack instruments through a single point
    private func setupVRackSumMixer() {
        let sumMixer = AVAudioMixerNode()
        audioEngine.engine.attach(sumMixer)
        
        // Connect sum mixer to main mixer
        // Use a standard format since the engine might not be started yet
        let format = AVAudioFormat(standardFormatWithSampleRate: audioEngine.sampleRate, channels: 2)!
        audioEngine.engine.connect(sumMixer, to: audioEngine.engine.mainMixerNode, format: format)
        
        vRackSumMixer = sumMixer
        vRackSumMixerConnected = true
        print("[PlaybackEngine] V-Rack sum mixer created and connected with format: \(format)")
    }
    
    /// Ensure the V-Rack sum mixer is connected (call after engine restart)
    private func ensureVRackSumMixerConnected() {
        guard let sumMixer = vRackSumMixer else {
            setupVRackSumMixer()
            return
        }
        
        // Check if still connected by trying to get output format
        // If not attached, re-attach and connect
        if audioEngine.engine.outputConnectionPoints(for: sumMixer, outputBus: 0).isEmpty {
            print("[PlaybackEngine] V-Rack sum mixer disconnected, reconnecting...")
            let format = AVAudioFormat(standardFormatWithSampleRate: audioEngine.sampleRate, channels: 2)!
            audioEngine.engine.connect(sumMixer, to: audioEngine.engine.mainMixerNode, format: format)
            print("[PlaybackEngine] V-Rack sum mixer reconnected")
        }
    }
    
    /// Set up the Core Audio backend
    private func setupCoreAudioBackend() {
        guard let backend = coreAudioBackend else { return }
        do {
            try backend.start()
            print("[PlaybackEngine] Core Audio backend started, sample rate: \(backend.sampleRate)")
        } catch {
            print("[PlaybackEngine] ⚠️ Failed to start Core Audio backend: \(error)")
            print("[PlaybackEngine] Falling back to legacy AVAudioEngine")
            coreAudioBackend = nil
            setupLegacyAudioCallback()
        }
    }
    
    /// Set up the sample-accurate audio callback for MIDI timing (legacy mode)
    private func setupLegacyAudioCallback() {
        // This callback is called from the audio thread every buffer
        // It's the ONLY place we should process time-critical MIDI events
        audioEngine.midiEventCallback = { [weak self] bufferStartSample, frameCount, tempo in
            self?.processAudioBuffer(startSample: bufferStartSample, frameCount: frameCount, tempo: tempo)
        }
    }
    
    // MARK: - Setup
    
    public func bind(to transportState: TransportState) {
        self.transportState = transportState
        
        transportState.transportEventSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleTransportEvent(event)
            }
            .store(in: &cancellables)
        
        // Update audio engine tempo when transport tempo changes
        transportState.tempoSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tempo in
                self?.audioEngine.currentTempo = tempo.bpm
            }
            .store(in: &cancellables)
    }
    
    private func handleTransportEvent(_ event: TransportEvent) {
        switch event {
        case .play:
            startPlayback()
        case .stop:
            stopPlayback()
        case .pause:
            pausePlayback()
        default:
            break
        }
    }
    
    // MARK: - Track Setup
    
    /// Setup a MIDI track with an instrument (AU plugin or fallback sampler)
    public func setupMIDITrack(_ track: Track) async throws {
        guard track.type == .midi || track.type == .instrument else { return }
        
        // Skip if already set up
        if trackInstruments[track.id] != nil { return }
        
        // Core Audio backend path
        if let backend = coreAudioBackend {
            try backend.createTrack(id: track.id)
            print("[PlaybackEngine] Created track in Core Audio backend: \(track.name)")
            // Note: The backend manages its own default instruments
            return
        }
        
        // Legacy AVAudioEngine path
        // Create fallback sampler
        let sampler = AVAudioUnitSampler()
        
        // Attach to audio engine
        audioEngine.engine.attach(sampler)
        
        // Connect to track input
        if let trackNode = audioEngine.trackNode(for: track.id) {
            let format = AVAudioFormat(standardFormatWithSampleRate: audioEngine.sampleRate, channels: 2)!
            audioEngine.engine.connect(sampler, to: trackNode.inputMixer, format: format)
        }
        
        // Load default sound (built-in piano)
        try await loadDefaultSound(for: sampler)
        
        trackInstruments[track.id] = .sampler(sampler)
        print("[PlaybackEngine] Setup fallback sampler for track: \(track.name)")
    }
    
    // Mixer nodes used for sample rate conversion when loading AU instruments
    private var instrumentMixers: [TrackID: AVAudioMixerNode] = [:]
    
    /// Load an AU instrument plugin for a track
    public func loadInstrument(_ audioUnit: AVAudioUnit, for trackID: TrackID, pluginID: UUID) async throws {
        // Core Audio backend path - load via backend's plugin hosting
        if let backend = coreAudioBackend {
            print("[PlaybackEngine] Loading instrument via Core Audio backend")
            let desc = audioUnit.audioComponentDescription
            _ = try await backend.loadInstrument(desc, for: trackID)
            // Also store in trackInstruments for UI access
            trackInstruments[trackID] = .auInstrument(audioUnit, pluginID: pluginID)
            print("[PlaybackEngine] ✓ Instrument loaded via Core Audio backend")
            return
        }
        
        // Legacy AVAudioEngine path
        // Remove existing instrument if any
        removeInstrument(for: trackID)
        
        print("[PlaybackEngine] ========================================")
        print("[PlaybackEngine] Loading AU instrument: \(audioUnit.name)")
        print("[PlaybackEngine] Track ID: \(trackID.rawValue)")
        print("[PlaybackEngine] Audio Engine running: \(audioEngine.engine.isRunning)")
        
        // Stop the engine before making changes
        let wasRunning = audioEngine.engine.isRunning
        if wasRunning {
            audioEngine.engine.stop()
            print("[PlaybackEngine] Stopped engine for reconfiguration")
        }
        
        // Get the output format from the AU
        let auFormat = audioUnit.outputFormat(forBus: 0)
        print("[PlaybackEngine] AU native format: \(auFormat)")
        
        // Engine format
        let engineFormat = AVAudioFormat(standardFormatWithSampleRate: audioEngine.sampleRate, channels: 2)!
        print("[PlaybackEngine] Engine format: \(engineFormat)")
        
        // Attach the AU to the audio engine
        audioEngine.engine.attach(audioUnit)
        print("[PlaybackEngine] Attached AU to engine")
        
        // Create a mixer node to handle sample rate conversion
        // AVAudioMixerNode automatically converts between formats
        let converterMixer = AVAudioMixerNode()
        audioEngine.engine.attach(converterMixer)
        instrumentMixers[trackID] = converterMixer
        print("[PlaybackEngine] Created converter mixer for sample rate conversion")
        
        // Connect: AU (44100) -> converterMixer -> trackNode.inputMixer (48000)
        // The mixer node handles the sample rate conversion automatically
        audioEngine.engine.connect(audioUnit, to: converterMixer, format: auFormat)
        print("[PlaybackEngine] Connected AU -> converterMixer (AU format: \(auFormat.sampleRate) Hz)")
        
        // Connect to track input with engine format
        if let trackNode = audioEngine.trackNode(for: trackID) {
            audioEngine.engine.connect(converterMixer, to: trackNode.inputMixer, format: engineFormat)
            print("[PlaybackEngine] Connected converterMixer -> trackNode.inputMixer (engine format: \(engineFormat.sampleRate) Hz)")
            print("[PlaybackEngine] Track inputMixer volume: \(trackNode.inputMixer.outputVolume)")
            converterMixer.outputVolume = 1.0
            print("[PlaybackEngine] Converter mixer volume: \(converterMixer.outputVolume)")
        } else {
            print("[PlaybackEngine] ERROR: No track node for \(trackID.rawValue)")
            throw PlaybackError.trackNotFound(trackID)
        }
        
        // Restart the engine
        if wasRunning {
            do {
                try audioEngine.engine.start()
                print("[PlaybackEngine] ✓ Engine restarted")
            } catch {
                print("[PlaybackEngine] ⚠️ Failed to restart engine: \(error)")
            }
        }
        
        // Check the connections
        let auConnections = audioEngine.engine.outputConnectionPoints(for: audioUnit, outputBus: 0)
        let mixerConnections = audioEngine.engine.outputConnectionPoints(for: converterMixer, outputBus: 0)
        print("[PlaybackEngine] AU output connections: \(auConnections.count)")
        print("[PlaybackEngine] Converter mixer output connections: \(mixerConnections.count)")
        
        // Check if the AU is now rendering
        print("[PlaybackEngine] AU render resources allocated: \(audioUnit.auAudioUnit.renderResourcesAllocated)")
        
        trackInstruments[trackID] = .auInstrument(audioUnit, pluginID: pluginID)
        
        // Verify we can get the instrument back
        if let inst = trackInstruments[trackID] {
            print("[PlaybackEngine] Instrument stored successfully: \(inst)")
        }
        
        print("[PlaybackEngine] ========================================")
    }
    
    /// Remove the instrument from a track
    public func removeInstrument(for trackID: TrackID) {
        guard let instrument = trackInstruments[trackID] else { return }
        
        // Disconnect and detach the audio node
        audioEngine.engine.disconnectNodeOutput(instrument.audioNode)
        audioEngine.engine.detach(instrument.audioNode)
        
        // Also remove the converter mixer if it exists
        if let mixer = instrumentMixers[trackID] {
            audioEngine.engine.disconnectNodeOutput(mixer)
            audioEngine.engine.detach(mixer)
            instrumentMixers.removeValue(forKey: trackID)
        }
        
        trackInstruments.removeValue(forKey: trackID)
        print("[PlaybackEngine] Removed instrument from track: \(trackID.rawValue)")
    }
    
    /// Get the instrument for a track
    public func instrument(for trackID: TrackID) -> TrackInstrument? {
        trackInstruments[trackID]
    }
    
    /// Debug: list all loaded instruments
    public func debugInstrumentList() -> String {
        if trackInstruments.isEmpty {
            return "No instruments loaded"
        }
        return trackInstruments.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", ")
    }
    
    // MARK: - V-Rack Instrument Management
    
    /// Load an AU instrument plugin for the V-Rack
    public func loadRackInstrument(_ audioUnit: AVAudioUnit, rackID: UUID, pluginID: UUID) async throws {
        // Remove existing instrument if any
        removeRackInstrument(rackID: rackID)
        
        print("[PlaybackEngine] ========================================")
        print("[PlaybackEngine] Loading V-Rack AU instrument: \(audioUnit.name)")
        print("[PlaybackEngine] Rack ID: \(rackID)")
        
        // Stop the engine before making changes
        let wasRunning = audioEngine.engine.isRunning
        if wasRunning {
            audioEngine.engine.stop()
        }
        
        // Attach the audio unit to the engine
        audioEngine.engine.attach(audioUnit)
        
        // Create a mixer for sample rate conversion
        let converterMixer = AVAudioMixerNode()
        audioEngine.engine.attach(converterMixer)
        rackInstrumentMixers[rackID] = converterMixer
        
        // Get the AU's native output format
        let auFormat = audioUnit.outputFormat(forBus: 0)
        // Use a standard format for the engine side (more reliable than querying stopped engine)
        let engineFormat = AVAudioFormat(standardFormatWithSampleRate: audioEngine.sampleRate, channels: 2)!
        
        print("[PlaybackEngine] AU output format: \(auFormat)")
        print("[PlaybackEngine] Engine format: \(engineFormat)")
        
        // Ensure V-Rack sum mixer is set up and connected
        ensureVRackSumMixerConnected()
        
        // Connect: AU -> converterMixer (using AU's format)
        audioEngine.engine.connect(audioUnit, to: converterMixer, format: auFormat)
        
        // Connect: converterMixer -> vRackSumMixer -> mainMixer (using engine's format)
        // This routes all V-Rack instruments through a single point for recording
        if let sumMixer = vRackSumMixer {
            audioEngine.engine.connect(converterMixer, to: sumMixer, format: engineFormat)
            print("[PlaybackEngine] Connected to V-Rack sum mixer")
        } else {
            // Fallback: connect directly to main mixer if sum mixer not available
            audioEngine.engine.connect(converterMixer, to: audioEngine.engine.mainMixerNode, format: engineFormat)
            print("[PlaybackEngine] Warning: V-Rack sum mixer not available, connected directly to main mixer")
        }
        
        // Allocate render resources
        try audioUnit.auAudioUnit.allocateRenderResources()
        
        // Restart engine if it was running
        if wasRunning {
            try audioEngine.engine.start()
            // Ensure sum mixer is still connected after restart
            ensureVRackSumMixerConnected()
        }
        
        // Store the instrument
        rackInstruments[rackID] = .auInstrument(audioUnit, pluginID: pluginID)
        
        print("[PlaybackEngine] V-Rack instrument loaded successfully: \(audioUnit.name)")
        
        // NOTE: V-Rack instruments stay ONLY in AVAudioEngine
        // When Core Audio backend is active, we use a HYBRID approach:
        // - V-Rack instruments render through AVAudioEngine (already connected)
        // - Scheduled MIDI for V-Rack is sent through the legacy path
        // This avoids the complexity of duplicating AUv3 plugins
        if coreAudioBackend != nil {
            print("[PlaybackEngine] V-Rack instrument stays in AVAudioEngine (hybrid mode)")
        }
    }
    
    /// Remove a rack instrument
    public func removeRackInstrument(rackID: UUID) {
        guard let instrument = rackInstruments[rackID] else { return }
        
        // Disconnect and detach the audio node
        audioEngine.engine.disconnectNodeOutput(instrument.audioNode)
        audioEngine.engine.detach(instrument.audioNode)
        
        // Also remove the converter mixer if it exists
        if let mixer = rackInstrumentMixers[rackID] {
            audioEngine.engine.disconnectNodeOutput(mixer)
            audioEngine.engine.detach(mixer)
            rackInstrumentMixers.removeValue(forKey: rackID)
        }
        
        // Note: V-Rack instruments are NOT in Core Audio backend (hybrid mode)
        // They stay only in AVAudioEngine
        
        rackInstruments.removeValue(forKey: rackID)
        print("[PlaybackEngine] Removed V-Rack instrument: \(rackID)")
    }
    
    /// Get a rack instrument by ID
    public func rackInstrument(for rackID: UUID) -> TrackInstrument? {
        rackInstruments[rackID]
    }
    
    /// Send MIDI to a rack instrument on a specific channel
    public func sendMIDIToRackInstrument(rackID: UUID, note: UInt8, velocity: UInt8, channel: UInt8, isNoteOn: Bool) {
        guard let instrument = rackInstruments[rackID] else {
            print("[PlaybackEngine] No rack instrument found for ID: \(rackID)")
            return
        }
        
        if isNoteOn {
            instrument.startNote(note, velocity: velocity, channel: channel)
        } else {
            instrument.stopNote(note, channel: channel)
        }
    }
    
    // MARK: - V-Rack Recording
    
    /// Recording result returned after V-Rack recording completes
    public struct VRackRecordingResult {
        public let fileURL: URL
        public let startBeat: Double
        public let durationInSamples: Int64
        public let sampleRate: Double
        public let latencyCompensation: TimeInterval
    }
    
    /// Start recording from the V-Rack sum mixer
    /// - Parameter destinationURL: URL where the WAV file will be saved
    /// - Returns: True if recording started successfully
    @discardableResult
    public func startVRackRecording(to destinationURL: URL) -> Bool {
        guard let sumMixer = vRackSumMixer else {
            print("[PlaybackEngine] Cannot start V-Rack recording: sum mixer not available")
            return false
        }
        
        guard !isRecordingVRack else {
            print("[PlaybackEngine] V-Rack recording already in progress")
            return false
        }
        
        // Get the format from the sum mixer
        let format = sumMixer.outputFormat(forBus: 0)
        
        // Create the audio file for recording
        do {
            let audioFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            
            vRackRecordingFile = audioFile
            vRackRecordingURL = destinationURL
            vRackRecordingStartBeat = transportState?.playheadBeats ?? 0
            
            // Clear waveform buffer for new recording
            vRackWaveformBuffer.removeAll()
            vRackWaveformSamples.removeAll()
            
            // Install a tap on the sum mixer to capture audio
            sumMixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self = self, let file = self.vRackRecordingFile else { return }
                
                do {
                    try file.write(from: buffer)
                    
                    // Calculate level for metering and collect waveform samples
                    if let channelData = buffer.floatChannelData?[0] {
                        let frameLength = Int(buffer.frameLength)
                        var sum: Float = 0
                        var waveformPoints: [Float] = []
                        
                        // Downsample for waveform display (take every Nth sample)
                        let downsampleFactor = max(1, frameLength / 64)
                        
                        for i in 0..<frameLength {
                            let sample = channelData[i]
                            sum += sample * sample
                            
                            // Collect samples for waveform visualization
                            if i % downsampleFactor == 0 {
                                waveformPoints.append(abs(sample))
                            }
                        }
                        
                        let rms = sqrt(sum / Float(frameLength))
                        let level = 20 * log10(max(rms, 0.000001))
                        let normalizedLevel = max(0, min(1, (level + 60) / 60))
                        
                        DispatchQueue.main.async {
                            self.vRackRecordingLevel = normalizedLevel
                            
                            // Update waveform buffer
                            self.vRackWaveformBuffer.append(contentsOf: waveformPoints)
                            
                            // Trim buffer if it gets too large
                            if self.vRackWaveformBuffer.count > self.maxWaveformSamples {
                                self.vRackWaveformBuffer.removeFirst(self.vRackWaveformBuffer.count - self.maxWaveformSamples)
                            }
                            
                            self.vRackWaveformSamples = self.vRackWaveformBuffer
                        }
                    }
                } catch {
                    print("[PlaybackEngine] Error writing V-Rack recording buffer: \(error)")
                }
            }
            
            isRecordingVRack = true
            print("[PlaybackEngine] V-Rack recording started to: \(destinationURL.lastPathComponent)")
            return true
            
        } catch {
            print("[PlaybackEngine] Failed to create V-Rack recording file: \(error)")
            return false
        }
    }
    
    /// Stop V-Rack recording and return the result
    /// - Returns: Recording result containing file info and timing data, or nil if not recording
    public func stopVRackRecording() -> VRackRecordingResult? {
        guard isRecordingVRack, let sumMixer = vRackSumMixer else {
            return nil
        }
        
        // Remove the recording tap
        sumMixer.removeTap(onBus: 0)
        
        // Get recording info before clearing
        guard let file = vRackRecordingFile, let url = vRackRecordingURL else {
            isRecordingVRack = false
            return nil
        }
        
        let durationInSamples = file.length
        let sampleRate = file.processingFormat.sampleRate
        let startBeat = vRackRecordingStartBeat
        let latency = calculateVRackLatency()
        
        // Clear recording state
        vRackRecordingFile = nil
        vRackRecordingURL = nil
        isRecordingVRack = false
        vRackRecordingLevel = 0
        vRackWaveformBuffer.removeAll()
        vRackWaveformSamples.removeAll()
        
        print("[PlaybackEngine] V-Rack recording stopped. Duration: \(Double(durationInSamples) / sampleRate)s, Latency compensation: \(latency * 1000)ms")
        
        return VRackRecordingResult(
            fileURL: url,
            startBeat: startBeat,
            durationInSamples: durationInSamples,
            sampleRate: sampleRate,
            latencyCompensation: latency
        )
    }
    
    /// Calculate the maximum latency across all loaded V-Rack instruments
    /// This is used to offset the recorded audio so it aligns with MIDI events
    public func calculateVRackLatency() -> TimeInterval {
        var maxLatency: TimeInterval = 0
        
        for (_, instrument) in rackInstruments {
            if case .auInstrument(let au, _) = instrument {
                let auLatency = au.auAudioUnit.latency
                maxLatency = max(maxLatency, auLatency)
                print("[PlaybackEngine] Instrument \(au.name) latency: \(auLatency * 1000)ms")
            }
        }
        
        print("[PlaybackEngine] Max V-Rack latency: \(maxLatency * 1000)ms")
        return maxLatency
    }
    
    /// Convert latency in seconds to beats at a given tempo
    public func latencyInBeats(_ latency: TimeInterval, atTempo tempo: Double) -> Double {
        // beats per second = tempo / 60
        // latency in beats = latency * (tempo / 60)
        return latency * (tempo / 60.0)
    }
    
    /// Get the audio engine buffer latency in seconds
    public var bufferLatencySeconds: TimeInterval {
        Double(audioEngine.bufferSize) / audioEngine.sampleRate
    }
    
    // MARK: - V-Rack Input Monitoring
    
    /// Start monitoring V-Rack input levels (for armed audio tracks with V-Rack input)
    /// This is lighter weight than recording - just measures levels without writing to disk
    public func startVRackInputMonitoring() {
        guard let sumMixer = vRackSumMixer else {
            print("[PlaybackEngine] Cannot start V-Rack monitoring: sum mixer not available")
            return
        }
        
        // Don't start monitoring if already recording (recording tap provides levels)
        guard !isRecordingVRack && !isMonitoringVRackInput else {
            return
        }
        
        let format = sumMixer.outputFormat(forBus: 0)
        
        // Install a lightweight tap just for metering
        sumMixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // Calculate stereo levels
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            
            var leftSum: Float = 0
            var rightSum: Float = 0
            
            if let channelData = buffer.floatChannelData {
                // Left channel
                for i in 0..<frameLength {
                    let sample = channelData[0][i]
                    leftSum += sample * sample
                }
                
                // Right channel (if stereo)
                if buffer.format.channelCount > 1 {
                    for i in 0..<frameLength {
                        let sample = channelData[1][i]
                        rightSum += sample * sample
                    }
                } else {
                    rightSum = leftSum  // Mono - use same value
                }
            }
            
            let leftRms = sqrt(leftSum / Float(frameLength))
            let rightRms = sqrt(rightSum / Float(frameLength))
            
            // Convert to normalized 0-1 range (with -60dB floor)
            let leftDb = 20 * log10(max(leftRms, 0.000001))
            let rightDb = 20 * log10(max(rightRms, 0.000001))
            
            let leftNormalized = max(0, min(1, (leftDb + 60) / 60))
            let rightNormalized = max(0, min(1, (rightDb + 60) / 60))
            
            DispatchQueue.main.async {
                self.vRackInputLevel = (leftNormalized, rightNormalized)
            }
        }
        
        isMonitoringVRackInput = true
        print("[PlaybackEngine] V-Rack input monitoring started")
    }
    
    /// Stop monitoring V-Rack input levels
    public func stopVRackInputMonitoring() {
        guard isMonitoringVRackInput, let sumMixer = vRackSumMixer else {
            return
        }
        
        // Don't remove tap if we're recording (recording needs it)
        guard !isRecordingVRack else {
            return
        }
        
        sumMixer.removeTap(onBus: 0)
        isMonitoringVRackInput = false
        vRackInputLevel = (0, 0)
        
        print("[PlaybackEngine] V-Rack input monitoring stopped")
    }

    /// Debug: Check audio engine state and play a test tone
    public func debugAudioPath(for trackID: TrackID) {
        print("[DEBUG] ========================================")
        print("[DEBUG] Audio Engine running: \(audioEngine.engine.isRunning)")
        print("[DEBUG] Audio Engine sample rate: \(audioEngine.sampleRate)")
        print("[DEBUG] Master volume: \(audioEngine.masterVolume)")
        
        if let trackNode = audioEngine.trackNode(for: trackID) {
            print("[DEBUG] Track node found")
            print("[DEBUG] Input mixer volume: \(trackNode.inputMixer.outputVolume)")
            print("[DEBUG] Gain node volume: \(trackNode.gainNode.outputVolume)")
            print("[DEBUG] Output mixer volume: \(trackNode.outputMixer.outputVolume)")
        } else {
            print("[DEBUG] No track node!")
        }
        
        if let instrument = trackInstruments[trackID] {
            print("[DEBUG] Instrument found: \(instrument)")
            
            // Check if AU is connected
            if case .auInstrument(let au, _) = instrument {
                print("[DEBUG] AU name: \(au.name)")
                print("[DEBUG] AU manufacturer: \(au.manufacturerName)")
                let connections = audioEngine.engine.outputConnectionPoints(for: au, outputBus: 0)
                print("[DEBUG] AU has \(connections.count) output connections")
                
                // Check scheduleMIDIEventBlock
                if au.auAudioUnit.scheduleMIDIEventBlock != nil {
                    print("[DEBUG] scheduleMIDIEventBlock is available")
                } else {
                    print("[DEBUG] scheduleMIDIEventBlock is NIL - using MusicDeviceMIDIEvent")
                }
            }
        } else {
            print("[DEBUG] No instrument for track!")
        }
        print("[DEBUG] ========================================")
    }
    
    /// Load a SoundFont or default instrument into a sampler
    private func loadDefaultSound(for sampler: AVAudioUnitSampler) async throws {
        // Try to load the built-in piano sound from the system
        // This uses the DLS (Downloadable Sounds) format built into macOS
        
        // Path to the built-in Grand Piano
        let soundBankURL = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        
        if FileManager.default.fileExists(atPath: soundBankURL.path) {
            try sampler.loadSoundBankInstrument(
                at: soundBankURL,
                program: 0,        // Piano
                bankMSB: 0x79,     // Melodic bank
                bankLSB: 0
            )
        } else {
            // Fallback: Use a simple sine wave instrument
            // The sampler will produce a basic sound without a sound bank
            print("Warning: Could not load system sound bank, using basic synthesis")
        }
    }
    
    /// Load a custom SoundFont for a track
    public func loadSoundFont(url: URL, for trackID: TrackID, program: UInt8 = 0) async throws {
        guard case .sampler(let sampler) = trackInstruments[trackID] else {
            throw PlaybackError.instrumentNotLoaded(trackID)
        }
        
        try sampler.loadSoundBankInstrument(
            at: url,
            program: program,
            bankMSB: 0x79,
            bankLSB: 0
        )
    }
    
    /// Get the sampler for a track (for external use like note preview)
    /// Returns nil if track uses an AU instrument instead of sampler
    public func sampler(for trackID: TrackID) -> AVAudioUnitSampler? {
        if case .sampler(let sampler) = trackInstruments[trackID] {
            return sampler
        }
        return nil
    }
    
    // MARK: - Playback Control
    
    public func startPlayback() {
        guard let transport = transportState else { return }

        isPlaying = true
        
        // Calculate the starting sample position from beat position
        playbackStartBeat = transport.playbackStartBeat
        let sampleRate = coreAudioBackend?.sampleRate ?? audioEngine.sampleRate
        playbackStartSample = beatsToSamples(playbackStartBeat, tempo: transport.tempo.bpm, sampleRate: sampleRate)
        lastProcessedSample = playbackStartSample
        
        // Core Audio backend path (HYBRID MODE)
        if let backend = coreAudioBackend {
            print("[PlaybackEngine] ========================================")
            print("[PlaybackEngine] Starting HYBRID playback")
            print("[PlaybackEngine] Start beat: \(playbackStartBeat)")
            print("[PlaybackEngine] Start sample: \(playbackStartSample)")
            print("[PlaybackEngine] Sample rate: \(backend.sampleRate)")
            print("[PlaybackEngine] Buffer size: \(backend.bufferSize)")
            print("[PlaybackEngine] V-Rack MIDI events: \(scheduledMIDIEvents.count)")
            print("[PlaybackEngine] Audio clips: \(audioPlayerNodes.count)")
            print("[PlaybackEngine] ========================================")
            
            // Start playback via backend (for timing reference)
            backend.play(from: playbackStartSample)
            
            // HYBRID: Start audio clips through AVAudioEngine
            // This keeps them in sync with V-Rack instruments
            startAllAudioPlayers()
            
            // HYBRID: Start timer to process V-Rack MIDI events, metronome, and audio clips
            // This is needed because AVAudioEngine's timing tap may not fire
            // if no audio is flowing through it initially
            let hasVRackEvents = !scheduledMIDIEvents.isEmpty
            let hasMetronome = transport.isMetronomeEnabled
            let hasFutureAudioClips = audioClipInfo.values.contains { $0.clipStartBeat > playbackStartBeat }
            if hasVRackEvents || hasMetronome || hasFutureAudioClips {
                startHybridMIDITimer(tempo: transport.tempo.bpm, sampleRate: backend.sampleRate)
            }
            
            // Start metering
            startMetering()
            return
        }
        
        // Legacy AVAudioEngine path
        // Update audio engine tempo
        audioEngine.currentTempo = transport.tempo.bpm

        print("[PlaybackEngine] ========================================")
        print("[PlaybackEngine] Starting SAMPLE-ACCURATE playback (Legacy)")
        print("[PlaybackEngine] Start beat: \(playbackStartBeat)")
        print("[PlaybackEngine] Start sample: \(playbackStartSample)")
        print("[PlaybackEngine] Sample rate: \(audioEngine.sampleRate)")
        print("[PlaybackEngine] Buffer size: \(audioEngine.bufferSize) (~\(String(format: "%.1f", audioEngine.latencyMs))ms)")
        print("[PlaybackEngine] Scheduled MIDI events: \(scheduledMIDIEvents.count)")
        print("[PlaybackEngine] Loaded instruments: \(debugInstrumentList())")
        print("[PlaybackEngine] ========================================")
        
        // Start all scheduled audio player nodes
        startAllAudioPlayers()
        
        // Start metering (UI only, not timing-critical)
        startMetering()
        
        // Note: MIDI events are now processed in processAudioBuffer() 
        // which is called from the audio thread - no Timer needed!
    }
    
    /// Convert beats to samples
    private func beatsToSamples(_ beats: Double, tempo: Double, sampleRate: Double? = nil) -> Int64 {
        let sr = sampleRate ?? coreAudioBackend?.sampleRate ?? audioEngine.sampleRate
        let seconds = (beats / tempo) * 60.0
        return Int64(seconds * sr)
    }
    
    /// Convert samples to beats
    private func samplesToBeats(_ samples: Int64, tempo: Double, sampleRate: Double? = nil) -> Double {
        let sr = sampleRate ?? coreAudioBackend?.sampleRate ?? audioEngine.sampleRate
        let seconds = Double(samples) / sr
        return (seconds / 60.0) * tempo
    }
    
    /// Process MIDI events for the current audio buffer (called from audio thread)
    /// This is the heart of sample-accurate timing
    private func processAudioBuffer(startSample: Int64, frameCount: AVAudioFrameCount, tempo: Double) {
        guard isPlaying else { return }
        
        let bufferEndSample = startSample + Int64(frameCount)
        
        // Convert sample range to beat range
        let bufferStartBeat = samplesToBeats(startSample - playbackStartSample, tempo: tempo) + playbackStartBeat
        let bufferEndBeat = samplesToBeats(bufferEndSample - playbackStartSample, tempo: tempo) + playbackStartBeat
        
        // Dispatch MIDI processing to high-priority queue (NOT the audio thread)
        // This avoids blocking the audio render and prevents deadlocks
        midiProcessingQueue.async { [weak self] in
            guard let self = self, self.isPlaying else { return }
            
            // Process MIDI events that fall within this buffer's time window
            for i in 0..<self.scheduledMIDIEvents.count {
                guard !self.scheduledMIDIEvents[i].processed else { continue }
                
                let eventBeat = self.scheduledMIDIEvents[i].absoluteBeat
                
                // Skip events before our window
                guard eventBeat >= bufferStartBeat else { continue }
                
                // Stop if we're past the buffer window
                guard eventBeat < bufferEndBeat else { break }
                
                // Process the event immediately (AUEventSampleTimeImmediate since we're slightly behind)
                self.processEventSampleAccurate(self.scheduledMIDIEvents[i], sampleOffset: AUEventSampleTimeImmediate)
                self.scheduledMIDIEvents[i].processed = true
            }
            
            // Process note-offs
            self.processNoteOffsInBuffer(bufferStartBeat: bufferStartBeat, bufferEndBeat: bufferEndBeat, tempo: tempo)
        }
        
        // Update last processed position
        lastProcessedSample = bufferEndSample
    }
    
    // MARK: - Hybrid Mode Timer
    
    /// Start timer for processing V-Rack MIDI events in hybrid mode
    private func startHybridMIDITimer(tempo: Double, sampleRate: Double) {
        stopHybridMIDITimer()
        
        // Record the start time
        hybridPlaybackStartTime = mach_absolute_time()
        
        // Initialize metronome tracking based on start position:
        // - If starting exactly on a beat (e.g., 7.0), allow that beat's click
        // - If starting between beats (e.g., 7.5), wait for the next beat
        let startBeatFloor = floor(playbackStartBeat)
        if playbackStartBeat == startBeatFloor {
            // Exactly on a beat - set to previous so this beat's click will play
            lastMetronomeBeat = Int(startBeatFloor) - 1
        } else {
            // Between beats - set to current floor so we wait for next beat
            lastMetronomeBeat = Int(startBeatFloor)
        }
        
        // Track initial metronome state for detecting toggle-on during playback
        wasMetronomeEnabled = transportState?.isMetronomeEnabled ?? false
        
        // Create a timer that fires every ~5ms (matches typical audio buffer interval)
        let timer = DispatchSource.makeTimerSource(queue: midiProcessingQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        
        timer.setEventHandler { [weak self] in
            self?.processHybridMIDIEvents(tempo: tempo, sampleRate: sampleRate)
        }
        
        hybridMIDITimer = timer
        timer.resume()
        
        print("[PlaybackEngine] Started hybrid MIDI timer for V-Rack events")
    }
    
    /// Stop the hybrid MIDI timer
    private func stopHybridMIDITimer() {
        hybridMIDITimer?.cancel()
        hybridMIDITimer = nil
    }
    
    /// Process V-Rack MIDI events based on elapsed time
    private func processHybridMIDIEvents(tempo: Double, sampleRate: Double) {
        guard isPlaying else { return }
        
        // Calculate elapsed time in nanoseconds
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        
        let elapsed = mach_absolute_time() - hybridPlaybackStartTime
        let elapsedNanos = elapsed * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
        let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000.0
        
        // Convert to beat position
        let currentBeat = playbackStartBeat + (elapsedSeconds / 60.0) * tempo
        
        // Process metronome clicks
        if let transport = transportState {
            let isMetronomeOn = transport.isMetronomeEnabled
            
            // Detect when metronome is toggled ON during playback
            if isMetronomeOn && !wasMetronomeEnabled {
                // Just enabled - set lastMetronomeBeat to current beat
                // so we wait for the NEXT beat instead of clicking immediately
                let currentBeatInt = Int(floor(currentBeat))
                lastMetronomeBeat = currentBeatInt
                print("[PlaybackEngine] Metronome toggled ON at beat \(currentBeat), waiting for beat \(currentBeatInt + 1)")
            }
            wasMetronomeEnabled = isMetronomeOn
            
            if isMetronomeOn {
                let currentBeatInt = Int(floor(currentBeat))
                while lastMetronomeBeat < currentBeatInt {
                    lastMetronomeBeat += 1
                    let beatsPerBar = transport.timeSignature.beatsPerBar
                    let isDownbeat = (lastMetronomeBeat % beatsPerBar) == 0
                    audioEngine.playMetronomeClick(isDownbeat: isDownbeat)
                }
            }
        }
        
        // Check and start any audio clips that the playhead has reached
        checkAndStartAudioClips(currentBeat: currentBeat, tempo: tempo)
        
        // Process events up to current beat
        for i in 0..<scheduledMIDIEvents.count {
            guard !scheduledMIDIEvents[i].processed else { continue }
            
            let eventBeat = scheduledMIDIEvents[i].absoluteBeat
            
            // Process events that should have played by now
            if eventBeat <= currentBeat {
                processEventSampleAccurate(scheduledMIDIEvents[i], sampleOffset: AUEventSampleTimeImmediate)
                scheduledMIDIEvents[i].processed = true
            }
        }
        
        // Process note-offs - stop notes and remove from active list
        var indicesToRemove: [Int] = []
        for (index, note) in activeNotes.enumerated() {
            if note.endBeat <= currentBeat {
                let instrument: TrackInstrument? = {
                    switch note.midiOutput {
                    case .rackInstrument(let rackID, _):
                        return rackInstruments[rackID]
                    case .trackInstrument, .none:
                        return trackInstruments[note.trackID]
                    }
                }()
                instrument?.stopNote(note.pitch, channel: note.channel)
                indicesToRemove.append(index)
            }
        }
        // Remove in reverse order to preserve indices
        for index in indicesToRemove.reversed() {
            activeNotes.remove(at: index)
        }
    }
    
    /// Process a single MIDI event with sample-accurate timing
    /// Called from midiProcessingQueue - NOT the audio thread
    private func processEventSampleAccurate(_ scheduled: ScheduledEvent, sampleOffset: AUEventSampleTime) {
        // Determine the instrument and channel based on midiOutput routing
        let (instrument, channel): (TrackInstrument?, UInt8) = {
            switch scheduled.midiOutput {
            case .rackInstrument(let rackID, let ch):
                return (rackInstruments[rackID], ch - 1)
            case .trackInstrument, .none:
                return (trackInstruments[scheduled.trackID], 0)
            }
        }()
        
        guard let instrument = instrument else { return }
        
        switch scheduled.event.type {
        case .note(let noteData):
            // Send note immediately (we're already timed to the buffer)
            instrument.startNoteSampleAccurate(
                noteData.pitch,
                velocity: noteData.velocity,
                channel: channel,
                sampleOffset: sampleOffset
            )
            
            // Track active note for note-off
            let noteEndBeat = scheduled.absoluteBeat + noteData.duration
            activeNotes.append(ActiveNote(
                trackID: scheduled.trackID,
                pitch: noteData.pitch,
                channel: channel,
                endBeat: noteEndBeat,
                midiOutput: scheduled.midiOutput
            ))
            
        case .controlChange(let controller, let value):
            instrument.sendController(controller, value: value, channel: channel)
            
        case .programChange(let program):
            instrument.sendProgramChange(program, channel: channel)
            
        case .pitchBend(let value):
            let unsignedValue = UInt16(bitPattern: Int16(value + 8192))
            instrument.sendPitchBend(unsignedValue, channel: channel)
            
        default:
            break
        }
    }
    
    /// Process note-offs that fall within the buffer
    /// Called from midiProcessingQueue - NOT the audio thread
    private func processNoteOffsInBuffer(bufferStartBeat: Double, bufferEndBeat: Double, tempo: Double) {
        let notesToStop = activeNotes.filter { $0.endBeat >= bufferStartBeat && $0.endBeat < bufferEndBeat }
        
        for note in notesToStop {
            let instrument: TrackInstrument? = {
                switch note.midiOutput {
                case .rackInstrument(let rackID, _):
                    return rackInstruments[rackID]
                case .trackInstrument, .none:
                    return trackInstruments[note.trackID]
                }
            }()
            
            if let instrument = instrument {
                instrument.stopNoteSampleAccurate(note.pitch, channel: note.channel, sampleOffset: AUEventSampleTimeImmediate)
            }
        }
        
        activeNotes.removeAll { $0.endBeat < bufferEndBeat }
    }
    
    /// Start audio clips that should be playing immediately
    /// Clips scheduled for the future will be triggered by processHybridMIDIEvents
    private func startAllAudioPlayers() {
        guard let transport = transportState else { 
            print("[PlaybackEngine] No transport state")
            return 
        }
        
        // Use the captured start beat for consistent timing
        let currentBeat = playbackStartBeat
        let tempo = transport.tempo.bpm
        
        // Compensate for AVAudioPlayerNode output latency
        // There are multiple buffers in the audio chain (scheduling + output + OS audio)
        // Empirically determined compensation
        let latencyCompensationFrames = AVAudioFramePosition(audioEngine.bufferSize * 8)
        
        print("[PlaybackEngine] Starting audio players at beat \(currentBeat), \(audioPlayerNodes.count) clips, latency comp: \(latencyCompensationFrames) frames")
        
        for (clipID, playerNode) in audioPlayerNodes {
            guard let info = audioClipInfo[clipID],
                  let audioFile = audioClipFiles[clipID] else { continue }
            
            if currentBeat >= info.clipStartBeat && currentBeat < info.clipEndBeat {
                // Playhead is within this clip - start immediately with offset
                let offsetBeats = currentBeat - info.clipStartBeat
                let offsetSeconds = offsetBeats * 60.0 / tempo
                var offsetFrames = AVAudioFramePosition(offsetSeconds * audioFile.processingFormat.sampleRate)
                
                // Add latency compensation - skip ahead in the file to compensate for output latency
                offsetFrames += latencyCompensationFrames
                
                if offsetFrames < audioFile.length {
                    let remainingFrames = AVAudioFrameCount(audioFile.length - offsetFrames)
                    
                    // Schedule the segment and start playing
                    playerNode.scheduleSegment(
                        audioFile,
                        startingFrame: offsetFrames,
                        frameCount: remainingFrames,
                        at: nil
                    )
                    playerNode.play()
                    print("[PlaybackEngine] Started clip \(clipID) at offset \(offsetFrames) frames (includes \(latencyCompensationFrames) latency comp)")
                }
                
            } else if currentBeat < info.clipStartBeat {
                // Clip starts in the future - will be triggered by processHybridMIDIEvents
                print("[PlaybackEngine] Clip \(clipID) scheduled to start at beat \(info.clipStartBeat) (current: \(currentBeat))")
            }
        }
    }
    
    /// Check and start any audio clips that the playhead has reached
    /// Called from the hybrid timer during playback
    private func checkAndStartAudioClips(currentBeat: Double, tempo: Double) {
        // Compensate for AVAudioPlayerNode output latency (multiple buffers in chain)
        let latencyCompensationFrames = AVAudioFramePosition(audioEngine.bufferSize * 8)
        
        for (clipID, playerNode) in audioPlayerNodes {
            guard let info = audioClipInfo[clipID],
                  let audioFile = audioClipFiles[clipID] else { continue }
            
            // Check if we just reached this clip's start (within a small window)
            // Only start if not already playing
            if !playerNode.isPlaying && currentBeat >= info.clipStartBeat && currentBeat < info.clipEndBeat {
                // Calculate offset into the clip (in case we're slightly past the start)
                let offsetBeats = currentBeat - info.clipStartBeat
                let offsetSeconds = offsetBeats * 60.0 / tempo
                
                // Calculate frame offset with latency compensation
                var offsetFrames: AVAudioFramePosition
                if offsetSeconds > 0.05 {
                    offsetFrames = AVAudioFramePosition(offsetSeconds * audioFile.processingFormat.sampleRate)
                } else {
                    offsetFrames = 0
                }
                
                // Add latency compensation - skip ahead in the file
                offsetFrames += latencyCompensationFrames
                
                if offsetFrames < audioFile.length {
                    let remainingFrames = AVAudioFrameCount(audioFile.length - offsetFrames)
                    
                    playerNode.scheduleSegment(
                        audioFile,
                        startingFrame: offsetFrames,
                        frameCount: remainingFrames,
                        at: nil
                    )
                    playerNode.play()
                    print("[PlaybackEngine] Timer-triggered clip \(clipID) at beat \(currentBeat) (offset: \(offsetFrames) frames, includes latency comp)")
                }
            }
        }
    }
    
    public func stopPlayback() {
        isPlaying = false

        // Stop metering
        stopMetering()
        
        // Stop hybrid MIDI timer (if running)
        stopHybridMIDITimer()

        // Core Audio backend path (HYBRID MODE)
        if let backend = coreAudioBackend {
            backend.stopPlayback()
            backend.clearScheduledMIDIEvents()
            backend.clearAudioClips()
            
            // Stop V-Rack notes and clear events (hybrid mode)
            stopAllNotes()
            midiProcessingQueue.sync {
                scheduledMIDIEvents.removeAll()
                activeNotes.removeAll()
            }
            
            // Stop audio players (hybrid mode uses AVAudioEngine for audio clips)
            stopAllAudioPlayers()
            
            print("[PlaybackEngine] Stopped HYBRID playback")
            return
        }

        // Legacy path
        // Stop all active notes
        stopAllNotes()

        // Stop all audio players
        stopAllAudioPlayers()

        // Clear scheduled events (safe since isPlaying is false)
        midiProcessingQueue.sync {
            scheduledMIDIEvents.removeAll()
            activeNotes.removeAll()
        }
        
        print("[PlaybackEngine] Stopped playback at sample \(lastProcessedSample)")
    }
    
    public func pausePlayback() {
        isPlaying = false
        
        // Note: We don't stop notes on pause - they'll continue until their natural end
        // This matches DAW behavior where pausing doesn't cut notes off
    }
    
    // MARK: - Event Scheduling
    
    /// Prepare all clips for playback
    public func prepareForPlayback(project: Project) {
        // Core Audio backend path
        if let backend = coreAudioBackend {
            prepareForPlaybackCoreAudio(project: project, backend: backend)
            return
        }
        
        // Legacy path
        prepareForPlaybackLegacy(project: project)
    }
    
    /// Prepare playback using Core Audio backend
    private func prepareForPlaybackCoreAudio(project: Project, backend: AudioBackend) {
        // HYBRID MODE: 
        // - V-Rack instruments stay in AVAudioEngine and use legacy MIDI scheduling
        // - Audio clips play through AVAudioEngine for sync
        // - Track instruments use Core Audio backend (future)
        
        // IMPORTANT: Stop the hybrid MIDI timer FIRST to prevent race conditions
        // The timer accesses scheduledMIDIEvents and activeNotes on midiProcessingQueue
        stopHybridMIDITimer()
        
        // Clear previous events and players
        backend.clearScheduledMIDIEvents()
        backend.clearAudioClips()
        
        // Synchronize access to shared state with the MIDI processing queue
        midiProcessingQueue.sync {
            scheduledMIDIEvents.removeAll()
            activeNotes.removeAll()
        }
        
        // Clean up audio players (hybrid mode uses AVAudioEngine for audio)
        cleanupAudioPlayers()
        
        // Get start position
        if let transport = transportState {
            playbackStartBeat = transport.playbackStartBeat
            playbackStartSample = beatsToSamples(playbackStartBeat, tempo: transport.tempo.bpm)
            lastProcessedSample = playbackStartSample
        }
        
        let sampleRate = backend.sampleRate
        let tempo = project.tempo.bpm
        
        print("[PlaybackEngine] ========================================")
        print("[PlaybackEngine] Preparing HYBRID playback for \(project.tracks.count) tracks")
        print("[PlaybackEngine] Sample rate: \(sampleRate), Tempo: \(tempo)")
        print("[PlaybackEngine] Start beat: \(playbackStartBeat), Start sample: \(playbackStartSample)")
        print("[PlaybackEngine] ========================================")
        
        // Collect events - Core Audio backend events and legacy V-Rack events separately
        // Use local arrays first to avoid race conditions, then assign atomically
        var coreAudioMIDIEvents: [ScheduledMIDIEvent] = []
        var localScheduledMIDIEvents: [ScheduledEvent] = []
        
        for track in project.tracks {
            guard !track.isMuted else { continue }
            
            // Ensure track exists in backend
            try? backend.createTrack(id: track.id)
            backend.setTrackVolume(track.volume, for: track.id)
            backend.setTrackPan(track.pan, for: track.id)
            
            // Check if track routes to V-Rack
            let routesToVRack: Bool
            let vRackInfo: (rackID: UUID, channel: UInt8)?
            
            if case .rackInstrument(let rackID, let channel) = track.midiOutput {
                routesToVRack = true
                vRackInfo = (rackID, channel)
                print("[PlaybackEngine] Track '\(track.name)' routes to V-Rack \(rackID) ch \(channel) → LEGACY path")
            } else {
                routesToVRack = false
                vRackInfo = nil
                print("[PlaybackEngine] Track '\(track.name)' uses track instrument → CORE AUDIO path")
            }
            
            for clip in track.clips {
                guard !clip.isMuted else { continue }
                
                switch clip.content {
                case .midi(let midiData):
                    let clipStartBeat = clip.timeRange.start.beats(atTempo: tempo)
                    let clipEndBeat = clip.timeRange.end.beats(atTempo: tempo)
                    
                    for event in midiData.events {
                        let absoluteBeat = clipStartBeat + event.beatPosition
                        guard absoluteBeat >= clipStartBeat && absoluteBeat < clipEndBeat else { continue }
                        
                        if routesToVRack, let info = vRackInfo {
                            // V-RACK: Use legacy scheduling (will be processed via AVAudioEngine)
                            let scheduledEvent = ScheduledEvent(
                                trackID: track.id,
                                clipID: clip.id,
                                absoluteBeat: absoluteBeat,
                                event: event,
                                midiOutput: .rackInstrument(id: info.rackID, channel: info.channel)
                            )
                            localScheduledMIDIEvents.append(scheduledEvent)
                        } else {
                            // CORE AUDIO: Schedule to backend
                            let samplePos = Int64((absoluteBeat / tempo) * 60.0 * sampleRate)
                            
                            switch event.type {
                            case .note(let noteData):
                                let noteOn = ScheduledMIDIEvent.noteOn(
                                    trackID: track.id,
                                    samplePosition: samplePos,
                                    note: noteData.pitch,
                                    velocity: noteData.velocity,
                                    channel: 0
                                )
                                coreAudioMIDIEvents.append(noteOn)
                                
                                let durationSamples = Int64((noteData.duration / tempo) * 60.0 * sampleRate)
                                let noteOff = ScheduledMIDIEvent.noteOff(
                                    trackID: track.id,
                                    samplePosition: samplePos + durationSamples,
                                    note: noteData.pitch,
                                    channel: 0
                                )
                                coreAudioMIDIEvents.append(noteOff)
                                
                            case .controlChange(let cc, let value):
                                let ccEvent = ScheduledMIDIEvent.controlChange(
                                    trackID: track.id,
                                    samplePosition: samplePos,
                                    controller: cc,
                                    value: value,
                                    channel: 0
                                )
                                coreAudioMIDIEvents.append(ccEvent)
                                
                            default:
                                break
                            }
                        }
                    }
                    print("[PlaybackEngine] Collected \(midiData.events.count) MIDI events from '\(clip.name)'")
                    
                case .audio(let audioData):
                    // HYBRID MODE: Audio clips go through AVAudioEngine (same path as V-Rack)
                    // This ensures audio clips and V-Rack instruments stay in sync
                    // since they both play through AVAudioEngine's output
                    prepareAudioClipWithAVAudioPlayer(audioData, clip: clip, track: track, project: project)
                    print("[PlaybackEngine] Prepared audio clip '\(clip.name)' for HYBRID playback")
                    
                case .empty:
                    break
                }
            }
        }
        
        // HYBRID SCHEDULING:
        
        // 1. Sort and schedule Core Audio events
        coreAudioMIDIEvents.sort { $0.samplePosition < $1.samplePosition }
        for event in coreAudioMIDIEvents {
            backend.scheduleMIDIEvent(event)
        }
        
        // 2. Sort legacy V-Rack events by beat position
        localScheduledMIDIEvents.sort { $0.absoluteBeat < $1.absoluteBeat }
        
        // 3. Atomically assign to the shared state (thread-safe)
        midiProcessingQueue.sync {
            scheduledMIDIEvents = localScheduledMIDIEvents
        }
        
        print("[PlaybackEngine] HYBRID scheduling complete:")
        print("[PlaybackEngine]   Core Audio events: \(coreAudioMIDIEvents.count)")
        print("[PlaybackEngine]   V-Rack events (legacy): \(localScheduledMIDIEvents.count)")
        
        if let firstEvent = coreAudioMIDIEvents.first, let lastEvent = coreAudioMIDIEvents.last {
            print("[PlaybackEngine]   Core Audio range: sample \(firstEvent.samplePosition) to \(lastEvent.samplePosition)")
        }
        if let firstEvent = localScheduledMIDIEvents.first, let lastEvent = localScheduledMIDIEvents.last {
            print("[PlaybackEngine]   V-Rack range: beat \(firstEvent.absoluteBeat) to \(lastEvent.absoluteBeat)")
        }
        
        // HYBRID MODE: Metronome goes through AVAudioEngine (same path as audio/MIDI)
        // Don't use Core Audio backend metronome - it's on a separate audio path
        if let transport = transportState, transport.isMetronomeEnabled {
            audioEngine.setMetronomeEnabled(true)
            print("[PlaybackEngine] Metronome enabled via AVAudioEngine (hybrid sync)")
        }
    }
    
    /// Prepare playback using legacy AVAudioEngine
    private func prepareForPlaybackLegacy(project: Project) {
        // Stop any running timers first to prevent race conditions
        stopHybridMIDITimer()
        
        // Clear events with proper synchronization
        midiProcessingQueue.sync {
            scheduledMIDIEvents.removeAll()
            activeNotes.removeAll()
        }
        
        hasLoggedPlaybackDebug = false

        // Clean up old audio player nodes first
        cleanupAudioPlayers()

        // IMPORTANT: Use the transport's captured start position
        if let transport = transportState {
            playbackStartBeat = transport.playbackStartBeat
            playbackStartSample = beatsToSamples(playbackStartBeat, tempo: transport.tempo.bpm)
            lastProcessedSample = playbackStartSample
            print("[PlaybackEngine] Using transport's playbackStartBeat: \(playbackStartBeat) (sample: \(playbackStartSample))")
        }
        
        print("[PlaybackEngine] ========================================")
        print("[PlaybackEngine] Preparing playback for \(project.tracks.count) tracks")
        print("[PlaybackEngine] Loaded instruments: \(debugInstrumentList())")
        
        // List all track IDs for debugging
        for track in project.tracks {
            let hasInstrument = trackInstruments[track.id] != nil
            print("[PlaybackEngine] Track '\(track.name)' (ID: \(track.id.rawValue)) - instrument loaded: \(hasInstrument)")
        }
        print("[PlaybackEngine] ========================================")

        for track in project.tracks {
            // Skip muted tracks
            guard !track.isMuted else { continue }

            for clip in track.clips {
                guard !clip.isMuted else { continue }
                
                print("[PlaybackEngine] Processing clip '\(clip.name)' on track '\(track.name)' (ID: \(track.id.rawValue))")

                switch clip.content {
                case .midi(let midiData):
                    print("[PlaybackEngine] MIDI clip with \(midiData.events.count) events")
                    scheduleMIDIClip(midiData, clip: clip, track: track, project: project)

                case .audio(let audioData):
                    // Use simple AVAudioPlayer for reliable playback
                    prepareAudioClipWithAVAudioPlayer(audioData, clip: clip, track: track, project: project)
                    
                case .empty:
                    // Empty/placeholder clip - skip
                    break
                }
            }
        }
        
        // Sort by beat position for efficient processing (thread-safe)
        midiProcessingQueue.sync {
            scheduledMIDIEvents.sort { $0.absoluteBeat < $1.absoluteBeat }
        }
    }
    
    /// Clean up existing audio player nodes and AVAudioPlayers
    private func cleanupAudioPlayers() {
        // Clean up legacy AVAudioPlayerNode instances
        for (_, players) in trackPlayers {
            for (_, player) in players {
                player.stop()
                if player.engine != nil {
                    audioEngine.engine.disconnectNodeOutput(player)
                    audioEngine.engine.detach(player)
                }
            }
        }
        trackPlayers.removeAll()
        scheduledClips.removeAll()

        // Clean up sample-accurate player nodes
        for (_, nodes) in sampleAccurateNodes {
            for node in nodes {
                node.stop()
                if node.engine != nil {
                    audioEngine.engine.disconnectNodeOutput(node)
                    audioEngine.engine.detach(node)
                }
            }
        }
        sampleAccurateNodes.removeAll()

        // Clean up AVAudioPlayerNode instances
        for (_, playerNode) in audioPlayerNodes {
            playerNode.stop()
            audioEngine.engine.disconnectNodeOutput(playerNode)
            audioEngine.engine.detach(playerNode)
        }
        audioPlayerNodes.removeAll()
        audioClipFiles.removeAll()
        audioClipInfo.removeAll()
    }
    
    /// Prepare an audio clip for playback using AVAudioPlayerNode (synced with V-Rack through same engine)
    private func prepareAudioClipWithAVAudioPlayer(
        _ audioData: AudioClipData,
        clip: Clip,
        track: Track,
        project: Project
    ) {
        let fileURL = URL(fileURLWithPath: audioData.fileReference.originalPath)
        
        print("[PlaybackEngine] Preparing audio clip '\(clip.name)' with AVAudioPlayerNode from: \(fileURL.path)")
        
        // Check file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[PlaybackEngine] ERROR: Audio file not found: \(fileURL.path)")
            return
        }
        
        do {
            // Load the audio file
            let audioFile = try AVAudioFile(forReading: fileURL)
            
            guard audioFile.length > 0 else {
                print("[PlaybackEngine] ERROR: Audio file is empty")
                return
            }
            
            // Create AVAudioPlayerNode and attach to engine
            let playerNode = AVAudioPlayerNode()
            audioEngine.engine.attach(playerNode)
            
            // Connect to main mixer (same path as V-Rack instruments for perfect sync)
            let format = audioFile.processingFormat
            audioEngine.engine.connect(playerNode, to: audioEngine.engine.mainMixerNode, format: format)
            
            // Set volume
            playerNode.volume = track.volume * clip.gain
            
            // Store player node, file, and clip info
            audioPlayerNodes[clip.id] = playerNode
            audioClipFiles[clip.id] = audioFile
            
            let clipStartBeat = clip.timeRange.start.beats(atTempo: project.tempo.bpm)
            let clipEndBeat = clip.timeRange.end.beats(atTempo: project.tempo.bpm)
            
            audioClipInfo[clip.id] = AudioClipPlaybackInfo(
                clipID: clip.id,
                trackID: track.id,
                clipStartBeat: clipStartBeat,
                clipEndBeat: clipEndBeat,
                fileURL: fileURL,
                volume: track.volume * clip.gain
            )
            
            let fileDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            print("[PlaybackEngine] Prepared audio clip '\(clip.name)': \(fileDuration)s, beats \(clipStartBeat)-\(clipEndBeat)")
            
        } catch {
            print("[PlaybackEngine] ERROR preparing audio clip: \(error)")
        }
    }
    
    private func scheduleMIDIClip(
        _ midiData: MIDIClipData,
        clip: Clip,
        track: Track,
        project: Project
    ) {
        let clipStartBeat = clip.timeRange.start.beats(atTempo: project.tempo.bpm)
        let clipEndBeat = clip.timeRange.end.beats(atTempo: project.tempo.bpm)

        for event in midiData.events {
            let absoluteBeat = clipStartBeat + event.beatPosition

            // Skip events outside clip bounds
            guard absoluteBeat >= clipStartBeat && absoluteBeat < clipEndBeat else { continue }

            let scheduled = ScheduledEvent(
                trackID: track.id,
                clipID: clip.id,
                absoluteBeat: absoluteBeat,
                event: event,
                midiOutput: track.midiOutput  // Capture the track's routing
            )

            scheduledMIDIEvents.append(scheduled)
        }
    }
    
    /// Synchronous version of audio clip scheduling for reliable playback
    private func scheduleAudioClipSync(
        _ audioData: AudioClipData,
        clip: Clip,
        track: Track,
        project: Project
    ) {
        do {
            // Load the audio file - use original path (absolute) or fallback
            let fileURL = URL(fileURLWithPath: audioData.fileReference.originalPath)
            
            print("[PlaybackEngine] Scheduling audio clip '\(clip.name)' from: \(fileURL.path)")
            
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                print("[PlaybackEngine] ERROR: Audio file not found: \(fileURL.path)")
                return
            }
            
            let audioFile = try AVAudioFile(forReading: fileURL)
            
            // Validate the audio file has actual content
            guard audioFile.length > 0 else {
                print("[PlaybackEngine] ERROR: Audio file is empty: \(fileURL.path)")
                return
            }
            
            print("[PlaybackEngine] Loaded audio file: \(audioFile.length) frames, \(audioFile.fileFormat.sampleRate) Hz, \(audioFile.fileFormat.channelCount) channels")
            
            // Make sure the audio engine is running before attaching nodes
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            
            // Create player node
            let playerNode = AVAudioPlayerNode()
            audioEngine.engine.attach(playerNode)
            
            // Connect to track
            guard let trackNode = audioEngine.trackNode(for: track.id) else {
                print("[PlaybackEngine] ERROR: Track node not found for track \(track.id)")
                audioEngine.engine.detach(playerNode)
                return
            }
            
            // Use a standard format for connection to avoid format mismatches
            let format = audioFile.processingFormat
            audioEngine.engine.connect(playerNode, to: trackNode.inputMixer, format: format)
            print("[PlaybackEngine] Connected player to track '\(track.name)'")
            
            // Calculate timing
            guard let transport = transportState else {
                print("[PlaybackEngine] ERROR: No transport state")
                audioEngine.engine.detach(playerNode)
                return
            }
            
            let clipStartBeat = clip.timeRange.start.beats(atTempo: transport.tempo.bpm)
            let currentBeat = transport.playheadBeats
            
            print("[PlaybackEngine] Clip starts at beat \(clipStartBeat), playhead at \(currentBeat)")
            
            // Schedule and immediately start playback
            // Using play() + scheduleSegment/scheduleFile with at:nil together
            
            if clipStartBeat <= currentBeat {
                // Clip starts before or at current position - calculate offset
                let offsetBeats = currentBeat - clipStartBeat
                let offsetSeconds = offsetBeats * 60.0 / transport.tempo.bpm
                let offsetFrames = AVAudioFramePosition(offsetSeconds * audioFile.fileFormat.sampleRate)
                
                if offsetFrames < audioFile.length {
                    let remainingFrames = AVAudioFrameCount(audioFile.length - offsetFrames)
                    
                    // Validate we have frames to play
                    guard remainingFrames > 0 else {
                        print("[PlaybackEngine] No frames remaining to play")
                        audioEngine.engine.detach(playerNode)
                        return
                    }
                    
                    // Start the player FIRST, then schedule
                    // This is the correct order for AVAudioPlayerNode
                    playerNode.play()
                    
                    playerNode.scheduleSegment(
                        audioFile,
                        startingFrame: offsetFrames,
                        frameCount: remainingFrames,
                        at: nil
                    )
                    
                    print("[PlaybackEngine] Started and scheduled segment from frame \(offsetFrames), \(remainingFrames) frames")
                    
                    // Store for later cleanup
                    if trackPlayers[track.id] == nil {
                        trackPlayers[track.id] = [:]
                    }
                    trackPlayers[track.id]?[clip.id] = playerNode
                    scheduledClips.insert(clip.id)
                    
                } else {
                    print("[PlaybackEngine] Clip already finished at current position")
                    audioEngine.engine.detach(playerNode)
                    return
                }
            } else {
                // Clip starts in the future - we'll handle this with a timer
                // For now, just store it
                print("[PlaybackEngine] Clip starts in the future (beat \(clipStartBeat)), skipping for now")
                audioEngine.engine.detach(playerNode)
            }
            
        } catch {
            print("[PlaybackEngine] ERROR scheduling audio clip: \(error)")
        }
    }
    
    private func scheduleAudioClip(
        _ audioData: AudioClipData,
        clip: Clip,
        track: Track,
        project: Project
    ) {
        // Call the synchronous version
        scheduleAudioClipSync(audioData, clip: clip, track: track, project: project)
    }
    
    // MARK: - Playback Processing (Legacy methods removed - now using sample-accurate audio callback)
    
    private var hasLoggedPlaybackDebug = false
    
    /// Stop audio clips that have passed their end beat
    private func processAudioClipEndings(at currentBeat: Double) {
        var clipsToStop: [ClipID] = []
        
        for (clipID, info) in audioClipInfo {
            // Check if playhead has passed the clip's end beat
            if currentBeat >= info.clipEndBeat {
                // Only stop if the player is still playing
                if let playerNode = audioPlayerNodes[clipID], playerNode.isPlaying {
                    playerNode.stop()
                    clipsToStop.append(clipID)
                    print("[PlaybackEngine] Stopped audio clip \(clipID) at beat \(currentBeat) (end beat: \(info.clipEndBeat))")
                }
            }
        }
        
        // Remove stopped clips from tracking
        for clipID in clipsToStop {
            if let playerNode = audioPlayerNodes[clipID] {
                audioEngine.engine.disconnectNodeOutput(playerNode)
                audioEngine.engine.detach(playerNode)
            }
            audioPlayerNodes.removeValue(forKey: clipID)
            audioClipFiles.removeValue(forKey: clipID)
            audioClipInfo.removeValue(forKey: clipID)
        }
    }
    
    private func stopAllNotes() {
        for (trackID, instrument) in trackInstruments {
            for note in activeNotes where note.trackID == trackID {
                instrument.stopNote(note.pitch, channel: note.channel)
            }
        }
        activeNotes.removeAll()
    }
    
    private func stopAllAudioPlayers() {
        print("[PlaybackEngine] Stopping all audio players")
        
        // Stop legacy AVAudioPlayerNode instances
        for (_, players) in trackPlayers {
            for (clipID, player) in players {
                player.stop()
                print("[PlaybackEngine] Stopped AVAudioPlayerNode for clip \(clipID)")
            }
        }
        
        // Stop sample-accurate player nodes
        for (_, nodes) in sampleAccurateNodes {
            for node in nodes {
                node.stop()
            }
        }
        
        // Stop AVAudioPlayerNode instances
        for (clipID, playerNode) in audioPlayerNodes {
            playerNode.stop()
            print("[PlaybackEngine] Stopped AVAudioPlayerNode for clip \(clipID)")
        }
    }
    
    // MARK: - Real-time Volume Control
    
    /// Update volume for all audio clips on a track in real-time
    public func updateTrackVolume(_ trackID: TrackID, volume: Float) {
        for (clipID, info) in audioClipInfo {
            if info.trackID == trackID {
                if let playerNode = audioPlayerNodes[clipID] {
                    playerNode.volume = volume
                }
            }
        }
    }
    
    // MARK: - Metering
    
    private func startMetering() {
        meteringTimer?.invalidate()
        meteringTimer = Timer.scheduledTimer(withTimeInterval: meteringInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMeterLevels()
            }
        }
    }
    
    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        
        // Reset all levels to zero
        trackMeterLevels.removeAll()
        masterMeterLevel = (0, 0)
    }
    
    private func updateMeterLevels() {
        var newTrackLevels: [TrackID: (left: Float, right: Float)] = [:]
        var masterLeft: Float = 0
        var masterRight: Float = 0
        
        // Track which clips are playing via AVAudioPlayerNode
        for (clipID, playerNode) in audioPlayerNodes {
            guard playerNode.isPlaying else { continue }
            
            // AVAudioPlayerNode doesn't have built-in metering like AVAudioPlayer
            // For now, we estimate level based on volume setting
            // A more accurate approach would install a tap on each node
            if let info = audioClipInfo[clipID] {
                let trackID = info.trackID
                let estimatedLevel = playerNode.volume * 0.7  // Rough estimate
                
                // Accumulate levels per track (take max if multiple clips)
                if let existing = newTrackLevels[trackID] {
                    newTrackLevels[trackID] = (
                        left: max(existing.left, estimatedLevel),
                        right: max(existing.right, estimatedLevel)
                    )
                } else {
                    newTrackLevels[trackID] = (left: estimatedLevel, right: estimatedLevel)
                }
                
                // Accumulate for master
                masterLeft = max(masterLeft, estimatedLevel)
                masterRight = max(masterRight, estimatedLevel)
            }
        }
        
        trackMeterLevels = newTrackLevels
        masterMeterLevel = (masterLeft, masterRight)
    }
    
    /// Convert decibels to normalized 0-1 level
    private func normalizedLevel(fromDecibels dB: Float) -> Float {
        // dB range is typically -160 to 0, map to 0-1
        // Use -60 dB as effective floor for display
        let minDB: Float = -60
        let maxDB: Float = 0
        
        if dB <= minDB { return 0 }
        if dB >= maxDB { return 1 }
        
        return (dB - minDB) / (maxDB - minDB)
    }
    
    // MARK: - Note Preview
    
    /// Play a note immediately for preview (piano roll, keyboard)
    public func playNotePreview(pitch: UInt8, velocity: UInt8, on trackID: TrackID) {
        // Core Audio backend path
        if let backend = coreAudioBackend {
            backend.sendImmediateMIDI(status: 0x90, data1: pitch, data2: velocity, to: trackID)
            return
        }
        
        // Legacy path
        guard let instrument = trackInstruments[trackID] else { return }
        instrument.startNote(pitch, velocity: velocity, channel: 0)
    }
    
    /// Stop a preview note
    public func stopNotePreview(pitch: UInt8, on trackID: TrackID) {
        // Core Audio backend path
        if let backend = coreAudioBackend {
            backend.sendImmediateMIDI(status: 0x80, data1: pitch, data2: 0, to: trackID)
            return
        }
        
        // Legacy path
        guard let instrument = trackInstruments[trackID] else { return }
        instrument.stopNote(pitch, channel: 0)
    }
    
    /// Play a test note to verify audio is working
    public func playTestNote(on trackID: TrackID) {
        // Core Audio backend path
        if let backend = coreAudioBackend {
            backend.sendImmediateMIDI(status: 0x90, data1: 60, data2: 100, to: trackID)
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { [weak self] in
                    self?.coreAudioBackend?.sendImmediateMIDI(status: 0x80, data1: 60, data2: 0, to: trackID)
                }
            }
            return
        }
        
        // Legacy path
        guard let instrument = trackInstruments[trackID] else { return }
        
        // Middle C at medium velocity
        instrument.startNote(60, velocity: 100, channel: 0)
        
        // Stop after 0.5 seconds
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { [weak self] in
                self?.trackInstruments[trackID]?.stopNote(60, channel: 0)
            }
        }
    }
    
    // MARK: - Cleanup
    
    public func cleanup() {
        stopPlayback()
        
        // Detach all instruments
        for instrument in trackInstruments.values {
            audioEngine.engine.detach(instrument.audioNode)
        }
        trackInstruments.removeAll()
        
        // Detach all players
        for players in trackPlayers.values {
            for player in players.values {
                audioEngine.engine.detach(player)
            }
        }
        trackPlayers.removeAll()
    }
}

// MARK: - Supporting Types

private struct ScheduledEvent {
    let trackID: TrackID
    let clipID: ClipID
    let absoluteBeat: Double
    let event: MIDIEvent
    let midiOutput: MIDIOutputDestination?  // Where to route this event
    var processed: Bool = false
}

private struct ActiveNote {
    let trackID: TrackID
    let pitch: UInt8
    let channel: UInt8
    let endBeat: Double
    let midiOutput: MIDIOutputDestination?  // For proper note-off routing
}

/// Info about an audio clip for playback timing
private struct AudioClipPlaybackInfo {
    let clipID: ClipID
    let trackID: TrackID
    let clipStartBeat: Double
    let clipEndBeat: Double
    let fileURL: URL
    let volume: Float
}

// MARK: - Errors

public enum PlaybackError: Error, LocalizedError {
    case trackNotFound(TrackID)
    case instrumentNotLoaded(TrackID)
    case soundBankLoadFailed(URL, Error)
    case audioFileLoadFailed(URL, Error)
    
    public var errorDescription: String? {
        switch self {
        case .trackNotFound(let id):
            return "Track not found: \(id.rawValue)"
        case .instrumentNotLoaded(let id):
            return "Instrument not loaded for track: \(id.rawValue)"
        case .soundBankLoadFailed(let url, let error):
            return "Failed to load sound bank at \(url): \(error.localizedDescription)"
        case .audioFileLoadFailed(let url, let error):
            return "Failed to load audio file at \(url): \(error.localizedDescription)"
        }
    }
}

// MARK: - Track Instrument

/// Represents an instrument on a track - either an AU instrument plugin or fallback sampler
public enum TrackInstrument {
    case auInstrument(AVAudioUnit, pluginID: UUID)
    case sampler(AVAudioUnitSampler)
    
    /// The underlying audio unit node
    public var audioNode: AVAudioNode {
        switch self {
        case .auInstrument(let au, _): return au
        case .sampler(let sampler): return sampler
        }
    }
    
    /// Send a MIDI note on event (immediate - for preview/live playing)
    public func startNote(_ note: UInt8, velocity: UInt8, channel: UInt8) {
        startNoteSampleAccurate(note, velocity: velocity, channel: channel, sampleOffset: AUEventSampleTimeImmediate)
    }
    
    /// Send a MIDI note on event with sample-accurate timing
    public func startNoteSampleAccurate(_ note: UInt8, velocity: UInt8, channel: UInt8, sampleOffset: AUEventSampleTime) {
        switch self {
        case .auInstrument(let au, _):
            // Prefer scheduleMIDIEventBlock for sample-accurate timing
            if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                var noteOnData: [UInt8] = [0x90 | (channel & 0x0F), note, velocity]
                noteOnData.withUnsafeMutableBufferPointer { buffer in
                    block(sampleOffset, 0, 3, buffer.baseAddress!)
                }
            } else {
                // Fallback to MusicDeviceMIDIEvent (not sample-accurate)
                let status = UInt32(0x90 | (channel & 0x0F))
                MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(note), UInt32(velocity), 0)
            }
        case .sampler(let sampler):
            sampler.startNote(note, withVelocity: velocity, onChannel: channel)
        }
    }
    
    /// Send a MIDI note off event (immediate)
    public func stopNote(_ note: UInt8, channel: UInt8) {
        stopNoteSampleAccurate(note, channel: channel, sampleOffset: AUEventSampleTimeImmediate)
    }
    
    /// Send a MIDI note off event with sample-accurate timing
    public func stopNoteSampleAccurate(_ note: UInt8, channel: UInt8, sampleOffset: AUEventSampleTime) {
        switch self {
        case .auInstrument(let au, _):
            // Prefer scheduleMIDIEventBlock for sample-accurate timing
            if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                var noteOffData: [UInt8] = [0x80 | (channel & 0x0F), note, 0]
                noteOffData.withUnsafeMutableBufferPointer { buffer in
                    block(sampleOffset, 0, 3, buffer.baseAddress!)
                }
            } else {
                // Fallback to MusicDeviceMIDIEvent (not sample-accurate)
                let status = UInt32(0x80 | (channel & 0x0F))
                MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(note), 0, 0)
            }
        case .sampler(let sampler):
            sampler.stopNote(note, onChannel: channel)
        }
    }
    
    /// Send a control change
    public func sendController(_ controller: UInt8, value: UInt8, channel: UInt8) {
        switch self {
        case .auInstrument(let au, _):
            let status = UInt32(0xB0 | (channel & 0x0F))
            let result = MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(controller), UInt32(value), 0)
            if result != noErr {
                if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                    var ccData: [UInt8] = [0xB0 | (channel & 0x0F), controller, value]
                    ccData.withUnsafeMutableBufferPointer { buffer in
                        block(AUEventSampleTimeImmediate, 0, 3, buffer.baseAddress!)
                    }
                }
            }
        case .sampler(let sampler):
            sampler.sendController(controller, withValue: value, onChannel: channel)
        }
    }
    
    /// Send a program change
    public func sendProgramChange(_ program: UInt8, channel: UInt8) {
        switch self {
        case .auInstrument(let au, _):
            let status = UInt32(0xC0 | (channel & 0x0F))
            let result = MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(program), 0, 0)
            if result != noErr {
                if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                    var pgmData: [UInt8] = [0xC0 | (channel & 0x0F), program]
                    pgmData.withUnsafeMutableBufferPointer { buffer in
                        block(AUEventSampleTimeImmediate, 0, 2, buffer.baseAddress!)
                    }
                }
            }
        case .sampler(let sampler):
            sampler.sendProgramChange(program, onChannel: channel)
        }
    }

    /// Send pitch bend
    public func sendPitchBend(_ value: UInt16, channel: UInt8) {
        switch self {
        case .auInstrument(let au, _):
            let lsb = UInt8(value & 0x7F)
            let msb = UInt8((value >> 7) & 0x7F)
            let status = UInt32(0xE0 | (channel & 0x0F))
            let result = MusicDeviceMIDIEvent(au.audioUnit, status, UInt32(lsb), UInt32(msb), 0)
            if result != noErr {
                if let block = au.auAudioUnit.scheduleMIDIEventBlock {
                    var pbData: [UInt8] = [0xE0 | (channel & 0x0F), lsb, msb]
                    pbData.withUnsafeMutableBufferPointer { buffer in
                        block(AUEventSampleTimeImmediate, 0, 3, buffer.baseAddress!)
                    }
                }
            }
        case .sampler(let sampler):
            sampler.sendPitchBend(value, onChannel: channel)
        }
    }
}

