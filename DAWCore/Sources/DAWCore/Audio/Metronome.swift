import Foundation
import AVFoundation
import Combine

/// Metronome that plays click sounds on each beat
@MainActor
public final class Metronome: ObservableObject {
    
    // MARK: - Properties
    
    private var audioEngine: AVAudioEngine?
    private var clickPlayer: AVAudioPlayerNode?
    private var clickBuffer: AVAudioPCMBuffer?
    private var accentBuffer: AVAudioPCMBuffer?
    
    private weak var transportState: TransportState?
    private var cancellables = Set<AnyCancellable>()
    
    private var lastClickBeat: Int = -1
    private var isRunning = false
    
    @Published public var volume: Float = 0.7
    @Published public var accentDownbeat: Bool = true
    
    // MARK: - Initialization
    
    public init() {
        setupAudio()
    }
    
    deinit {
        // Clean up audio resources directly (can't call MainActor methods from deinit)
        clickPlayer?.stop()
        audioEngine?.stop()
    }
    
    // MARK: - Setup
    
    private func setupAudio() {
        audioEngine = AVAudioEngine()
        clickPlayer = AVAudioPlayerNode()
        
        guard let engine = audioEngine, let player = clickPlayer else { return }
        
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        
        // Generate click sounds
        clickBuffer = generateClickBuffer(frequency: 1000, duration: 0.02, volume: 0.8)
        accentBuffer = generateClickBuffer(frequency: 1500, duration: 0.03, volume: 1.0)
        
        do {
            try engine.start()
            print("[Metronome] Audio engine started")
        } catch {
            print("[Metronome] Failed to start audio engine: \(error)")
        }
    }
    
    /// Generate a click sound buffer
    private func generateClickBuffer(frequency: Double, duration: Double, volume: Float) -> AVAudioPCMBuffer? {
        let sampleRate: Double = 44100
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        
        buffer.frameLength = frameCount
        
        guard let leftChannel = buffer.floatChannelData?[0],
              let rightChannel = buffer.floatChannelData?[1] else {
            return nil
        }
        
        // Generate a short sine wave with exponential decay
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let envelope = exp(-time * 50) // Fast decay
            let sample = Float(sin(2.0 * .pi * frequency * time) * envelope * Double(volume))
            leftChannel[frame] = sample
            rightChannel[frame] = sample
        }
        
        return buffer
    }
    
    // MARK: - Binding
    
    public func bind(to transport: TransportState) {
        self.transportState = transport
        
        // Subscribe to playhead updates
        transport.$playheadBeats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] beats in
                self?.checkAndPlayClick(at: beats)
            }
            .store(in: &cancellables)
        
        // Subscribe to play/stop
        transport.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                if isPlaying {
                    self?.start()
                } else {
                    self?.stop()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Playback Control
    
    public func start() {
        guard let transport = transportState else { return }
        
        isRunning = true
        lastClickBeat = Int(floor(transport.playheadBeats)) - 1
        
        // Start the player if not already playing
        if let player = clickPlayer, !player.isPlaying {
            player.play()
        }
        
        print("[Metronome] Started at beat \(transport.playheadBeats)")
    }
    
    public func stop() {
        isRunning = false
        lastClickBeat = -1
        print("[Metronome] Stopped")
    }
    
    // MARK: - Click Logic
    
    private func checkAndPlayClick(at beats: Double) {
        guard isRunning,
              let transport = transportState,
              transport.isMetronomeEnabled else { return }
        
        let currentBeatInt = Int(floor(beats))
        
        // Play click when we cross into a new beat
        if currentBeatInt > lastClickBeat {
            let timeSig = transport.timeSignature
            let isDownbeat = currentBeatInt % timeSig.beatsPerBar == 0
            
            playClick(accent: isDownbeat && accentDownbeat)
            lastClickBeat = currentBeatInt
        }
    }
    
    private func playClick(accent: Bool) {
        guard let player = clickPlayer,
              let engine = audioEngine,
              engine.isRunning else { return }
        
        let buffer = accent ? accentBuffer : clickBuffer
        guard let clickBuffer = buffer else { return }
        
        // Schedule the click immediately
        player.scheduleBuffer(clickBuffer, at: nil, options: [], completionHandler: nil)
        
        if !player.isPlaying {
            player.play()
        }
    }
    
    // MARK: - Preview
    
    /// Play a single click for preview/testing
    public func playPreviewClick() {
        guard let player = clickPlayer,
              let engine = audioEngine else { return }
        
        if !engine.isRunning {
            try? engine.start()
        }
        
        if let buffer = clickBuffer {
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            if !player.isPlaying {
                player.play()
            }
        }
    }
}
