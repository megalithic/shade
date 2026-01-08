# Dotfiles Integration Handoff: Shade Context Gathering

**Date:** 2026-01-08
**Epic:** shade-qji (Context Gathering in Shade)
**Target Repo:** `~/.dotfiles`

## Overview

Shade now has native context gathering capabilities. This document describes the changes needed in `~/.dotfiles` to utilize the new architecture where **Shade handles nvim RPC and context gathering** instead of Hammerspoon.

---

## Architecture Change

### Old Flow (Hammerspoon-centric)
```
1. Hammerspoon receives hotkey (Hyper+Shift+N, Hyper+Shift+O, etc.)
2. Hammerspoon does one of:
   a. Gathers context via Lua modules
   b. Writes context.json
   c. Sends nvim command directly via --remote-send
3. Hammerspoon manages nvim server connection
4. Hammerspoon shows Shade panel
```

### New Flow (Shade-centric)
```
1. Hammerspoon receives hotkey
2. Hammerspoon sends notification to Shade (e.g., io.shade.note.daily)
3. Hammerspoon ensures Shade is running
4. Shade receives notification and handles everything:
   - Gathers context (for text captures)
   - Reads context (for image captures from clipper)
   - Sends nvim commands via native RPC
   - Shows panel as needed
```

**Key principle:** Hammerspoon should NOT call `sendNvimCommand()` anymore. Just send notifications.

---

## Files to Modify

### 1. `lib/interop/shade.lua`

**Change `openDailyNote()` to use notification pattern:**

```lua
--- Open daily note in Shade
--- Shade handles :ObsidianToday via native nvim RPC
function M.openDailyNote()
  local function triggerDaily()
    postNotification(NOTIFICATION_DAILY)
    hs.timer.doAfter(0.1, function() M.show() end)
  end

  if M.isRunning() then
    triggerDaily()
  else
    M.launch(function()
      hs.timer.doAfter(0.5, triggerDaily)
    end)
  end
end
```

### 2. `clipper.lua`

**Change `captureQuick()` and `captureFull()` to use notification pattern.**

See `hammerspoon-simplification.md` for full code changes.

### 3. `lib/interop/context.lua`

**Add deprecation notice** (keep functional for debugging):

```lua
---@deprecated Context gathering moved to Shade (shade-qji epic, Jan 2026)
```

### 4. `lib/interop/selection.lua`

**Add deprecation notice:**

```lua
---@deprecated Selection capture moved to Shade (shade-qji.1, Jan 2026)
```

---

## Notification Reference

| Notification | When to Send | What Shade Does |
|--------------|--------------|-----------------|
| `io.shade.toggle` | Toggle visibility | Shows/hides panel |
| `io.shade.show` | Force show | Shows panel |
| `io.shade.hide` | Force hide | Hides panel |
| `io.shade.quit` | Quit app | Terminates Shade |
| `io.shade.note.capture` | Hyper+Shift+N | Gathers context, creates text capture |
| `io.shade.note.daily` | Hyper+Shift+O | Opens daily note via :ObsidianToday |
| `io.shade.note.capture.image` | Clipper n/N | Reads context (imageFilename), creates image capture |

---

## Context JSON Schema

The context.json schema for backwards compatibility:

```json
{
  "appType": "browser" | "terminal" | "neovim" | "editor" | "communication" | "screenshot" | "other",
  "appName": "Brave Browser Nightly",
  "bundleID": "com.brave.Browser.nightly",
  "windowTitle": "GitHub - shade",
  "url": "https://github.com/example/shade",
  "filePath": "/path/to/file.swift",
  "filetype": "swift",
  "selection": "selected text here",
  "detectedLanguage": "swift",
  "line": 42,
  "col": 5,
  "imageFilename": "20260108-123456.png"
}
```

**Note:** `imageFilename` is only set by clipper for image captures.

---

## Testing Checklist

### Daily Note (Hyper+Shift+O)
- [ ] Opens daily note in Shade
- [ ] Works when Shade is already running
- [ ] Works when Shade needs to be launched

### Text Capture (Hyper+Shift+N)
- [ ] Creates capture with context from frontmost app
- [ ] Browser: has URL, title, selection
- [ ] Terminal: has window title, selection
- [ ] Terminal+nvim: has file path, filetype, selection, line/col
- [ ] Editor: has window title, selection

### Image Capture (Clipper modal)
- [ ] Screenshot + `n`: Quick capture (background, no panel)
- [ ] Screenshot + `Shift+N`: Full capture (shows panel for editing)
- [ ] Image file is copied to assets folder
- [ ] Note is created with image embed

---

## Rollback Plan

If issues arise, revert functions to use direct nvim commands:

1. **openDailyNote()**: Restore `sendNvimCommand(":ObsidianToday")`
2. **captureQuick()/captureFull()**: Restore `sendNvimCommand(":Obsidian new_from_template...")`

The old code patterns are preserved in this doc for reference.

---

## Related Shade Changes Required

For image captures (`io.shade.note.capture.image`), Shade needs:

1. New notification handler in `ShadeAppDelegate.swift`
2. `imageFilename` field in `CaptureContext` struct
3. `openImageCapture()` method in `ShadeNvim.swift`

See `hammerspoon-simplification.md` for details.

---

## Quick Reference: What Hammerspoon Should Do Now

| Action | Old Way | New Way |
|--------|---------|---------|
| Daily note | `sendNvimCommand(":ObsidianToday")` | `postNotification(NOTIFICATION_DAILY)` |
| Text capture | `context.getContext()` + `writeContext()` + `sendNvimCommand()` | `postNotification(NOTIFICATION_CAPTURE)` |
| Image capture | `writeContext()` + `sendNvimCommand()` | `writeContext()` + `postNotification("io.shade.note.capture.image")` |

**The pattern is always:** ensure Shade is running, then post notification.
