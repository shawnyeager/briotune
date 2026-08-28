#!/usr/bin/env bash
# Drive the shipped brio-ctl binary. Do not re-implement the control mapper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/brio-ctl"
PANEL="$ROOT/Panel.qml"
BAR="$ROOT/BarWidget.qml"
MANIFEST="$ROOT/manifest.json"
PLUGIN_ID="io.github.shawnyeager.briotune"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x $CLI ]] || fail "missing shipped CLI: $CLI"
bash -n "$CLI" || fail "bash -n failed on $CLI"

probe_json="$("$CLI" probe)"
echo "$probe_json" | jq -e '.present == true' >/dev/null || fail "probe present != true"
echo "$probe_json" | jq -e '.usb == "046d:085e"' >/dev/null || fail "probe usb is not 046d:085e"
echo "$probe_json" | jq -e '.name | test("BRIO")' >/dev/null || fail "probe name lacks BRIO"
echo "$probe_json" | jq -e '.model | test("BRIO")' >/dev/null || fail "probe model lacks BRIO"
echo "$probe_json" | jq -e '.fov == true and .zoom == true' >/dev/null || fail "probe lacks fov/zoom"

status_json="$("$CLI" status)"
echo "$status_json" | jq -e '.usb == "046d:085e"' >/dev/null || fail "status usb is not 046d:085e"
for name in brightness contrast saturation sharpness gain backlight \
            "anti-flicker" zoom pan tilt focus "focus-auto" exposure \
            "exposure-auto" "white-balance" "white-balance-auto" \
            "dynamic-framerate" fov look led "led-frequency" \
            "pan-relative" "tilt-relative" "pantilt-reset" \
            "pantilt-preset" "motor-focus"; do
  echo "$status_json" | jq -e --arg n "$name" '.controls[$n] != null' >/dev/null \
    || fail "status missing control $name"
done
echo "$status_json" | jq -e '.controls.fov.values == [65,78,90]' >/dev/null \
  || fail "FoV values are not 65, 78, 90"

# Round-trip one standard UVC control through the shipped CLI.
orig_brightness="$(echo "$status_json" | jq -r '.controls.brightness.value')"
orig_default="$(echo "$status_json" | jq -r '.controls.brightness.default')"
target=140
if [[ $orig_brightness == "$target" ]]; then target=110; fi
"$CLI" set "brightness=$target" >/dev/null
after="$("$CLI" status | jq -r '.controls.brightness.value')"
[[ $after == "$target" ]] || fail "brightness set $target but status is $after"
"$CLI" set "brightness=$orig_brightness" >/dev/null
restored="$("$CLI" status | jq -r '.controls.brightness.value')"
[[ $restored == "$orig_brightness" ]] || fail "failed to restore brightness"

# Round-trip FoV through the Logitech XU via the shipped CLI.
orig_fov="$("$CLI" status | jq -r '.controls.fov.value')"
for deg in 65 78 90; do
  "$CLI" set "fov=$deg" >/dev/null
  got="$("$CLI" status | jq -r '.controls.fov.value')"
  [[ $got == "$deg" ]] || fail "fov set $deg but status is $got"
done
"$CLI" set "fov=$orig_fov" >/dev/null

# Look overlay first, then explicit UVC. Saved brightness must stick.
"$CLI" set look=vivid brightness=111 >/dev/null
got="$("$CLI" status | jq -r '.controls.brightness.value')"
[[ $got == 111 ]] || fail "look+brightness left brightness $got, want 111"
"$CLI" set "brightness=$orig_brightness" >/dev/null

# Look is a UVC overlay, not an XU; assert the shipped CLI applies it.
"$CLI" set look=vivid | jq -e '.ok == true and .set.look == "vivid"' >/dev/null \
  || fail "look=vivid did not apply"

# Reset restores camera-reported defaults (brightness).
"$CLI" set brightness=111 >/dev/null
"$CLI" reset >/dev/null
reset_b="$("$CLI" status | jq -r '.controls.brightness.value')"
[[ $reset_b == "$orig_default" ]] || fail "reset brightness $reset_b != default $orig_default"

# Structural UI: jobs-to-be-done controls wired to the shipped CLI.
grep -q 'import QtMultimedia' "$PANEL" || fail "Panel.qml lacks QtMultimedia"
grep -q 'VideoOutput' "$PANEL" || fail "Panel.qml lacks live VideoOutput preview"
grep -q 'Field of view' "$PANEL" || fail "Panel.qml lacks Field of view"
grep -q '65°' "$PANEL" || fail "Panel.qml lacks 65° chip"
grep -q 'Zoom' "$PANEL" || fail "Panel.qml lacks Zoom"
grep -q 'Focus' "$PANEL" || fail "Panel.qml lacks Focus"
grep -q 'Exposure' "$PANEL" || fail "Panel.qml lacks Exposure"
grep -q 'White balance' "$PANEL" || fail "Panel.qml lacks White balance"
grep -q 'text: "Look"' "$PANEL" || fail "Panel.qml lacks Look"
grep -q 'Image adjustments' "$PANEL" || fail "Panel.qml lacks Image adjustments"
grep -q 'imageTab' "$PANEL" && fail "Image adjustments must not use tabs" || true
grep -q 'Brightness' "$PANEL" || fail "Panel.qml lacks Brightness in Image adjustments"
grep -q '4K photo' "$PANEL" || fail "Panel.qml lacks 4K photo"
grep -q 'Reset' "$PANEL" || fail "Panel.qml lacks Reset"
grep -q 'brio-ctl' "$PANEL" || fail "Panel.qml is not wired to brio-ctl"
grep -q '046d:085e' "$PANEL" || fail "Panel.qml does not bind USB 046d:085e"
grep -q "ipcTarget: \"$PLUGIN_ID\"" "$PANEL" || fail "Panel.qml lacks IPC target $PLUGIN_ID"
grep -q 'manageIpc: false' "$PANEL" || fail "Panel.qml must set manageIpc: false"
grep -q 'centerOnBar' "$PANEL" && fail "Panel.qml must not center on the bar" || true
grep -q 'releaseSiblings' "$PANEL" || fail "Panel.qml lacks multi-monitor camera handoff"
grep -A6 'function open()' "$PANEL" | grep -q 'imageOpen = false' \
  || fail "open() must collapse Image adjustments"
grep -A14 'function open()' "$PANEL" | grep -q 'startCamera' \
  || fail "open() must start the preview after show()"
grep -A14 'function open()' "$PANEL" | grep -q 'cameraStart.restart' \
  || fail "open() must delay startCamera until sibling V4L2 drops"
grep -q 'pickPreviewFormat\|cameraFormat' "$PANEL" \
  && fail "Panel.qml must not force a preview format" || true
python3 - "$PANEL" <<'PY' || fail "open path runs status before the camera grabs V4L2"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
open_fn = re.search(r"function open\(\) \{.*?\n  \}", text, re.S)
opened = re.search(r"onOpenedChanged: \{.*?\n  \}", text, re.S)
if not open_fn or not opened:
    raise SystemExit("open handlers missing")
if "refresh()" in open_fn.group(0) or "refresh()" in opened.group(0):
    raise SystemExit("refresh on open")
PY
grep -q 'updateEntryInline' "$PANEL" || fail "Panel.qml does not persist settings to shell.json"

[[ -f $BAR ]] || fail "missing BarWidget.qml"
grep -q "moduleName: \"$PLUGIN_ID\"" "$BAR" || fail "BarWidget.qml lacks moduleName $PLUGIN_ID"
grep -q 'source: Qt.resolvedUrl("Panel.qml")' "$BAR" || fail "BarWidget.qml does not load Panel.qml"
grep -q 'visible: present' "$BAR" || fail "BarWidget.qml does not hide when unplugged"

[[ -f $MANIFEST ]] || fail "missing manifest.json"
jq -e --arg id "$PLUGIN_ID" '.id == $id' "$MANIFEST" >/dev/null || fail "manifest id is not $PLUGIN_ID"
jq -e '.entryPoints.barWidget == "BarWidget.qml"' "$MANIFEST" >/dev/null || fail "manifest barWidget entry is not BarWidget.qml"
jq -e '.license == "MIT"' "$MANIFEST" >/dev/null || fail "manifest lacks MIT license"
jq -e 'has("omarchy") | not' "$MANIFEST" >/dev/null || fail "finished plugin must not keep omarchy.clonedFrom"
[[ -f $ROOT/LICENSE ]] || fail "missing LICENSE"
[[ -f $ROOT/README.md ]] || fail "missing README.md"

# Recording lamp, IR view, and frame-rate boost stay CLI-only in the panel.
if grep -E 'setControl\("led|preview-ir|led-frequency|dynamic-framerate' "$PANEL"; then
  fail "Panel.qml exposes a CLI-only control"
fi

# Reset must not persist the in-flight status blob. Arm persist only after
# the reset JSON returns, then persist the following status.
python3 - "$PANEL" <<'PY' || fail "resetCamera arms persist before reset JSON"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
fn = re.search(r"function resetCamera\(\) \{.*?\n  \}", text, re.S)
if not fn:
    raise SystemExit("resetCamera missing")
if "persistAfterStatus = true" in fn.group(0):
    raise SystemExit("resetCamera sets persistAfterStatus")
PY
grep -A20 'id: cliProc' "$PANEL" | grep -q 'persistAfterStatus = true' \
  || fail "cliProc does not arm persistAfterStatus from reset JSON"

# Main node also has YUYV 340x340. IR is the node whose largest mode is 340.
if grep -A40 'function pickBrioDevice' "$PANEL" | grep -q 'width === 340 && res.height === 340'; then
  fail "pickBrioDevice treats any 340x340 format as IR"
fi
grep -A40 'function pickBrioDevice' "$PANEL" | grep -q 'maxW' \
  || fail "pickBrioDevice does not pick the color node by max width"

# Wheel overlay must sit above PanelSlider and accept no click buttons.
grep -A40 'component WheelPassSlider' "$PANEL" | grep -q 'acceptedButtons: Qt.NoButton' \
  || fail "WheelPassSlider has no click-through wheel overlay"

# Snapshot must wait until Camera actually released V4L2.
grep -A12 'id: camera' "$PANEL" | grep -q 'snapshotBusy' \
  || fail "Camera onActiveChanged does not start snapshot after release"
grep -q 'snapshotTries' "$PANEL" || fail "Panel.qml does not retry snapshot after a busy fd"

python3 - "$CLI" <<'PY' || fail "apply_set runs apply_look after explicit UVC"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
fn = re.search(r"def apply_set\(dev: str, pairs: list\[tuple\[str, str\]\]\) -> dict\[str, Any\]:.*?\n    return applied", text, re.S)
if not fn:
    raise SystemExit("apply_set missing")
body = fn.group(0)
look = body.find("apply_look(dev, look_id)")
uvc = body.find("v4l2_set(dev, uvc_first)")
if look < 0 or uvc < 0 or look > uvc:
    raise SystemExit("apply_look is not before v4l2_set")
if body.count("apply_look(") != 1:
    raise SystemExit("apply_set apply_look count")
PY

python3 - "$PANEL" <<'PY' || fail "look click does not refresh sliders from status"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
idx = text.find('root.look = parent.modelData.value')
if idx < 0:
    raise SystemExit("look click missing")
blob = text[idx:idx+420]
if "persistAfterStatus = true" not in blob:
    raise SystemExit("look click does not arm persistAfterStatus")
if 'enqueue(["status"])' not in blob:
    raise SystemExit("look click does not enqueue status")
if "setControl(" in blob:
    raise SystemExit("look click still uses setControl")
PY

python3 - "$PANEL" <<'PY' || fail "probe timer still skips while the panel is open"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
if "!root.opened && !root.wantPreview" in text:
    raise SystemExit("probe skipped while opened")
PY

grep -q cameractrls "$CLI" && fail "brio-ctl still depends on cameractrls" || true

help="$("$CLI" --help)"
echo "$help" | grep -q 'FoV 90' && fail "brio-ctl help still says reset sets FoV 90" || true
echo "$help" | grep -qi 'fov is unchanged' || fail "brio-ctl help does not say FoV is unchanged"

grep -q 'Filters' "$ROOT/README.md" && fail "README still says Filters" || true
grep -q 'Filters' "$ROOT/BRIO.md" && fail "BRIO.md still says Filters" || true

echo "PASS"
