import SwiftUI
import DAWCore

// MARK: - Notification Names

public extension Notification.Name {
    static let performUndo = Notification.Name("performUndo")
    static let performRedo = Notification.Name("performRedo")
    static let togglePlayPause = Notification.Name("togglePlayPause")
    static let stop = Notification.Name("stop")
    static let returnToZero = Notification.Name("returnToZero")
    static let toggleLoop = Notification.Name("toggleLoop")
    static let toggleMetronome = Notification.Name("toggleMetronome")
    static let newAudioTrack = Notification.Name("newAudioTrack")
    static let newMIDITrack = Notification.Name("newMIDITrack")
    static let deleteSelectedTrack = Notification.Name("deleteSelectedTrack")
    static let toggleMixer = Notification.Name("toggleMixer")
    static let toggleInspector = Notification.Name("toggleInspector")
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let projectDidChange = Notification.Name("projectDidChange")
    
    // Plugin state management
    static let savePluginStates = Notification.Name("savePluginStates")
    static let clearAllPlugins = Notification.Name("clearAllPlugins")
    static let restorePluginStates = Notification.Name("restorePluginStates")
    
    // Request current project from viewModel
    static let requestProjectForSave = Notification.Name("requestProjectForSave")
    static let projectDataForSave = Notification.Name("projectDataForSave")
}

// MARK: - Keyboard Handler

/// Handles keyboard shortcuts for the DAW
public struct KeyboardShortcutHandler: ViewModifier {
    @ObservedObject var viewModel: ProjectViewModel
    
    public func body(content: Content) -> some View {
        content
            .modifier(TransportShortcuts(viewModel: viewModel))
            .modifier(EditShortcuts(viewModel: viewModel))
            .modifier(ViewShortcuts(viewModel: viewModel))
    }
}

private struct TransportShortcuts: ViewModifier {
    @ObservedObject var viewModel: ProjectViewModel
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .togglePlayPause)) { _ in
                viewModel.togglePlayPause()
            }
            .onReceive(NotificationCenter.default.publisher(for: .stop)) { _ in
                viewModel.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .returnToZero)) { _ in
                viewModel.transportState.returnToZero()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleLoop)) { _ in
                viewModel.transportState.toggleLoop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleMetronome)) { _ in
                viewModel.transportState.isMetronomeEnabled.toggle()
            }
    }
}

private struct EditShortcuts: ViewModifier {
    @ObservedObject var viewModel: ProjectViewModel
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .performUndo)) { _ in
                viewModel.undo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .performRedo)) { _ in
                viewModel.redo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newAudioTrack)) { _ in
                viewModel.addTrack(type: .audio)
            }
            .onReceive(NotificationCenter.default.publisher(for: .newMIDITrack)) { _ in
                viewModel.addTrack(type: .midi)
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedTrack)) { _ in
                if let trackID = viewModel.selectedTrackID {
                    viewModel.deleteTrack(id: trackID)
                }
            }
    }
}

private struct ViewShortcuts: ViewModifier {
    @ObservedObject var viewModel: ProjectViewModel
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .toggleMixer)) { _ in
                viewModel.showMixer.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in
                viewModel.showInspector.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in
                viewModel.zoomIn()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in
                viewModel.zoomOut()
            }
    }
}

extension View {
    public func handleKeyboardShortcuts(viewModel: ProjectViewModel) -> some View {
        modifier(KeyboardShortcutHandler(viewModel: viewModel))
    }
}

// MARK: - Focus-based Keyboard Handling

/// Keyboard event handler for focused views
public struct FocusedKeyboardHandler: ViewModifier {
    @ObservedObject var viewModel: ProjectViewModel
    @FocusState private var isFocused: Bool
    
    public func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onKeyPress(.space) {
                viewModel.togglePlayPause()
                return .handled
            }
            .onKeyPress(.return) {
                viewModel.stop()
                return .handled
            }
            .onKeyPress(.delete) {
                deleteSelection()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                nudgePlayhead(by: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                nudgePlayhead(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                selectPreviousTrack()
                return .handled
            }
            .onKeyPress(.downArrow) {
                selectNextTrack()
                return .handled
            }
    }
    
    private func deleteSelection() {
        // Delete selected clips
        for clipID in viewModel.selectedClipIDs {
            if let trackID = viewModel.selectedTrackID {
                viewModel.deleteClip(id: clipID, from: trackID)
            }
        }
    }
    
    private func nudgePlayhead(by beats: Double) {
        let newBeat = max(0, viewModel.transportState.playheadBeats + beats)
        viewModel.transportState.setPlayheadBeats(newBeat)
    }
    
    private func selectPreviousTrack() {
        guard let currentID = viewModel.selectedTrackID,
              let currentIndex = viewModel.project.tracks.firstIndex(where: { $0.id == currentID }),
              currentIndex > 0 else { return }
        
        viewModel.selectAndArmTrack(viewModel.project.tracks[currentIndex - 1].id)
    }
    
    private func selectNextTrack() {
        guard let currentID = viewModel.selectedTrackID,
              let currentIndex = viewModel.project.tracks.firstIndex(where: { $0.id == currentID }),
              currentIndex < viewModel.project.tracks.count - 1 else { return }
        
        viewModel.selectAndArmTrack(viewModel.project.tracks[currentIndex + 1].id)
    }
}

extension View {
    public func handleFocusedKeyboard(viewModel: ProjectViewModel) -> some View {
        modifier(FocusedKeyboardHandler(viewModel: viewModel))
    }
}

// MARK: - Global Key Monitor

/// Monitors keyboard events at the application level (requires AppKit)
public final class GlobalKeyMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var keyUpMonitor: Any?
    
    public weak var viewModel: ProjectViewModel?
    
    /// Set to true to disable keyboard shortcuts (e.g., when a modal is open)
    public var isDisabled: Bool = false
    
    // Bar jump mode state
    private var isBarJumpMode: Bool = false
    private var barJumpInput: String = ""
    
    /// Callback to show bar jump input in UI (optional)
    public var onBarJumpModeChanged: ((Bool, String) -> Void)?
    
    /// Callbacks for push-to-talk (fn key)
    public var onPushToTalkStart: (() -> Void)?
    public var onPushToTalkEnd: (() -> Void)?
    
    // Track fn key state
    private var isFnPressed = false
    
    public init() {}
    
    deinit {
        stop()
    }
    
    public func start() {
        // Stop any existing monitors first
        stop()
        
        print("[KeyMonitor] Starting keyboard monitor")
        
        // Local monitor for keyDown (when app is in focus)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil  // Event was handled
            }
            return event
        }
        
        // Monitor for keyUp (for other key releases if needed)
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if self?.handleKeyUpEvent(event) == true {
                return nil
            }
            return event
        }
        
        // Monitor flagsChanged for fn key push-to-talk
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }
    
    public func stop() {
        if let monitor = localMonitor {
            print("[KeyMonitor] Stopping keyboard monitor")
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = keyUpMonitor {
            NSEvent.removeMonitor(monitor)
            keyUpMonitor = nil
        }
    }
    
    private func handleKeyUpEvent(_ event: NSEvent) -> Bool {
        // Reserved for future key up handling
        return false
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        // Handle fn key for push-to-talk
        let fnPressed = event.modifierFlags.contains(.function)
        
        if fnPressed && !isFnPressed {
            // fn key pressed
            print("[KeyMonitor] fn key pressed - starting push-to-talk")
            isFnPressed = true
            onPushToTalkStart?()
        } else if !fnPressed && isFnPressed {
            // fn key released
            print("[KeyMonitor] fn key released - stopping push-to-talk")
            isFnPressed = false
            onPushToTalkEnd?()
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let viewModel = viewModel else { return false }
        
        // Don't handle events when disabled (e.g., modal/sheet is open)
        if isDisabled { return false }
        
        // Don't handle events when typing in a text field
        // EXCEPT for delete key when clips are selected (delete works for both)
        let isDeleteKey = event.keyCode == 51 || event.keyCode == 117
        let hasSelectedClips = MainActor.assumeIsolated { !viewModel.selectedClipIDs.isEmpty }
        if isTextFieldFirstResponder() && !(isDeleteKey && hasSelectedClips) { return false }
        
        // Check for modifier keys
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        
        // Handle bar jump mode input
        if isBarJumpMode {
            return handleBarJumpInput(event, viewModel: viewModel)
        }
        
        // Debug: Log all key events to help diagnose numpad issues
        print("[KeyMonitor] keyCode: \(event.keyCode), chars: '\(event.characters ?? "nil")', modifiers: \(modifiers.rawValue)")
        
        // Check for period key by character (handles both main keyboard and numpad)
        if let chars = event.characters, chars == "." {
            // Accept period with no modifiers, or with numericPad flag (for numpad)
            if modifiers.isEmpty || modifiers == .numericPad {
                isBarJumpMode = true
                barJumpInput = ""
                onBarJumpModeChanged?(true, "")
                return true
            }
        }
        
        switch event.keyCode {
            
        case 49:  // Space
            if modifiers.isEmpty {
                Task { @MainActor in
                    viewModel.togglePlayPause()
                }
                return true
            }
            
        case 36:  // Return
            if modifiers.isEmpty {
                Task { @MainActor in
                    viewModel.stop()
                }
                return true
            }
            
        case 76:  // Numpad Enter - acts like spacebar (play/pause)
            Task { @MainActor in
                viewModel.togglePlayPause()
            }
            return true
            
        case 85:  // Numpad 3 - Record
            Task { @MainActor in
                if viewModel.isRecording {
                    viewModel.stopRecording()
                } else {
                    viewModel.startRecording()
                }
            }
            return true
            
        case 6:  // Z
            if modifiers == .command {
                Task { @MainActor in
                    viewModel.undo()
                }
                return true
            } else if modifiers == [.command, .shift] {
                Task { @MainActor in
                    viewModel.redo()
                }
                return true
            }
            
        case 37:  // L
            if modifiers == .command {
                Task { @MainActor in
                    viewModel.transportState.toggleLoop()
                }
                return true
            }
            
        case 8:  // C
            if modifiers == .command {
                Task { @MainActor in
                    viewModel.copySelectedClips()
                }
                return true
            }
            
        case 9:  // V
            if modifiers == .command {
                Task { @MainActor in
                    viewModel.pasteClips()
                }
                return true
            }
            
        case 7:  // X
            if modifiers == .command {
                Task { @MainActor in
                    viewModel.cutSelectedClips()
                }
                return true
            }
            
        case 2:  // D
            if modifiers == .command {
                Task { @MainActor in
                    viewModel.duplicateSelectedClips()
                }
                return true
            }
            
        case 0:  // A
            if modifiers == .command {
                Task { @MainActor in
                    viewModel.selectAllClipsOnTrack()
                }
                return true
            }
            
        case 14:  // E
            if modifiers == .command {
                Task { @MainActor in
                    viewModel.splitClipAtPlayhead()
                }
                return true
            }
            
        case 51:  // Delete/Backspace
            print("[KeyMonitor] Delete key pressed, modifiers: \(modifiers)")
            if modifiers.isEmpty {
                // If piano roll is open, let the event pass through to MIDI editor
                // NSEvent handlers run on main thread, so we can use MainActor.assumeIsolated
                let pianoRollShowing = MainActor.assumeIsolated { viewModel.showPianoRoll }
                if pianoRollShowing {
                    print("[KeyMonitor] Piano roll open, passing through")
                    return false
                }
                let clipCount = MainActor.assumeIsolated { viewModel.selectedClipIDs.count }
                print("[KeyMonitor] Deleting \(clipCount) selected clips")
                Task { @MainActor in
                    viewModel.deleteSelectedClips()
                }
                return true
            }
            
        case 117:  // Forward Delete
            print("[KeyMonitor] Forward Delete key pressed, modifiers: \(modifiers)")
            if modifiers.isEmpty {
                // If piano roll is open, let the event pass through to MIDI editor
                let pianoRollShowing = MainActor.assumeIsolated { viewModel.showPianoRoll }
                if pianoRollShowing {
                    print("[KeyMonitor] Piano roll open, passing through")
                    return false
                }
                let clipCount = MainActor.assumeIsolated { viewModel.selectedClipIDs.count }
                print("[KeyMonitor] Deleting \(clipCount) selected clips")
                Task { @MainActor in
                    viewModel.deleteSelectedClips()
                }
                return true
            }
            
        case 53:  // Escape
            if modifiers.isEmpty {
                Task { @MainActor in
                    viewModel.deselectAllClips()
                }
                return true
            }
            
        case 123:  // Left Arrow
            if modifiers == .option {
                // Option+Left: Nudge clip left by 1 beat
                Task { @MainActor in
                    viewModel.nudgeSelectedClips(byBeats: -1)
                }
                return true
            } else if modifiers == [.option, .shift] {
                // Option+Shift+Left: Nudge clip left by 0.25 beat
                Task { @MainActor in
                    viewModel.nudgeSelectedClips(byBeats: -0.25)
                }
                return true
            }
            
        case 124:  // Right Arrow
            if modifiers == .option {
                // Option+Right: Nudge clip right by 1 beat
                Task { @MainActor in
                    viewModel.nudgeSelectedClips(byBeats: 1)
                }
                return true
            } else if modifiers == [.option, .shift] {
                // Option+Shift+Right: Nudge clip right by 0.25 beat
                Task { @MainActor in
                    viewModel.nudgeSelectedClips(byBeats: 0.25)
                }
                return true
            }
            
        case 5:  // G
            if modifiers == .command {
                // Cmd+G: Trim selected clips to grid
                Task { @MainActor in
                    viewModel.trimSelectedClipsToGrid()
                }
                return true
            }
            
        default:
            break
        }
        
        return false
    }
    
    /// Handle keyboard input while in bar jump mode
    private func handleBarJumpInput(_ event: NSEvent, viewModel: ProjectViewModel) -> Bool {
        let keyCode = event.keyCode
        
        // Number keys (main keyboard: 18-29 for 1-0, numpad: 82-92)
        // Main keyboard number row
        let numberKeyCodes: [UInt16: String] = [
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
            23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            // Numpad
            82: "0", 83: "1", 84: "2", 85: "3", 86: "4",
            87: "5", 88: "6", 89: "7", 91: "8", 92: "9"
        ]
        
        switch keyCode {
        case 36, 76:  // Return or Numpad Enter - Execute jump
            if let barNumber = Int(barJumpInput), barNumber > 0 {
                Task { @MainActor in
                    // Calculate beat position from bar number
                    // Bar 1 = beat 0, Bar 2 = beat 4 (in 4/4), etc.
                    let beatsPerBar = Double(viewModel.transportState.timeSignature.beatsPerBar)
                    let targetBeat = Double(barNumber - 1) * beatsPerBar
                    viewModel.seekTo(beat: targetBeat)
                }
            }
            exitBarJumpMode()
            return true
            
        case 53:  // Escape - Cancel bar jump
            exitBarJumpMode()
            return true
            
        case 51:  // Delete/Backspace - Remove last digit
            if !barJumpInput.isEmpty {
                barJumpInput.removeLast()
                onBarJumpModeChanged?(true, barJumpInput)
            } else {
                exitBarJumpMode()
            }
            return true
            
        default:
            // Check if it's a number key by keycode first
            if let digit = numberKeyCodes[keyCode] {
                barJumpInput += digit
                onBarJumpModeChanged?(true, barJumpInput)
                return true
            }
            // Fallback: check by character (for numpad compatibility)
            if let chars = event.characters, chars.count == 1,
               let char = chars.first, char.isNumber {
                barJumpInput += String(char)
                onBarJumpModeChanged?(true, barJumpInput)
                return true
            }
            // Any other key cancels bar jump mode
            exitBarJumpMode()
            return false
        }
    }
    
    private func exitBarJumpMode() {
        isBarJumpMode = false
        barJumpInput = ""
        onBarJumpModeChanged?(false, "")
    }
    
    /// Check if the current first responder is a text input field
    private func isTextFieldFirstResponder() -> Bool {
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else {
            return false
        }
        
        // Check if it's a text view or text field
        if firstResponder is NSTextView || firstResponder is NSTextField {
            return true
        }
        
        // Also check the field editor (used by NSTextField)
        if let textView = firstResponder as? NSTextView,
           textView.isFieldEditor {
            return true
        }
        
        return false
    }
}

// MARK: - Piano Keyboard Input

/// Handles MIDI keyboard input for note preview
public struct PianoKeyboardInputHandler: ViewModifier {
    @ObservedObject var viewModel: ProjectViewModel
    let trackID: TrackID?
    
    @State private var pressedKeys: Set<UInt8> = []
    
    // Computer keyboard to MIDI note mapping
    private let keyMap: [UInt16: UInt8] = [
        // Lower row: Z-M = C3-B3
        6: 48,   // Z = C3
        7: 49,   // X = C#3
        8: 50,   // C = D3
        9: 51,   // V = D#3
        11: 52,  // B = E3
        45: 53,  // N = F3
        46: 54,  // M = F#3
        
        // Middle row: A-L = C4-B4
        0: 60,   // A = C4 (Middle C)
        1: 61,   // S = C#4
        2: 62,   // D = D4
        3: 63,   // F = D#4
        5: 64,   // G = E4
        4: 65,   // H = F4
        38: 66,  // J = F#4
        40: 67,  // K = G4
        37: 68,  // L = G#4
        
        // Upper row: Q-P = C5-B5
        12: 72,  // Q = C5
        13: 73,  // W = C#5
        14: 74,  // E = D5
        15: 75,  // R = D#5
        17: 76,  // T = E5
        16: 77,  // Y = F5
        32: 78,  // U = F#5
        34: 79,  // I = G5
        31: 80,  // O = G#5
        35: 81,  // P = A5
    ]
    
    public func body(content: Content) -> some View {
        content
            .onKeyPress(phases: .down) { keyPress in
                handleKeyDown(keyPress)
            }
            .onKeyPress(phases: .up) { keyPress in
                handleKeyUp(keyPress)
            }
    }
    
    private func handleKeyDown(_ keyPress: KeyPress) -> KeyPress.Result {
        // This would need the actual key code, which isn't directly available
        // In production, you'd use NSEvent monitoring
        return .ignored
    }
    
    private func handleKeyUp(_ keyPress: KeyPress) -> KeyPress.Result {
        return .ignored
    }
}

extension View {
    public func handlePianoKeyboardInput(viewModel: ProjectViewModel, trackID: TrackID?) -> some View {
        modifier(PianoKeyboardInputHandler(viewModel: viewModel, trackID: trackID))
    }
}

// MARK: - Selection Manager

/// Manages selection state and operations
@MainActor
public final class SelectionManager: ObservableObject {
    @Published public var selectedTrackIDs: Set<TrackID> = []
    @Published public var selectedClipIDs: Set<ClipID> = []
    @Published public var selectedNoteIDs: Set<UUID> = []
    @Published public var selectedAutomationPointIDs: Set<UUID> = []
    
    // Selection rectangle
    @Published public var isMarqueeSelecting: Bool = false
    @Published public var marqueeStart: CGPoint = .zero
    @Published public var marqueeEnd: CGPoint = .zero
    
    public var marqueeRect: CGRect {
        CGRect(
            x: min(marqueeStart.x, marqueeEnd.x),
            y: min(marqueeStart.y, marqueeEnd.y),
            width: abs(marqueeEnd.x - marqueeStart.x),
            height: abs(marqueeEnd.y - marqueeStart.y)
        )
    }
    
    public init() {}
    
    // MARK: - Track Selection
    
    public func selectTrack(_ id: TrackID, addToSelection: Bool = false) {
        if addToSelection {
            selectedTrackIDs.insert(id)
        } else {
            selectedTrackIDs = [id]
        }
    }
    
    public func deselectTrack(_ id: TrackID) {
        selectedTrackIDs.remove(id)
    }
    
    public func toggleTrackSelection(_ id: TrackID) {
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
        } else {
            selectedTrackIDs.insert(id)
        }
    }
    
    // MARK: - Clip Selection
    
    public func selectClip(_ id: ClipID, addToSelection: Bool = false) {
        if addToSelection {
            selectedClipIDs.insert(id)
        } else {
            selectedClipIDs = [id]
        }
    }
    
    public func deselectClip(_ id: ClipID) {
        selectedClipIDs.remove(id)
    }
    
    public func selectClips(_ ids: [ClipID], addToSelection: Bool = false) {
        if addToSelection {
            selectedClipIDs.formUnion(ids)
        } else {
            selectedClipIDs = Set(ids)
        }
    }
    
    // MARK: - Note Selection
    
    public func selectNote(_ id: UUID, addToSelection: Bool = false) {
        if addToSelection {
            selectedNoteIDs.insert(id)
        } else {
            selectedNoteIDs = [id]
        }
    }
    
    public func selectNotes(_ ids: [UUID], addToSelection: Bool = false) {
        if addToSelection {
            selectedNoteIDs.formUnion(ids)
        } else {
            selectedNoteIDs = Set(ids)
        }
    }
    
    // MARK: - Clear Selection
    
    public func clearAllSelections() {
        selectedTrackIDs.removeAll()
        selectedClipIDs.removeAll()
        selectedNoteIDs.removeAll()
        selectedAutomationPointIDs.removeAll()
    }
    
    public func clearClipSelection() {
        selectedClipIDs.removeAll()
    }
    
    public func clearNoteSelection() {
        selectedNoteIDs.removeAll()
    }
    
    // MARK: - Marquee Selection
    
    public func startMarqueeSelection(at point: CGPoint) {
        isMarqueeSelecting = true
        marqueeStart = point
        marqueeEnd = point
    }
    
    public func updateMarqueeSelection(to point: CGPoint) {
        marqueeEnd = point
    }
    
    public func endMarqueeSelection() {
        isMarqueeSelecting = false
    }
}

// MARK: - Marquee Selection View

public struct MarqueeSelectionOverlay: View {
    @ObservedObject var selectionManager: SelectionManager
    
    public init(selectionManager: SelectionManager) {
        self.selectionManager = selectionManager
    }
    
    public var body: some View {
        if selectionManager.isMarqueeSelecting {
            Rectangle()
                .fill(Color.accentColor.opacity(0.1))
                .overlay(
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 1)
                )
                .frame(
                    width: selectionManager.marqueeRect.width,
                    height: selectionManager.marqueeRect.height
                )
                .position(
                    x: selectionManager.marqueeRect.midX,
                    y: selectionManager.marqueeRect.midY
                )
        }
    }
}
