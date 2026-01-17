import Foundation
import AudioToolbox

// MARK: - MIDI Scheduler

/// Sample-accurate MIDI event scheduler
/// Events are added from the main thread and processed in the render callback
public final class MIDIScheduler {
    
    // MARK: - Properties
    
    /// Ring buffer for scheduled events
    private let eventBuffer: MIDIEventRingBuffer
    
    /// Active notes for tracking note-offs
    private var activeNotes: [(trackID: TrackID, pitch: UInt8, channel: UInt8, endSample: Int64)] = []
    private let maxActiveNotes = 256
    
    // MARK: - Initialization
    
    init(capacity: Int = 32768) {
        eventBuffer = MIDIEventRingBuffer(capacity: capacity)
        activeNotes.reserveCapacity(maxActiveNotes)
    }
    
    // MARK: - Scheduling (Main Thread)
    
    /// Schedule a MIDI event
    /// - Parameter event: The event to schedule
    /// - Note: Call from main thread only
    func schedule(_ event: ScheduledMIDIEvent) {
        eventBuffer.schedule(event)
    }
    
    /// Schedule multiple events (should be sorted by sample position)
    /// - Parameter events: Events to schedule
    /// - Note: Call from main thread only
    func schedule(contentsOf events: [ScheduledMIDIEvent]) {
        _ = eventBuffer.schedule(contentsOf: events)
    }
    
    /// Schedule a note with automatic note-off
    /// - Parameters:
    ///   - trackID: Target track
    ///   - pitch: MIDI note number
    ///   - velocity: Note velocity
    ///   - startSample: When to start the note
    ///   - durationSamples: Duration in samples
    ///   - channel: MIDI channel
    func scheduleNote(
        trackID: TrackID,
        pitch: UInt8,
        velocity: UInt8,
        startSample: Int64,
        durationSamples: Int64,
        channel: UInt8 = 0
    ) {
        // Schedule note-on
        let noteOn = ScheduledMIDIEvent.noteOn(
            trackID: trackID,
            samplePosition: startSample,
            note: pitch,
            velocity: velocity,
            channel: channel
        )
        schedule(noteOn)
        
        // Schedule note-off
        let noteOff = ScheduledMIDIEvent.noteOff(
            trackID: trackID,
            samplePosition: startSample + durationSamples,
            note: pitch,
            channel: channel
        )
        schedule(noteOff)
    }
    
    /// Clear all scheduled events
    func clear() {
        eventBuffer.clear()
        activeNotes.removeAll(keepingCapacity: true)
    }
    
    // MARK: - Processing (Audio Thread)
    
    /// Process events for the current buffer
    /// - Parameters:
    ///   - startSample: Start of buffer in samples
    ///   - endSample: End of buffer in samples
    ///   - renderGraph: The render graph to send MIDI to
    /// - Returns: Number of events processed
    /// - Note: Called from audio thread - MUST be realtime safe
    @discardableResult
    func processEvents(
        startSample: Int64,
        endSample: Int64,
        renderGraph: RenderGraph
    ) -> Int {
        var processed = 0
        
        // Process events from the ring buffer
        while let event = eventBuffer.peekIfInRange(startSample: startSample, endSample: endSample) {
            // Calculate sample offset within this buffer
            let sampleOffset = UInt32(max(0, event.samplePosition - startSample))
            
            // Send the MIDI event
            renderGraph.sendMIDI(
                to: event.trackID,
                status: event.status,
                data1: event.data1,
                data2: event.data2,
                sampleOffset: sampleOffset
            )
            
            // Track note-on for later note-off
            if isNoteOn(event.status) {
                trackNoteOn(event)
            }
            
            eventBuffer.pop()
            processed += 1
        }
        
        return processed
    }
    
    // MARK: - Note Tracking
    
    private func isNoteOn(_ status: UInt8) -> Bool {
        (status & 0xF0) == 0x90
    }
    
    private func isNoteOff(_ status: UInt8) -> Bool {
        (status & 0xF0) == 0x80
    }
    
    private func trackNoteOn(_ event: ScheduledMIDIEvent) {
        // Note tracking for sustain, etc. could be added here
        // For now, note-offs are scheduled explicitly
    }
    
    // MARK: - Query
    
    var isEmpty: Bool {
        eventBuffer.isEmpty
    }
    
    var eventCount: Int {
        eventBuffer.count
    }
}

// MARK: - MIDI Event Helpers

extension ScheduledMIDIEvent {
    /// Check if this is a note-on event
    var isNoteOn: Bool {
        (status & 0xF0) == 0x90 && data2 > 0
    }
    
    /// Check if this is a note-off event
    var isNoteOff: Bool {
        (status & 0xF0) == 0x80 || ((status & 0xF0) == 0x90 && data2 == 0)
    }
    
    /// Check if this is a control change
    var isControlChange: Bool {
        (status & 0xF0) == 0xB0
    }
    
    /// Get the MIDI channel (0-15)
    var midiChannel: UInt8 {
        status & 0x0F
    }
    
    /// Get the note number (for note events)
    var noteNumber: UInt8 {
        data1
    }
    
    /// Get the velocity (for note events)
    var velocity: UInt8 {
        data2
    }
}
