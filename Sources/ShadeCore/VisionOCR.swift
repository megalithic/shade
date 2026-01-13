import Foundation
import Vision
import AppKit

// MARK: - OCR Result Types

/// A block of recognized text with position and confidence
public struct TextBlock: Equatable, Sendable {
    /// The recognized text content
    public let text: String
    /// Confidence score (0.0 - 1.0)
    public let confidence: Float
    /// Bounding box in normalized coordinates (0-1, origin bottom-left)
    public let boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// Result of OCR text extraction
public struct OCRResult: Equatable, Sendable {
    /// Full extracted text (all blocks joined)
    public let text: String
    /// Individual text blocks with positions
    public let blocks: [TextBlock]
    /// Overall confidence (average of block confidences)
    public let confidence: Float
    /// Number of text observations found
    public let observationCount: Int

    public init(text: String, blocks: [TextBlock], confidence: Float, observationCount: Int) {
        self.text = text
        self.blocks = blocks
        self.confidence = confidence
        self.observationCount = observationCount
    }

    /// Empty result for images with no text
    public static let empty = OCRResult(text: "", blocks: [], confidence: 0, observationCount: 0)
}

// MARK: - OCR Errors

/// Errors that can occur during OCR processing
public enum OCRError: Error, LocalizedError, Equatable {
    case imageLoadFailed(String)
    case cgImageCreationFailed
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let path):
            return "Failed to load image: \(path)"
        case .cgImageCreationFailed:
            return "Failed to create CGImage from loaded image"
        case .recognitionFailed(let reason):
            return "Text recognition failed: \(reason)"
        }
    }
}

// MARK: - VisionOCR Actor

/// Actor for performing OCR using Apple Vision framework
/// Thread-safe, async-first design for integration with Swift concurrency
public actor VisionOCR {

    /// Recognition level: fast (less accurate) or accurate (slower)
    public enum RecognitionLevel: Sendable {
        case fast
        case accurate
    }

    /// Supported languages for recognition
    /// nil means auto-detect
    public let languages: [String]?

    /// Recognition level
    public let recognitionLevel: RecognitionLevel

    /// Minimum confidence threshold for including text blocks
    public let minimumConfidence: Float

    public init(
        languages: [String]? = nil,
        recognitionLevel: RecognitionLevel = .accurate,
        minimumConfidence: Float = 0.0
    ) {
        self.languages = languages
        self.recognitionLevel = recognitionLevel
        self.minimumConfidence = minimumConfidence
    }

    /// Extract text from an image file
    /// - Parameter imagePath: Path to the image file
    /// - Returns: OCRResult containing extracted text and metadata
    public func extractText(from imagePath: String) async throws -> OCRResult {
        shadeLogger.debug("VisionOCR: Starting extraction from \(imagePath)")

        // Load image
        guard let nsImage = NSImage(contentsOfFile: imagePath) else {
            shadeLogger.error("VisionOCR: Failed to load image: \(imagePath)")
            throw OCRError.imageLoadFailed(imagePath)
        }

        // Convert to CGImage
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            shadeLogger.error("VisionOCR: Failed to create CGImage")
            throw OCRError.cgImageCreationFailed
        }

        return try await extractText(from: cgImage)
    }

    /// Extract text from a CGImage
    /// - Parameter cgImage: The image to process
    /// - Returns: OCRResult containing extracted text and metadata
    public func extractText(from cgImage: CGImage) async throws -> OCRResult {
        // Create request
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = true

        // Set languages if specified
        if let languages = languages {
            request.recognitionLanguages = languages
        }

        // Perform recognition
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            shadeLogger.error("VisionOCR: Recognition failed: \(error)")
            throw OCRError.recognitionFailed(error.localizedDescription)
        }

        // Process results
        guard let observations = request.results else {
            shadeLogger.debug("VisionOCR: No results returned")
            return .empty
        }

        var blocks: [TextBlock] = []
        var totalConfidence: Float = 0

        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else {
                continue
            }

            let confidence = topCandidate.confidence
            if confidence < minimumConfidence {
                continue
            }

            let block = TextBlock(
                text: topCandidate.string,
                confidence: confidence,
                boundingBox: observation.boundingBox
            )
            blocks.append(block)
            totalConfidence += confidence
        }

        // Sort blocks by position (top to bottom, left to right)
        blocks.sort { b1, b2 in
            // Compare Y first (higher Y = higher on page in Vision coordinates)
            if abs(b1.boundingBox.midY - b2.boundingBox.midY) > 0.02 {
                return b1.boundingBox.midY > b2.boundingBox.midY
            }
            // Then X (left to right)
            return b1.boundingBox.midX < b2.boundingBox.midX
        }

        // Join text with newlines for blocks on different lines
        let text = blocks.map(\.text).joined(separator: "\n")
        let avgConfidence = blocks.isEmpty ? 0 : totalConfidence / Float(blocks.count)

        shadeLogger.info("VisionOCR: Extracted \(blocks.count) blocks, avg confidence: \(String(format: "%.2f", avgConfidence))")

        return OCRResult(
            text: text,
            blocks: blocks,
            confidence: avgConfidence,
            observationCount: observations.count
        )
    }
}

// MARK: - Convenience Extensions

extension OCRResult {
    /// Whether the OCR found any text
    public var hasText: Bool {
        !text.isEmpty
    }

    /// Text truncated to a maximum length with ellipsis
    public func truncatedText(maxLength: Int = 200) -> String {
        if text.count <= maxLength {
            return text
        }
        return String(text.prefix(maxLength)) + "..."
    }
}
