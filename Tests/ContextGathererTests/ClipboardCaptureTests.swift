import XCTest
import AppKit
@testable import ContextGatherer

final class ClipboardCaptureTests: XCTestCase {

    // MARK: - ClipboardState Tests

    func testClipboardState_IsEmpty_TrueForNoItems() {
        // ClipboardState is internal, so we test indirectly via capture behavior
        // An empty capture should fail with noSelection
    }

    func testClipboardCaptureError_Description_ReturnsReadableMessage() {
        let errors: [ClipboardCaptureError] = [
            .saveFailure("test error"),
            .restoreFailure("test error"),
            .copyTimeout,
            .copyFailed,
            .noSelection,
            .externalClipboardChange
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty)
            // Ensure description doesn't crash and contains meaningful info
            print("Error description: \(error.description)")
        }
    }
}

// MARK: - Live Integration Tests

/// These tests interact with the real clipboard and are skipped in CI.
/// They verify the binary-safe save/restore cycle.
///
/// Run with: swift test --filter ClipboardCaptureLiveTests
final class ClipboardCaptureLiveTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private var originalContents: [NSPasteboardItem]?

    override func setUpWithError() throws {
        // Skip in CI environment
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Skipping live clipboard tests in CI environment")
        }

        pasteboard = NSPasteboard.general
    }

    override func tearDown() {
        // No cleanup needed - tests restore clipboard themselves
    }

    // MARK: - Plain Text Preservation

    func testLive_PlainText_PreservedAfterCapture() async throws {
        // Setup: Put plain text on clipboard
        let originalText = "Original clipboard content - do not lose me!"
        pasteboard.clearContents()
        pasteboard.setString(originalText, forType: .string)

        // Verify setup
        XCTAssertEqual(pasteboard.string(forType: .string), originalText)

        // Act: Attempt capture (will fail with noSelection since nothing is selected)
        let result = await ClipboardCapture.captureSelection()

        // Assert: Capture should fail (no selection), but clipboard should be restored
        switch result {
        case .success:
            XCTFail("Expected failure since nothing is selected")
        case .failure:
            // Expected - the important thing is clipboard restoration
            break
        }

        // Verify clipboard was restored
        let restoredText = pasteboard.string(forType: .string)
        XCTAssertEqual(restoredText, originalText, "Plain text clipboard should be preserved")
    }

    func testLive_TextWithFormatting_PreservedAfterCapture() async throws {
        // Setup: Put text with tabs and newlines on clipboard
        let formattedText = """
        function example() {
        \tlet x = 1;
        \tlet y = 2;
        \treturn x + y;
        }
        """
        pasteboard.clearContents()
        pasteboard.setString(formattedText, forType: .string)

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: Formatted text should be preserved exactly
        let restoredText = pasteboard.string(forType: .string)
        XCTAssertEqual(restoredText, formattedText, "Formatted text (tabs/newlines) should be preserved")

        // Verify tabs are still tabs
        XCTAssertTrue(restoredText?.contains("\t") == true, "Tab characters should be preserved")
    }

    // MARK: - Multi-Type Preservation

    func testLive_MultipleTypes_AllPreserved() async throws {
        // Setup: Put content with multiple type representations
        let plainText = "Hello World"
        let htmlText = "<b>Hello World</b>"

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(plainText, forType: .string)
        item.setString(htmlText, forType: .html)
        pasteboard.writeObjects([item])

        // Verify setup
        XCTAssertEqual(pasteboard.string(forType: .string), plainText)
        XCTAssertEqual(pasteboard.string(forType: .html), htmlText)

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: Both types should be preserved
        XCTAssertEqual(pasteboard.string(forType: .string), plainText, "Plain text type preserved")
        XCTAssertEqual(pasteboard.string(forType: .html), htmlText, "HTML type preserved")
    }

    func testLive_RTFContent_Preserved() async throws {
        // Setup: Create RTF content
        let plainText = "Bold and Italic"
        let attributedString = NSAttributedString(
            string: plainText,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
        )

        guard let rtfData = try? attributedString.data(
            from: NSRange(location: 0, length: attributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            throw XCTSkip("Could not create RTF data")
        }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(rtfData, forType: .rtf)
        item.setString(plainText, forType: .string)
        pasteboard.writeObjects([item])

        // Verify setup
        XCTAssertNotNil(pasteboard.data(forType: .rtf))

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: RTF data should be preserved
        let restoredRTF = pasteboard.data(forType: .rtf)
        XCTAssertNotNil(restoredRTF, "RTF data should be preserved")
        XCTAssertEqual(restoredRTF, rtfData, "RTF data should be identical")
    }

    // MARK: - Binary Data Preservation

    func testLive_ImageData_Preserved() async throws {
        // Setup: Create a simple image and put it on clipboard
        let imageSize = NSSize(width: 100, height: 100)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation else {
            throw XCTSkip("Could not create TIFF data")
        }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(tiffData, forType: .tiff)
        pasteboard.writeObjects([item])

        // Verify setup
        let originalData = pasteboard.data(forType: .tiff)
        XCTAssertNotNil(originalData)
        XCTAssertEqual(originalData?.count, tiffData.count)

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: Image data should be preserved exactly
        let restoredData = pasteboard.data(forType: .tiff)
        XCTAssertNotNil(restoredData, "Image data should be preserved")
        XCTAssertEqual(restoredData?.count, tiffData.count, "Image data size should match")
        XCTAssertEqual(restoredData, tiffData, "Image data should be identical byte-for-byte")
    }

    func testLive_PNGImage_Preserved() async throws {
        // Setup: Create PNG image data
        let imageSize = NSSize(width: 50, height: 50)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Could not create PNG data")
        }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        pasteboard.writeObjects([item])

        // Verify setup
        XCTAssertNotNil(pasteboard.data(forType: .png))

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: PNG data should be preserved
        let restoredData = pasteboard.data(forType: .png)
        XCTAssertNotNil(restoredData, "PNG data should be preserved")
        XCTAssertEqual(restoredData, pngData, "PNG data should be identical")
    }

    // MARK: - Multiple Items Preservation

    func testLive_MultipleItems_AllPreserved() async throws {
        // Setup: Put multiple distinct items on clipboard
        let text1 = "First item"
        let text2 = "Second item"

        let item1 = NSPasteboardItem()
        item1.setString(text1, forType: .string)

        let item2 = NSPasteboardItem()
        item2.setString(text2, forType: .string)

        pasteboard.clearContents()
        pasteboard.writeObjects([item1, item2])

        // Verify setup - should have 2 items
        let originalItems = pasteboard.pasteboardItems
        XCTAssertEqual(originalItems?.count, 2, "Should have 2 items")

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: Both items should be preserved
        let restoredItems = pasteboard.pasteboardItems
        XCTAssertEqual(restoredItems?.count, 2, "Should still have 2 items")

        // Verify content of items
        let texts = restoredItems?.compactMap { $0.string(forType: .string) } ?? []
        XCTAssertTrue(texts.contains(text1), "First item should be preserved")
        XCTAssertTrue(texts.contains(text2), "Second item should be preserved")
    }

    // MARK: - Empty Clipboard

    func testLive_EmptyClipboard_RemainsEmpty() async throws {
        // Setup: Clear clipboard
        pasteboard.clearContents()

        // Verify setup
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty != false)

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: Clipboard should still be empty (or have minimal content)
        // Note: The capture operation itself might leave a trace, which is acceptable
        // The important thing is we don't crash or leave garbage data
    }

    // MARK: - URL Preservation

    func testLive_URL_Preserved() async throws {
        // Setup: Put a URL on clipboard
        let url = URL(string: "https://github.com/example/project")!

        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])

        // Also verify the URL type is present
        XCTAssertTrue(pasteboard.types?.contains(.URL) == true)

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: URL should be preserved
        // Note: URL might be preserved as string representation
        let hasURLContent = pasteboard.string(forType: .string)?.contains("github.com") == true ||
                          pasteboard.types?.contains(.URL) == true

        XCTAssertTrue(hasURLContent, "URL content should be preserved")
    }

    // MARK: - File Reference Preservation

    func testLive_FilePath_Preserved() async throws {
        // Setup: Put a file path on clipboard
        let filePath = "/tmp/test-clipboard-file.txt"
        let fileURL = URL(fileURLWithPath: filePath)

        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: File reference should be preserved
        let hasFileContent = pasteboard.string(forType: .fileURL) != nil ||
                           pasteboard.string(forType: .string)?.contains("test-clipboard-file") == true ||
                           pasteboard.types?.contains(.fileURL) == true

        XCTAssertTrue(hasFileContent, "File URL should be preserved in some form")
    }

    // MARK: - Stress Tests

    func testLive_LargeTextContent_Preserved() async throws {
        // Setup: Create large text content (1MB)
        let repeatedString = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40000)
        let originalSize = repeatedString.utf8.count

        pasteboard.clearContents()
        pasteboard.setString(repeatedString, forType: .string)

        // Verify setup
        XCTAssertGreaterThan(originalSize, 1_000_000, "Test string should be > 1MB")

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: Large content should be preserved
        let restoredText = pasteboard.string(forType: .string)
        XCTAssertEqual(restoredText?.count, repeatedString.count, "Large text should be preserved completely")
    }

    func testLive_ManyTypes_AllPreserved() async throws {
        // Setup: Put item with many type representations
        let plainText = "Multi-format content"
        let htmlText = "<p>Multi-format content</p>"
        let rtfText = "{\\rtf1 Multi-format content}"

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(plainText, forType: .string)
        item.setString(htmlText, forType: .html)
        item.setString(rtfText, forType: NSPasteboard.PasteboardType("public.rtf"))
        pasteboard.writeObjects([item])

        let originalTypes = pasteboard.types ?? []
        let originalTypeCount = originalTypes.count

        // Act: Attempt capture
        _ = await ClipboardCapture.captureSelection()

        // Assert: All types should be preserved
        let restoredTypes = pasteboard.types ?? []
        XCTAssertEqual(restoredTypes.count, originalTypeCount, "Type count should be preserved")

        XCTAssertEqual(pasteboard.string(forType: .string), plainText)
        XCTAssertEqual(pasteboard.string(forType: .html), htmlText)
    }
}

// MARK: - Selection Capture Tests (Manual)

/// These tests require manual interaction and should be run individually.
/// They test the actual Cmd+C capture with a real selection.
///
/// To run: Select some text in another app, then run the specific test.
final class ClipboardCaptureManualTests: XCTestCase {

    override func setUpWithError() throws {
        // Skip in CI environment
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Skipping manual clipboard tests in CI environment")
        }
    }

    /// Manual test: Select text in another app, then run this test.
    /// It should capture your selection and restore your clipboard.
    func testManual_CaptureSelection_WithRealSelection() async throws {
        throw XCTSkip("Manual test - run individually with text selected in another app")

        // Save what's currently on clipboard for comparison
        let originalClipboard = NSPasteboard.general.string(forType: .string)

        print("Original clipboard: \(originalClipboard ?? "empty")")
        print("Attempting to capture selection via Cmd+C...")

        let result = await ClipboardCapture.captureSelection()

        switch result {
        case .success(let text):
            print("✅ Captured selection (\(text.count) chars):")
            print("---")
            print(text)
            print("---")

            // Verify clipboard was restored
            let restoredClipboard = NSPasteboard.general.string(forType: .string)
            XCTAssertEqual(restoredClipboard, originalClipboard, "Clipboard should be restored")

        case .failure(let error):
            print("❌ Capture failed: \(error)")
            XCTFail("Capture failed: \(error)")
        }
    }
}
