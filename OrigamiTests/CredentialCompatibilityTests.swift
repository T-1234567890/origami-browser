import Testing
import WebKit
@testable import Origami

/// Synthetic pages only: these tests must not depend on Keychain contents or a signed-in Mac.
@MainActor struct CredentialCompatibilityTests {
    @Test(.timeLimit(.minutes(1))) func browserScriptsPreserveCredentialFieldsAndWebAuthentication() async throws {
        let page = TabPage(); defer { page.dispose() }
        let web = page.webView
        web.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let controller = web.configuration.userContentController
        // Materialize a Swift snapshot; WebKit bridges a mutable backing array.
        let scripts = controller.userScripts.map { $0 }
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: """
            window.credentialBaseline = {
                credentials: navigator.credentials,
                get: navigator.credentials?.get,
                create: navigator.credentials?.create,
                publicKey: window.PublicKeyCredential
            };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.forEach(controller.addUserScript)
        web.loadHTMLString("""
            <!doctype html><html><head><title>Credential fixture</title></head><body>
            <form id="login"><input id="username" autocomplete="username webauthn">
            <input id="password" type="password" autocomplete="current-password"><button>Sign in</button></form>
            <form id="signup"><input id="email" type="email" autocomplete="username">
            <input id="newPassword" type="password" autocomplete="new-password"></form>
            <input id="code" autocomplete="one-time-code" inputmode="numeric">
            </body></html>
            """, baseURL: URL(string: "https://example.invalid/login")!)
        for _ in 0..<200 {
            if !web.isLoading, web.title == "Credential fixture" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(web.title == "Credential fixture")
        let result = try await web.callAsyncJavaScript("""
            const baseline=window.credentialBaseline;
            const fields=[['username','username webauthn'],['password','current-password'],
              ['email','username'],['newPassword','new-password'],['code','one-time-code']];
            const attributes=fields.every(([id,value])=>document.getElementById(id).getAttribute('autocomplete')===value);
            const input=document.getElementById('password'); input.focus();
            input.value='synthetic-test-value';
            const event=new Event('input',{bubbles:true,cancelable:true}); input.dispatchEvent(event);
            const key=new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}); input.dispatchEvent(key);
            return {
              attributes,
              focused:document.activeElement===input,
              inputAllowed:!event.defaultPrevented,
              keyAllowed:!key.defaultPrevented,
              passwordType:input.type==='password',
              otp:document.getElementById('code').inputMode==='numeric',
              secure:window.isSecureContext,
              api:typeof navigator.credentials?.get==='function' && typeof PublicKeyCredential==='function',
              unchanged:baseline.credentials===navigator.credentials && baseline.get===navigator.credentials?.get &&
                baseline.create===navigator.credentials?.create && baseline.publicKey===window.PublicKeyCredential
            };
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Bool]
        let values = try #require(result)
        for (name, passed) in values { #expect(passed, "Credential compatibility: \(name)") }
        #expect(values.count == 9)
        #expect(!web.configuration.websiteDataStore.isPersistent)
    }
}
