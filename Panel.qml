import QtQuick
import Quickshell
import Quickshell.Io
import QtQuick.Dialogs
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omagent"
  ipcTarget: "omagent"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  // Writable on purpose: the shell assigns the service singleton after load
  // (item.service = ...). The bar-widget-loaded instance has no shell
  // injection, so fall back to resolving it through the bar.
  property var service: null

  function ensureService() {
    if (!root.service && root.bar && root.bar.shell) {
      root.service = root.bar.shell.serviceFor("omagent")
    }
  }

  // Compact vs expanded card. Expanded is wider with a taller message
  // list; the shell clamps the card inside the screen either way.
  readonly property bool expanded: root.service && root.service.viewMode === "expanded"
  readonly property int cardWidth: root.expanded ? Style.space(640) : Style.space(460)
  readonly property int listHeight: root.expanded ? Style.space(520) : Style.space(360)

  function open() { root.controller.show() }
  function openFromHotkey() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // file:// URL -> local path for the upload pipeline.
  function pathFromUrl(u) {
    var s = String(u || "")
    if (s.indexOf("file://") === 0) s = s.slice(7)
    try { s = decodeURIComponent(s) } catch (e) {}
    return s
  }

  // Markdown-to-HTML for chatbot replies: headings, bold/italic, inline
  // code and code blocks, lists, quotes, links and simple tables render as
  // rich text so long replies stay scannable. User messages pass through
  // the same renderer for a consistent look. Anything unrecognized falls
  // back to plain paragraphs (Qt ignores unknown tags but shows content).
  function escapeHtml(s) {
    return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }
  function inlineMd(s) {
    var t = s
    t = t.replace(/`([^`]+)`/g, '<font face="Monospace">$1</font>')
    t = t.replace(/!\[([^\]]*)\]\([^)]+\)/g, "$1")
    t = t.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>')
    t = t.replace(/(\*\*|__)(.*?)\1/g, "<b>$2</b>")
    t = t.replace(/(^|[\s(>])\*([^*\n]+)\*/g, "$1<i>$2</i>")
    t = t.replace(/(^|[\s(>])_([^_\n]+)_/g, "$1<i>$2</i>")
    t = t.replace(/~~(.*?)~~/g, "$1")
    return t
  }
  function markdownToHtml(s) {
    var lines = String(s || "").split("\n")
    var html = "", inCode = false, inList = false, para = []
    function flushPara() { if (para.length) { html += "<p>" + para.join("<br>") + "</p>"; para = [] } }
    function closeList() { if (inList) { html += "</ul>"; inList = false } }
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (/^\s*```[\w-]*\s*$/.test(line)) {
        if (inCode) { html += "</font></pre>"; inCode = false }
        else { flushPara(); closeList(); html += '<pre><font face="Monospace">'; inCode = true }
        continue
      }
      if (inCode) { html += escapeHtml(line) + "\n"; continue }
      var t = line
      if (/^\s*$/.test(t)) { flushPara(); closeList(); continue }
      var h = t.match(/^\s{0,3}#{1,6}\s+(.*)$/)
      if (h) { flushPara(); closeList(); html += "<h3>" + inlineMd(escapeHtml(h[1])) + "</h3>"; continue }
      var li = t.match(/^\s{0,3}(?:[-*+]\s+|\d+[.)]\s+)(.*)$/)
      if (li) { flushPara(); if (!inList) { html += "<ul>"; inList = true } html += "<li>" + inlineMd(escapeHtml(li[1])) + "</li>"; continue }
      if (/^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$/.test(t)) { flushPara(); closeList(); html += "<hr>"; continue }
      var q = t.match(/^\s{0,3}>\s?(.*)$/)
      if (q) { flushPara(); closeList(); html += "<p><i>" + inlineMd(escapeHtml(q[1])) + "</i></p>"; continue }
      if ((t.match(/\|/g) || []).length >= 2 && !/^\s*[\s|:~-]+\s*$/.test(t)) {
        flushPara(); closeList()
        var cells = t.split("|").map(function(c) { return inlineMd(escapeHtml(c.trim())) }).filter(function(c) { return c !== "" })
        html += "<p>" + cells.join(" &nbsp; ") + "</p>"; continue
      }
      if (/^\s*[\s|:~-]+\s*$/.test(t)) continue
      closeList()
      para.push(inlineMd(escapeHtml(t)))
    }
    flushPara(); closeList()
    if (inCode) html += "</font></pre>"
    return html
  }

  Component.onCompleted: root.ensureService()
  onBarChanged: root.ensureService()

  // Focus the message field shortly after opening so typing works
  // immediately. Delayed past the panel's own focus priming.
  Timer {
    id: focusTimer
    interval: 120
    repeat: false
    onTriggered: {
      var c = contentLoader.item
      if (c && c.focusInput) c.focusInput()
    }
  }
  onOpenedChanged: {
    if (root.opened) focusTimer.restart()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.cardWidth)
    contentHeight: panel.fittedContentHeight(contentLoader.item ? contentLoader.item.implicitHeight : Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: contentLoader.item ? (contentLoader.item.inputActive || contentLoader.item.popupOpen || contentLoader.item.pickerOpen) : false
      onCloseRequested: root.close()

      Loader {
        id: contentLoader
        anchors.fill: parent
        active: Boolean(root.service)
        sourceComponent: panelContent
      }
    }
  }

  Component {
    id: panelContent

    Column {
      id: contentRoot
      width: panel.fittedContentWidth(root.cardWidth)

      // Whether the text input (inside the chat view) has focus — the key
      // catcher must not swallow typing while the message field is active.
      property bool inputActive: bodyLoader.item && bodyLoader.item.inputActive ? bodyLoader.item.inputActive : false
      // Whether the model dropdown popup is open — same handling for its keys.
      property bool popupOpen: modelDropdown.popupOpen
      // Whether the file picker is open — it needs its own keys too.
      property bool pickerOpen: Boolean(bodyLoader.item && bodyLoader.item.showPicker)

      // Focus whatever text field the active view offers.
      function focusInput() {
        var v = bodyLoader.item
        if (v && v.focusField) v.focusField()
      }

      // ---------------- header: model left, actions right ----------------
      Item {
        width: parent.width
        height: Math.max(modelDropdown.height, headerRow.implicitHeight) + Style.space(8)

        Dropdown {
          id: modelDropdown
          width: Style.space(150)
          height: Style.spacing.controlHeight
          visible: root.service && root.service.hasKey
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          label: "Model"
          showLabel: false
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          options: root.service ? root.service.availableModels : []
          value: root.service ? root.service.model : ""
          onChanged: function(v) {
            if (root.service) root.service.setModel(v, false)
          }
          onPopupOpenChanged: {
              if (modelDropdown.popupOpen && root.service && root.service.availableModels.length === 0) {
                root.service.refreshModels(true)
              }
          }
        }

        Row {
          id: headerRow
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Button {
            iconText: root.expanded ? "\uf066" : "\uf065"
            tooltipText: root.expanded ? "Compact view" : "Expanded view"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
              if (root.service) root.service.cycleViewMode()
            }
          }
          Button {
            iconText: "\uf0ea"
            tooltipText: "New chat"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
              if (root.service) root.service.clearConversation()
            }
          }
          Button {
            iconText: "\uf09c"
            tooltipText: root.service && root.service.hasKey ? "Remove API key" : "Add API key"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
              if (root.service && root.service.hasKey) root.service.clearApiKey()
            }
          }
        }
      }

      PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

      // ---------------- body ----------------
      // Explicit height: Loaders do not size themselves, so mirror the
      // loaded view's implicit height for a deterministic panel size.
      Loader {
        id: bodyLoader
        width: parent.width
        height: item ? item.implicitHeight : 0
        active: true
        sourceComponent: root.service ? (root.service.hasKey ? chatView : loginView) : loginView
        onLoaded: contentRoot.focusInput()
      }
    }
  }

  // =====================================================================
  //  No-key view: paste a Gemini API key
  // =====================================================================
  Component {
    id: loginView

    Column {
      width: parent.width
      spacing: Style.space(16)

      function focusField() {
        keyField.forceActiveFocus()
      }

      Item {
        width: parent.width
        height: Style.space(72)

        Text {
          anchors.centerIn: parent
          text: "\udb85\udea1"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.display
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Enter your Gemini API key"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - Style.space(64)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: "Get a free key from Google AI Studio (aistudio.google.com/apikey). The key is stored in this plugin's folder with mode 0600 and sent only to Google's API."
        color: Color.muted
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      TextField {
        id: keyField
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - Style.space(64)
        placeholderText: "AIza…"
        echoMode: TextInput.Password
        foreground: root.bar ? root.bar.foreground : Color.foreground
        Keys.onReturnPressed: {
          if (root.service) root.service.saveApiKey(keyField.text)
        }
        Keys.onEnterPressed: {
          if (root.service) root.service.saveApiKey(keyField.text)
        }
      }

      Button {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Save key"
        iconText: "\uf0d1"
        foreground: root.bar ? root.bar.foreground : Color.foreground
        onClicked: {
          if (root.service) root.service.saveApiKey(keyField.text)
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        wrapMode: Text.WordWrap
        width: parent.width - Style.space(64)
        horizontalAlignment: Text.AlignHCenter
        visible: root.service && root.service.statusText !== ""
        text: root.service ? root.service.statusText : ""
        color: Color.muted
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Item {
        width: parent.width
        height: Style.space(8)
      }
    }
  }

  // =====================================================================
  //  Chat view
  // =====================================================================
  Component {
    id: chatView

    Column {
      width: parent.width
      spacing: Style.space(6)

      property bool inputActive: inputField && inputField.activeFocus
      property bool showAttach: false
      property bool showPicker: false

      function focusField() {
        inputField.forceActiveFocus()
      }

      // Native file picker: a separate dialog window (FileDialog is not a
      // visual Item and cannot live inside the panel layout).
      FileDialog {
        id: filePicker
        fileMode: FileDialog.OpenFile
        nameFilters: ["Image files (*.png *.jpg *.jpeg *.webp)", "All files (*)"]
        currentFolder: "file://" + (root.service ? root.service.home : "") + "/Pictures"
        onAccepted: {
          var u = String(filePicker.selectedFile)
          showPicker = false
          if (root.service) root.service.stageImageFile(pathFromUrl(u))
        }
        onRejected: showPicker = false
      }
      property int suggestionIndex: 0
      property var suggestions: [
        "Ask anything…",
        "Explain a difficult concept…",
        "Draft a message…",
        "Help me debug…",
        "Summarize this…",
        "Brainstorm ideas…",
        "Write a function that…"
      ]

      Rectangle {
        width: parent.width
        height: root.listHeight
        color: "transparent"
        clip: true

        // Empty-state hint while the conversation has no messages.
        Text {
          anchors.centerIn: parent
          visible: !root.service || !root.service.conversationModel
            || root.service.conversationModel.count === 0
          text: "Ask anything — replies stream in below."
          color: Color.muted
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        ListView {
          id: chatList
          anchors.fill: parent
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(12)
          anchors.topMargin: Style.space(8)
          anchors.bottomMargin: Style.space(8)
          spacing: Style.space(12)
          model: root.service ? root.service.conversationModel : null
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: true
          cacheBuffer: Style.space(200)

          onCountChanged: Qt.callLater(function() {
            if (chatList.count > 0) chatList.positionViewAtEnd()
          })

          delegate: Item {
            id: bubbleDelegate
            required property int index
            required property string role
            required property string text
            required property string imageData
            required property string imageMime
            width: chatList.width
            height: bubbleColumn.implicitHeight + Style.space(4)

            Column {
              id: bubbleColumn
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(4)

              Image {
                anchors.left: role === "assistant" ? parent.left : undefined
                anchors.right: role === "assistant" ? undefined : parent.right
                visible: bubbleDelegate.imageData !== ""
                width: Math.min(Style.space(280), parent.width - Style.space(24))
                fillMode: Image.PreserveAspectFit
                source: bubbleDelegate.imageData !== ""
                  ? ("data:" + bubbleDelegate.imageMime + ";base64," + bubbleDelegate.imageData)
                  : ""
              }

              Rectangle {
                id: bubbleBox
                anchors.left: role === "assistant" ? parent.left : undefined
                anchors.right: role === "assistant" ? undefined : parent.right
                // While the reply is loading the bubble holds a typing
                // indicator instead of text.
                readonly property bool loading: role === "assistant" && bubbleDelegate.text === ""
                  && root.service && root.service.sending
                  && index === root.service.lastAssistantIndex()
                // Fixed row width (no content measuring) so the label's
                // wrap width can never loop back into this binding.
                width: bubbleBox.loading ? Style.space(42)
                  : Math.min(bubbleMeasure.implicitWidth + Style.space(24), parent.width - Style.space(24))
                height: bubbleBox.loading ? Style.space(24)
                  : bubbleLabel.implicitHeight + Style.space(12)
                radius: Style.space(4)
                color: role === "assistant"
                  ? (root.bar ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.08) : Qt.rgba(1, 1, 1, 0.08))
                  : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)

                TextEdit {
                  id: bubbleLabel
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  anchors.topMargin: Style.space(8)
                  anchors.bottomMargin: Style.space(8)
                  visible: bubbleDelegate.text !== ""
                  verticalAlignment: TextEdit.AlignVCenter
                  horizontalAlignment: role === "assistant" ? TextEdit.AlignLeft : TextEdit.AlignRight
                  text: markdownToHtml(bubbleDelegate.text)
                  textFormat: TextEdit.RichText
                  readOnly: true
                  selectByMouse: true
                  selectByKeyboard: true
                  cursorVisible: false
                  selectionColor: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.4)
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: TextEdit.WordWrap
                }

                // Hidden single-line measurer: gives the hug-width without
                // constraining the visible label, so no width loop is possible.
                TextEdit {
                  id: bubbleMeasure
                  visible: false
                  text: markdownToHtml(bubbleDelegate.text)
                  textFormat: TextEdit.RichText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: TextEdit.NoWrap
                }

                Row {
                  anchors.centerIn: parent
                  visible: bubbleBox.loading
                  spacing: Style.space(4)

                  Repeater {
                    model: 3

                    Rectangle {
                      width: Style.space(6)
                      height: Style.space(6)
                      radius: Style.space(3)
                      color: Color.muted
                      opacity: 0.25

                      SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        running: bubbleBox.loading
                        PauseAnimation { duration: index * 180 }
                        NumberAnimation { from: 0.25; to: 1.0; duration: 350; easing.type: Easing.InOutQuad }
                        NumberAnimation { from: 1.0; to: 0.25; duration: 350; easing.type: Easing.InOutQuad }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        wrapMode: Text.WordWrap
        width: parent.width - Style.space(40)
        horizontalAlignment: Text.AlignHCenter
        visible: root.service && root.service.statusText !== ""
        text: root.service ? root.service.statusText : ""
        color: Color.muted
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

      // ---------------- image attach ----------------
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: showAttach && !(root.service && root.service.sending)

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          spacing: Style.space(8)

          Button {
            text: "Paste from clipboard"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: {
              showAttach = false
              if (root.service) root.service.pasteImage()
            }
          }
          Button {
            text: "Choose file…"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: {
              showAttach = false
              showPicker = true
              filePicker.open()
            }
          }
        }
      }

      Item {
        width: parent.width
        height: pendingRow.implicitHeight + Style.space(8)
        visible: root.service && root.service.pendingImageData !== ""

        Row {
          id: pendingRow
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Image {
            width: Style.space(64)
            height: Style.space(64)
            fillMode: Image.PreserveAspectCrop
            source: root.service && root.service.pendingImageData !== ""
              ? ("data:" + root.service.pendingImageMime + ";base64," + root.service.pendingImageData)
              : ""
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Image attached — sending with your next message."
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf00d"
            tooltipText: "Remove image"
            foreground: Color.muted
            onClicked: {
              if (root.service) root.service.clearPendingImage()
            }
          }
        }
      }

      Item {
        width: parent.width
        height: inputRow.implicitHeight + Style.space(8)

        Row {
          id: inputRow
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          TextField {
            id: inputField
            width: parent.width - attachButton.implicitWidth - sendButton.implicitWidth - parent.spacing * 2
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: suggestions[suggestionIndex]
            foreground: root.bar ? root.bar.foreground : Color.foreground
            enabled: !(root.service && root.service.sending)
            Keys.onReturnPressed: {
              if (root.service) root.service.send(inputField.text)
              inputField.text = ""
            }
            Keys.onEnterPressed: {
              if (root.service) root.service.send(inputField.text)
              inputField.text = ""
            }
          }

          Button {
            id: attachButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf0c6"
            tooltipText: "Attach image"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: showAttach = !showAttach
          }

          Button {
            id: sendButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.service && root.service.sending ? "\uf04d" : "\uf1d8"
            tooltipText: root.service && root.service.sending ? "Stop" : "Send"
            accent: !(root.service && root.service.sending)
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: {
              if (!root.service) return
              if (root.service.sending) {
                root.service.stopSending()
              } else {
                root.service.send(inputField.text)
                inputField.text = ""
              }
            }
          }
        }

        Timer {
          interval: 4000
          running: true
          repeat: true
          onTriggered: suggestionIndex = (suggestionIndex + 1) % suggestions.length
        }
      }
    }
  }
}
