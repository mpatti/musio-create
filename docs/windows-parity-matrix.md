# Windows Parity Matrix (vs current macOS app)

Status legend: `Done` | `In Progress` | `Planned` | `Blocked`

| Area | Current macOS state | Windows target | Primary blocker | Status |
|---|---|---|---|---|
| App packaging & launch | SPM/Xcode launch on macOS 14+ | Windows executable + installer flow | Packaging/signing pipeline not defined | Planned |
| Core project model | Implemented in shared DAWCore models | Reuse shared model unchanged | Validation on Windows runtime not yet done | Planned |
| Project persistence | Save/load project data implemented | Same format and compatibility | Cross-platform file path/permission audit pending | Planned |
| Transport controls | Play/stop/record/loop/metronome implemented | Equivalent behavior and timing | Backend timing source differs on Windows | Planned |
| Audio backend | CoreAudio backend integrated | WASAPI baseline (ASIO optional) | No Windows backend implementation yet | Blocked |
| Audio recording | Implemented with current engine paths | Equivalent capture/monitoring | Depends on Windows backend + device I/O path | Blocked |
| MIDI input/record | MIDI manager + sequencer present | Equivalent MIDI device support | Platform MIDI API bridge required | Blocked |
| Timeline editing | SwiftUI timeline and clip workflows active | Same editing semantics | Needs Windows validation and interaction QA | Planned |
| Piano roll editing | Implemented (advanced + track-level views) | Same tools and note edit behavior | Needs Windows input/scroll behavior tuning | Planned |
| Mixer workflows | Mixer/track controls implemented | Equivalent routing/control behavior | Audio backend + plugin lifecycle dependencies | Planned |
| Plugin discovery | AudioUnit scan/load on macOS | VST3 discovery/load on Windows | AudioUnit path is Apple-only; Windows host path unfinished | Blocked |
| Plugin window UI | AppKit/CoreAudioKit plugin editor windows | Native Windows plugin editor hosting | AppKit-only implementation today | Blocked |
| Plugin parameter fallback UI | Generic parameter UI exists | Reuse generic UI where possible | Plugin lifecycle/parameter mapping on Windows incomplete | Planned |
| Live waveform view | NSView/AppKit-accelerated rendering | Windows-compatible renderer | AppKit-only rendering path | In Progress |
| Authentication UI | SwiftUI auth with Apple/email paths | SwiftUI auth with platform-appropriate options | Apple Sign-In path is platform-specific | In Progress |
| AI assistant integration | Implemented with Supabase/Claude service path | Same assistant outcome | Needs full Windows app runtime + QA | Planned |
| Offline bounce/export | Offline bounce path present in CoreAudio module | Equivalent export workflow | CoreAudio-specific rendering path | Blocked |
| Tests (unit) | DAWCore tests runnable on macOS | Tests run in Windows CI | CI matrix and platform-safe tests not set | Planned |
| Release quality gates | Manual local testing today | Repeatable cross-platform QA checklist | No Windows test plan automation yet | Planned |

## Foundation updates made in this branch

- Added capability-gating and explicit TODO stubs for AppKit-only plugin/window and waveform surfaces.
- Added centralized platform capability flags in DAWCore for staged backend separation.
- Preserved current macOS behavior; no fake Windows runtime implementation introduced.
