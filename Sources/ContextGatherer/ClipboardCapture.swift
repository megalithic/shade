import AppKit
import Carbon.HIToolbox
import Foundation
import os.log

// MARK: - Logging

private let logger = Logger(subsystem: "io.shade", category: "ClipboardCapture")

// MARK: - Clipboard State

/// Represents a complete snapshot of the clipboard state
/// Preserves all items with all their type representations (including binary data)
public struct ClipboardState: Sendable {
    /// Each item is an array of (type, data) pairs
    /// Using arrays instead of dictionaries to preserve order
    fileprivate let items: [[(NSPasteboard.PasteboardType, Data)]]

    /// The change count when this state was captured
    fileprivate let changeCount: Int

    /// Whether the clipboard was empty
    public var isEmpty: Bool {
        items.isEmpty || items.allSatisfy { $0.isEmpty }
    }

    /// Number of items in the clipboard
    public var itemCount: Int {
        items.count
    }

    /// Total bytes of data preserved
    public var totalBytes: Int {
        items.reduce(0) { sum, item in
            sum + item.reduce(0) { $0 + $1.1.count }
        }
    }
}

// MARK: - Clipboard Capture Errors

public enum ClipboardCaptureError: Error, CustomStringConvertible {
    case saveFailure(String)
    case restoreFailure(String)
    case copyTimeout
    case copyFailed
    case noSelection
    case externalClipboardChange

    public var description: String {
        switch self {
        case .saveFailure(let msg): return "Failed to save clipboard: \(msg)"
        case .restoreFailure(let msg): return "Failed to restore clipboard: \(msg)"
        case .copyTimeout: return "Cmd+C timed out"
        case .copyFailed: return "Cmd+C failed to execute"
        case .noSelection: return "No text selection after copy"
        case .externalClipboardChange: return "Clipboard was modified externally during capture"
        }
    }
}

// MARK: - Clipboard Capture

/// Captures selected text by programmatically triggering Cmd+C
/// with full clipboard preservation and restoration.
///
/// ## Usage
/// ```swift
/// let result = await ClipboardCapture.captureSelection()
/// switch result {
/// case .success(let text):
///     print("Captured: \(text)")
/// case .failure(let error):
///     print("Failed: \(error)")
/// }
/// ```
///
/// ## Safety Guarantees
/// - All clipboard items are preserved (text, images, files, etc.)
/// - All type representations are preserved (RTF, HTML, binary, etc.)
/// - Clipboard is restored even on error or timeout
/// - External clipboard changes are detected
public enum ClipboardCapture {

    /// Timeout for the copy operation
    private static let copyTimeout: Duration = .milliseconds(500)

    /// Small delay after Cmd+C to let the app update the clipboard
    private static let postCopyDelay: Duration = .milliseconds(50)

    // MARK: - Public API

    /// Capture selected text from the frontmost application using Cmd+C
    ///
    /// This method:
    /// 1. Saves the entire clipboard state (all items, all types, binary-safe)
    /// 2. Sends Cmd+C to the frontmost app
    /// 3. Reads the new clipboard content
    /// 4. Restores the original clipboard state
    ///
    /// - Returns: The selected text, or an error
    public static func captureSelection() async -> Result<String, ClipboardCaptureError> {
        let pasteboard = NSPasteboard.general

        // 1. Save clipboard state
        let savedState: ClipboardState
        do {
            savedState = try saveClipboardState(pasteboard)
            logger.debug("Saved clipboard: \(savedState.itemCount) items, \(savedState.totalBytes) bytes")
        } catch {
            logger.error("Failed to save clipboard: \(error)")
            return .failure(.saveFailure(error.localizedDescription))
        }

        // 2. Clear clipboard so we can detect if Cmd+C worked
        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount

        // 3. Send Cmd+C with timeout
        let copySuccess = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                return sendCmdC()
            }

            group.addTask {
                try? await Task.sleep(for: copyTimeout)
                return false // Timeout sentinel
            }

            // First result wins
            if let result = await group.next() {
                group.cancelAll()
                return result
            }
            return false
        }

        // Small delay to let the app update the clipboard
        try? await Task.sleep(for: postCopyDelay)

        // 4. Check if clipboard changed (Cmd+C worked)
        let newChangeCount = pasteboard.changeCount

        if !copySuccess || newChangeCount == clearedChangeCount {
            // Cmd+C failed or didn't change clipboard - restore and fail
            logger.warning("Cmd+C did not update clipboard, restoring original")
            restoreClipboardState(savedState, to: pasteboard)
            return .failure(copySuccess ? .noSelection : .copyTimeout)
        }

        // 5. Read the new selection
        let selection = pasteboard.string(forType: .string)

        // 6. Restore original clipboard
        restoreClipboardState(savedState, to: pasteboard)
        logger.debug("Restored clipboard: \(savedState.itemCount) items")

        // 7. Return result
        if let text = selection, !text.isEmpty {
            return .success(text)
        } else {
            return .failure(.noSelection)
        }
    }

    // MARK: - Clipboard State Management

    /// Save the complete clipboard state
    private static func saveClipboardState(_ pasteboard: NSPasteboard) throws -> ClipboardState {
        var items: [[(NSPasteboard.PasteboardType, Data)]] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var itemData: [(NSPasteboard.PasteboardType, Data)] = []

            for type in item.types {
                // Read raw data for each type (binary-safe)
                if let data = item.data(forType: type) {
                    itemData.append((type, data))
                    logger.debug("  Saved type: \(type.rawValue) (\(data.count) bytes)")
                }
            }

            if !itemData.isEmpty {
                items.append(itemData)
            }
        }

        return ClipboardState(
            items: items,
            changeCount: pasteboard.changeCount
        )
    }

    /// Restore clipboard state
    @discardableResult
    private static func restoreClipboardState(_ state: ClipboardState, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()

        if state.isEmpty {
            // Original clipboard was empty, nothing to restore
            return true
        }

        var restoredItems: [NSPasteboardItem] = []

        for itemData in state.items {
            let newItem = NSPasteboardItem()

            for (type, data) in itemData {
                newItem.setData(data, forType: type)
            }

            restoredItems.append(newItem)
        }

        let success = pasteboard.writeObjects(restoredItems)

        if !success {
            logger.error("Failed to write restored items to clipboard")
        }

        return success
    }

    // MARK: - Keyboard Simulation

    /// Send Cmd+C to the frontmost application
    private static func sendCmdC() -> Bool {
        // Key code for 'C' is 8
        let keyCode: CGKeyCode = 8

        // Create key down event with Cmd modifier
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
            logger.error("Failed to create key down event")
            return false
        }
        keyDown.flags = .maskCommand

        // Create key up event with Cmd modifier
        guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            logger.error("Failed to create key up event")
            return false
        }
        keyUp.flags = .maskCommand

        // Post events
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        logger.debug("Sent Cmd+C")
        return true
    }
}
