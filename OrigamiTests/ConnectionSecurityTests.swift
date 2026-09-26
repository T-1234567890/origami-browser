import Testing
import WebKit
@testable import Origami

@MainActor struct ConnectionSecurityTests {
    @Test func defaultPolicyFallsBackAutomaticallyAndSettingPersists() throws {
        let name = "Origami.SecurityFixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = BrowserPreferences(defaults: defaults)
        #expect(preferences.httpsFirst)
        #expect(HTTPSFirst.policy(enabled: true) == .automaticFallbackToHTTP)
        preferences.httpsFirst = false
        #expect(!BrowserPreferences(defaults: defaults).httpsFirst)
        #expect(HTTPSFirst.policy(enabled: false) == .keepAsRequested)
    }
    @Test func existingPagesReadChangedPreferenceForEveryNavigation() throws {
        let preferences = BrowserPreferences()
        let services = try BrowserServices(database: DatabaseManager(), preferences: preferences)
        let page = TabPage(services: services); defer { page.dispose() }
        #expect(page.webView.configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy == .automaticFallbackToHTTP)
        let navigation = WKWebpagePreferences()
        for enabled in [true, false, true] {
            preferences.httpsFirst = enabled
            page.applyConnectionPolicy(to: navigation)
            #expect(navigation.preferredHTTPSNavigationPolicy == HTTPSFirst.policy(enabled: enabled))
        }
    }
    @Test(arguments: ["example.com/path?q=test#section", "localhost:8080", "127.0.0.1:3000", "[::1]:8080"])
    func bareAddressesAllowNativeUpgradeAndFallback(_ address: String) {
        #expect(OmniboxRouter.destination(for: address, engine: .google, httpsFirst: true)?.absoluteString == "http://" + address)
        #expect(OmniboxRouter.destination(for: address, engine: .google, httpsFirst: false)?.absoluteString == "https://" + address)
    }
    @Test func explicitSchemesAndSearchesArePreserved() {
        for address in ["https://example.com/path", "http://example.com/path"] {
            #expect(OmniboxRouter.destination(for: address, engine: .google, httpsFirst: true)?.absoluteString == address)
        }
        #expect(OmniboxRouter.destination(for: "browser search", engine: .google, httpsFirst: true) == SearchEngine.google.searchURL(for: "browser search"))
    }
    @Test func privatePagesUseTheSameProtection() throws {
        let preferences = BrowserPreferences(), database = try DatabaseManager()
        let profile = try ProfileRepository(database).ensureDefault()
        let services = try BrowserServices(database: DatabaseManager(), preferences: preferences, privateProfile: profile)
        let page = TabPage(services: services, profileID: profile.id); defer { page.dispose() }
        #expect(!page.webView.configuration.websiteDataStore.isPersistent)
        let navigation = WKWebpagePreferences(); page.applyConnectionPolicy(to: navigation)
        #expect(navigation.preferredHTTPSNavigationPolicy == .automaticFallbackToHTTP)
    }
    @Test(.timeLimit(.minutes(1)), arguments: ["http", "https"])
    func actualWebViewDoesNotInferCertificateTrustFromURL(scheme: String) async throws {
        let preferences = BrowserPreferences(); preferences.httpsFirst = false
        let services = try BrowserServices(database: DatabaseManager(), preferences: preferences)
        let page = TabPage(services: services); defer { page.dispose() }
        page.webView.loadHTMLString("<title>Connection fixture</title><p>Local synthetic document</p>",
                                   baseURL: URL(string: "\(scheme)://example.invalid/"))
        for _ in 0..<150 {
            if page.webView.title == "Connection fixture", !page.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(page.webView.title == "Connection fixture")
        #expect(page.connectionSecurity == (scheme == "http" ? .insecure : .unverified))
        // An HTTPS base URL on synthetic HTML is not a TLS connection.
        #expect(!page.canViewCertificate)
    }
    @Test func unverifiedAndFailedPagesNeverAdvertiseValidatedCertificates() {
        let page = TabPage(); defer { page.dispose() }
        #expect(page.connectionSecurity == .local)
        #expect(!page.canViewCertificate)
        page.webView(page.webView, didFailProvisionalNavigation: nil,
                     withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted))
        #expect(page.connectionSecurity != .secure)
        #expect(!page.canViewCertificate)
        #expect(ConnectionSecurity.unverified.warning)
        #expect(ConnectionSecurity.insecure.warning)
        #expect(ConnectionSecurity.mixed.warning)
        #expect(!ConnectionSecurity.secure.warning)
        #expect(ConnectionSecurity.secure.rawValue == "Encrypted connection")
    }
}
