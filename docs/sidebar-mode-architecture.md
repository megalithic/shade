# Sidebar Mode Architecture Analysis & Redesign

> **Status**: Analysis complete, ready for implementation
> **Priority**: P1 (workflow blocker)
> **Related Beads**: shade-hfu, shade-den

## Executive Summary

The current sidebar mode has two bugs that cause workflow friction:

1. **shade-hfu**: Companion window captured once at entry, never updated
2. **shade-den**: Panel position/size not reset when showing after hide

Both stem from the same root cause: **state management treats mode and position as separate concerns when they should be unified**.

---

## Bug Analysis

### Bug 1: shade-hfu - Companion Not Tracked Dynamically

**Current behavior**:
```
enterSidebarMode() → capture lastNonShadeFrontApp as companionBundleID → DONE
```

The companion is captured ONCE. If the user switches focus to another app while in sidebar mode, that app doesn't become the new companion.

**Scenario**:
1. User in Safari, triggers `io.shade.mode.sidebar-left`
2. Safari becomes companion (resized to right half)
3. User clicks Slack
4. User toggles sidebar off
5. **Result**: Safari restored to original size, but user expected Slack

**Root cause**: `companionBundleID` is set in `enterSidebarMode()` and never updated.

### Bug 2: shade-den - Stale Position on Show

**Current behavior**:
```swift
hidePanel() {
    exitSidebarMode()  // Sets currentMode = .floating, restores companion
    panel?.hide()       // Panel still at sidebar SIZE/POSITION
}

handleToggleNotification() {
    if currentMode != .floating {  // FALSE - already .floating from hidePanel()
        // This block skipped!
        panel?.resize(...)
    }
    showPanelWithSurface()  // Shows panel at STALE sidebar position
}
```

**Scenario**:
1. Panel in sidebar-left mode (currentMode = .sidebarLeft)
2. User hides panel (hidePanel called)
3. exitSidebarMode() sets currentMode = .floating
4. Panel hidden but still AT sidebar dimensions
5. User shows panel via toggle
6. Check `currentMode != .floating` is FALSE
7. **Result**: Panel shown at sidebar position, not centered floating

**Root cause**: `exitSidebarMode()` doesn't reset panel position/size, and the toggle check relies on `currentMode` which is already reset.

---

## Current State Model

```
┌─────────────────────────────────────────────────────────────┐
│                    Current State Variables                   │
├─────────────────────────────────────────────────────────────┤
│  currentMode: PanelMode           (.floating/.sidebarLeft/R)│
│  companionBundleID: String?       (captured once at entry)  │
│  companionOriginalFrame: CGRect?  (for restoration)         │
│  previousFocusedApp: NSRunningApplication?  (for focus)     │
│  lastNonShadeFrontApp: NSRunningApplication? (tracked)      │
│  isBackgrounded: Bool             (surface destroyed)       │
└─────────────────────────────────────────────────────────────┘
```

**Problems**:
1. No separation between "logical mode" and "visual state"
2. Companion tracking doesn't respond to focus changes
3. Panel position not tracked - relies on checking `currentMode`

---

## Proposed Architecture

### Core Insight

Separate concerns into:
1. **Display Mode** - The logical mode (floating vs sidebar)
2. **Panel Geometry** - The actual position/size of the panel
3. **Companion Tracking** - Dynamic tracking of paired window

### New State Model

```swift
/// Panel display mode - the logical state
enum DisplayMode {
    case floating
    case sidebar(edge: Edge, companion: CompanionState?)
}

enum Edge {
    case left, right
}

/// Tracks the companion window in sidebar mode
struct CompanionState {
    let bundleID: String
    let originalFrame: CGRect
    var currentWindow: AXUIElement?  // For dynamic tracking
}

/// Unified panel state
struct PanelState {
    var mode: DisplayMode = .floating
    var floatingFrame: CGRect?  // Last known floating position/size
    var isVisible: Bool = false
}
```

### Key Changes

#### 1. Track Panel Geometry Separately

```swift
// Save floating frame before entering sidebar
func enterSidebarMode(_ edge: Edge) {
    // Save current floating frame for later restoration
    if case .floating = panelState.mode {
        panelState.floatingFrame = panel?.frame
    }

    // ... enter sidebar
}

// Restore floating frame on exit
func exitSidebarMode() {
    // Restore panel to saved floating frame
    if let floatingFrame = panelState.floatingFrame {
        panel?.setFrame(floatingFrame, display: true)
    } else {
        // Fallback to default centered position
        panel?.resize(width: appConfig.width, height: appConfig.height)
    }

    // ... restore companion
}
```

#### 2. Dynamic Companion Tracking

When in sidebar mode, listen for app activation and update companion:

```swift
// In workspace notification handler
@objc private func handleAppActivation(_ notification: Notification) {
    guard case .sidebar(let edge, _) = panelState.mode else { return }

    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

    // Option A: Auto-update companion (aggressive)
    // updateCompanion(to: app, edge: edge)

    // Option B: Track but don't auto-resize (conservative)
    lastNonShadeFrontApp = app
}
```

#### 3. Unified Show/Hide Logic

```swift
func showPanel() {
    switch panelState.mode {
    case .floating:
        // Always restore to floating position
        if let frame = panelState.floatingFrame {
            panel?.setFrame(frame, display: true)
        } else {
            panel?.positionCentered()
        }

    case .sidebar(let edge, let companion):
        // Re-enter sidebar with current or new companion
        panel?.positionSidebar(mode: edge == .left ? .sidebarLeft : .sidebarRight,
                               width: appConfig.sidebarWidth)
        // Note: Companion might have changed while hidden
    }

    panel?.show(skipPositioning: true)
    panelState.isVisible = true
}

func hidePanel() {
    panelState.isVisible = false

    // If in sidebar mode, restore companion but DON'T change mode
    if case .sidebar(_, let companion) = panelState.mode {
        restoreCompanion(companion)
    }

    panel?.hide()
}
```

---

## Implementation Plan

### Phase 1: Fix shade-den (Stale Position)

**Minimal fix** - Don't reset mode in hidePanel, just restore companion:

```swift
func hidePanel() {
    // Restore companion if in sidebar mode, but keep mode state
    if case .sidebar = currentMode {
        restoreCompanionWindow()
        // DON'T set currentMode = .floating here
    }
    panel?.hide()
}

func handleToggleNotification() {
    if isPanelVisible {
        hidePanel()
    } else {
        // Mode is still sidebar - re-enter properly
        if currentMode != .floating {
            // Re-capture companion (current frontmost)
            enterSidebarMode(currentMode)
        } else {
            showPanelWithSurface()
        }
    }
}
```

### Phase 2: Fix shade-hfu (Dynamic Companion)

Add option for dynamic companion tracking:

```swift
// Configuration
var dynamicCompanionTracking: Bool = true

// In workspace notification handler
if dynamicCompanionTracking && currentMode != .floating {
    // Update which app would become companion on next sidebar entry
    // But don't auto-resize existing companion
}
```

### Phase 3: Full Architecture Refactor (Optional)

If phases 1-2 prove insufficient, implement the full `PanelState` model above.

---

## Research: Similar Apps

### iTerm2 Hotkey Window
- **Behavior**: Drops down from top, doesn't manage companion windows
- **Relevance**: Low - no sidebar/companion concept

### Amethyst/Yabai/AeroSpace (Tiling WMs)
- **Behavior**: Manage ALL windows in tiles, not just one companion
- **Relevance**: Medium - overkill for our use case, but show AX patterns

### Swindler (Swift Library)
- **Behavior**: Event-driven window state tracking via AXUIElement
- **Events**: `WindowMovedEvent`, `WindowFrameChangedEvent`, `MainWindowChanged`
- **Relevance**: HIGH - shows exactly how to track window changes
- **API**: `swindlerState.on { (event: WindowMovedEvent) in ... }`

### Rectangle/Magnet
- **Behavior**: User-triggered window snapping, not automatic
- **Relevance**: Low - different interaction model

---

## Swindler Integration (Future)

If we need robust window tracking, consider adding Swindler:

```swift
// Package.swift
.package(url: "https://github.com/tmandry/Swindler", from: "0.2.0")

// Usage
swindler.on { (event: FrontmostApplicationChangedEvent) in
    guard case .sidebar = self.panelState.mode else { return }
    // Handle companion change
}
```

**Pros**:
- Handles all edge cases in AX notifications
- Event ordering guarantees
- Distinguishes user vs programmatic changes

**Cons**:
- Another dependency
- May be overkill for our needs

---

## Testing Scenarios

### shade-den: Show After Hide in Sidebar Mode

1. Start in floating mode
2. Enter sidebar-left (Hyper+Ctrl+O or `io.shade.mode.sidebar-left`)
3. Verify: Safari (or current app) resized to right half
4. Hide Shade (Hyper+N or `io.shade.toggle`)
5. Verify: Safari restored to original size
6. Show Shade (Hyper+N)
7. **Expected**: Shade appears FLOATING and CENTERED
8. **Bug behavior**: Shade appears at left edge (sidebar position)

### shade-hfu: Companion Changes While in Sidebar

1. Start in Safari
2. Enter sidebar-left
3. Verify: Safari is companion (right half)
4. Click on Slack (Slack becomes frontmost)
5. Exit sidebar (Hyper+Ctrl+O)
6. **Expected (option A)**: Slack is restored (if it was resized)
7. **Expected (option B)**: Safari is restored (original companion)
8. **Question**: Which behavior do we want?

### Focus Restoration

1. Start in Safari
2. Show Shade (Hyper+N)
3. Type in terminal
4. Hide Shade (Hyper+N)
5. **Expected**: Safari regains focus
6. Verify: Safari is frontmost

---

## Decision Points

1. **Dynamic companion**: Should companion auto-update when user focuses another app in sidebar mode?
   - **Option A**: Yes, always track current app
   - **Option B**: No, companion is fixed until mode exit (current behavior)
   - **Option C**: Configurable

2. **Show after hide in sidebar mode**: What should happen?
   - **Option A**: Reset to floating (current intent, buggy implementation)
   - **Option B**: Re-enter sidebar with same companion
   - **Option C**: Re-enter sidebar with current frontmost as companion

3. **Swindler dependency**: Should we add it?
   - **Option A**: Yes, for robust window tracking
   - **Option B**: No, our AX code is sufficient
   - **Option C**: Later, if bugs persist after fixes

---

## References

- [Swindler - macOS window management library](https://github.com/tmandry/Swindler)
- [iTerm2 Hotkey Window Documentation](https://iterm2.com/documentation-hotkey.html)
- [Amethyst Tiling WM](https://github.com/ianyh/Amethyst)
- [NSPanel Documentation](https://developer.apple.com/documentation/appkit/nspanel)
- [AeroSpace TWM](https://github.com/nikitabobko/AeroSpace)
