# Handoff Documents

This directory contains handoff documentation for integrating Shade's new context gathering capabilities with `~/.dotfiles`.

## Documents

| Document | Purpose |
|----------|---------|
| [dotfiles-integration.md](./dotfiles-integration.md) | Overview, architecture diagrams, testing checklist |
| [hammerspoon-simplification.md](./hammerspoon-simplification.md) | **Detailed code changes** for shade.lua and clipper.lua |
| [nvim-socket-integration.md](./nvim-socket-integration.md) | How nvim socket discovery works (reference) |

## Quick Start

1. **Read `hammerspoon-simplification.md`** - This has ALL the code changes needed
2. Make the changes to:
   - `lib/interop/shade.lua` - Fix `openDailyNote()`
   - `clipper.lua` - Fix `captureQuick()` and `captureFull()`
   - `lib/interop/context.lua` - Add deprecation notice
   - `lib/interop/selection.lua` - Add deprecation notice
3. Test using the checklist in `dotfiles-integration.md`

## Summary of Changes

### Must Fix Now (Broken)
- **`openDailyNote()`** in shade.lua - Currently tries to send nvim command directly, fails

### Should Fix (For Image Captures)
- **`captureQuick()`** in clipper.lua - Uses direct nvim commands
- **`captureFull()`** in clipper.lua - Uses direct nvim commands

### Nice to Have (Cleanup)
- Add deprecation notices to context.lua and selection.lua

## Key Principle

**Hammerspoon should NOT send nvim commands directly anymore.**

Old pattern:
```lua
shade.sendNvimCommand(":ObsidianToday")
```

New pattern:
```lua
postNotification(NOTIFICATION_DAILY)
-- or
hs.distributednotifications.post("io.shade.note.daily", nil, nil)
```

## Related Beads

- **shade-qji**: Context Gathering in Shade (epic) - CLOSED
- **shade-qji.6**: Wire up context gathering to capture triggers - CLOSED

## Shade Components (Already Built)

| Component | File | Purpose |
|-----------|------|---------|
| ContextGatherer | `Sources/ContextGatherer/ContextGatherer.swift` | Orchestrates all gathering |
| AccessibilityHelper | `Sources/ContextGatherer/AccessibilityHelper.swift` | AX API for selection |
| AppTypeDetector | `Sources/ContextGatherer/AppTypeDetector.swift` | App categorization |
| JXABridge | `Sources/ContextGatherer/JXABridge.swift` | Browser context via JXA |
| LanguageDetector | `Sources/ContextGatherer/LanguageDetector.swift` | Programming language detection |
