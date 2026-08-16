# obsbot-control

Control an **OBSBOT Meet 2** webcam from macOS using only open-source code. No
OBSBOT Center, no vendor SDK, no account, and nothing sent to any server.

The camera is a standard USB Video Class (UVC) device. This tool talks the UVC
control protocol directly through the open-source
[VVUVCKit](https://github.com/mrRay/VVUVCKit) framework, so all image and zoom
settings are reachable without the vendor's software.

## Status

- `obsbot` CLI: works. Controls zoom and all image settings.
- Menubar GUI: planned.
- Audio settings: under investigation (separate from the video/UVC layer).

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

## Build

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
./obsbot reset                  # restore all controls to defaults
./obsbot                        # usage
```

## How it works

1. Find the OBSBOT on the USB bus via IOKit (vendor ID 13668, product ID
   65275), read its `locationID`.
2. Open a `VVUVCController` for that device.
3. Read or write the UVC controls directly.

No network access. Nothing leaves the machine.

## Layout

```
main.m          the CLI
build.sh        one-line clang build
vendor/         VVUVCKit.framework + USBBusProber.framework (open source)
```

## Third-party code

VVUVCKit and USBBusProber by vade (mrRay), redistributed under their original
license. See `vendor/*/`.
