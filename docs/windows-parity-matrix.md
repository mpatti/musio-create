# Windows Parity Matrix (vs current macOS app)

Status legend: `Done` | `In Progress` | `Planned` | `Blocked`

| Area | Current macOS state | Windows target | Current Windows milestone state | Status |
|---|---|---|---|---|
| App packaging & launch | SPM/Xcode launch on macOS 14+ | Downloadable Windows artifact and launch path | GitHub Actions now produces downloadable `MusioCreatePreview.exe` ZIP artifact | Done |
| CI artifact pipeline | Manual/mac-focused before | Repeatable Windows runner build | `windows-preview-build.yml` on `windows-latest` with artifact upload | Done |
| Core project model | Implemented in shared DAWCore models | Reuse shared model on Windows runtime | Shared model not yet compiled/validated on Windows due Apple-framework coupling | In Progress |
| Project persistence | Save/load implemented | Same format compatibility | Windows runtime integration not started | Planned |
| Transport controls | Implemented | Equivalent behavior | Not in preview executable yet | Planned |
| Audio backend | CoreAudio/AVAudioEngine paths | WASAPI baseline (ASIO optional) | Not implemented yet | Blocked |
| Audio recording | Implemented | Equivalent capture/monitoring | Depends on Windows audio backend | Blocked |
| MIDI input/record | Implemented | Equivalent MIDI support | CoreMIDI compile-time coupling isolated via fallback shim; Windows runtime backend still pending | In Progress |
| Timeline editing | Implemented | Same editing semantics | Not in preview executable yet | Planned |
| Piano roll editing | Implemented | Same behavior | Not in preview executable yet | Planned |
| Mixer workflows | Implemented | Equivalent routing/control | Depends on backend + host layers | Planned |
| Plugin discovery/load | AU + existing paths | VST3-first on Windows | Runtime host still pending, but DAWCore preset API is now AU-type-decoupled via `PluginFactoryPreset` | In Progress |
| Plugin window UI | AppKit/CoreAudioKit driven | Native Windows plugin hosting | Not implemented yet | Blocked |
| Authentication UI | SwiftUI auth paths | Cross-platform auth UX | Windows app shell not integrated yet | Planned |
| AI assistant integration | Implemented with Supabase/Claude path | Equivalent outcomes | Runtime integration pending Windows shell | Planned |
| Tests in CI | macOS Swift tests | Add Windows-targeted tests as runtime lands | Not yet | Planned |

## Foundation updates in this milestone

- Added a **launchable Windows preview executable** project at `WindowsPreview/`.
- Added **GitHub Actions Windows artifact pipeline** at `.github/workflows/windows-preview-build.yml`.
- Added `docs/windows-build-and-run.md` with concrete download/run instructions.
- Isolated `DAWCore` CoreMIDI dependency behind conditional compilation and added `MIDIManager+PlatformFallback.swift` to keep non-Apple builds moving while Windows MIDI backend work is implemented.
- Decoupled DAWCore plugin preset APIs from Apple `AUAudioUnitPreset` by introducing `PluginFactoryPreset` in `PluginHost`, with explicit Windows TODOs for VST3 preset/program mapping.

This milestone is intentionally transparent: it ships a real Windows executable and CI distribution path without misrepresenting DAW feature parity.
