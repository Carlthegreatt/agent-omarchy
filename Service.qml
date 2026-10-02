import QtQuick
import Quickshell
import Quickshell.Io

// Gemini Chat — service singleton.
//
// Talks to the Gemini API (generativelanguage.googleapis.com) directly. There
// is no CLI and no Google OAuth: the user pastes an API key from Google AI
// Studio, which is stored in this plugin's directory (mode 0600) and sent to
// the API as the x-goog-api-key header. Requests stream via
// streamGenerateContent (SSE) so replies appear as they are generated.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "omagent"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string pluginDir: home + "/.config/omarchy/plugins/" + pluginId
  readonly property string keyFile: pluginDir + "/api_key"

  // Model can be overridden by writing a model name into the plugin dir's
  // "model" file; otherwise the default below is used.
  property string model: "gemini-3.5-flash"
  property var availableModels: []

  // View mode ("compact" | "expanded"), persisted in the plugin dir's
  // "view" file. Compact is the default bar-anchored card; expanded is a
  // wider, taller card for long sessions.
  property string viewMode: "compact"

  // ---- state surfaced to the UI -------------------------------------------
  property string apiKey: ""
  readonly property bool hasKey: apiKey !== ""
  property bool keyChecked: false
  property bool sending: false
  property string statusText: ""

  ListModel {
    id: conversation
    dynamicRoles: true
  }

  // Ids are component-scoped in QML: expose the model so the panel's
  // ListView can bind to it (service.conversation would be undefined).
  readonly property var conversationModel: conversation


  function lastAssistantIndex() {
    for (var i = conversation.count - 1; i >= 0; i--) {
      if (conversation.get(i).role === "assistant") return i
    }
    return -1
  }

  // ---- API key -------------------------------------------------------------

  function loadKey() {
    readKey.command = [
      "bash", "-lc",
      'if [ -f "$0" ]; then cat "$0"; else printf "%s" "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}"; fi',
      root.keyFile
    ]
    readKey.running = true
  }

  Process {
    id: readKey
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.apiKey = String(text).trim()
        root.keyChecked = true
        root.loadModel()
        if (root.apiKey !== "") root.refreshModels(false)
      }
    }
  }

  function loadModel() {
    readModel.command = ["bash", "-lc", 'cat "$0" 2>/dev/null || true', root.pluginDir + "/model"]
    readModel.running = true
  }

  Process {
    id: readModel
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text).trim()
        if (m !== "") root.model = m
        root.loadView()
      }
    }
  }

  function loadView() {
    readView.command = ["bash", "-lc", 'cat "$0" 2>/dev/null || true', root.pluginDir + "/view"]
    readView.running = true
  }

  Process {
    id: readView
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var v = String(text).trim()
        if (v === "expanded" || v === "compact") root.viewMode = v
      }
    }
  }

  function setViewMode(mode) {
    var m = (mode === "expanded") ? "expanded" : "compact"
    root.viewMode = m
    saveViewProc.command = [
      "bash", "-lc",
      'printf "%s" "$1" > "$0"',
      root.pluginDir + "/view", m
    ]
    saveViewProc.running = true
  }

  Process {
    id: saveViewProc
    running: false
  }

  function cycleViewMode() {
    root.setViewMode(root.viewMode === "expanded" ? "compact" : "expanded")
  }

  function saveApiKey(key) {
    var value = String(key || "").trim()
    if (value === "") {
      root.statusText = "Enter an API key first."
      return
    }
    saveKey.command = [
      "bash", "-lc",
      'umask 077; printf "%s" "$KEYVALUE" > "$0"',
      root.keyFile
    ]
    saveKey.environment = { "KEYVALUE": value }
    root.pendingKey = value
    saveKey.running = true
  }

  property string pendingKey: ""
  property string saveError: ""

  Process {
    id: saveKey
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.saveError = text.trim()
    }
    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0) {
        root.apiKey = root.pendingKey
        root.pendingKey = ""
        root.saveError = ""
        root.statusText = "API key saved."
        root.refreshModels(true)
      } else if (root.saveError !== "") {
        root.statusText = "Could not save the API key: " + root.saveError
      } else {
        root.statusText = "Could not save the API key (exit " + exitCode + ")."
      }
    }
  }

  // ---- image attach ----------------------------------------------------------
  // One staged image per message: pasted from the clipboard or picked from
  // disk, downscaled to 1568px JPEG and held as base64 in memory only.
  // Temp files live under XDG_RUNTIME_DIR and are deleted after encoding.

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  property string pendingImageData: ""
  property string pendingImageMime: ""
  property string attachOut: ""
  property string attachErr: ""

  function clearPendingImage() {
    root.pendingImageData = ""
    root.pendingImageMime = ""
  }

  function stageImageFile(path) {
    var p = String(path || "").trim()
    if (p === "" || attachProc.running) return
    root.statusText = "Reading image…"
    attachProc.command = [
      "bash", "-lc",
      'IN="$0"; OUT="$1"; magick "$IN" -resize "1568x1568>" -quality 82 "jpg:$OUT" && base64 -w0 "$OUT"; RC=$?; rm -f "$OUT"; exit $RC',
      p, root.runtimeDir + "/omagent-attach.jpg"
    ]
    attachProc.running = true
  }

  function pasteImage() {
    if (attachProc.running) return
    root.statusText = "Reading clipboard…"
    attachProc.command = [
      "bash", "-lc",
      'IN="$0"; OUT="$1"; ' +
      'T=$(wl-paste --list-types 2>/dev/null | grep -m1 -E "^image/(png|jpeg|jpg|webp)$"); ' +
      'if [ -z "$T" ]; then echo "NOIMAGE" >&2; exit 3; fi; ' +
      'wl-paste --type "$T" > "$IN" && magick "$IN" -resize "1568x1568>" -quality 82 "jpg:$OUT" && base64 -w0 "$OUT"; ' +
      'RC=$?; rm -f "$IN" "$OUT"; exit $RC',
      root.runtimeDir + "/omagent-clipboard", root.runtimeDir + "/omagent-attach.jpg"
    ]
    attachProc.running = true
  }

  Process {
    id: attachProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.attachOut = String(text).trim()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.attachErr = String(text).trim()
    }
    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0 && root.attachOut !== "") {
        root.pendingImageData = root.attachOut
        root.pendingImageMime = "image/jpeg"
        root.statusText = ""
      } else if (exitCode === 3 || root.attachErr.indexOf("NOIMAGE") >= 0) {
        root.statusText = "Clipboard has no image — copy an image first."
      } else {
        var detail = root.attachErr.split("\n")[0]
        root.statusText = "Couldn't read that image." + (detail !== "" ? " " + detail : "")
      }
      root.attachOut = ""
      root.attachErr = ""
    }
  }

  // ---- models --------------------------------------------------------------


  // Ask the API which models this key can use, then drop any model that is
  // not on the list (self-heals "model no longer available" errors).
  // announce=true reports the outcome in statusText; otherwise failures stay
  // silent except for a limited automatic retry (covers lookups that run
  // before the network is up at boot).

  property bool listAnnounce: false
  property int listRetries: 0

  function refreshModels(announce) {
    if (root.apiKey === "" || listProc.running) return
    root.listAnnounce = !!announce
    listProc.environment = { "GEMINI_API_KEY": root.apiKey }
    listProc.command = [
      "bash", "-lc",
      'curl -sS -X GET "https://generativelanguage.googleapis.com/v1beta/models" ' +
      '-H "x-goog-api-key: $GEMINI_API_KEY"'
    ]
    listProc.running = true
  }

  Process {
    id: listProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyModelList(String(text), root.listAnnounce)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {}
    }
    onExited: (exitCode, exitStatus) => {}
  }

  Timer {
    id: listRetryTimer
    interval: 8000
    repeat: false
    onTriggered: {
      if (root.availableModels.length === 0 && root.apiKey !== "") root.refreshModels(false)
    }
  }

  function applyModelList(body, announce) {
    var names = []
    // Free chat-capable models only: Gemini Flash/Pro text variants. Drop
    // Live/TTS/image/embedding/video/music/robotics/research endpoints.
    var skipTokens = ["live", "tts", "image", "embed", "veo", "lyria",
      "banana", "translate", "robotics", "vision", "aqa", "research", "deep"]
    try {
      var obj = JSON.parse(body)
      if (obj && obj.error) {
        if (announce && obj.error.message) root.statusText = String(obj.error.message)
        else if (root.listRetries < 3) { root.listRetries++; listRetryTimer.restart() }
        return
      }
      var models = (obj && obj.models) || []
      for (var i = 0; i < models.length; i++) {
        var methods = models[i].supportedGenerationMethods || []
        if (methods.indexOf("generateContent") < 0) continue
        var full = String(models[i].name || "")
        if (full.indexOf("models/") === 0) full = full.slice(7)
        if (full === "" || names.indexOf(full) >= 0) continue
        var lower = full.toLowerCase()
        if (lower.indexOf("gemini") < 0) continue
        var skip = false
        for (var s = 0; s < skipTokens.length; s++) {
          if (lower.indexOf(skipTokens[s]) >= 0) { skip = true; break }
        }
        if (skip) continue
        names.push(full)
      }
    } catch (e) {
      if (announce) root.statusText = "Couldn't read the model list."
      else if (root.listRetries < 3) { root.listRetries++; listRetryTimer.restart() }
      return
    }
    if (names.length === 0) {
      if (announce) root.statusText = "No chat models found for this key."
      else if (root.listRetries < 3) { root.listRetries++; listRetryTimer.restart() }
      return
    }
    root.listRetries = 0
    root.availableModels = names
    if (names.indexOf(root.model) < 0) {
      root.setModel(names[0], true)
      root.statusText = "Switched to model " + names[0] + " (previous one is unavailable)."
    } else if (announce) {
      root.statusText = "Found " + names.length + " chat models."
    }
  }

  function setModel(name, silent) {
    var m = String(name || "").trim()
    if (m === "") return
    root.model = m
    saveModelProc.command = [
      "bash", "-lc",
      'printf "%s" "$1" > "$0"',
      root.pluginDir + "/model", m
    ]
    saveModelProc.running = true
    if (!silent) root.statusText = "Model: " + m
  }

  Process {
    id: saveModelProc
    running: false
  }

  function clearApiKey() {
    clearKey.command = ["bash", "-lc", 'rm -f "$0"', root.keyFile]
    clearKey.running = true
  }

  Process {
    id: clearKey
    running: false
    onExited: (exitCode, exitStatus) => {
      root.apiKey = ""
      root.statusText = "API key removed."
    }
  }

  // ---- chat ----------------------------------------------------------------

  property string replyBuffer: ""
  property int chunkCount: 0

  function send(raw) {
    var text = String(raw || "").trim()
    if (text === "" && root.pendingImageData === "") return
    if (!root.hasKey) {
      root.statusText = "Add your Gemini API key first."
      return
    }
    if (root.sending || replyProc.running) return

    var imgData = root.pendingImageData
    var imgMime = root.pendingImageMime
    root.pendingImageData = ""
    root.pendingImageMime = ""
    var userMsg = { role: "user", text: text, imageData: imgData, imageMime: imgMime }
    conversation.append(userMsg)
    conversation.append({ role: "assistant", text: "", imageData: "", imageMime: "" })
    root.sending = true
    root.replyBuffer = ""
    root.chunkCount = 0
    root.statusText = ""

    var payload = JSON.stringify(buildPayload())
    replyProc.environment = {
      "GEMINI_API_KEY": root.apiKey,
      "GEMINI_PAYLOAD": payload
    }
    replyProc.command = [
      "bash", "-lc",
      'printf "%s" "$GEMINI_PAYLOAD" | curl -sSN -X POST ' +
      '"https://generativelanguage.googleapis.com/v1beta/models/' + root.model +
      ':streamGenerateContent?alt=sse" ' +
      '-H "Content-Type: application/json" ' +
      '-H "x-goog-api-key: $GEMINI_API_KEY" ' +
      '--data-binary @-'
    ]
    replyProc.running = true
  }

  // Build a v1beta generateContent payload from the recent conversation.
  // Messages carrying an image send it as an inline_data part so the model
  // keeps visual context on follow-up turns.
  function buildPayload() {
    var contents = []
    var from = Math.max(0, conversation.count - 12)
    for (var i = from; i < conversation.count; i++) {
      var m = conversation.get(i)
      var img = String(m.imageData || "")
      var txt = String(m.text || "")
      if (txt === "" && img === "") continue
      var parts = []
      if (txt !== "") parts.push({ text: txt })
      if (img !== "") {
        parts.push({ inline_data: { mime_type: String(m.imageMime || "image/jpeg"), data: img } })
      }
      if (parts.length === 0) continue
      contents.push({
        role: m.role === "assistant" ? "model" : "user",
        parts: parts
      })
    }
    return {
      contents: contents,
      generationConfig: { temperature: 0.7 }
    }
  }

  Process {
    id: replyProc
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        root.handleStreamLine(String(line || ""))
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "" && root.statusText === "") root.statusText = text.trim()
    }
    onExited: (exitCode, exitStatus) => {
      root.sending = false
      root.finishReply(exitCode)
    }
  }

  // End-of-reply reconciliation. Streaming may have missed content (e.g. a
  // pretty-printed multi-line error document), so the full buffered body is
  // parsed here as a fallback before giving up.
  function finishReply(exitCode) {
    var idx = root.lastAssistantIndex()
    var haveText = idx >= 0 && String(conversation.get(idx).text).trim() !== ""
    if (!haveText) root.extractBufferedReply()
    haveText = idx >= 0 && String(conversation.get(idx).text).trim() !== ""

    if (!haveText) {
      if (idx >= 0) conversation.remove(idx)
      if (root.statusText === "") {
        var detail = root.bufferedError()
        if (detail !== "") root.statusText = detail
        else root.statusText = "No reply text (exit " + exitCode + ", chunks " + root.chunkCount + ", bytes " + root.replyBuffer.length + ")."
      }
    } else if (exitCode !== 0 && root.statusText === "") {
      root.statusText = "Gemini finished with a warning (exit code " + exitCode + ")."
    }
    root.replyBuffer = ""
  }

  // Pull an "error" message out of the buffered body, tolerating both
  // single-line and pretty-printed multi-line JSON.
  function bufferedError() {
    var buf = root.replyBuffer
    if (buf === "") return ""
    try {
      var obj = JSON.parse(buf)
      if (obj && obj.error && obj.error.message) return String(obj.error.message)
    } catch (e) {}
    // SSE error chunks embed one JSON object per data: line.
    var lines = buf.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var s = lines[i].trim()
      if (s.indexOf("data:") === 0) s = s.slice(5).trim()
      if (s === "" || s.charAt(0) !== "{") continue
      try {
        var o = JSON.parse(s)
        if (o && o.error && o.error.message) return String(o.error.message)
      } catch (e2) {}
    }
    return ""
  }

  // Last resort: if streaming produced nothing, try to harvest reply text
  // from the buffered body as a whole document.
  function extractBufferedReply() {
    var buf = root.replyBuffer
    if (buf === "") return
    var idx = root.lastAssistantIndex()
    if (idx < 0) return
    var texts = []
    try {
      var obj = JSON.parse(buf)
      collectTexts(obj, texts)
    } catch (e) {}
    if (texts.length === 0) {
      var lines = buf.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var s = lines[i].trim()
        if (s.indexOf("data:") === 0) s = s.slice(5).trim()
        if (s === "" || s.charAt(0) !== "{") continue
        try {
          collectTexts(JSON.parse(s), texts)
        } catch (e2) {}
      }
    }
    if (texts.length > 0) {
      conversation.setProperty(idx, "text", texts.join(""))
    }
  }

  function collectTexts(node, out) {
    if (node === null || node === undefined) return
    if (typeof node === "string") return
    if (Array.isArray(node)) {
      for (var i = 0; i < node.length; i++) collectTexts(node[i], out)
      return
    }
    if (typeof node === "object") {
      if (node.thought === true) return // reasoning traces stay out of replies
      if (typeof node.text === "string" && node.parts === undefined && node.content === undefined) {
        // A bare {"text": ...} part object.
        out.push(node.text)
        return
      }
      for (var k in node) collectTexts(node[k], out)
    }
  }

  // Handle one line of the SSE stream.
  function handleStreamLine(line) {
    var s = line.trim()
    if (s === "") return
    root.chunkCount++
    if (root.replyBuffer.length < 200000) root.replyBuffer += line + "\n"
    var data = s
    if (s.indexOf("data:") === 0) data = s.slice(5).trim()
    if (data === "" || data === "[DONE]") return
    if (data.charAt(0) !== "{") return

    var obj
    try {
      obj = JSON.parse(data)
    } catch (e) {
      return
    }

    if (obj.error) {
      if (obj.error.message) root.statusText = String(obj.error.message)
      return
    }

    var candidates = obj.candidates
    if (!candidates || candidates.length === 0) return
    var parts = candidates[0].content && candidates[0].content.parts
    if (!parts) return

    var idx = root.lastAssistantIndex()
    if (idx < 0) return
    for (var i = 0; i < parts.length; i++) {
      if (!parts[i] || parts[i].thought === true) continue
      var piece = parts[i].text
      if (!piece) continue
      var current = String(conversation.get(idx).text)
      conversation.setProperty(idx, "text", current + piece)
    }
  }

  function clearConversation() {
    if (root.sending) return
    conversation.clear()
  }

  function stopSending() {
    if (root.sending && replyProc.running) {
      replyProc.signal(9)
      root.sending = false
      root.statusText = "Stopped."
    }
  }

  Component.onCompleted: root.loadKey()
}
