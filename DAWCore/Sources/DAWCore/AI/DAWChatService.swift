import Foundation

// MARK: - Chat Message

public struct ChatMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let content: String
    public let timestamp: Date
    public let toolCalls: [ToolCall]?
    public let toolResults: [ToolResult]?
    
    public enum MessageRole: String, Codable, Sendable {
        case user
        case assistant
        case system
    }
    
    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        toolCalls: [ToolCall]? = nil,
        toolResults: [ToolResult]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }
    
    public static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: .user, content: content)
    }
    
    public static func assistant(_ content: String, toolCalls: [ToolCall]? = nil) -> ChatMessage {
        ChatMessage(role: .assistant, content: content, toolCalls: toolCalls)
    }
}

// MARK: - Tool Result

public struct ToolResult: Codable, Sendable {
    public let toolCallId: String
    public let result: ActionResult
    
    public init(toolCallId: String, result: ActionResult) {
        self.toolCallId = toolCallId
        self.result = result
    }
}

// MARK: - Chat Response

public struct ChatResponse: Sendable {
    public let message: String
    public let toolCalls: [ToolCall]
    public let stopReason: StopReason
    
    public enum StopReason: String, Sendable {
        case endTurn = "end_turn"
        case toolUse = "tool_use"
        case maxTokens = "max_tokens"
        case unknown
    }
    
    public init(message: String, toolCalls: [ToolCall], stopReason: StopReason) {
        self.message = message
        self.toolCalls = toolCalls
        self.stopReason = stopReason
    }
}

// MARK: - DAW Chat Service

public actor DAWChatService {
    
    private let directAPIURL = "https://api.anthropic.com/v1/messages"
    private let session: URLSession
    private let actionRegistry = DAWActionRegistry.shared
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Request Helper
    
    private func makeRequest(body: [String: Any]) async throws -> (Data, URLResponse) {
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        
        // Prefer Supabase Edge Function if configured
        if SupabaseEdgeFunctionConfig.isConfigured,
           let proxyURL = SupabaseEdgeFunctionConfig.claudeProxyURL(),
           let anonKey = SupabaseEdgeFunctionConfig.supabaseAnonKey {
            
            print("[DAWChat] Using Supabase Edge Function proxy")
            
            var request = URLRequest(url: proxyURL)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = jsonData
            
            return try await session.data(for: request)
        }
        
        // Fallback to direct API if local key is set
        if let apiKey = ClaudeAPIKeyStorage.apiKey, !apiKey.isEmpty {
            print("[DAWChat] Using direct API with local key")
            
            var request = URLRequest(url: URL(string: directAPIURL)!)
            request.httpMethod = "POST"
            request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            
            return try await session.data(for: request)
        }
        
        throw ClaudeError.notConfigured
    }
    
    // MARK: - System Prompt
    
    private func buildSystemPrompt(projectState: String) -> String {
        return """
        You are an AI assistant integrated into a Digital Audio Workstation (DAW). You help users create, edit, and manage their music projects through natural conversation.

        ## Your Capabilities
        You can perform any action a human user can do in the DAW, including:
        - Creating, deleting, and managing tracks (audio, MIDI, instrument)
        - Controlling transport (play, stop, record, seek)
        - Editing clips (create, move, duplicate, delete)
        - Adjusting mixer settings (volume, pan, mute, solo)
        - Setting tempo and time signature
        - Managing project settings

        ## Current Project State
        \(projectState)

        ## Guidelines
        1. When the user asks you to do something, use the appropriate tools to execute the action
        2. Always confirm what you did after executing actions
        3. If a request is ambiguous, ask for clarification
        4. When referring to bars, use 1-based numbering (bar 1 is the first bar)
        5. Be concise but helpful in your responses
        6. If you can't do something, explain why and suggest alternatives
        7. You can chain multiple actions together for complex requests

        ## Important Notes
        - Track names are case-insensitive when searching
        - Clip indices are 0-based (first clip is index 0)
        - Volume is 0.0 to 1.0 (linear), but users may say "dB"
        - Pan is -1.0 (left) to 1.0 (right)
        - All time positions can be specified in bars (1-based) or beats (0-based)
        """
    }
    
    // MARK: - Send Message
    
    public func sendMessage(
        _ message: String,
        projectState: String,
        conversationHistory: [ChatMessage]
    ) async throws -> ChatResponse {
        guard ClaudeService.isAvailable else {
            throw ClaudeError.notConfigured
        }
        
        // Build messages array for API
        var messages: [[String: Any]] = []
        
        // Add conversation history
        for chatMessage in conversationHistory {
            switch chatMessage.role {
            case .user:
                // Check if this is a tool results message
                if let toolResults = chatMessage.toolResults, !toolResults.isEmpty {
                    // Format as tool_result blocks
                    var resultContent: [[String: Any]] = []
                    for result in toolResults {
                        resultContent.append([
                            "type": "tool_result",
                            "tool_use_id": result.toolCallId,
                            "content": result.result.message
                        ])
                    }
                    messages.append([
                        "role": "user",
                        "content": resultContent
                    ])
                } else {
                    // Regular user message
                    messages.append([
                        "role": "user",
                        "content": chatMessage.content
                    ])
                }
            case .assistant:
                if let toolCalls = chatMessage.toolCalls, !toolCalls.isEmpty {
                    // Assistant message with tool use
                    var content: [[String: Any]] = []
                    
                    if !chatMessage.content.isEmpty {
                        content.append([
                            "type": "text",
                            "text": chatMessage.content
                        ])
                    }
                    
                    for toolCall in toolCalls {
                        content.append([
                            "type": "tool_use",
                            "id": toolCall.id,
                            "name": toolCall.name,
                            "input": toolCall.arguments.mapValues { $0.value }
                        ])
                    }
                    
                    messages.append([
                        "role": "assistant",
                        "content": content
                    ])
                } else {
                    messages.append([
                        "role": "assistant",
                        "content": chatMessage.content
                    ])
                }
            case .system:
                // System messages are handled separately
                break
            }
        }
        
        // Add current user message
        messages.append([
            "role": "user",
            "content": message
        ])
        
        // Build request body
        let requestBody: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 4096,
            "system": buildSystemPrompt(projectState: projectState),
            "tools": actionRegistry.getAllToolsForClaude(),
            "messages": messages
        ]
        
        print("[DAWChat] Sending message to Claude...")
        
        // Make the request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await makeRequest(body: requestBody)
        } catch {
            throw ClaudeError.networkError(error)
        }
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }
        
        print("[DAWChat] Response status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[DAWChat] ERROR: \(errorMessage)")
            throw ClaudeError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Parse response
        return try parseResponse(data: data)
    }
    
    // MARK: - Continue with Tool Results
    
    public func continueWithToolResults(
        toolResults: [ToolResult],
        projectState: String,
        conversationHistory: [ChatMessage]
    ) async throws -> ChatResponse {
        guard ClaudeService.isAvailable else {
            throw ClaudeError.notConfigured
        }
        
        // Build messages including the tool results
        var messages: [[String: Any]] = []
        
        // Add conversation history (same as sendMessage)
        for chatMessage in conversationHistory {
            switch chatMessage.role {
            case .user:
                // Check if this is a tool results message
                if let msgToolResults = chatMessage.toolResults, !msgToolResults.isEmpty {
                    // Format as tool_result blocks
                    var resultContent: [[String: Any]] = []
                    for result in msgToolResults {
                        resultContent.append([
                            "type": "tool_result",
                            "tool_use_id": result.toolCallId,
                            "content": result.result.message
                        ])
                    }
                    messages.append([
                        "role": "user",
                        "content": resultContent
                    ])
                } else {
                    // Regular user message
                    messages.append([
                        "role": "user",
                        "content": chatMessage.content
                    ])
                }
            case .assistant:
                if let toolCalls = chatMessage.toolCalls, !toolCalls.isEmpty {
                    var content: [[String: Any]] = []
                    
                    if !chatMessage.content.isEmpty {
                        content.append([
                            "type": "text",
                            "text": chatMessage.content
                        ])
                    }
                    
                    for toolCall in toolCalls {
                        content.append([
                            "type": "tool_use",
                            "id": toolCall.id,
                            "name": toolCall.name,
                            "input": toolCall.arguments.mapValues { $0.value }
                        ])
                    }
                    
                    messages.append([
                        "role": "assistant",
                        "content": content
                    ])
                } else {
                    messages.append([
                        "role": "assistant",
                        "content": chatMessage.content
                    ])
                }
            case .system:
                break
            }
        }
        
        // Note: Tool results are already included in conversationHistory, 
        // so we don't add them again here
        
        // Build request
        let requestBody: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 4096,
            "system": buildSystemPrompt(projectState: projectState),
            "tools": actionRegistry.getAllToolsForClaude(),
            "messages": messages
        ]
        
        print("[DAWChat] Continuing with tool results...")
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await makeRequest(body: requestBody)
        } catch {
            throw ClaudeError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        return try parseResponse(data: data)
    }
    
    // MARK: - Parse Response
    
    private func parseResponse(data: Data) throws -> ChatResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let stopReason = json["stop_reason"] as? String else {
            throw ClaudeError.invalidResponse
        }
        
        var textContent = ""
        var toolCalls: [ToolCall] = []
        
        for block in content {
            guard let blockType = block["type"] as? String else { continue }
            
            switch blockType {
            case "text":
                if let text = block["text"] as? String {
                    textContent += text
                }
                
            case "tool_use":
                if let id = block["id"] as? String,
                   let name = block["name"] as? String,
                   let input = block["input"] as? [String: Any] {
                    let arguments = input.mapValues { AnyCodable($0) }
                    toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
                }
                
            default:
                break
            }
        }
        
        let reason: ChatResponse.StopReason
        switch stopReason {
        case "end_turn": reason = .endTurn
        case "tool_use": reason = .toolUse
        case "max_tokens": reason = .maxTokens
        default: reason = .unknown
        }
        
        print("[DAWChat] Parsed response: \(textContent.prefix(100))... | \(toolCalls.count) tool calls | stop: \(stopReason)")
        
        return ChatResponse(message: textContent, toolCalls: toolCalls, stopReason: reason)
    }
}
