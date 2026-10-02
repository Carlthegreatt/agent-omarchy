# Omagent
AI chat wrapper for the Omarchy shell, powered directly by the Gemini API. Paste
an API key once and chat with Gemini from a native panel — no CLI, no OAuth.

## What it does

- Adds a Gemini glyph to the bar (right side). Left click toggles the chat
  panel; the icon turns accent-coloured when an API key is saved.
- `SUPER+G` opens the panel from anywhere (keybinding added below).
- A menu entry (`AI -> Omagent`) summons the panel too.
- Replies stream token-by-token as they are generated.
- Images: the paperclip button stages one picture per message — paste it
  from the clipboard or pick a file. It is downscaled to 1568px JPEG,
  previewed above the input, shown as a thumbnail in your bubble, and sent
  as an `inline_data` part (kept in follow-up context too).
- The header's expand button switches between compact (460px) and expanded
  (640px, taller history) cards; the choice persists in the `view` file.
- SUPER+G, the menu entry, and the bar icon all open the same bar-anchored
  panel instance (the plugin exposes no standalone panel entry, so position
  is always the centered bar popover).

## Setup

1. Get a Gemini API key from Google AI Studio:
   https://aistudio.google.com/apikey
2. Open the panel (`SUPER+G` or the bar icon) and paste the key.
3. The key is saved to `api_key` in this plugin's folder (mode 0600) and
   reused on every restart. You can also pre-seed it from a terminal:

   ```sh
   umask 077 && printf '%s' 'YOUR_KEY' > ~/.config/omarchy/plugins/Omagent/api_key
   ```

   An env-var fallback (`GEMINI_API_KEY`, then `GOOGLE_API_KEY`) is used when
   no key file exists yet.

4. Optional: set the model by writing a model name into the plugin dir's
   `model` file (default is `gemini-3.6-flash`):

   ```sh
   printf '%s' 'gemini-3.6-flash' > ~/.config/omarchy/plugins/omagent/model
   ```

   The panel also lists the models your key can use automatically and switches
   away from retired ones; the ⇄ button in the panel header cycles through
   them.

## How it works

| Action                 | What happens                                                    |
|------------------------|-----------------------------------------------------------------|
| Save key               | Written to `api_key` (0600) in the plugin folder                |
| Chat                   | `curl` POSTs to `…/v1beta/models/<model>:streamGenerateContent?alt=sse` with `x-goog-api-key`; SSE chunks are parsed into the panel |
| Remove key             | Header button deletes `api_key`                                 |

The key and request body travel in the curl process's *environment* (not
argv), so they never show up in `ps` output. The conversation history is
included in each request so replies stay in context (capped to the most
recent turns, `temperature: 0.7`).

## Files

```
omagent/
├── manifest.json   plugin manifest (validated by `omarchy plugin validate`)
├── Service.qml     API-key store + chat bridge (curl streaming via Process)
├── Panel.qml       chat window UI + API-key entry view
├── BarWidget.qml   bar icon that toggles the panel
└── README.md
```

## Installing / enabling

```sh
# The plugin folder already lives in the user plugin dir; check it shows up:
omarchy plugin list | grep omagent
# Enable (and place the bar icon) if it isn't already:
omarchy plugin enable omagent right
# Validate the manifest:
omarchy plugin validate ~/.config/omarchy/plugins/omagent
```

Edits under `~/.config/omarchy/plugins/` hot-reload on save. If a change
doesn't apply, first clear the stale QML disk cache, then force a rescan:

```sh
rm -rf ~/.cache/quickshell/qmlcache
omarchy-shell shell rescanPlugins
```

## Optional: keybinding and menu

- Keybinding (`~/.config/hypr/bindings.lua`):

  ```lua
  hl.unbind("SUPER + G")  -- was: Toggle window grouping
  o.bind("SUPER + G", "Omagent", "omarchy shell shell toggle omagent '{}'")
  ```

- Menu entry (`~/.config/omarchy/extensions/omarchy-menu.jsonc`), add:

  ```jsonc
  "ai.omagent": {
    "icon": "\udb85\udea1",
    "label": "Omagent",
    "aliases": ["gemini", "ai"],
    "description": "Chat with Gemini",
    "action": "omarchy shell shell toggle omagent '{}'"
  }
  ```

## Notes / limitations

- Streaming SSE is line-split; tool activity/other response parts are ignored,
  only text is shown.
- The panel shows a "Stopped." note if you cancel a reply mid-stream.
- Removing the key deletes `api_key`; the conversation is in-memory only.
