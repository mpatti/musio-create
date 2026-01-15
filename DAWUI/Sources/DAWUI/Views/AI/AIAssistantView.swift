import SwiftUI
import DAWCore

// MARK: - AI Assistant View

public struct AIAssistantView: View {
    @ObservedObject var viewModel: ProjectViewModel
    @StateObject private var chatViewModel: AIChatViewModel
    @ObservedObject var voiceInput: VoiceInputManager
    @FocusState private var isInputFocused: Bool
    @Binding var isGenerativeFillMode: Bool
    
    public init(viewModel: ProjectViewModel, isGenerativeFillMode: Binding<Bool>, voiceInput: VoiceInputManager) {
        self.viewModel = viewModel
        self._chatViewModel = StateObject(wrappedValue: AIChatViewModel(viewModel: viewModel))
        self._isGenerativeFillMode = isGenerativeFillMode
        self.voiceInput = voiceInput
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chatViewModel.messages.filter { !$0.isToolResults }) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        
                        if chatViewModel.isProcessing {
                            TypingIndicator()
                        }
                    }
                    .padding()
                }
                .onTapGesture {
                    // Clicking in the message area releases focus from text field
                    isInputFocused = false
                }
                .onChange(of: chatViewModel.messages.count) { _, _ in
                    if let lastMessage = chatViewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Error message if any
            if let error = chatViewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Dismiss") {
                        chatViewModel.errorMessage = nil
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }
            
            // Input area
            inputArea
        }
        .background(Color(nsColor: .controlBackgroundColor))
        // Release focus when transport state changes (play/stop/record)
        .onChange(of: viewModel.transportState.isPlaying) { _, _ in
            isInputFocused = false
        }
        .onChange(of: viewModel.isRecording) { _, _ in
            isInputFocused = false
        }
        // Release focus when user selects a track
        .onChange(of: viewModel.selectedTrackID) { _, _ in
            isInputFocused = false
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundColor(.purple)
            Text("AI Assistant")
                .font(.headline)
            Spacer()
            
            // Generative Fill toggle
            Toggle(isOn: $isGenerativeFillMode) {
                Image(systemName: "wand.and.stars")
            }
            .toggleStyle(.button)
            .tint(isGenerativeFillMode ? .purple : nil)
            .help(isGenerativeFillMode ? "Exit Generative Fill mode" : "Generative Fill - click and drag on track to select range")
            
            Button(action: { chatViewModel.clearChat() }) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear chat history")
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Input Area
    
    private var inputArea: some View {
        VStack(spacing: 0) {
            // Voice input indicator
            if voiceInput.isListening {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Listening...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if !voiceInput.transcribedText.isEmpty {
                        Text(voiceInput.transcribedText)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
            }
            
            // Voice error message
            if let voiceError = voiceInput.errorMessage {
                HStack {
                    Image(systemName: "mic.slash")
                        .foregroundColor(.orange)
                    Text(voiceError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Dismiss") {
                        voiceInput.errorMessage = nil
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
            
            HStack(spacing: 8) {
                TextField("Ask me anything...", text: $chatViewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .onSubmit {
                        if !chatViewModel.inputText.isEmpty && !chatViewModel.isProcessing {
                            Task {
                                await chatViewModel.sendMessage()
                            }
                        }
                    }
                
                // Microphone button
                Button(action: {
                    print("[AIAssistant] Mic button clicked, isListening: \(voiceInput.isListening), authorized: \(voiceInput.isAuthorized), status: \(voiceInput.authorizationStatus.rawValue)")
                    voiceInput.toggleListening()
                }) {
                    Image(systemName: voiceInput.isListening ? "mic.fill" : "mic")
                        .foregroundColor(micButtonColor)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help(micButtonHelp)
                
                // Send button
                Button(action: {
                    Task {
                        await chatViewModel.sendMessage()
                    }
                }) {
                    Image(systemName: chatViewModel.isProcessing ? "hourglass" : "paperplane.fill")
                        .foregroundColor(chatViewModel.inputText.isEmpty || chatViewModel.isProcessing ? .secondary : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(chatViewModel.inputText.isEmpty || chatViewModel.isProcessing)
            }
            .padding()
            .background(Color(nsColor: .textBackgroundColor))
        }
        // Setup auto-send when voice transcription completes
        .onAppear {
            voiceInput.onTranscriptionComplete = { [weak chatViewModel] text in
                guard let chatViewModel = chatViewModel else { return }
                Task { @MainActor in
                    // Set the input text and send immediately
                    chatViewModel.inputText = text
                    await chatViewModel.sendMessage()
                }
            }
        }
    }
    
    private var micButtonColor: Color {
        if voiceInput.isListening {
            return .red
        } else if !voiceInput.isAuthorized && voiceInput.authorizationStatus != .notDetermined {
            return .orange  // Show orange if not authorized
        } else {
            return .secondary
        }
    }
    
    private var micButtonHelp: String {
        if voiceInput.isListening {
            return "Stop listening"
        } else if !voiceInput.isAuthorized {
            switch voiceInput.authorizationStatus {
            case .denied:
                return "Speech recognition denied - check System Settings"
            case .restricted:
                return "Speech recognition restricted"
            case .notDetermined:
                return "Click to enable voice input"
            default:
                return "Start voice input"
            }
        } else {
            return "Start voice input"
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Avatar
            avatar
            
            VStack(alignment: .leading, spacing: 4) {
                // Content
                Text(message.content)
                    .textSelection(.enabled)
                
                // Tool calls if present
                if let toolCalls = message.toolCallsDisplay {
                    Text(toolCalls)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Color.black.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            
            if message.role == .user {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
    
    private var avatar: some View {
        Group {
            if message.role == .user {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            } else {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundColor(.purple)
            }
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var dotCount = 0
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundColor(.purple)
            
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(dotCount == index ? 1 : 0.3)
                }
            }
            .onAppear {
                startAnimation()
            }
        }
    }
    
    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            withAnimation {
                dotCount = (dotCount + 1) % 3
            }
        }
    }
}

// MARK: - Quick Actions (Optional)

struct QuickActionsBar: View {
    let onAction: (String) -> Void
    
    private let quickActions = [
        ("Add MIDI track", "rectangle.stack.badge.plus"),
        ("Set tempo", "metronome"),
        ("Mute all", "speaker.slash"),
        ("Show mixer", "slider.horizontal.3")
    ]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickActions, id: \.0) { action in
                    Button(action: { onAction(action.0) }) {
                        Label(action.0, systemImage: action.1)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
}
