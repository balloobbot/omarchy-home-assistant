import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Runs ha.py: mDNS discovery, OAuth login, suggestions, live state stream and
// toggles. Every argument goes through argv; nothing is interpolated into a shell.
Item {
  id: root

  property string serverId: ""
  property var entityIds: []
  // The panel asks for suggestions only while it is open.
  property bool wantSuggestions: false

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string helperPath: pluginDir + "/ha.py"

  property var servers: []
  property bool discovering: false
  property bool discovered: false

  property string loginServerId: ""
  readonly property bool loggingIn: loginProcess.running

  property bool connected: false
  property bool authFailed: false
  property string lastError: ""
  // entity_id -> entity
  property var states: ({})

  property var suggestions: []
  property var allEntities: []
  property bool suggesting: false
  property string suggestionsFor: ""

  property var pending: ({})

  signal loggedIn(string uuid, string url)

  function helper(args) { return ["python3", "-I", helperPath].concat(args) }

  function discover() {
    if (discoverProcess.running) return
    discovering = true
    discoverProcess.command = helper(["discover"])
    discoverProcess.running = true
  }

  function login(server) {
    if (!server || !Model.isServerId(server.uuid) || loginProcess.running) return
    loginServerId = server.uuid
    lastError = ""
    loginProcess.command = helper(["login", server.uuid, server.url, server.name])
    loginProcess.running = true
  }

  function cancelLogin() { if (loginProcess.running) loginProcess.signal(15) }

  function logout(uuid) {
    if (!Model.isServerId(uuid)) return
    Quickshell.execDetached(helper(["logout", uuid]))
    if (uuid === serverId) {
      authFailed = true
      connected = false
      watchProcess.running = false
    }
    Qt.callLater(discover)
  }

  function loadSuggestions(force) {
    if (!Model.isServerId(serverId) || suggestProcess.running) return
    if (!force && suggestionsFor === serverId && allEntities.length > 0) return
    suggesting = true
    suggestProcess.forServer = serverId
    suggestProcess.command = helper(["suggest", serverId])
    suggestProcess.running = true
  }

  function toggle(entityId) {
    if (!Model.isServerId(serverId) || !Model.isEntityId(entityId)) return
    if (!Model.canToggle(entityId) && !Model.canPress(entityId)) return
    var p = Object.assign({}, pending)
    p[entityId] = true
    pending = p
    toggleComponent.createObject(root, { entityId: entityId, command: helper(["toggle", serverId, entityId]) })
  }

  // volume_up / volume_down / volume_mute for media players, lock / unlock for locks.
  function action(entityId, service) {
    if (!Model.isServerId(serverId) || !Model.isEntityId(entityId)) return
    var allowed = Model.isMedia(entityId) ? ["volume_up", "volume_down", "volume_mute"]
      : Model.isLock(entityId) ? ["lock", "unlock"] : []
    if (allowed.indexOf(service) < 0) return
    var p = Object.assign({}, pending)
    p[entityId] = true
    pending = p
    toggleComponent.createObject(root, { entityId: entityId, command: helper(["action", serverId, entityId, service]) })
  }

  function restartWatch() {
    watchProcess.running = false
    states = ({})
    connected = false
    if (!Model.isServerId(serverId) || entityIds.length === 0 || authFailed) return
    watchRestart.restart()
  }

  onServerIdChanged: {
    authFailed = false
    lastError = ""
    suggestions = []
    allEntities = []
    suggestionsFor = ""
    restartWatch()
    if (wantSuggestions) loadSuggestions(true)
  }
  onEntityIdsChanged: restartWatch()
  onWantSuggestionsChanged: if (wantSuggestions) loadSuggestions(false)

  Timer {
    id: watchRestart
    interval: 150
    onTriggered: {
      if (!Model.isServerId(root.serverId) || root.entityIds.length === 0) return
      watchProcess.command = root.helper(["watch", root.serverId].concat(root.entityIds))
      watchProcess.running = true
    }
  }

  Process {
    id: discoverProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.parse(text)
        if (result && result.servers) root.servers = Model.cleanServers(result.servers)
        else if (result && result.error) root.lastError = Model.str(result.error, 200)
      }
    }
    onExited: { root.discovering = false; root.discovered = true }
  }

  Process {
    id: loginProcess
    stdout: SplitParser {
      onRead: function(line) {
        var msg = Model.parse(line)
        if (!msg) return
        if (msg.error) root.lastError = Model.str(msg.error, 200)
        else if (msg.type === "done" && Model.isServerId(msg.uuid)) {
          root.lastError = ""
          if (msg.uuid === root.serverId) {
            root.authFailed = false
            root.restartWatch()
            root.loadSuggestions(true)
          }
          root.loggedIn(String(msg.uuid), Model.str(msg.url, 200))
        }
      }
    }
    onExited: { root.loginServerId = ""; root.discover() }
  }

  Process {
    id: suggestProcess
    property string forServer: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (suggestProcess.forServer !== root.serverId) return
        var result = Model.parse(text)
        if (!result) { root.lastError = "Could not read suggestions"; return }  // i18n: ignore
        if (result.error) {
          root.lastError = Model.str(result.error, 200)
          if (result.code === "auth") root.authFailed = true
          return
        }
        root.suggestions = Model.cleanEntities(result.suggestions, 40)
        root.allEntities = Model.cleanEntities(result.entities, 3000)
        root.suggestionsFor = root.serverId
      }
    }
    onExited: root.suggesting = false
  }

  Process {
    id: watchProcess
    stdout: SplitParser {
      onRead: function(line) {
        var msg = Model.parse(line)
        if (!msg) return
        if (msg.type === "status") {
          root.connected = msg.connected === true
          if (msg.connected) root.lastError = ""
          else root.lastError = Model.str(msg.error, 200)
          if (msg.code === "auth") root.authFailed = true
        } else if (msg.type === "states") {
          var list = Model.cleanEntities(msg.states, 32)
          var next = ({})
          for (var i = 0; i < list.length; i++) next[list[i].entity_id] = list[i]
          root.states = next
          root.pending = ({})
        }
      }
    }
    onExited: function(exitCode) {
      root.connected = false
      // The helper reconnects by itself; an exit means auth failed or it crashed.
      if (exitCode !== 2 && running === false && root.entityIds.length > 0 && !root.authFailed) crashRestart.restart()
    }
  }

  Timer {
    id: crashRestart
    interval: 15000
    onTriggered: root.restartWatch()
  }

  Component {
    id: toggleComponent
    Process {
      id: proc
      property string entityId: ""
      running: true
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var result = Model.parse(text)
          if (result && result.error) {
            root.lastError = Model.str(result.error, 200)
            if (result.code === "auth") root.authFailed = true
          }
        }
      }
      onExited: {
        // The state stream clears pending on the next update; clear it here
        // too in case nothing changed.
        clearPending.entityId = proc.entityId
        clearPending.restart()
        proc.destroy()
      }
    }
  }

  Timer {
    id: clearPending
    property string entityId: ""
    interval: 1500
    onTriggered: {
      var p = Object.assign({}, root.pending)
      delete p[entityId]
      root.pending = p
    }
  }
}
