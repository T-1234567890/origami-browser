# Origami Roadmap

Origami will continue focusing on native macOS browsing, useful built-in tools, contextual intelligence, and an open-source development model.

> This roadmap is directional, not a commitment. Features, scope, and target versions may change as Origami evolves.

Status key:

- ✅ = Implemented
- ~~Strikethrough~~ = Removed / deprioritized
- Normal text = Planned

When an entire version is complete, ✅ appears after its title instead of beside individual features. Crossed-out items remain crossed out.

## v1.0.x — Ship & Polish ✅

Focus on improving the existing browser rather than expanding scope.

- Stability, performance, and bug fixes
- Reader Mode improvements
- Peek / Split View polish
- RSS and JSON Reader fixes
- Media detection improvements
- Compact Mode refinement
- Release, update, and distribution pipeline polish

## v1.1 — Better Browsing ✅

- Peek 2.0 with structured, non-AI previews
- Content and ad blocking
- Migration from other browsers
- Connection security indicators
- Certificate information
- Profiles 2.0 / configurable profile sharing

Migration prioritizes bookmarks, history, tabs, and sessions. Website password importing is not implemented; Apple Passwords integration must not be assumed to provide a replacement until a supported path is verified.

Profiles should remain a single concept, with no separate Spaces system. They may provide isolated browsing contexts or lighter context switches, with configurable sharing or isolation for website data / sign-ins, history, bookmarks, appearance, and tab layout. Pinned tabs, tab groups, and open tabs can remain profile-specific. AI and search settings remain global.

## v1.1.1 — Stabilization & Release Validation

The planned v1.1 feature set is implemented; the remaining work in the v1.1 line is stabilization and release validation. The items below are remaining release checks, not claims that the corresponding fixes are absent. Completed earlier versions retain their historical status.

- Verify new-tab background and title-image replacement: repeated changes, cancellation, invalid/large files, profile switching and relaunch.
- Verify downloads on real sites, including Google Images Save Image As, duplicate filenames, cancellation/failure, simultaneous downloads, tab closure, private browsing and restored history. Confirm the normal-size download icon bounces when a download starts and file-type icons display correctly.
- Verify essential link/image context-menu actions and gallery Peek suppression. Copy Image currently uses the displayed snapshot for cross-origin images and is disabled in embedded frames.
- Verify printing and complete-page exports on complex sites, including CSS/assets and reopening saved pages offline. Document remaining fidelity limits.
- Verify the native PDFKit viewer on public, authenticated, large and encrypted PDFs: Save/Print, search, thumbnails, Back/Forward, duplicate tabs, Share/Preview and private-session cleanup. See [the PDF validation checklist](docs/native-pdf-viewer.md).
- Verify default-profile selection and bookmark-import merging across relaunch and shared/isolated profiles. Existing duplicate bookmark folders are not retroactively consolidated by the import fix.
- Verify the final signed release: approved passkey entitlement, sandbox permissions, update/distribution flow, and successful real-site passkey sign-in.
- Run relevant regression tests and Xcode Cloud tests; resolve failures before tagging the next beta. Keep CI checks independent of personal accounts and local Keychain contents.

Builds and targeted tests have passed for individual changes; this is not yet a completed release-validation checklist. Manual confirmation is still needed for the flows above.

## v1.2 — Everyday Tools

- ~~Local password manager~~
- Passkeys & Keychain Integration
  - ✅ Native website passkey sign-in through WebKit / Apple Passwords (confirmed on GitHub)
  - ✅ Keychain-backed storage for Origami-owned AI API keys
  - Validate passkey registration, multiple credentials, conditional mediation, cancellation and security keys across supported sites
  - Manual Apple Passwords / Password Providers filling — investigate the public AppKit native-field AutoFill path; a complete browser fill flow is not yet demonstrated and production filling remains disabled
  - Website password save/update — blocked by the native macOS API limitations in the inspected SDK; separate from manual filling
  - Verify native verification-code / TOTP AutoFill; preserve standard one-time-code fields without collecting codes or secrets
- Translate
- ~~Dictionary~~
- Page Simplifier
- Task Widget
- Network / Connection tools
  - Public IP information
  - DNS lookup
  - ✅ Certificate information
  - Site network information
  - Connection diagnostics
- ~~Quick Weather~~

Password integration is not complete merely because passkeys work. The AuthenticationServices password-request probe returned error 1004; `performAutoFillAssistedRequests()` and `ASCredentialDataManager.save(...)` are unavailable on native macOS in the inspected Xcode 26.5 SDK. A separate public AppKit path (`NSTextField` / `NSSecureTextField` with `contentType`) did show a system Passwords popup, but the user reported password-only filling and a disabled Apple Passwords menu. This is partial evidence, not a working browser integration and not proof that all public paths are impossible. Automatic website matching remains unsupported by the investigated request APIs; explicit manual selection would be acceptable if verified.

The standalone password probes were removed at the user's request; the production password fallback remains disabled and working passkeys are unchanged. Native verification-code / TOTP suggestions still need verification. New delivered-code APIs require macOS 27 and are not in the installed SDK. See [the authentication investigation](docs/password-autofill.md). Do not add a custom vault or private-API workaround.

Suggested implementation order: finish v1.1.1 release validation, then build the remaining Network / Connection tools, Translate, Page Simplifier, and the simple Task Widget. Keep password-provider investigation separate from these deliverable features; do not promise full Apple Passwords integration until the system picker and safe form filling work end-to-end.

The Task Widget should remain intentionally simple: a daily task list, free-form notes, a small monthly calendar, and the ability to add the current webpage as a task. It is not intended to become a project-management system.

## v1.3 — Contextual Intelligence

- Ask This Page
- Select Text and Ask
- Persistent AI conversation while browsing
- Context-aware AI panel

Ask the Web remains the research-oriented mode, while these features should focus on the page or content the user is currently viewing.

For vertical-tab layouts, the AI conversation can appear alongside the webpage. For horizontal layouts, explore an appropriate side panel or floating/pinnable presentation.

## v1.4 — Extensions

- Extension compatibility
- Permission handling
- Extension management
- Define a realistic supported API / manifest scope before claiming broad compatibility
- Evaluate Apple Passwords / third-party credential extension compatibility only through documented, supported integration; an extension host alone does not establish compatibility

Treat extensions as a major engineering area rather than a small feature.

## Principles

- Native to macOS
- WebKit-first
- AI-native, never AI-required
- Useful without an account
- Privacy-conscious and local-first where practical
- Open source
- Avoid adding complexity when a simpler browser-native solution works better

## Possible Areas to Explore

These are exploratory ideas, not committed features, and are not assigned to a specific release version.

- Visual Search
- Visual Match
- Voice input
- Discuss with the Web
- Real-time voice conversations grounded in the current webpage or selected content
