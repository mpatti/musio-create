import Speech
import AVFoundation
import Combine

/// Manages voice input using macOS native speech recognition
@MainActor
public class VoiceInputManager: ObservableObject {
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    
    @Published public var transcribedText = ""
    @Published public var isListening = false
    @Published public var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published public var errorMessage: String?
    
    /// Called when transcription completes with the final text (for auto-send feature)
    public var onTranscriptionComplete: ((String) -> Void)?
    
    public var isAuthorized: Bool {
        authorizationStatus == .authorized
    }
    
    public init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        checkPermissions()
    }
    
    /// Check and request speech recognition permissions
    public func checkPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                print("[VoiceInput] Authorization status: \(status.rawValue)")
                if status != .authorized {
                    self?.errorMessage = self?.authorizationMessage(for: status)
                }
            }
        }
    }
    
    private func authorizationMessage(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "Speech recognition denied. Enable in System Settings > Privacy & Security > Speech Recognition."
        case .restricted:
            return "Speech recognition is restricted on this device."
        case .notDetermined:
            return "Speech recognition permission not yet requested."
        case .authorized:
            return ""
        @unknown default:
            return "Unknown speech recognition status."
        }
    }
    
    /// Toggle listening state
    public func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }
    
    /// Start listening and transcribing speech
    public func startListening() {
        guard let speechRecognizer = speechRecognizer else {
            errorMessage = "Speech recognizer not available"
            print("[VoiceInput] ERROR: Speech recognizer is nil")
            return
        }
        
        guard speechRecognizer.isAvailable else {
            errorMessage = "Speech recognition not available right now. Try again later."
            print("[VoiceInput] ERROR: Speech recognizer not available")
            return
        }
        
        guard isAuthorized else {
            errorMessage = "Speech recognition not authorized"
            print("[VoiceInput] ERROR: Not authorized, status: \(authorizationStatus.rawValue)")
            checkPermissions()
            return
        }
        
        // Cancel any existing task
        stopListening()
        
        // Clear previous state
        transcribedText = ""
        errorMessage = nil
        
        // Create a new audio engine for each session
        audioEngine = AVAudioEngine()
        
        guard let audioEngine = audioEngine else {
            errorMessage = "Failed to create audio engine"
            return
        }
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            errorMessage = "Unable to create speech recognition request"
            return
        }
        
        // Configure recognition request
        recognitionRequest.shouldReportPartialResults = true
        
        // Don't require on-device - let it use server if needed for better accuracy
        if #available(macOS 13.0, *) {
            recognitionRequest.requiresOnDeviceRecognition = false
            recognitionRequest.addsPunctuation = true
        }
        
        // Get the input node
        let inputNode = audioEngine.inputNode
        
        // Get the native format of the input node
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        print("[VoiceInput] Input audio format: \(recordingFormat)")
        print("[VoiceInput] Sample rate: \(recordingFormat.sampleRate)")
        print("[VoiceInput] Channels: \(recordingFormat.channelCount)")
        
        // Check if format is valid
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            errorMessage = "Invalid audio format. Check microphone permissions."
            print("[VoiceInput] ERROR: Invalid audio format")
            return
        }
        
        // Start recognition task BEFORE starting audio engine
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                
                var isFinal = false
                
                if let result = result {
                    self.transcribedText = result.bestTranscription.formattedString
                    isFinal = result.isFinal
                    print("[VoiceInput] Transcription: \(self.transcribedText) (final: \(isFinal))")
                }
                
                if let error = error {
                    print("[VoiceInput] Recognition error: \(error.localizedDescription)")
                    // Only show error if we're still supposed to be listening
                    if self.isListening && !isFinal {
                        // Check if it's just a timeout (user stopped talking)
                        let nsError = error as NSError
                        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                            // This is just "no speech detected" - not really an error
                            print("[VoiceInput] No speech detected, stopping")
                        } else {
                            self.errorMessage = "Recognition error: \(error.localizedDescription)"
                        }
                    }
                }
                
                if error != nil || isFinal {
                    self.stopListening()
                }
            }
        }
        
        // Create a mono format at the same sample rate as input (simpler conversion)
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: recordingFormat.sampleRate, channels: 1, interleaved: false) else {
            errorMessage = "Could not create mono format"
            return
        }
        print("[VoiceInput] Mono format for speech: \(monoFormat)")
        
        // Install audio tap with larger buffer
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData else { return }
            
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(recordingFormat.channelCount)
            
            // Create mono buffer
            guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity) else {
                return
            }
            monoBuffer.frameLength = buffer.frameLength
            
            guard let monoData = monoBuffer.floatChannelData?[0] else { return }
            
            // Mix all channels down to mono (average)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                monoData[frame] = sum / Float(channelCount)
            }
            
            // Calculate RMS to verify audio
            var rmsSum: Float = 0
            for i in 0..<frameCount {
                let sample = monoData[i]
                rmsSum += sample * sample
            }
            let rms = sqrt(rmsSum / Float(frameCount))
            if rms > 0.01 {
                print("[VoiceInput] Mono audio level: \(rms)")
            }
            
            // Send mono buffer to speech recognizer
            self.recognitionRequest?.append(monoBuffer)
        }
        
        // Prepare and start audio engine
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
            isListening = true
            print("[VoiceInput] Started listening successfully")
        } catch {
            errorMessage = "Could not start audio: \(error.localizedDescription)"
            print("[VoiceInput] ERROR starting audio engine: \(error)")
            cleanup()
        }
    }
    
    /// Stop listening and finalize transcription
    public func stopListening() {
        print("[VoiceInput] Stopping... isListening: \(isListening), text: '\(transcribedText)'")
        
        let wasListening = isListening
        let finalText = transcribedText
        
        // Stop audio engine
        if let audioEngine = audioEngine, audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        // End the audio stream
        recognitionRequest?.endAudio()
        
        // Cancel task
        recognitionTask?.cancel()
        
        // Clean up
        cleanup()
        
        isListening = false
        
        // Call completion handler if we have transcribed text
        if wasListening && !finalText.isEmpty {
            print("[VoiceInput] Calling completion with: '\(finalText)'")
            onTranscriptionComplete?(finalText)
            transcribedText = ""
        }
    }
    
    private func cleanup() {
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
    }
    
    /// Clear the transcribed text
    public func clearTranscription() {
        transcribedText = ""
    }
}
