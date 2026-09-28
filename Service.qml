import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Shell-wide singleton (kind: "service"). Owns the one long-lived helper
// process that holds the LEAP connection to the Caseta bridge, so every bar
// instance (one per monitor) reads the same state over a single connection.
//
// Protocol with bin/caseta_bridge.py: JSON lines both ways. The helper emits
// status/snapshot/update/error events; we write {cmd, ...} commands.
Item {
  id: root

  // Qt.resolvedUrl percent-encodes the path; decode before it goes into argv.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")

  // "starting" | "not-installed" | "unpaired" | "connecting" | "connected" | "error"
  property string bridgeState: "starting"
  property string message: ""
  property string host: ""
  property var devices: []
  property var scenes: []
  property string lastError: ""

  // Lights that were on before the last "all off", so the same switch can
  // bring them back.
  property var restorable: []

  readonly property bool connected: bridgeState === "connected"
  readonly property bool needsSetup: bridgeState === "unpaired" || bridgeState === "not-installed"
  readonly property int onCount: Model.onCount(devices)
  readonly property int lightCount: Model.lightCount(devices)
  readonly property bool anyOn: onCount > 0
  readonly property string statusLine: Model.statusLine(bridgeState, onCount, lightCount, message)

  property int _backoff: 0
  property bool _manualRestart: false
  property string _stderrTail: ""

  // ---------------------------------------------------------------- commands

  function send(command) {
    if (!helper.running) return false
    helper.write(JSON.stringify(command) + "\n")
    return true
  }

  function device(id) {
    return Model.findDevice(devices, id)
  }

  function setLevel(id, level) {
    var value = Model.clampLevel(level)
    devices = Model.withDevice(devices, id, { level: value })
    send({ cmd: "set", id: id, level: value })
  }

  function setFan(id, index) {
    var i = Math.max(0, Math.min(Model.FAN_SPEEDS.length - 1, Math.round(index)))
    devices = Model.withDevice(devices, id, { fan: Model.FAN_SPEEDS[i] })
    send({ cmd: "fan", id: id, speed: Model.FAN_SPEEDS[i] })
  }

  function toggleDevice(id) {
    var d = device(id)
    if (!d) return
    if (d.domain === "fan") {
      devices = Model.withDevice(devices, id, { fan: Model.isOn(d) ? "Off" : "Medium" })
    } else {
      var on = d.domain === "light" ? (d.last || 100) : 100
      devices = Model.withDevice(devices, id, { level: Model.isOn(d) ? 0 : on })
    }
    send({ cmd: "toggle", id: id })
  }

  function turnOn(id) {
    var d = device(id)
    if (!d) return
    if (!Model.isOn(d)) toggleDevice(id)
  }

  function turnOff(id) {
    var d = device(id)
    if (!d) return
    if (Model.isOn(d)) toggleDevice(id)
  }

  function allOff() {
    var snapshot = Model.onSnapshot(devices)
    if (snapshot.length === 0) return
    restorable = snapshot
    var next = devices
    for (var i = 0; i < snapshot.length; i++) next = Model.withDevice(next, snapshot[i].id, { level: 0 })
    devices = next
    send({ cmd: "all-off" })
  }

  function restore() {
    if (restorable.length === 0) return
    var next = devices
    for (var i = 0; i < restorable.length; i++)
      next = Model.withDevice(next, restorable[i].id, { level: restorable[i].level })
    devices = next
    send({ cmd: "restore", devices: restorable })
    restorable = []
  }

  function activateScene(id) {
    send({ cmd: "scene", id: id })
  }

  function refresh() {
    send({ cmd: "refresh" })
  }

  // Restart the helper now (after pairing, or from the panel's Retry).
  function reconnect() {
    _backoff = 0
    restartTimer.stop()
    if (helper.running) {
      _manualRestart = true
      helper.running = false
    } else {
      startHelper()
    }
  }

  function startHelper() {
    if (!connected) bridgeState = "starting"
    _stderrTail = ""
    helper.running = true
  }

  // ---------------------------------------------------------------- events

  function handleLine(line) {
    var event
    try { event = JSON.parse(line) } catch (e) { return }
    if (!event || typeof event !== "object") return

    if (event.event === "status") {
      bridgeState = String(event.state || "error")
      message = String(event.message || "")
      if (event.host) host = String(event.host)
      if (bridgeState === "connected") _backoff = 0
    } else if (event.event === "snapshot") {
      devices = event.devices instanceof Array ? event.devices : []
      scenes = event.scenes instanceof Array ? event.scenes : []
      if (event.host) host = String(event.host)
    } else if (event.event === "update" && event.device) {
      var d = event.device
      if (device(d.id)) devices = Model.withDevice(devices, d.id, d)
      else refresh()
    } else if (event.event === "error") {
      lastError = String(event.message || "Command failed")
      errorTimer.restart()
    }
  }

  function handleExit(code) {
    if (_manualRestart) {
      _manualRestart = false
      startHelper()
      return
    }
    // 3 = not paired, 4 = venv missing: the helper already said so, and
    // retrying will not help until setup runs (which calls reconnect()).
    if (code === 3 || code === 4) return
    if (bridgeState !== "error") {
      bridgeState = "error"
      message = _stderrTail !== "" ? _stderrTail : "Helper exited (" + code + ")"
    }
    var delays = [2000, 5000, 15000, 30000]
    restartTimer.interval = delays[Math.min(_backoff, delays.length - 1)]
    _backoff++
    restartTimer.restart()
  }

  Process {
    id: helper
    command: [root.pluginDir + "/bin/caseta-bridge", "daemon"]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(data) { root.handleLine(data) } }
    stderr: SplitParser {
      onRead: function(data) {
        var text = String(data).trim()
        if (text !== "") root._stderrTail = text
      }
    }
    onExited: function(exitCode) { root.handleExit(exitCode) }
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: root.startHelper()
  }

  Timer {
    id: errorTimer
    interval: 6000
    repeat: false
    onTriggered: root.lastError = ""
  }

  Component.onCompleted: startHelper()

  // ---------------------------------------------------------------- IPC
  //
  //   omarchy-shell caseta toggle "Office Lamp"
  //   omarchy-shell caseta set "Kitchen" 40
  //   omarchy-shell caseta scene "Movie Night"
  //   omarchy-shell caseta allOff
  //
  // Devices match by id, "Area Name", a unique name, or a substring.
  IpcHandler {
    target: "caseta"

    function toggle(name: string): string {
      var d = Model.matchDevice(root.devices, name)
      if (!d) return "unknown device"
      root.toggleDevice(d.id)
      return "ok"
    }

    function turnOn(name: string): string {
      var d = Model.matchDevice(root.devices, name)
      if (!d) return "unknown device"
      root.turnOn(d.id)
      return "ok"
    }

    function turnOff(name: string): string {
      var d = Model.matchDevice(root.devices, name)
      if (!d) return "unknown device"
      root.turnOff(d.id)
      return "ok"
    }

    function set(name: string, level: int): string {
      var d = Model.matchDevice(root.devices, name)
      if (!d) return "unknown device"
      if (d.domain === "fan") root.setFan(d.id, Math.round(level / 25))
      else root.setLevel(d.id, level)
      return "ok"
    }

    function scene(name: string): string {
      var s = Model.matchScene(root.scenes, name)
      if (!s) return "unknown scene"
      root.activateScene(s.id)
      return "ok"
    }

    function allOff(): string {
      root.allOff()
      return "ok"
    }

    function restore(): string {
      root.restore()
      return "ok"
    }

    function list(): string {
      return JSON.stringify({ state: root.bridgeState, devices: root.devices, scenes: root.scenes })
    }

    function status(): string {
      return root.bridgeState + (root.message !== "" ? ": " + root.message : "")
    }

    function reconnect(): string {
      root.reconnect()
      return "ok"
    }
  }
}
