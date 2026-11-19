.pragma library

// Pure helpers for the Home Assistant plugin. Everything coming from Home
// Assistant or mDNS is untrusted: it is only ever rendered through
// Text.PlainText and passed to the helper as argv, never through a shell.

var ENTITY_RE = /^[a-z0-9_]+\.[a-z0-9_]+$/
var UUID_RE = /^[A-Za-z0-9_-]{1,64}$/
var PICTURE_RE = /^\/api\/camera_proxy\/[a-z0-9_]+\.[a-z0-9_]+\?token=[A-Za-z0-9_-]{1,128}$/
var MAX_ENTITIES = 16

var TOGGLE_DOMAINS = ["light", "switch", "fan", "input_boolean", "automation", "cover",
  "climate", "humidifier", "siren", "valve", "water_heater", "vacuum", "remote", "group", "lock"]
var PRESS_DOMAINS = ["button", "input_button", "scene", "script"]

var DOMAIN_GLYPHS = {
  light: "\u{f0335}", switch: "\u{f0a19}", fan: "\u{f0210}", input_boolean: "\u{f0a19}",
  automation: "\u{f0467}", cover: "\u{f111b}", media_player: "\u{f075a}", climate: "\u{f050f}",
  lock: "\u{f033e}", button: "\u{f0a43}", input_button: "\u{f0a43}", scene: "\u{f070e}",
  script: "\u{f0bc1}", person: "\u{f0004}", device_tracker: "\u{f034e}", binary_sensor: "\u{f0e26}",
  sun: "\u{f0599}", weather: "\u{f0590}", camera: "\u{f0100}", vacuum: "\u{f070d}",
  alarm_control_panel: "\u{f0498}", water_heater: "\u{f0f92}", humidifier: "\u{f058e}",
  valve: "\u{f1066}", update: "\u{f06b0}", calendar: "\u{f00ed}", todo: "\u{f0c52}"
}

var CLASS_GLYPHS = {
  temperature: "\u{f050f}", humidity: "\u{f058e}", power: "\u{f140b}", energy: "\u{f140b}",
  battery: "\u{f0079}", illuminance: "\u{f0335}", door: "\u{f081c}", window: "\u{f05b1}",
  motion: "\u{f0d91}", occupancy: "\u{f0d91}", presence: "\u{f0004}", carbon_dioxide: "\u{f07e4}",
  pressure: "\u{f029a}", moisture: "\u{f058c}", connectivity: "\u{f05a9}", plug: "\u{f06a5}",
  opening: "\u{f081c}", garage_door: "\u{f12d3}", smoke: "\u{f0238}", gas: "\u{f0238}",
  monetary: "\u{f01c1}", precipitation: "\u{f0597}", wind_speed: "\u{f059d}", pm25: "\u{f0590}"
}

var HA_GLYPH = "\u{f07d0}"
var SENSOR_GLYPH = "\u{f0d3d}"

function str(value, limit) {
  var text = value === undefined || value === null ? "" : String(value)
  text = text.replace(/[\r\n\t]+/g, " ")
  var max = limit || 120
  return text.length > max ? text.substring(0, max - 1) + "…" : text
}

function domainOf(entityId) {
  var id = String(entityId || "")
  var dot = id.indexOf(".")
  return dot > 0 ? id.substring(0, dot) : ""
}

function isEntityId(value) { return ENTITY_RE.test(String(value || "")) }
function isServerId(value) { return UUID_RE.test(String(value || "")) }

function canToggle(entityId) { return TOGGLE_DOMAINS.indexOf(domainOf(entityId)) >= 0 }
function canPress(entityId) { return PRESS_DOMAINS.indexOf(domainOf(entityId)) >= 0 }
function isLock(entityId) { return domainOf(entityId) === "lock" }
function isCamera(entityId) { return domainOf(entityId) === "camera" }
function isMedia(entityId) { return domainOf(entityId) === "media_player" }
// Locks get explicit Lock / Unlock buttons rather than an on/off switch.
function showSwitch(entityId) { return canToggle(entityId) && !isLock(entityId) }

// Camera still on the server, with a cache-busting tick so it refreshes.
function pictureUrl(serverUrl, entity, tick) {
  if (!entity || !entity.picture || !/^https?:\/\/[^\s]+$/.test(String(serverUrl || ""))) return ""
  return String(serverUrl).replace(/\/$/, "") + entity.picture + "&_=" + tick
}

// "Playing · 35%" for media players.
function volumeText(entity, fmt) {
  if (!entity || entity.volume < 0) return ""
  if (entity.muted) return "\u{f075f}"
  return (fmt ? fmt(Math.round(entity.volume * 100), 0) : Math.round(entity.volume * 100)) + "%"
}

function unavailable(state) {
  var s = String(state || "")
  return s === "" || s === "unavailable" || s === "unknown"
}

function isOn(entity) {
  if (!entity) return false
  var s = String(entity.state || "")
  if (domainOf(entity.entity_id) === "lock") return s === "unlocked" || s === "open"
  return ["on", "open", "opening", "playing", "home", "heat", "cool", "heat_cool", "auto", "dry", "fan_only", "cleaning"].indexOf(s) >= 0
}

function glyph(entity) {
  if (!entity) return SENSOR_GLYPH
  var domain = domainOf(entity.entity_id)
  if (domain === "lock") return isOn(entity) ? "\u{f0fc6}" : "\u{f033e}"
  if (domain === "light" && !isOn(entity)) return "\u{f0336}"
  if ((domain === "sensor" || domain === "binary_sensor") && CLASS_GLYPHS[entity.deviceClass]) return CLASS_GLYPHS[entity.deviceClass]
  return DOMAIN_GLYPHS[domain] || SENSOR_GLYPH
}

// "21.5 °C", "On", "Locked". `t` translates; `fmt` localizes numbers.
function stateText(entity, t, fmt) {
  if (!entity) return ""
  var s = String(entity.state || "")
  if (unavailable(s)) return t("state.unavailable")
  var n = Number(s)
  if (s.trim() !== "" && isFinite(n)) {
    var decimals = s.indexOf(".") >= 0 ? Math.min(2, s.length - s.indexOf(".") - 1) : 0
    var value = fmt ? fmt(n, decimals) : s
    return entity.unit ? value + " " + str(entity.unit, 16) : value
  }
  var key = "state." + s
  var translated = t(key)
  if (translated !== key) return translated
  var pretty = s.replace(/_/g, " ")
  return str(pretty.charAt(0).toUpperCase() + pretty.substring(1), 40)
}

// Settings arrays may have been hand-edited: keep only valid unique ids.
function cleanIds(list, limit) {
  var outList = []
  if (!Array.isArray(list)) return outList
  for (var i = 0; i < list.length && outList.length < (limit || MAX_ENTITIES); i++) {
    var id = String(list[i] || "")
    if (isEntityId(id) && outList.indexOf(id) < 0) outList.push(id)
  }
  return outList
}

function without(list, id) { return list.filter(function(x) { return x !== id }) }

function withAdded(list, id) {
  if (!isEntityId(id) || list.indexOf(id) >= 0 || list.length >= MAX_ENTITIES) return list
  return list.concat([id])
}

function moved(list, id, dy) {
  var i = list.indexOf(id)
  var j = i + dy
  if (i < 0 || j < 0 || j >= list.length) return list
  var next = list.slice()
  next[i] = list[j]
  next[j] = id
  return next
}

// Parse one JSON line or blob from the helper; null when it is not an object.
function parse(text) {
  try {
    var value = JSON.parse(String(text || ""))
    return value && typeof value === "object" && !Array.isArray(value) ? value : null
  } catch (e) {
    return null
  }
}

function cleanEntity(raw) {
  if (!raw || !isEntityId(raw.entity_id)) return null
  return {
    entity_id: String(raw.entity_id),
    name: str(raw.name || raw.entity_id, 80),
    state: str(raw.state, 60),
    unit: str(raw.unit, 16),
    deviceClass: str(raw.deviceClass, 32),
    source: str(raw.source, 16),
    volume: typeof raw.volume === "number" && raw.volume >= 0 && raw.volume <= 1 ? raw.volume : -1,
    muted: raw.muted === true,
    picture: PICTURE_RE.test(String(raw.picture || "")) ? String(raw.picture) : ""
  }
}

function cleanEntities(list, limit) {
  var outList = []
  if (!Array.isArray(list)) return outList
  for (var i = 0; i < list.length && outList.length < limit; i++) {
    var e = cleanEntity(list[i])
    if (e) outList.push(e)
  }
  return outList
}

function cleanServers(list) {
  var outList = []
  if (!Array.isArray(list)) return outList
  for (var i = 0; i < list.length && outList.length < 16; i++) {
    var s = list[i]
    if (!s || !isServerId(s.uuid)) continue
    var url = str(s.url, 200)
    if (!/^https?:\/\//.test(url)) continue
    outList.push({ uuid: String(s.uuid), name: str(s.name || s.uuid, 60), url: url, version: str(s.version, 40), loggedIn: s.loggedIn === true })
  }
  return outList
}

// Entities matching a filter, best matches first, chosen ones skipped.
function search(all, query, exclude, limit) {
  var q = String(query || "").toLowerCase().trim()
  if (q === "") return []
  var words = q.split(/\s+/)
  var scored = []
  for (var i = 0; i < all.length; i++) {
    var e = all[i]
    if (exclude.indexOf(e.entity_id) >= 0) continue
    var hay = (e.name + " " + e.entity_id).toLowerCase()
    var ok = true
    for (var w = 0; w < words.length; w++) if (hay.indexOf(words[w]) < 0) { ok = false; break }
    if (!ok) continue
    var name = e.name.toLowerCase()
    scored.push({ e: e, score: name.indexOf(q) === 0 ? 0 : (name.indexOf(q) >= 0 ? 1 : 2) })
  }
  scored.sort(function(a, b) { return a.score - b.score || (a.e.name < b.e.name ? -1 : 1) })
  return scored.slice(0, limit || 30).map(function(x) { return x.e })
}
