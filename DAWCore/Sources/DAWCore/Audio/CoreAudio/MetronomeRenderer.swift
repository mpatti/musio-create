import Foundation
import AudioToolbox

// MARK: - Metronome Renderer

/// Synthesizes metronome clicks directly in the render callback
/// Provides sample-accurate timing for the metronome
public final class MetronomeRenderer {
    
    // MARK: - Properties
    
    /// Pre-generated click waveform (normal beat)
    private var clickBuffer: [Float]
    
    /// Pre-generated accent waveform (downbeat)
    private var accentBuffer: [Float]
    
    /// Scheduled clicks ring buffer
    private var scheduledClicks: RingBuffer<MetronomeClick>
    
    /// Sample rate
    private let sampleRate: Double
    
    /// Whether metronome is enabled
    public var isEnabled: Bool = false
    
    /// Volume (0.0 - 1.0)
    public var volume: Float = 0.7
    
    // MARK: - Types
    
    struct MetronomeClick {
        let samplePosition: Int64
        let isAccent: Bool
    }
    
    // MARK: - Initialization
    
    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.scheduledClicks = RingBuffer(capacity: 2048)
        
        // Generate click sounds
        clickBuffer = Self.generateClick(frequency: 1000, sampleRate: sampleRate, duration: 0.02, volume: 0.8)
        accentBuffer = Self.generateClick(frequency: 1500, sampleRate: sampleRate, duration: 0.03, volume: 1.0)
    }
    
    // MARK: - Click Generation
    
    private static func generateClick(frequency: Double, sampleRate: Double, duration: Double, volume: Float) -> [Float] {
        let sampleCount = Int(sampleRate * duration)
        var buffer = [Float](repeating: 0, count: sampleCount)
        
        for i in 0..<sampleCount {
            let time = Double(i) / sampleRate
            let envelope = exp(-time * 50) // Fast exponential decay
            let sample = Float(sin(2.0 * .pi * frequency * time) * envelope * Double(volume))
            buffer[i] = sample
        }
        
        return buffer
    }
    
    // MARK: - Scheduling (Main Thread)
    
    /// Schedule metronome clicks for a beat range
    /// - Parameters:
    ///   - startBeat: Start beat
    ///   - endBeat: End beat
    ///   - tempo: Tempo in BPM
    ///   - sampleRate: Sample rate
    ///   - timeSignature: Time signature for accent placement
    func scheduleClicks(
        from startBeat: Double,
        to endBeat: Double,
        tempo: Double,
        sampleRate: Double,
        timeSignature: TimeSignature
    ) {
        // Clear existing clicks
        scheduledClicks.clear()
        
        let beatsPerBar = timeSignature.beatsPerBar
        let samplesPerBeat = (60.0 / tempo) * sampleRate
        
        // Start from the next whole beat
        var beat = ceil(startBeat)
        
        while beat < endBeat {
            let samplePosition = Int64(beat * samplesPerBeat)
            let beatInBar = Int(beat) % beatsPerBar
            let isAccent = beatInBar == 0
            
            let click = MetronomeClick(samplePosition: samplePosition, isAccent: isAccent)
            scheduledClicks.push(click)
            
            beat += 1
        }
    }
    
    /// Clear all scheduled clicks
    func clearClicks() {
        scheduledClicks.clear()
    }
    
    // MARK: - Rendering (Audio Thread)
    
    /// Render metronome into the output buffer
    /// Called from audio thread - MUST be realtime safe
    func render(
        into bufferList: UnsafeMutablePointer<AudioBufferList>,
        currentSample: Int64,
        frameCount: UInt32
    ) {
        guard isEnabled else { return }
        
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        guard ablPointer.count >= 2 else { return }
        
        let outputLeft = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
        let outputRight = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
        
        guard let outL = outputLeft, let outR = outputRight else { return }
        
        let endSample = currentSample + Int64(frameCount)
        
        // Process scheduled clicks
        while let click = scheduledClicks.peek() {
            // Skip clicks in the past
            if click.samplePosition < currentSample {
                scheduledClicks.pop()
                continue
            }
            
            // Stop if click is beyond this buffer
            if click.samplePosition >= endSample {
                break
            }
            
            // Calculate offset within buffer
            let offset = Int(click.samplePosition - currentSample)
            let clickData = click.isAccent ? accentBuffer : clickBuffer
            
            // Add click to output
            addClickToBuffer(
                outL: outL,
                outR: outR,
                clickData: clickData,
                offset: offset,
                frameCount: Int(frameCount)
            )
            
            scheduledClicks.pop()
        }
    }
    
    private func addClickToBuffer(
        outL: UnsafeMutablePointer<Float>,
        outR: UnsafeMutablePointer<Float>,
        clickData: [Float],
        offset: Int,
        frameCount: Int
    ) {
        let clickLength = clickData.count
        let samplesToWrite = min(clickLength, frameCount - offset)
        
        guard samplesToWrite > 0 && offset >= 0 else { return }
        
        for i in 0..<samplesToWrite {
            let sample = clickData[i] * volume
            outL[offset + i] += sample
            outR[offset + i] += sample
        }
    }
}
