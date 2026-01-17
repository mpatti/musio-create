import Foundation
import AudioToolbox
import CoreAudio
import AVFoundation

// MARK: - Core Audio Backend

/// Professional-grade audio backend using direct Core Audio APIs
/// Provides sample-accurate timing, direct AudioUnit hosting, and offline bounce
public final class CoreAudioBackend: AudioBackend {
    
    // MARK: - Properties
    
    /// Output Audio Unit (hardware interface)
    private var outputUnit: AudioComponentInstance?
    
    /// Render graph for track/plugin management
    private var renderGraph: RenderGraph!
    
    /// MIDI event scheduler
    private var midiScheduler: MIDIScheduler!
    
    /// Audio clip renderer
    private var audioClipRenderer: AudioClipRenderer!
    
    /// Metronome renderer
    private var metronomeRenderer: MetronomeRenderer!
    
    /// Offline bounce engine
    private var offlineBounce: OfflineBounce!
    
    // MARK: - State (Atomic for thread safety)
    
    private var _isRunning: Bool = false
    private var _isPlaying: Bool = false
    private var _currentSamplePosition: Int64 = 0
    private var _playbackStartSample: Int64 = 0
    private var _sampleRate: Double = 44100
    private var _bufferSize: UInt32 = 512
    private var _masterVolume: Float = 1.0
    private var _tempo: Double = 120.0
    
    // MARK: - AudioBackend Protocol Properties
    
    public var isRunning: Bool { _isRunning }
    public var sampleRate: Double { _sampleRate }
    public var bufferSize: UInt32 { _bufferSize }
    public var currentSamplePosition: Int64 { _currentSamplePosition }
    public var isPlaying: Bool { _isPlaying }
    public var masterVolume: Float { _masterVolume }
    
    // MARK: - Initialization
    
    public init() {
        print("[CoreAudioBackend] Initializing...")
        
        // Get sample rate from system
        _sampleRate = getSystemSampleRate()
        
        // Initialize components
        midiScheduler = MIDIScheduler(capacity: 32768)
        renderGraph = RenderGraph(sampleRate: _sampleRate, bufferSize: Int(_bufferSize))
        audioClipRenderer = AudioClipRenderer(sampleRate: _sampleRate)
        metronomeRenderer = MetronomeRenderer(sampleRate: _sampleRate)
        offlineBounce = OfflineBounce(renderGraph: renderGraph, midiScheduler: midiScheduler, audioClipRenderer: audioClipRenderer, metronomeRenderer: metronomeRenderer)
        
        // Setup output unit
        setupOutputUnit()
        
        print("[CoreAudioBackend] Initialized with sample rate: \(_sampleRate)")
    }
    
    deinit {
        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
    }
    
    // MARK: - Output Unit Setup
    
    private func getSystemSampleRate() -> Double {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        
        propertyAddress.mSelector = kAudioDevicePropertyNominalSampleRate
        propertyAddress.mScope = kAudioObjectPropertyScopeGlobal
        
        var sampleRate: Double = 44100
        size = UInt32(MemoryLayout<Double>.size)
        
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &sampleRate)
        
        return sampleRate
    }
    
    private func setupOutputUnit() {
        // Find default output component
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        guard let component = AudioComponentFindNext(nil, &desc) else {
            fatalError("[CoreAudioBackend] Could not find default output audio unit")
        }
        
        var status = AudioComponentInstanceNew(component, &outputUnit)
        guard status == noErr, let unit = outputUnit else {
            fatalError("[CoreAudioBackend] Could not create output unit: \(status)")
        }
        
        // Set stream format
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: _sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        
        if status != noErr {
            print("[CoreAudioBackend] Warning: Could not set stream format: \(status)")
        }
        
        // Set render callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: coreAudioRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        
        guard status == noErr else {
            fatalError("[CoreAudioBackend] Could not set render callback: \(status)")
        }
        
        // Initialize
        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            fatalError("[CoreAudioBackend] Could not initialize output unit: \(status)")
        }
        
        print("[CoreAudioBackend] Output unit configured")
    }
    
    // MARK: - Lifecycle
    
    public func start() throws {
        guard let unit = outputUnit, !_isRunning else { return }
        
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw AudioBackendError.failedToStart("AudioOutputUnitStart failed: \(status)")
        }
        
        _isRunning = true
        print("[CoreAudioBackend] Started")
    }
    
    public func stop() {
        guard let unit = outputUnit, _isRunning else { return }
        
        AudioOutputUnitStop(unit)
        _isRunning = false
        _isPlaying = false
        
        print("[CoreAudioBackend] Stopped")
    }
    
    // MARK: - Track Management
    
    public func createTrack(id: TrackID) throws {
        renderGraph.createTrack(id: id)
    }
    
    public func removeTrack(id: TrackID) {
        renderGraph.removeTrack(id: id)
    }
    
    public func setTrackVolume(_ volume: Float, for trackID: TrackID) {
        renderGraph.setTrackVolume(volume, for: trackID)
    }
    
    public func setTrackPan(_ pan: Float, for trackID: TrackID) {
        renderGraph.setTrackPan(pan, for: trackID)
    }
    
    public func setTrackMute(_ muted: Bool, for trackID: TrackID) {
        renderGraph.setTrackMute(muted, for: trackID)
    }
    
    // MARK: - Plugin Hosting
    
    public func loadInstrument(
        _ description: AudioComponentDescription,
        for trackID: TrackID
    ) async throws -> AudioUnit {
        return try await renderGraph.loadInstrument(description, for: trackID)
    }
    
    public func loadEffect(
        _ description: AudioComponentDescription,
        for trackID: TrackID,
        slot: Int
    ) async throws -> AudioUnit {
        return try await renderGraph.loadEffect(description, for: trackID, slot: slot)
    }
    
    public func unloadPlugin(for trackID: TrackID, slot: Int) {
        renderGraph.unloadPlugin(for: trackID, slot: slot)
    }
    
    public func getInstrumentAudioUnit(for trackID: TrackID) -> AudioUnit? {
        return renderGraph.getInstrumentUnit(for: trackID)
    }
    
    // MARK: - MIDI
    
    private var scheduledEventCount = 0
    
    public func scheduleMIDIEvent(_ event: ScheduledMIDIEvent) {
        midiScheduler.schedule(event)
        scheduledEventCount += 1
    }
    
    public func sendImmediateMIDI(status: UInt8, data1: UInt8, data2: UInt8, to trackID: TrackID) {
        guard let unit = renderGraph.getInstrumentUnit(for: trackID) else { return }
        MusicDeviceMIDIEvent(unit, UInt32(status), UInt32(data1), UInt32(data2), 0)
    }
    
    public func clearScheduledMIDIEvents() {
        midiScheduler.clear()
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
        try audioClipRenderer.scheduleClip(
            url: url,
            trackID: trackID,
            startSample: startSample,
            offsetSample: offsetSample,
            endSample: endSample,
            volume: volume
        )
    }
    
    public func clearAudioClips() {
        audioClipRenderer.clearClips()
    }
    
    // MARK: - Playback Control
    
    private var renderCallCount = 0
    private var lastLogTime: UInt64 = 0
    
    public func play(from samplePosition: Int64) {
        _playbackStartSample = samplePosition
        _currentSamplePosition = samplePosition
        _isPlaying = true
        renderCallCount = 0
        
        print("[CoreAudioBackend] ========================================")
        print("[CoreAudioBackend] Playing from sample \(samplePosition)")
        print("[CoreAudioBackend] Scheduled events: \(scheduledEventCount)")
        print("[CoreAudioBackend] MIDI scheduler event count: \(midiScheduler.eventCount)")
        print("[CoreAudioBackend] Is running: \(_isRunning)")
        print("[CoreAudioBackend] ========================================")
    }
    
    public func pause() {
        _isPlaying = false
        print("[CoreAudioBackend] Paused at sample \(_currentSamplePosition)")
    }
    
    public func stopPlayback() {
        _isPlaying = false
        
        // Stop all notes
        renderGraph.allNotesOff()
        
        print("[CoreAudioBackend] Stopped playback")
    }
    
    public func seek(to samplePosition: Int64) {
        _currentSamplePosition = samplePosition
        _playbackStartSample = samplePosition
    }
    
    // MARK: - Metronome
    
    public func setMetronomeEnabled(_ enabled: Bool) {
        metronomeRenderer.isEnabled = enabled
    }
    
    public func setMetronomeVolume(_ volume: Float) {
        metronomeRenderer.volume = volume
    }
    
    public func scheduleMetronomeClicks(
        from startBeat: Double,
        to endBeat: Double,
        tempo: Double,
        timeSignature: TimeSignature
    ) {
        _tempo = tempo
        metronomeRenderer.scheduleClicks(
            from: startBeat,
            to: endBeat,
            tempo: tempo,
            sampleRate: _sampleRate,
            timeSignature: timeSignature
        )
    }
    
    // MARK: - Offline Bounce
    
    public func bounceOffline(
        from startSample: Int64,
        to endSample: Int64,
        outputURL: URL,
        progress: ((Double) -> Void)?
    ) async throws {
        try await offlineBounce.bounce(
            from: startSample,
            to: endSample,
            outputURL: outputURL,
            sampleRate: _sampleRate,
            progress: progress
        )
    }
    
    // MARK: - Configuration
    
    public func setBufferSize(_ size: UInt32) throws {
        guard let unit = outputUnit else { return }
        
        var bufferFrameSize = size
        let status = AudioUnitSetProperty(
            unit,
            kAudioDevicePropertyBufferFrameSize,
            kAudioUnitScope_Global,
            0,
            &bufferFrameSize,
            UInt32(MemoryLayout<UInt32>.size)
        )
        
        if status == noErr {
            _bufferSize = size
            renderGraph.setBufferSize(Int(size))
            print("[CoreAudioBackend] Buffer size set to \(size)")
        } else {
            throw AudioBackendError.configurationError("Could not set buffer size: \(status)")
        }
    }
    
    public func setMasterVolume(_ volume: Float) {
        _masterVolume = volume
        renderGraph.setMasterVolume(volume)
    }
    
    // MARK: - Render Callback (Called from Audio Thread)
    
    /// The main render function - called from the audio thread
    /// This is where all sample-accurate processing happens
    func render(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32,
        bufferList: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let bufferList = bufferList else { return noErr }
        
        // Clear output buffer
        clearBuffer(bufferList, frameCount: frameCount)
        
        guard _isPlaying else {
            // Output silence when not playing
            return noErr
        }
        
        renderCallCount += 1
        
        let startSample = _currentSamplePosition
        let endSample = startSample + Int64(frameCount)
        
        // Debug logging (throttled to once per second)
        let now = mach_absolute_time()
        if now - lastLogTime > 1_000_000_000 {  // ~1 second
            print("[CoreAudioBackend:Render] Sample range: \(startSample)-\(endSample), Events pending: \(midiScheduler.eventCount)")
            lastLogTime = now
        }
        
        // 1. Process MIDI events for this buffer
        let eventsProcessed = midiScheduler.processEvents(
            startSample: startSample,
            endSample: endSample,
            renderGraph: renderGraph
        )
        
        if eventsProcessed > 0 {
            print("[CoreAudioBackend:Render] Processed \(eventsProcessed) MIDI events at sample \(startSample)")
        }
        
        // 2. Render all tracks through the graph
        renderGraph.render(
            frameCount: frameCount,
            currentSample: startSample,
            outputBuffer: bufferList
        )
        
        // 3. Render audio clips
        audioClipRenderer.render(
            into: bufferList,
            currentSample: startSample,
            frameCount: frameCount
        )
        
        // 4. Render metronome
        metronomeRenderer.render(
            into: bufferList,
            currentSample: startSample,
            frameCount: frameCount
        )
        
        // 5. Apply master volume
        applyMasterVolume(bufferList, volume: _masterVolume, frameCount: frameCount)
        
        // 6. Update position
        _currentSamplePosition = endSample
        
        return noErr
    }
    
    // MARK: - Buffer Helpers
    
    private func clearBuffer(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in ablPointer {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
    
    private func applyMasterVolume(_ bufferList: UnsafeMutablePointer<AudioBufferList>, volume: Float, frameCount: UInt32) {
        guard volume != 1.0 else { return }
        
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in ablPointer {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<Int(frameCount) {
                data[i] *= volume
            }
        }
    }
}

// MARK: - Render Callback (C Function)

/// The C render callback that bridges to Swift
private func coreAudioRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let backend = Unmanaged<CoreAudioBackend>.fromOpaque(inRefCon).takeUnretainedValue()
    return backend.render(
        ioActionFlags: ioActionFlags,
        timeStamp: inTimeStamp,
        busNumber: inBusNumber,
        frameCount: inNumberFrames,
        bufferList: ioData
    )
}
