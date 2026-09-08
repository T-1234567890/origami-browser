# Releasing Origami

Origami uses Sparkle 2.9.6 for direct macOS updates. Xcode Cloud owns Developer ID signing and notarization; GitHub Actions owns orchestration, ZIP packaging, Sparkle signing, and distribution. No Apple signing certificate is imported into GitHub.

## Version contract

Stable tags use `vMAJOR.MINOR.PATCH`. Beta tags use `vMAJOR.MINOR.PATCH-beta.N`, where `N` is a positive integer. Version components are nonnegative integers without leading zeroes. Zero beta numbers, metadata suffixes, whitespace, and other release stages are rejected.

Marketing versions remain `MAJOR.MINOR.PATCH`; beta identity is stored separately. The app displays `Origami MAJOR.MINOR.PATCH` with `Beta N` appended for beta builds. The full numeric marketing version is always displayed.

`Origami/Updates/ReleaseIdentity.swift` is the single parser. The app uses it to validate bundle metadata; `scripts/release/VersionTool.swift` compiles with that same source for automation. No second tag parser exists in the workflows.

The Xcode Cloud `CI_BUILD_NUMBER` becomes integer `CFBundleVersion`. It increases across marketing versions; never reset the Cloud product's build counter. Publication rejects a number at or below **any** existing appcast build. It also rejects backwards release identity transitions, including publishing a lower marketing version after a higher-version beta. This initial single-feed pipeline does not support maintenance backports across parallel version tracks. If Cloud is recreated, set its next build number above the highest published build before releasing.

`ci_scripts/ci_post_clone.sh` validates `CI_TAG` and generates ignored `Configuration/Release.generated.xcconfig` before compilation. Marketing version remains numeric. Separate Info.plist keys hold the release tag, stage and prerelease number. Signed metadata is checked again against the tag and Cloud build number after downloading. Unconfigured local builds show a development version in **General → About** and have updates disabled.

## Sparkle and channels

The native `SPUStandardUpdaterController` is shared by the app menu's **Check for Updates…** and **Settings → General → Updates**. Sparkle owns checking, downloading, installation and its UI. Automatic checks default on in configured builds; Sparkle persists that setting. System profiling and automatic installation are disabled by default.

Stable accepts only the unmarked default channel. Beta accepts default plus `beta`. Changing preferences does not change the installed build identity or install an older build. Sparkle compares monotonically increasing build numbers. The channel preference is separately persisted as `updates.channel`.

The app contains `SUFeedURL` and `SUPublicEDKey`, never the private key. Invalid/missing configuration disables the updater. A sandboxed build enables Sparkle's installer XPC service and its two documented, bundle-specific Mach lookup exceptions; existing outgoing-network permission makes the downloader service unnecessary. Xcode Cloud's archive/export flow must re-sign Sparkle and its nested helpers for distribution.

## Manual configuration checklist

No credentials have been created, no workflow has been started, and no release has been published by adding this infrastructure.

1. **Apple/Xcode Cloud setup:** connect this repository and Origami's app/product in Xcode Cloud. Create an enabled workflow named **Release**, using the shared **Origami** scheme, current compatible Xcode (26.5 or later), macOS, an **Archive** action with **Release** configuration and direct **Developer ID** distribution, and a **Notarize** post-action. Enable manual builds of tags. Keep tag-change automatic starts off to avoid duplicating the build started by GitHub. Configure cloud-managed signing for the existing bundle identifier and team, and grant the needed Apple account permissions/agreements. The exported artifact must be `STAPLED_NOTARIZED_ARCHIVE`; an unsigned archive, App Store export or ordinary build product is deliberately rejected.
2. **App Store Connect Team API key:** supply a Team API key whose role can read the selected workflow/artifacts and start builds. Put its key ID, issuer ID and complete PEM private key in the three GitHub secrets below. No personal API key, Apple password, certificate P12 or certificate password is used.
3. **Sparkle keys:** using the official matching Sparkle distribution, create/export your Ed25519 key on your own secured machine. Put the exported private key contents in the GitHub secret below. Keep an offline backup. Put the public key in both GitHub and the Xcode Cloud workflow environment as described below. The supplied public key is recorded in `Configuration/Updates.xcconfig`; use that same value for `SPARKLE_PUBLIC_ED_KEY` in GitHub and Xcode Cloud. No private signing key is stored in the repository.
4. **GitHub repository variables:** supply the workflow ID, expected Apple team/bundle identifiers and public update configuration below. GitHub Actions must be enabled and repository rules must permit the workflow to create releases and write the dedicated `appcast` branch. No external hosting account is needed.
5. **Xcode Cloud environment:** set `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` to the exact same public values as GitHub. They are public configuration, not secrets. Cloud supplies its own `CI_TAG`, `CI_BUILD_NUMBER` and repository path. Do not put the Sparkle private key or ASC API key in the build environment.
6. **First real release test:** after reviewing and committing this code, exercise a beta release with actual credentials. Confirm the returned app's signature/ticket, helper installation, update UI, both channels and a later stable transition on actual Macs. Public end-to-end delivery requires the repository/feed/assets to be publicly accessible. Do not change visibility solely to run mocked tests.

### GitHub secrets

| Name | Value |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | Team API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Team issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Complete `.p8` PEM contents |
| `SPARKLE_ED_PRIVATE_KEY` | Private key text exported by Sparkle's supported tooling |

`GITHUB_TOKEN` is GitHub's built-in, job-scoped token. Do not create another token for this pipeline. No `MACOS_CERTIFICATE_P12` or `MACOS_CERTIFICATE_PASSWORD` is required.

### GitHub repository variables

| Name | Purpose |
| --- | --- |
| `XCODE_CLOUD_WORKFLOW_ID` | Existing enabled Release workflow ID; repository/tag references are resolved through it |
| `APPLE_TEAM_ID` | Expected Developer ID team, verified in the returned signature |
| `BUNDLE_IDENTIFIER` | Expected application bundle ID, matching the Xcode target |
| `SPARKLE_PUBLIC_ED_KEY` | Base64 Sparkle public Ed25519 key |
| `SPARKLE_FEED_URL` | `https://raw.githubusercontent.com/T-1234567890/origami-browser/appcast/appcast.xml` for the canonical repository |

No additional app/product ID is needed: the API resolves the workflow's associated repository. For forks, the feed URL must use that workflow repository's owner/name. The URL is deterministic but is deliberately not embedded as production configuration until the maintainer supplies it. This implementation publishes only to that GitHub branch location.

For local updater testing, optionally create ignored `Configuration/LocalUpdates.xcconfig`. Use `ORIGAMI_PUBLIC_ED_KEY` and `ORIGAMI_FEED_URL`; spell the latter's HTTPS prefix `https:/$()/` to avoid xcconfig's `//` comment syntax. Do not put any private credential in an xcconfig.

## Workflow and artifact flow

`release.yml` runs on `v*` tags, then validates the exact contract before accessing release secrets or starting Cloud. `release-checks.yml` runs mocked tests on pull requests or manual dispatch without release credentials. The release and recovery workflows share one non-cancelling concurrency group. GitHub may replace older **pending** runs in a concurrency group; push one release tag at a time and finish/recover it before pushing another.

The release job:

1. Validates all configuration and existing appcast ordering.
2. Creates a short-lived ES256 Team API JWT, resolves the exact tag, starts one clean Cloud build, then polls for up to two hours. Ambiguous POST failures are not automatically retried. The finished commit SHA must match the Git tag.
3. Requires exactly one stapled notarized archive from a successful archive action and downloads it using its temporary URL. Credentials are never forwarded to artifact storage.
4. Rejects unsafe archive paths/symlinks and unreasonable sizes. Verifies the app's bundle identity, updater configuration, build number, Developer ID certificate/team, Gatekeeper assessment and stapled notarization ticket. Debuggable distribution builds are rejected.
5. Packages `Origami-<version-and-stage>.zip` with `ditto`, preserving symlinks and signing metadata. The app bundle is never changed after signing. A second extraction verifies packaging did not invalidate the app.
6. Downloads checksum-pinned official Sparkle tooling. `generate_appcast` signs via stdin, checks the key against the app's public key, retains old entries, disables deltas and assigns `beta` only to prereleases. The resulting signature, enclosure URL, length, channel and minimum OS are validated. No key appears in a command argument, repository file or printed tool output.
7. Creates a draft release with commit-generated notes. Uploads ZIP, `SHA256SUMS.txt`, recovery `appcast.xml`, and non-sensitive `release.json` (identity/commit/Cloud run ID). Only then publishes the normal release or prerelease with its display title.
8. Publishes `appcast.xml` to the dedicated `appcast` branch using the Git data API. It is a feed-only branch. Existing feed heads are checked, and writes cannot force-push. Release assets always use exact tag URLs; the updater never uses `/releases/latest/download/appcast.xml`.

The only write permission is `contents: write` on release/recovery jobs. Checkout actions are commit-pinned. ASC temporary key files are owner-only and removed with their temporary directory; Sparkle keys use stdin. Tool diagnostics are captured rather than exposing response bodies, temporary download URLs or secrets. Runner-local artifacts and caches disappear with the ephemeral hosted runner. No secret, build archive or raw API dump is a repository output.

## Release procedure and failure recovery

Run the regular app tests/build and `python3 -m unittest discover -s scripts/release/tests -v`. Review the changes and release identity. Create and push one supported tag only when intentionally ready to release; this document does not execute that action.

Authentication, Cloud failure/timeout, artifact verification and Sparkle failure abort before publishing anything. Upload failure leaves a draft, which no updater consumes. Inspect the failed run and remove **only its incomplete draft** before re-running that tag's failed release job; this starts a fresh Cloud build with a higher build number. Never move a published tag or replace a published binary. A timed-out or ambiguous Cloud start may still be running: inspect/cancel it in Cloud before restarting.

If release publication succeeded but the appcast write failed, run **Recover Published Appcast** with the published tag. It downloads the existing binary/metadata, verifies the checksum and signed app, regenerates the feed with Sparkle, and publishes it without a new Cloud build or replacing binary assets. It refuses backwards/conflicting updates. Do not run a newer release first. If the feed already contains the build, there is nothing to recover; confirm its exact asset URL rather than rerunning a release.

A private repository supports script tests and private pipeline exercises with repository permissions. Ordinary Origami installations cannot anonymously download private assets or this private raw feed. No GitHub authentication is embedded in the app. Even after visibility changes, verify the raw feed and exact ZIP URLs from an unauthenticated client before announcing public updates.

## Key rotation and limitations

Retain the Sparkle private key securely: losing it can prevent installed clients accepting future updates. Follow Sparkle's documented transition procedure before changing the embedded public key; replacing both secrets at once is not a migration. Keep the old key for any necessary transition releases. Rotate ASC keys independently, update the three secrets together, and revoke old keys after a controlled test. Apple certificate/team changes likewise require testing the upgrade path; do not disable signature verification to bypass failures.

No real Apple/GitHub/Sparkle release is exercised by the automated fixture tests. Account permissions, Cloud-managed signing, notarization artifact shape, Gatekeeper network assessment and installation still require the first real release. ZIP is the primary artifact; DMG, deltas, parallel maintenance feeds, and an authenticated private-repository updater are intentionally absent.

References: [Sparkle sandbox integration](https://sparkle-project.org/documentation/sandboxing/), [Sparkle publishing](https://sparkle-project.org/documentation/publishing/), [Xcode Cloud build numbers](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds/), [App Store Connect build runs](https://developer.apple.com/documentation/appstoreconnectapi/build-runs).

### Release diagnostics

Before starting Xcode Cloud, the runner reports the requested tag and commit, workflow enabled state, repository, and resolved tag reference. It checks manual tag conditions when the API exposes them. Apple JSON:API failures report only bounded, sanitized status, code, title, detail, and source pointer fields; non-JSON bodies are omitted. A rejected or ambiguous build-start POST is never automatically retried. Inspect the reported condition and the Cloud workflow before rerunning.

GitHub generates release notes from repository history. Job summaries use the full marketing version and report success only after binary publication and the final appcast update. A startup failure instead identifies the App Store Connect stage and safe Apple diagnostics. The tests status in a successful summary reflects the configured Xcode Cloud workflow, which must run its tests before succeeding.
