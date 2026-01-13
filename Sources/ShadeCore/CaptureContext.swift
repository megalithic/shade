import Foundation

/// Context passed from Hammerspoon for quick capture
/// Used for JSON serialization between Hammerspoon, Shade, and obsidian.nvim
public struct CaptureContext: Codable, Equatable {
    /// App type: "browser", "terminal", "neovim", "screenshot", "other"
    public var appType: String?

    /// Application name: "Brave Browser", etc.
    public var appName: String?

    /// Window title
    public var windowTitle: String?

    /// URL if browser
    public var url: String?

    /// File path if editor
    public var filePath: String?

    /// Selected text
    public var selection: String?

    /// Detected language for code
    public var detectedLanguage: String?

    /// ISO8601 timestamp
    public var timestamp: String?

    /// Image filename for processed captures (e.g., "20260108-123456.png")
    /// Set by Shade after processing tempImagePath
    public var imageFilename: String?

    /// Temporary image path from Hammerspoon
    /// Shade processes this, copies to assets, and replaces with imageFilename
    public var tempImagePath: String?

    /// Text extracted from image via OCR (VisionKit)
    /// Set by Shade after running VisionOCR on the image
    public var extractedText: String?

    /// OCR confidence score (0.0 - 1.0)
    /// Average confidence across all text blocks
    public var ocrConfidence: Float?

    public init(
        appType: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        filePath: String? = nil,
        selection: String? = nil,
        detectedLanguage: String? = nil,
        timestamp: String? = nil,
        imageFilename: String? = nil,
        tempImagePath: String? = nil,
        extractedText: String? = nil,
        ocrConfidence: Float? = nil
    ) {
        self.appType = appType
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.filePath = filePath
        self.selection = selection
        self.detectedLanguage = detectedLanguage
        self.timestamp = timestamp
        self.imageFilename = imageFilename
        self.tempImagePath = tempImagePath
        self.extractedText = extractedText
        self.ocrConfidence = ocrConfidence
    }

    enum CodingKeys: String, CodingKey {
        case appType = "appType"
        case appName = "appName"
        case windowTitle = "windowTitle"
        case url = "url"
        case filePath = "filePath"
        case selection = "selection"
        case detectedLanguage = "detectedLanguage"
        case timestamp = "timestamp"
        case imageFilename = "imageFilename"
        case tempImagePath = "tempImagePath"
        case extractedText = "extractedText"
        case ocrConfidence = "ocrConfidence"
    }

    /// Whether this is an image capture (from clipper)
    /// Checks for either processed imageFilename or unprocessed tempImagePath
    public var isImageCapture: Bool {
        imageFilename != nil || tempImagePath != nil
    }

    /// Whether this capture needs image processing
    /// True if we have a temp path but no final filename yet
    public var needsImageProcessing: Bool {
        tempImagePath != nil && imageFilename == nil
    }
}

// MARK: - JSON Convenience

extension CaptureContext {
    /// Decode from JSON data
    public static func fromJSON(_ data: Data) throws -> CaptureContext {
        try JSONDecoder().decode(CaptureContext.self, from: data)
    }

    /// Encode to JSON data
    public func toJSON(prettyPrint: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrint {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(self)
    }

    /// Decode from JSON string
    public static func fromJSONString(_ string: String) throws -> CaptureContext {
        guard let data = string.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Invalid UTF-8 string")
            )
        }
        return try fromJSON(data)
    }

    /// Encode to JSON string
    public func toJSONString(prettyPrint: Bool = false) throws -> String {
        let data = try toJSON(prettyPrint: prettyPrint)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                data,
                EncodingError.Context(codingPath: [], debugDescription: "Invalid UTF-8 data")
            )
        }
        return string
    }
}
