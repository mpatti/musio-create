# Musio Create

Musio Create is a macOS DAW built with Swift + SwiftUI.

The goal is simple: fast music ideas, clean UI, and modern AI-assisted workflows without feeling bloated.

---

## What you can do right now

- Build and run the app from Swift Package Manager
- Create audio and MIDI tracks
- Use transport controls (play/stop/record/loop/metronome)
- Edit MIDI in the piano roll
- Work with mixer/inspector-style views
- Save and load project data
- Use built-in AI assistant flows (when configured)

---

## Quick start

### Requirements

- macOS 14+
- Xcode 15+
- Swift 5.9+

### Run from terminal

```bash
swift build
swift run DAWApp
```

### Run in Xcode

```bash
open Package.swift
```

---

## Project structure (plain English)

```text
Musio Create/
├── Package.swift
├── DAWCore/      # Audio/MIDI engine, models, transport, persistence, AI services
├── DAWUI/        # SwiftUI views + view models
├── VST3Bridge/   # Swift/C++ bridge for VST3 hosting
├── DAWApp/       # App entry point + app resources
└── Tests/        # Unit tests
```

If you’re new to the codebase, start in:

- `DAWApp/Sources/DAWApp/DAWApp.swift` (app wiring + menus)
- `DAWUI/Sources/DAWUI/Views` (main UI)
- `DAWCore/Sources/DAWCore` (audio/MIDI internals)

---

## AI assistant setup (optional)

Musio Create supports Claude-based assistant features.

You can configure it either:

1. Through a Supabase edge proxy, or
2. With a local API key stored on your machine.

⚠️ **Do not commit API keys to git.**
Keys should live in local config/env/UserDefaults only.

---

## Notes on naming

The app is named **Musio Create**.
Some internal target names may still reference legacy DAW naming while refactors continue.

---

## Contributing

PRs are welcome. Keep changes focused, test before pushing, and avoid mixing refactors with behavior changes.

---

## License

MIT
