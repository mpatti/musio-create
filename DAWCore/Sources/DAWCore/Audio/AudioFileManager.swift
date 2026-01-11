import Foundation
import AVFoundation

// MARK: - Audio File Manager

/// Manages loading, caching, and conversion of audio files
public actor AudioFileManager {
    
    // MARK: - Properties
    
    private var fileCache: [UUID: CachedAudioFile] = [:]
    private var bufferCache: [UUID: AVAudioPCMBuffer] = [:]
    private let maxCacheSize: Int
    private var currentCacheSize: Int = 0
    
    // MARK: - Initialization
    
    public init(maxCacheSizeBytes: Int = 500_000_000) {  // 500 MB default
        self.maxCacheSize = maxCacheSizeBytes
    }
    
    // MARK: - File Loading
    
    /// Load an audio file from disk
    public func loadFile(from url: URL) async throws -> AudioFileInfo {
        let file = try AVAudioFile(forReading: url)
        
        let info = AudioFileInfo(
            url: url,
            format: file.processingFormat,
            length: file.length,
            sampleRate: file.processingFormat.sampleRate,
            channelCount: Int(file.processingFormat.channelCount)
        )
        
        return info
    }
    
    /// Load an audio file and cache it for playback
    public func loadAndCache(
        reference: AudioFileReference,
        projectDirectory: URL
    ) async throws -> AVAudioFile {
        // Check cache first
        if let cached = fileCache[reference.fileID] {
            return cached.file
        }
        
        // Construct full path
        let fileURL = projectDirectory.appendingPathComponent(reference.relativePath)
        
        let file = try AVAudioFile(forReading: fileURL)
        
        // Cache the file
        let cached = CachedAudioFile(file: file, accessTime: Date())
        fileCache[reference.fileID] = cached
        
        return file
    }
    
    /// Read audio data into a buffer
    public func readBuffer(
        from file: AVAudioFile,
        startFrame: AVAudioFramePosition = 0,
        frameCount: AVAudioFrameCount? = nil
    ) async throws -> AVAudioPCMBuffer {
        let frames = frameCount ?? AVAudioFrameCount(file.length - startFrame)
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frames
        ) else {
            throw AudioEngineError.bufferAllocationFailed
        }
        
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frames)
        
        return buffer
    }
    
    /// Pre-cache a buffer for quick access
    public func cacheBuffer(_ buffer: AVAudioPCMBuffer, for fileID: UUID) {
        // Estimate buffer size
        let bufferSize = Int(buffer.frameLength) * Int(buffer.format.channelCount) * 4  // 4 bytes per float
        
        // Evict old entries if needed
        while currentCacheSize + bufferSize > maxCacheSize && !bufferCache.isEmpty {
            // Remove oldest entry (simple FIFO for now)
            if let firstKey = bufferCache.keys.first {
                if let oldBuffer = bufferCache.removeValue(forKey: firstKey) {
                    let oldSize = Int(oldBuffer.frameLength) * Int(oldBuffer.format.channelCount) * 4
                    currentCacheSize -= oldSize
                }
            }
        }
        
        bufferCache[fileID] = buffer
        currentCacheSize += bufferSize
    }
    
    /// Get cached buffer if available
    public func getCachedBuffer(for fileID: UUID) -> AVAudioPCMBuffer? {
        bufferCache[fileID]
    }
    
    /// Clear all caches
    public func clearCache() {
        fileCache.removeAll()
        bufferCache.removeAll()
        currentCacheSize = 0
    }
    
    // MARK: - Waveform Generation
    
    /// Generate waveform data for UI display
    public func generateWaveform(
        from file: AVAudioFile,
        samplesPerPixel: Int = 256,
        maxPoints: Int = 10000
    ) async throws -> WaveformData {
        let frameCount = AVAudioFrameCount(file.length)
        let channelCount = Int(file.processingFormat.channelCount)
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw AudioEngineError.bufferAllocationFailed
        }
        
        file.framePosition = 0
        try file.read(into: buffer)
        
        guard let channelData = buffer.floatChannelData else {
            throw AudioEngineError.invalidFormat
        }
        
        let totalSamples = Int(buffer.frameLength)
        let numPoints = min(maxPoints, totalSamples / samplesPerPixel)
        
        var minValues: [Float] = []
        var maxValues: [Float] = []
        
        for i in 0..<numPoints {
            let startSample = i * samplesPerPixel
            let endSample = min(startSample + samplesPerPixel, totalSamples)
            
            var minVal: Float = 0
            var maxVal: Float = 0
            
            // Average across channels
            for channel in 0..<channelCount {
                for sample in startSample..<endSample {
                    let value = channelData[channel][sample]
                    minVal = min(minVal, value)
                    maxVal = max(maxVal, value)
                }
            }
            
            minValues.append(minVal)
            maxValues.append(maxVal)
        }
        
        return WaveformData(
            minValues: minValues,
            maxValues: maxValues,
            sampleRate: file.processingFormat.sampleRate,
            duration: Double(totalSamples) / file.processingFormat.sampleRate
        )
    }
    
    // MARK: - Format Conversion
    
    /// Convert audio file to project format
    public func convertToProjectFormat(
        sourceURL: URL,
        destinationURL: URL,
        sampleRate: Double = 44100,
        channelCount: Int = 2,
        bitDepth: Int = 24
    ) async throws {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        let destFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: settings
        )
        
        // Process in chunks
        let chunkSize: AVAudioFrameCount = 65536
        let format = destFile.processingFormat
        
        while sourceFile.framePosition < sourceFile.length {
            let remainingFrames = AVAudioFrameCount(sourceFile.length - sourceFile.framePosition)
            let framesToRead = min(chunkSize, remainingFrames)
            
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: framesToRead
            ) else {
                throw AudioEngineError.bufferAllocationFailed
            }
            
            try sourceFile.read(into: buffer, frameCount: framesToRead)
            try destFile.write(from: buffer)
        }
    }
    
    // MARK: - Export
    
    /// Export audio to a file
    public func exportAudio(
        buffer: AVAudioPCMBuffer,
        to url: URL,
        format: AudioExportFormat
    ) async throws {
        let settings = format.settings
        
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings
        )
        
        try file.write(from: buffer)
    }
}

// MARK: - Supporting Types

public struct AudioFileInfo: Sendable {
    public let url: URL
    public let format: AVAudioFormat
    public let length: AVAudioFramePosition
    public let sampleRate: Double
    public let channelCount: Int
    
    public var duration: TimeInterval {
        Double(length) / sampleRate
    }
}

private struct CachedAudioFile {
    let file: AVAudioFile
    var accessTime: Date
}

public struct WaveformData: Sendable {
    public let minValues: [Float]
    public let maxValues: [Float]
    public let sampleRate: Double
    public let duration: TimeInterval
    
    public var pointCount: Int { minValues.count }
}

// MARK: - Export Format

public enum AudioExportFormat {
    case wav(sampleRate: Double, bitDepth: Int)
    case aiff(sampleRate: Double, bitDepth: Int)
    case mp3(quality: Float)  // 0.0 to 1.0
    case aac(bitRate: Int)
    
    public var settings: [String: Any] {
        switch self {
        case .wav(let sampleRate, let bitDepth):
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: bitDepth,
                AVLinearPCMIsFloatKey: bitDepth == 32,
                AVLinearPCMIsBigEndianKey: false
            ]
            
        case .aiff(let sampleRate, let bitDepth):
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: bitDepth,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: true
            ]
            
        case .mp3(let quality):
            return [
                AVFormatIDKey: kAudioFormatMPEGLayer3,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderAudioQualityKey: AVAudioQuality(rawValue: Int(quality * 100)) ?? .high
            ]
            
        case .aac(let bitRate):
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: bitRate
            ]
        }
    }
    
    public var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .mp3: return "mp3"
        case .aac: return "m4a"
        }
    }
}
