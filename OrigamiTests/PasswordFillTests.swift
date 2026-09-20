import AuthenticationServices
import Testing
import WebKit
@testable import Origami

@MainActor struct PasswordFillTests {
    @Test func passwordAutoFillRequiresExplicitOptIn() {
        #expect(!BrowserFeatureFlags.passwordAutoFillEnabled(environment: [:]))
        #expect(!BrowserFeatureFlags.passwordAutoFillEnabled(environment: ["ORIGAMI_ENABLE_PASSWORD_AUTOFILL": "0"]))
        #expect(BrowserFeatureFlags.passwordAutoFillEnabled(environment: ["ORIGAMI_ENABLE_PASSWORD_AUTOFILL": "1"]))
    }

    @Test func publicRequestIsPasswordOnly() {
        let request = ASAuthorizationPasswordProvider().createRequest()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        #expect(controller.authorizationRequests.count == 1)
        #expect(controller.authorizationRequests.first is ASAuthorizationPasswordRequest)
        // Do not perform an account-dependent authorization in CI.
    }

    @Test(.timeLimit(.minutes(1))) func fillIsOneShotAndDoesNotSubmit() async throws {
        let (web, reports) = try await fixture()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers() }
        let token = try #require(reports.token)
        let filled = try await fill(web, token)
        #expect(filled)
        let correct = try await web.evaluateJavaScript("document.querySelector('[name=login]').value === 'fixture-user' && document.querySelector('[type=password]').value === 'fixture-password' && window.inputEvents === 2 && window.submissions === 0") as? Bool
        #expect(correct == true)
        #expect(try await fill(web, token) == false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        "document.querySelector('form').action='https://other.invalid/login'",
        "history.replaceState({},'', '/different')",
        "document.querySelector('[type=password]').remove()",
        "document.querySelector('[type=password]').autocomplete='new-password'",
        "document.querySelector('form').method='get'",
        "document.querySelector('[type=password]').disabled=true",
        "document.querySelector('form').innerHTML='<input name=login><input type=password>'"
    ])
    func changedTargetsRejectCredentials(_ mutation: String) async throws {
        let (web, reports) = try await fixture()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers() }
        let token = try #require(reports.token)
        _ = try await web.evaluateJavaScript(mutation)
        #expect(try await fill(web, token) == false)
    }

    @Test(.timeLimit(.minutes(1))) func positionUpdatesKeepTheSameTarget() async throws {
        let (web, reports) = try await fixture()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers() }
        let token = try #require(reports.token)
        let initialY = try #require(reports.y)
        _ = try await web.evaluateJavaScript("document.querySelector('form').style.marginTop='120px'")
        for _ in 0..<100 {
            if (reports.y ?? 0) > initialY { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((reports.y ?? 0) > initialY)
        #expect(reports.token == token)
        #expect(try await fill(web, token))
    }

    private func fill(_ web: WKWebView, _ token: String) async throws -> Bool {
        try await web.callAsyncJavaScript("return window.__origamiPasswordFill.fill(token, username, password);",
            arguments: ["token": token, "username": "fixture-user", "password": "fixture-password"],
            in: nil, contentWorld: PasswordFillScript.world) as? Bool == true
    }

    private func fixture() async throws -> (WKWebView, Reports) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let reports = Reports()
        configuration.userContentController.add(reports, contentWorld: PasswordFillScript.world, name: "origamiPasswordFocus")
        configuration.userContentController.addUserScript(WKUserScript(source: PasswordFillScript.source,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: PasswordFillScript.world))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        web.loadHTMLString("""
            <title>Password fixture</title><form method="post"><input name="login" autocomplete="username">
            <input type="password" autocomplete="current-password"><button>Sign in</button></form>
            <script>window.inputEvents=0;window.submissions=0;
            document.addEventListener('input',()=>window.inputEvents++);
            document.addEventListener('submit',e=>{e.preventDefault();window.submissions++});</script>
            """, baseURL: URL(string: "https://example.invalid/login")!)
        for _ in 0..<100 {
            if web.title == "Password fixture" && !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.evaluateJavaScript("document.querySelector('[name=login]').focus()")
        for _ in 0..<100 {
            if reports.token != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (web, reports)
    }

    @MainActor private final class Reports: NSObject, WKScriptMessageHandler {
        var token: String?
        var y: Double?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Intentionally ignore all other data, and never collect field values.
            token = (message.body as? [String: Any])?["token"] as? String
            y = (message.body as? [String: Any])?["y"] as? Double
        }
    }
}
