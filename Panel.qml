import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button + keyboard-driven panel for Lutron Caseta lights. All bridge
// state lives in Service.qml (one connection shared by every monitor's bar);
// this file only renders it and forwards user actions.
//
// Bar:   left click opens the panel, right click toggles the pinned light (or
//        all lights off / back on when nothing is pinned), scroll dims the
//        pinned light.
// Panel: j/k move, h/l dim, 1-9/0 jump to 10-90/100%, Enter toggles,
//        p pins, a all off/restore, r reconnects, Esc closes.
Panel {
  id: root
  moduleName: "io.github.demirhere.caseta"
  manageIpc: false

  readonly property var service: bar?.shell?.serviceFor("io.github.demirhere.caseta") ?? null
  readonly property var devices: service ? service.devices : []
  readonly property var scenes: service ? service.scenes : []
  readonly property bool connected: !!service && service.connected
  readonly property bool needsSetup: !service || service.needsSetup
  readonly property bool anyOn: !!service && service.anyOn
  readonly property bool canRestore: !!service && service.restorable.length > 0
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")

  readonly property string pinnedId: String(setting("pinned", ""))
  readonly property var pinnedDevice: pinnedId !== "" ? Model.findDevice(devices, pinnedId) : null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // Repeaters are fed from a structure-only model (areas + device ids) that
  // changes only when the device list itself does. Rebuilding delegates on
  // every level update would destroy a slider in the middle of a drag.
  readonly property string layoutKey: {
    var parts = []
    for (var i = 0; i < devices.length; i++) parts.push(devices[i].area + "\u0001" + devices[i].id)
    parts.push("\u0002")
    for (var j = 0; j < scenes.length; j++) parts.push(scenes[j].id + "\u0001" + scenes[j].name)
    return parts.join("\u0003")
  }
  property var layoutGroups: []
  property var layoutScenes: []
  onLayoutKeyChanged: rebuildLayout()
  Component.onCompleted: rebuildLayout()

  function rebuildLayout() {
    var groups = Model.groupByArea(devices)
    var out = []
    for (var i = 0; i < groups.length; i++) {
      var ids = []
      for (var j = 0; j < groups[i].devices.length; j++) ids.push(groups[i].devices[j].id)
      out.push({ area: groups[i].area, ids: ids })
    }
    layoutGroups = out
    var sc = []
    for (var k = 0; k < scenes.length; k++) sc.push({ id: scenes[k].id, name: scenes[k].name })
    layoutScenes = sc
  }

  // ---------------------------------------------------------------- cursor
  //
  // One flat list of cursor targets in visual order. Keys, not indices, so a
  // snapshot that reorders rows keeps the cursor on the same light.
  property string cursorKey: "header"
  property bool cursorActive: false
  property real lastActivateAt: 0

  readonly property var targets: {
    var list = ["header"]
    if (!connected) {
      list.push("action")
      return list
    }
    for (var i = 0; i < layoutGroups.length; i++)
      for (var j = 0; j < layoutGroups[i].ids.length; j++) list.push("d:" + layoutGroups[i].ids[j])
    for (var k = 0; k < layoutScenes.length; k++) list.push("s:" + layoutScenes[k].id)
    return list
  }

  readonly property var cursorDevice: cursorKey.indexOf("d:") === 0
    ? Model.findDevice(devices, cursorKey.slice(2)) : null

  function moveCursor(delta) {
    var i = targets.indexOf(cursorKey)
    if (i < 0) i = 0
    cursorKey = targets[Math.max(0, Math.min(targets.length - 1, i + delta))]
  }

  function hover(key) {
    cursorActive = true
    cursorKey = key
  }

  function activateCursor() {
    if (cursorKey === "header") heroToggle()
    else if (cursorKey === "action") setupAction()
    else if (cursorKey.indexOf("d:") === 0) service.toggleDevice(cursorKey.slice(2))
    else if (cursorKey.indexOf("s:") === 0) service.activateScene(cursorKey.slice(2))
  }

  function adjustCursor(dx) {
    var d = cursorDevice
    if (!d || !service) return
    if (d.domain === "fan") service.setFan(d.id, Model.fanIndex(d) + dx)
    else if (d.domain === "switch") { if ((dx > 0) !== Model.isOn(d)) service.toggleDevice(d.id) }
    else service.setLevel(d.id, Math.max(0, d.level) + dx * 10)
  }

  function jumpCursor(digit) {
    var d = cursorDevice
    if (!d || !service) return
    var level = digit === 0 ? 100 : digit * 10
    if (d.domain === "fan") service.setFan(d.id, Math.round(level / 25))
    else if (Model.isDimmable(d)) service.setLevel(d.id, level)
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var margin = 6
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    var top = item.mapToItem(flick.contentItem || flick, 0, 0).y
    var bottom = top + (item.height || 0)
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, Math.min(maxY, top - margin))
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = Math.max(0, Math.min(maxY, bottom + margin - flick.height))
  }

  onOpenedChanged: {
    if (!opened) return
    cursorKey = "header"
    cursorActive = false
    // Pick up a pairing done from a terminal, or retry a failed bridge.
    if (service && (service.needsSetup || service.bridgeState === "error")) service.reconnect()
  }

  // ---------------------------------------------------------------- actions

  function heroToggle() {
    if (!service) return
    if (anyOn) service.allOff()
    else service.restore()
  }

  function setupAction() {
    if (!service) return
    if (service.needsSetup) {
      Quickshell.execDetached([
        "omarchy-launch-floating-terminal-with-presentation",
        "'" + pluginDir + "/bin/caseta-setup'"
      ])
      close()
    } else {
      service.reconnect()
    }
  }

  function quickToggle() {
    if (!service || !connected) { toggle(); return }
    if (pinnedDevice) service.toggleDevice(pinnedDevice.id)
    else heroToggle()
  }

  property real wheelAccumulator: 0

  function wheelPinned(delta) {
    var d = pinnedDevice
    if (!d || !service || !connected) return
    var wheel = Util.wheelSteps(wheelAccumulator, delta)
    wheelAccumulator = wheel.remainder
    if (wheel.steps === 0) return
    var value
    if (d.domain === "fan") {
      value = Math.max(0, Math.min(4, Model.fanIndex(d) + wheel.steps))
      service.setFan(d.id, value)
      value = value * 25
    } else if (d.domain === "switch") {
      if ((wheel.steps > 0) !== Model.isOn(d)) service.toggleDevice(d.id)
      value = wheel.steps > 0 ? 100 : 0
    } else {
      value = Model.clampLevel(Math.max(0, d.level) + wheel.steps * 5)
      service.setLevel(d.id, value)
    }
    if (bar && bar.shell)
      bar.shell.summon("omarchy.osd", JSON.stringify({ icon: Model.glyph(Model.findDevice(devices, d.id)), value: value }))
  }

  function togglePin(id) {
    persistSettings({ pinned: pinnedId === id ? "" : id })
  }

  // Same pattern as omarchy.clock: apply locally so the panel redraws on the
  // click, then write the widget's shell.json entry.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  readonly property string barGlyph: {
    if (!connected) return Model.GLYPH.bulbOffline
    if (pinnedDevice) return Model.glyph(pinnedDevice)
    return anyOn ? Model.GLYPH.bulb : Model.GLYPH.bulbOutline
  }

  readonly property string barTooltip: {
    if (!service) return "Lights"
    if (!connected) return "Lights · " + service.statusLine
    var text = "Lights · " + service.statusLine
    if (pinnedDevice) text += "\n" + pinnedDevice.name + " · " + Model.stateText(pinnedDevice)
    return text
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph
    dimmed: !root.connected
    tooltipText: root.barTooltip
    onPressed: function(b) {
      if (b === Qt.RightButton) root.quickToggle()
      else root.toggle()
    }
    onWheelMoved: function(delta) { root.wheelPinned(delta) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustCursor(dx)
      }
      onActivateRequested: {
        if (!root.cursorActive) { root.cursorActive = true; return }
        // A held Enter/Space auto-repeats; with real lights that would flap a
        // light or re-run a scene many times a second. Act on the first press
        // and swallow presses that keep arriving in quick succession.
        var now = Date.now()
        var repeat = now - root.lastActivateAt < 350
        root.lastActivateAt = now
        if (!repeat) root.activateCursor()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t >= "0" && t <= "9") { root.cursorActive = true; root.jumpCursor(Number(t)); return }
        var key = t.toLowerCase()
        if (key === "p" && root.cursorDevice) root.togglePin(root.cursorDevice.id)
        else if (key === "a") root.heroToggle()
        else if (key === "r" && root.service) root.service.reconnect()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: bulb · Lights / status · all-off switch ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, masterSwitch.implicitHeight)

            Text {
              id: heroIcon
              text: !root.connected ? Model.GLYPH.bulbOffline
                : (root.anyOn ? Model.GLYPH.bulbGroup : Model.GLYPH.bulbGroupOff)
              color: root.fg
              opacity: root.anyOn ? 1.0 : 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            // On while anything is lit. Switching it off turns every light
            // off and remembers them; switching it back on restores exactly
            // those lights at their old levels.
            ToggleSwitch {
              id: masterSwitch
              visible: root.connected
              checked: root.anyOn
              busy: !root.anyOn && !root.canRestore
              opacity: busy ? 0.4 : 1.0
              hasCursor: root.cursorActive && root.cursorKey === "header"
              foreground: root.fg
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onHovered: function(on) { if (on) root.hover("header") }
              onToggled: root.heroToggle()

              PanelToolTip {
                visible: masterSwitch.containsMouse
                text: root.anyOn ? "Turn all lights off" : (root.canRestore ? "Turn those lights back on" : "All lights are off")
                fontFamily: root.fontFamily
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: masterSwitch.visible ? masterSwitch.width + Style.space(12) : 0
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: "Lights"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: (root.service ? root.service.statusLine : "Starting").toUpperCase()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }
          }

          Text {
            width: parent.width
            visible: !!root.service && root.service.lastError !== ""
            text: root.service ? root.service.lastError : ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---------- Not connected: explain and offer the fix ----------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: !root.connected

            PanelSeparator { foreground: root.fg }

            Text {
              width: parent.width
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              text: {
                var s = root.service
                if (!s) return "Enable the Caseta service to use this widget."
                if (s.needsSetup)
                  return "Pair with your Caseta Smart Bridge. Setup opens a terminal, finds the bridge and asks you to press the small black button on its back."
                if (s.bridgeState === "connecting")
                  return "Connecting to the bridge" + (s.host !== "" ? " at " + s.host : "") + "…" + (s.message !== "" ? "\n" + s.message : "")
                if (s.bridgeState === "error") return s.message !== "" ? s.message : "The bridge helper stopped."
                return "Starting…"
              }
            }

            Button {
              id: actionButton
              visible: !!root.service && root.service.bridgeState !== "starting"
              text: root.needsSetup ? "Pair bridge" : "Reconnect"
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              hasCursor: root.cursorActive && root.cursorKey === "action"
              onHovered: function(on) { if (on) root.hover("action") }
              onClicked: root.setupAction()
            }
          }

          // ---------- Rooms ----------
          Repeater {
            model: root.connected ? root.layoutGroups : []

            Column {
              id: group
              required property var modelData
              width: panelColumn.width
              spacing: Style.space(6)

              PanelSeparator { foreground: root.fg }

              PanelSectionHeader {
                text: group.modelData.area.toUpperCase()
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Repeater {
                model: group.modelData.ids

                DeviceRow {
                  required property var modelData
                  width: group.width
                  deviceId: modelData
                }
              }
            }
          }

          // ---------- Scenes ----------
          PanelSeparator {
            visible: root.connected && root.layoutScenes.length > 0
            foreground: root.fg
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.connected && root.layoutScenes.length > 0

            PanelSectionHeader {
              text: "SCENES"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.connected ? root.layoutScenes : []

              SceneRow {
                required property var modelData
                width: panelColumn.width
                sceneId: modelData.id
                sceneName: modelData.name
              }
            }
          }

          Text {
            width: parent.width
            visible: root.connected && root.layoutGroups.length === 0
            text: "The bridge reported no lights, switches or fans."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- rows

  // One light, switch, fan or shade. Reads its live state by id so level
  // updates re-bind in place instead of recreating the row.
  component DeviceRow: CursorSurface {
    id: row
    required property string deviceId

    readonly property var device: Model.findDevice(root.devices, deviceId)
    readonly property string key: "d:" + deviceId
    readonly property bool on: Model.isOn(device)
    readonly property bool pinned: root.pinnedId === deviceId
    readonly property bool hasSlider: !!device && device.domain !== "switch"

    hasCursor: root.cursorActive && root.cursorKey === key
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(row)
    foreground: root.fg
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: rowColumn.implicitHeight + Style.spacing.xl

    Column {
      id: rowColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(2)

      Item {
        width: parent.width
        implicitHeight: Math.max(rowIcon.implicitHeight, rowSwitch.visible ? rowSwitch.implicitHeight : 0, pinButton.implicitHeight)

        Text {
          id: rowIcon
          text: Model.glyph(row.device)
          color: root.fg
          opacity: row.on ? 1.0 : 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.service.toggleDevice(row.deviceId)
          }
        }

        Text {
          text: row.device ? row.device.name : ""
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.on
          elide: Text.ElideRight
          anchors.left: rowIcon.right
          anchors.leftMargin: Style.space(8)
          anchors.right: trailing.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        Row {
          id: trailing
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          PanelActionButton {
            id: pinButton
            visible: row.pinned || row.hasCursor
            iconText: row.pinned ? Model.GLYPH.pin : Model.GLYPH.pinOutline
            tooltipText: row.pinned ? "Unpin from bar" : "Pin to bar (right-click toggles, scroll dims)"
            foreground: row.pinned ? root.fg : root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.togglePin(row.deviceId)
          }

          Text {
            visible: row.hasSlider
            text: Model.stateText(row.device)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            width: Style.space(58)
            horizontalAlignment: Text.AlignRight
            anchors.verticalCenter: parent.verticalCenter
          }

          ToggleSwitch {
            id: rowSwitch
            visible: !row.hasSlider
            checked: row.on
            interactive: true
            cursorRing: false
            trackHeight: Math.max(16, Math.round(Style.spacing.controlHeight * 0.42))
            foreground: root.fg
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.service.toggleDevice(row.deviceId)
          }
        }
      }

      PanelSlider {
        id: slider
        visible: row.hasSlider
        bar: root.bar
        width: parent.width
        readonly property bool fan: !!row.device && row.device.domain === "fan"
        minimum: 0
        maximum: fan ? 4 : 100
        step: fan ? 1 : 5
        integer: true
        tickCount: fan ? 5 : 0
        value: fan ? Model.fanIndex(row.device) : Math.max(0, row.device ? row.device.level : 0)
        opacity: row.on ? 1.0 : 0.5
        onMoved: function(v) {
          if (fan) root.service.setFan(row.deviceId, v)
          else root.service.setLevel(row.deviceId, v)
        }
        onRightClicked: root.service.toggleDevice(row.deviceId)
      }
    }

    // Hover moves the panel cursor; clicks fall through to the controls.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: if (containsMouse) root.hover(row.key)
    }
  }

  component SceneRow: CursorSurface {
    id: sceneRow
    required property string sceneId
    required property string sceneName
    readonly property string key: "s:" + sceneId

    hasCursor: root.cursorActive && root.cursorKey === key
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sceneRow)
    foreground: root.fg
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: sceneInner.implicitHeight + Style.spacing.xl

    Row {
      id: sceneInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: Model.GLYPH.scene
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: sceneRow.sceneName
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(30)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.hover(sceneRow.key)
      onClicked: root.service.activateScene(sceneRow.sceneId)
    }
  }
}
