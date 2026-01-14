import SwiftUI
import DAWCore
import AVFoundation

// MARK: - AI Generate Panel View

/// Floating panel for generating AI audio samples
public struct AIGeneratePanelView: View {
    @ObservedObject var viewModel: ProjectViewModel
    @Binding var isPresented: Bool
    
    @State private var prompt: String = ""
    @State private var selectedBeats: Int = 4
    @State private var isGenerating: Bool = false
    @State private var errorMessage: String?
    @State private var generatedAudioURL: URL?
    @State private var isPreviewPlaying: Bool = false
    @State private var previewPlayer: AVAudioPlayer?
    @State private var continueFromPrevious: Bool = false
    
    private let beatOptions = [1, 2, 4, 8, 16, 32]
    
    private let categoryChips = [
        "percussion loop",
        "drum loop",
        "pad",
        "cinematic hit",
        "riser",
        "horror texture",
        "ambient drone",
        "SFX impact"
    ]
    
    public init(viewModel: ProjectViewModel, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Category chips
                    categoryChipsView
                    
                    // Prompt input
                    promptInputView
                    
                    // Beat selector
                    beatSelectorView
                    
                    // Continuation toggle (only show if there's a previous AI clip)
                    if let previousClip = findPreviousAIClip() {
                        continuationToggleView(previousClip: previousClip)
                    }
                    
                    // Context info
                    contextInfoView
                    
                    // Error message
                    if let error = errorMessage {
                        errorView(error)
                    }
                    
                    // Preview section (when audio is generated)
                    if generatedAudioURL != nil {
                        previewView
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer with action buttons
            footerView
        }
        .frame(width: 450, height: 500)
        .onDisappear {
            stopPreview()
            // Don't cleanup here - only cleanup if user explicitly discards
            // The file is needed for the timeline if user placed it
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Image(systemName: "wand.and.stars")
                .foregroundColor(.accentColor)
            Text("AI Audio Generate")
                .font(.headline)
            Spacer()
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
    
    // MARK: - Category Chips
    
    private var categoryChipsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Categories")
                .font(.caption)
                .foregroundColor(.secondary)
            
            FlowLayout(spacing: 6) {
                ForEach(categoryChips, id: \.self) { category in
                    Button(action: {
                        if prompt.isEmpty {
                            prompt = category
                        } else {
                            prompt = category + " - " + prompt
                        }
                    }) {
                        Text(category)
                            .font(.system(size: 11))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - Prompt Input
    
    private var promptInputView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe the sound you want")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextField("e.g., epic trailer drums with toms and cymbals", text: $prompt)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }
    
    // MARK: - Beat Selector
    
    private var beatSelectorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Duration")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(durationText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 8) {
                ForEach(beatOptions, id: \.self) { beats in
                    Button(action: { selectedBeats = beats }) {
                        Text("\(beats)")
                            .font(.system(size: 12, weight: selectedBeats == beats ? .semibold : .regular))
                            .frame(width: 40, height: 28)
                            .background(selectedBeats == beats ? Color.accentColor : Color.secondary.opacity(0.1))
                            .foregroundColor(selectedBeats == beats ? .white : .primary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Text("beats")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var durationText: String {
        let tempo = viewModel.transportState.tempo.bpm
        let seconds = (Double(selectedBeats) / tempo) * 60.0
        let bars = selectedBeats / 4
        
        if bars >= 1 {
            return String(format: "\(bars) bar\(bars > 1 ? "s" : "") (%.1fs at %.0f BPM)", seconds, tempo)
        } else {
            return String(format: "%.1f seconds at %.0f BPM", seconds, tempo)
        }
    }
    
    // MARK: - Continuation Toggle
    
    private func continuationToggleView(previousClip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $continueFromPrevious) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundColor(continueFromPrevious ? .accentColor : .secondary)
                    Text("Continue from previous")
                        .font(.system(size: 12))
                }
            }
            .toggleStyle(.checkbox)
            
            if continueFromPrevious {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Continuing: \"\(previousClip.name)\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 22)
            }
        }
        .padding(10)
        .background(continueFromPrevious ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
    
    /// Find the most recent AI-generated clip on the first audio track
    private func findPreviousAIClip() -> Clip? {
        // Look for the first audio track
        guard let audioTrack = viewModel.project.tracks.first(where: { $0.type == .audio }) else {
            return nil
        }
        
        // Find AI-generated clips (clips whose name is not the default or matches AI patterns)
        // AI clips are named after their prompt, not "Generated Audio"
        let aiClips = audioTrack.clips.filter { clip in
            // Check if it's an audio clip
            guard case .audio = clip.content else { return false }
            
            // AI-generated clips have prompt-based names (not default names)
            // They're typically not named exactly "Generated Audio" unless prompt was empty
            let name = clip.name.lowercased()
            
            // Heuristics for AI-generated content:
            // 1. Contains common audio generation keywords
            // 2. Is not a standard imported file name
            let aiKeywords = ["loop", "drum", "beat", "pad", "ambient", "sfx", "percussion", 
                             "cinematic", "riser", "hit", "texture", "drone", "bass", "synth",
                             "piano", "strings", "brass", "guitar", "vocal", "choir"]
            
            let containsKeyword = aiKeywords.contains { name.contains($0) }
            let isLikelyAI = containsKeyword || 
                            !name.hasSuffix(".wav") && 
                            !name.hasSuffix(".mp3") && 
                            !name.hasSuffix(".aif") &&
                            clip.name != "Generated Audio"
            
            return isLikelyAI
        }
        
        // Return the most recent clip (last in the array, or by position)
        return aiClips.max(by: { $0.timeRange.start.samples < $1.timeRange.start.samples })
    }
    
    /// Get continuation context for the previous AI clip
    private func getContinuationContext() -> ContinuationContext? {
        guard continueFromPrevious, let previousClip = findPreviousAIClip() else {
            return nil
        }
        
        let tempo = viewModel.transportState.tempo.bpm
        let previousBeats = Int(previousClip.timeRange.duration.beats(atTempo: tempo))
        
        return ContinuationContext(
            previousPrompt: previousClip.name,  // The clip name IS the prompt (truncated)
            previousBeats: previousBeats,
            previousClipName: previousClip.name
        )
    }
    
    // MARK: - Context Info
    
    private var contextInfoView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Context")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                Label("\(Int(viewModel.transportState.tempo.bpm)) BPM", systemImage: "metronome")
                    .font(.caption)
                
                Spacer()
                
                if let context = getMIDIContext(), let desc = context.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(6)
        }
    }
    
    private func getMIDIContext() -> MIDIContext? {
        let startBeat = viewModel.transportState.playheadBeats
        let endBeat = startBeat + Double(selectedBeats)
        return MIDIContextAnalyzer.analyzeProject(viewModel.project, beatRange: startBeat...endBeat)
    }
    
    // MARK: - Error View
    
    private func errorView(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }
    
    // MARK: - Preview View
    
    private var previewView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                Button(action: togglePreview) {
                    Image(systemName: isPreviewPlaying ? "stop.fill" : "play.fill")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                
                Text("Generated audio ready")
                    .font(.caption)
                
                Spacer()
                
                Button("Discard") {
                    cleanupPreview()
                }
                .font(.caption)
            }
            .padding(8)
            .background(Color.green.opacity(0.1))
            .cornerRadius(6)
        }
    }
    
    // MARK: - Footer
    
    @State private var showSettings: Bool = false
    
    private var footerView: some View {
        HStack {
            if !ElevenLabsAPIKeyStorage.hasAPIKey {
                Button(action: { showSettings = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .foregroundColor(.orange)
                        Text("Configure API Key")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showSettings) {
                    AISettingsView()
                }
            }
            
            Spacer()
            
            Button("Cancel") {
                cleanupPreview()  // Delete the temp file if user cancels
                isPresented = false
            }
            .keyboardShortcut(.escape)
            
            if generatedAudioURL != nil {
                Button("Place on Timeline") {
                    placeOnTimeline()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: generate) {
                    if isGenerating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 60)
                    } else {
                        Text("Generate")
                            .frame(width: 60)
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(prompt.isEmpty || isGenerating || !ElevenLabsAPIKeyStorage.hasAPIKey)
            }
        }
        .padding()
    }
    
    // MARK: - Actions
    
    private func generate() {
        guard !prompt.isEmpty else { return }
        
        isGenerating = true
        errorMessage = nil
        
        // Get continuation context if enabled
        let continuationContext = getContinuationContext()
        
        Task {
            do {
                let url = try await viewModel.generateAIAudio(
                    prompt: prompt,
                    beats: selectedBeats,
                    continuationContext: continuationContext
                )
                await MainActor.run {
                    generatedAudioURL = url
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isGenerating = false
                }
            }
        }
    }
    
    private func togglePreview() {
        if isPreviewPlaying {
            stopPreview()
        } else {
            playPreview()
        }
    }
    
    private func playPreview() {
        guard let url = generatedAudioURL else { return }
        
        do {
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.play()
            isPreviewPlaying = true
        } catch {
            errorMessage = "Failed to play preview: \(error.localizedDescription)"
        }
    }
    
    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewPlaying = false
    }
    
    private func cleanupPreview() {
        stopPreview()
        if let url = generatedAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        generatedAudioURL = nil
    }
    
    private func placeOnTimeline() {
        guard let url = generatedAudioURL else { return }
        
        let startBeat = viewModel.transportState.playheadBeats
        let durationBeats = Double(selectedBeats)
        
        viewModel.importGeneratedAudio(from: url, atBeat: startBeat, durationBeats: durationBeats)
        
        // Close panel
        isPresented = false
    }
}

// MARK: - Flow Layout

/// Simple flow layout for chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                       y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }
    
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            positions.append(CGPoint(x: currentX, y: currentY))
            
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, currentX)
        }
        
        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}
