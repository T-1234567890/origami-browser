# Native authentication integration

## Second path: native AppKit field/menu investigation — September 25, 2026

This investigation deliberately did not rerun the failed AuthenticationServices password request. It examined public WebKit/AppKit APIs, AuthenticationServices consumer/provider boundaries, and Origami's input/menu handling.

### Result: public native-field AutoFill exists; the complete browser flow is not demonstrated

Apple's [WWDC20 AutoFill everywhere](https://developer.apple.com/videos/play/wwdc2020/10115/) documents native AppKit password and security-code AutoFill, including third-party providers. Its example uses `NSTextField.contentType = .username` and `NSSecureTextField.contentType = .password`. These APIs are public since macOS 11 and available on Origami's macOS 15.4 target. This is **native field AutoFill**, not `ASAuthorizationPasswordProvider`, and warrants a separate runtime test.

The public `NSResponder` standard action [`showContextMenuForSelection(_:)`](https://developer.apple.com/documentation/appkit/nsstandardkeybindingresponding/showcontextmenuforselection(_:)) is available since macOS 15. It routes through the responder chain and displays an ordinary context menu. It does **not** promise a password chooser or a password result callback. `NSView.menu(for:)`, `NSTextInputClient`, `NSTextInputContext`, `NSResponder.complete(_:)`, and native secure fields expose no documented password-provider-specific invocation selector in the inspected SDK. No private selector was invoked or guessed.

A genuine native credential field could receive values from system AutoFill through normal text editing. That is different from receiving an `ASPasswordCredential` with an authorization completion. It supplies no verified website scope, provider identity, or proof that a particular text edit was AutoFill. A future browser POC would therefore need an explicit user-directed fill operation, strict target binding, and prompt clearing of native fields. A native field should not be disguised as a system credential picker.

### WebKit and Origami audit

No native-macOS public WKWebView password-provider menu, field accessory delegate, or AutoFill enable switch was found in the installed public WebKit headers. The context-menu customization declarations in WKUIDelegate are UIKit APIs inside the iOS-family availability guards; they are not native AppKit password hooks. HTTP authentication challenges and WebAuthn requests are separate mechanisms.

Origami source findings:

- `TabPage` constructs an ordinary `WKWebView`; there is no custom WebKit subclass intercepting secure-input responders.
- `ImageDownloadMenu` checks the composed event path and returns for inputs, textareas, contenteditable fields, and text selection **before** calling `preventDefault()`. Its image/link menu does not replace normal login-input menus.
- `WebContentHost` attaches and sizes the web view. Its left-click monitor returns the event unchanged. It does not override context-menu, right-click, or first-responder handling.
- Browser scripts and preferences reviewed do not disable native form accessories or rewrite autocomplete attributes. The experimental password observer is currently gated off.
- The explicit `makeFirstResponder` override found in `GlobalBrowserControls` belongs to the separate quick-search field, not the web content.

**No suppression of native password UI was found in the reviewed production paths.** This is a source-audit result, not proof that every website, user script, focus transition, or system configuration behaves identically.

### AuthenticationServices alternatives

| Public surface | Role / why it is not the requested consumer hook |
| --- | --- |
| `ASCredentialProviderViewController.prepareCredentialList(for:)` | Called by the system inside a credential-provider extension. Not a browser API for invoking Apple Passwords. |
| `ASCredentialProviderExtensionContext.completeRequest(withSelectedCredential:completionHandler:)` | Provider returns a selected credential to the system; not an interface Origami can use to request another provider's credentials. |
| `ASCredentialIdentityStore`, `ASPasswordCredentialIdentity`, `ASPasswordCredentialRequest` | Provider identity/request infrastructure; not enumeration of Apple Passwords or a system chooser factory. |
| `ASSettingsHelper` | Opens provider settings or requests enabling an app's own provider extension. Does not select or return a password. |
| Browser public-key credential APIs | Passkeys/security keys only; working Origami integration unchanged. |
| `ASCredentialDataManager` | Reporting infrastructure; password save method unavailable on native macOS in this SDK; no alternative password chooser found. |

No new entitlement is documented for tagging ordinary AppKit input fields or invoking their standard context menus. The isolated probe requests only sandbox and outgoing networking. This does not grant website-scoped suggestions. Associated domains concern app/website credential association; the existing public-key browser entitlement does not enable password AutoFill. No evidence was found that adding `com.apple.developer.web-browser` supplies a documented WKWebView password-menu action. Credential-provider and Keychain-sharing entitlements were not added.

### Orion evidence

An [Orion developer's public explanation](https://orionfeedback.org/d/6932-suggest-a-password-from-a-3rd-party-password-managers-automatically/7) specifically attributes the provider popup to native NSTextField controls and describes limitations on accessing provider suggestions. This supports investigating AppKit fields; it does not document Orion's implementation or authorize use of any private method. The Apple documentation above is the public API basis.

### Isolated probe and observations

The standalone development-signed, sandboxed AppKit probe was removed at the user’s request after this investigation. It was not part of Origami. The tested setup included:

- Real native username/password fields tagged with `contentType`.
- A plain WKWebView with standard HTML login fields and no submission.
- Normal/ephemeral data-store selection.
- An optional **subset** of Origami settings and its input-preserving menu guard. This is not a full instance of Origami's browser store, scripts, blockers, or window host.
- Native focus-only interaction. The initial revision also tested the documented responder-chain context-menu action, but that control was removed to avoid competing menus.
- Value-free edit notifications; no credential text is read, logged, transferred to WebKit, or persisted. Clear native fields or close the probe after testing.

Initial runtime observation: the native context-menu action routed successfully. The user reported an incorrectly positioned dropdown and a password popup that appeared and disappeared. The initial button focused the secure field **and** requested its context menu; competing AutoFill/context menus are a plausible explanation, not a confirmed cause. The user could not identify the exact clicked control and closed the initial window. The simplified probe was then launched without context-menu buttons, retaining only direct native-field interaction and a focus-only button. Direct field interaction is the important next test.

After the simplified probe launched, the user confirmed that directly clicking the native password field opens a Passwords popup. The subsequent result was **only the password fills**, with the **Apple Passwords menu greyed out and not interactive**. Treat that as a partial user-observed native-field result, not proof of successful Apple Passwords credential selection or delivery. No username/password values were inspected. The cause of the disabled menu is unknown; neither a missing browser entitlement nor an Origami bug has been established.

| Comparison | Evidence / limit |
| --- | --- |
| Native AppKit password field | User observed the system Passwords popup on focus; later reported password-only filling and a disabled Apple Passwords menu. Full authorization/selection flow not demonstrated. |
| Vanilla WKWebView, normal store | Local HTML login fixture was loaded in the running probe. No user-confirmed menu/chooser result. |
| WKWebView with Origami configuration subset | Implemented as a comparison option; no confirmed user result. Not equivalent to the full app. |
| Ephemeral WKWebView | Implemented as a comparison option; no confirmed user result. |
| Actual Origami | Source audit found no input-menu suppression. No new runtime comparison of its menu against the fixture was completed. |
| Safari | Not tested during this investigation. Safari behavior cannot be inferred from the vanilla web view. |

A successful context-menu dispatch alone is not evidence of password selection. No production key-button POC has been enabled. The standalone probe compiles, is development-signed with sandbox/network entitlements, and has a different bundle identity from Origami; it is not a provisioning-equivalent reproduction. No private API or framework internals were inspected.

### Decision and next step

There is a documented **native AppKit AutoFill surface**, so the earlier negative AuthenticationServices result must not be generalized to all public macOS UI paths. However, no documented direct Password Providers selector was found, and the native-field probe did not demonstrate a working manual Apple Passwords selection plus username/password delivery. Consequently, an Orion-style browser bridge remains **unproven**, rather than declared impossible.

Keep production password/passkey code unchanged. The next targeted check is why Apple Passwords is disabled for this minimal native field: compare with a normal AppKit app under the same AutoFill provider settings and signing context, then ask Apple Developer Technical Support whether native-field AutoFill is supported for a browser-owned, user-invoked login accessory and how a username/password pair is delivered. Include the macOS 26.3/Xcode 26.5 versions and the disabled-menu observation; the temporary probe source has been removed. Do not infer that adding browser/provider entitlements will fix it.

Only after a working picker and delivery are demonstrated should a browser POC bind the native fields to a specific tab, document generation, main frame, HTTPS origin, and exact login form. It must invalidate on navigation/tab changes/field removal, require explicit fill, clear temporary native fields, never submit, and never retain private-browsing credential metadata. No fake system UI, vault, direct Keychain access, or extension-hosting workaround was added.

---

## Manual Password Providers investigation — September 25, 2026

**Result: no viable documented public implementation was established on this Mac.** A manual picker containing all credentials would satisfy this investigation; lack of automatic website matching is **not**, by itself, a rejection of that design. The remaining blocker is obtaining such a picker through a documented native macOS consumer API. The tested AuthenticationServices request failed before returning a credential. No inline password UI or form filling was enabled, and passkey code/signing were not changed.

### Runtime and SDK evidence

Environment: macOS **26.3**, Xcode **26.5 (17F42)**; Origami deploys to **macOS 15.4**.

An isolated development-signed, sandboxed AppKit app was compiled, its signature verified, and launched. It contains a WKWebView test form and a native **Request Password** button. The button retains an `ASAuthorizationController`, assigns both delegates, supplies its visible `NSWindow` as the presentation anchor, and invokes `performRequests()` with `ASAuthorizationPasswordProvider().createRequest()`. No request runs automatically. It never reads, logs, persists, or fills credential values.

| Check | Actual result |
| --- | --- |
| `performRequests()`, normal WKWebView data store | User clicked the button; delegate returned `ASAuthorizationError`, code **1004**. No authorized credential returned. |
| Same request, ephemeral WKWebView data store | Same **1004**, including repeated requests. |
| Native picker / Touch ID | No successful picker/authorization flow established. User reported the request failure; no independent visual inspection was performed. |
| `performAutoFillAssistedRequests()` | Standalone `swiftc -typecheck` fails: explicitly **unavailable in macOS**. Cannot runtime-test this method through public APIs on this target. |
| Credential callback | Success branch checks only whether the type is `ASPasswordCredential`; it was not reached. Username/password values and their presence were deliberately not inspected. |
| Request cancellation | Probe includes `cancel()`; picker cancellation was **not verified**, because requests failed first. |
| Multiple credentials, no match, two-step login, GitHub fill, tab/navigation changes, iframe fill | **Not tested end-to-end**: no working credential source. No production fill POC was enabled. |
| Passkeys | Existing user-confirmed GitHub success; architecture unchanged. No new passkey login was performed during this investigation. |
| OTP/TOTP | HTML `one-time-code` fixture provided; actual delivered-code/TOTP suggestions **not verified**. No codes or secrets accessed. |

**1004 is a generic failure, not proof of a particular missing entitlement.** This isolated probe has its own bundle identity, sandbox and network entitlements, and no associated domains or browser capabilities. It is not a provisioning-equivalent Origami build. Its failure establishes that this ordinary native request did not yield the desired chooser here, not that every possible third-party browser implementation is impossible. The normal/ephemeral check changes the web view's data store; AuthenticationServices requests themselves have no private-browsing parameter or reference to that web view.

The standalone password-request probe and its temporary build artifacts were removed at the user’s request. The historical test results above are retained.

### Public API and entitlement boundaries

- `ASAuthorizationPasswordProvider`, `ASAuthorizationController.performRequests()`, and `ASPasswordCredential` are public on macOS 10.15+. Apple's documented password-sharing path uses `com.apple.developer.associated-domains`, cooperating website association, and user consent. That relationship cannot simply be claimed for arbitrary browsing sites such as GitHub.
- `ASAuthorizationPasswordRequest` has no URL/domain filter, and its parent request adds only the provider. `ASPasswordCredential` exposes `user` and `password`, **not a website/domain**. A genuinely user-directed all-passwords chooser could still be useful, but no documented option enabling that chooser was found on this request.
- The existing signed Origami app was inspected again with `codesign`: **public-key-credential = true**, sandbox enabled. **web-browser**, **associated-domains**, **keychain-access-groups**, and **autofill-credential-provider** are absent. No entitlements were added for this probe/investigation beyond the probe's sandbox/network access.
- `com.apple.developer.web-browser.public-key-credential` is for browser passkeys, not password retrieval. No documentation was found making `com.apple.developer.web-browser` an arbitrary-site password-request unlock on native macOS; requesting it is not an established fix for this failure.
- `ASCredentialDataManager` exists on macOS 26.2+, but the installed Swift interface explicitly marks `save(password:for:title:anchor:)` unavailable on macOS. Its reporting APIs do not retrieve credentials. Save/update is outside this POC anyway.
- `com.apple.developer.authentication-services.autofill-credential-provider` is for supplying a manager's credentials, not consuming Apple Passwords. Keychain Sharing does not grant access to Apple's password database. Neither is an appropriate workaround.
- AppKit presentation uses an `NSWindow`, not a tab view. The probe supplies a real window; that supplies presentation context, not credential eligibility or website scope.

### Orion comparison

[Kagi's documented manual flow](https://help.kagi.com/orion/features/password-management.html#using-safari-passwords-in-orion-on-macos) explicitly describes a login-field key icon, a Passwords action, system unlocking, and manual credential selection. It establishes the user-visible behavior, **not the implementation API**. These public instructions do not identify `ASAuthorizationPasswordProvider`, a browser entitlement, or a public method Origami can call to reproduce it. This investigation does not assert Orion uses private APIs; its internals were not inspected.

### Form and UI design assessment, if a credential source becomes viable

The existing dormant fallback in `PasswordFillController` / `PasswordFillScript` was reviewed. It uses a named isolated content world, main-frame messages, a native SwiftUI key button, exact web-view identity, HTTPS URL and form-action checks, and one-shot DOM target references. It recognizes username/current-password fields conservatively and excludes new-password and OTP fields. It currently requires one username and one password in a POST form; username-first, password-only, ambiguous and iframe forms are unsupported. Dynamic focus, mutations, scrolling and resizing update its anchor. These are source findings, **not proof of a working or fully audited password-fill feature**.

A native overlay is preferable for a future POC: it avoids inserting credential controls into website DOM/CSS and makes the initiating click browser-owned. It still needs robust zoom/scroll/occlusion handling. Shadow DOM isolates styles but modifies the page and can be moved or removed by it; a plain injected button has the most CSS/layout interference. No new affordance was built because the credential-source gate failed.

Before enabling any fill, capture a request identifier, tab/web-view identity, navigation generation, origin, frame identity and exact form/field references; invalidate on navigation, tab switch, frame destruction, or target change. Revalidate **before sending secrets into JavaScript**, then again in the isolated world, and never submit automatically. Same-URL reloads and SPA form replacement must invalidate old requests too. Fill with structured arguments and the minimum `input`/`change` events, without retaining values in browser state. Swift/Foundation do not guarantee zeroization of framework-owned immutable strings.

Public `WKFrameInfo.securityOrigin` and `callAsyncJavaScript(...in:contentWorld:)` support frame targeting. That does not authorize cross-origin credential disclosure. A first POC should reject **all child frames**, including same-origin frames, until explicit frame lifetime/origin binding is implemented and tested. No cross-origin support is claimed.

WKWebView keeps native WebAuthn and existing input/autocomplete behavior. Standard `username`, `current-password`, `new-password`, `one-time-code`, and `webauthn` semantics should remain untouched. Apple documents these field semantics, but they do not guarantee Safari-equivalent password/TOTP UI in every WKWebView. Current delivered-verification-code API documentation describes macOS 27 functionality absent from this SDK; it is not a TOTP/password-picker solution.

### Decision / next step

Leave the production password fallback disabled. The native picker must first be demonstrated through a documented macOS API; only then is an inline-fill POC justified. An Apple Developer Technical Support question should ask specifically for the supported **manual all-credentials Password Providers consumer API in a native AppKit/WKWebView browser**, and whether any additional entitlement is required. Supply the documented probe setup and redacted result code, not credential data. No custom vault, extension hosting, private API, Keychain enumeration, or passkey workaround was added.

Sources: [Apple password access security](https://support.apple.com/guide/security/app-access-to-saved-passwords-sec8762eb992/web), [password provider](https://developer.apple.com/documentation/authenticationservices/asauthorizationpasswordprovider), [password credential](https://developer.apple.com/documentation/authenticationservices/aspasswordcredential), [AutoFill-assisted requests](https://developer.apple.com/documentation/authenticationservices/asauthorizationcontroller/performautofillassistedrequests()), [HTML field semantics](https://developer.apple.com/documentation/security/enabling-password-autofill-on-an-html-input-element), and the installed SDK headers/Swift interfaces. Orion's documentation is evidence for its UX only.

---

## Earlier website-scoped investigation — September 25, 2026

**Conclusion:** no documented, safely website-scoped direct password integration was found for Origami's native macOS WKWebView browser using the installed Xcode 26.5 SDK. This is not a claim that Apple Passwords cannot work in any third-party browser: Apple supports extensions in selected browsers. No password proof of concept was enabled and no application code or signing configuration was changed in this investigation.

### Current evidence

- Deployment target: macOS 15.4. Installed toolchain: Xcode 26.5 (17F42).
- Read the effective entitlements of the running Xcode-built Origami app using `codesign`: `com.apple.developer.web-browser.public-key-credential = true`, sandbox enabled. `com.apple.developer.web-browser`, associated domains and keychain-access-groups are absent.
- The user confirms real-site passkey authentication succeeds. Earlier provisioning failures below are historical, not a current blocker.
- Native WKWebView configuration preserves input interaction and profile-specific website data. No public password-AutoFill enable switch was found in WKPreferences, WKWebViewConfiguration, WKWebView or WKUIDelegate headers.
- Existing password fallback remains disabled before installing its DOM observer or making a request. Its origin/target checks cannot compensate for a credential API that does not supply a verifiable website scope.

### API and entitlement findings

| API/path | macOS availability and conclusion |
| --- | --- |
| ASAuthorizationPasswordProvider.createRequest(), ASAuthorizationController.performRequests(), ASPasswordCredential | Public since macOS 10.15. Appropriate for app-associated website credentials with website cooperation and user consent. The request has no website/domain selector; the returned credential contains username/password but no domain. No documented browser-entitlement exception was found for arbitrary websites. This does not satisfy Origami's domain-scoped picker requirements. |
| SecRequestSharedWebCredential | Has a domain argument and returned server metadata, but explicitly restricts access to associated domains. Deprecated on macOS in favor of AuthenticationServices. Not a workaround for unrelated sites. |
| SecAddSharedWebCredential | Available on macOS 11, deprecated in 26.2; requires the shared-web-credential associated-domain relationship. Can add/update for cooperating sites, not arbitrary browser sites. |
| ASCredentialDataManager.save(password:for:title:anchor:) | Class available on macOS 26.2, but this method is explicitly unavailable on macOS. A standalone swiftc typecheck produced that exact error. Current Apple documentation also omits native macOS from this method's availability. Mac Catalyst availability does not apply to this AppKit app. |
| ASCredentialDataManager reporting methods / older ASCredentialUpdater | Account/credential validity reports, not a password picker or save/update replacement. Origami cannot infer reliable server account state from arbitrary submitted forms. |
| ASAuthorizationController.performAutoFillAssistedRequests() | Explicitly unavailable on macOS in the SDK. |
| ASAuthorizationWebBrowserPublicKeyCredentialManager and browser public-key providers | Passkeys/security keys; not a username/password retrieval API. Existing native WebKit handling stays unchanged. |
| ASDeliveredVerificationCodesManager | Current documentation introduces this in macOS 27; absent from the installed 26.5 SDK. Covers delivered SMS/email codes, not TOTP secrets or ordinary password credentials. No SDK upgrade, polling or new code access was added. |
| Credential-provider extensions / identity store | A provider supplies credentials from its own manager. These are not APIs for a browser to enumerate or consume Apple Passwords directly. |
| ASWebAuthenticationSession | Service login with a callback handled by a browser; not a password-return API or a way to transfer an arbitrary site's authenticated session into Origami's WKWebView. |

The save method's documentation requires a webcredentials associated domain **or** `com.apple.developer.web-browser` on supported platforms. Origami lacks that separate entitlement, but obtaining it would not make a macOS-unavailable method callable. The working public-key entitlement does not grant password access. Keychain Sharing does not grant access to Apple's credential database. No additional entitlement with documented arbitrary-site password retrieval on native macOS was identified.

### Native AutoFill and extension alternative

Preserve `username`, `current-password`, `new-password`, `one-time-code` and `webauthn` semantics. Apple documents verification-code AutoFill through correctly tagged fields, and macOS 26 delivered-code AutoFill through normal text input. Actual suggestions depend on macOS/provider/site behavior; neither TOTP suggestions nor Safari-equivalent password generation/save UI in Origami has been verified. No code observes or stores code values.

Apple's supported third-party-browser password route is its iCloud Passwords extension. Origami currently has no WKWebExtension host. The available Apple support documentation does not establish that installing an extension host would authorize Apple's companion integration for Origami. Implementing a host, impersonating another browser or reverse-engineering native messaging is not a safe minimal proof of concept for this task. This remains a separate compatibility question for Apple, not a proven solution or a reason to create a custom vault.

Multiple-password selection, cancellation/no match, username-first forms and password/username changes cannot be claimed implemented without a valid scoped source. The gated fallback accepts only a same-origin HTTPS POST form with one visible username and one password; it deliberately rejects signup, ambiguous, changed and OTP targets. Private mode, profile separation and working passkeys are unchanged.

### Manual verification boundary

No saved passwords or verification codes were accessed during this investigation; no runtime authorization was performed. The only new executable probe was a compile-only API-availability check. Existing unit results below are historical, not freshly rerun tests.

On the same configured Mac, compare Safari and the freshly signed Origami build on the same login site: saved account(s), cancellation, no matching account, username-first login, signup/password change, and one-time-code fields with configured TOTP and delivered codes. Repeat in private browsing and across two tabs/profiles/origins. Record whether the system actually offers suggestions; do not record values. Recheck the already-working passkey sign-in as a regression check. These remain user-assisted checks, not evidence of an implemented password picker.

Additional sources:

- [App access to saved passwords](https://support.apple.com/guide/security/app-access-to-saved-passwords-sec8762eb992/web)
- [Password save/update API](https://developer.apple.com/documentation/authenticationservices/ascredentialdatamanager/save(password:for:title:anchor:))
- [Delivered verification codes](https://developer.apple.com/documentation/authenticationservices/asdeliveredverificationcodesmanager)
- [iCloud Keychain verification-code AutoFill](https://developer.apple.com/documentation/authenticationservices/securing-logins-with-icloud-keychain-verification-codes)
- [Apple Passwords extensions for third-party browsers](https://support.apple.com/guide/passwords/mchlf7ac261e/mac)

---


Origami delegates website authentication to WebKit/macOS. It has no website credential vault, password history, TOTP generator, credential-list UI, or JavaScript WebAuthn replacement.

## Supported architecture

`BrowserCredentialCoordinator` centralizes signed-capability detection and browser passkey authorization. The coordinator provides an explicit authorization entry point without adding a status row or permanent authentication UI. No automatic permission prompt is added. It handles not-determined, authorized and denied states, prevents overlapping requests, and refreshes after returning from System Settings. Denied access explains Privacy & Security → Passkeys Access for Web Browsers and opens System Settings through NSWorkspace. No undocumented Settings URLs are used.

Passkey creation, assertion, conditional mediation, credential selection and security-key handling remain with WKWebView's native implementation. The coordinator does not enumerate credentials or copy challenges through a page bridge. Actual support depends on the OS, provider, website and signed capability; exposing `navigator.credentials` alone does not prove successful authentication.

## Password API limits — Xcode 26.5, deployment macOS 15.4

| Operation | Status |
| --- | --- |
| Native WebKit password/OTP suggestions | Preserved; Safari-equivalent presentation is not guaranteed |
| Arbitrary-site password picker via ASAuthorizationPasswordProvider | Disabled: no documented manual all-credentials chooser established; isolated runtime requests failed with code 1004 |
| Password save/update via ASCredentialDataManager | Unavailable on macOS in the inspected SDK |
| Passkeys | Native WebKit plus browser permission coordinator, gated by effective signed entitlement |
| App-owned API keys | KeychainStore using Security.framework |

`ASAuthorizationPasswordProvider.createRequest()` and `ASAuthorizationController.performRequests()` are public macOS APIs for app-associated credentials. They are not a domain-scoped picker for arbitrary browser pages. The old experimental request remains disabled even with `ORIGAMI_ENABLE_PASSWORD_AUTOFILL=1`. This prevents sending app-associated credentials to an unrelated site. No field observer is installed while this capability is unavailable. No form password is collected for save/update.

The SDK declares ASCredentialDataManager itself available on macOS 26.2, but explicitly marks `save(password:for:title:anchor:)` unavailable on macOS. Its SwiftUI wrapper does not remove that restriction. The general save API documentation requires either a webcredentials associated domain or `com.apple.developer.web-browser`; adding that entitlement cannot make an unavailable macOS method usable. The macOS reporting methods are not save APIs and require reliable relying-party information; Origami does not guess account deletion or changes from page contents.

Normal username/password, new-password, one-time-code and webauthn autocomplete attributes, native input events, focus, form submission and profile data stores are preserved. The dormant isolated-world fallback rejects cross-origin form actions, ambiguous fields, new-password forms, changed targets and OTP-as-username fields. It is main-frame only, one-shot, and does not submit. It cannot be enabled until a documented credential source is demonstrated, whether website-scoped or explicitly user-selected for the initiating website. Lack of domain metadata alone does not rule out the latter design.

Delivered-code AutoFill is provided by macOS where available. macOS 26 supports Messages/Mail delivered-code AutoFill for text-entry apps. Origami does not restrict it with NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac. Password-manager TOTP suggestions depend on the native provider integration; there is no guarantee that WKWebView presents every Safari suggestion. Origami never reads TOTP seeds, polls codes, or implements a credential-provider extension to scrape them. No beta-only APIs are adopted.

## Signing and capability gates

The ordinary entitlement file now requests the approved `com.apple.developer.web-browser.public-key-credential` capability, alongside sandbox, printing and scoped-file access. Both Debug and Release use this file. Xcode also emits the existing network/camera/microphone/user-selected-file entitlements. No Keychain Sharing, Associated Domains or App Groups were added.

`Configuration/Passkeys.xcconfig` is now a compatibility alias for the normal entitlement file. No opt-in build is needed. Select the approved development team and refresh the explicit Origami provisioning profile. Ad-hoc builds cannot use this managed entitlement.

The coordinator reads the running executable's entitlements with SecCodeCopySelf, SecCodeCopyStaticCode and SecCodeCopySigningInformation. Missing/failed signing information and ad-hoc signatures fail closed. A signed entitlement is necessary, but the OS permission decision remains authoritative; it is not proof of Apple approval on its own.

The user confirms Apple has approved the passkey capability. The earlier development-signing attempt used an installed wildcard profile that lacked Web Browser Public Key Credential Requests. Account approval and inclusion in the signed application are distinct; refresh the explicit Origami profile for the approved team. The distinct `com.apple.developer.web-browser` entitlement is absent and was not added; it would not unlock the macOS-unavailable save method.

Before release, inspect the actual signed archive, not merely project settings:

```sh
codesign -d --entitlements :- /path/to/Origami.app
codesign -dv --verbose=4 /path/to/Origami.app
security cms -D -i /path/to/Origami.app/Contents/embedded.provisionprofile
```

Check the passkey entitlement in both signature and approved profile, the expected identifier/team, a non-ad-hoc identity, and sandbox permissions. Do not ship a locally added managed entitlement that the profile does not authorize.

## App-owned Keychain

KeychainStore implements add/read/update/delete and upsert, handles a concurrent duplicate insertion, and preserves OSStatus in typed errors without including secret values. AI UI maps errors to its existing generic message. Existing provider API keys retain service/account identity and backend, so no plaintext migration is needed. Items are non-synchronizing and WhenUnlockedThisDeviceOnly; no user-presence or biometric requirement is added. Metadata-only availability checks avoid prompts.

Only Origami's AI provider API keys currently use this store. Model names, provider selection and setup flags remain preferences. Website passwords, passkeys and OTP secrets never enter it. There is no new credential persistence in private browsing, profile storage, session restoration or diagnostics. Private WKWebsiteDataStore does not imply that a system provider cannot offer an existing user credential.

## Validation and manual handoff

Validation before enabling the managed entitlement in normal builds: 10 tests in three suites passed, the ordinary Apple Development-signed build succeeded, and `codesign --verify --strict` passed. Effective entitlements include sandbox, network client, scoped/user-selected files, printing, camera/microphone, debug get-task-allow and the existing Sparkle Mach services. Neither managed browser entitlement is present in that baseline build. The passkey-enabled build was blocked by provisioning before signing.

Account-independent tests cover Keychain CRUD/error/duplicate handling at an injected Security boundary, separate capability detection, ad-hoc gating, passkey request state policy, hostile form changes, OTP exclusion, preserved native autocomplete/WebAuthn APIs, ephemeral WebKit data, and responder/window attachment. They do not access a user's saved credentials or prove real Keychain ACL behavior. Earlier code-1004 password-request observations are generic authorization failures, not proof of a particular missing entitlement.

Use a freshly built development app and signed release, not the older installed app:

1. Verify the final signature/profile first. Exercise native website passkey authorization and check allow, deny and return-from-Settings behavior; denial must not repeatedly prompt.
2. Compare identical GitHub login, signup and password-change pages in Safari and Origami on the same Mac. Check multiple saved accounts, cancellation, strong-password generation, save/update prompts and changed usernames. Record unsupported native flows as limitations; there is no fallback vault.
3. Test passkey registration and sign-in, multiple passkeys, conditional UI, cancellation, denied permission and a security key on supporting sites. Confirm successful website authentication, not merely a displayed dialog.
4. Test password-manager TOTP and Messages/Mail codes in one-time-code fields where offered. Never record values.
5. Repeat after navigation, reload, tab switching, profile switching, private windows and cross-origin iframe forms. No credential should be injected by Origami into another target.
6. In a signed build, save/update/remove a disposable AI key, relaunch, and check normal access without repeated biometric prompts. Real account-assisted and release-build checks remain manual and unverified here.

## Apple references

- [Passkeys in browser apps](https://developer.apple.com/documentation/authenticationservices/authenticating-people-by-using-passkeys-in-browser-apps)
- [Password save API](https://developer.apple.com/documentation/authenticationservices/ascredentialdatamanager/save(password:for:title:anchor:)) — additionally inspect SDK platform availability
- [Browser passkey entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
- [Delivered-code AutoFill on macOS](https://developer.apple.com/documentation/bundleresources/information-property-list/nsautofillrequirestextcontenttypeforonetimecodeonmac)

Historical provisioning attempt (resolved in the running build inspected above): automatic updates were enabled for the installed development team and bundle ID `dev.1234567890.Origami`. Xcode selected an explicit “Mac Team Provisioning Profile: dev.1234567890.Origami”, but reported that it still lacks Web Browser Public Key Credential Requests. The enabled normal build therefore fails signing until that App ID/profile includes the approved capability. Confirm the approved team/App ID and enable the managed capability in the developer portal before regenerating profiles. This is a provisioning blocker, not a request to reapply for approval.
