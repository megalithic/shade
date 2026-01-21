# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Project overview

**Shade** is a floating terminal panel for macOS that hosts Neovim for quick note capture.
It integrates with Hammerspoon (hotkeys), obsidian.nvim (note templates), and provides
context-aware capture from any application.

## Architecture

```
┌─────────────────┐     IPC notifications     ┌─────────────────┐
│   Hammerspoon   │ ─────────────────────────→│      Shade      │
│   (hotkeys)     │                           │  (Swift app)    │
└─────────────────┘                           └────────┬────────┘
        │                                              │
        │ writes bootstrap context                     │ nvim RPC
        ↓                                              ↓
┌─────────────────┐                           ┌─────────────────┐
│  context.json   │←──────────────────────────│     Neovim      │
│  (~/.local/     │  reads context for        │  (obsidian.nvim)│
│   state/shade/) │  template substitution    └─────────────────┘
└─────────────────┘
```

## Key components

| Component | Location | Purpose |
|-----------|----------|---------|
| ShadeAppDelegate | `Sources/ShadeAppDelegate.swift` | Main app, IPC, panel management |
| ContextGatherer | `Sources/ContextGatherer/` | Gathers context from frontmost app |
| FocusTracker | `Sources/ShadeCore/FocusTracker.swift` | Tracks non-Shade frontmost app |
| ShadeNvim | `Sources/ShadeNvim.swift` | Nvim RPC client |
| StateDirectory | `Sources/StateDirectory.swift` | Context file I/O |

## IPC notifications (Hammerspoon → Shade)

| Notification | Purpose |
|--------------|---------|
| `io.shade.toggle` | Toggle panel visibility |
| `io.shade.show` | Show panel |
| `io.shade.hide` | Hide panel |
| `io.shade.quit` | Quit Shade |
| `io.shade.note.capture` | Capture note with context |
| `io.shade.note.daily` | Open daily note |
| `io.shade.note.capture.image` | Capture with image |
| `io.shade.note.capture.sidebar` | Capture in sidebar mode |
| `io.shade.sidebar.recall` | Re-enter sidebar with last companion |

## Context capture flow

### Warm start (Shade already running)

1. User triggers capture (Hyper+Shift+N)
2. Hammerspoon sends `io.shade.note.capture`
3. Shade uses `lastNonShadeFrontApp` (proactively tracked)
4. ContextGatherer gathers full context
5. Shade writes context.json, opens capture in nvim

### Cold start (Shade not running) - CRITICAL TIMING

1. User triggers capture
2. Hammerspoon captures frontmost app **BEFORE** launching Shade
3. Hammerspoon writes bootstrap context (`{ bundleID, appName, _bootstrap: true }`)
4. Hammerspoon launches Shade
5. Shade initializes, but is now frontmost (can't track previous app)
6. On capture notification, `capturePreviousFocusedApp()` finds no tracked app
7. Shade reads bootstrap context, looks up app by bundleID
8. ContextGatherer gathers full context from bootstrap app
9. Proceeds normally

**The bootstrap context solves the race condition where Shade becomes frontmost
before its workspace observer can track the previous app.**

## Context file schema

Located at `~/.local/state/shade/context.json`:

```json
{
  "appType": "browser",
  "appName": "Brave Browser Nightly",
  "bundleID": "com.brave.Browser.nightly",
  "windowTitle": "GitHub - user/repo",
  "url": "https://github.com/user/repo",
  "filePath": null,
  "filetype": null,
  "selection": "selected text from browser",
  "detectedLanguage": "javascript",
  "line": null,
  "col": null,
  "timestamp": "2026-02-26T09:30:00Z",
  "_bootstrap": false
}
```

### Bootstrap context (written by Hammerspoon on cold start)

```json
{
  "bundleID": "com.brave.Browser.nightly",
  "appName": "Brave Browser Nightly",
  "_bootstrap": true
}
```

## Building and running

```bash
# Build (release)
swift build -c release

# Run (uses config from ~/.config/shade/config.toml if present)
.build/release/shade

# Run with specific binary version (set in Hammerspoon)
# _G.SHADE_VER = "debug" | "release" | "install" | "/custom/path"
```

## Testing

```bash
swift test
```

## Debugging

### Check context capture

```bash
# Watch context file
watch cat ~/.local/state/shade/context.json

# Check Shade logs
tail -f ~/.local/state/shade/errors.log
```

### Common issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Context shows Shade as app | Cold start timing race | Ensure Hammerspoon writes bootstrap context |
| No selection captured | AX permissions | Grant Accessibility permissions |
| Nvim RPC fails | Socket path mismatch | Check `~/.local/state/shade/nvim.sock` |
| Panel won't show | Panel destroyed | Toggle or restart Shade |

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd sync               # Sync with git
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

