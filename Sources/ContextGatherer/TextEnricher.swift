import Foundation
import os.log

// MARK: - Logging

private let logger = Logger(subsystem: "io.shade", category: "TextEnricher")

// MARK: - Detected Link Types

/// Represents a detected link in text
public struct DetectedLink: Sendable, Equatable {
    /// The original text that was detected
    public let originalText: String

    /// The range in the original string
    public let range: Range<String.Index>

    /// The resolved URL (with scheme added if needed)
    public let url: URL

    /// The type of link detected
    public let type: LinkType

    /// Link type classification
    public enum LinkType: Sendable, Equatable {
        case url           // Standard URL with scheme
        case bareDomain    // Domain without scheme (e.g., github.com/user/repo)
        case email         // Email address
    }
}

// MARK: - Enrichment Result

/// Result of text enrichment
public struct EnrichmentResult: Sendable {
    /// The enriched text with markdown links
    public let text: String

    /// Links that were detected and converted
    public let links: [DetectedLink]

    /// Whether any enrichment was performed
    public var wasEnriched: Bool {
        !links.isEmpty
    }
}

// MARK: - Title Fetch Result

/// Result of fetching a page title
public struct TitleFetchResult: Sendable {
    public let url: URL
    public let title: String?
    public let error: Error?

    public init(url: URL, title: String?, error: Error? = nil) {
        self.url = url
        self.title = title
        self.error = error
    }
}

// MARK: - Text Enricher

/// Detects URLs and emails in text and converts them to markdown links
///
/// ## Features
/// - Detects URLs with schemes (http://, https://, file://)
/// - Detects bare domains (github.com/user/repo, www.example.com)
/// - Detects email addresses and converts to mailto: links
/// - Optionally fetches page titles asynchronously
///
/// ## Usage
/// ```swift
/// // Simple enrichment (no title fetching)
/// let result = TextEnricher.enrich("Check out github.com/user/repo")
/// // Result: "Check out [github.com/user/repo](https://github.com/user/repo)"
///
/// // With async title fetching
/// let result = await TextEnricher.enrichWithTitles("See https://example.com")
/// // Result: "See [Example Domain](https://example.com)"
/// ```
public enum TextEnricher {

    // MARK: - Configuration

    /// Timeout for title fetching (can be overridden)
    public static var titleFetchTimeout: TimeInterval = 5.0

    // MARK: - Public API

    /// Detect all links in text without modifying it
    /// - Parameter text: The text to scan
    /// - Returns: Array of detected links with their positions
    public static func detectLinks(in text: String) -> [DetectedLink] {
        var links: [DetectedLink] = []

        // 1. Use NSDataDetector for URLs (handles most cases well)
        links.append(contentsOf: detectWithDataDetector(in: text))

        // 2. Use regex for bare domains that NSDataDetector misses
        links.append(contentsOf: detectBareDomains(in: text, excluding: links))

        // Sort by position in text
        return links.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Enrich text by converting detected links to markdown format
    /// - Parameter text: The text to enrich
    /// - Returns: EnrichmentResult with converted text and detected links
    public static func enrich(_ text: String) -> EnrichmentResult {
        let links = detectLinks(in: text)

        if links.isEmpty {
            return EnrichmentResult(text: text, links: [])
        }

        // Build enriched text by replacing links from end to start
        // (to preserve earlier indices)
        var enrichedText = text
        for link in links.reversed() {
            let markdown = formatAsMarkdown(link)
            enrichedText.replaceSubrange(link.range, with: markdown)
        }

        return EnrichmentResult(text: enrichedText, links: links)
    }

    /// Enrich text with async title fetching for URLs
    /// - Parameters:
    ///   - text: The text to enrich
    ///   - timeout: Timeout per URL for title fetching
    /// - Returns: EnrichmentResult with titles fetched where possible
    public static func enrichWithTitles(
        _ text: String,
        timeout: TimeInterval? = nil
    ) async -> EnrichmentResult {
        let links = detectLinks(in: text)

        if links.isEmpty {
            return EnrichmentResult(text: text, links: [])
        }

        // Fetch titles for HTTP(S) URLs in parallel
        let httpLinks = links.filter {
            $0.type != .email && ($0.url.scheme == "http" || $0.url.scheme == "https")
        }

        let titles = await fetchTitles(for: httpLinks, timeout: timeout ?? titleFetchTimeout)

        // Build enriched text
        var enrichedText = text
        for link in links.reversed() {
            let title = titles[link.url]
            let markdown = formatAsMarkdown(link, title: title)
            enrichedText.replaceSubrange(link.range, with: markdown)
        }

        return EnrichmentResult(text: enrichedText, links: links)
    }

    // MARK: - Detection Implementation

    /// Detect links using NSDataDetector
    private static func detectWithDataDetector(in text: String) -> [DetectedLink] {
        var results: [DetectedLink] = []

        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            logger.error("Failed to create NSDataDetector")
            return []
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: nsRange)

        for match in matches {
            guard let range = Range(match.range, in: text),
                  let url = match.url else {
                continue
            }

            let originalText = String(text[range])
            let type: DetectedLink.LinkType

            // Classify the link type
            if url.scheme == "mailto" {
                type = .email
            } else if url.scheme == "http" || url.scheme == "https" || url.scheme == "file" {
                type = .url
            } else {
                // Skip unknown schemes
                continue
            }

            results.append(DetectedLink(
                originalText: originalText,
                range: range,
                url: url,
                type: type
            ))
        }

        return results
    }

    /// Detect bare domains that NSDataDetector might miss
    /// Examples: github.com/user/repo, example.com/path
    private static func detectBareDomains(
        in text: String,
        excluding existingLinks: [DetectedLink]
    ) -> [DetectedLink] {
        var results: [DetectedLink] = []

        // Regex for bare domains:
        // - Optional www.
        // - Domain with TLD (2-63 chars each part, TLD 2-10 chars)
        // - Optional path, query, fragment
        // Negative lookbehind for :// to avoid matching URLs that already have schemes
        let pattern = #"""
        (?<![:/])           # Not preceded by :/ (avoid matching after scheme)
        \b                  # Word boundary
        (?:www\.)?          # Optional www.
        (?:
            [a-zA-Z0-9]     # Start with alphanumeric
            [a-zA-Z0-9-]*   # Middle can have hyphens
            [a-zA-Z0-9]     # End with alphanumeric
            \.              # Dot
        )+                  # One or more domain parts
        [a-zA-Z]{2,10}      # TLD (2-10 chars)
        (?:                 # Optional path/query/fragment
            (?:/[^\s<>"\[\]()]*)?  # Path (excluding special chars)
        )
        \b
        """#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.allowCommentsAndWhitespace]
        ) else {
            logger.error("Failed to compile bare domain regex")
            return []
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        for match in matches {
            guard let range = Range(match.range, in: text) else {
                continue
            }

            // Skip if this range overlaps with an existing detected link
            let overlaps = existingLinks.contains { existing in
                existing.range.overlaps(range)
            }
            if overlaps {
                continue
            }

            let originalText = String(text[range])

            // Validate it looks like a real domain (has valid TLD)
            guard looksLikeValidDomain(originalText) else {
                continue
            }

            // Construct URL with https scheme
            guard let url = URL(string: "https://\(originalText)") else {
                continue
            }

            results.append(DetectedLink(
                originalText: originalText,
                range: range,
                url: url,
                type: .bareDomain
            ))
        }

        return results
    }

    /// Check if a string looks like a valid domain
    /// Filters out things like version numbers (1.0.0) and IP-like strings
    private static func looksLikeValidDomain(_ text: String) -> Bool {
        // Must contain at least one dot
        guard text.contains(".") else { return false }

        // Extract the TLD (last component after final dot)
        let components = text.split(separator: "/").first.map(String.init) ?? text
        let domainParts = components.split(separator: ".")

        guard let tld = domainParts.last else { return false }

        // TLD must be alphabetic (not numeric like in "1.0.0")
        guard tld.allSatisfy({ $0.isLetter }) else { return false }

        // Common TLDs for quick validation
        let commonTLDs = Set([
            "com", "org", "net", "edu", "gov", "io", "co", "dev", "app",
            "me", "info", "biz", "us", "uk", "ca", "de", "fr", "au", "jp",
            "ru", "ch", "nl", "se", "no", "fi", "be", "at", "es", "it",
            "ai", "xyz", "tech", "online", "site", "cloud", "sh", "to",
        ])

        let tldLower = tld.lowercased()

        // Accept if it's a common TLD or at least 2 chars
        return commonTLDs.contains(tldLower) || tld.count >= 2
    }

    // MARK: - Formatting

    /// Format a detected link as markdown
    private static func formatAsMarkdown(_ link: DetectedLink, title: String? = nil) -> String {
        switch link.type {
        case .email:
            // Format: [email@example.com](mailto:email@example.com)
            let email = link.originalText
            return "[\(email)](mailto:\(email))"

        case .url, .bareDomain:
            // Format: [title or url](url)
            let displayText = title ?? link.originalText
            return "[\(displayText)](\(link.url.absoluteString))"
        }
    }

    // MARK: - Title Fetching

    /// Fetch page titles for multiple URLs in parallel
    private static func fetchTitles(
        for links: [DetectedLink],
        timeout: TimeInterval
    ) async -> [URL: String] {
        guard !links.isEmpty else { return [:] }

        // Deduplicate URLs
        let uniqueURLs = Set(links.map(\.url))

        logger.debug("Fetching titles for \(uniqueURLs.count) URLs")

        // Fetch in parallel with timeout
        return await withTaskGroup(of: TitleFetchResult.self) { group in
            for url in uniqueURLs {
                group.addTask {
                    await fetchTitle(for: url, timeout: timeout)
                }
            }

            var results: [URL: String] = [:]
            for await result in group {
                if let title = result.title {
                    results[result.url] = title
                }
            }
            return results
        }
    }

    /// Fetch page title for a single URL
    private static func fetchTitle(for url: URL, timeout: TimeInterval) async -> TitleFetchResult {
        logger.debug("Fetching title for \(url.absoluteString)")

        do {
            // Create request with timeout
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.httpMethod = "GET"
            // Be a good citizen - some sites block non-browser user agents
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            // Only fetch HTML
            request.setValue("text/html", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            // Check response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                logger.debug("Non-success response for \(url.absoluteString)")
                return TitleFetchResult(url: url, title: nil)
            }

            // Parse HTML for title
            guard let html = String(data: data, encoding: .utf8) else {
                return TitleFetchResult(url: url, title: nil)
            }

            let title = extractTitle(from: html)

            if let title = title {
                logger.debug("Found title for \(url.host ?? ""): \(title)")
            }

            return TitleFetchResult(url: url, title: title)

        } catch {
            logger.debug("Failed to fetch \(url.absoluteString): \(error.localizedDescription)")
            return TitleFetchResult(url: url, title: nil, error: error)
        }
    }

    /// Extract <title> from HTML
    private static func extractTitle(from html: String) -> String? {
        // Simple regex to extract title tag content
        // Handles: <title>Text</title>, <title attr="val">Text</title>
        let pattern = #"<title[^>]*>([^<]+)</title>"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let nsRange = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: nsRange),
              let titleRange = Range(match.range(at: 1), in: html) else {
            return nil
        }

        var title = String(html[titleRange])

        // Clean up the title
        title = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Decode common HTML entities
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Skip if title is empty or too generic
        guard !title.isEmpty,
              title.lowercased() != "untitled",
              title.count < 200 else {
            return nil
        }

        return title
    }
}

// MARK: - String Extension for Link Detection

public extension String {
    /// Detect all links in this string
    var detectedLinks: [DetectedLink] {
        TextEnricher.detectLinks(in: self)
    }

    /// Enrich this string by converting links to markdown
    var enriched: String {
        TextEnricher.enrich(self).text
    }

    /// Enrich this string with async title fetching
    func enrichedWithTitles(timeout: TimeInterval = 5.0) async -> String {
        await TextEnricher.enrichWithTitles(self, timeout: timeout).text
    }
}
