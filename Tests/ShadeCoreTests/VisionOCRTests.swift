import XCTest
@testable import ShadeCore

final class VisionOCRTests: XCTestCase {

    // MARK: - TextBlock Tests

    func testTextBlock_Init() {
        let block = TextBlock(
            text: "Hello World",
            confidence: 0.95,
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        )

        XCTAssertEqual(block.text, "Hello World")
        XCTAssertEqual(block.confidence, 0.95)
        XCTAssertEqual(block.boundingBox, CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
    }

    func testTextBlock_Equatable() {
        let block1 = TextBlock(text: "Test", confidence: 0.9, boundingBox: .zero)
        let block2 = TextBlock(text: "Test", confidence: 0.9, boundingBox: .zero)
        let block3 = TextBlock(text: "Different", confidence: 0.9, boundingBox: .zero)

        XCTAssertEqual(block1, block2)
        XCTAssertNotEqual(block1, block3)
    }

    // MARK: - OCRResult Tests

    func testOCRResult_Init() {
        let blocks = [
            TextBlock(text: "Line 1", confidence: 0.9, boundingBox: .zero),
            TextBlock(text: "Line 2", confidence: 0.8, boundingBox: .zero)
        ]

        let result = OCRResult(
            text: "Line 1\nLine 2",
            blocks: blocks,
            confidence: 0.85,
            observationCount: 2
        )

        XCTAssertEqual(result.text, "Line 1\nLine 2")
        XCTAssertEqual(result.blocks.count, 2)
        XCTAssertEqual(result.confidence, 0.85)
        XCTAssertEqual(result.observationCount, 2)
    }

    func testOCRResult_Empty() {
        let empty = OCRResult.empty

        XCTAssertEqual(empty.text, "")
        XCTAssertTrue(empty.blocks.isEmpty)
        XCTAssertEqual(empty.confidence, 0)
        XCTAssertEqual(empty.observationCount, 0)
    }

    func testOCRResult_HasText() {
        let withText = OCRResult(text: "Hello", blocks: [], confidence: 0.9, observationCount: 1)
        let withoutText = OCRResult.empty

        XCTAssertTrue(withText.hasText)
        XCTAssertFalse(withoutText.hasText)
    }

    func testOCRResult_TruncatedText_Short() {
        let result = OCRResult(text: "Short text", blocks: [], confidence: 0.9, observationCount: 1)

        XCTAssertEqual(result.truncatedText(maxLength: 100), "Short text")
    }

    func testOCRResult_TruncatedText_Long() {
        let longText = String(repeating: "A", count: 300)
        let result = OCRResult(text: longText, blocks: [], confidence: 0.9, observationCount: 1)

        let truncated = result.truncatedText(maxLength: 50)

        XCTAssertEqual(truncated.count, 53)  // 50 chars + "..."
        XCTAssertTrue(truncated.hasSuffix("..."))
    }

    func testOCRResult_Equatable() {
        let result1 = OCRResult(text: "Test", blocks: [], confidence: 0.9, observationCount: 1)
        let result2 = OCRResult(text: "Test", blocks: [], confidence: 0.9, observationCount: 1)
        let result3 = OCRResult(text: "Different", blocks: [], confidence: 0.9, observationCount: 1)

        XCTAssertEqual(result1, result2)
        XCTAssertNotEqual(result1, result3)
    }

    // MARK: - OCRError Tests

    func testOCRError_ImageLoadFailed() {
        let error = OCRError.imageLoadFailed("/path/to/image.png")

        XCTAssertEqual(error, .imageLoadFailed("/path/to/image.png"))
        XCTAssertTrue(error.errorDescription?.contains("/path/to/image.png") ?? false)
    }

    func testOCRError_CGImageCreationFailed() {
        let error = OCRError.cgImageCreationFailed

        XCTAssertEqual(error, .cgImageCreationFailed)
        XCTAssertNotNil(error.errorDescription)
    }

    func testOCRError_RecognitionFailed() {
        let error = OCRError.recognitionFailed("Some reason")

        XCTAssertEqual(error, .recognitionFailed("Some reason"))
        XCTAssertTrue(error.errorDescription?.contains("Some reason") ?? false)
    }

    // MARK: - VisionOCR Actor Tests

    func testVisionOCR_Init_Defaults() async {
        let ocr = VisionOCR()

        // Actor properties accessible
        let level = await ocr.recognitionLevel
        let languages = await ocr.languages
        let minConfidence = await ocr.minimumConfidence

        XCTAssertEqual(level, .accurate)
        XCTAssertNil(languages)
        XCTAssertEqual(minConfidence, 0.0)
    }

    func testVisionOCR_Init_CustomSettings() async {
        let ocr = VisionOCR(
            languages: ["en-US", "es-ES"],
            recognitionLevel: .fast,
            minimumConfidence: 0.5
        )

        let level = await ocr.recognitionLevel
        let languages = await ocr.languages
        let minConfidence = await ocr.minimumConfidence

        XCTAssertEqual(level, .fast)
        XCTAssertEqual(languages, ["en-US", "es-ES"])
        XCTAssertEqual(minConfidence, 0.5)
    }

    func testVisionOCR_ExtractText_InvalidPath() async {
        let ocr = VisionOCR()

        do {
            _ = try await ocr.extractText(from: "/nonexistent/image.png")
            XCTFail("Expected error for invalid path")
        } catch let error as OCRError {
            XCTAssertEqual(error, .imageLoadFailed("/nonexistent/image.png"))
        } catch {
            XCTFail("Expected OCRError, got: \(error)")
        }
    }

    // MARK: - Integration Test (requires real image)

    func testVisionOCR_ExtractText_RealImage() async throws {
        // Create a simple test image with text
        let testImagePath = NSTemporaryDirectory() + "ocr_test_image.png"

        // Create a simple image with text using Core Graphics
        let width = 200
        let height = 50
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create graphics context")
        }

        // Fill white background
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw "Hello" text
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let string = NSAttributedString(string: "Hello OCR", attributes: attributes)
        let line = CTLineCreateWithAttributedString(string)

        context.textPosition = CGPoint(x: 10, y: 15)
        CTLineDraw(line, context)

        guard let cgImage = context.makeImage() else {
            throw XCTSkip("Could not create test image")
        }

        // Save to file
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Could not save test image")
        }
        try pngData.write(to: URL(fileURLWithPath: testImagePath))

        defer {
            try? FileManager.default.removeItem(atPath: testImagePath)
        }

        // Run OCR
        let ocr = VisionOCR()
        let result = try await ocr.extractText(from: testImagePath)

        // Verify we got some text
        // Note: Exact text matching is fragile due to OCR variability
        XCTAssertTrue(result.hasText, "Expected OCR to extract some text")
        XCTAssertGreaterThan(result.observationCount, 0, "Expected at least one observation")
    }
}
