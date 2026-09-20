import AuthenticationServices
import SwiftUI
import WebKit
import Observation

@MainActor @Observable final class PasswordFillController: NSObject, WKScriptMessageHandler,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private(set) var available = false
    private(set) var busy = false
    var message: String?
    private(set) var fieldAnchor: CGPoint?
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored var allowed: (() -> Bool)?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var authorization: ASAuthorizationController?
    @ObservationIgnored private var anchor: NSWindow?

    func install(on webView: WKWebView) {
        guard BrowserFeatureFlags.passwordAutoFill else { return }
        self.webView = webView
        let content = webView.configuration.userContentController
        content.add(self, contentWorld: PasswordFillScript.world, name: "origamiPasswordFocus")
        content.addUserScript(WKUserScript(source: PasswordFillScript.source, injectionTime: .atDocumentEnd,
                                          forMainFrameOnly: true, in: PasswordFillScript.world))
    }

    func reset() {
        let previous = authorization
        authorization = nil; anchor = nil; token = nil; url = nil
        available = false; busy = false; message = nil; fieldAnchor = nil
        previous?.cancel()
    }

    func dispose() {
        reset()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "origamiPasswordFocus", contentWorld: PasswordFillScript.world)
        webView = nil; allowed = nil
    }

    func refresh() {
        guard BrowserFeatureFlags.passwordAutoFill, let webView, allowed?() == true else { return }
        Task { _ = try? await webView.callAsyncJavaScript("window.__origamiPasswordFill?.refresh();", arguments: [:], in: nil, contentWorld: PasswordFillScript.world) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let text = body["url"] as? String,
              let url = URL(string: text), url.scheme == "https", webView?.url == url,
              let token = body["token"] as? String, token.count <= 32 else { return }
        if self.token != token || self.url != url { reset() }
        guard !token.isEmpty, allowed?() == true else { reset(); return }
        self.token = token; self.url = url; available = true
        if let x = body["x"] as? Double, let y = body["y"] as? Double,
           x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) {
            fieldAnchor = CGPoint(x: x, y: y)
        } else {
            fieldAnchor = nil
        }
    }

    /// Only called from the native key button, never from a webpage message.
    func request() {
        guard BrowserFeatureFlags.passwordAutoFill, !busy, available, token != nil, allowed?() == true,
              let webView, webView.url == url, let window = webView.window, window.isKeyWindow else { return }
        message = nil; busy = true; anchor = window
        let request = ASAuthorizationPasswordProvider().createRequest()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        authorization = controller
        controller.delegate = self; controller.presentationContextProvider = self
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Captured before performRequests and retained for the authorization lifetime.
        anchor ?? NSWindow()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization result: ASAuthorization) {
        guard controller === authorization else { return }
        guard let credential = result.credential as? ASPasswordCredential,
              let webView, webView.url == url, webView.window === anchor,
              allowed?() == true, let token else { reset(); return }
        Task { @MainActor [weak self] in
            guard let self, controller === self.authorization, self.allowed?() == true,
                  webView.url == self.url, webView.window === self.anchor else { return }
            // Structured arguments avoid interpolation/logging. Credentials are held
            // transiently for this call only and are never persisted or submitted.
            let filled = try? await webView.callAsyncJavaScript(
                "return window.__origamiPasswordFill?.fill(token, username, password) === true;",
                arguments: ["token": token, "username": credential.user, "password": credential.password],
                in: nil, contentWorld: PasswordFillScript.world) as? Bool
            guard controller === self.authorization else { return }
            self.authorization = nil; self.anchor = nil; self.busy = false
            self.token = nil; self.available = false
            if filled != true { self.message = L10n.string("The login form changed. Focus it and try again.") }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === authorization else { return }
        authorization = nil; anchor = nil; busy = false
        let code = (error as NSError).code
        if (error as NSError).domain == ASAuthorizationError.errorDomain && code == ASAuthorizationError.canceled.rawValue { return }
        // Do not display localizedDescription/userInfo: provider errors may include account data.
        message = L10n.format("Apple Passwords could not complete this request (code %@). Website password access through this API requires an approved app–website association. Origami cannot offer Safari-style password access through this request alone.", String(code))
    }
}

struct PasswordFillButton: View {
    let controller: PasswordFillController
    var body: some View {
        GeometryReader { geometry in
            if BrowserFeatureFlags.passwordAutoFill, let anchor = controller.fieldAnchor,
               controller.available || controller.message != nil,
               anchor.y * geometry.size.height + 36 <= geometry.size.height {
                Button { controller.request() } label: {
                    Image(systemName: "key.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                .fixedSize()
                .disabled(controller.busy)
                .help("Use a saved password").accessibilityLabel("Use a saved password")
                .popover(isPresented: Binding(get: { controller.message != nil }, set: { if !$0 { controller.message = nil } })) {
                    Text(controller.message ?? "").font(.callout).padding(14).frame(width: 290)
                }
                .position(x: min(max(22, anchor.x * geometry.size.width - 20), max(22, geometry.size.width - 22)),
                          y: anchor.y * geometry.size.height + 20)
            }
        }
    }
}
