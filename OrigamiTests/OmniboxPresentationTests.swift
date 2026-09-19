import Foundation
import AppKit
import Testing
@testable import Origami

struct OmniboxPresentationTests {
    @Test func hidesOnlyLeadingSchemeOutsideEditing() {
        #expect(OmniboxPresentation.displayValue("https://example.com/path?q=http://other.test") == "example.com/path?q=http://other.test")
        #expect(OmniboxPresentation.displayValue("http://localhost:8080/path") == "http://localhost:8080/path")
        #expect(OmniboxPresentation.displayValue("HTTPS://example.com") == "example.com")
        #expect(OmniboxPresentation.displayValue("") == "")
    }
    @Test func insecurePrefixIsVisibleAndRedOnlyForHTTP() {
        let value = OmniboxPresentation.attributedDisplay("http://example.invalid/path", font: .systemFont(ofSize: 13))
        #expect(value.string == "http://example.invalid/path")
        #expect(value.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
        #expect(value.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor == .labelColor)
        #expect(!OmniboxPresentation.isInsecure("https://example.invalid"))
        #expect(!OmniboxPresentation.isInsecure("search http://example.invalid"))
    }
    @Test func focusedAddressFollowsFallbackWithoutOverwritingUserEdits() {
        let previous = "https://http.badssl.com/", current = "http://http.badssl.com/"
        #expect(OmniboxPresentation.shouldRefreshEditing(previous: previous, current: current, text: previous))
        #expect(!OmniboxPresentation.shouldRefreshEditing(previous: previous, current: current, text: "https://other.example/"))
        #expect(!OmniboxPresentation.shouldRefreshEditing(previous: previous, current: previous, text: previous))
    }
    @Test func unverifiedHTTPSKeepsRedSchemeWithoutInventingHTTP() {
        let attempted = "https://http.badssl.com/"
        let warning = OmniboxPresentation.attributedDisplay(attempted, font: .systemFont(ofSize: 13), connectionWarning: true)
        #expect(warning.string == attempted)
        #expect(warning.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
        #expect(OmniboxPresentation.displayValue(attempted) == "http.badssl.com/")
        let fallback = OmniboxPresentation.attributedDisplay("http://http.badssl.com/", font: .systemFont(ofSize: 13))
        #expect(fallback.string == "http://http.badssl.com/")
        #expect(fallback.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
    }
    @Test func editingPreservesTheFullNavigableAddress() {
        let address = "https://example.com/你好?q=swift#section"
        #expect(OmniboxPresentation.editingValue(address) == address)
        #expect(OmniboxPresentation.schemeLength(address) == 8)
        #expect(OmniboxPresentation.schemeLength("http://example.com") == 7)
        #expect(OmniboxPresentation.schemeLength("swift actor isolation") == 0)
    }
    @Test func allBuiltInPagesHaveEmptyOmniboxValues() {
        for page in InternalPage.allCases {
            let address = "origami://\(page.rawValue)"
            #expect(OmniboxPresentation.displayValue(address).isEmpty)
            #expect(OmniboxPresentation.editingValue(address).isEmpty)
        }
        #expect(OmniboxPresentation.displayValue("https://history.example.com") == "history.example.com")
    }
}
