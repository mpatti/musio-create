import SwiftUI
import AVFoundation

// MARK: - Audio Waveform View

/// Displays the waveform of an audio file (or a portion of it)
public struct AudioWaveformView: View {
    let audioFilePath: String
    let color: Color
    let sourceStartSample: Int64  // Where in the file to start reading
    let sourceLengthSamples: Int64  // How many samples to display (0 = entire file)
    
    @State private var waveformData: [Float] = []
    @State private var isLoading = true
    
    public init(
        audioFilePath: String,
        color: Color = .blue,
        sourceStartSample: Int64 = 0,
        sourceLengthSamples: Int64 = 0
    ) {
        self.audioFilePath = audioFilePath
        self.color = color
        self.sourceStartSample = sourceStartSample
        self.sourceLengthSamples = sourceLengthSamples
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
        let width = size.width
        let dataCount = waveformData.count
        
        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY))
        
        // Draw top half - scale waveform data to fill entire width
        for x in 0..<Int(width) {
            // Map pixel position to waveform data index
            let dataPosition = Double(x) / Double(width) * Double(dataCount)
            let startIdx = Int(dataPosition)
            let endIdx = min(startIdx + max(1, dataCount / Int(width)), dataCount)
            
            guard startIdx < dataCount else {
                path.addLine(to: CGPoint(x: CGFloat(x), y: midY))
                continue
            }
            
            // Find max amplitude in this segment
            var maxAmp: Float = 0
            for i in startIdx..<endIdx {
                maxAmp = max(maxAmp, abs(waveformData[i]))
            }
            
            let amplitude = CGFloat(maxAmp) * (size.height / 2) * 0.9
            path.addLine(to: CGPoint(x: CGFloat(x), y: midY - amplitude))
        }
        
        // Draw back along bottom
        for x in stride(from: Int(width) - 1, through: 0, by: -1) {
            let dataPosition = Double(x) / Double(width) * Double(dataCount)
            let startIdx = Int(dataPosition)
            let endIdx = min(startIdx + max(1, dataCount / Int(width)), dataCount)
            
            guard startIdx < dataCount else {
                path.addLine(to: CGPoint(x: CGFloat(x), y: midY))
                continue
            }
            
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
            let data = await generateWaveformData(
                from: audioFilePath,
                targetSamples: 500,
                startSample: sourceStartSample,
                lengthSamples: sourceLengthSamples
            )
            
            await MainActor.run {
                self.waveformData = data
                self.isLoading = false
            }
        }
    }
    
    private func generateWaveformData(
        from path: String,
        targetSamples: Int,
        startSample: Int64,
        lengthSamples: Int64
    ) async -> [Float] {
        let url = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else {
            return []
        }
        
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            
            // Determine the range to read
            let fileLength = audioFile.length
            let effectiveStart = min(startSample, fileLength)
            let effectiveLength: Int64
            if lengthSamples > 0 {
                effectiveLength = min(lengthSamples, fileLength - effectiveStart)
            } else {
                effectiveLength = fileLength - effectiveStart
            }
            
            guard effectiveLength > 0 else { return [] }
            
            // Calculate how many frames per waveform sample
            let framesPerSample = max(1, Int(effectiveLength) / targetSamples)
            
            // Read file in chunks
            var waveform: [Float] = []
            let bufferSize = AVAudioFrameCount(min(44100, Int(effectiveLength)))
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
                return []
            }
            
            var framePosition: AVAudioFramePosition = effectiveStart
            let endPosition = effectiveStart + effectiveLength
            var sampleAccumulator: Float = 0
            var sampleCount = 0
            
            while framePosition < endPosition {
                let framesToRead = min(bufferSize, AVAudioFrameCount(endPosition - framePosition))
                
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
            
            return waveform
            
        } catch {
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
