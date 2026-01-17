import Foundation
import AudioToolbox
import AVFoundation

// MARK: - Offline Bounce

/// Renders audio offline (non-realtime) to a file
/// Allows bouncing at faster than realtime speeds
public final class OfflineBounce {
    
    // MARK: - Properties
    
    private let renderGraph: RenderGraph
    private let midiScheduler: MIDIScheduler
    private let audioClipRenderer: AudioClipRenderer
    private let metronomeRenderer: MetronomeRenderer
    
    // MARK: - Initialization
    
    init(
        renderGraph: RenderGraph,
        midiScheduler: MIDIScheduler,
        audioClipRenderer: AudioClipRenderer,
        metronomeRenderer: MetronomeRenderer
    ) {
        self.renderGraph = renderGraph
        self.midiScheduler = midiScheduler
        self.audioClipRenderer = audioClipRenderer
        self.metronomeRenderer = metronomeRenderer
    }
    
    // MARK: - Bounce
    
    /// Bounce audio to a file
    /// - Parameters:
    ///   - startSample: Start position in samples
    ///   - endSample: End position in samples
    ///   - outputURL: Output file URL
    ///   - sampleRate: Sample rate for output
    ///   - progress: Optional progress callback (0.0 - 1.0)
    func bounce(
        from startSample: Int64,
        to endSample: Int64,
        outputURL: URL,
        sampleRate: Double,
        bufferSize: UInt32 = 4096,
        progress: ((Double) -> Void)?
    ) async throws {
        print("[OfflineBounce] Starting bounce from \(startSample) to \(endSample)")
        print("[OfflineBounce] Output: \(outputURL.path)")
        
        // Create output file
        var outputFile: ExtAudioFileRef?
        
        // Output format (32-bit float)
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        // File format (16-bit PCM WAV)
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        
        // Delete existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        // Create output file
        var status = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileWAVEType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &outputFile
        )
        
        guard status == noErr, let outFile = outputFile else {
            throw AudioBackendError.bounceError("Could not create output file: \(status)")
        }
        
        // Set client format
        status = ExtAudioFileSetProperty(
            outFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        
        guard status == noErr else {
            ExtAudioFileDispose(outFile)
            throw AudioBackendError.bounceError("Could not set client format: \(status)")
        }
        
        // Allocate render buffers
        let leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(bufferSize))
        let rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(bufferSize))
        defer {
            leftBuffer.deallocate()
            rightBuffer.deallocate()
        }
        
        // Initialize buffers
        leftBuffer.initialize(repeating: 0, count: Int(bufferSize))
        rightBuffer.initialize(repeating: 0, count: Int(bufferSize))
        
        // Set up buffer list
        var bufferList = AudioBufferList(
            mNumberBuffers: 2,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: bufferSize * 4,
                mData: leftBuffer
            )
        )
        
        // We need to set up the second buffer manually
        // AudioBufferList is a C struct with variable-length array
        let ablPointer = UnsafeMutableAudioBufferListPointer(&bufferList)
        if ablPointer.count >= 2 {
            ablPointer[1] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: bufferSize * 4,
                mData: rightBuffer
            )
        }
        
        let totalSamples = endSample - startSample
        var currentSample = startSample
        var lastProgressUpdate = Date()
        
        // Render loop
        while currentSample < endSample {
            // Check for cancellation
            try Task.checkCancellation()
            
            // Calculate frames for this iteration
            let remainingSamples = endSample - currentSample
            let framesToRender = min(UInt32(remainingSamples), bufferSize)
            
            // Clear buffers
            memset(leftBuffer, 0, Int(framesToRender) * MemoryLayout<Float>.size)
            memset(rightBuffer, 0, Int(framesToRender) * MemoryLayout<Float>.size)
            
            // Render MIDI
            midiScheduler.processEvents(
                startSample: currentSample,
                endSample: currentSample + Int64(framesToRender),
                renderGraph: renderGraph
            )
            
            // Render tracks
            renderGraph.render(
                frameCount: framesToRender,
                currentSample: currentSample,
                outputBuffer: &bufferList
            )
            
            // Render audio clips
            audioClipRenderer.render(
                into: &bufferList,
                currentSample: currentSample,
                frameCount: framesToRender
            )
            
            // Render metronome (if enabled)
            metronomeRenderer.render(
                into: &bufferList,
                currentSample: currentSample,
                frameCount: framesToRender
            )
            
            // Write to file
            status = ExtAudioFileWrite(outFile, framesToRender, &bufferList)
            if status != noErr {
                ExtAudioFileDispose(outFile)
                throw AudioBackendError.bounceError("Write error: \(status)")
            }
            
            currentSample += Int64(framesToRender)
            
            // Update progress (throttled to avoid UI flood)
            let now = Date()
            if now.timeIntervalSince(lastProgressUpdate) >= 0.1 {
                let progressValue = Double(currentSample - startSample) / Double(totalSamples)
                progress?(progressValue)
                lastProgressUpdate = now
                
                // Yield to allow other tasks
                await Task.yield()
            }
        }
        
        // Close file
        ExtAudioFileDispose(outFile)
        
        // Final progress update
        progress?(1.0)
        
        print("[OfflineBounce] Bounce complete: \(outputURL.path)")
    }
    
    /// Bounce to AIFF format
    func bounceToAIFF(
        from startSample: Int64,
        to endSample: Int64,
        outputURL: URL,
        sampleRate: Double,
        bitDepth: Int = 24,
        progress: ((Double) -> Void)?
    ) async throws {
        // Similar to WAV bounce but with AIFF format
        // For now, redirect to WAV
        let wavURL = outputURL.deletingPathExtension().appendingPathExtension("wav")
        try await bounce(from: startSample, to: endSample, outputURL: wavURL, sampleRate: sampleRate, progress: progress)
    }
    
    /// Bounce to MP3 format (requires additional encoding step)
    func bounceToMP3(
        from startSample: Int64,
        to endSample: Int64,
        outputURL: URL,
        sampleRate: Double,
        bitRate: Int = 320,
        progress: ((Double) -> Void)?
    ) async throws {
        // First bounce to WAV, then convert
        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        
        try await bounce(from: startSample, to: endSample, outputURL: tempWAV, sampleRate: sampleRate, progress: { p in
            progress?(p * 0.9)  // 90% for rendering
        })
        
        // Convert to MP3 using AVAssetExportSession
        let asset = AVAsset(url: tempWAV)
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioBackendError.bounceError("Could not create export session")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a  // MP3 isn't directly supported, use M4A
        
        await exportSession.export()
        
        if let error = exportSession.error {
            throw AudioBackendError.bounceError("Export failed: \(error.localizedDescription)")
        }
        
        // Clean up temp file
        try? FileManager.default.removeItem(at: tempWAV)
        
        progress?(1.0)
    }
}
