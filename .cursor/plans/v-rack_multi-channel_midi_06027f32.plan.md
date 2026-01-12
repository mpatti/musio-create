---
name: V-Rack Multi-Channel MIDI
overview: Implement a V-Rack style system for hosting multi-timbral instruments, allowing up to 16 MIDI tracks to route to different channels of a single rack instrument.
todos:
  - id: model-vrack
    content: Create VRack.swift with RackInstrument and VRack structs
    status: completed
  - id: model-track
    content: Add MIDIOutputDestination enum and midiOutput property to Track
    status: completed
  - id: model-project
    content: Add vRack property to Project
    status: completed
  - id: engine-rack
    content: Add rack instrument loading/management to PlaybackEngine
    status: completed
  - id: engine-routing
    content: Update MIDI routing to support rack destinations with channels
    status: completed
  - id: ui-vrack
    content: Create VRackView sidebar panel
    status: completed
  - id: ui-header
    content: Add MIDI output selector to track header
    status: completed
  - id: ui-inspector
    content: Add MIDI output section to Inspector
    status: completed
  - id: ui-layout
    content: Add V-Rack sidebar toggle to main window
    status: completed
  - id: vm-rack
    content: Add rack management methods to ProjectViewModel
    status: completed
---

# V-Rack Multi-Channel MIDI Instrument Hosting

## Architecture Overview

```mermaid
flowchart TB
    subgraph VRack [V-Rack Sidebar]
        RI1[Rack Instrument 1<br/>e.g. Kontakt]
        RI2[Rack Instrument 2<br/>e.g. Omnisphere]
    end
    
    subgraph Tracks [MIDI Tracks]
        T1[MIDI Track 1<br/>Output: RI1 Ch 1]
        T2[MIDI Track 2<br/>Output: RI1 Ch 2]
        T3[MIDI Track 3<br/>Output: RI1 Ch 10]
        T4[MIDI Track 4<br/>Output: RI2 Ch 1]
    end
    
    T1 -->|Ch 1| RI1
    T2 -->|Ch 2| RI1
    T3 -->|Ch 10| RI1
    T4 -->|Ch 1| RI2
    
    RI1 --> Master[Master Output]
    RI2 --> Master
```

## Data Model Changes

### 1. New V-Rack Model

Create [DAWCore/Sources/DAWCore/Models/VRack.swift](DAWCore/Sources/DAWCore/Models/VRack.swift):

```swift
public struct RackInstrument: Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var pluginSlot: PluginSlot
    public var volume: Float
    public var isMuted: Bool
}

public struct VRack: Codable {
    public var instruments: [RackInstrument]
}
```

### 2. Update Track Model

Modify [DAWCore/Sources/DAWCore/Models/Track.swift](DAWCore/Sources/DAWCore/Models/Track.swift):

```swift
// Add to Track struct:
public var midiOutput: MIDIOutputDestination?

public enum MIDIOutputDestination: Codable {
    case trackInstrument           // Use track's own instrument slot
    case rackInstrument(id: UUID, channel: UInt8)  // Route to V-Rack
}
```

### 3. Update Project Model

Add V-Rack to [DAWCore/Sources/DAWCore/Models/Project.swift](DAWCore/Sources/DAWCore/Models/Project.swift):

```swift
public var vRack: VRack = VRack(instruments: [])
```

## Audio Engine Changes

### 4. PlaybackEngine Updates

Modify [DAWCore/Sources/DAWCore/Audio/PlaybackEngine.swift](DAWCore/Sources/DAWCore/Audio/PlaybackEngine.swift):

- Add `rackInstruments: [UUID: TrackInstrument]` dictionary
- Add `loadRackInstrument(_:pluginID:)` method
- Add `removeRackInstrument(_:)` method
- Update `sendMIDIToTrack()` to check `midiOutput` destination and route accordingly
- Route to rack instrument on specified channel (1-16)

## UI Components

### 5. V-Rack Sidebar Panel

Create [DAWUI/Sources/DAWUI/Views/VRack/VRackView.swift](DAWUI/Sources/DAWUI/Views/VRack/VRackView.swift):

- List of rack instruments with:
  - Instrument name and plugin
  - Add/remove buttons
  - Volume/mute controls
  - Click to open plugin UI
- "+" button to add new rack instrument
- Plugin browser integration

### 6. Track Header MIDI Output Selector

Update [DAWUI/Sources/DAWUI/Views/Timeline/TrackHeaderView.swift](DAWUI/Sources/DAWUI/Views/Timeline/TrackHeaderView.swift):

- Add compact dropdown showing current output (e.g., "Kontakt Ch 1")
- Menu with:
  - "Track Instrument" option (default)
  - List of rack instruments, each with submenu for channels 1-16

### 7. Inspector MIDI Output Section

Update Inspector in [DAWUI/Sources/DAWUI/Views/MainWindowView.swift](DAWUI/Sources/DAWUI/Views/MainWindowView.swift):

- Add "MIDI Output" section for MIDI/instrument tracks
- Dropdown for destination selection
- Channel picker (1-16)

### 8. Main Window Layout

Update [DAWUI/Sources/DAWUI/Views/MainWindowView.swift](DAWUI/Sources/DAWUI/Views/MainWindowView.swift):

- Add V-Rack sidebar panel (collapsible)
- Toggle button in toolbar to show/hide V-Rack

## ViewModel Updates

### 9. ProjectViewModel

Update [DAWUI/Sources/DAWUI/ViewModels/ProjectViewModel.swift](DAWUI/Sources/DAWUI/ViewModels/ProjectViewModel.swift):

- Add rack instrument management methods:
  - `addRackInstrument()`
  - `removeRackInstrument(_:)`
  - `loadRackInstrumentPlugin(_:pluginID:)`
- Update `routeMIDIToInstrument()` to handle rack routing
- Update playback preparation to load rack instruments

## MIDI Routing Flow

```mermaid
sequenceDiagram
    participant MIDI as MIDI Input
    participant VM as ProjectViewModel
    participant Track as MIDI Track
    participant PE as PlaybackEngine
    participant Rack as Rack Instrument
    
    MIDI->>VM: MIDI Event
    VM->>Track: Check midiOutput
    alt Track Instrument
        VM->>PE: sendMIDI(trackID, ch:0)
        PE->>Track: Play on track instrument
    else Rack Instrument
        VM->>PE: sendMIDI(rackID, ch:N)
        PE->>Rack: Play on channel N
    end
```

## File Summary

| File | Action |

|------|--------|

| `DAWCore/.../Models/VRack.swift` | Create |

| `DAWCore/.../Models/Track.swift` | Modify |

| `DAWCore/.../Models/Project.swift` | Modify |

| `DAWCore/.../Audio/PlaybackEngine.swift` | Modify |

| `DAWUI/.../Views/VRack/VRackView.swift` | Create |

| `DAWUI/.../Views/Timeline/TrackHeaderView.swift` | Modify |

| `DAWUI/.../Views/MainWindowView.swift` | Modify |

| `DAWUI/.../ViewModels/ProjectViewModel.swift` | Modify |