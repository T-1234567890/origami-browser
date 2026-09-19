# Web Highlighter

Web Highlighter is a local browsing tool, not an annotation workspace. There are no notes, AI calls, accounts, network requests, or sync.

## Interaction

Show the **Highlighter** panel from Quick Tools or Settings → General. The compact glass capsule stays at the bottom of the webpage. Its marker and eraser buttons are mutually exclusive; click the active tool again to turn it off without hiding the panel. Turning Highlighter off in Quick Tools hides both the panel and saved highlights without deleting them. Choose yellow, mint, or lavender, then select ordinary page text to highlight it. With the eraser enabled, click a saved highlight or select its text to remove it. Selections intersecting multiple saved highlights are ignored rather than making an ambiguous edit.

The panel stays visible while scrolling or changing selections. Saved highlights remain visible when only the marker/eraser tool is off. Disabling Highlighter itself hides them; enabling it restores them when a confident match exists. The default color is configurable. Private highlights stay in that window's in-memory database and are cleared when it closes.

## Architecture

- `HighlightRecord` and `HighlightAnchor` are versioned Codable values, independent of the UI.
- `HighlightStore` uses GRDB and migration `v16_web_highlights`, scoped by profile and URL. Profile deletion cascades to highlights.
- `HighlightManager` owns the store, mode, default style, and revision shared by that service context.
- `WebHighlighterController` owns each webpage's isolated-world bridge, navigation identity, selection state, and native save/update/remove actions.
- `HighlightScript` extracts selections, resolves anchors, observes page changes, and renders ranges using WebKit's public CSS Custom Highlights API.
- `WebHighlighterToolbar` is a SwiftUI overlay on the existing webpage view. `WebHighlighterSettings` provides General settings. No extra window or notes sidebar is created.

The controller is installed only on normal browser `TabPage` WebViews with browser services. Peek, internal pages, and Reader do not receive active highlight controls. Generated Visual WebViews are separate and receive no highlighter bridge.

## Local format

Each record contains an ID, schema version, exact page URL, bounded page title, normalized selected text, up to 64 UTF-16 units of prefix and suffix context, start/end child-node paths, node offsets, a document position hint, style, and creation date. The database stores profile ID, URL, and creation time in indexed columns and the record as a Codable payload.

Queries and fragments are retained to distinguish search results and SPA routes. Embedded URL credentials and non-HTTP(S) schemes are rejected. Highlights can contain sensitive webpage text: they remain in the existing protected local database and are never logged or sent anywhere. Private contexts use their existing separate in-memory database.

## Anchoring and restoration

The JavaScript restorer builds a bounded text index of eligible visible text. It normalizes whitespace while preserving a mapping to original DOM offsets.

1. Find exact quote candidates and rank them using prefix/suffix agreement.
2. Verify the saved DOM paths/range against the quote and context-selected candidate; use this direct range when it remains correct.
3. If the DOM changed, reconstruct the range from the text index.
4. Duplicate quotes require strong surrounding-context agreement and a clear margin over the next candidate. Short quotes also require strong context. Position alone never resolves ambiguity.
5. If the exact quote disappeared, allow only a small contiguous edit within unique, unchanged context on both sides. Short quotes and substantially rewritten passages do not use fuzzy matching.
6. Leave unresolvable records saved but unpainted. Never attach them to the closest-looking passage without the required confidence.

Rendering uses three CSS `Highlight` collections with translucent colors and preserves the page's text color. It does not insert spans, split text nodes, change selection ranges, or modify link behavior. Repeated restoration replaces these collections instead of duplicating wrappers. A constructed stylesheet supplies the highlight colors.

## WebKit integration and safety

All JavaScript runs in the named `Origami.WebHighlighter` content world, in the main frame. The normal page world cannot invoke the message handler. Messages carry a document identity and URL; native code checks the main frame, current URL, identity, payload shape, and limits. Messages describe a selection or lifecycle event; they cannot directly write the database. With a tool enabled, a trusted selection event requests an action; native code revalidates the retained selection, active tool, and current document before saving it.

Skip forms, links, buttons, editable content, ARIA textboxes/searchboxes/comboboxes, inputs, password fields, textareas, hidden content, and script/style nodes. A range crossing an excluded control is also rejected. There are no filesystem, shell, credential, or network operations in the bridge. User-facing errors are generic and contain no selected text or URL.

## Dynamic pages and navigation

A debounced `MutationObserver` attempts restoration after changes to text or child nodes. Each route gets at most 20 automatic restoration passes, at least one second apart. The text index is capped at 200,000 UTF-16 units and 10,000 text nodes; selections at 8,000 units; saved highlights at 200 per profile/page. Pages without saved highlights do not build a restoration index.

`popstate`, `hashchange`, `pageshow`, and a lightweight 500 ms URL comparison handle navigation, including `pushState` and back-forward cache restoration. URL changes discard the previous route's ranges before loading that route's records. In-flight native actions check identity again after JavaScript returns. Cross-tab edits become visible through the manager revision when the webpage is shown.

## Implementation examples

The production Swift implementation saves only after the selection is verified:

```swift
let record = HighlightRecord(
    url: url.absoluteString,
    pageTitle: String((webView.title ?? "").prefix(300)),
    anchor: selected.anchor,
    style: style ?? manager.style
)
try manager.store.save(record, profile: profile)
manager.revision += 1
```

The JavaScript rendering pattern is:

```javascript
const range = resolve(record.anchor, textIndex);
if (range) styleHighlights.add(range);
CSS.highlights.set(styleName, styleHighlights);
```

Swift sends configuration using `callAsyncJavaScript` arguments, never source-code interpolation of webpage text. See the implementation in `Origami/Highlighter/` for the complete bridge and matching algorithm.

## Implementation phases and verification

1. **Storage:** versioned records, migration, profile isolation, private lifecycle, and persistent preference defaults.
2. **Restoration:** bounded text index, verified DOM hints, exact/context matching, conservative fuzzy fallback, and non-mutating rendering.
3. **Interaction:** native bottom panel, highlight/erase modes and color selection, General settings, Quick Tools, and document/SPA lifecycle guards.
4. **Verification:** synthetic WebKit and temporary-database tests, followed by live-page visual and interaction checks.

Automated tests cover database reopening, style changes/removal, profile deletion/isolation, private-window cleanup, URL/input bounds, preference persistence, markup changes, duplicate quotes, fuzzy edits, excluded content, idempotent rendering, dynamic insertion, SPA navigation, stale selections, native save/change/remove flow, and page-world bridge isolation. Tests use generated pages and temporary data, without relying on the source checkout at runtime or external services.

Manual checks remain necessary for bottom-panel presentation at different window sizes, light/dark contrast across websites, VoiceOver/keyboard feel, and rapidly updating SPAs. V1 does not support subframes, shadow-root text, PDFs, canvas text, Reader annotations, or guaranteed restoration after major rewrites. Extremely dynamic pages can exhaust the bounded retry budget; revisiting/reloading starts a new budget. Engine-specific Custom Highlights rendering differences remain possible.

The record IDs, schema version, and store API leave room for a later page list, search/export, Reader integration, and optional sync. None is implemented here.
