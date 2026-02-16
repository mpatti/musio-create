# Musio Create Windows Build & Run

## What this milestone delivers

This branch produces a **downloadable, launchable Windows executable** as an overnight milestone artifact:

- Artifact name: `MusioCreate-WindowsPreview-win-x64.zip`
- Binary inside: `MusioCreatePreview.exe`
- Built on: GitHub Actions `windows-latest`

This is a **Windows preview launcher**, not full DAW parity yet.

## Download from GitHub Actions

1. Open the repository Actions page:
   - `https://github.com/mpatti/musio-create/actions`
2. Open the latest run of **Windows Preview Build** on branch `windows-morning-build`.
3. Download artifact: **MusioCreate-WindowsPreview-win-x64**.
4. Extract the ZIP.
5. Run `MusioCreatePreview.exe`.

## Local Windows build (optional)

Requirements:
- .NET 8 SDK

Commands (PowerShell):

```powershell
dotnet publish WindowsPreview/MusioCreate.WindowsPreview.csproj `
  -c Release `
  -r win-x64 `
  --self-contained true `
  /p:PublishSingleFile=true `
  /p:IncludeNativeLibrariesForSelfExtract=true `
  -o dist/windows-preview
```

Run:

```powershell
./dist/windows-preview/MusioCreatePreview.exe
```

## Current behavior in Windows artifact

- Launches as native Windows EXE
- Shows milestone status and capability boundaries
- Provides one-click links to repo, CI runs, and Windows docs

## Known gaps

- No SwiftUI DAW shell on Windows yet
- No WASAPI/ASIO engine path wired yet
- No Windows VST3 GUI hosting yet

## Why this shape

This milestone prioritizes a real downloadable and launchable Windows deliverable overnight while keeping the architecture honest (no fake parity claims). It also establishes repeatable Windows artifact generation in CI for each iteration.
