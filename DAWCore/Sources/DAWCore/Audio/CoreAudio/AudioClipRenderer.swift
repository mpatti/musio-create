import Foundation
import AudioToolbox
import AVFoundation

// MARK: - Audio Clip Renderer

/// Renders audio clips using ExtAudioFile for format conversion
/// Provides sample-accurate playback of audio files
public final class AudioClipRenderer {
    
    // MARK: - Scheduled Clip
    
    struct ScheduledClip {
        let trackID: TrackID
        let extAudioFile: ExtAudioFileRef
        let startSample: Int64
        let offsetSample: Int64  // Where in the file to start reading
        let endSample: Int64
        let volume: Float
        var currentReadPosition: Int64  // Track how far we've read
    }
    
    // MARK: - Properties
    
    private var scheduledClips: [ScheduledClip] = []
    private let sampleRate: Double
    
    /// Read buffer for ExtAudioFile
    private var readBuffer: UnsafeMutablePointer<Float>?
    private var readBufferSize: Int = 0
    
    // MARK: - Initialization
    
    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }
    
    deinit {
        // Close all open files
        for clip in scheduledClips {
            ExtAudioFileDispose(clip.extAudioFile)
        }
        readBuffer?.deallocate()
    }
    
    // MARK: - Clip Management (Main Thread)
    
    /// Schedule an audio clip for playback
    func scheduleClip(
        url: URL,
        trackID: TrackID,
        startSample: Int64,
        offsetSample: Int64,
        endSample: Int64,
        volume: Float
    ) throws {
        // Open the file
        var extAudioFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(url as CFURL, &extAudioFile)
        
        guard status == noErr, let file = extAudioFile else {
            throw AudioBackendError.audioFileLoadFailed(url, "ExtAudioFileOpenURL failed: \(status)")
        }
        
        // Set the client format (what we want to read)
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,  // 2 channels * 4 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        status = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        
        if status != noErr {
            ExtAudioFileDispose(file)
            throw AudioBackendError.audioFileLoadFailed(url, "Could not set client format: \(status)")
        }
        
        // Seek to offset position
        if offsetSample > 0 {
            status = ExtAudioFileSeek(file, offsetSample)
            if status != noErr {
                print("[AudioClipRenderer] Warning: Could not seek to offset \(offsetSample): \(status)")
            }
        }
        
        let clip = ScheduledClip(
            trackID: trackID,
            extAudioFile: file,
            startSample: startSample,
            offsetSample: offsetSample,
            endSample: endSample,
            volume: volume,
            currentReadPosition: startSample
        )
        
        scheduledClips.append(clip)
        print("[AudioClipRenderer] Scheduled clip from \(url.lastPathComponent) at sample \(startSample)")
    }
    
    /// Clear all scheduled clips
    func clearClips() {
        for clip in scheduledClips {
            ExtAudioFileDispose(clip.extAudioFile)
        }
        scheduledClips.removeAll()
    }
    
    // MARK: - Rendering (Audio Thread)
    
    /// Render audio clips into the output buffer
    /// Called from audio thread - should be realtime safe (ExtAudioFile is not perfectly RT-safe but acceptable)
    func render(
        into bufferList: UnsafeMutablePointer<AudioBufferList>,
        currentSample: Int64,
        frameCount: UInt32
    ) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        guard ablPointer.count >= 2 else { return }
        
        let outputLeft = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
        let outputRight = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
        
        guard let outL = outputLeft, let outR = outputRight else { return }
        
        let endSample = currentSample + Int64(frameCount)
        
        // Ensure read buffer is big enough
        ensureReadBuffer(size: Int(frameCount) * 2)  // Stereo interleaved
        guard let readBuf = readBuffer else { return }
        
        for i in 0..<scheduledClips.count {
            var clip = scheduledClips[i]
            
            // Skip if clip hasn't started yet
            if currentSample < clip.startSample {
                continue
            }
            
            // Skip if clip has ended
            if currentSample >= clip.endSample {
                continue
            }
            
            // Calculate how many frames to read
            let clipEndInBuffer = min(endSample, clip.endSample)
            let clipStartInBuffer = max(currentSample, clip.startSample)
            let framesToRead = UInt32(clipEndInBuffer - clipStartInBuffer)
            
            guard framesToRead > 0 else { continue }
            
            // Calculate offset in output buffer
            let outputOffset = Int(clipStartInBuffer - currentSample)
            
            // Set up buffer for reading
            var readBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: framesToRead * 8,  // 2 channels * 4 bytes
                    mData: readBuf
                )
            )
            
            // Read from file
            var framesToReadVar = framesToRead
            let status = ExtAudioFileRead(clip.extAudioFile, &framesToReadVar, &readBufferList)
            
            if status != noErr {
                print("[AudioClipRenderer] Read error: \(status)")
                continue
            }
            
            let framesRead = Int(framesToReadVar)
            
            // Mix into output (interleaved stereo to non-interleaved)
            for frame in 0..<framesRead {
                let leftSample = readBuf[frame * 2] * clip.volume
                let rightSample = readBuf[frame * 2 + 1] * clip.volume
                
                outL[outputOffset + frame] += leftSample
                outR[outputOffset + frame] += rightSample
            }
            
            clip.currentReadPosition = clipEndInBuffer
            scheduledClips[i] = clip
        }
    }
    
    private func ensureReadBuffer(size: Int) {
        if readBufferSize < size {
            readBuffer?.deallocate()
            readBuffer = UnsafeMutablePointer<Float>.allocate(capacity: size)
            readBufferSize = size
        }
    }
}
