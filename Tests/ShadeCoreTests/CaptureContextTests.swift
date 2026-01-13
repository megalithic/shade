import XCTest
@testable import ShadeCore

final class CaptureContextTests: XCTestCase {

    // MARK: - isImageCapture Tests

    func testIsImageCapture_TrueWhenImageFilenameSet() {
        let context = CaptureContext(imageFilename: "20260112-143045.png")

        XCTAssertTrue(context.isImageCapture)
    }

    func testIsImageCapture_TrueWhenTempImagePathSet() {
        let context = CaptureContext(tempImagePath: "/tmp/screenshot.png")

        XCTAssertTrue(context.isImageCapture)
    }

    func testIsImageCapture_TrueWhenBothSet() {
        let context = CaptureContext(
            imageFilename: "20260112-143045.png",
            tempImagePath: "/tmp/screenshot.png"
        )

        XCTAssertTrue(context.isImageCapture)
    }

    func testIsImageCapture_FalseWhenNeitherSet() {
        let context = CaptureContext(appType: "browser", url: "https://example.com")

        XCTAssertFalse(context.isImageCapture)
    }

    // MARK: - needsImageProcessing Tests

    func testNeedsImageProcessing_TrueWhenTempPathWithoutFilename() {
        let context = CaptureContext(tempImagePath: "/tmp/screenshot.png")

        XCTAssertTrue(context.needsImageProcessing)
    }

    func testNeedsImageProcessing_FalseWhenImageFilenameSet() {
        let context = CaptureContext(
            imageFilename: "20260112-143045.png",
            tempImagePath: "/tmp/screenshot.png"
        )

        XCTAssertFalse(context.needsImageProcessing)
    }

    func testNeedsImageProcessing_FalseWhenOnlyFilenameSet() {
        let context = CaptureContext(imageFilename: "20260112-143045.png")

        XCTAssertFalse(context.needsImageProcessing)
    }

    func testNeedsImageProcessing_FalseWhenNeitherSet() {
        let context = CaptureContext()

        XCTAssertFalse(context.needsImageProcessing)
    }

    // MARK: - JSON Encoding/Decoding Tests

    func testJSON_EncodesAllFields() throws {
        let context = CaptureContext(
            appType: "browser",
            appName: "Safari",
            windowTitle: "Test Page",
            url: "https://example.com",
            filePath: "/path/to/file.txt",
            selection: "selected text",
            detectedLanguage: "swift",
            timestamp: "2026-01-12T14:30:45Z",
            imageFilename: "image.png",
            tempImagePath: "/tmp/temp.png"
        )

        let data = try context.toJSON()
        let decoded = try CaptureContext.fromJSON(data)

        XCTAssertEqual(context, decoded)
    }

    func testJSON_EncodesWithCamelCaseKeys() throws {
        let context = CaptureContext(
            appType: "browser",
            windowTitle: "Test",
            imageFilename: "image.png",
            tempImagePath: "/tmp/temp.png"
        )

        let json = try context.toJSONString()

        XCTAssertTrue(json.contains("\"appType\""))
        XCTAssertTrue(json.contains("\"windowTitle\""))
        XCTAssertTrue(json.contains("\"imageFilename\""))
        XCTAssertTrue(json.contains("\"tempImagePath\""))
    }

    func testJSON_DecodesFromCamelCaseKeys() throws {
        let json = """
        {
            "appType": "terminal",
            "appName": "Ghostty",
            "windowTitle": "nvim",
            "filePath": "/code/main.swift",
            "detectedLanguage": "swift"
        }
        """

        let context = try CaptureContext.fromJSONString(json)

        XCTAssertEqual(context.appType, "terminal")
        XCTAssertEqual(context.appName, "Ghostty")
        XCTAssertEqual(context.windowTitle, "nvim")
        XCTAssertEqual(context.filePath, "/code/main.swift")
        XCTAssertEqual(context.detectedLanguage, "swift")
    }

    func testJSON_HandlesNilFields() throws {
        let context = CaptureContext(appType: "other")

        let data = try context.toJSON()
        let decoded = try CaptureContext.fromJSON(data)

        XCTAssertEqual(decoded.appType, "other")
        XCTAssertNil(decoded.appName)
        XCTAssertNil(decoded.windowTitle)
        XCTAssertNil(decoded.url)
        XCTAssertNil(decoded.filePath)
        XCTAssertNil(decoded.selection)
        XCTAssertNil(decoded.imageFilename)
        XCTAssertNil(decoded.tempImagePath)
        XCTAssertNil(decoded.extractedText)
        XCTAssertNil(decoded.ocrConfidence)
        XCTAssertNil(decoded.summary)
        XCTAssertNil(decoded.suggestedTags)
    }

    // MARK: - OCR Field Tests

    func testOCRFields_ExtractedText() {
        let context = CaptureContext(
            imageFilename: "test.png",
            extractedText: "Hello from OCR",
            ocrConfidence: 0.95
        )

        XCTAssertEqual(context.extractedText, "Hello from OCR")
        XCTAssertEqual(context.ocrConfidence, 0.95)
    }

    func testOCRFields_JSON_RoundTrip() throws {
        let context = CaptureContext(
            appType: "screenshot",
            imageFilename: "20260113-143045.png",
            extractedText: "OCR extracted this text\nWith multiple lines",
            ocrConfidence: 0.87
        )

        let data = try context.toJSON()
        let decoded = try CaptureContext.fromJSON(data)

        XCTAssertEqual(decoded.extractedText, context.extractedText)
        XCTAssertEqual(decoded.ocrConfidence, context.ocrConfidence)
    }

    func testOCRFields_EncodedInJSON() throws {
        let context = CaptureContext(
            extractedText: "Test text",
            ocrConfidence: 0.9
        )

        let json = try context.toJSONString()

        XCTAssertTrue(json.contains("\"extractedText\""))
        XCTAssertTrue(json.contains("\"ocrConfidence\""))
    }

    // MARK: - LLM Field Tests

    func testLLMFields_Summary() {
        let context = CaptureContext(
            imageFilename: "test.png",
            extractedText: "Original OCR text",
            summary: "A concise summary of the content"
        )

        XCTAssertEqual(context.summary, "A concise summary of the content")
    }

    func testLLMFields_SuggestedTags() {
        let context = CaptureContext(
            imageFilename: "test.png",
            suggestedTags: ["web-development", "api-design", "documentation"]
        )

        XCTAssertEqual(context.suggestedTags?.count, 3)
        XCTAssertEqual(context.suggestedTags?[0], "web-development")
        XCTAssertEqual(context.suggestedTags?[1], "api-design")
        XCTAssertEqual(context.suggestedTags?[2], "documentation")
    }

    func testLLMFields_JSON_RoundTrip() throws {
        let context = CaptureContext(
            appType: "screenshot",
            imageFilename: "20260113-143045.png",
            extractedText: "OCR extracted text",
            ocrConfidence: 0.92,
            summary: "This is a summary of the OCR content",
            suggestedTags: ["meeting-notes", "action-items"]
        )

        let data = try context.toJSON()
        let decoded = try CaptureContext.fromJSON(data)

        XCTAssertEqual(decoded.summary, context.summary)
        XCTAssertEqual(decoded.suggestedTags, context.suggestedTags)
    }

    func testLLMFields_EncodedInJSON() throws {
        let context = CaptureContext(
            summary: "Test summary",
            suggestedTags: ["tag1", "tag2"]
        )

        let json = try context.toJSONString()

        XCTAssertTrue(json.contains("\"summary\""))
        XCTAssertTrue(json.contains("\"suggestedTags\""))
        XCTAssertTrue(json.contains("\"tag1\""))
        XCTAssertTrue(json.contains("\"tag2\""))
    }

    func testLLMFields_DecodesFromJSON() throws {
        let json = """
        {
            "appType": "screenshot",
            "imageFilename": "capture.png",
            "extractedText": "Some OCR text",
            "summary": "Summary from LLM",
            "suggestedTags": ["swift", "ios-development"]
        }
        """

        let context = try CaptureContext.fromJSONString(json)

        XCTAssertEqual(context.summary, "Summary from LLM")
        XCTAssertEqual(context.suggestedTags, ["swift", "ios-development"])
    }

    func testLLMFields_EmptyTagsArray() throws {
        let context = CaptureContext(suggestedTags: [])

        let data = try context.toJSON()
        let decoded = try CaptureContext.fromJSON(data)

        XCTAssertEqual(decoded.suggestedTags, [])
    }

    func testJSON_PrettyPrintOption() throws {
        let context = CaptureContext(appType: "browser")

        let compact = try context.toJSONString(prettyPrint: false)
        let pretty = try context.toJSONString(prettyPrint: true)

        // Pretty print should be longer due to whitespace
        XCTAssertGreaterThan(pretty.count, compact.count)
        XCTAssertTrue(pretty.contains("\n"))
    }

    func testJSON_EmptyContext() throws {
        let context = CaptureContext()

        let data = try context.toJSON()
        let decoded = try CaptureContext.fromJSON(data)

        XCTAssertEqual(context, decoded)
    }

    func testJSONString_InvalidUTF8Throws() {
        // This tests error handling for malformed input
        let invalidJSON = "{ invalid json }"

        XCTAssertThrowsError(try CaptureContext.fromJSONString(invalidJSON))
    }

    // MARK: - Equatable Tests

    func testEquatable_EqualContexts() {
        let context1 = CaptureContext(
            appType: "browser",
            url: "https://example.com",
            imageFilename: "image.png"
        )
        let context2 = CaptureContext(
            appType: "browser",
            url: "https://example.com",
            imageFilename: "image.png"
        )

        XCTAssertEqual(context1, context2)
    }

    func testEquatable_DifferentContexts() {
        let context1 = CaptureContext(appType: "browser")
        let context2 = CaptureContext(appType: "terminal")

        XCTAssertNotEqual(context1, context2)
    }

    // MARK: - Init Tests

    func testInit_DefaultsAllToNil() {
        let context = CaptureContext()

        XCTAssertNil(context.appType)
        XCTAssertNil(context.appName)
        XCTAssertNil(context.windowTitle)
        XCTAssertNil(context.url)
        XCTAssertNil(context.filePath)
        XCTAssertNil(context.selection)
        XCTAssertNil(context.detectedLanguage)
        XCTAssertNil(context.timestamp)
        XCTAssertNil(context.imageFilename)
        XCTAssertNil(context.tempImagePath)
        XCTAssertNil(context.extractedText)
        XCTAssertNil(context.ocrConfidence)
        XCTAssertNil(context.summary)
        XCTAssertNil(context.suggestedTags)
    }

    func testInit_AcceptsAllParameters() {
        let context = CaptureContext(
            appType: "browser",
            appName: "Brave",
            windowTitle: "Example",
            url: "https://example.com",
            filePath: "/path/to/file",
            selection: "selected",
            detectedLanguage: "markdown",
            timestamp: "2026-01-12T14:30:45Z",
            imageFilename: "image.png",
            tempImagePath: "/tmp/temp.png",
            extractedText: "OCR text",
            ocrConfidence: 0.95,
            summary: "LLM summary",
            suggestedTags: ["tag1", "tag2"]
        )

        XCTAssertEqual(context.appType, "browser")
        XCTAssertEqual(context.appName, "Brave")
        XCTAssertEqual(context.windowTitle, "Example")
        XCTAssertEqual(context.url, "https://example.com")
        XCTAssertEqual(context.filePath, "/path/to/file")
        XCTAssertEqual(context.selection, "selected")
        XCTAssertEqual(context.detectedLanguage, "markdown")
        XCTAssertEqual(context.timestamp, "2026-01-12T14:30:45Z")
        XCTAssertEqual(context.imageFilename, "image.png")
        XCTAssertEqual(context.tempImagePath, "/tmp/temp.png")
        XCTAssertEqual(context.extractedText, "OCR text")
        XCTAssertEqual(context.ocrConfidence, 0.95)
        XCTAssertEqual(context.summary, "LLM summary")
        XCTAssertEqual(context.suggestedTags, ["tag1", "tag2"])
    }
}
