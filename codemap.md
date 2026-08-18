# codemap.md

Orientation map for agents. Read this before touching code; read `AGENTS.md` for hard rules, `README.md` for the feature/controls list. This file describes structure, not policy or features.

## 1. Architecture

Two deliverables, one surface underneath:

- **`obsbot` CLI** (`main.m`) — command-line control.
- **OBSBOT Control** (`gui/ObsbotApp.swift`) — SwiftUI/AppKit menu-bar agent app.

Both talk to the exact same two device APIs, independently (no shared library, no IPC between them):

- **UVC image controls** (zoom, focus, exposure, brightness, contrast, saturation, sharpness, gain, white balance) via the vendored **VVUVCKit** framework (`VVUVCController`), found by locating the OBSBOT on the USB bus through **IOKit** (vendor ID 13668 / product ID 65275) and opening a controller for its `locationID`.
- **Mic volume/mute** via **CoreAudio**, found by name-matching an input device whose name contains "OBSBOT".

The GUI's device-discovery and CoreAudio helper functions are a straight Swift port of the CLI's C functions (same logic, translated, not shared code — see section 5).

## 2. CLI structure (`main.m`, ~368 lines)

- `findOBSBOTLocationID()` — `main.m:12` — IOKit USB scan by VID/PID, falls back to name match.
- `ControlEntry` struct + `controls[9]` dispatch table — `main.m:62`, populated at runtime by `initControls()` at `main.m:77` (comment there explains why: `@selector()` isn't a compile-time constant, so no static initializer).
- `findControl(name)` — `main.m:90` — case-insensitive name lookup into the table.
- Generic Objective-C reflection helpers to call `VVUVCController` selectors without hardcoding each one: `callLong` (`main.m:99`), `callVoidLong` (`main.m:109`), `callBool` (`main.m:117`) — built on `NSInvocation`.
- CoreAudio helpers, ported almost verbatim into the GUI later: `findOBSBOTAudioDeviceID` (`main.m:128`), `audioHasProperty` (`main.m:160`), `audioGetVolume`/`audioSetVolume` (`main.m:165`, `173`), `audioGetMute`/`audioSetMute` (`main.m:178`, `186`).
- `main()` (`main.m:202`) — argument dispatch:
  - `get` (`main.m:224`) — prints every supported control + range + auto state, then mic volume/mute.
  - `reset` (`main.m:259`) — `resetParamsToDefaults`.
  - `set <name> <value|auto>` (`main.m:265`) — special-cased `micvolume` and `mic mute/unmute` before falling through to the generic control table; `auto` is handled per-control (focus/whitebalance/exposure each have different auto-mode selectors).
- Control set: zoom, focus, exposure, brightness, contrast, saturation, sharpness, gain, whitebalance. Ranges/auto-support: see `README.md` controls table — don't restate here.

## 3. GUI structure (`gui/ObsbotApp.swift`, ~1474 lines, one file)

Deliberately one file, one `ObservableObject` + one main view (see the ponytail comment at the top of the file). Sections, top to bottom:

- **Device discovery** (`gui/ObsbotApp.swift:17-138`) — `findOBSBOTLocationID`, `findOBSBOTProductName`, and the CoreAudio helpers (`findOBSBOTAudioDeviceID`, `audioHasProperty`, `audioGetVolume/SetVolume`, `audioGetMute/SetMute`). Ported from `main.m`'s C functions.
- **`CameraModel`** (`gui/ObsbotApp.swift:151-892`) — the entire app state, an `NSObject`/`ObservableObject`/`AVCaptureVideoDataOutputSampleBufferDelegate`. Key subsystems inside it:
  - **UVC control state**: `@Published zoom/exposure/whiteBalance/brightness` + their ranges + `autoMode`, backed by a `VVUVCController?` (`controller`, private). Setters: `setZoom`/`setExposure`/`setWhiteBalance`/`setBrightness`/`setAuto`/`reset` at `gui/ObsbotApp.swift:859-891`. `refresh()` (`gui/ObsbotApp.swift:783`) connects/reconnects and pulls live values; re-checks IOKit presence each call since a stale controller means the camera was unplugged.
  - **Mic state**: `@Published micAvailable/micVolume/micMuted/micLevel`, `audioDeviceID` — `gui/ObsbotApp.swift:167-181`. `refreshMic()` (`gui/ObsbotApp.swift:823`), `setMicVolume`/`setMicMuted` (`gui/ObsbotApp.swift:847-857`).
  - **Mic level meter**: a *separate* `AVCaptureSession` (`audioSession`) that taps the OBSBOT mic's audio channel and polls `averagePowerLevel` on a 20Hz timer (`startMicLevelMeter` / `pollMicLevel`, `gui/ObsbotApp.swift:444-514`). Not the same session as camera preview or keep-alive.
  - **Live camera preview**: a third `AVCaptureSession` (`session`), `previewState` enum (`idle/starting/running/denied/inUse/unavailable`, `gui/ObsbotApp.swift:142`), lifecycle in `startPreview`/`stopPreview`/`attachPreviewLayer`/`applyPreviewMirror` (`gui/ObsbotApp.swift:308-428`). Ref-counted via `panelAppeared`/`panelDisappeared` (`gui/ObsbotApp.swift:259-274`) so the popover and the pinned floating window share one session.
  - **Keep-mic-live-during-calls** (the workaround for "OBSBOT mic is silent unless a video stream is open"): a *fourth* `AVCaptureSession` (`keepAliveSession`), output-less and preview-less, held open only while the toggle is on AND CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere` says another app is actually using the mic. Toggle property: `keepMicLiveDuringCalls` (`gui/ObsbotApp.swift:190`, persisted to `UserDefaults`). Setter: `setKeepMicLiveDuringCalls` (`gui/ObsbotApp.swift:545`). CoreAudio listener install/remove: `installMicRunningSomewhereListener`/`removeMicRunningSomewhereListener` (`gui/ObsbotApp.swift:576-616`) — note the comment about block-identity matching for listener removal. Session start/stop: `startKeepAliveSession...` / `stopKeepAliveSession` (`gui/ObsbotApp.swift:638-707`).
  - **Login item**: `launchAtLogin` (`gui/ObsbotApp.swift:198`), truth source is `SMAppService.mainApp.status`, *not* `UserDefaults` — re-read via `refreshLaunchAtLogin()` on `.onAppear` (matches the pattern noted in `AGENTS.md`). Setter `setLaunchAtLogin` (`gui/ObsbotApp.swift:561`) calls `SMAppService.mainApp.register()/unregister()`.
  - **Session lifecycle threading**: all four `AVCaptureSession`s' configuration mutations go through one private serial queue, `sessionQueue` (`gui/ObsbotApp.swift:229`), separate from `videoQueue` (frame delegate callbacks only). The comment there explains the crash this fixes (`NSFastEnumerationMutation` abort from configuring on main while `startRunning` enumerated on another thread).
  - **Pinned floating window**: `pinned`, `setPinned` (`gui/ObsbotApp.swift:720-766`) — builds a borderless floating `NSWindow` hosting the same `PanelView`, dismisses the `MenuBarExtra` popover when pinning.
  - **Escape-to-close**: local key monitor for keyCode 53, installed/removed alongside panel visibility (`gui/ObsbotApp.swift:276-306`).
- **Aperture visual tokens** (`gui/ObsbotApp.swift:894-917`) — `enum Aperture` (colors: `bgTop/bgBottom/text/value/label/fillStart/fillEnd/accent/knob/hairline/resetText`) + a `Color(hex:)` initializer. This is the single palette; any new UI must draw from these tokens, per `AGENTS.md`.
- **Reusable controls**: `ApertureToggleStyle` (`gui/ObsbotApp.swift:921`) — pill toggle, the required pattern for every settings toggle; `ApertureSlider` (`gui/ObsbotApp.swift:945`) — drag + step-button slider used for every numeric control; `MicLevelMeter` (`gui/ObsbotApp.swift:1041`).
- **`PreviewLayerView`** (`gui/ObsbotApp.swift:1079`) — `NSViewRepresentable` wrapping `AVCaptureVideoPreviewLayer`, mirrors the displayed (not captured) frame.
- **`PanelView`** (`gui/ObsbotApp.swift:1122-1379`) — the actual panel UI: preview area, header (device name + pin), the four `ApertureSlider`s (zoom/exposure/white balance/brightness), mic section (slider + mute button + level meter + keep-mic-live toggle, only shown if `micAvailable`), launch-at-login toggle, Auto/Reset buttons, and an always-present quit row (`quitRow`, `gui/ObsbotApp.swift:1343` — the only way to quit, since this is an `LSUIElement` app with no Dock menu).
- **`AppDelegate`** (`gui/ObsbotApp.swift:1387`) — handles `applicationShouldHandleReopen` so re-invoking from Spotlight/Raycast while already running surfaces the panel.
- **`ObsbotApp`** (`@main`, `gui/ObsbotApp.swift:1401`) — sets `.accessory` activation policy, constructs `CameraModel`, declares the `MenuBarExtra(.window)` scene. `#if DEBUG` block (`gui/ObsbotApp.swift:1412-1462`) wires headless env-var test hooks (`OBSBOT_PREVIEW_TEST`, `OBSBOT_PIN_TEST`, `OBSBOT_ESCAPE_TEST`, `OBSBOT_KEEPALIVE_TEST`, `OBSBOT_KEEPALIVE_RAPID_TEST`) — gated out of release builds.

**Adding a new settings toggle**: `@Published` model property + explicit setter method + `Toggle(...).toggleStyle(ApertureToggleStyle())` in `PanelView`, following `keepMicLiveDuringCalls`/`setKeepMicLiveDuringCalls` exactly. Exception: state whose truth lives outside the app (like `launchAtLogin`) reads that source on `.onAppear`, not `UserDefaults`.

## 4. Build & install

- **CLI**: `./build.sh` (`build.sh:1`) — one `clang` invocation: `main.m` + `-F vendor -framework VVUVCKit -framework Foundation -framework IOKit -framework CoreAudio -framework AudioToolbox`, rpath into `vendor/`. Output: `./obsbot`. Needs Xcode command-line tools; no download (frameworks are committed).
- **GUI**: `cd gui && ./build.sh [--install]` (`gui/build.sh:1`) — plain `swiftc` (no Xcode project):
  - Builds `OBSBOT Control.app` bundle by hand: copies `design/AppIcon.icns` and the two vendor frameworks into the bundle, compiles `ObsbotApp.swift` with `-import-objc-header Bridging.h -F ../vendor -framework VVUVCKit ...`, target `arm64-apple-macos13.0`.
  - Writes `Info.plist` inline (bundle id `design.constellation.obsbot-control`, `LSUIElement=true`, camera/mic usage strings).
  - Ad-hoc codesigns (`codesign --force --deep -s -`).
  - `--install` additionally copies the built app to `~/Applications` (for Spotlight/Raycast) and re-signs it there.
- Both build scripts are the source of truth for build details; if this doc and a script disagree, trust the script.

## 5. Data flow: control command → device

```
CLI:  argv -> findControl() dispatch table -> NSInvocation call on VVUVCController -> UVC device
      argv "micvolume"/"mic" -> findOBSBOTAudioDeviceID() -> CoreAudio AudioObjectSetPropertyData

GUI:  slider drag / toggle -> CameraModel setter (setZoom, setMicVolume, setKeepMicLiveDuringCalls...)
      -> VVUVCController method call (direct, no NSInvocation reflection needed in Swift)
         or CoreAudio AudioObjectSetPropertyData
      -> UVC device / CoreAudio device
```

Neither path goes through the other binary or any shared library — the GUI's Swift device-discovery and CoreAudio functions are an independent, hand-translated copy of the CLI's C functions, not a shared dependency. Changing device-discovery logic requires editing both files.

## 6. `vendor/` and `design/`

- **`vendor/`** — `VVUVCKit.framework` and `USBBusProber.framework`, third-party (by vade/mrRay), redistributed under original license. **Do not edit.** Both build scripts assume these are already present (no download step exists).
- **`design/`** — `appicon.svg` (source), `make-icon.sh` (needs `cairosvg`, regenerates `AppIcon.icns` — only run when the icon changes), `AppIcon.icns` (committed, so normal builds need no rasterizer), `directions.html` (design exploration, not part of the build).

## 7. Gotchas an agent must know

- **The OBSBOT mic is silent unless a video stream is open.** Any mic-related change must account for this; the GUI's whole "keep mic live" subsystem (section 3) exists solely to work around it.
- **The GUI is one file.** Don't propose splitting it into MVVM/multiple files unless asked; that's a deliberate choice (see the ponytail comment at `gui/ObsbotApp.swift:7`).
- **`design/AppIcon.icns` is committed** — do not assume a build needs `cairosvg`; only regenerate when the icon itself changes.
- **No network calls, ever.** This project's entire reason to exist is avoiding OBSBOT's cloud software. Stop and ask before adding anything that could look like network access.
- **Don't edit `vendor/`.**
- **USB `locationID` and CoreAudio device IDs are both ephemeral** (replugging changes them) — both CLI and GUI re-discover the device on every relevant operation rather than caching an ID long-term; the GUI additionally re-arms its CoreAudio listener after a device ID changes (see `refreshMic()`, `gui/ObsbotApp.swift:823`).
- **All `AVCaptureSession` configuration in the GUI must go through `sessionQueue`**, never main or ad hoc — see the crash explanation at `gui/ObsbotApp.swift:221-229`.
