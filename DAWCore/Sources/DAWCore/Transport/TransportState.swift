import Foundation
import Combine
import ObjectiveC
import CoreVideo

// Debug logging to file
private func transportLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let logMessage = "[Transport \(timestamp)] \(message)\n"
    
    let logPath = "/tmp/dawapp_transport.log"
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

// MARK: - Transport State

/// Represents the current transport state of the DAW
@MainActor
public final class TransportState: ObservableObject {
    // MARK: - Published Properties
    
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var isPaused: Bool = false
    
    @Published public var tempo: Tempo = Tempo(bpm: 120) {
        didSet {
            tempoSubject.send(tempo)
        }
    }
    
    @Published public var timeSignature: TimeSignature = .common
    
    @Published public private(set) var playheadPosition: TimePosition = TimePosition()
    @Published public private(set) var playheadBeats: Double = 0.0
    
    @Published public var isLoopEnabled: Bool = false
    @Published public var loopStart: TimePosition = TimePosition()
    @Published public var loopEnd: TimePosition = TimePosition(beats: 4, tempo: 120)
    
    @Published public var isMetronomeEnabled: Bool = false
    @Published public var metronomeVolume: Float = 0.7
    
    @Published public var isCountInEnabled: Bool = false
    @Published public var countInBars: Int = 1
    
    // Solo state (derived from tracks)
    @Published public var hasSoloedTracks: Bool = false
    
    // MARK: - Combine Subjects
    
    /// High-frequency playhead updates (for UI rendering)
    public let playheadSubject = PassthroughSubject<TimePosition, Never>()
    
    /// Tempo changes
    public let tempoSubject = PassthroughSubject<Tempo, Never>()
    
    /// Transport events (play, stop, etc.)
    public let transportEventSubject = PassthroughSubject<TransportEvent, Never>()
    
    // MARK: - Internal State
    
    private var playStartTime: Date?
    private var playStartPosition: TimePosition = TimePosition()
    private var playbackTimer: Timer?
    private var lastToggleTime: Date = .distantPast
    
    /// The exact beat position when playback started - use this for sync!
    @Published public private(set) var playbackStartBeat: Double = 0
    
    /// The sample position when playback started
    public private(set) var playbackStartSamplePosition: Int64 = 0
    
    public var sampleRate: Double = 44100
    
    /// Reference to audio engine for sample-accurate timing
    private weak var audioEngine: AudioEngine?
    private var samplePositionCancellable: AnyCancellable?
    
    // MARK: - Initialization
    
    public init() {}
    
    deinit {
        playbackTimer?.invalidate()
        samplePositionCancellable?.cancel()
    }
    
    // MARK: - Audio Engine Binding
    
    /// Bind to audio engine for sample-accurate timing
    public func bind(to engine: AudioEngine) {
        self.audioEngine = engine
        self.sampleRate = engine.sampleRate
        
        // Subscribe to sample position updates from audio engine
        samplePositionCancellable = engine.samplePositionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] samplePosition in
                self?.updatePlayheadFromSamplePosition(samplePosition)
            }
        
        transportLog("Bound to AudioEngine, sampleRate=\(sampleRate)")
    }
    
    /// Update playhead from audio engine's sample position
    private func updatePlayheadFromSamplePosition(_ samplePosition: Int64) {
        guard isPlaying else { return }
        
        // Convert sample position to time position
        playheadPosition = TimePosition(samples: samplePosition, sampleRate: sampleRate)
        playheadBeats = playheadPosition.beats(atTempo: tempo.bpm)
        
        // Handle looping
        if isLoopEnabled {
            let loopEndBeat = loopEnd.beats(atTempo: tempo.bpm)
            if playheadBeats >= loopEndBeat {
                let loopStartBeat = loopStart.beats(atTempo: tempo.bpm)
                setPlayheadBeats(loopStartBeat)
            }
        }
        
        playheadSubject.send(playheadPosition)
    }
    
    /// Get the current sample position from audio engine
    public func getCurrentSamplePosition() -> Int64 {
        return audioEngine?.getCurrentSamplePosition() ?? playheadPosition.samples
    }
    
    /// Convert a host time (mach_absolute_time) to sample position
    public func hostTimeToSamplePosition(_ hostTime: UInt64) -> Int64 {
        return audioEngine?.hostTimeToSamplePosition(hostTime) ?? playheadPosition.samples
    }
    
    /// Convert sample position to beat position
    public func samplePositionToBeats(_ samplePosition: Int64) -> Double {
        let seconds = Double(samplePosition) / sampleRate
        return (seconds / 60.0) * tempo.bpm
    }
    
    // MARK: - Transport Controls
    
    public func play() {
        transportLog("play() called, isPlaying=\(isPlaying), isPaused=\(isPaused)")
        guard !isPlaying else { 
            transportLog("Already playing, returning early")
            return 
        }
        
        // CRITICAL: Capture the EXACT position BEFORE anything else
        // This is the position that audio/MIDI playback must use
        playbackStartBeat = playheadBeats
        playStartPosition = playheadPosition
        playbackStartSamplePosition = playheadPosition.samples
        
        isPlaying = true
        isPaused = false
        
        transportLog("Captured playbackStartBeat=\(playbackStartBeat), samplePos=\(playbackStartSamplePosition)")
        
        // Send the event FIRST so preparation can happen at the captured position
        transportLog("Sending .play event")
        transportEventSubject.send(.play)
        
        // Start audio engine playback if bound
        if let engine = audioEngine {
            engine.startPlayback(from: playbackStartSamplePosition)
            transportLog("Started audio engine playback")
        } else {
            // Fallback to timer-based playback if no audio engine
            playStartTime = Date()
            transportLog("Starting fallback playback timer (no audio engine)")
            startPlaybackTimer()
        }
        
        transportLog("play() complete, isPlaying=\(isPlaying)")
    }
    
    public func stop() {
        transportLog("stop() called, isPlaying=\(isPlaying), isRecording=\(isRecording)")
        let wasPlaying = isPlaying
        
        isPlaying = false
        isPaused = false
        isRecording = false
        
        // Stop audio engine playback
        audioEngine?.stopPlayback()
        
        // Stop fallback playback timer
        stopPlaybackTimer()
        transportLog("Playback stopped")
        
        // Return to start position (or loop start if looping)
        if wasPlaying {
            if isLoopEnabled {
                playheadPosition = loopStart
                playheadBeats = loopStart.beats(atTempo: tempo.bpm)
            } else {
                playheadPosition = TimePosition(sampleRate: sampleRate)
                playheadBeats = 0
            }
            transportLog("Reset playhead to \(playheadBeats)")
        }
        
        transportEventSubject.send(.stop)
        transportLog("stop() complete, isPlaying=\(isPlaying)")
    }
    
    public func pause() {
        guard isPlaying else { return }
        
        isPlaying = false
        isPaused = true
        isRecording = false
        
        // Stop playback timer
        stopPlaybackTimer()
        
        transportEventSubject.send(.pause)
    }
    
    // MARK: - Playback Timer
    
    private var displayLink: CVDisplayLink?
    private var useDisplayLink = false
    
    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        timerUpdateCount = 0
        
        // Use a CADisplayLink-style approach via DispatchSource for reliable updates
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16)) // ~60fps
        timer.setEventHandler { [weak self] in
            self?.updatePlayheadFromTimer()
        }
        timer.resume()
        
        // Store as Any to work with DispatchSourceTimer
        objc_setAssociatedObject(self, "dispatchTimer", timer, .OBJC_ASSOCIATION_RETAIN)
        
        transportLog("Playback timer started (DispatchSource)")
    }
    
    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        
        // Cancel dispatch timer if exists
        if let timer = objc_getAssociatedObject(self, "dispatchTimer") as? DispatchSourceTimer {
            timer.cancel()
            objc_setAssociatedObject(self, "dispatchTimer", nil, .OBJC_ASSOCIATION_RETAIN)
        }
        
        transportLog("Playback timer stopped")
    }
    
    private var timerUpdateCount = 0
    
    private func updatePlayheadFromTimer() {
        guard isPlaying, let startTime = playStartTime else { return }
        
        let elapsedSeconds = Date().timeIntervalSince(startTime)
        let newSamples = playStartPosition.samples + Int64(elapsedSeconds * sampleRate)
        
        playheadPosition = TimePosition(samples: newSamples, sampleRate: sampleRate)
        playheadBeats = playheadPosition.beats(atTempo: tempo.bpm)
        
        timerUpdateCount += 1
        if timerUpdateCount % 60 == 1 {
            // Also calculate expected beats directly from elapsed time for comparison
            let expectedBeats = playbackStartBeat + (elapsedSeconds / 60.0) * tempo.bpm
            transportLog("Timer #\(timerUpdateCount): beats=\(String(format: "%.2f", playheadBeats)) expected=\(String(format: "%.2f", expectedBeats)) elapsed=\(String(format: "%.2f", elapsedSeconds))s")
        }
        
        // Handle looping
        if isLoopEnabled {
            let loopEndBeat = loopEnd.beats(atTempo: tempo.bpm)
            if playheadBeats >= loopEndBeat {
                let loopStartBeat = loopStart.beats(atTempo: tempo.bpm)
                playheadBeats = loopStartBeat
                playheadPosition = loopStart
                playStartTime = Date()
                playStartPosition = loopStart
            }
        }
        
        playheadSubject.send(playheadPosition)
    }
    
    public func togglePlayPause() {
        // Debounce rapid clicks (ignore if less than 200ms since last toggle)
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) > 0.2 else {
            transportLog("togglePlayPause() DEBOUNCED - too rapid")
            return
        }
        lastToggleTime = now
        
        transportLog("togglePlayPause() called, isPlaying=\(isPlaying)")
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    public func record() {
        isRecording = true
        if !isPlaying {
            play()
        }
        transportEventSubject.send(.record)
    }
    
    public func stopRecording() {
        isRecording = false
        transportEventSubject.send(.stopRecording)
    }
    
    public func returnToZero() {
        setPlayheadPosition(TimePosition(sampleRate: sampleRate))
        transportEventSubject.send(.returnToZero)
    }
    
    public func goToEnd(projectDuration: TimePosition) {
        setPlayheadPosition(projectDuration)
    }
    
    // MARK: - Playhead Control
    
    public func setPlayheadPosition(_ position: TimePosition) {
        playheadPosition = position
        playheadBeats = position.beats(atTempo: tempo.bpm)
        playheadSubject.send(position)
        
        // Update play start if currently playing
        if isPlaying {
            playStartTime = Date()
            playStartPosition = position
        }
    }
    
    public func setPlayheadBeats(_ beats: Double) {
        let position = TimePosition(beats: beats, tempo: tempo.bpm, sampleRate: sampleRate)
        setPlayheadPosition(position)
    }
    
    /// Update playhead based on audio engine callback
    public func updatePlayhead(samples: Int64) {
        playheadPosition = TimePosition(samples: samples, sampleRate: sampleRate)
        playheadBeats = playheadPosition.beats(atTempo: tempo.bpm)
        playheadSubject.send(playheadPosition)
    }
    
    // MARK: - Loop Control
    
    public func setLoop(start: TimePosition, end: TimePosition) {
        loopStart = start
        loopEnd = end
    }
    
    public func setLoopBeats(start: Double, end: Double) {
        loopStart = TimePosition(beats: start, tempo: tempo.bpm, sampleRate: sampleRate)
        loopEnd = TimePosition(beats: end, tempo: tempo.bpm, sampleRate: sampleRate)
    }
    
    public func toggleLoop() {
        isLoopEnabled.toggle()
        transportEventSubject.send(isLoopEnabled ? .loopEnabled : .loopDisabled)
    }
    
    // MARK: - Tempo Control
    
    public func setTempo(_ bpm: Double) {
        tempo = Tempo(bpm: bpm)
    }
    
    public func nudgeTempo(by delta: Double) {
        tempo = Tempo(bpm: tempo.bpm + delta)
    }
    
    public func tapTempo(tapTimes: [Date]) {
        guard tapTimes.count >= 2 else { return }
        
        var intervals: [TimeInterval] = []
        for i in 1..<tapTimes.count {
            intervals.append(tapTimes[i].timeIntervalSince(tapTimes[i-1]))
        }
        
        let averageInterval = intervals.reduce(0, +) / Double(intervals.count)
        let tappedBPM = 60.0 / averageInterval
        
        // Clamp to reasonable range
        tempo = Tempo(bpm: max(20, min(999, tappedBPM)))
    }
    
    // MARK: - Bar/Beat Position
    
    public var currentBar: Int {
        Int(playheadBeats / Double(timeSignature.beatsPerBar)) + 1
    }
    
    public var currentBeat: Int {
        Int(playheadBeats.truncatingRemainder(dividingBy: Double(timeSignature.beatsPerBar))) + 1
    }
    
    public var formattedPosition: String {
        playheadPosition.formatted(atTempo: tempo.bpm, timeSignature: timeSignature)
    }
    
    public var timecodePosition: String {
        let seconds = playheadPosition.seconds
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let frames = Int((seconds.truncatingRemainder(dividingBy: 1)) * 30)  // 30 fps
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, secs, frames)
    }
}

// MARK: - Transport Event

public enum TransportEvent: Sendable {
    case play
    case stop
    case pause
    case record
    case stopRecording
    case returnToZero
    case loopEnabled
    case loopDisabled
    case tempoChanged(Tempo)
    case timeSignatureChanged(TimeSignature)
}

// MARK: - Metronome Settings

public struct MetronomeSettings: Codable, Sendable {
    public var isEnabled: Bool
    public var volume: Float
    public var accentDownbeat: Bool
    public var sound: MetronomeSound
    public var prerollBars: Int
    
    public init(
        isEnabled: Bool = false,
        volume: Float = 0.7,
        accentDownbeat: Bool = true,
        sound: MetronomeSound = .click,
        prerollBars: Int = 0
    ) {
        self.isEnabled = isEnabled
        self.volume = volume
        self.accentDownbeat = accentDownbeat
        self.sound = sound
        self.prerollBars = prerollBars
    }
}

public enum MetronomeSound: String, Codable, Sendable, CaseIterable {
    case click
    case woodblock
    case cowbell
    case beep
}
