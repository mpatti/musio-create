import SwiftUI
import DAWCore

// MARK: - AI Assistant View

public struct AIAssistantView: View {
    @ObservedObject var viewModel: ProjectViewModel
    @StateObject private var chatViewModel: AIChatViewModel
    @FocusState private var isInputFocused: Bool
    @Binding var isGenerativeFillMode: Bool
    
    public init(viewModel: ProjectViewModel, isGenerativeFillMode: Binding<Bool>) {
        self.viewModel = viewModel
        self._chatViewModel = StateObject(wrappedValue: AIChatViewModel(viewModel: viewModel))
        self._isGenerativeFillMode = isGenerativeFillMode
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
