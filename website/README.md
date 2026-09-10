# Origami website

A static HTML/CSS/JavaScript site. No framework, package install, build step, third-party scripts, or remote fonts.

Preview from the repository root:

```sh
python3 -m http.server 8765 --directory website
```

Publish the contents of `website/` with any static host. Relative asset and page links support deployment in a subdirectory.

## Release configuration

`release.json` is the sole source of `version`, `channel` (`beta` or `stable`), and `downloadURL`. `download.js` fetches it once and wires both Download for Mac buttons directly to the published GitHub ZIP asset. All-null metadata keeps the buttons disabled; unavailable/invalid metadata also fails closed. JavaScript is required to enable downloads.

The release pipeline updates this file on the repository default branch **after** publishing the GitHub Release and appcast. Before Stable, the newest public Beta is selected; once Stable exists, the newest Stable stays the default. The website-only **Update Website Download** workflow safely retries this final step without rebuilding or republishing assets. See `../docs/releasing.md` for permissions and recovery. Commit the website and integration on the default branch before releasing.

No hosting connection or deployment workflow is configured. Updating this repository file does not publish the website to a host. There is no framework build step; validate with `node --check website/download.js`, `node --check website/main.js`, and `node --test website/tests/download.test.cjs`.

Set `siteURL` to the final public URL with a trailing slash. Also set the canonical URL, `og:url`, and an absolute `og:image` URL directly in `index.html` when publishing: social crawlers may not execute JavaScript. No production hostname is assumed.

## Editing

- `index.html`: copy, six video mappings, feature grid, footer.
- `styles.css`: responsive layout and tokens, with the reference site's token vocabulary and Origami's actual `#55D4B3` accent.
- `swift-native.css`: the existing Hibiscus native Swift bar CSS, retaining its original Swift orange palette. Its HTML and official Swift asset were reused, not replaced. Additional narrow-screen/touch rules preserve the interaction; keyboard focus also reveals the benefits.
- `main.js`: scroll-stack playback selection, one active autoplay video, covered/offscreen/background pausing, reduced-motion and data-saver handling.
- `privacy/`, `terms/`, `license/`, `notices/`: local information pages grounded in the current README, package resolution, and bundled notices. Reconcile these with changes to the app or hosting configuration before publishing.

## Video map

| Section | Local file |
| --- | --- |
| Ask the Web | `assets/videos/ask-the-web.mp4` |
| Peek + Split View | `assets/videos/peek-split-view.mp4` |
| Tabs | `assets/videos/2-tab-modes.mp4` |
| Reader | `assets/videos/reader-mode.mp4` |
| JSON Reader | `assets/videos/json.mp4` |
| RSS Reader | `assets/videos/rss.mp4` |

Videos were re-encoded from the supplied marketing resources to H.264, CRF 23, yuv420p, fast-start MP4 with no audio, retaining 1920×1080 and original duration. Total video size is about 17.9 MB versus 163.1 MB for the originals. Poster JPEGs are extracted from the real demos. No footage is cropped, sped up, or cut by this website.

The six main features form a native CSS sticky scroll stack with ordinary document scrolling. Panels too tall for the viewport remain in normal flow. Reduced motion and short viewports use a static layout.

Videos are noninteractive, muted, inline, looping demos, with no controls or full-size links. Only the active panel receives a video source; posters are loaded near the viewport. Covered panels pause. Reduced motion and data saver show real poster frames instead of autoplay. If autoplay is denied, the poster remains. With JavaScript disabled, real posters remain available. No small headings appear above section titles.

The covered source is MPL-2.0. The app icon and marketing videos remain branding/marketing assets, subject to the repository's branding terms.

## Verification (2026-09-10)

- All local HTML links and assets resolved; all four information pages and six MP4s returned HTTP 200.
- Desktop (1280 px), mobile (390 px), and tablet (820 px) compositions were inspected in the in-app browser. Native Swift bar keyboard focus reveals all three benefits.
- The original media controller was verified before the scroll-stack revision; see the revision checks below for current behavior. Reduced motion was tested at the controller level and checked in CSS; physical-device/OS preference testing was not performed.
- Video streams retain 1920×1080, have no audio, and use H.264. Current package/bundled notice contents were checked against the website.
- The GitHub CTA matches `git remote`, but its public unauthenticated URL returned HTTP 404. Resolve repository visibility before public launch. The ownership link returned HTTP 200.
- No deployment or release publication was performed.


## Scroll-stack revision

Removed all section eyebrow headings, native video controls, and full-size video links. The six chapters now overlap using native sticky positioning; desktop and 390px mobile stack layouts were visually checked. Swift retains its orange bar; the site retains mint. Static/controller checks cover the six noninteractive videos, active-panel selection, background pause, and reduced-motion poster fallback.

## Motion and link details

Links use color-only hover feedback. GitHub links include an inline, current-color GitHub SVG. “AI era.” shares the italic serif style of “open-source”; the introduction includes a small app icon before Origami.

Lightweight, one-shot opacity/vertical entrance animations cover the hero, introduction, feature content, smaller feature grid, native section, final CTA, and footer. These use the built-in Web Animations API and IntersectionObserver, never hide content in the base CSS, and cancel immediately when reduced motion is enabled. Sticky chapter containers are not transformed. No animation dependency is added.

Privacy and Terms use an independently built Origami document layout in `policies.css`, with section navigation and a responsive reading column. The Hibiscus policies inform topic coverage only. Privacy covers local browser data, retention, private browsing, optional provider requests, updates, and website hosting. Terms preserve MPL rights and cover branding, third parties, availability, and the reference's warranty/liability clauses. Contact links follow Origami's repository reporting route. No Hibiscus-specific photo, App Store, or TestFlight provisions are carried over.

The six scroll cards now share one centered heading/subtitle/video composition and compact dimensions (960×665 at a 1280×900 viewport; 358×485 at 390×844). Disclosure space is reserved consistently. GitHub marks appear only in the main CTA buttons, not the header or footer.

The twelve fundamentals use consistent mint outline SVG icons. The grid retains the page entrance animations; individual icons are static. Readability appears last in the technology list; full attribution remains in Third-Party Notices. Video edges remain borderless, and the shared wider scroll-card layout is unchanged.


## Open source and privacy field

The section after Built for Mac uses readable, centered HTML above a decorative ASCII field on the shared page background. The field uses full-opacity characters with a frosted treatment: 0.65–1px canvas blur and a translucent neutral layer, without opacity fades. Foreground text stays sharp. On entry, its pronounced rounded edges open smoothly to the full viewport as the frost settles; on exit, they gently close and soften again. The text shifts slightly with those transitions. These effects reverse with scrolling and are disabled for reduced motion. The final CTA uses content-driven height, 72–112px vertical padding, and no extra top margin or entrance fade. ASCII messages use dark ink without an outline. Only one message is visible at a time, selected by progress through a 340svh section with a sticky viewport stage. Scrolling backwards restores earlier messages; standing still never advances the text. Transitions take 180ms. Reduced motion removes the sticky sequence and shows all text immediately. No icon or buttons are present. The exact glyph vocabulary is `@ # $ % * + = - : .`.

Glyphs are cached at native device resolution on a fixed pixel-aligned grid. Smooth, seeded density patches drift through varied characters without repeating bands; there are no text cutouts or enlarged bitmaps. Animation pauses offscreen and in background tabs, with a static field for reduced motion and data saver. Desktop/mobile playback is about 12/10 fps. Validate with `node --test website/tests/*.test.cjs`.


## Informational version label

`latest-version.js` lazily reads GitHub's public repository tags when the final CTA approaches the viewport. It validates stable and beta Origami tags and compares their numeric semantic versions, including beta numbers and stable precedence at the same core version. A higher-core beta may be the newest informational tag while the download remains Stable. The label is a tag only, not a claim that an asset was released.

Requests use no authentication, omit credentials, and have an eight-second total timeout and ten-page limit. Failures, no valid tags, or incomplete pagination quietly leave the reserved label area empty. No download URL is constructed or changed. The final CTA headline uses the shared serif font; its small version label uses the normal sans-serif.
