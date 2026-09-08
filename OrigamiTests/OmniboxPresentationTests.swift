import Foundation
import Testing
@testable import Origami

struct OmniboxPresentationTests {
    @Test func hidesOnlyLeadingSchemeOutsideEditing() {
        #expect(OmniboxPresentation.displayValue("https://example.com/path?q=http://other.test") == "example.com/path?q=http://other.test")
        #expect(OmniboxPresentation.displayValue("http://localhost:8080/path") == "localhost:8080/path")
        #expect(OmniboxPresentation.displayValue("HTTPS://example.com") == "example.com")
        #expect(OmniboxPresentation.displayValue("") == "")
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
