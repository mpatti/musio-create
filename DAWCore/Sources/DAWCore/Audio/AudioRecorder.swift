import Foundation
import AVFoundation
import Combine

// MARK: - Debug Logging

private func debugLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let logMessage = "[\(timestamp)] \(message)\n"
    print(logMessage)
    
    // Also write to file for GUI app debugging
    let logPath = "/tmp/dawapp_audio.log"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        if let data = logMessage.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: logMessage.data(using: .utf8), attributes: nil)
    }
}

// MARK: - Audio Recorder

/// Handles audio recording from input devices
@MainActor
public final class AudioRecorder: ObservableObject {
    
    // MARK: - Properties
    
    private let audioEngine: AudioEngine
    private var inputNode: AVAudioInputNode?
    private var recordingFile: AVAudioFile?
    private var recordingFormat: AVAudioFormat?
    
    // Recording state
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var inputLevel: Float = 0
    @Published public private(set) var peakLevel: Float = 0
    
    // Real-time waveform data for visualization
    @Published public private(set) var waveformSamples: [Float] = []
    public let waveformUpdateSubject = PassthroughSubject<[Float], Never>()
    
    // Recording settings
    public var recordingDirectory: URL?
    public var sampleRate: Double = 44100
    public var channelCount: Int = 2
    public var bitDepth: Int = 24
    
    // Monitoring
    public var inputMonitoringEnabled: Bool = false
    
    // Current recording info
    private var recordingStartTime: Date?
    private var recordingURL: URL?
    private var recordingSampleCount: Int64 = 0
    
    // Level metering
    private var meterTimer: Timer?
    
    // Waveform buffer for visualization
    private var waveformBuffer: [Float] = []
    private let waveformDownsampleFactor: Int = 512  // Samples per waveform point
    private var sampleAccumulator: Float = 0
    private var sampleCount: Int = 0
    
    // Combine
    private var cancellables = Set<AnyCancellable>()
    
    // Input monitoring
    private var isMonitoringInput: Bool = false
    private var monitoringTapInstalled: Bool = false
    
    // MARK: - Initialization
    
    public init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }
    
    // MARK: - Input Monitoring (for level meters when armed but not recording)
    
    /// Check and request microphone permission
    public func requestMicrophonePermission() async -> Bool {
        // First check current status
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        debugLog("Current microphone authorization status: \(status.rawValue)")
        
        switch status {
        case .authorized:
            debugLog("Microphone: Already authorized")
            return true
        case .notDetermined:
            debugLog("Microphone: Not determined, requesting access...")
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    debugLog("Microphone access \(granted ? "granted" : "denied")")
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            debugLog("Microphone: Access denied. Please enable in System Preferences → Privacy & Security → Microphone")
            return false
        case .restricted:
            debugLog("Microphone: Access restricted by system policy")
            return false
        @unknown default:
            debugLog("Microphone: Unknown authorization status")
            return false
        }
    }
    
    /// Start monitoring input levels (call when track is armed)
    public func startInputMonitoring() {
        guard !isMonitoringInput, !isRecording else { 
            debugLog("Already monitoring or recording, skipping startInputMonitoring")
            return 
        }
        
        debugLog("startInputMonitoring called")
        
        // First check/request microphone permission
        Task {
            let granted = await requestMicrophonePermission()
            guard granted else {
                debugLog("Microphone permission not granted - cannot monitor input")
                // Try anyway for non-sandboxed apps
                debugLog("Attempting to start monitoring anyway...")
                await MainActor.run {
                    self.startInputMonitoringInternal()
                }
                return
            }
            
            await MainActor.run {
                self.startInputMonitoringInternal()
            }
        }
    }
    
    private func startInputMonitoringInternal() {
        debugLog("startInputMonitoringInternal: Starting...")
        do {
            // Make sure audio engine is running
            debugLog("Ensuring audio engine is running...")
            try audioEngine.ensureRunning()
            debugLog("Audio engine running: \(audioEngine.engine.isRunning)")
            
            let inputNode = audioEngine.engine.inputNode
            debugLog("Got input node: \(inputNode)")
            
            // Get the input format from the hardware
            let hardwareFormat = inputNode.inputFormat(forBus: 0)
            debugLog("Hardware input format: \(hardwareFormat)")
            
            // Get the output format of the input node (what it sends to the rest of the graph)
            let format = inputNode.outputFormat(forBus: 0)
            debugLog("Input node output format: \(format)")
            
            // Check if format is valid
            guard format.sampleRate > 0, format.channelCount > 0 else {
                debugLog("Invalid input format - trying to use hardware format")
                
                // Try using the hardware format directly
                guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
                    debugLog("Hardware format also invalid: \(hardwareFormat)")
                    return
                }
                
                // Remove existing tap if any
                if monitoringTapInstalled {
                    inputNode.removeTap(onBus: 0)
                    monitoringTapInstalled = false
                }
                
                // Install tap with nil format (use default)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                    self?.processMonitoringBuffer(buffer)
                }
                
                monitoringTapInstalled = true
                isMonitoringInput = true
                debugLog("Started input monitoring with default format")
                return
            }
            
            // Remove existing tap if any
            if monitoringTapInstalled {
                inputNode.removeTap(onBus: 0)
                monitoringTapInstalled = false
            }
            
            // Install tap for monitoring
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.processMonitoringBuffer(buffer)
            }
            
            monitoringTapInstalled = true
            isMonitoringInput = true
            debugLog("Started input monitoring with format: \(format)")
            
        } catch {
            debugLog("Failed to start input monitoring: \(error)")
        }
    }
    
    /// Stop monitoring input levels
    public func stopInputMonitoring() {
        guard isMonitoringInput, !isRecording else { return }
        
        if monitoringTapInstalled {
            let inputNode = audioEngine.engine.inputNode
            inputNode.removeTap(onBus: 0)
            monitoringTapInstalled = false
        }
        
        isMonitoringInput = false
        inputLevel = 0
        debugLog("Stopped input monitoring")
    }
    
    private var monitoringBufferCount = 0
    
    private func processMonitoringBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        var maxSample: Float = 0
        let frameLength = Int(buffer.frameLength)
        
        for channel in 0..<Int(buffer.format.channelCount) {
            for sample in 0..<frameLength {
                let absSample = abs(channelData[channel][sample])
                maxSample = max(maxSample, absSample)
            }
        }
        
        monitoringBufferCount += 1
        if monitoringBufferCount % 50 == 1 {
            debugLog("Input monitoring: buffer #\(monitoringBufferCount), level: \(maxSample)")
        }
        
        Task { @MainActor in
            self.inputLevel = maxSample
        }
    }
    
    // MARK: - Input Device Setup
    
    /// Get list of available audio input devices
    public func availableInputDevices() -> [AudioInputDevice] {
        var devices: [AudioInputDevice] = []
        
        // Get system audio devices
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr else { return devices }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        
        guard status == noErr else { return devices }
        
        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputPropertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var inputDataSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputPropertyAddress, 0, nil, &inputDataSize)
            
            guard status == noErr, inputDataSize > 0 else { continue }
            
            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferList.deallocate() }
            
            status = AudioObjectGetPropertyData(deviceID, &inputPropertyAddress, 0, nil, &inputDataSize, bufferList)
            
            guard status == noErr else { continue }
            
            var inputChannels: UInt32 = 0
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for buffer in buffers {
                inputChannels += buffer.mNumberChannels
            }
            
            guard inputChannels > 0 else { continue }
            
            // Get device name
            var namePropertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &namePropertyAddress, 0, nil, &nameSize, &name)
            
            devices.append(AudioInputDevice(
                id: deviceID,
                name: name as String,
                channelCount: Int(inputChannels)
            ))
        }
        
        return devices
    }
    
    /// Set the input device to use for recording
    public func setInputDevice(_ device: AudioInputDevice) throws {
        // In AVAudioEngine, input device is system-controlled
        // For device selection, you'd use Audio HAL APIs
        // This is a placeholder for the full implementation
    }
    
    // MARK: - Recording Control
    
    /// Start recording to a file
    public func startRecording(
        trackID: TrackID,
        filename: String? = nil
    ) throws -> URL {
        guard !isRecording else {
            throw RecordingError.alreadyRecording
        }
        
        // Stop monitoring if active (we'll use the recording tap instead)
        if isMonitoringInput {
            stopInputMonitoring()
        }
        
        // Ensure audio engine is running
        try audioEngine.ensureRunning()
        
        // Ensure recording directory exists
        let directory = recordingDirectory ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // Generate filename
        let name = filename ?? "Recording_\(Date().timeIntervalSince1970)"
        let fileURL = directory.appendingPathComponent("\(name).wav")
        
        // Get input node
        inputNode = audioEngine.engine.inputNode
        guard let inputNode = inputNode else {
            throw RecordingError.noInputAvailable
        }
        
        // Get input format - use the output format of the input node (what comes from the tap)
        let tapFormat = inputNode.outputFormat(forBus: 0)
        
        // We want to record in stereo - create a stereo format at the same sample rate
        let recordingSampleRate = tapFormat.sampleRate > 0 ? tapFormat.sampleRate : 48000.0
        sampleRate = recordingSampleRate
        
        // Create a stereo recording format
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: recordingSampleRate, channels: 2) else {
            throw RecordingError.invalidFormat
        }
        
        debugLog("Tap format: \(tapFormat)")
        debugLog("Recording stereo format: \(stereoFormat)")
        
        // Create output file settings - stereo WAV at input sample rate
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: recordingSampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        // Create recording file
        recordingFile = try AVAudioFile(
            forWriting: fileURL,
            settings: outputSettings
        )
        
        recordingFormat = stereoFormat
        channelCount = 2
        
        // Clear waveform data
        waveformBuffer.removeAll()
        waveformSamples.removeAll()
        sampleAccumulator = 0
        sampleCount = 0
        
        // Install tap on input node - use nil format to get default
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nil  // Use default format from the node
        ) { [weak self] buffer, time in
            self?.processRecordingBuffer(buffer)
        }
        
        // Update state
        isRecording = true
        recordingStartTime = Date()
        recordingURL = fileURL
        recordingSampleCount = 0
        peakLevel = 0
        
        // Start level metering
        startLevelMetering()
        
        debugLog("Started recording to: \(fileURL)")
        
        return fileURL
    }
    
    /// Stop recording and finalize the file
    public func stopRecording() -> RecordingResult? {
        guard isRecording, let inputNode = inputNode else { return nil }
        
        // Remove tap
        inputNode.removeTap(onBus: 0)
        
        // Stop level metering
        stopLevelMetering()
        
        // Finalize file
        let result: RecordingResult?
        if let url = recordingURL,
           let startTime = recordingStartTime,
           let file = recordingFile {
            result = RecordingResult(
                fileURL: url,
                duration: Date().timeIntervalSince(startTime),
                sampleCount: recordingSampleCount,
                sampleRate: sampleRate,
                channelCount: channelCount,
                peakLevel: peakLevel
            )
        } else {
            result = nil
        }
        
        // Reset state
        isRecording = false
        recordingFile = nil
        recordingURL = nil
        recordingStartTime = nil
        self.inputNode = nil
        
        return result
    }
    
    /// Cancel recording and delete the file
    public func cancelRecording() {
        guard isRecording else { return }
        
        let url = recordingURL
        _ = stopRecording()
        
        // Delete the file
        if let url = url {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    // MARK: - Buffer Processing
    
    private func processRecordingBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let file = recordingFile,
              let channelData = buffer.floatChannelData else { return }
        
        let frameLength = Int(buffer.frameLength)
        let inputChannelCount = Int(buffer.format.channelCount)
        
        // Convert to stereo if needed
        do {
            // Create a stereo buffer at the same sample rate
            guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 2),
                  let stereoBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: buffer.frameCapacity) else {
                debugLog("Failed to create stereo buffer")
                return
            }
            
            stereoBuffer.frameLength = buffer.frameLength
            
            guard let stereoChannelData = stereoBuffer.floatChannelData else { return }
            
            // Mix input channels to stereo
            // If input has 1 channel: mono to both L/R
            // If input has 2 channels: copy directly
            // If input has more: use first 2 or mix
            for frame in 0..<frameLength {
                if inputChannelCount == 1 {
                    // Mono to stereo
                    let sample = channelData[0][frame]
                    stereoChannelData[0][frame] = sample
                    stereoChannelData[1][frame] = sample
                } else if inputChannelCount >= 2 {
                    // Use first two channels
                    stereoChannelData[0][frame] = channelData[0][frame]
                    stereoChannelData[1][frame] = channelData[1][frame]
                }
            }
            
            // Write stereo buffer to file
            try file.write(from: stereoBuffer)
            recordingSampleCount += Int64(buffer.frameLength)
            
            // Update duration
            Task { @MainActor in
                self.recordingDuration = Double(self.recordingSampleCount) / self.sampleRate
            }
        } catch {
            debugLog("Error writing audio buffer: \(error)")
        }
        
        // Calculate levels and update waveform
        var maxSample: Float = 0
        var newWaveformPoints: [Float] = []
        
        for sample in 0..<frameLength {
            // Mix channels to mono for visualization
            var monoSample: Float = 0
            for channel in 0..<min(2, inputChannelCount) {
                monoSample += channelData[channel][sample]
            }
            monoSample /= Float(min(2, inputChannelCount))
            
            let absSample = abs(monoSample)
            maxSample = max(maxSample, absSample)
            
            // Accumulate for waveform downsampling
            sampleAccumulator = max(sampleAccumulator, absSample)
            sampleCount += 1
            
            if sampleCount >= waveformDownsampleFactor {
                newWaveformPoints.append(sampleAccumulator)
                sampleAccumulator = 0
                sampleCount = 0
            }
        }
        
        Task { @MainActor in
            self.inputLevel = maxSample
            self.peakLevel = max(self.peakLevel, maxSample)
            
            // Update waveform
            if !newWaveformPoints.isEmpty {
                self.waveformBuffer.append(contentsOf: newWaveformPoints)
                self.waveformSamples = self.waveformBuffer
                self.waveformUpdateSubject.send(self.waveformBuffer)
            }
        }
    }
    
    // MARK: - Level Metering
    
    private func startLevelMetering() {
        // Decay peak level over time
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Decay input level when not receiving audio
                self.inputLevel *= 0.9
            }
        }
    }
    
    private func stopLevelMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        inputLevel = 0
    }
    
    // MARK: - Input Monitoring
    
    /// Enable/disable input monitoring (hear yourself while recording)
    public func setInputMonitoring(enabled: Bool, volume: Float = 1.0) {
        inputMonitoringEnabled = enabled
        
        // Connect input to output for monitoring
        // Note: This can cause feedback with speakers - should only use with headphones
        if enabled {
            let inputNode = audioEngine.engine.inputNode
            let mainMixer = audioEngine.engine.mainMixerNode
            let format = inputNode.outputFormat(forBus: 0)
            
            // Create a mixer for monitoring level control
            let monitorMixer = AVAudioMixerNode()
            audioEngine.engine.attach(monitorMixer)
            monitorMixer.outputVolume = volume
            
            audioEngine.engine.connect(inputNode, to: monitorMixer, format: format)
            audioEngine.engine.connect(monitorMixer, to: mainMixer, format: format)
        }
    }
}

// MARK: - Audio Input Device

public struct AudioInputDevice: Identifiable, Sendable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public let channelCount: Int
    public let channels: [AudioInputChannel]
    
    public init(id: AudioDeviceID, name: String, channelCount: Int) {
        self.id = id
        self.name = name
        self.channelCount = channelCount
        // Create channel list
        var channels: [AudioInputChannel] = []
        for i in 0..<channelCount {
            channels.append(AudioInputChannel(
                deviceID: id,
                channelIndex: i,
                name: "Input \(i + 1)"
            ))
        }
        // Add stereo pairs
        if channelCount >= 2 {
            for i in stride(from: 0, to: channelCount - 1, by: 2) {
                channels.append(AudioInputChannel(
                    deviceID: id,
                    channelIndex: i,
                    channelIndex2: i + 1,
                    name: "Input \(i + 1)-\(i + 2) (Stereo)",
                    isStereo: true
                ))
            }
        }
        self.channels = channels
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: AudioInputDevice, rhs: AudioInputDevice) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Audio Input Channel

public struct AudioInputChannel: Identifiable, Sendable, Hashable {
    public let id: String
    public let deviceID: AudioDeviceID
    public let channelIndex: Int
    public let channelIndex2: Int?  // For stereo pairs
    public let name: String
    public let isStereo: Bool
    
    public init(deviceID: AudioDeviceID, channelIndex: Int, channelIndex2: Int? = nil, name: String, isStereo: Bool = false) {
        self.id = "\(deviceID)-\(channelIndex)-\(channelIndex2 ?? -1)"
        self.deviceID = deviceID
        self.channelIndex = channelIndex
        self.channelIndex2 = channelIndex2
        self.name = name
        self.isStereo = isStereo
    }
}

// MARK: - Recording Result

public struct RecordingResult: Sendable {
    public let fileURL: URL
    public let duration: TimeInterval
    public let sampleCount: Int64
    public let sampleRate: Double
    public let channelCount: Int
    public let peakLevel: Float
    
    public var normalizedPeakDB: Float {
        20 * log10(peakLevel)
    }
}

// MARK: - Recording Error

public enum RecordingError: Error, LocalizedError {
    case alreadyRecording
    case noInputAvailable
    case fileCreationFailed(URL)
    case permissionDenied
    case deviceNotFound
    case invalidFormat
    
    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Already recording"
        case .noInputAvailable:
            return "No audio input available"
        case .fileCreationFailed(let url):
            return "Failed to create recording file at \(url)"
        case .invalidFormat:
            return "Invalid audio format"
        case .permissionDenied:
            return "Microphone access denied"
        case .deviceNotFound:
            return "Audio device not found"
        }
    }
}

// MARK: - MIDI Recorder

/// Handles recording of MIDI input
@MainActor
public final class MIDIRecorderManager: ObservableObject {
    
    // MARK: - Properties
    
    private let midiManager: MIDIManager
    private weak var transportState: TransportState?
    
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var recordedEventCount: Int = 0
    /// Real-time stream of recorded events for live display
    @Published public private(set) var liveRecordedEvents: [MIDIEvent] = []
    /// The beat position where recording started (for positioning notes on timeline)
    @Published public private(set) var liveRecordingStartBeat: Double = 0
    
    private var recordedEvents: [MIDIEvent] = []
    private var recordingStartBeat: Double = 0
    private var recordingStartSamplePosition: Int64 = 0  // Sample position when recording started
    private var pendingNotes: [UInt8: (startBeat: Double, velocity: UInt8, channel: UInt8)] = [:]
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init(midiManager: MIDIManager) {
        self.midiManager = midiManager
        setupMIDIListener()
    }
    
    private func setupMIDIListener() {
        midiManager.midiEventSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMIDIEvent(event)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Recording Control
    
    public func bind(to transportState: TransportState) {
        self.transportState = transportState
    }
    
    public func startRecording() {
        guard let transport = transportState else { return }
        
        isRecording = true
        recordedEvents.removeAll()
        liveRecordedEvents.removeAll()
        pendingNotes.removeAll()
        recordedEventCount = 0
        recordingStartBeat = transport.playheadBeats
        liveRecordingStartBeat = recordingStartBeat
        recordingStartSamplePosition = transport.getCurrentSamplePosition()
        
        // Clear and start log
        try? "".write(toFile: "/tmp/midi_recording.log", atomically: true, encoding: .utf8)
        midiLog("=== RECORDING STARTED ===")
        midiLog("startBeat=\(recordingStartBeat), startSamplePos=\(recordingStartSamplePosition)")
        midiLog("tempo=\(transport.tempo.bpm) BPM, sampleRate=\(transport.sampleRate)")
    }
    
    public func stopRecording() -> [MIDIEvent] {
        guard isRecording, let transport = transportState else { return [] }
        
        // Close any pending notes at current sample position
        let currentSamplePosition = transport.getCurrentSamplePosition()
        let currentBeat = transport.samplePositionToBeats(currentSamplePosition)
        
        for (pitch, noteInfo) in pendingNotes {
            let duration = max(0.01, currentBeat - noteInfo.startBeat)
            let event = MIDIEvent.note(
                at: noteInfo.startBeat - recordingStartBeat,
                pitch: pitch,
                velocity: noteInfo.velocity,
                duration: duration,
                channel: noteInfo.channel
            )
            recordedEvents.append(event)
            print("[MIDIRecorder] Closing pending note \(pitch) with duration \(String(format: "%.3f", duration))")
        }
        
        isRecording = false
        pendingNotes.removeAll()
        
        let events = recordedEvents
        recordedEvents.removeAll()
        liveRecordedEvents.removeAll()
        
        print("[MIDIRecorder] Stopped recording. Total events: \(events.count)")
        for event in events {
            print("[MIDIRecorder]   - Beat \(String(format: "%.3f", event.beatPosition)): \(event.type)")
        }
        
        return events
    }
    
    /// Get the beat position when recording started (for clip placement)
    public var currentRecordingStartBeat: Double {
        recordingStartBeat
    }
    
    public func cancelRecording() {
        isRecording = false
        recordedEvents.removeAll()
        pendingNotes.removeAll()
        recordedEventCount = 0
    }
    
    // MARK: - MIDI Event Handling
    
    private func handleMIDIEvent(_ event: IncomingMIDIEvent) {
        guard isRecording, let transport = transportState else { return }
        
        // Get the current sample position from the audio engine via transport
        // This is the SINGLE SOURCE OF TRUTH for timing
        let currentSamplePosition = transport.hostTimeToSamplePosition(event.hostTime)
        let eventBeat = transport.samplePositionToBeats(currentSamplePosition)
        let relativeBeat = eventBeat - recordingStartBeat
        
        midiLog("Event: samplePos=\(currentSamplePosition), beat=\(String(format: "%.3f", eventBeat)), relative=\(String(format: "%.3f", relativeBeat))")
        
        switch event.type {
        case .note(let noteData):
            midiLog("RAW NOTE: pitch=\(noteData.pitch), velocity=\(noteData.velocity), beat=\(String(format: "%.3f", relativeBeat))")
            
            // Check if this is a note-off:
            // - velocity = 0 (standard note-off)
            // - velocity = 1 (some keyboards use this for note-off)
            // - OR there's already a pending note for this pitch (re-trigger = complete old note first)
            let isNoteOff = noteData.velocity == 0 || noteData.velocity == 1
            let hasPendingNote = pendingNotes[noteData.pitch] != nil
            
            if isNoteOff || (hasPendingNote && noteData.velocity < 10) {
                // Note off - complete the pending note
                if let pending = pendingNotes.removeValue(forKey: noteData.pitch) {
                    let duration = max(0.01, eventBeat - pending.startBeat)
                    let relativeStart = pending.startBeat - recordingStartBeat
                    let noteEvent = MIDIEvent.note(
                        at: relativeStart,
                        pitch: noteData.pitch,
                        velocity: pending.velocity,
                        duration: duration,
                        channel: pending.channel
                    )
                    recordedEvents.append(noteEvent)
                    recordedEventCount = recordedEvents.count
                    // Update live events for real-time display
                    liveRecordedEvents = recordedEvents
                    midiLog("  -> NOTE OFF: start=\(String(format: "%.3f", relativeStart)), dur=\(String(format: "%.3f", duration))")
                } else {
                    midiLog("  -> NOTE OFF ignored (no pending note)")
                }
            } else if noteData.velocity > 0 {
                // Note on - store as pending with precise beat position
                // First complete any existing pending note for this pitch
                if let pending = pendingNotes.removeValue(forKey: noteData.pitch) {
                    let duration = max(0.01, eventBeat - pending.startBeat)
                    let relativeStart = pending.startBeat - recordingStartBeat
                    let noteEvent = MIDIEvent.note(
                        at: relativeStart,
                        pitch: noteData.pitch,
                        velocity: pending.velocity,
                        duration: duration,
                        channel: pending.channel
                    )
                    recordedEvents.append(noteEvent)
                    // Update live events for real-time display
                    liveRecordedEvents = recordedEvents
                    midiLog("  -> AUTO NOTE OFF (retrigger): start=\(String(format: "%.3f", relativeStart)), dur=\(String(format: "%.3f", duration))")
                }
                
                pendingNotes[noteData.pitch] = (
                    startBeat: eventBeat,
                    velocity: noteData.velocity,
                    channel: event.channel
                )
                midiLog("  -> NOTE ON stored")
            }
            
        case .controlChange(let controller, let value):
            let ccEvent = MIDIEvent.controlChange(
                at: relativeBeat,
                controller: controller,
                value: value,
                channel: event.channel
            )
            recordedEvents.append(ccEvent)
            recordedEventCount = recordedEvents.count
            
        case .pitchBend(let value):
            let pbEvent = MIDIEvent.pitchBend(
                at: relativeBeat,
                value: value,
                channel: event.channel
            )
            recordedEvents.append(pbEvent)
            recordedEventCount = recordedEvents.count
            
        default:
            break
        }
    }
    
    /// Write MIDI debug log to file
    private func midiLog(_ message: String) {
        let logMessage = "[MIDIRecorder] \(message)\n"
        let logPath = "/tmp/midi_recording.log"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            if let data = logMessage.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: logMessage.data(using: .utf8), attributes: nil)
        }
    }
    
    // MARK: - Create Clip from Recording
    
    public func createClip(
        from events: [MIDIEvent],
        name: String = "Recorded MIDI",
        quantize: Bool = false,
        gridDivision: Double = 0.25
    ) -> Clip? {
        guard !events.isEmpty else { return nil }
        
        // Find the extent of the recorded events
        var minBeat = Double.infinity
        var maxBeat = Double.zero
        
        var processedEvents = events
        
        for event in events {
            minBeat = min(minBeat, event.beatPosition)
            
            if case .note(let data) = event.type {
                maxBeat = max(maxBeat, event.beatPosition + data.duration)
            } else {
                maxBeat = max(maxBeat, event.beatPosition)
            }
        }
        
        // Optionally quantize
        if quantize {
            processedEvents = events.map { event in
                var quantized = event
                let quantizedBeat = TimeUtilities.quantize(
                    beats: event.beatPosition,
                    gridDivision: gridDivision,
                    mode: .nearest
                )
                quantized.beatPosition = quantizedBeat
                return quantized
            }
        }
        
        // Normalize event positions (relative to clip start)
        processedEvents = processedEvents.map { event in
            var normalized = event
            normalized.beatPosition -= minBeat
            return normalized
        }
        
        // Create clip
        guard let transportState = transportState else { return nil }
        
        let tempo = transportState.tempo.bpm
        let sampleRate = 44100.0  // Would come from project
        
        // IMPORTANT: Events are stored relative to recordingStartBeat
        // So the absolute clip position is recordingStartBeat + minBeat
        let absoluteStartBeat = recordingStartBeat + minBeat
        let clipStart = TimePosition(beats: absoluteStartBeat, tempo: tempo, sampleRate: sampleRate)
        let clipDuration = TimePosition(beats: max(0.25, maxBeat - minBeat), tempo: tempo, sampleRate: sampleRate)
        
        print("[MIDIRecorder] Creating clip at absolute beat \(absoluteStartBeat), duration \(maxBeat - minBeat) beats")
        print("[MIDIRecorder] Event range: \(minBeat) to \(maxBeat)")
        
        let midiData = MIDIClipData(events: processedEvents, originalTempo: tempo)
        
        return Clip(
            name: name,
            timeRange: TimeRange(start: clipStart, duration: clipDuration),
            content: .midi(midiData)
        )
    }
}
