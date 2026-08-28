# Logitech BRIO Ultra 4K HD — reverse-engineering report

Device: USB `046d:085e`, serial ADF03892, on bus 006.
Date: 2026-08-27. Host: framework laptop, Omarchy Linux, kernel 7.1.9-arch1-2.

## Device nodes

| Node | by-id suffix | Purpose |
|---|---|---|
| /dev/video2 | video-index0 | Main capture (YUYV, MJPG, NV12) |
| /dev/video3 | video-index1 | Metadata for video2 |
| /dev/video4 | video-index2 | IR sensor, GREY 340x340 @30 |
| /dev/video5 | video-index3 | Metadata for video4 |

Stable path: `/dev/v4l/by-id/usb-046d_Logitech_BRIO_*-video-index0`.

The IR node streams valid frames. The frames are near black on Linux
because the IR flood emitters only fire under the Windows Hello driver.

## Formats and frame rates (main node)

| Format | Top modes |
|---|---|
| MJPG | 4096x2160 @30 (DCI 4K), 3840x2160 @30, 2560x1440 @30, 1920x1080 @60, 1280x720 @90, 640x480 @120 |
| YUYV | up to 1600x896 @30 (uncompressed) |
| NV12 | up to 1920x1080 @30 |

YUYV also offers square crops 340x340 and 440x440 @30 (conferencing
thumbnails). 20 resolutions total per format family.

## Standard UVC controls (v4l2-ctl)

| Control | Range | Default |
|---|---|---|
| brightness | 0–255 | 128 |
| contrast | 0–255 | 128 |
| saturation | 0–255 | 128 |
| sharpness | 0–255 | 128 |
| gain | 0–255 | 0 |
| backlight_compensation | 0–1 | 1 |
| white_balance_automatic | bool | 1 |
| white_balance_temperature | 2000–7500 K, step 10 | 4000 |
| auto_exposure | 1=manual, 3=aperture priority | 3 |
| exposure_time_absolute | 3–2047 (units of 100 µs) | 250 |
| exposure_dynamic_framerate | bool | 0 |
| power_line_frequency | 0=off, 1=50 Hz, 2=60 Hz | 2 |
| focus_automatic_continuous | bool | 1 |
| focus_absolute | 0–255, step 5 | 0 |
| zoom_absolute | 100–500 (1.0x–5.0x digital) | 100 |
| pan_absolute | ±36000, step 3600 (±10°, 1° steps) | 0 |
| tilt_absolute | ±36000, step 3600 | 0 |

Pan and tilt only move the crop window while zoom is above 1.0x.

## Logitech vendor extension units (UVC XU)

Three extension units sit in the video-control chain:

| Unit ID | GUID | Controls |
|---|---|---|
| 14 | 2c49d16a-32b8-4485-3ea8-643a152362f2 | 6 |
| 6 | 23e49ed0-1178-4f31-ae52-d2fb8a8d3b48 | 14 (video pipeline: FoV lives here) |
| 8 | 69678ee4-410f-40db-a850-7420d7d8240e | 8 (device info / LED) |

BrioTune talks to these without `cameractrls`:

- **Field of view**: UVC XU, GUID `49e40215-f434-47fe-b158-0e885023e51b`,
  selector 0x05. Menu 65° / 78° / 90°.
- **Look**: not an XU. Named overlays of brightness, contrast, saturation,
  sharpness, and white balance. Write-only as a look id.
- **Recording LED**: UVC XU on the peripheral GUID
  `ffe52d21-8030-4e2c-82d9-f587d00540bd`, selector 0x09. Mode off / on /
  blink / auto, plus blink frequency 0–255.

## Verified working

- Control set + read-back round trip (brightness, FoV).
- MJPEG capture at 3840x2160 and 1920x1080 @60 (ffmpeg and mpv).
- IR node capture at 340x340.
- 4K still capture with a 15-frame auto-exposure warm-up.

Frames captured during the survey were black: the physical privacy
shutter was closed. The streams themselves negotiated and delivered
at full rate.

## Deliverable

This repository is the Omarchy plugin `io.github.shawnyeager.briotune`
(BrioTune), installed at
`~/.config/omarchy/plugins/io.github.shawnyeager.briotune/`:

- `manifest.json` — bar-widget manifest. Entry point is `BarWidget.qml`.
- `BarWidget.qml` — bar icon. Loads `Panel.qml` and owns IPC.
- `Panel.qml` — nested details panel (`manageIpc: false`). A live
  preview (QtMultimedia) is the interface: scroll it to zoom, drag it
  to pan while zoomed. FoV chips, zoom slider, and Focus / Exposure /
  White balance switches that reveal a manual slider only when Auto is
  off. Image adjustments (Look, then sliders). Footer: 4K photo, Reset.
- `bin/brio-ctl` — CLI wrapper over v4l2-ctl plus Logitech UVC XU; also usable
  standalone: `probe | status | set | reset | preview | preview-ir |
  snapshot`. The LED controls, IR sensor view, and dynamic-framerate
  toggle are CLI-only; the panel stays curated.

Note for future edits: the shell keeps live panel instances across
plugin hot reloads. After editing Panel.qml, run
`omarchy restart shell` to see the change.

The widget sits in the bar right section (registered in
`~/.config/omarchy/shell.json`) and hides itself when the camera is
unplugged. Open: `omarchy-shell shell summon io.github.shawnyeager.briotune '{}'`.
