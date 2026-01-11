# DAW SwiftUI

A professional-grade Digital Audio Workstation built with Swift and SwiftUI for macOS 14+.

## Architecture

```
DAWSwiftUI/
├── Package.swift              # Swift Package Manager manifest
├── DAWCore/                   # Core audio/MIDI engine (no UI dependencies)
│   └── Sources/DAWCore/
│       ├── Models/            # Track, Clip, MIDIEvent, AutomationLane
│       ├── Audio/             # AVAudioEngine wrapper, track routing
│       ├── MIDI/              # CoreMIDI, sequencer, scheduling
│       ├── Plugins/           # AUv3 host, plugin parameter management
│       ├── Transport/         # Playback state, tempo, time signatures
│       ├── Timeline/          # Timeline data structures, beat/time conversion
│       ├── Undo/              # Undo/redo system
│       ├── Persistence/       # Project save/load
│       └── Utilities/         # Shared utilities
├── DAWUI/                     # SwiftUI views and view models
│   └── Sources/DAWUI/
│       ├── Views/
│       │   ├── Timeline/      # Multi-track timeline view
│       │   ├── PianoRoll/     # MIDI piano roll editor
│       │   ├── Mixer/         # Mixing console
│       │   ├── Inspector/     # Track/plugin inspector
│       │   ├── Transport/     # Transport controls
│       │   └── Shared/        # Reusable components
│       ├── ViewModels/        # View models for state management
│       └── MetalRendering/    # Metal shaders for high-perf rendering
├── VST3Bridge/                # C++ bridge for VST3 plugin hosting
│   └── Sources/
│       ├── VST3Bridge/        # Swift wrapper
│       └── VST3BridgeCpp/     # C++ implementation
│           ├── include/       # Public C headers
│           └── src/           # C++ implementation
└── DAWApp/                    # Main application target
    ├── Sources/DAWApp/        # App entry point
    └── Resources/             # Assets, entitlements
```

## Requirements

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

## Building

```bash
swift build
swift run DAWApp
```

Or open in Xcode:
```bash
open Package.swift
```

## Entitlements Required

The following entitlements are needed for full functionality:

```xml
<!-- For Audio Unit hosting -->
<key>com.apple.security.app-sandbox</key>
<true/>

<!-- Audio input access -->
<key>com.apple.security.device.audio-input</key>
<true/>

<!-- For loading external plugins -->
<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
<array>
    <string>com.apple.audio.audiohald</string>
</array>

<!-- File access for loading audio files -->
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

## Key Features

- **Multi-track Timeline**: Audio and MIDI tracks with clip-based editing
- **Piano Roll Editor**: Full-featured MIDI note editor with velocity editing
- **Audio Engine**: Built on AVAudioEngine with per-track plugin chains
- **Plugin Hosting**: AUv3 (native) and VST3 (via C++ bridge)
- **Automation**: Per-track automation lanes for volume, pan, and plugin parameters
- **Transport**: Play, stop, record, loop, with tempo and time signature support
- **Undo/Redo**: Full undo support for all editing operations
- **Project Persistence**: JSON-based project format with versioning

## License

MIT License
