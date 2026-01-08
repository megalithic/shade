# Nvim Socket Integration Handoff

**Date:** 2026-01-08
**Epic:** shade-qji (Context Gathering in Shade)
**Target Repo:** `~/.dotfiles`

## Overview

Shade now has native nvim RPC support via `ShadeNvim.swift`. This document covers how the nvim socket system works and any changes needed for full integration.

---

## Current Socket Architecture

### Socket Registration (nvim side)
Location: `~/.dotfiles/config/nvim/lua/config/interop.lua`

```
/tmp/nvim-sockets/
├── dotfiles_1_0_48115      # tmux: session_window_pane_pid
├── shade_0_0_52341         # tmux: session_window_pane_pid  
└── global_48115            # non-tmux: global_pid
```

Each file contains the actual socket path:
```
/var/folders/.../nvim.12345.0
```

### Socket Discovery Priority
1. **Tmux context:** Match `{session}_{window}_{pane}_*` prefix
2. **Frontmost app PID:** Match `global_{pid}` for non-tmux nvim
3. **Most recent global:** Fallback to latest `global_*` file

---

## Shade's nvim Integration

### ShadeNvim Module (`Sources/ShadeNvim.swift`)

Shade already has comprehensive nvim RPC support:

```swift
// Get context from active nvim instance
let context = await ShadeNvim.shared.getContext()
// Returns: NvimContext(path, filetype, selection, line, col, mode)

// Socket discovery (same priority as Hammerspoon)
let socket = ShadeNvim.shared.getActiveSocket()

// Direct RPC calls
let result = ShadeNvim.shared.eval(socket: socket, expr: "expand('%:p')")
```

### NvimContext Struct

```swift
public struct NvimContext: Sendable, Codable {
    public let path: String?
    public let filetype: String?
    public let selection: String?
    public let line: Int?
    public let col: Int?
    public let mode: String?
}
```

---

## No Changes Required

The nvim socket system works identically for both Hammerspoon and Shade:

| Component | Hammerspoon | Shade |
|-----------|-------------|-------|
| Socket dir | `/tmp/nvim-sockets` | `/tmp/nvim-sockets` |
| Registration | nvim autocmd | nvim autocmd (same) |
| Discovery | `nvim.getActiveSocket()` | `ShadeNvim.shared.getActiveSocket()` |
| RPC method | `nvim --server --remote-expr` | `Process` + same args |

---

## Shade's Nvim Server (Panel nvim)

Shade also runs its own nvim instance in the panel:

**Socket path:** `~/.local/state/shade/nvim.sock`

This is separate from the user's tmux/editor nvim instances and is used for:
- Capture note editing
- Daily note viewing
- obsidian.nvim integration

### Interaction Pattern

```
User nvim (code editing)     Shade nvim (notes)
        │                           │
        │  ShadeNvim.getContext()   │
        ◄───────────────────────────┤  (reads from user's nvim)
        │                           │
        │                           │
        │   sendNvimCommand()       │
        ├───────────────────────────►  (sends to Shade's nvim)
        │                           │
```

---

## Testing

### Verify Socket Discovery

```bash
# List all registered sockets
ls -la /tmp/nvim-sockets/

# Check active tmux context
tmux display-message -p '#{session_name}_#{window_index}_#{pane_index}'

# Test RPC to a socket
nvim --server "$(cat /tmp/nvim-sockets/global_12345)" --remote-expr "expand('%:p')"
```

### Test from Shade

```swift
// In Shade's debug console or test
let socket = ShadeNvim.shared.getActiveSocket()
print("Active socket: \(socket ?? "none")")

let context = await ShadeNvim.shared.getContext()
print("Context: \(context)")
```

---

## Potential Future Enhancements

1. **Socket cleanup:** Shade could help clean up stale sockets on launch
2. **Socket watcher:** Use FSEvents to watch `/tmp/nvim-sockets/` for changes
3. **Multi-nvim support:** UI to select which nvim instance to capture from

These are not required for the current epic but noted for future consideration.
