# Localization guide

This guide standardizes the contribution process described in [issue #1: Add more language localizations to Origami](https://github.com/T-1234567890/origami-browser/issues/1). Use that issue to coordinate languages and ask about ambiguous strings; use this document for the repository workflow.

## Current scope

English (`en`) is the source language. Simplified Chinese (`zh-Hans`) is the only additional language currently enabled. Issue #1 lists other planned languages; that list is not a claim that they are implemented or ready to ship. This guide does not enable additional languages.

The older infrastructure discussion in issue #1 predates the current String Catalog and language manager. Check the current checkout before starting work, and coordinate a new language in the issue before changing the supported-language set. Keep each language in a separate pull request where possible.

## Files and responsibilities

| File | Purpose |
| --- | --- |
| `Origami/Localization/Localizable.xcstrings` | Source strings, English and Simplified Chinese translations, translator comments, and catalog variations. |
| `Origami/Localization/LanguageManager.swift` | Stable language identifiers, language resolution, saved selection, `L10n` lookups, and the `LiveLanguage` view modifier. |
| `Origami/Views/Internal/NativeSettings.swift` | Language picker and confirmation before applying a selection. |
| `Origami.xcodeproj/project.pbxproj` | Xcode development language and known regions. |
| `scripts/check_localizations.py` | Catalog completeness, formatting-token checks, and a limited scan for missing literal `L10n` keys. |
| `OrigamiTests/LocalizationTests.swift` | Supported-language resolution, live locale observation, persistence, bundled translations, and fallback checks. |

## Contribution workflow

### 1. Agree on scope and gather context

Choose a language you know well and comment on issue #1 to coordinate work. For a correction to an existing translation, describe the affected screen and why the current wording is wrong.

Find each string's use in the app before translating it. Record its screen, control type, purpose, nearby labels, available space, and any placeholders. For an ambiguous source string, ask in the issue or PR rather than guessing. Add a useful translator comment in the String Catalog when context is not obvious.

Keep English source keys unchanged unless there is a clear source-text problem. Explain necessary source changes separately so reviewers can identify their effect on every translation.

### 2. Edit the String Catalog

Open `Origami/Localization/Localizable.xcstrings` in Xcode and edit the translation for the intended locale. Do not hard-code translated text in Swift or create a parallel translation dictionary.

- Use natural, concise wording suitable for a native macOS browser.
- Preserve formatting argument types, argument positions, literal percent signs, and meaningful line breaks. For example, `%@` and `%lld` represent different kinds of values and are not interchangeable.
- If grammar requires argument reordering, use positional placeholders consistently and verify them with the validator and runtime formatting.
- Use String Catalog plural variations where wording depends on a count; do not assume English plural rules apply to every language. Review all required variants, including zero and larger counts where relevant.
- Mark entries translated only after reviewing them. A populated field alone does not establish translation quality.
- Review the diff after building: Xcode may extract strings or mark entries stale. Do not silently remove entries used through dynamic lookup.

### 3. Preserve terminology and data boundaries

Normally leave these names unchanged: **Origami, WebKit, Peek, Ask the Web, GitHub, Swift, SwiftUI**.

Use familiar localized Safari/macOS or mainstream browser terminology for Bookmarks, History, Downloads, Profiles, Private Browsing, Reader Mode, Split View, Content Blocking, Ad Blocking, Settings, and Permissions. Keep the same term across menus, buttons, help text, accessibility labels, and error messages. Keep Content Blocking and Ad Blocking distinct.

Translate display text, not persisted enum values, preference keys, internal URLs, API/schema identifiers, CSS/JavaScript identifiers, or protocol values. Do not translate website content, AI-generated answers, user-created names, browsing data, or authoritative third-party license text through the app catalog.

### 4. Review AI-assisted translations

Issue #1 welcomes context-aware AI assistance, but requires manual review before submission. Do not submit unchecked machine translation. Give the translation tool the feature context and formatting constraints, for example:

> Translate these Origami macOS browser interface strings from English to Simplified Chinese. For each string, use the supplied screen, control type, surrounding text, and translator comment. Preserve placeholders and product names exactly. Use concise native macOS terminology. Flag ambiguity instead of guessing. Return only the requested translation entries for review.

Provide app-owned strings and synthetic examples only. Do not send credentials, private URLs, user names, browsing history, or other personal data as translation context. Review wording, grammar, terminology, button/menu phrasing, and the actual interface after using AI.

### 5. Handle missing localization narrowly

Literal SwiftUI labels use the catalog through the view's locale:

```swift
Text("Settings")
Button("Cancel") { dismiss() }
```

Dynamic app-owned labels and AppKit text use `L10n`:

```swift
Text(L10n.string(category.rawValue))
let message = L10n.format("Bookmarks (%lld)", Int64(count))
```

Ensure every possible dynamic key exists in the catalog. Xcode does not extract arbitrary runtime values, and the validation script's source scan cannot enumerate them all. Keep user-supplied titles verbatim instead of treating them as localization keys.

Make only the smallest code change needed to expose missing user-facing text. Do not change unrelated logic or redesign the UI as part of a translation PR. Avoid caching translated strings in static constants: new lookups must reflect the current language. Use `L10n.locale` for app-owned locale-sensitive formatting, but keep identifiers and machine-readable values locale-independent.

## Language selection and live updates

Choose **Settings → General → App Language**. The picker stages a selection and asks for confirmation. Confirm applies it immediately; Cancel changes neither the current language nor the saved preference.

The selection is global, not profile-specific. `LanguageManager` persists `app.language`; System Default resolves the system's preferred supported language and falls back to English. Explicit selections use their stable identifiers, not translated display names.

`LiveLanguage` supplies the observable locale to browser window roots and separately hosted SwiftUI panels. App-owned command labels and dynamic text use live `L10n` lookups. Do not use a language-dependent `.id` on the browser root or recreate stores, tabs, or web views to refresh translations. Switching languages must preserve browsing and playback state.

The manager also saves Apple's per-app `AppleLanguages` override for the next launch. System-owned macOS UI and already-materialized message text may retain their existing language; the immediate-update guarantee applies to Origami's live-localized interface. Report stale app-owned text as a bug rather than adding a blanket restart requirement.

## Validation and UI review

From the repository root, run:

```sh
python3 scripts/check_localizations.py

xcodebuild -project Origami.xcodeproj -scheme Origami \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  -only-testing:OrigamiTests/LocalizationTests test

git diff --check
```

See [CONTRIBUTING.md](../CONTRIBUTING.md#build-and-test) for the full build/test workflow. Keep generated build products and test results out of the PR.

The script currently requires exactly `en` and `zh-Hans`, checks translated states and formatting-token parity, rejects unexpected bidirectional control characters, and checks simple literal `L10n` calls. It does **not** prove linguistic quality, complete dynamic-key coverage, correct plural semantics, or visual correctness. A passing build is not a substitute for UI review.

Run a fresh build in both supported languages and review the surfaces required by issue #1:

| Area | Minimum review |
| --- | --- |
| Toolbar and menus | Address/search hints, commands, tooltips, and shortcut labels. |
| Settings and About | Section labels, controls, notices, links, and separately hosted panels. |
| Onboarding and migration | Instructions, choices, progress, empty states, and warnings. |
| Profiles, history, bookmarks, downloads | Labels, counts, actions, and unchanged user-created names. |
| Privacy and security | Permissions, blocking controls, connection warnings, and error text. |
| Reader Mode and Peek | Controls, metadata, accessibility labels, and compact layouts. |

Check clipping, truncated buttons, alignment, overly wide controls, awkward wrapping, and untranslated app-owned text at normal and narrow window widths. Check light/dark appearance where contrast affects readability. Mention larger layout problems in the PR or a separate issue instead of expanding translation scope.

Also verify language switching: cancel a change, confirm it, switch back, and choose System Default. Check other open windows and panels, app-owned menus, and persistence after relaunch. Confirm tabs, form input, playback, and profile data survive unchanged. Use synthetic data; do not include private content in review screenshots.

Tests must run in Xcode Cloud's test-without-building environment: use bundled resources, isolated defaults, and synthetic data. Do not depend on the runtime source checkout, developer-local paths, credentials, accounts, or machine-specific state.

## Enabling a future language

A new language requires a coordinated implementation PR, not just an extra catalog column. After agreeing on scope in issue #1:

1. Add its stable identifier and native display name to `AppLanguage`.
2. Extend system-language resolution for the intended script/region variants without silently mapping distinct languages or scripts together.
3. Add the Xcode localization/known region and complete the catalog entries and necessary plural variations.
4. Update the validator's exact supported-language set and its status output, plus language-resolution and bundled-resource tests.
5. Review live switching, fallback behavior, and the actual interface; update this guide's current-scope section.

Do not enable incomplete locales or describe planned languages as shipped. English remains the fallback for missing keys; fallback is not a reason to submit incomplete translations.

## Pull request checklist

Include the language, related issue, affected screens, translation method, review method, verification results, and known gaps in the PR description.

- [ ] One language per PR where practical; unrelated code and formatting changes excluded.
- [ ] Natural wording reviewed by someone familiar with the language, or carefully manually reviewed after contextual AI assistance.
- [ ] Product names, terminology, placeholders, and plural behavior checked.
- [ ] Catalog validator and build/tests completed; failures or unrun checks stated explicitly.
- [ ] Main UI and confirmation/live-switching behavior checked in the target language.
- [ ] Screenshots/logs contain no private data; user content and persisted identifiers remain unchanged.

Source: [issue #1](https://github.com/T-1234567890/origami-browser/issues/1), including its contribution, terminology, implementation, UI-review, and submission guidance. Keep the issue and this guide aligned when the supported-language policy changes.
