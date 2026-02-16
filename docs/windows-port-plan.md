# Musio Create Windows Port Plan (Milestone: windows-morning-build)

## Objective for this milestone

Deliver by morning a GitHub-hosted Windows download that can be launched, while preserving macOS behavior and documenting parity gaps honestly.

## What shipped in this milestone

1. **Milestone branch:** `windows-morning-build`
2. **Launchable Windows artifact path:**
   - Added `WindowsPreview/` .NET project producing `MusioCreatePreview.exe`.
   - This is a preview launcher milestone executable (criterion B), not full DAW parity.
3. **Windows CI artifacts on GitHub Actions:**
   - Workflow: `.github/workflows/windows-preview-build.yml`
   - Runner: `windows-latest`
   - Output artifact: `MusioCreate-WindowsPreview-win-x64.zip`
4. **Documentation:**
   - Updated `docs/windows-port-plan.md`
   - Updated `docs/windows-parity-matrix.md`
   - Added `docs/windows-build-and-run.md`
5. **Core Windows-capability scaffolding increment (post-preview):**
   - Expanded `DAWCore/Platform/PlatformCapabilities.swift` with explicit plugin-format and audio-backend abstractions (`PluginFormat`, `AudioBackend`).
   - Added runtime capability reporting (`supportedPluginFormats`, `preferredPluginFormat`, `defaultAudioBackend`, `runtimeSummary`) with Windows-first defaults (`VST3` + `WASAPI`) while preserving existing macOS behavior (`AudioUnit` + `CoreAudio`).
   - Updated `PluginHost.scanForPlugins()` to gate AU scanning through the centralized capability layer and log the runtime summary when AU scanning is unavailable.

## Why this is the strongest realistic overnight path

A full SwiftUI + audio + plugin-host Windows DAW binary is not realistically completable in one overnight sprint from the current Apple-framework-coupled codebase. This milestone therefore:

- ships a **real, launchable Windows executable** immediately,
- establishes **repeatable CI-based Windows distribution**, and
- keeps parity work honest and incremental.

## Next implementation phases (toward criterion A)

### Phase 1: Core compile portability
- ✅ Added centralized runtime capability scaffolding for plugin/audio backend selection (`PlatformCapabilities`).
- Isolate Apple-only DAWCore files behind platform gates.
- Introduce portable interfaces for audio, MIDI, plugin lifecycle.
- Get a Windows-compiling shared core slice in CI.

### Phase 2: Windows DAW shell bring-up
- Implement first Windows app shell (WinUI/WPF/Avalonia or equivalent) that hosts project load/save + basic transport.
- Keep project format compatibility with macOS.

### Phase 3: Audio backend
- Implement WASAPI baseline backend.
- Add latency/buffer controls and deterministic transport timing.

### Phase 4: Plugin hosting parity
- Extend VST3 path for Windows discovery/load/unload.
- Add native plugin editor host window embedding.

### Phase 5: User-facing parity hardening
- Timeline/mixer/piano-roll behavior parity checks.
- AI assistant parity validation on Windows runtime.
- Installer/signing/update channel for beta users.

## Guardrails followed

- No secrets added to repository.
- No fake capability claims.
- macOS behavior preserved as-is in existing Swift targets.
