import Foundation
import MLXLLM
import MLXLMCommon
import ContextGatherer

// MARK: - Error Types

/// Errors that can occur during MLX inference
enum MLXInferenceError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(String)
    case generationFailed(String)
    case llmDisabled
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "MLX model not loaded"
        case .modelLoadFailed(let reason):
            return "Failed to load MLX model: \(reason)"
        case .generationFailed(let reason):
            return "Text generation failed: \(reason)"
        case .llmDisabled:
            return "LLM features are disabled in config"
        case .emptyInput:
            return "Cannot process empty input"
        }
    }
}

// MARK: - Summarization Style

/// Style presets for summarization output
enum SummarizationStyle: String, Sendable {
    /// 1-2 sentence summary, very concise
    case concise
    /// 2-3 sentences with key details
    case brief
    /// Bullet points of main topics
    case bullets
    /// Technical/factual summary
    case technical

    var systemPrompt: String {
        switch self {
        case .concise:
            return "You are a precise summarizer. Provide a 1-2 sentence summary that captures the essential meaning. Be factual and concise."
        case .brief:
            return "You are a skilled summarizer. Provide a 2-3 sentence summary that includes key details and context. Be clear and informative."
        case .bullets:
            return "You are a skilled summarizer. Extract the main points as a bulleted list. Use 3-5 bullet points maximum."
        case .technical:
            return "You are a technical writer. Summarize the content focusing on technical details, data, and specific information. Be precise."
        }
    }

    var userPromptPrefix: String {
        switch self {
        case .concise:
            return "Summarize in 1-2 sentences:\n\n"
        case .brief:
            return "Summarize the following, including key details:\n\n"
        case .bullets:
            return "Extract the main points as bullet points:\n\n"
        case .technical:
            return "Provide a technical summary of:\n\n"
        }
    }
}

// MARK: - Model Status

/// Status information about the loaded model
struct MLXModelStatus: Sendable {
    let isLoaded: Bool
    let modelId: String?
    let loadTime: Date?
}

// MARK: - MLX Inference Engine

/// Actor for on-device LLM inference using MLX Swift
///
/// MLXInferenceEngine provides lazy-loaded, thread-safe access to MLX models.
/// Models are downloaded and loaded on first use to minimize startup time.
///
/// Usage:
/// ```swift
/// let engine = MLXInferenceEngine()
/// let summary = try await engine.summarize(ocrText, style: .concise)
/// ```
actor MLXInferenceEngine {

    // MARK: - State

    /// The loaded model container (nil until first use)
    private var modelContainer: ModelContainer?

    /// Chat session for multi-turn conversations
    private var chatSession: ChatSession?

    /// Configuration from ShadeConfig
    private let config: LLMConfig

    /// When the model was loaded
    private var loadTime: Date?

    /// Whether a model load is in progress
    private var isLoading = false

    /// Progress callback for model downloads (must be Sendable for actor isolation)
    private var downloadProgress: (@Sendable (Double) -> Void)?

    // MARK: - Initialization

    /// Initialize with configuration from ShadeConfig
    init(config: LLMConfig? = nil) {
        self.config = config ?? ShadeConfig.shared.llm ?? LLMConfig()
    }

    // MARK: - Model Loading

    /// Ensure the model is loaded, downloading if necessary
    /// This is called automatically before any inference
    func ensureModelLoaded() async throws {
        // Check if LLM is enabled
        guard config.enabled else {
            throw MLXInferenceError.llmDisabled
        }

        // Already loaded
        if modelContainer != nil {
            return
        }

        // Prevent concurrent loading
        guard !isLoading else {
            // Wait for existing load to complete
            while isLoading {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            return
        }

        isLoading = true
        defer { isLoading = false }

        let modelId = config.model
        Log.info("Loading MLX model: \(modelId)")

        do {
            let startTime = Date()

            // Capture progress handler before async work (for actor isolation)
            let progressHandler = self.downloadProgress

            // Load model with progress handler
            let container = try await loadModelContainer(id: modelId) { progress in
                let pct = progress.fractionCompleted
                Log.debug("Model download: \(Int(pct * 100))%")
                // Call captured handler (already Sendable)
                progressHandler?(pct)
            }

            let elapsed = Date().timeIntervalSince(startTime)
            Log.info("Model loaded in \(String(format: "%.1f", elapsed))s")

            self.modelContainer = container
            self.loadTime = Date()

            // Create chat session with default instructions
            let generateParams = makeGenerateParameters()
            self.chatSession = ChatSession(
                container,
                instructions: nil,  // No persistent system prompt - we set per-request
                generateParameters: generateParams
            )

        } catch {
            Log.error("Failed to load model: \(error.localizedDescription)")
            throw MLXInferenceError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Set a callback for download progress (0.0-1.0)
    func setDownloadProgressHandler(_ handler: @escaping @Sendable (Double) -> Void) {
        self.downloadProgress = handler
    }

    // MARK: - Summarization

    /// Summarize text using the configured LLM
    ///
    /// - Parameters:
    ///   - text: The text to summarize (e.g., OCR output, clipboard content)
    ///   - style: Summarization style (default: .concise)
    /// - Returns: The generated summary
    func summarize(_ text: String, style: SummarizationStyle = .concise) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLXInferenceError.emptyInput
        }

        try await ensureModelLoaded()

        guard modelContainer != nil else {
            throw MLXInferenceError.modelNotLoaded
        }

        // Build prompt with style-specific instructions
        let prompt = style.userPromptPrefix + text

        Log.debug("Generating summary (style: \(style.rawValue), input length: \(text.count))")

        do {
            // Create a fresh session with the style-specific system prompt
            // This ensures each summarization request is independent
            let generateParams = makeGenerateParameters()
            let freshSession = ChatSession(
                modelContainer!,
                instructions: style.systemPrompt,
                generateParameters: generateParams
            )

            let response = try await freshSession.respond(to: prompt)

            Log.debug("Generated summary: \(response.count) chars")
            return response.trimmingCharacters(in: .whitespacesAndNewlines)

        } catch {
            Log.error("Generation failed: \(error.localizedDescription)")
            throw MLXInferenceError.generationFailed(error.localizedDescription)
        }
    }

    // MARK: - Categorization

    /// Categorize text and suggest tags based on content and context
    ///
    /// - Parameters:
    ///   - text: The text to categorize (e.g., OCR output, note content)
    ///   - context: Optional capture context (source app, URL, etc.)
    /// - Returns: Array of suggested tags (lowercase, hyphenated)
    func categorize(_ text: String, context: GatheredContext? = nil) async throws -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLXInferenceError.emptyInput
        }

        try await ensureModelLoaded()

        guard modelContainer != nil else {
            throw MLXInferenceError.modelNotLoaded
        }

        // Build context-aware prompt
        let contextInfo = buildContextInfo(from: context)
        let prompt = buildCategorizationPrompt(text: text, contextInfo: contextInfo)

        Log.debug("Categorizing (input length: \(text.count), has context: \(context != nil))")

        do {
            let generateParams = makeGenerateParameters()
            let session = ChatSession(
                modelContainer!,
                instructions: """
                You are a tagging assistant. Given text and optional context, suggest 2-4 relevant tags.
                Tags should be lowercase, hyphenated (e.g., "web-development", "meeting-notes").
                Return ONLY the tags, comma-separated, no explanation.
                """,
                generateParameters: generateParams
            )

            let response = try await session.respond(to: prompt)

            Log.debug("Categorization response: \(response)")
            return parseTagsResponse(response)

        } catch {
            Log.error("Categorization failed: \(error.localizedDescription)")
            throw MLXInferenceError.generationFailed(error.localizedDescription)
        }
    }

    /// Build context information string for the prompt
    private func buildContextInfo(from context: GatheredContext?) -> String {
        guard let ctx = context else { return "" }

        var parts: [String] = []

        if let appType = ctx.appType, !appType.isEmpty {
            parts.append("Source type: \(appType)")
        }
        if let appName = ctx.appName, !appName.isEmpty {
            parts.append("App: \(appName)")
        }
        if let url = ctx.url, !url.isEmpty {
            parts.append("URL: \(url)")
        }
        if let filePath = ctx.filePath, !filePath.isEmpty {
            // Just show filename, not full path
            let filename = (filePath as NSString).lastPathComponent
            parts.append("File: \(filename)")
        }
        if let filetype = ctx.filetype, !filetype.isEmpty {
            parts.append("Filetype: \(filetype)")
        }
        if let lang = ctx.detectedLanguage, !lang.isEmpty {
            parts.append("Language: \(lang)")
        }

        return parts.isEmpty ? "" : parts.joined(separator: ", ")
    }

    /// Build the categorization prompt
    private func buildCategorizationPrompt(text: String, contextInfo: String) -> String {
        var prompt = "Suggest 2-4 tags for this content"
        if !contextInfo.isEmpty {
            prompt += " (\(contextInfo))"
        }
        prompt += ":\n\n\(text)"
        return prompt
    }

    /// Parse the model's tag response into an array
    private func parseTagsResponse(_ response: String) -> [String] {
        // Model should return comma-separated tags
        // Handle various formats: "tag1, tag2" or "tag1,tag2" or "- tag1\n- tag2"
        let cleaned = response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "\n", with: ",")

        return cleaned
            .split(separator: ",")
            .map { tag in
                tag.trimmingCharacters(in: .whitespaces)
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .replacingOccurrences(of: "#", with: "")  // Remove any hashtags
            }
            .filter { !$0.isEmpty && $0.count > 1 }  // Filter empty and single-char
            .prefix(5)  // Max 5 tags
            .map { String($0) }
    }

    // MARK: - Model Management

    /// Get current model status
    func status() -> MLXModelStatus {
        MLXModelStatus(
            isLoaded: modelContainer != nil,
            modelId: modelContainer != nil ? config.model : nil,
            loadTime: loadTime
        )
    }

    /// Unload the model to free memory
    func unloadModel() {
        Log.info("Unloading MLX model")
        chatSession = nil
        modelContainer = nil
        loadTime = nil
    }

    /// Check if the model is currently loaded
    var isModelLoaded: Bool {
        modelContainer != nil
    }

    // MARK: - Private Helpers

    /// Create GenerateParameters from config
    private func makeGenerateParameters() -> GenerateParameters {
        GenerateParameters(
            maxTokens: config.maxTokens,
            temperature: Float(config.temperature),
            topP: Float(config.topP),
            repetitionPenalty: 1.1,  // Slight penalty to avoid repetition
            repetitionContextSize: 20
        )
    }
}

// MARK: - Convenience Extensions

extension MLXInferenceEngine {

    /// Quick summarize with default style
    func summarize(_ text: String) async throws -> String {
        try await summarize(text, style: .concise)
    }
}
