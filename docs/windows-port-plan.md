# Musio Create Windows Port Plan (Foundation)

> Scope: serious foundation toward feature parity with current macOS app. This document does **not** claim Windows support today.

## 1) Goals and Non-Goals

### Goals
- Reach functional parity with the core macOS music-creation workflow:
  - project create/open/save
  - transport, timeline, recording, MIDI editing
  - mixer + plugin insert workflows
  - AI assistant workflows
- Preserve architecture quality while introducing cross-platform seams.
- Keep macOS behavior stable while Windows work proceeds incrementally.

### Non-Goals (this phase)
- Shipping a production-ready Windows build now.
- Emulating macOS-only APIs on Windows.
- Rewriting the app in another framework.

## 2) Current Architecture Summary (macOS)

- **DAWCore**
  - audio engine, transport, MIDI, persistence, plugin host logic
  - strongly tied to Apple audio stack in several paths (AudioToolbox/CoreAudio/AVFoundation integration)
- **DAWUI**
  - SwiftUI app UI
  - AppKit bridges for plugin windows and waveform NSView rendering
- **VST3Bridge**
  - C++ bridge layer already a useful anchor for cross-platform plugin hosting
- **DAWApp**
  - app entry and macOS packaging/runtime assumptions

## 3) Target Windows Architecture

### Platform layering strategy
- Keep shared domain/editor logic in `DAWCore` + portable SwiftUI where possible.
- Introduce explicit platform capability boundaries:
  - audio backend boundary
  - plugin UI host boundary
  - platform image/window wrappers in UI
- Maintain `CoreAudioBackend` on macOS; add `WASAPI`/`ASIO` backend path for Windows (behind protocol/factory).

### Proposed backend map
- **macOS**: CoreAudio/AudioUnit + existing AppKit integrations
- **Windows**:
  - audio I/O: WASAPI first, ASIO optional/phase-2
  - plugins: VST3 host path (existing bridge extended)
  - plugin GUI host: Win32/COM window embedding facade

## 4) Feature Parity Definition

Parity target means a Windows user can:
1. install/run app, create/save/reopen project
2. record and edit MIDI/audio with low-latency monitoring
3. load/bypass/remove plugins per track
4. mix with stable playback/render behavior
5. use AI assistant features with equivalent outcomes

## 5) Milestones

### Milestone A — Foundation (now)
- planning docs + parity matrix
- platform capability wrappers and guarded macOS-only surfaces
- non-breaking compile/runtime on macOS

### Milestone B — Build/Runtime Bring-Up (Windows)
- package manifests and CI matrix for Windows
- first successful Windows compile with stubs where needed
- app launches to basic shell UI

### Milestone C — Audio Engine Bring-Up
- Windows backend implementation (WASAPI baseline)
- transport clocking parity + buffer/latency controls
- smoke tests for playback/recording

### Milestone D — Editing + Persistence Parity
- timeline/MIDI editing behavior validation
- project persistence compatibility checks
- undo/redo reliability checks

### Milestone E — Plugin Hosting Parity
- VST3 discovery/load/unload lifecycle on Windows
- plugin parameter automation path
- plugin editor window hosting stability

### Milestone F — AI + Productization
- AI assistant parity checks
- installer/signing/update strategy for Windows
- crash reporting + telemetry + beta rollout

## 6) Risks and Mitigations

- **Risk: Apple-framework coupling in shared code**
  - Mitigation: continue extracting platform seams + capability gates.
- **Risk: plugin GUI hosting complexity on Windows**
  - Mitigation: separate lifecycle host service; staged support and strict crash isolation.
- **Risk: audio latency/performance regressions**
  - Mitigation: benchmark harness per backend, configurable buffer profiles.
- **Risk: behavior drift from macOS**
  - Mitigation: parity matrix + targeted regression tests + golden projects.

## 7) Timeline Ranges (estimate)

- Foundation + compile bring-up: **2–4 weeks**
- Audio + editing parity baseline: **6–10 weeks**
- Plugin hosting and hardening: **6–12 weeks**
- Beta-ready Windows release candidate: **~4–7 months total**

Assumes focused part-time/small-team execution and no major third-party blocker.

## 8) Definition of Done for First Downloadable Windows Build

- Windows app launches and can create/save/reopen projects
- stable playback + basic recording
- basic MIDI editing
- at least one plugin format path functional (VST3)
- crash handling/logging and minimum installer UX
- explicit release notes documenting known gaps vs macOS
