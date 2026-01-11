import XCTest
@testable import DAWCore

final class DAWCoreTests: XCTestCase {
    
    // MARK: - Time Position Tests
    
    func testTimePositionConversion() {
        let position = TimePosition(beats: 4, tempo: 120, sampleRate: 44100)
        
        // 4 beats at 120 BPM = 2 seconds
        XCTAssertEqual(position.seconds, 2.0, accuracy: 0.001)
        
        // Verify sample count
        XCTAssertEqual(position.samples, 88200)
    }
    
    func testTimePositionFormatting() {
        let position = TimePosition(beats: 5.5, tempo: 120, sampleRate: 44100)
        let formatted = position.formatted(atTempo: 120, timeSignature: .common)
        
        // 5.5 beats = bar 2, beat 2 (0-indexed internally becomes 1-indexed in display)
        XCTAssertTrue(formatted.contains("2."))
    }
    
    func testTimeRangeOverlap() {
        let range1 = TimeRange(
            start: TimePosition(beats: 0, tempo: 120),
            duration: TimePosition(beats: 4, tempo: 120)
        )
        
        let range2 = TimeRange(
            start: TimePosition(beats: 2, tempo: 120),
            duration: TimePosition(beats: 4, tempo: 120)
        )
        
        let range3 = TimeRange(
            start: TimePosition(beats: 5, tempo: 120),
            duration: TimePosition(beats: 2, tempo: 120)
        )
        
        XCTAssertTrue(range1.overlaps(range2))
        XCTAssertFalse(range1.overlaps(range3))
    }
    
    // MARK: - Track Tests
    
    func testTrackCreation() {
        let track = Track(name: "Test Track", type: .midi, color: .blue)
        
        XCTAssertEqual(track.name, "Test Track")
        XCTAssertEqual(track.type, .midi)
        XCTAssertFalse(track.isMuted)
        XCTAssertFalse(track.isSolo)
        XCTAssertEqual(track.clips.count, 0)
    }
    
    func testTrackVolumeConversion() {
        var track = Track(name: "Test", type: .audio)
        
        // Set to -6 dB
        track.volumeDB = -6.0
        
        // Linear should be approximately 0.5
        XCTAssertEqual(track.volume, 0.501, accuracy: 0.01)
        
        // Verify round-trip
        XCTAssertEqual(track.volumeDB, -6.0, accuracy: 0.1)
    }
    
    // MARK: - MIDI Event Tests
    
    func testMIDINoteCreation() {
        let note = MIDIEvent.note(at: 1.0, pitch: 60, velocity: 100, duration: 0.5)
        
        XCTAssertEqual(note.beatPosition, 1.0)
        
        if case .note(let data) = note.type {
            XCTAssertEqual(data.pitch, 60)
            XCTAssertEqual(data.velocity, 100)
            XCTAssertEqual(data.duration, 0.5)
            XCTAssertEqual(data.noteName, "C4")
        } else {
            XCTFail("Expected note event")
        }
    }
    
    func testMIDINoteNameParsing() {
        XCTAssertEqual(NoteData.pitch(from: "C4"), 60)
        XCTAssertEqual(NoteData.pitch(from: "A4"), 69)
        XCTAssertEqual(NoteData.pitch(from: "C-1"), 0)
        XCTAssertEqual(NoteData.pitch(from: "G9"), 127)
    }
    
    func testMIDIScale() {
        let cMajor = MIDIScale.major
        
        // C4 (60) in C major
        XCTAssertTrue(cMajor.contains(pitch: 60, root: 60))  // C
        XCTAssertTrue(cMajor.contains(pitch: 64, root: 60))  // E
        XCTAssertTrue(cMajor.contains(pitch: 67, root: 60))  // G
        XCTAssertFalse(cMajor.contains(pitch: 61, root: 60)) // C#
    }
    
    // MARK: - Project Tests
    
    func testProjectCreation() {
        let project = ProjectFactory.createNewProject(name: "Test Project")
        
        XCTAssertEqual(project.name, "Test Project")
        XCTAssertEqual(project.tempo.bpm, 120)
        XCTAssertEqual(project.timeSignature, .common)
        XCTAssertEqual(project.tracks.count, 2)  // Default audio + MIDI tracks
    }
    
    func testProjectTrackManagement() {
        var project = Project(name: "Test")
        
        let track1 = Track(name: "Track 1", type: .audio)
        let track2 = Track(name: "Track 2", type: .midi)
        
        project.addTrack(track1)
        project.addTrack(track2)
        
        XCTAssertEqual(project.tracks.count, 2)
        
        project.removeTrack(id: track1.id)
        XCTAssertEqual(project.tracks.count, 1)
        XCTAssertEqual(project.tracks.first?.id, track2.id)
    }
    
    // MARK: - Automation Tests
    
    func testAutomationInterpolation() {
        var lane = AutomationLane(parameter: .volume)
        
        lane.setPoint(at: 0, value: 0.0)
        lane.setPoint(at: 4, value: 1.0)
        
        // Test linear interpolation
        XCTAssertEqual(lane.value(atBeat: 0), 0.0, accuracy: 0.001)
        XCTAssertEqual(lane.value(atBeat: 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(lane.value(atBeat: 4), 1.0, accuracy: 0.001)
    }
    
    // MARK: - Clip Tests
    
    func testMIDIClipData() {
        var midiData = MIDIClipData()
        
        midiData.events = [
            .note(at: 0, pitch: 60, velocity: 100, duration: 0.5),
            .note(at: 0.5, pitch: 62, velocity: 90, duration: 0.5),
            .note(at: 1, pitch: 64, velocity: 80, duration: 1.0),
        ]
        
        XCTAssertEqual(midiData.noteEvents.count, 3)
        XCTAssertEqual(midiData.sortedEvents.first?.beatPosition, 0)
    }
    
    // MARK: - Quantization Tests
    
    func testQuantization() {
        let beat = 1.7
        
        let quantizedNearest = TimeUtilities.quantize(beats: beat, gridDivision: 0.5, mode: .nearest)
        XCTAssertEqual(quantizedNearest, 1.5, accuracy: 0.001)
        
        let quantizedFloor = TimeUtilities.quantize(beats: beat, gridDivision: 0.5, mode: .floor)
        XCTAssertEqual(quantizedFloor, 1.5, accuracy: 0.001)
        
        let quantizedCeil = TimeUtilities.quantize(beats: beat, gridDivision: 0.5, mode: .ceil)
        XCTAssertEqual(quantizedCeil, 2.0, accuracy: 0.001)
    }
}
