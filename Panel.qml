import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Nested details panel. BarWidget.qml is the bar-widget entry.
// manageIpc is false; the bar widget owns IPC and popout identity.
Panel {
  id: root
  moduleName: "io.github.shawnyeager.briotune"
  ipcTarget: "io.github.shawnyeager.briotune"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string pluginDir: Qt.resolvedUrl("Panel.qml").toString().replace(/^file:\/\//, "").replace(/\/Panel\.qml$/, "")
  readonly property string cliPath: pluginDir + "/bin/brio-ctl"
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color well: Qt.rgba(fg.r, fg.g, fg.b, 0.07)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int rowPad: Style.space(12)
  readonly property int rowH: Style.space(44)

  property bool present: false
  property string modelName: "BRIO"
  property int zoom: 100
  property int pan: 0
  property int tilt: 0
  property int fov: 78
  property bool focusAuto: true
  property int focusValue: 0
  property bool exposureAuto: true
  property int exposureValue: 250
  property bool wbAuto: true
  property int wbValue: 4000
  property int brightness: 128
  property int contrast: 128
  property int saturation: 128
  property int sharpness: 128
  property bool backlight: true
  property string flicker: "60"
  property string look: ""
  property bool imageOpen: false
  property bool snapshotBusy: false
  property int snapshotTries: 0
  property bool persistAfterStatus: false
  property bool restored: false
  property string toast: ""
  property var cliQueue: []
  property int cameraTries: 0
  property bool wantPreview: false
  property bool draggingPreview: false
  property real dragStartX: 0
  property real dragStartY: 0
  property int dragStartPan: 0
  property int dragStartTilt: 0

  readonly property bool zoomed: zoom > 100
  readonly property var lookOptions: [
    { value: "default", label: "Default" },
    { value: "blossom", label: "Blossom" },
    { value: "bright", label: "Bright" },
    { value: "film", label: "Film" },
    { value: "forest", label: "Forest" },
    { value: "glaze", label: "Glaze" },
    { value: "gray", label: "Gray" },
    { value: "vibrant", label: "Vibrant" },
    { value: "vivid", label: "Vivid" }
  ]

  onSettingsChanged: hydrateFromSettings()
  onPresentChanged: {
    if (!present) {
      restored = false
      if (opened) close()
      return
    }
    if (!restored) {
      restored = true
      applySaved()
    }
  }

  // One Camera per bar instance, one exclusive V4L2 node. Opening on the
  // external display must drop the laptop instance first or the preview
  // stays dark.
  function siblingWidgets() {
    if (!bar || typeof bar.moduleWidgets !== "function") return []
    return bar.moduleWidgets(moduleName)
  }

  function releaseCamera() {
    cameraStart.stop()
    camera.active = false
  }

  function releaseSiblings() {
    var items = siblingWidgets()
    for (var i = 0; i < items.length; i++) {
      var other = items[i]
      if (!other || other === root.barIdentity) continue
      if (typeof other.releaseCamera === "function") other.releaseCamera()
      if (other.opened && typeof other.close === "function") other.close()
    }
  }

  function startCamera() {
    if (snapshotBusy || (!opened && !wantPreview)) return
    var dev = pickBrioDevice()
    if (!dev) {
      if (cameraTries < 5) {
        cameraTries += 1
        cameraStart.restart()
      }
      return
    }
    camera.cameraDevice = dev
    camera.active = true
    if (camera.active) {
      cameraTries = 0
      return
    }
    if (cameraTries < 5) {
      cameraTries += 1
      cameraStart.restart()
    }
  }

  function open() {
    imageOpen = false
    wantPreview = true
    cameraTries = 0
    releaseSiblings()
    root.controller.show()
    // startCamera after sibling V4L2 drops. Camera.active=false is async.
    cameraStart.restart()
  }

  function close() {
    wantPreview = false
    releaseCamera()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  onOpenedChanged: {
    if (opened) {
      imageOpen = false
      wantPreview = true
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    } else {
      wantPreview = false
      releaseCamera()
    }
  }

  function refresh() { enqueue(["status"]) }

  function enqueue(args) {
    cliQueue = cliQueue.concat([args])
    pump()
  }

  function pump() {
    if (cliProc.running || cliQueue.length === 0) return
    var next = cliQueue[0]
    var rest = []
    for (var i = 1; i < cliQueue.length; i++) rest.push(cliQueue[i])
    cliQueue = rest
    cliProc.command = [cliPath].concat(next)
    cliProc.running = true
  }

  function setControl() {
    var args = ["set"]
    for (var i = 0; i < arguments.length; i++) args.push(arguments[i])
    enqueue(args)
    persistCamera()
  }

  // Bar-widget state lives in shell.json via updateEntryInline.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function persistCamera() {
    persistSettings({
      look: look,
      fov: fov,
      zoom: zoom,
      pan: pan,
      tilt: tilt,
      focusAuto: focusAuto,
      focusValue: focusValue,
      exposureAuto: exposureAuto,
      exposureValue: exposureValue,
      wbAuto: wbAuto,
      wbValue: wbValue,
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
      sharpness: sharpness,
      backlight: backlight,
      flicker: flicker
    })
  }

  function hydrateFromSettings() {
    look = String(setting("look", look))
    fov = Number(setting("fov", fov))
    zoom = Number(setting("zoom", zoom))
    pan = Number(setting("pan", pan))
    tilt = Number(setting("tilt", tilt))
    focusAuto = setting("focusAuto", focusAuto) === true || setting("focusAuto", focusAuto) === 1
    focusValue = Number(setting("focusValue", focusValue))
    exposureAuto = setting("exposureAuto", exposureAuto) === true || setting("exposureAuto", exposureAuto) === 1
    exposureValue = Number(setting("exposureValue", exposureValue))
    wbAuto = setting("wbAuto", wbAuto) === true || setting("wbAuto", wbAuto) === 1
    wbValue = Number(setting("wbValue", wbValue))
    brightness = Number(setting("brightness", brightness))
    contrast = Number(setting("contrast", contrast))
    saturation = Number(setting("saturation", saturation))
    sharpness = Number(setting("sharpness", sharpness))
    backlight = setting("backlight", backlight) === true || setting("backlight", backlight) === 1
    flicker = String(setting("flicker", flicker))
  }

  function applySaved() {
    hydrateFromSettings()
    var args = ["set"]
    var lookId = String(setting("look", ""))
    if (lookId !== "") args.push("look=" + lookId)
    if (settings && settings.fov !== undefined) args.push("fov=" + Number(settings.fov))
    if (settings && settings.zoom !== undefined) args.push("zoom=" + Number(settings.zoom))
    if (settings && settings.pan !== undefined) args.push("pan=" + Number(settings.pan))
    if (settings && settings.tilt !== undefined) args.push("tilt=" + Number(settings.tilt))
    if (settings && settings.focusAuto !== undefined)
      args.push("focus-auto=" + (settings.focusAuto ? "on" : "off"))
    if (settings && settings.focusAuto === false && settings.focusValue !== undefined)
      args.push("focus=" + Number(settings.focusValue))
    if (settings && settings.exposureAuto !== undefined)
      args.push("exposure-auto=" + (settings.exposureAuto ? "auto" : "manual"))
    if (settings && settings.exposureAuto === false && settings.exposureValue !== undefined)
      args.push("exposure=" + Number(settings.exposureValue))
    if (settings && settings.wbAuto !== undefined)
      args.push("white-balance-auto=" + (settings.wbAuto ? "on" : "off"))
    if (settings && settings.wbAuto === false && settings.wbValue !== undefined)
      args.push("white-balance=" + Number(settings.wbValue))
    if (settings && settings.brightness !== undefined) args.push("brightness=" + Number(settings.brightness))
    if (settings && settings.contrast !== undefined) args.push("contrast=" + Number(settings.contrast))
    if (settings && settings.saturation !== undefined) args.push("saturation=" + Number(settings.saturation))
    if (settings && settings.sharpness !== undefined) args.push("sharpness=" + Number(settings.sharpness))
    if (settings && settings.backlight !== undefined)
      args.push("backlight=" + (settings.backlight ? "on" : "off"))
    if (settings && settings.flicker !== undefined) args.push("anti-flicker=" + settings.flicker)
    if (args.length > 1) enqueue(args)
  }

  function num(rec, fallback) {
    if (!rec || rec.value === undefined || rec.value === null) return fallback
    return Number(rec.value)
  }

  function applyStatus(raw) {
    var parsed
    try { parsed = JSON.parse(String(raw || "")) } catch (e) { return }
    if (!parsed || !parsed.controls) return
    if (parsed.model) root.modelName = String(parsed.model)
    var c = parsed.controls
    zoom = num(c.zoom, zoom)
    pan = num(c.pan, pan)
    tilt = num(c.tilt, tilt)
    fov = num(c.fov, fov)
    focusAuto = num(c["focus-auto"], focusAuto ? 1 : 0) === 1
    focusValue = num(c.focus, focusValue)
    exposureAuto = String((c["exposure-auto"] && c["exposure-auto"].label) || (exposureAuto ? "auto" : "manual")) === "auto"
    exposureValue = num(c.exposure, exposureValue)
    wbAuto = num(c["white-balance-auto"], wbAuto ? 1 : 0) === 1
    wbValue = num(c["white-balance"], wbValue)
    brightness = num(c.brightness, brightness)
    contrast = num(c.contrast, contrast)
    saturation = num(c.saturation, saturation)
    sharpness = num(c.sharpness, sharpness)
    backlight = num(c.backlight, backlight ? 1 : 0) === 1
    flicker = String((c["anti-flicker"] && c["anti-flicker"].label) || flicker)
    if (persistAfterStatus) {
      persistAfterStatus = false
      persistCamera()
    }
  }

  function clamp(n, lo, hi) { return Math.max(lo, Math.min(hi, n)) }
  function snap(n, step) { return Math.round(n / step) * step }
  function pickBrioDevice() {
    var inputs = mediaDevices.videoInputs
    var fallback = null
    for (var i = 0; i < inputs.length; i++) {
      var desc = String(inputs[i].description || "")
      if (desc.indexOf("BRIO") === -1 && desc.indexOf("Brio") === -1) continue
      var formats = inputs[i].videoFormats
      var maxW = 0
      if (formats) {
        for (var f = 0; f < formats.length; f++) {
          var res = formats[f].resolution
          if (res && res.width > maxW) maxW = res.width
        }
      }
      // Main node also has a 340×340 YUYV crop. IR is GREY 340×340 only.
      if (maxW > 340) return inputs[i]
      if (!fallback) fallback = inputs[i]
    }
    return fallback
  }

  function applyZoom(next) {
    next = clamp(Math.round(next), 100, 500)
    zoom = next
    if (next === 100) {
      pan = 0
      tilt = 0
      setControl("zoom=" + next, "pan=0", "tilt=0")
    } else {
      setControl("zoom=" + next)
    }
  }

  function takePhoto() {
    if (snapshotBusy || cliPath === "") return
    snapshotBusy = true
    snapshotTries = 0
    toast = "Capturing 4K…"
    if (camera.active)
      camera.active = false
    else
      snapshotWait.restart()
  }

  function resetCamera() {
    enqueue(["reset"])
    enqueue(["status"])
    look = "default"
    toast = "Reset"
    toastClear.restart()
  }

  function lookSelected(id) {
    if (root.look === "" || root.look === "default") return id === "default"
    return root.look === id
  }

  function scrollPanel(dy) {
    var maxY = Math.max(0, scroller.contentHeight - scroller.height)
    scroller.contentY = Math.max(0, Math.min(maxY, scroller.contentY - dy))
  }

  // PanelSlider's MouseArea handles onWheel. A sibling WheelHandler never
  // sees the event. Overlay a click-through MouseArea on top so hover
  // still scrolls the panel list.
  component WheelPassSlider: Item {
    property alias bar: sl.bar
    property alias value: sl.value
    property alias minimum: sl.minimum
    property alias maximum: sl.maximum
    property alias step: sl.step
    property alias integer: sl.integer
    signal moved(real value)
    signal released(real value)
    implicitHeight: sl.implicitHeight
    implicitWidth: sl.implicitWidth
    PanelSlider {
      id: sl
      anchors.fill: parent
      onMoved: function(v) { parent.moved(v) }
      onReleased: function(v) { parent.released(v) }
    }
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      onWheel: function(wheel) {
        wheel.accepted = true
        root.scrollPanel(wheel.angleDelta.y)
      }
    }
  }

  MediaDevices { id: mediaDevices }
  CaptureSession {
    camera: camera
    videoOutput: viewfinder
  }
  Camera {
    id: camera
    active: false
    onActiveChanged: {
      if (active) {
        root.cameraTries = 0
        if (root.opened && !root.snapshotBusy)
          Qt.callLater(root.refresh)
        return
      }
      if (root.snapshotBusy) {
        snapshotWait.restart()
        return
      }
      if (root.opened && root.cameraTries < 5)
        cameraStart.restart()
    }
  }

  Timer {
    id: cameraStart
    interval: 80
    onTriggered: root.startCamera()
  }

  Process {
    id: probeProc
    command: [root.cliPath, "probe"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var shown = false
        try {
          var parsed = JSON.parse(String(text || ""))
          shown = parsed && parsed.present === true && String(parsed.usb) === "046d:085e"
          if (shown && parsed.model) root.modelName = String(parsed.model)
        } catch (e) {}
        root.present = shown
      }
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: if (!probeProc.running) probeProc.running = true
  }

  Process {
    id: cliProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        // Arm persist after reset JSON, never from resetCamera(). An
        // in-flight status would otherwise write the pre-reset values.
        if (raw.indexOf("\"reset\"") !== -1) root.persistAfterStatus = true
        if (raw.indexOf("\"controls\"") !== -1) root.applyStatus(raw)
        root.pump()
      }
    }
  }

  Process {
    id: snapshotProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (raw.indexOf("\"ok\": true") === -1) return
        root.toast = "Saved 4K photo"
        root.snapshotBusy = false
        if (root.opened) {
          root.cameraTries = 0
          cameraStart.restart()
        }
        toastClear.restart()
      }
    }
    onExited: function(exitCode) {
      if (!root.snapshotBusy) return
      if (exitCode === 0) return
      if (root.snapshotTries < 8) {
        snapshotWait.restart()
        return
      }
      root.snapshotBusy = false
      root.toast = "Photo failed"
      if (root.opened) {
        root.cameraTries = 0
        cameraStart.restart()
      }
      toastClear.restart()
    }
  }

  Timer {
    id: snapshotWait
    interval: 80
    onTriggered: {
      root.snapshotTries += 1
      snapshotProc.command = [root.cliPath, "snapshot"]
      snapshotProc.running = true
    }
  }
  Timer {
    id: toastClear
    interval: 2200
    onTriggered: root.toast = ""
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened && root.present
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.resetCamera()
        else if (t === "p" || t === "P") root.takePhoto()
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: body.implicitHeight
        interactive: contentHeight > height
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: body
          width: scroller.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            height: Style.space(28)
            Text {
              anchors.left: parent.left
              anchors.right: connectedLab.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "󰖠  " + root.modelName
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              id: connectedLab
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "CONNECTED"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 0.8
            }
          }

          Item {
            id: previewFrame
            width: parent.width
            height: Math.round(width * 9 / 16)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: bar ? bar.background : Color.background
              clip: true

              VideoOutput {
                id: viewfinder
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectCrop
                visible: camera.active && !root.snapshotBusy
              }

              Text {
                visible: !camera.active || root.snapshotBusy
                anchors.centerIn: parent
                text: root.snapshotBusy ? "Capturing…" : (root.wantPreview ? "Starting…" : "No preview")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                visible: root.toast !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(10)
                text: root.toast
                color: "white"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: function(event) {
                  event.accepted = true
                  root.applyZoom(root.zoom + (event.angleDelta.y > 0 ? 15 : -15))
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                acceptedButtons: Qt.LeftButton
                cursorShape: root.zoomed ? (root.draggingPreview ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
                onPressed: function(mouse) {
                  if (!root.zoomed) return
                  root.draggingPreview = true
                  root.dragStartX = mouse.x
                  root.dragStartY = mouse.y
                  root.dragStartPan = root.pan
                  root.dragStartTilt = root.tilt
                }
                onPositionChanged: function(mouse) {
                  if (!root.draggingPreview) return
                  root.pan = root.clamp(root.snap(root.dragStartPan - (mouse.x - root.dragStartX) * 80, 3600), -36000, 36000)
                  root.tilt = root.clamp(root.snap(root.dragStartTilt + (mouse.y - root.dragStartY) * 80, 3600), -36000, 36000)
                }
                onReleased: {
                  if (!root.draggingPreview) return
                  root.draggingPreview = false
                  root.setControl("pan=" + root.pan, "tilt=" + root.tilt)
                }
              }
            }
          }

          // Field of view — Tune order: 90 · 78 · 65
          Rectangle {
            width: parent.width
            implicitHeight: root.rowH
            radius: Style.cornerRadius
            color: root.well

            Text {
              anchors.left: parent.left
              anchors.leftMargin: root.rowPad
              anchors.right: fovPills.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "Field of view"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Row {
              id: fovPills
              anchors.right: parent.right
              anchors.rightMargin: root.rowPad
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Repeater {
                model: [
                  { value: 90, label: "90°" },
                  { value: 78, label: "78°" },
                  { value: 65, label: "65°" }
                ]
                Button {
                  required property var modelData
                  text: modelData.label
                  selected: root.fov === modelData.value
                  foreground: root.fg
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(4)
                  onClicked: {
                    root.fov = modelData.value
                    root.setControl("fov=" + modelData.value)
                  }
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            implicitHeight: root.rowH
            radius: Style.cornerRadius
            color: root.well

            Text {
              id: zoomLab
              anchors.left: parent.left
              anchors.leftMargin: root.rowPad
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(52)
              text: "Zoom"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Button {
              id: zoomMinus
              anchors.left: zoomLab.right
              anchors.verticalCenter: parent.verticalCenter
              text: "−"
              foreground: root.fg
              fontSize: Style.font.body
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(2)
              onClicked: root.applyZoom(root.zoom - 20)
            }

            WheelPassSlider {
              anchors.left: zoomMinus.right
              anchors.right: zoomPlus.left
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              bar: root.bar
              minimum: 100
              maximum: 500
              step: 1
              integer: true
              value: root.zoom
              onMoved: function(v) { root.zoom = Math.round(v) }
              onReleased: function(v) { root.applyZoom(v) }
            }

            Button {
              id: zoomPlus
              anchors.right: parent.right
              anchors.rightMargin: root.rowPad
              anchors.verticalCenter: parent.verticalCenter
              text: "+"
              foreground: root.fg
              fontSize: Style.font.body
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(2)
              onClicked: root.applyZoom(root.zoom + 20)
            }
          }

          Rectangle {
            width: parent.width
            implicitHeight: focusCol.implicitHeight
            radius: Style.cornerRadius
            color: root.well
            Column {
              id: focusCol
              width: parent.width
              Item {
                width: parent.width
                height: root.rowH
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: root.rowPad
                  anchors.right: focusSw.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Focus"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Row {
                  id: focusSw
                  anchors.right: parent.right
                  anchors.rightMargin: root.rowPad
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)
                  Text {
                    text: root.focusAuto ? "Auto" : "Manual"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  ToggleSwitch {
                    checked: root.focusAuto
                    foreground: root.fg
                    onToggled: {
                      root.focusAuto = !root.focusAuto
                      root.setControl("focus-auto=" + (root.focusAuto ? "on" : "off"))
                    }
                  }
                }
              }
              Item {
                visible: !root.focusAuto
                width: parent.width
                height: focusSlider.implicitHeight + Style.space(8)
                WheelPassSlider {
                  id: focusSlider
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: root.rowPad
                  anchors.rightMargin: root.rowPad
                  anchors.verticalCenter: parent.verticalCenter
                  bar: root.bar
                  minimum: 0; maximum: 255; step: 5; integer: true
                  value: root.focusValue
                  onMoved: function(v) { root.focusValue = Math.round(v) }
                  onReleased: function(v) { root.setControl("focus=" + Math.round(v)) }
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            implicitHeight: expCol.implicitHeight
            radius: Style.cornerRadius
            color: root.well
            Column {
              id: expCol
              width: parent.width
              Item {
                width: parent.width
                height: root.rowH
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: root.rowPad
                  anchors.right: expSw.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Exposure"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Row {
                  id: expSw
                  anchors.right: parent.right
                  anchors.rightMargin: root.rowPad
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)
                  Text {
                    text: root.exposureAuto ? "Auto" : "Manual"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  ToggleSwitch {
                    checked: root.exposureAuto
                    foreground: root.fg
                    onToggled: {
                      root.exposureAuto = !root.exposureAuto
                      root.setControl("exposure-auto=" + (root.exposureAuto ? "auto" : "manual"))
                    }
                  }
                }
              }
              Item {
                visible: !root.exposureAuto
                width: parent.width
                height: expSlider.implicitHeight + Style.space(8)
                WheelPassSlider {
                  id: expSlider
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: root.rowPad
                  anchors.rightMargin: root.rowPad
                  anchors.verticalCenter: parent.verticalCenter
                  bar: root.bar
                  minimum: 3; maximum: 2047; integer: true
                  value: root.exposureValue
                  onMoved: function(v) { root.exposureValue = Math.round(v) }
                  onReleased: function(v) { root.setControl("exposure=" + Math.round(v)) }
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            implicitHeight: wbCol.implicitHeight
            radius: Style.cornerRadius
            color: root.well
            Column {
              id: wbCol
              width: parent.width
              Item {
                width: parent.width
                height: root.rowH
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: root.rowPad
                  anchors.right: wbSw.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "White balance"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Row {
                  id: wbSw
                  anchors.right: parent.right
                  anchors.rightMargin: root.rowPad
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)
                  Text {
                    text: root.wbAuto ? "Auto" : "Manual"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  ToggleSwitch {
                    checked: root.wbAuto
                    foreground: root.fg
                    onToggled: {
                      root.wbAuto = !root.wbAuto
                      root.setControl("white-balance-auto=" + (root.wbAuto ? "on" : "off"))
                    }
                  }
                }
              }
              Item {
                visible: !root.wbAuto
                width: parent.width
                height: wbSlider.implicitHeight + Style.space(8)
                WheelPassSlider {
                  id: wbSlider
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: root.rowPad
                  anchors.rightMargin: root.rowPad
                  anchors.verticalCenter: parent.verticalCenter
                  bar: root.bar
                  minimum: 2000; maximum: 7500; step: 10; integer: true
                  value: root.wbValue
                  onMoved: function(v) { root.wbValue = Math.round(v) }
                  onReleased: function(v) { root.setControl("white-balance=" + Math.round(v)) }
                }
              }
            }
          }

          // Image adjustments — one stack. Look, then sliders. No tabs.
          Rectangle {
            width: parent.width
            implicitHeight: imgCol.implicitHeight
            radius: Style.cornerRadius
            color: root.well
            Column {
              id: imgCol
              width: parent.width

              Item {
                width: parent.width
                height: root.rowH
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: root.rowPad
                  anchors.right: imgChevron.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Image adjustments"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  id: imgChevron
                  anchors.right: parent.right
                  anchors.rightMargin: root.rowPad
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(16)
                  horizontalAlignment: Text.AlignHCenter
                  text: root.imageOpen ? "⌄" : "›"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.imageOpen = !root.imageOpen
                }
              }

              Column {
                visible: root.imageOpen
                width: parent.width
                topPadding: Style.space(4)
                bottomPadding: Style.space(10)
                spacing: Style.space(8)

                Column {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    leftPadding: root.rowPad
                    text: "Look"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Grid {
                    id: lookGrid
                    x: root.rowPad
                    width: parent.width - root.rowPad * 2
                    columns: 3
                    columnSpacing: Style.space(6)
                    rowSpacing: Style.space(6)
                    Repeater {
                      model: root.lookOptions
                      Rectangle {
                        required property var modelData
                        width: Math.floor((lookGrid.width - lookGrid.columnSpacing * 2) / 3)
                        height: Style.space(32)
                        radius: Style.cornerRadius
                        color: root.lookSelected(modelData.value)
                          ? Style.selectedFillFor(root.fg, Color.accent)
                          : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
                        Text {
                          anchors.fill: parent
                          anchors.leftMargin: Style.space(4)
                          anchors.rightMargin: Style.space(4)
                          text: parent.modelData.label
                          color: root.fg
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          horizontalAlignment: Text.AlignHCenter
                          verticalAlignment: Text.AlignVCenter
                          elide: Text.ElideRight
                        }
                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            root.look = parent.modelData.value
                            root.persistAfterStatus = true
                            root.enqueue(["set", "look=" + parent.modelData.value])
                            root.enqueue(["status"])
                          }
                        }
                      }
                    }
                  }
                }

                Repeater {
                  model: [
                    { key: "brightness", label: "Brightness", min: 0, max: 255 },
                    { key: "contrast", label: "Contrast", min: 0, max: 255 },
                    { key: "saturation", label: "Saturation", min: 0, max: 255 },
                    { key: "sharpness", label: "Sharpness", min: 0, max: 255 }
                  ]
                  Item {
                    required property var modelData
                    width: imgCol.width
                    height: Style.space(40)
                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: root.rowPad
                      anchors.top: parent.top
                      text: parent.modelData.label
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      anchors.right: parent.right
                      anchors.rightMargin: root.rowPad
                      anchors.top: parent.top
                      text: String(root[parent.modelData.key])
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    WheelPassSlider {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.leftMargin: root.rowPad
                      anchors.rightMargin: root.rowPad
                      anchors.bottom: parent.bottom
                      bar: root.bar
                      minimum: parent.modelData.min
                      maximum: parent.modelData.max
                      step: 1
                      integer: true
                      value: root[parent.modelData.key]
                      onMoved: function(v) { root[parent.modelData.key] = Math.round(v) }
                      onReleased: function(v) { root.setControl(parent.modelData.key + "=" + Math.round(v)) }
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: 1
                  PanelSeparator {
                    foreground: root.fg
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: root.rowPad
                    anchors.rightMargin: root.rowPad
                  }
                }

                Item {
                  width: parent.width
                  height: Style.space(36)
                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: root.rowPad
                    anchors.right: backSw.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Backlight"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  ToggleSwitch {
                    id: backSw
                    anchors.right: parent.right
                    anchors.rightMargin: root.rowPad
                    anchors.verticalCenter: parent.verticalCenter
                    checked: root.backlight
                    foreground: root.fg
                    onToggled: {
                      root.backlight = !root.backlight
                      root.setControl("backlight=" + (root.backlight ? "on" : "off"))
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: Style.space(36)
                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: root.rowPad
                    anchors.right: flickPills.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Anti-flicker"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  Row {
                    id: flickPills
                    anchors.right: parent.right
                    anchors.rightMargin: root.rowPad
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)
                    Repeater {
                      model: [
                        { value: "off", label: "Off" },
                        { value: "50", label: "PAL 50 Hz" },
                        { value: "60", label: "NTSC 60 Hz" }
                      ]
                      Rectangle {
                        required property var modelData
                        width: flickLab.implicitWidth + Style.space(12)
                        height: Style.space(22)
                        radius: height / 2
                        color: root.flicker === modelData.value
                          ? Style.selectedFillFor(root.fg, Color.accent)
                          : "transparent"
                        Text {
                          id: flickLab
                          anchors.centerIn: parent
                          text: parent.modelData.label
                          color: root.fg
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            root.flicker = parent.modelData.value
                            root.setControl("anti-flicker=" + parent.modelData.value)
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: photoBtn.implicitHeight
            Button {
              id: photoBtn
              anchors.left: parent.left
              text: "4K photo"
              bordered: true
              foreground: root.fg
              enabled: !root.snapshotBusy
              onClicked: root.takePhoto()
            }
            Button {
              anchors.right: parent.right
              text: "Reset"
              foreground: root.fg
              enabled: !root.snapshotBusy
              onClicked: root.resetCamera()
            }
          }
        }
      }
    }
  }
}
