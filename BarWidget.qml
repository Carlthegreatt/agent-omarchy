import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "carl.gemini-chat"

  // Writable so a future shell injection cannot break; resolved through
  // the bar when the shell does not assign it directly.
  property var service: null

  function ensureService() {
    if (!root.service && root.bar && root.bar.shell) {
      root.service = root.bar.shell.serviceFor("carl.gemini-chat")
    }
  }

  Component.onCompleted: root.ensureService()

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: the shell requires
  // open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function getIconForegroundColor() {
    if (root.service) {
      if (root.service.hasKey) return Color.accent
      if (root.service.sending) return root.bar ? root.bar.urgent : Color.urgent
      if (root.service.keyChecked) return Color.muted
    }
    return root.bar ? root.bar.barForeground : Color.foreground
  }

  function getIconText() {
    if (root.service && root.service.sending) return "\uf021"
    return "\udb85\udea1"
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    root.ensureService()
    injectPanel()
  }
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.getIconText()
    foreground: root.getIconForegroundColor()
    slotSize: Style.bar.statusSlot
    tooltipText: "Chat"

    onPressed: function(b) {
      if (!root.bar) return
      root.togglePanel()
    }
  }
}