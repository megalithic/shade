# Hammerspoon Simplification Guide

**Date:** 2026-01-08
**Epic:** shade-qji (Context Gathering in Shade)
**Target Repo:** `~/.dotfiles/config/hammerspoon`

## Overview

With Shade now handling context gathering and nvim RPC natively, Hammerspoon's role simplifies to:
1. **Hotkey handling** - Receive Hyper+Shift+N, Hyper+Shift+O, etc.
2. **Notification dispatch** - Send `io.shade.*` notifications
3. **App lifecycle** - Launch Shade if not running

**Key principle:** Hammerspoon should NOT send nvim commands directly anymore. It just sends notifications to Shade, and Shade handles everything via its native nvim RPC.

---

## Files to Modify

### 1. `lib/interop/shade.lua`

#### Functions to Simplify

##### `captureWithContext()` - ALREADY DONE
This was already updated to use the notification pattern.

##### `openDailyNote()` - NEEDS UPDATE

**Current (broken - sends nvim command directly):**
```lua
function M.openDailyNote()
  local function sendDailyCommand()
    local success, err = M.sendNvimCommand(":ObsidianToday")
    if success then
      hs.timer.doAfter(0.1, function() M.show() end)
    else
      hs.alert.show("Failed to open daily note: " .. (err or "unknown"), 2)
    end
  end

  if M.isNvimServerRunning() then
    sendDailyCommand()
  else
    M.ensureRunning(function()
      M.sendNvimCommandWhenReady(":ObsidianToday", 5, function()
      end, function(err)
        hs.alert.show("Failed to open daily note: " .. err, 2)
      end)
    end)
  end
end
```

**New (uses notification pattern):**
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

#### Functions That Can Be Deprecated (but keep for now)

These functions are no longer needed for the primary workflow but may be useful for debugging:

```lua
-- Keep but mark as deprecated:
M.sendNvimCommand()          -- Shade handles nvim RPC now
M.sendNvimCommandWhenReady() -- Shade handles nvim RPC now
M.isNvimServerRunning()      -- Shade handles connection management
M.openFileWhenReady()        -- Shade handles file opening
M.writeContext()             -- Shade writes its own context
```

---

### 2. `clipper.lua`

The clipper module has TWO functions that need updating:

##### `captureQuick()` - NEEDS UPDATE

**Current (sends nvim command directly):**
```lua
function obj.captureQuick()
  -- ... image preparation code ...

  -- Write context with imageFilename for obsidian.nvim template
  local ctx = {
    imageFilename = imageFilename,
    appType = "screenshot",
    appName = "Screenshot",
  }
  if not shade.writeContext(ctx) then
    hs.alert.show("Capture failed: could not write context", 2)
    return false
  end

  -- Use obsidian.nvim to create note from template
  local nvimCmd = ":Obsidian new_from_template capture capture-image"

  if shade.isNvimServerRunning() then
    local cmdSuccess, cmdErr = shade.sendNvimCommand(nvimCmd)
    -- ...
  else
    shade.ensureRunning(function()
      shade.sendNvimCommandWhenReady(nvimCmd, 5, ...)
    end)
  end
  -- ...
end
```

**New (uses notification pattern):**
```lua
--- Quick capture: screenshot to note, linked in daily (fire-and-forget)
--- Shade handles context writing and obsidian.nvim command
function obj.captureQuick()
  if not obj.activeCapture.imagePath then
    U.log.w("captureQuick: no image path available")
    hs.alert.show("No screenshot available", 1)
    return false
  end

  local imagePath = obj.activeCapture.imagePath
  local imageUrl = obj.activeCapture.imageUrl

  -- Copy image to assets and get filename
  local success, imageFilename, err = prepareImageCapture(imagePath, imageUrl)
  if not success then
    hs.alert.show(fmt("Capture failed: %s", err or "unknown error"), 3)
    U.log.w(fmt("captureQuick: %s", err or "unknown error"))
    return false
  end

  -- Write context with imageFilename for Shade to read
  -- Shade will pass this to obsidian.nvim template
  local ctx = {
    imageFilename = imageFilename,
    appType = "screenshot",
    appName = "Screenshot",
  }
  if not shade.writeContext(ctx) then
    hs.alert.show("Capture failed: could not write context", 2)
    return false
  end

  -- Send notification - Shade handles the rest
  -- Shade will: read context, call :Obsidian new_from_template capture capture-image
  local function triggerImageCapture()
    hs.distributednotifications.post("io.shade.note.capture.image", nil, nil)
    hs.alert.show("Quick capture saved", 1.5)
    U.log.i("captureQuick: sent notification to Shade")
  end

  if shade.isRunning() then
    triggerImageCapture()
  else
    shade.launch(function()
      hs.timer.doAfter(0.5, triggerImageCapture)
    end)
  end

  -- Clear active capture since files are moved/deleted
  obj.clearCapture()
  return true
end
```

##### `captureFull()` - NEEDS UPDATE

**Current (sends nvim command directly):**
```lua
function obj.captureFull()
  -- ... same pattern as captureQuick ...
  local nvimCmd = ":Obsidian new_from_template capture capture-image"
  -- ... sends command directly to nvim ...
end
```

**New (uses notification pattern):**
```lua
--- Full capture: screenshot to note with floating editor (interactive)
--- Shade handles context and obsidian.nvim command, then shows panel
function obj.captureFull()
  if not obj.activeCapture.imagePath then
    U.log.w("captureFull: no image path available")
    hs.alert.show("No screenshot available", 1)
    return false
  end

  local imagePath = obj.activeCapture.imagePath
  local imageUrl = obj.activeCapture.imageUrl

  -- Copy image to assets and get filename
  local success, imageFilename, err = prepareImageCapture(imagePath, imageUrl)
  if not success then
    hs.alert.show(fmt("Capture failed: %s", err or "unknown error"), 3)
    U.log.w(fmt("captureFull: %s", err or "unknown error"))
    return false
  end

  -- Write context with imageFilename for Shade to read
  local ctx = {
    imageFilename = imageFilename,
    appType = "screenshot",
    appName = "Screenshot",
  }
  if not shade.writeContext(ctx) then
    hs.alert.show("Capture failed: could not write context", 2)
    return false
  end

  -- Send notification - Shade handles the rest and shows the panel
  local function triggerImageCapture()
    hs.distributednotifications.post("io.shade.note.capture.image", nil, nil)
    hs.timer.doAfter(0.1, function() shade.show() end)
    U.log.i("captureFull: sent notification to Shade")
  end

  if shade.isRunning() then
    triggerImageCapture()
  else
    shade.launch(function()
      hs.timer.doAfter(0.5, triggerImageCapture)
    end)
  end

  -- Clear active capture since files are moved/deleted
  obj.clearCapture()
  return true
end
```

---

### 3. `lib/interop/context.lua`

Add deprecation header but keep functional for other uses:

```lua
---@deprecated Context gathering moved to Shade (shade-qji epic, Jan 2026)
--- This module is kept for backwards compatibility and debugging.
--- For capture workflow, Shade now gathers context natively via:
---   - AccessibilityHelper.swift (AX API for selection, window title)
---   - AppTypeDetector.swift (app categorization)
---   - JXABridge.swift (browser URL/title/selection)
---   - LanguageDetector.swift (programming language detection)
```

### 4. `lib/interop/selection.lua`

Add deprecation header:

```lua
---@deprecated Selection capture moved to Shade (shade-qji.1, Jan 2026)
--- Shade uses AccessibilityHelper.swift for AX-based selection capture.
--- This module wraps bin/get-selection which is now redundant.
---
--- Keep only if you need standalone CLI selection capture.
```

---

## New Notification Required in Shade

**IMPORTANT:** Shade needs to handle a new notification for image captures:

Notification: `io.shade.note.capture.image`

This notification tells Shade to:
1. Read context from `~/.local/state/shade/context.json` (written by clipper)
2. Run `:Obsidian new_from_template capture capture-image`
3. Show the panel (for captureFull) or stay hidden (for captureQuick)

**This requires a change in Shade's ShadeAppDelegate.swift** - see the "Required Shade Changes" section below.

---

## Required Shade Changes

Add a new notification handler in `ShadeAppDelegate.swift`:

```swift
// In setupNotificationListener(), add:
center.addObserver(
    self,
    selector: #selector(handleImageCaptureNotification),
    name: NSNotification.Name("io.shade.note.capture.image"),
    object: nil
)

// Add new handler:
@objc private func handleImageCaptureNotification(_ notification: Notification) {
    Log.debug("IPC: note.capture.image")

    // Read context (written by clipper.lua with imageFilename)
    let context = StateDirectory.readContext()
    if let ctx = context {
        Log.debug("Image capture context: imageFilename=\(ctx.imageFilename ?? "nil")")
    }

    // Delete context file after reading (one-shot)
    StateDirectory.deleteContextFile()

    // Show panel with surface (will recreate if backgrounded)
    showPanelWithSurface()

    // Open image capture note using native RPC
    ShadeNvim.shared.connectAndPerform(
        { nvim in try await nvim.openImageCapture(context: context) },
        onSuccess: { path in Log.debug("Image capture opened: \(path)") },
        onError: { error in Log.error("Failed to open image capture: \(error)") }
    )
}
```

And add to `CaptureContext` struct:
```swift
struct CaptureContext: Codable {
    // ... existing fields ...
    var imageFilename: String?  // ADD THIS for clipper image captures
}
```

And add to `ShadeNvim`:
```swift
func openImageCapture(context: CaptureContext?) async throws -> String {
    // Run :Obsidian new_from_template capture capture-image
    try await command("Obsidian new_from_template capture capture-image")
    return "image capture created"
}
```

---

## Summary of ALL Changes

### Hammerspoon (`~/.dotfiles`)

| File | Function | Change |
|------|----------|--------|
| `lib/interop/shade.lua` | `openDailyNote()` | Use `NOTIFICATION_DAILY` instead of `sendNvimCommand()` |
| `lib/interop/shade.lua` | Header comment | Update to reflect new flow |
| `lib/interop/context.lua` | Module | Add deprecation notice |
| `lib/interop/selection.lua` | Module | Add deprecation notice |
| `clipper.lua` | `captureQuick()` | Use `io.shade.note.capture.image` notification |
| `clipper.lua` | `captureFull()` | Use `io.shade.note.capture.image` notification |

### Shade (`~/code/shade`) - SEPARATE TASK

| File | Change |
|------|--------|
| `ShadeAppDelegate.swift` | Add `handleImageCaptureNotification` handler |
| `StateDirectory.swift` | Add `imageFilename` to `CaptureContext` |
| `ShadeNvim.swift` | Add `openImageCapture()` method |

---

## Notification Reference

| Notification | Sender | Handler | Purpose |
|--------------|--------|---------|---------|
| `io.shade.toggle` | Hammerspoon | Shade | Toggle panel visibility |
| `io.shade.show` | Hammerspoon | Shade | Show panel |
| `io.shade.hide` | Hammerspoon | Shade | Hide panel |
| `io.shade.quit` | Hammerspoon | Shade | Quit app |
| `io.shade.note.capture` | Hammerspoon | Shade | Text capture (Shade gathers context) |
| `io.shade.note.daily` | Hammerspoon | Shade | Open daily note |
| `io.shade.note.capture.image` | Hammerspoon | Shade | Image capture (clipper writes context) |

---

## Testing Checklist

After making changes, test:

- [ ] **Hyper+Shift+O**: Opens daily note in Shade
- [ ] **Hyper+Shift+N**: Creates text capture with context from frontmost app
- [ ] **Screenshot + n**: Quick image capture (clipper modal)
- [ ] **Screenshot + Shift+N**: Full image capture with editor (clipper modal)
- [ ] **Hyper+N**: Smart toggle (shows Shade)

---

## Rollback Instructions

If issues arise with daily note:
```lua
-- In openDailyNote(), restore direct nvim command:
function M.openDailyNote()
  local function sendDailyCommand()
    local success, err = M.sendNvimCommand(":ObsidianToday")
    -- ... original implementation
  end
  -- ...
end
```

If issues arise with image capture, restore direct nvim command in `captureQuick()` and `captureFull()`.
