import Testing
import WebKit
@testable import Origami

/// Synthetic pages only: these tests must not depend on Keychain contents or a signed-in Mac.
@MainActor struct CredentialCompatibilityTests {
    @Test func hostUpdatesPreserveResponderAndWindowAttachment() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = WebContentHost(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = host
        let first = TabPage(), second = TabPage()
        defer { first.dispose(); second.dispose(); window.close() }
        host.attach(first.webView)
        #expect(window.makeFirstResponder(first.webView))
        // Frequent media/progress/SwiftUI updates must not detach a focused web view.
        for width in [800.0, 900, 700] {
            host.attach(first.webView)
            host.setFrameSize(NSSize(width: width, height: 600))
            #expect(first.webView.window === window)
            #expect(window.firstResponder === first.webView)
            #expect(host.subviews.count == 1)
        }
        host.attach(second.webView)
        #expect(first.webView.window == nil)
        #expect(second.webView.window === window)
        #expect(window.makeFirstResponder(second.webView))
        host.attach(first.webView)
        #expect(second.webView.window == nil)
        #expect(first.webView.window === window)
        #expect(window.makeFirstResponder(first.webView))
    }

    @Test(.timeLimit(.minutes(1))) func browserScriptsPreserveCredentialFieldsAndWebAuthentication() async throws {
        let page = TabPage(); defer { page.dispose() }
        let web = page.webView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = WebContentHost(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = host
        host.attach(web)
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
            <form id="login" method="post"><input id="username" autocomplete="username">
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
        #expect(web.window === window)
        #expect(window.makeFirstResponder(web))
        let result = try await web.callAsyncJavaScript("""
            const baseline=window.credentialBaseline;
            const fields=[['username','username'],['password','current-password'],
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

        // SPA replacement must retain native inputs and form submission semantics.
        let dynamic = try await web.callAsyncJavaScript("""
            const form=document.getElementById('login');
            form.innerHTML='<input id="replacement" name="login" autocomplete="username"><input type="password" name="password" autocomplete="current-password"><button>Sign in</button>';
            await new Promise(resolve=>setTimeout(resolve,300));
            const input=document.getElementById('replacement'); input.focus();
            let submitted=false;
            form.addEventListener('submit',event=>{
              submitted=!event.defaultPrevented; event.preventDefault();
            },{once:true});
            form.requestSubmit();
            return submitted && document.activeElement===input && input.autocomplete==='username' &&
              form.method==='post' && form.querySelector('[name=password]').autocomplete==='current-password';
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(dynamic == true)
    }
}
