# Browser migration

Welcome includes a dedicated import step. The same flow is available directly below Welcome in General Settings. Origami discovers installed browsers and their standard data locations, shows their names and icons, and reads profiles after you choose a browser. No folder or file selection is needed in the normal flow. Quit the source browser when prompted so the import reflects its latest data.

If macOS denies access, Allow Access opens a native permission picker already positioned at that browser’s data folder. Origami cannot bypass macOS privacy protection. Nonstandard/custom data locations are not automatically searched. During onboarding, importing stays in the setup flow; the imported profile opens after Start Browsing.

Imports create a separate, isolated Origami profile by default. Review the source profile, available categories and counts before confirming. Repeat for another source profile to preserve its boundaries. Search engine import is optional and changes the global preference.

In Settings, More options & details contains replacement as an explicit alternative with an overwrite warning and confirmation. Selected, available bookmarks, history and tabs replace those categories in the current profile. Unavailable or unchecked categories are preserved. Replacement is blocked for shared bookmark/history destinations or profiles open in another window. Destination database writes are transactional; source files are never changed intentionally. Back up existing data before replacement.

## Supported data and limits

- Discovery covers Safari, Google Chrome, Arc, Firefox, Brave, Microsoft Edge, Zen, Vivaldi, Opera and Orion at standard locations. Only detected browsers appear.
- Chromium-family profile folders: standard Bookmarks JSON, History SQLite and recognized search preferences from Preferences. Unencrypted SNSS v1/v3 sessions can provide current and pinned tabs. Encrypted or unsupported sessions are left unavailable; browser keys are never requested. Proprietary tab groups, Arc spaces/sidebar favorites and Vivaldi workspaces are not inferred.
- Firefox and Zen: places.sqlite bookmarks/history and JSON or Mozilla LZ4 session snapshots. Current entries, pinned tabs and named standard session groups are mapped into Origami. Private windows are excluded. Zen workspace/container identities are not transferred.
- Safari and compatible Orion exports: Bookmarks.plist or bookmarks HTML, plus Safari-shaped History.db where accessible. Other Orion schemas, native Safari/Orion sessions and their search preferences are not supported. Unavailable formats remain clearly identified; discovery does not add support for proprietary formats.

Only HTTP(S) destinations are imported. No passwords, cookies, authenticated sessions, extensions or download records/files are migrated. Restored tabs are sleeping until opened; they do not restore login state. Six tabs can remain pinned per Origami window. Additional pins become regular tabs. Multiple source windows are consolidated into one destination window.

Bounded reads reject oversized or malformed data. The review identifies unavailable categories instead of treating a failed read as an empty category. No imported contents or source paths are logged.

## Credential compatibility

Origami retains WebKit's credential fields and Web Authentication APIs; it does not implement a password manager or import Keychain data. Apple's [passkey browser guidance](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers) describes WebKit's handling of Web Authentication challenges. API availability alone does not establish that a signed build has every required capability or that a user's system provider is configured.

Automated tests use synthetic pages and temporary databases. They check credential attributes, page focus/events, Web Authentication API preservation, editable-field exclusions, parser limits, profile isolation and transaction rollback. They require no accounts or developer source checkout at runtime.

Before claiming end-to-end Apple Passwords support, test the signed app on a configured Mac:

1. Existing login: username/current-password suggestions, keyboard navigation, fill and submit.
2. Signup: email/new-password fields, strong-password suggestion and save confirmation.
3. Two-factor login: one-time-code suggestions and normal typing/paste.
4. Passkey registration, authentication, conditional UI and cancellation on a compatible HTTPS test site.
5. Repeat in an imported isolated profile and a private window. Verify native dialogs remain visible and cancellation leaves the page usable.

These provider/account-dependent checks are manual, not simulated by CI. Do not record credential values in test logs or bug reports.
