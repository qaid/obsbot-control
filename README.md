# obsbot-control

Control an **OBSBOT Meet 2** webcam from macOS using only open-source code. No
OBSBOT Center, no vendor SDK, no account, and nothing sent to any server.

The camera is a standard USB Video Class (UVC) device. This tool talks the UVC
control protocol directly through the open-source
[VVUVCKit](https://github.com/mrRay/VVUVCKit) framework, so all image and zoom
settings are reachable without the vendor's software.

## Status

- `obsbot` CLI: works. Controls zoom, all image settings, and mic volume/mute.
- OBSBOT Control (menu-bar GUI): works. Same controls, plus a live camera
  preview, a mic level meter, and a "Launch at login" toggle.

## Controls

| Control | Range | Auto mode |
|---|---|---|
| zoom | 0 – 100 | no |
| focus | 0 – 100 | yes |
| exposure | 1 – 2500 | yes |
| brightness | 0 – 100 | no |
| contrast | 0 – 100 | no |
| saturation | 0 – 100 | no |
| sharpness | 0 – 100 | no |
| gain | 1 – 64 | no |
| whitebalance | 2000 – 10000 (Kelvin) | yes |

Pan/tilt are not exposed: the Meet 2 does framing digitally, not by moving the
lens.

## Audio

Mic volume and mute are open, standard controls: macOS exposes them on any
input device through CoreAudio, so `obsbot` talks to CoreAudio directly (no
UVC, no vendor SDK). `obsbot set micvolume <0-100>` and
`obsbot set mic <mute|unmute>` control the "OBSBOT Meet 2 Microphone" input
device the same way the macOS Sound settings would.

The OBSBOT app's AI noise-reduction and pickup-pattern (directionality) modes
are proprietary vendor features, not standard CoreAudio controls, so they are
not supported here by design.

## Build (CLI)

Requires the Xcode command-line tools (`clang`). The two frameworks are
vendored in `vendor/`, so no download is needed.

```sh
./build.sh
```

## Use

```sh
./obsbot get                    # print every control with its current value and range
./obsbot set zoom 40            # set a control (clamps to range and tells you)
./obsbot set brightness 60
./obsbot set focus auto         # focus, exposure, whitebalance support "auto"
./obsbot set micvolume 55       # mic input gain, 0-100
./obsbot set mic mute           # mute/unmute the mic
./obsbot set mic unmute
./obsbot reset                  # restore all controls to defaults
./obsbot                        # usage
```

## How it works

1. Find the OBSBOT on the USB bus via IOKit (vendor ID 13668, product ID
   65275), read its `locationID`.
2. Open a `VVUVCController` for that device.
3. Read or write the UVC controls directly.

No network access. Nothing leaves the machine. This applies to both the CLI
and the GUI: neither talks to a server, neither needs an OBSBOT account.

## OBSBOT Control (GUI)

A SwiftUI/AppKit menu-bar app ("OBSBOT Control") wrapping the same UVC/CoreAudio
calls as the CLI. It runs as a background agent, not a Dock app (`LSUIElement`):
click the menu-bar icon to open the panel.

Features:

- Live camera preview.
- Zoom, exposure, white balance, and brightness sliders.
- Mic volume, mute, and a live input level meter.
- "Keep mic live during calls" toggle: the OBSBOT mic only passes audio while
  a video stream is open, so some call apps briefly silence it; this toggle
  works around that by holding a camera stream open in the background.
- "Launch at login" toggle (uses macOS's `SMAppService`).
- Custom app icon ("Aperture Bloom", a brass camera-aperture motif).

Build:

```sh
cd gui && ./build.sh
```

This produces `OBSBOT Control.app` in `gui/`. Run `./build.sh --install` to
also copy it to `~/Applications`, so Spotlight and Raycast can find it. The
icon is generated from `design/appicon.svg` via `design/make-icon.sh` (needs
`cairosvg`) into `design/AppIcon.icns`, but the `.icns` is committed, so a
normal build doesn't need a rasterizer.

## Layout

```
main.m          the CLI
build.sh        one-line clang build for the CLI
gui/            OBSBOT Control.app: SwiftUI/AppKit menu-bar GUI + its build.sh
design/         app icon source (appicon.svg), make-icon.sh, built AppIcon.icns
vendor/         VVUVCKit.framework + USBBusProber.framework (open source)
```

## Third-party code

VVUVCKit and USBBusProber by vade (mrRay), redistributed under their original
license. See `vendor/*/`.
