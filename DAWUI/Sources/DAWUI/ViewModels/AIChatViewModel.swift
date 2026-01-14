import Foundation
import SwiftUI
import DAWCore
import Combine

// MARK: - AI Chat View Model

@MainActor
public final class AIChatViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published public var messages: [ChatMessage] = []
    @Published public var isProcessing: Bool = false
    @Published public var inputText: String = ""
    @Published public var errorMessage: String?
    
    // MARK: - Private Properties
    
    private weak var viewModel: ProjectViewModel?
    private let chatService = DAWChatService()
    private lazy var actionExecutor: ActionExecutor? = {
        guard let vm = viewModel else { return nil }
        return ActionExecutor(viewModel: vm)
    }()
    
    // MARK: - Initialization
    
    public init(viewModel: ProjectViewModel) {
        self.viewModel = viewModel
        
        // Add welcome message
        messages.append(ChatMessage(
            role: .assistant,
            content: "Hello! I'm your DAW assistant. I can help you with tasks like creating tracks, adjusting settings, editing clips, and more. Just tell me what you'd like to do!"
        ))
    }
    
    // MARK: - Public Methods
    
    public func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        // Clear input and add user message
        inputText = ""
        errorMessage = nil
        
        let userMessage = ChatMessage.user(text)
        messages.append(userMessage)
        
        isProcessing = true
        
        do {
            try await processMessage(text)
        } catch {
            errorMessage = error.localizedDescription
            messages.append(ChatMessage.assistant("Sorry, I encountered an error: \(error.localizedDescription)"))
        }
        
        isProcessing = false
    }
    
    public func clearChat() {
        messages.removeAll()
        messages.append(ChatMessage(
            role: .assistant,
            content: "Chat cleared. How can I help you?"
        ))
    }
    
    // MARK: - Private Methods
    
    private func processMessage(_ text: String) async throws {
        guard let viewModel = viewModel else {
            throw NSError(domain: "AIChatViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "ViewModel not available"])
        }
        
        // Serialize current project state
        let projectState = ProjectStateSerializer.serialize(
            project: viewModel.project,
            selectedTrackID: viewModel.selectedTrackID,
            selectedClipIDs: viewModel.selectedClipIDs,
            isPlaying: viewModel.transportState.isPlaying,
            isRecording: viewModel.isRecording,
            playheadBeat: viewModel.transportState.playheadBeats
        )
        
        // Build conversation history (last N messages for context)
        let historyLimit = 20
        let historyMessages = Array(messages.suffix(historyLimit))
        
        // Send to Claude
        var response = try await chatService.sendMessage(
            text,
            projectState: projectState,
            conversationHistory: historyMessages
        )
        
        // Process tool calls if any
        while response.stopReason == .toolUse && !response.toolCalls.isEmpty {
            // Execute the tool calls
            guard let executor = actionExecutor else {
                throw NSError(domain: "AIChatViewModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Action executor not available"])
            }
            
            let toolResults = await executor.execute(toolCalls: response.toolCalls)
            
            // Add assistant message with tool calls
            let assistantMessage = ChatMessage.assistant(
                response.message,
                toolCalls: response.toolCalls
            )
            messages.append(assistantMessage)
            
            // Add tool results message
            let resultsMessage = ChatMessage(
                role: .user,
                content: formatToolResults(toolResults),
                toolResults: toolResults
            )
            messages.append(resultsMessage)
            
            // Get fresh project state after actions
            let updatedState = ProjectStateSerializer.serialize(
                project: viewModel.project,
                selectedTrackID: viewModel.selectedTrackID,
                selectedClipIDs: viewModel.selectedClipIDs,
                isPlaying: viewModel.transportState.isPlaying,
                isRecording: viewModel.isRecording,
                playheadBeat: viewModel.transportState.playheadBeats
            )
            
            // Continue the conversation with tool results
            let updatedHistory = Array(messages.suffix(historyLimit))
            response = try await chatService.continueWithToolResults(
                toolResults: toolResults,
                projectState: updatedState,
                conversationHistory: updatedHistory
            )
        }
        
        // Add final assistant response
        if !response.message.isEmpty {
            messages.append(ChatMessage.assistant(response.message))
        }
    }
    
    private func formatToolResults(_ results: [ToolResult]) -> String {
        return results.map { result in
            let status = result.result.success ? "✓" : "✗"
            return "\(status) \(result.result.message)"
        }.joined(separator: "\n")
    }
}

// MARK: - Display Helpers

extension ChatMessage {
    /// Returns a user-friendly display of tool calls
    public var toolCallsDisplay: String? {
        guard let calls = toolCalls, !calls.isEmpty else { return nil }
        return calls.map { call in
            let params = call.arguments.map { "\($0.key): \($0.value.value)" }.joined(separator: ", ")
            return "→ \(call.name)(\(params))"
        }.joined(separator: "\n")
    }
    
    /// Check if this is a tool results message (internal, not shown directly)
    public var isToolResults: Bool {
        toolResults != nil && !toolResults!.isEmpty
    }
}
