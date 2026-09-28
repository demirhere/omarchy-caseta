.pragma library

// Pure helpers for the Caseta panel and service. No QML types in here so the
// logic stays easy to reason about (and to test with plain node).

var GLYPH = {
  bulbOn: String.fromCodePoint(0xF06E8),       // md-lightbulb_on
  bulb: String.fromCodePoint(0xF0335),         // md-lightbulb
  bulbOutline: String.fromCodePoint(0xF0336),  // md-lightbulb_outline
  bulbOffline: String.fromCodePoint(0xF0E50),  // md-lightbulb_off_outline
  bulbGroup: String.fromCodePoint(0xF1253),    // md-lightbulb_group
  bulbGroupOff: String.fromCodePoint(0xF1254), // md-lightbulb_group_outline
  fan: String.fromCodePoint(0xF0210),          // md-fan
  fanOff: String.fromCodePoint(0xF081D),       // md-fan_off
  shade: String.fromCodePoint(0xF00AC),        // md-blinds
  shadeOpen: String.fromCodePoint(0xF1011),    // md-blinds_open
  scene: String.fromCodePoint(0xF03D8),        // md-palette
  pin: String.fromCodePoint(0xF0403),          // md-pin
  pinOutline: String.fromCodePoint(0xF0931)    // md-pin_outline
}

var FAN_SPEEDS = ["Off", "Low", "Medium", "MediumHigh", "High"]
var FAN_LABELS = ["Off", "Low", "Medium", "Med-High", "High"]

function isDimmable(device) {
  return !!device && (device.domain === "light" || device.domain === "cover")
}

function isLight(device) {
  return !!device && (device.domain === "light" || device.domain === "switch")
}

function fanIndex(device) {
  var i = FAN_SPEEDS.indexOf(device && device.fan ? device.fan : "Off")
  return i < 0 ? 0 : i
}

function isOn(device) {
  if (!device) return false
  if (device.domain === "fan") return fanIndex(device) > 0
  return device.level > 0
}

function onCount(devices) {
  var n = 0
  for (var i = 0; i < devices.length; i++) if (isLight(devices[i]) && isOn(devices[i])) n++
  return n
}

function lightCount(devices) {
  var n = 0
  for (var i = 0; i < devices.length; i++) if (isLight(devices[i])) n++
  return n
}

// What is on right now, in the shape the helper's "restore" command takes.
function onSnapshot(devices) {
  var out = []
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    if (isLight(d) && isOn(d)) out.push({ id: d.id, level: d.level })
  }
  return out
}

function glyph(device) {
  if (!device) return GLYPH.bulbOutline
  if (device.domain === "fan") return isOn(device) ? GLYPH.fan : GLYPH.fanOff
  if (device.domain === "cover") return device.level > 0 ? GLYPH.shadeOpen : GLYPH.shade
  return isOn(device) ? GLYPH.bulb : GLYPH.bulbOutline
}

function stateText(device) {
  if (!device) return ""
  if (device.level < 0 && device.domain !== "fan") return "—"
  if (device.domain === "fan") return FAN_LABELS[fanIndex(device)]
  if (device.domain === "switch") return device.level > 0 ? "On" : "Off"
  if (device.domain === "cover") return device.level <= 0 ? "Closed" : (device.level >= 100 ? "Open" : device.level + "%")
  return device.level > 0 ? device.level + "%" : "Off"
}

// [{area, devices: [...]}] preserving the helper's area/name ordering.
function groupByArea(devices) {
  var groups = []
  var index = {}
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    var key = d.area || "Other"
    if (!(key in index)) {
      index[key] = groups.length
      groups.push({ area: key, devices: [] })
    }
    groups[index[key]].devices.push(d)
  }
  return groups
}

function withDevice(devices, id, patch) {
  var next = []
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    if (d.id !== id) { next.push(d); continue }
    var copy = {}
    for (var k in d) copy[k] = d[k]
    for (var p in patch) copy[p] = patch[p]
    next.push(copy)
  }
  return next
}

function findDevice(devices, id) {
  for (var i = 0; i < devices.length; i++) if (devices[i].id === id) return devices[i]
  return null
}

// Match a device for IPC/keybindings: id, "Area Name", or a unique name.
function matchDevice(devices, query) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return null
  var byName = []
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    if (d.id === q) return d
    var full = ((d.area ? d.area + " " : "") + d.name).toLowerCase()
    if (full === q) return d
    if (d.name.toLowerCase() === q) byName.push(d)
  }
  if (byName.length === 1) return byName[0]
  for (var j = 0; j < devices.length; j++) {
    var f = ((devices[j].area ? devices[j].area + " " : "") + devices[j].name).toLowerCase()
    if (f.indexOf(q) !== -1) return devices[j]
  }
  return null
}

function matchScene(scenes, query) {
  var q = String(query || "").trim().toLowerCase()
  for (var i = 0; i < scenes.length; i++)
    if (scenes[i].id === q || scenes[i].name.toLowerCase() === q) return scenes[i]
  for (var j = 0; j < scenes.length; j++)
    if (scenes[j].name.toLowerCase().indexOf(q) !== -1) return scenes[j]
  return null
}

function statusLine(state, onCount, lightCount, message) {
  if (state === "connected") {
    if (lightCount === 0) return "No lights found"
    if (onCount === 0) return "All off"
    return onCount === lightCount ? "All on" : onCount + " on"
  }
  if (state === "connecting") return "Connecting"
  if (state === "unpaired") return "Not paired"
  if (state === "not-installed") return "Setup needed"
  if (state === "error") return "Bridge error"
  return "Starting"
}

function clampLevel(level) {
  return Math.max(0, Math.min(100, Math.round(level)))
}
