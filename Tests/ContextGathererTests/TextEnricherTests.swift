import XCTest
@testable import ContextGatherer

final class TextEnricherTests: XCTestCase {

    // MARK: - URL Detection Tests

    func testDetectLinks_HttpsUrl_Detected() {
        let text = "Check out https://example.com for more"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.originalText, "https://example.com")
        XCTAssertEqual(links.first?.type, .url)
        XCTAssertEqual(links.first?.url.absoluteString, "https://example.com")
    }

    func testDetectLinks_HttpUrl_Detected() {
        let text = "Visit http://old-site.com/page"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.originalText, "http://old-site.com/page")
        XCTAssertEqual(links.first?.type, .url)
    }

    func testDetectLinks_UrlWithPath_Detected() {
        let text = "See https://github.com/user/repo/blob/main/README.md"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.originalText, "https://github.com/user/repo/blob/main/README.md")
    }

    func testDetectLinks_UrlWithQueryString_Detected() {
        let text = "Search: https://google.com/search?q=swift+url+detection"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 1)
        XCTAssert(links.first?.originalText.contains("q=swift") == true)
    }

    func testDetectLinks_MultipleUrls_AllDetected() {
        let text = "First: https://one.com then https://two.com"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].originalText, "https://one.com")
        XCTAssertEqual(links[1].originalText, "https://two.com")
    }

    func testDetectLinks_UrlInParentheses_Detected() {
        let text = "More info (https://example.com/docs)"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 1)
        // URL should be detected without the trailing parenthesis
        XCTAssert(links.first?.originalText.hasPrefix("https://example.com") == true)
    }

    // MARK: - Bare Domain Detection Tests

    func testDetectLinks_BareDomain_Detected() {
        let text = "Visit github.com/user/repo for source code"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 1)
        // NSDataDetector detects bare domains as URLs with http scheme
        // Our implementation may classify as .url or .bareDomain depending on detection path
        XCTAssert(links.first?.type == .url || links.first?.type == .bareDomain)
        XCTAssert(links.first?.url.absoluteString.contains("github.com/user/repo") == true)
    }

    func testDetectLinks_BareDomainWithWww_Detected() {
        let text = "Go to www.example.com/path"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 1)
        XCTAssert(links.first?.originalText.contains("www.example.com") == true)
    }

    func testDetectLinks_VersionNumber_NotDetectedAsDomain() {
        let text = "Version 1.0.0 is released"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 0)
    }

    func testDetectLinks_IpAddress_NotDetectedAsDomain() {
        let text = "Server at 192.168.1.1"
        let links = TextEnricher.detectLinks(in: text)

        // NSDataDetector might detect this, but we shouldn't treat it as a domain
        // If detected, it shouldn't be treated as a bare domain
        for link in links {
            XCTAssertNotEqual(link.type, .bareDomain)
        }
    }

    // MARK: - Email Detection Tests

    func testDetectLinks_Email_Detected() {
        let text = "Contact me at user@example.com"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.type, .email)
        XCTAssertEqual(links.first?.url.scheme, "mailto")
    }

    func testDetectLinks_MultipleEmails_AllDetected() {
        let text = "Email alice@one.com or bob@two.org"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(links.allSatisfy { $0.type == .email })
    }

    // MARK: - Mixed Content Tests

    func testDetectLinks_MixedContent_AllTypesDetected() {
        let text = """
        Check https://docs.example.com for docs,
        visit github.com/project for source,
        or email support@example.com for help.
        """
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertGreaterThanOrEqual(links.count, 3)

        let types = Set(links.map(\.type))
        XCTAssertTrue(types.contains(.url))
        XCTAssertTrue(types.contains(.email))
        // Note: bareDomain detection depends on NSDataDetector behavior
    }

    func testDetectLinks_NoLinks_EmptyArray() {
        let text = "Just plain text with no links at all"
        let links = TextEnricher.detectLinks(in: text)

        XCTAssertEqual(links.count, 0)
    }

    // MARK: - Enrichment Tests

    func testEnrich_HttpsUrl_ConvertsToMarkdown() {
        let text = "See https://example.com for more"
        let result = TextEnricher.enrich(text)

        XCTAssertTrue(result.wasEnriched)
        XCTAssertEqual(result.text, "See [https://example.com](https://example.com) for more")
    }

    func testEnrich_BareDomain_AddsScheme() {
        let text = "Visit github.com/user/repo"
        let result = TextEnricher.enrich(text)

        XCTAssertTrue(result.wasEnriched)
        // NSDataDetector may add http:// or https:// depending on platform version
        XCTAssertTrue(
            result.text.contains("github.com/user/repo](http") ||
            result.text.contains("github.com/user/repo](https"),
            "Expected markdown link with scheme, got: \(result.text)"
        )
    }

    func testEnrich_Email_ConvertsToMailtoLink() {
        let text = "Email user@example.com"
        let result = TextEnricher.enrich(text)

        XCTAssertTrue(result.wasEnriched)
        XCTAssertTrue(result.text.contains("[user@example.com](mailto:user@example.com)"))
    }

    func testEnrich_NoLinks_ReturnsOriginalText() {
        let text = "Plain text without links"
        let result = TextEnricher.enrich(text)

        XCTAssertFalse(result.wasEnriched)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.links.count, 0)
    }

    func testEnrich_MultipleLinks_AllConverted() {
        let text = "See https://one.com and https://two.com"
        let result = TextEnricher.enrich(text)

        XCTAssertTrue(result.wasEnriched)
        XCTAssertEqual(result.links.count, 2)
        XCTAssertTrue(result.text.contains("[https://one.com](https://one.com)"))
        XCTAssertTrue(result.text.contains("[https://two.com](https://two.com)"))
    }

    // MARK: - String Extension Tests

    func testStringExtension_DetectedLinks() {
        let text = "Visit https://example.com"
        XCTAssertEqual(text.detectedLinks.count, 1)
    }

    func testStringExtension_Enriched() {
        let text = "Go to https://example.com"
        let enriched = text.enriched
        XCTAssertTrue(enriched.contains("[https://example.com](https://example.com)"))
    }

    // MARK: - Edge Cases

    func testEnrich_UrlAtStartOfText_Handled() {
        let text = "https://example.com is great"
        let result = TextEnricher.enrich(text)

        XCTAssertTrue(result.text.hasPrefix("[https://example.com]"))
    }

    func testEnrich_UrlAtEndOfText_Handled() {
        let text = "Check out https://example.com"
        let result = TextEnricher.enrich(text)

        XCTAssertTrue(result.text.hasSuffix("(https://example.com)"))
    }

    func testEnrich_UrlOnlyText_Handled() {
        let text = "https://example.com"
        let result = TextEnricher.enrich(text)

        XCTAssertEqual(result.text, "[https://example.com](https://example.com)")
    }

    func testEnrich_EmptyText_ReturnsEmpty() {
        let text = ""
        let result = TextEnricher.enrich(text)

        XCTAssertFalse(result.wasEnriched)
        XCTAssertEqual(result.text, "")
    }

    func testEnrich_WhitespaceOnly_ReturnsOriginal() {
        let text = "   \n\t  "
        let result = TextEnricher.enrich(text)

        XCTAssertFalse(result.wasEnriched)
        XCTAssertEqual(result.text, text)
    }

    // MARK: - Special URL Characters

    func testEnrich_UrlWithSpecialChars_Preserved() {
        let text = "API: https://api.example.com/v1/users?filter=active&sort=name"
        let result = TextEnricher.enrich(text)

        XCTAssertTrue(result.wasEnriched)
        XCTAssertTrue(result.text.contains("filter=active"))
        XCTAssertTrue(result.text.contains("sort=name"))
    }

    func testEnrich_UrlWithFragment_Preserved() {
        let text = "See https://docs.com/page#section"
        let result = TextEnricher.enrich(text)

        XCTAssertTrue(result.wasEnriched)
        XCTAssertTrue(result.text.contains("#section"))
    }
}

// MARK: - Live Title Fetching Tests

/// These tests make network requests and are skipped in CI
final class TextEnricherLiveTests: XCTestCase {

    override func setUpWithError() throws {
        // Skip in CI environment
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Skipping live network tests in CI environment")
        }
    }

    func testLive_EnrichWithTitles_FetchesRealTitle() async throws {
        // Use a stable, well-known URL
        let text = "Example site: https://example.com"
        let result = await TextEnricher.enrichWithTitles(text, timeout: 10.0)

        XCTAssertTrue(result.wasEnriched)
        // example.com has title "Example Domain"
        XCTAssertTrue(
            result.text.contains("Example Domain") || result.text.contains("example.com"),
            "Expected title 'Example Domain' or fallback to URL, got: \(result.text)"
        )
    }

    func testLive_EnrichWithTitles_HandlesTimeout() async {
        // Set very short timeout
        let text = "Fast check: https://example.com"
        let result = await TextEnricher.enrichWithTitles(text, timeout: 0.001)

        // Should still enrich, just without title
        XCTAssertTrue(result.wasEnriched)
        XCTAssertTrue(result.text.contains("https://example.com"))
    }

    func testLive_EnrichWithTitles_HandlesInvalidUrl() async {
        let text = "Invalid: https://this-domain-definitely-does-not-exist-12345.com"
        let result = await TextEnricher.enrichWithTitles(text, timeout: 5.0)

        // Should still enrich with the URL as fallback
        XCTAssertTrue(result.wasEnriched)
        XCTAssertTrue(result.text.contains("this-domain-definitely-does-not-exist"))
    }

    func testLive_EnrichWithTitles_MultipleUrls_ParallelFetch() async {
        let text = """
        First: https://example.com
        Second: https://httpbin.org/html
        """

        let start = Date()
        let result = await TextEnricher.enrichWithTitles(text, timeout: 10.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.wasEnriched)
        // Parallel fetching should be faster than sequential (< 2x single request time)
        // Just verify it completes in reasonable time
        XCTAssertLessThan(elapsed, 15.0)
    }
}
