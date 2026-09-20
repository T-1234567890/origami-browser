# Password AutoFill

Origami does not provide a password manager, store credentials, or rewrite `autocomplete` attributes. A user-initiated key button requests saved credentials using Apple's native authorization UI. Automatic Safari-style suggestions remain a separate, unresolved capability.

## Experimental feature flag

The experimental key-button authorization is off by default. To opt in, set
`ORIGAMI_ENABLE_PASSWORD_AUTOFILL=1` in the Xcode scheme's Run environment and
relaunch. All other values leave it disabled. The flag gates script/handler
installation, the floating button, and authorization requests. It is not a user
setting and does not disable WebKit's own native AutoFill behavior.

## User-initiated authorization

The key button appears as a small floating icon below the focused field, following scrolling and layout changes when a supported login input is focused. It calls `ASAuthorizationPasswordProvider.createRequest()`, presents the resulting `ASAuthorizationPasswordRequest` using `ASAuthorizationController.performRequests()`, and accepts only `ASPasswordCredential`. Both APIs are public and available from macOS 10.15. No private WebKit menu action or fake picker is used.

Returned credentials are transient structured JavaScript arguments, never interpolated into script source, logged, copied to the clipboard, or persisted by Origami. An isolated content world fills only the captured form after revalidating its URL, focused input, element identities and action. It dispatches input/change events but never submits the form. Navigation, leaving the web content, and tab changes cancel pending authorization. No webpage message can initiate an authorization request.

The first implementation supports HTTPS main-frame forms with a same-origin POST action, exactly one visible writable password field, and exactly one identifiable username/email field. It deliberately omits ambiguous forms, cross-origin/iframe login forms, multi-step username-only forms, new-password forms, HTTP and mixed-content pages. Native website fields remain usable normally.

### Runtime result

On macOS 26.3 with the Xcode 26.5 SDK, a standalone ad-hoc-signed AppKit probe called the exact provider/request/controller flow with a real NSWindow presentation anchor. The delegate returned `com.apple.AuthenticationServices.AuthorizationError`, code **1004** (`ASAuthorizationError.failed`), with no credential. Only the error domain/code was recorded. This proves runtime availability and a failure in that probe configuration, not successful website credential access or a blanket failure on every signed build.

`ASAuthorizationPasswordRequest` exposes no public relying-party URL/domain selector in this SDK. This flow must not be represented as unrestricted access to passwords for whatever website is open. A properly signed Origami build still needs account-assisted verification of which credentials Apple offers. Origami shows a sanitized numeric authorization error when the request fails; cancellation is silent. `performAutoFillAssistedRequests()` is explicitly unavailable on macOS in this SDK and is not used.

## Browser integration

Tab selection must not clear the key window's first responder: in Split View, selection can happen after the user has already focused a login field. The address bar ends editing only when its own field or field editor still owns focus. Delayed address updates must not dismiss another control's editing session.

The web content host retains the attached WKWebView across ordinary layout updates. Profile website data stores remain independent of the system password provider. Origami's scripts preserve username, current-password, new-password and one-time-code fields, including dynamically replaced forms. See Apple's [HTML Password AutoFill guidance](https://developer.apple.com/documentation/security/enabling-password-autofill-on-an-html-input-element).

## Verification and limits

Automated tests cover responder ownership, web view attachment, credential attributes, focus/input events, form submission and dynamic form replacement. They use synthetic pages and do not access saved credentials. These checks establish browser compatibility, not successful system credential suggestions.

During investigation on macOS 26.3, Safari showed automatic saved-password suggestions on GitHub's login page. A minimal AppKit app using an unmodified WKWebView did not show automatic suggestions when the password field was focused, although WebKit exposed its existing AutoFill context menu. That control was ad-hoc signed; this observation does not establish a limitation for every macOS version or signing configuration. Its context menu is not a proposed Origami feature. No public WKWebView switch for Safari's automatic password suggestion UI was identified in the inspected SDK.

The user subsequently reported that GitHub still shows no automatic Apple Passwords suggestions. Treat Safari-style password AutoFill as an unresolved feature, not as fixed by the responder changes. The older installed Origami app is not evidence of the current checkout's behavior; a controlled comparison of a freshly built app and a valid signed release remains outstanding. Command-line tests cannot confirm whether the system credential popover appears.

Before claiming Safari-style parity, test a freshly compiled development app and a valid signed release on the same configured Mac and URLs:

- Saved username/password suggestions, fill and normal submission.
- Strong-password generation on signup and password-change forms.
- One-time-code suggestions where the system offers them.
- Reload, navigation, tab and Split View selection, profile changes, and private windows.

Do not record credential values or verification codes. Passkeys are a separate verification area; Web Authentication API availability does not prove password AutoFill works. If system authorization fails, document the observed platform/signing conditions rather than using private APIs or claiming success.

The reported code 1004 is a generic authorization failure, not a diagnosis of a specific entitlement or account problem. Apple documents [app access to saved passwords](https://support.apple.com/en-gb/guide/security/sec8762eb992/web) as requiring approval by the app developer and website administrator, plus user consent. Origami cannot establish that association for GitHub or other unrelated websites on its own. Moving the key button does not resolve this API limitation. Error codes are formatted as identifiers without locale digit grouping.
