import SwiftUI
import AVFoundation

// MARK: - Audio Waveform View

/// Displays the waveform of an audio file
public struct AudioWaveformView: View {
    let audioFilePath: String
    let color: Color
    
    @State private var waveformData: [Float] = []
    @State private var isLoading = true
    
    public init(audioFilePath: String, color: Color = .blue) {
        self.audioFilePath = audioFilePath
        self.color = color
    }
    
    public var body: some View {
        GeometryReader { geometry in
            if isLoading {
                // Loading placeholder
                Rectangle()
                    .fill(color.opacity(0.2))
            } else if waveformData.isEmpty {
                // No data
                Rectangle()
                    .fill(color.opacity(0.1))
            } else {
                // Waveform
                Canvas { context, size in
                    drawWaveform(context: context, size: size)
                }
            }
        }
        .onAppear {
            loadWaveform()
        }
        .onChange(of: audioFilePath) { _ in
            loadWaveform()
        }
    }
    
    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        guard !waveformData.isEmpty else { return }
        
        let midY = size.height / 2
        let samplesPerPixel = max(1, waveformData.count / Int(size.width))
        
        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY))
        
        // Draw top half
        for x in 0..<Int(size.width) {
            let startIdx = x * samplesPerPixel
            let endIdx = min(startIdx + samplesPerPixel, waveformData.count)
            
            guard startIdx < waveformData.count else { break }
            
            // Find max amplitude in this segment
            var maxAmp: Float = 0
            for i in startIdx..<endIdx {
                maxAmp = max(maxAmp, abs(waveformData[i]))
            }
            
            let amplitude = CGFloat(maxAmp) * (size.height / 2) * 0.9
            path.addLine(to: CGPoint(x: CGFloat(x), y: midY - amplitude))
        }
        
        // Draw back along bottom
        for x in stride(from: Int(size.width) - 1, through: 0, by: -1) {
            let startIdx = x * samplesPerPixel
            let endIdx = min(startIdx + samplesPerPixel, waveformData.count)
            
            guard startIdx < waveformData.count else { continue }
            
            var maxAmp: Float = 0
            for i in startIdx..<endIdx {
                maxAmp = max(maxAmp, abs(waveformData[i]))
            }
            
            let amplitude = CGFloat(maxAmp) * (size.height / 2) * 0.9
            path.addLine(to: CGPoint(x: CGFloat(x), y: midY + amplitude))
        }
        
        path.closeSubpath()
        
        // Fill
        context.fill(path, with: .color(color.opacity(0.6)))
        
        // Stroke
        context.stroke(path, with: .color(color), lineWidth: 0.5)
    }
    
    private func loadWaveform() {
        isLoading = true
        
        Task {
            let data = await generateWaveformData(from: audioFilePath, targetSamples: 1000)
            
            await MainActor.run {
                self.waveformData = data
                self.isLoading = false
            }
        }
    }
    
    private func generateWaveformData(from path: String, targetSamples: Int) async -> [Float] {
        let url = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else {
            print("Waveform: File not found at \(path)")
            return []
        }
        
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let totalFrames = Int(audioFile.length)
            let format = audioFile.processingFormat
            
            guard totalFrames > 0 else { return [] }
            
            // Calculate how many frames per sample
            let framesPerSample = max(1, totalFrames / targetSamples)
            
            // Read file in chunks
            var waveform: [Float] = []
            let bufferSize = AVAudioFrameCount(min(44100, totalFrames)) // 1 second or less
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
                return []
            }
            
            var framePosition: AVAudioFramePosition = 0
            var sampleAccumulator: Float = 0
            var sampleCount = 0
            
            while framePosition < audioFile.length {
                let framesToRead = min(bufferSize, AVAudioFrameCount(audioFile.length - framePosition))
                
                audioFile.framePosition = framePosition
                try audioFile.read(into: buffer, frameCount: framesToRead)
                
                guard let channelData = buffer.floatChannelData else { break }
                
                let channelCount = Int(format.channelCount)
                let frameLength = Int(buffer.frameLength)
                
                for i in 0..<frameLength {
                    // Mix all channels
                    var sample: Float = 0
                    for ch in 0..<channelCount {
                        sample += abs(channelData[ch][i])
                    }
                    sample /= Float(channelCount)
                    
                    sampleAccumulator = max(sampleAccumulator, sample)
                    sampleCount += 1
                    
                    if sampleCount >= framesPerSample {
                        waveform.append(sampleAccumulator)
                        sampleAccumulator = 0
                        sampleCount = 0
                    }
                }
                
                framePosition += AVAudioFramePosition(framesToRead)
            }
            
            // Add any remaining samples
            if sampleCount > 0 {
                waveform.append(sampleAccumulator)
            }
            
            print("Generated waveform with \(waveform.count) samples from \(totalFrames) frames")
            return waveform
            
        } catch {
            print("Failed to load audio file for waveform: \(error)")
            return []
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AudioWaveformView_Previews: PreviewProvider {
    static var previews: some View {
        AudioWaveformView(audioFilePath: "/path/to/audio.wav", color: .blue)
            .frame(height: 60)
            .padding()
    }
}
#endif
