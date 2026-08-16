# AGENTS.md

Guidance for any AI agent working in this repo (Claude Code, Codex, others). Single source of truth: `CLAUDE.md` imports this file, so edit here, not there.

## What this project is

`obsbot-control` controls an **OBSBOT Meet 2** webcam on macOS using only open-source code: no OBSBOT Center, no vendor SDK, no account. The camera is a standard UVC device; the app talks the UVC control protocol directly through the vendored [VVUVCKit](https://github.com/mrRay/VVUVCKit) framework, and mic controls via CoreAudio.

Two deliverables:
- **`obsbot` CLI** — `main.m`, built by root `./build.sh`.
- **OBSBOT Control** — a SwiftUI/AppKit menu-bar agent app, `gui/ObsbotApp.swift`, built by `gui/build.sh`.

See `README.md` for the feature list, controls table, and usage. Do not restate those here; read the file.

## Hard rules

- **No network calls, ever.** Privacy is the whole point of this project: it exists because the user distrusts OBSBOT's cloud vendor software. Nothing may talk to a server, phone home, or require an account. If a task seems to need the network, stop and ask.
- **Commit and push only when the user asks.** Work is local-first; the user reviews before every commit. Never push unprompted.
- **Do not edit `vendor/`.** VVUVCKit and USBBusProber are vendored third-party frameworks, redistributed under their original license.

## Layout

```
main.m          the CLI
build.sh        clang build for the CLI -> ./obsbot
gui/            OBSBOT Control.app: SwiftUI/AppKit menu-bar app + its build.sh
design/         app icon: appicon.svg (source), make-icon.sh, AppIcon.icns
vendor/         VVUVCKit + USBBusProber frameworks (do not edit)
```

## Building

- CLI: `./build.sh` (needs Xcode command-line tools; frameworks are vendored, no download).
- GUI: `cd gui && ./build.sh`; add `--install` to also copy the app to `~/Applications`. Plain `swiftc`, no Xcode project. Target `arm64-apple-macos13.0`, bundle id `design.constellation.obsbot-control`, `LSUIElement` agent app.

The commands are the source of truth; if they change, the scripts change, not this file.

## Conventions and gotchas

- **The GUI is one file** (`gui/ObsbotApp.swift`). When adding a settings toggle, match the existing `keepMicLiveDuringCalls` pattern: a `@Published` model property + a setter + a `Toggle` using `ApertureToggleStyle`. Exception: state whose truth lives outside the app (e.g. login-item status from `SMAppService`) reads that source on `.onAppear`, not UserDefaults.
- **Visual direction is "Aperture":** warm charcoal ground with brass/amber accents, photographic. Keep new UI within that palette (`Aperture.*` tokens in the GUI file).
- **The OBSBOT mic only passes audio while a video stream is open.** The "keep mic live" toggle works around this by holding a background camera stream. If you touch mic behavior, account for this.
- **App icon** is generated from `design/appicon.svg` via `design/make-icon.sh` (needs `cairosvg`), but `design/AppIcon.icns` is committed, so a normal build needs no rasterizer. Only regenerate when the icon changes.

## Model routing (which agent does what)

The user is a solo founder: product/design strong, engineering-beginner. Explain infra/security/mobile more; assume product and UX judgment.

- **Taste-critical or user-facing work** (UI, icon, copy, API shape): use a high-taste model. First taste-critical build of a thing can use the strongest available; iteration on the GUI goes to a mid-tier fast model (Sonnet), not the ceiling.
- **Bulk/mechanical work** (clear-spec implementation, migrations, data): cheapest capable model (Codex / gpt-5.6-sol).
- **Reviews:** an independent perspective is worth more than the model that wrote the code.
- If you (the session model) are an expensive orchestrator tier, delegate the code-writing and spend your turn on planning, briefing, review, and integration.
