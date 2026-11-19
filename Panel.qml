import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// A few Home Assistant entities in the bar, and a panel to toggle them, pick
// a server found over mDNS, and add entities suggested from the default
// dashboard's favorites and Home Assistant's common controls.
Panel {
  id: root
  moduleName: "paulus.home-assistant"
  ipcTarget: "paulus.home-assistant"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---- settings (this widget's shell.json entry)
  readonly property var server: {
    var s = setting("server", null)
    return s && Model.isServerId(s.uuid) ? { uuid: String(s.uuid), name: Model.str(s.name || "", 60), url: Model.str(s.url || "", 200) } : null
  }
  readonly property var entityIds: Model.cleanIds(setting("entities", []))

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) {
      if (values[key] === undefined) delete entry[key]
      else entry[key] = values[key]
    }
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function chooseServer(s) {
    if (!s) return
    if (!s.loggedIn) { ha.login(s); return }
    var same = server && server.uuid === s.uuid
    persistSettings({ server: { uuid: s.uuid, name: s.name, url: s.url } })
    if (same) { mode = entityIds.length === 0 ? "add" : "main"; return }
    persistSettings({ entities: [], barEntities: undefined, barMax: undefined })
    mode = "add"
  }

  function addEntity(id) {
    var next = Model.withAdded(entityIds, id)
    if (next === entityIds) return
    persistSettings({ entities: next, barEntities: undefined, barMax: undefined })
  }

  function removeEntity(id) {
    persistSettings({ entities: Model.without(entityIds, id), barEntities: undefined, barMax: undefined })
  }

  // Camera stills refresh every few seconds, only while the panel is open.
  property int pictureTick: 0
  Timer {
    interval: 5000
    repeat: true
    running: root.opened && root.effectiveMode === "main"
    onTriggered: root.pictureTick++
  }

  function moveEntity(id, dy) { persistSettings({ entities: Model.moved(entityIds, id, dy) }) }

  // ---- service
  Service {
    id: ha
    serverId: root.server ? root.server.uuid : ""
    entityIds: root.entityIds
    wantSuggestions: root.opened && root.mode === "add"
    onLoggedIn: function(uuid, url) {
      for (var i = 0; i < ha.servers.length; i++) {
        if (ha.servers[i].uuid === uuid) {
          var s = Object.assign({}, ha.servers[i], { loggedIn: true, url: url || ha.servers[i].url })
          root.chooseServer(s)
          return
        }
      }
    }
  }

  // ---- view state
  // "main": chosen entities; "servers": the mDNS picker; "add": suggestions.
  property string mode: "main"
  property string filterText: ""
  property int cursor: -1
  readonly property bool cursorActive: cursor >= 0

  readonly property var t: function(key) { return strings.t(key) }
  readonly property var fmt: function(n, d) { return Commons.I18n.formatNumber(n, d) }

  function entity(id) {
    var e = ha.states[id]
    if (e) return e
    for (var i = 0; i < ha.allEntities.length; i++) if (ha.allEntities[i].entity_id === id) return ha.allEntities[i]
    return { entity_id: id, name: id, state: "", unit: "", deviceClass: "" }
  }

  readonly property string effectiveMode: !server ? "servers" : mode

  readonly property var rows: {
    var out = []
    var i
    if (effectiveMode === "servers") {
      out.push({ kind: "header", text: strings.t("servers.header") })
      for (i = 0; i < ha.servers.length; i++) out.push({ kind: "server", server: ha.servers[i] })
      if (ha.servers.length === 0)
        out.push({ kind: "note", text: ha.discovering || !ha.discovered ? strings.t("servers.searching") : strings.t("servers.none") })
      out.push({ kind: "action", action: "rediscover", icon: "\u{f0450}", text: strings.t("servers.rescan") })
      if (server) out.push({ kind: "action", action: "back", icon: "\u{f004d}", text: strings.t("action.back") })
      return out
    }
    if (ha.authFailed) out.push({ kind: "action", action: "login", icon: "\u{f0343}", text: strings.t("login.again").arg(server.name || server.url) })
    if (effectiveMode === "add") {
      var q = filterText.trim()
      if (q !== "") {
        var matches = Model.search(ha.allEntities, q, entityIds, 30)
        for (i = 0; i < matches.length; i++) out.push({ kind: "suggestion", entity: matches[i] })
        if (matches.length === 0) out.push({ kind: "note", text: strings.t("add.noMatches") })
      } else {
        // What the panel shows now, removable here and only here.
        if (entityIds.length > 0) out.push({ kind: "header", text: strings.t("manage.showing") })
        for (i = 0; i < entityIds.length; i++) out.push({ kind: "managed", id: entityIds[i] })
        var items = ha.suggestions.filter(function(e) { return entityIds.indexOf(e.entity_id) < 0 })
        if (items.length > 0) out.push({ kind: "header", text: strings.t("add.suggestions") })
        for (i = 0; i < items.length; i++) out.push({ kind: "suggestion", entity: items[i] })
        if (!out.some(function(r) { return r.kind === "suggestion" })) {
          out.push({ kind: "header", text: strings.t("manage.add") })
          out.push({ kind: "note", text: ha.suggesting ? strings.t("add.loading") : strings.t("add.nothing") })
        }
      }
      out.push({ kind: "action", action: "done", icon: "\u{f012c}", text: strings.t("action.done") })
      return out
    }
    for (i = 0; i < entityIds.length; i++) out.push({ kind: "entity", id: entityIds[i] })
    if (entityIds.length === 0) out.push({ kind: "note", text: strings.t("main.empty") })
    return out
  }

  function selectable(row) { return row && row.kind !== "header" && row.kind !== "note" }

  function moveCursor(dy) {
    var i = cursor
    for (var step = 0; step < rows.length; step++) {
      i = i < 0 ? (dy > 0 ? 0 : rows.length - 1) : i + dy
      if (i < 0 || i >= rows.length) {
        if (dy < 0 && effectiveMode === "add" && panel.loadedContent) panel.loadedContent.focusFilter()
        return
      }
      if (selectable(rows[i])) { cursor = i; return }
    }
  }

  function activate(row) {
    if (!row) return
    if (row.kind === "server") chooseServer(row.server)
    else if (row.kind === "suggestion") addEntity(row.entity.entity_id)
    else if (row.kind === "entity") { if (!Model.isLock(row.id)) ha.toggle(row.id) }
    else if (row.kind === "action") {
      if (row.action === "rediscover") ha.discover()
      else if (row.action === "back") setMode("main")
      else if (row.action === "add") setMode("add")
      else if (row.action === "done") setMode("main")
      else if (row.action === "login") {
        var s = Object.assign({ loggedIn: false }, server)
        ha.login(s)
      }
    }
  }

  function setMode(next) {
    mode = next
    filterText = ""
    cursor = -1
    if (next === "servers") ha.discover()
    if (next === "add") ha.loadSuggestions(false)
  }

  onRowsChanged: if (cursor >= rows.length || (cursor >= 0 && !selectable(rows[cursor]))) cursor = -1
  onEffectiveModeChanged: if (effectiveMode === "servers") ha.discover()

  onOpenedChanged: if (opened) {
    cursor = -1
    filterText = ""
    if (mode === "add" && entityIds.length > 0) mode = "main"
    if (effectiveMode === "servers") ha.discover()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  readonly property string statusText: {
    if (!server) return strings.t("status.noServer")
    if (ha.loggingIn) return strings.t("status.loggingIn")
    if (ha.authFailed) return strings.t("status.loggedOut")
    if (entityIds.length === 0) return strings.t("status.noEntities")
    if (ha.connected) return strings.t("status.connected")
    if (ha.lastError !== "") return strings.t("status.offline")
    return strings.t("status.connecting")
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return root.statusText }
    function servers(): void { root.setMode("servers"); root.open() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: ""
    iconComponent: Component {
      Item {
        HaLogo {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize
          color: root.barForeground
        }
      }
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) { root.setMode("servers"); root.open() }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(760))

    content: PanelKeyCatcher {
      id: keys
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      blocked: filterField.activeFocus
      reorderable: root.effectiveMode === "add" && root.filterText === ""

      function focusFilter() { root.cursor = -1; filterField.forceActiveFocus() }

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: if (root.cursorActive) root.activate(root.rows[root.cursor])
      onCloseRequested: {
        if (root.effectiveMode !== "main" && root.server) root.setMode("main")
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: {
        var row = root.rows[root.cursor]
        if (row && row.kind === "managed") root.removeEntity(row.id)
      }
      onReorderRequested: function(dy) {
        var row = root.rows[root.cursor]
        if (!row || row.kind !== "managed") return
        var at = root.entityIds.indexOf(row.id)
        if (at + dy < 0 || at + dy >= root.entityIds.length) return
        root.moveEntity(row.id, dy)
        root.cursor = root.cursor + dy
      }
      onTextKey: function(text, modifiers) {
        var row = root.rows[root.cursor]
        if (text === "a" && root.effectiveMode === "main") root.setMode("add")
        else if (text === "s") root.setMode("servers")
        else if ((text === "+" || text === "=") && row && row.kind === "entity") ha.action(row.id, "volume_up")
        else if (text === "-" && row && row.kind === "entity") ha.action(row.id, "volume_down")
        else if (text === "m" && row && row.kind === "entity") ha.action(row.id, "volume_mute")
        else if (text === "x" && row && row.kind === "managed") root.removeEntity(row.id)
        else if (text === "/" && root.effectiveMode === "add") focusFilter()
        else if (text === "r") { if (root.effectiveMode === "servers") ha.discover(); else ha.loadSuggestions(true) }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          PanelHero {
            id: hero
            width: parent.width - Style.space(10)
            title: root.server ? (root.server.name || strings.t("title")) : strings.t("title")
            meta: root.statusText
            detail: ha.lastError !== "" && !ha.connected ? ha.lastError : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              HaLogo {
                iconSize: Style.font.display
                color: hero.foreground
              }
            }
            trailingControl: Component {
              PanelActionButton {
                visible: root.server !== null && root.effectiveMode !== "servers"
                iconText: root.effectiveMode === "main" ? "\u{f0493}" : "\u{f048b}"
                tooltipText: strings.t(root.effectiveMode === "main" ? "action.settings" : "action.switchServer")
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                onClicked: root.setMode(root.effectiveMode === "main" ? "add" : "servers")
              }
            }
          }

          TextField {
            id: filterField
            visible: root.effectiveMode === "add"
            width: parent.width
            placeholderText: strings.t("add.filter")
            foreground: root.foreground
            text: root.filterText
            onTextChanged: if (text !== root.filterText) root.filterText = text
            Keys.onDownPressed: { keys.forceActiveFocus(); root.cursor = -1; root.moveCursor(1) }
            Keys.onEscapePressed: { if (text !== "") root.filterText = ""; else keys.forceActiveFocus() }
            Keys.onReturnPressed: {
              keys.forceActiveFocus()
              root.cursor = -1
              root.moveCursor(1)
              if (root.cursorActive) root.activate(root.rows[root.cursor])
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.rows
              delegate: Loader {
                required property var modelData
                required property int index
                width: column.width
                sourceComponent: modelData.kind === "header" ? headerRow
                  : modelData.kind === "note" ? noteRow
                  : modelData.kind === "server" ? serverRow
                  : modelData.kind === "entity" && Model.isCamera(modelData.id) ? cameraRow
                  : modelData.kind === "entity" ? entityRow
                  : modelData.kind === "suggestion" ? suggestionRow
                  : modelData.kind === "managed" ? managedRow
                  : actionRow
                onLoaded: { item.row = modelData; item.rowIndex = index }
                onModelDataChanged: if (item) item.row = modelData
                onIndexChanged: if (item) item.rowIndex = index
              }
            }
          }
        }
      }
    }
  }

  // ---- rows

  Component {
    id: headerRow
    Item {
      property var row: null
      property int rowIndex: 0
      implicitHeight: header.implicitHeight + Style.space(6)
      PanelSectionHeader {
        id: header
        anchors.bottom: parent.bottom
        text: row ? row.text : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }
  }

  Component {
    id: noteRow
    Text {
      property var row: null
      property int rowIndex: 0
      textFormat: Text.PlainText
      text: row ? row.text : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
      topPadding: Style.space(6)
      bottomPadding: Style.space(6)
    }
  }

  component RowSurface: CursorSurface {
    id: surface
    property var row: null
    property int rowIndex: 0
    property alias glyph: glyphText.text
    property alias title: titleText.text
    property alias subtitle: subtitleText.text
    property real glyphOpacity: 1
    default property alias trailing: trailingRow.data
    signal activated()

    hasCursor: root.cursor === rowIndex
    foreground: root.foreground
    implicitHeight: Math.max(Style.space(40), body.implicitHeight + Style.spacing.rowPaddingX)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.cursor = surface.rowIndex
      onClicked: surface.activated()
    }

    RowLayout {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        id: glyphText
        textFormat: Text.PlainText
        color: root.foreground
        opacity: surface.glyphOpacity
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.preferredWidth: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text {
          id: titleText
          textFormat: Text.PlainText
          Layout.fillWidth: true
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          id: subtitleText
          textFormat: Text.PlainText
          visible: text !== ""
          Layout.fillWidth: true
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: trailingRow
        spacing: Style.space(4)
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  Component {
    id: serverRow
    RowSurface {
      readonly property var s: row ? row.server : null
      readonly property bool current: s && root.server && s.uuid === root.server.uuid
      glyph: current ? "\u{f012c}" : ""
      title: s ? s.name : ""
      subtitle: !s ? "" : (ha.loggingIn && ha.loginServerId === s.uuid ? strings.t("servers.waiting")
        : s.url + "  ·  " + (s.loggedIn ? strings.t("servers.loggedIn") : strings.t("servers.notLoggedIn")))
      onActivated: root.chooseServer(s)

      PanelActionButton {
        visible: s !== null && s.loggedIn
        iconText: "\u{f0343}"
        tooltipText: strings.t("servers.logout")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: ha.logout(s.uuid)
      }
    }
  }

  Component {
    id: entityRow
    RowSurface {
      id: er
      readonly property string entityId: row ? row.id : ""
      readonly property var e: row ? root.entity(entityId) : null
      readonly property bool busy: ha.pending[entityId] === true
      readonly property bool locked: e && e.state === "locked"
      readonly property string volume: Model.isMedia(entityId) ? Model.volumeText(e, root.fmt) : ""
      glyph: Model.glyph(e)
      glyphOpacity: Model.showSwitch(entityId) && !Model.isOn(e) ? 0.5 : 1
      title: e ? e.name : entityId
      // The amplifier only gets its volume (when it reports one), never its state.
      subtitle: Model.isMedia(entityId) ? (volume !== "" ? strings.t("entity.volume").arg(volume) : "")
        : !ha.states[entityId] ? (ha.connected ? strings.t("state.unavailable") : "…")
        : Model.stateText(e, root.t, root.fmt)
      // Clicking a lock row does nothing; its buttons are explicit.
      onActivated: if (!Model.isLock(entityId)) ha.toggle(entityId)

      PanelActionButton {
        visible: Model.isMedia(er.entityId)
        iconText: "\u{f075e}"
        tooltipText: strings.t("entity.volumeDown")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: ha.action(er.entityId, "volume_down")
      }
      PanelActionButton {
        visible: Model.isMedia(er.entityId)
        iconText: "\u{f057e}"
        tooltipText: strings.t("entity.volumeUp")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: ha.action(er.entityId, "volume_up")
      }
      PanelActionButton {
        visible: Model.isLock(er.entityId)
        iconText: "\u{f033e}"
        tooltipText: strings.t("entity.lock")
        foreground: root.foreground
        fontFamily: root.fontFamily
        opacity: er.locked ? 0.35 : 1
        enabled: !er.busy
        onClicked: ha.action(er.entityId, "lock")
      }
      PanelActionButton {
        visible: Model.isLock(er.entityId)
        iconText: "\u{f0fc6}"
        tooltipText: strings.t("entity.unlock")
        foreground: root.foreground
        fontFamily: root.fontFamily
        opacity: er.locked ? 1 : 0.35
        enabled: !er.busy
        onClicked: ha.action(er.entityId, "unlock")
      }
      ToggleSwitch {
        visible: Model.showSwitch(er.entityId)
        checked: Model.isOn(er.e)
        busy: er.busy
        cursorRing: false
        foreground: root.foreground
        onToggled: ha.toggle(er.entityId)
      }
      PanelActionButton {
        visible: Model.canPress(er.entityId)
        iconText: "\u{f040a}"
        tooltipText: strings.t("entity.run")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: ha.toggle(er.entityId)
      }
    }
  }

  Component {
    id: cameraRow
    Column {
      id: cam
      property var row: null
      property int rowIndex: 0
      readonly property string entityId: row ? row.id : ""
      readonly property var e: root.entity(entityId)
      readonly property string url: root.server ? Model.pictureUrl(root.server.url, ha.states[entityId], root.pictureTick) : ""
      spacing: Style.space(6)

      RowSurface {
        width: parent.width
        row: cam.row
        rowIndex: cam.rowIndex
        glyph: Model.glyph(cam.e)
        title: cam.e ? cam.e.name : cam.entityId
      }

      Item {
        id: frame
        width: parent.width
        height: Math.round(width * 9 / 16)
        clip: true

        // Two images swap so a refresh never flashes an empty frame.
        property bool useA: true
        Image {
          id: imgA
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          sourceSize.width: 1280
          visible: frame.useA && status === Image.Ready
          onStatusChanged: if (status === Image.Ready && !frame.useA) frame.useA = true
        }
        Image {
          id: imgB
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          sourceSize.width: 1280
          visible: !frame.useA && status === Image.Ready
          onStatusChanged: if (status === Image.Ready && frame.useA) frame.useA = false
        }
        Component.onCompleted: imgA.source = cam.url
        Connections {
          target: cam
          function onUrlChanged() {
            if (cam.url === "") return
            if (frame.useA) imgB.source = cam.url
            else imgA.source = cam.url
          }
        }

        Text {
          anchors.centerIn: parent
          visible: imgA.status !== Image.Ready && imgB.status !== Image.Ready
          textFormat: Text.PlainText
          text: cam.url === "" ? strings.t("camera.noPicture") : strings.t("camera.loading")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.pictureTick++
        }
      }
    }
  }

  Component {
    id: managedRow
    RowSurface {
      id: mr
      readonly property string entityId: row ? row.id : ""
      readonly property var e: root.entity(entityId)
      glyph: Model.glyph(e)
      title: e ? e.name : entityId
      subtitle: entityId

      PanelActionButton {
        iconText: "\u{f0156}"
        tooltipText: strings.t("entity.remove")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.removeEntity(mr.entityId)
      }
    }
  }

  Component {
    id: suggestionRow
    RowSurface {
      readonly property var e: row ? row.entity : null
      glyph: Model.glyph(e)
      title: e ? e.name : ""
      subtitle: e ? e.entity_id + "  ·  " + Model.stateText(e, root.t, root.fmt) : ""
      onActivated: if (e) root.addEntity(e.entity_id)

      PanelActionButton {
        iconText: "\u{f0415}"
        tooltipText: strings.t("action.add")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.entityIds.length < Model.MAX_ENTITIES
        onClicked: root.addEntity(e.entity_id)
      }
    }
  }

  Component {
    id: actionRow
    RowSurface {
      glyph: row ? row.icon : ""
      title: row ? row.text : ""
      glyphOpacity: 0.8
      onActivated: root.activate(row)
    }
  }
}
