import Foundation
import ContextGatherer
import ShadeCore
@preconcurrency import MessagePack

/// Manages async LLM enrichment tasks for image captures.
///
/// When an image is captured and OCR'd, we want to:
/// 1. Show the note immediately with placeholders
/// 2. Run MLX summarization/categorization in the background
/// 3. Replace placeholders when MLX completes
/// 4. Cancel enrichment if the buffer closes
///
/// ## Usage
/// ```swift
/// let manager = AsyncEnrichmentManager.shared
///
/// // Start enrichment after opening capture note
/// let enrichmentId = await manager.startEnrichment(
///     bufferId: bufferId,
///     ocrText: ocrResult.text,
///     context: gatheredContext
/// )
///
/// // Enrichment runs in background, updates nvim when done
/// ```
actor AsyncEnrichmentManager {

    // MARK: - Singleton

    static let shared = AsyncEnrichmentManager()

    // MARK: - Types

    /// Unique identifier for an enrichment task
    struct EnrichmentID: Hashable, Sendable {
        let id: UUID

        init() { self.id = UUID() }
    }

    /// Represents a pending enrichment task
    struct PendingEnrichment: Sendable {
        let id: EnrichmentID
        let bufferId: Int64
        let ocrText: String
        let context: GatheredContext?
        let task: Task<Void, Never>
        let startTime: Date

        /// Placeholders inserted into the buffer
        var summaryPlaceholder: String { "<!-- shade:pending:summary -->" }
        var tagsPlaceholder: String { "<!-- shade:pending:tags -->" }
    }

    /// Result of an enrichment operation
    struct EnrichmentResult: Sendable {
        let summary: String?
        let tags: [String]?
        let error: String?

        var succeeded: Bool { error == nil && (summary != nil || tags != nil) }
    }

    // MARK: - State

    /// Active enrichments keyed by buffer ID
    /// One enrichment per buffer at a time
    private var pendingEnrichments: [Int64: PendingEnrichment] = [:]

    /// Subscription ID for buffer detach events
    private var detachSubscription: NvimEvents.SubscriptionID?

    /// Whether we've started listening for buffer events
    private var isListening = false

    /// Callback for pending count changes (called on count change with new count)
    private var countChangedHandler: (@Sendable (Int) -> Void)?

    /// Set a callback for when pending enrichment count changes
    func setCountChangedHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        self.countChangedHandler = handler
    }

    /// Notify count changed
    private func notifyCountChanged() {
        countChangedHandler?(pendingEnrichments.count)
    }

    // MARK: - Public API

    /// Start an async enrichment task for a buffer
    ///
    /// This kicks off background MLX inference and returns immediately.
    /// The manager will update the buffer when inference completes.
    ///
    /// - Parameters:
    ///   - bufferId: The nvim buffer ID containing the capture note
    ///   - ocrText: Text extracted from the image via VisionOCR
    ///   - context: Optional capture context for categorization hints
    /// - Returns: EnrichmentID for tracking (can be used to cancel)
    func startEnrichment(
        bufferId: Int64,
        ocrText: String,
        context: GatheredContext? = nil
    ) -> EnrichmentID {
        // Cancel any existing enrichment for this buffer
        if let existing = pendingEnrichments[bufferId] {
            Log.debug("AsyncEnrichment: Cancelling existing enrichment for buffer \(bufferId)")
            existing.task.cancel()
            pendingEnrichments.removeValue(forKey: bufferId)
        }

        let enrichmentId = EnrichmentID()

        Log.info("AsyncEnrichment: Starting enrichment \(enrichmentId.id) for buffer \(bufferId)")

        // Create the background task
        // Note: Using unowned self since we cancel tasks before dealloc
        let task = Task {
            await self.runEnrichment(
                id: enrichmentId,
                bufferId: bufferId,
                ocrText: ocrText,
                context: context
            )
        }

        let pending = PendingEnrichment(
            id: enrichmentId,
            bufferId: bufferId,
            ocrText: ocrText,
            context: context,
            task: task,
            startTime: Date()
        )

        pendingEnrichments[bufferId] = pending
        notifyCountChanged()

        // Ensure we're listening for buffer close events
        Task { await ensureListening() }

        return enrichmentId
    }

    /// Cancel an enrichment task
    ///
    /// - Parameter bufferId: The buffer ID to cancel enrichment for
    func cancelEnrichment(forBuffer bufferId: Int64) {
        guard let pending = pendingEnrichments.removeValue(forKey: bufferId) else {
            return
        }

        Log.debug("AsyncEnrichment: Cancelled enrichment for buffer \(bufferId)")
        pending.task.cancel()
        notifyCountChanged()
    }

    /// Cancel all pending enrichments
    func cancelAll() {
        Log.debug("AsyncEnrichment: Cancelling all \(pendingEnrichments.count) enrichments")
        for (_, pending) in pendingEnrichments {
            pending.task.cancel()
        }
        pendingEnrichments.removeAll()
        notifyCountChanged()
    }

    /// Check if there's an active enrichment for a buffer
    func hasActiveEnrichment(forBuffer bufferId: Int64) -> Bool {
        pendingEnrichments[bufferId] != nil
    }

    /// Get count of pending enrichments
    var pendingCount: Int {
        pendingEnrichments.count
    }

    // MARK: - Private Implementation

    /// Run the actual enrichment (called in background task)
    private func runEnrichment(
        id: EnrichmentID,
        bufferId: Int64,
        ocrText: String,
        context: GatheredContext?
    ) async {
        let mlx = MLXInferenceEngine.shared

        var result = EnrichmentResult(summary: nil, tags: nil, error: nil)

        // Check for cancellation
        guard !Task.isCancelled else {
            Log.debug("AsyncEnrichment: Task cancelled before starting")
            return
        }

        // Run summarization
        do {
            let summary = try await mlx.summarize(ocrText, style: .concise)
            result = EnrichmentResult(summary: summary, tags: result.tags, error: nil)
            Log.debug("AsyncEnrichment: Summary generated (\(summary.count) chars)")
        } catch MLXInferenceError.llmDisabled {
            Log.debug("AsyncEnrichment: LLM disabled, skipping summarization")
        } catch {
            Log.warn("AsyncEnrichment: Summarization failed: \(error.localizedDescription)")
            result = EnrichmentResult(summary: nil, tags: result.tags, error: error.localizedDescription)
        }

        // Check for cancellation
        guard !Task.isCancelled else {
            Log.debug("AsyncEnrichment: Task cancelled after summarization")
            return
        }

        // Run categorization
        do {
            let tags = try await mlx.categorize(ocrText, context: context)
            result = EnrichmentResult(summary: result.summary, tags: tags, error: result.error)
            Log.debug("AsyncEnrichment: Tags generated: \(tags.joined(separator: ", "))")
        } catch MLXInferenceError.llmDisabled {
            // Already logged above
        } catch {
            Log.warn("AsyncEnrichment: Categorization failed: \(error.localizedDescription)")
            // Don't overwrite error if summarization also failed
            if result.error == nil {
                result = EnrichmentResult(summary: result.summary, tags: nil, error: error.localizedDescription)
            }
        }

        // Check for cancellation
        guard !Task.isCancelled else {
            Log.debug("AsyncEnrichment: Task cancelled after categorization")
            return
        }

        // Check if enrichment is still pending (buffer might have closed)
        guard pendingEnrichments[bufferId]?.id == id else {
            Log.debug("AsyncEnrichment: Enrichment no longer pending (buffer may have closed)")
            return
        }

        // Apply results to buffer
        await applyEnrichmentResult(bufferId: bufferId, result: result)

        // Get start time before cleanup
        let startTime = pendingEnrichments[bufferId]?.startTime ?? Date()

        // Clean up
        pendingEnrichments.removeValue(forKey: bufferId)
        notifyCountChanged()

        let elapsed = Date().timeIntervalSince(startTime)
        Log.info("AsyncEnrichment: Completed enrichment for buffer \(bufferId) in \(String(format: "%.1f", elapsed))s")
    }

    /// Apply enrichment results to the buffer by replacing placeholders
    private func applyEnrichmentResult(bufferId: Int64, result: EnrichmentResult) async {
        guard result.succeeded else {
            // Show error notification if enrichment failed
            if let error = result.error {
                await showNvimNotification(
                    message: "Enrichment failed: \(error)",
                    level: .warn
                )
            }
            return
        }

        // Replace placeholders in buffer
        await replacePlaceholders(
            bufferId: bufferId,
            summary: result.summary,
            tags: result.tags
        )

        // Show success notification
        await showNvimNotification(
            message: "Note enriched with AI summary and tags",
            level: .info
        )
    }

    /// Replace placeholder comments in buffer with actual content
    private func replacePlaceholders(
        bufferId: Int64,
        summary: String?,
        tags: [String]?
    ) async {
        let nvim = ShadeNvim.shared

        do {
            // Use Lua for atomic find-and-replace operation
            let luaCode = buildReplacementLua(
                bufferId: bufferId,
                summary: summary,
                tags: tags
            )

            try await nvim.executeLua(luaCode)
            Log.debug("AsyncEnrichment: Replaced placeholders in buffer \(bufferId)")

        } catch {
            Log.error("AsyncEnrichment: Failed to replace placeholders: \(error.localizedDescription)")
        }
    }

    /// Build Lua code for placeholder replacement
    /// Uses a two-pass approach to handle multi-line replacements properly:
    /// 1. Find placeholder lines and mark them for replacement
    /// 2. Build new lines array with proper multi-line handling
    private func buildReplacementLua(
        bufferId: Int64,
        summary: String?,
        tags: [String]?
    ) -> String {
        // Escape strings for Lua (keeping newlines as \n for splitting later)
        let escapedSummary = summary?.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") ?? ""

        let formattedTags = tags?.map { "#\($0)" }.joined(separator: " ") ?? ""

        return """
            local bufnr = \(bufferId)
            if not vim.api.nvim_buf_is_valid(bufnr) then
                return false
            end

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local new_lines = {}
            local modified = false

            -- Helper to split string by newlines
            local function split_lines(str)
                local result = {}
                for line in (str .. '\\n'):gmatch('([^\\n]*)\\n') do
                    table.insert(result, line)
                end
                return result
            end

            for i, line in ipairs(lines) do
                local handled = false

                -- Replace summary placeholder
                if line:find('<!-- shade:pending:summary -->', 1, true) then
                    local summary = "\(escapedSummary)"
                    if summary ~= "" then
                        -- Format as Obsidian callout with each line prefixed with >
                        local summary_lines = split_lines(summary)
                        table.insert(new_lines, '> [!summary]')
                        for _, sline in ipairs(summary_lines) do
                            if sline ~= "" then
                                table.insert(new_lines, '> ' .. sline)
                            end
                        end
                        modified = true
                        handled = true
                    else
                        -- Skip the placeholder line if no summary
                        modified = true
                        handled = true
                    end
                end

                -- Replace tags placeholder
                if not handled and line:find('<!-- shade:pending:tags -->', 1, true) then
                    local tags = "\(formattedTags)"
                    if tags ~= "" then
                        table.insert(new_lines, '**Tags:** ' .. tags)
                        modified = true
                        handled = true
                    else
                        -- Skip the placeholder line if no tags
                        modified = true
                        handled = true
                    end
                end

                -- Keep original line if not a placeholder
                if not handled then
                    table.insert(new_lines, line)
                end
            end

            if modified then
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
            end

            return modified
            """
    }

    /// Show a notification in nvim
    private func showNvimNotification(message: String, level: NotificationLevel) async {
        let nvim = ShadeNvim.shared

        do {
            let levelNum: Int
            switch level {
            case .info: levelNum = 2  // vim.log.levels.INFO
            case .warn: levelNum = 3  // vim.log.levels.WARN
            case .error: levelNum = 4 // vim.log.levels.ERROR
            }

            let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")

            try await nvim.executeLua("""
                vim.notify("\(escapedMessage)", \(levelNum), { title = "Shade" })
                """)
        } catch {
            Log.warn("AsyncEnrichment: Failed to show notification: \(error.localizedDescription)")
        }
    }

    private enum NotificationLevel {
        case info, warn, error
    }

    // MARK: - Buffer Event Handling

    /// Start listening for buffer close events
    private func ensureListening() async {
        guard !isListening else { return }
        isListening = true

        // Subscribe to buffer detach events
        detachSubscription = await ShadeNvim.shared.onBufferDetach { [weak self] event in
            guard let self = self else { return }
            Task {
                await self.handleBufferDetach(bufferId: event.buffer)
            }
        }

        Log.debug("AsyncEnrichment: Started listening for buffer events")
    }

    /// Handle buffer detach (close) event
    private func handleBufferDetach(bufferId: Int64) {
        // Cancel any pending enrichment for this buffer
        if pendingEnrichments[bufferId] != nil {
            Log.debug("AsyncEnrichment: Buffer \(bufferId) closed, cancelling enrichment")
            cancelEnrichment(forBuffer: bufferId)
        }
    }
}

