# Peek 2.0

Peek is a compact, non-AI link preview. It uses the existing hover delay, placement, dismissal, and a webpage preview bounded to 280×200 points. The original preview body keeps that size and ratio, with the webpage slightly inset inside it. Only the 32-point glass top bar adds height, for a maximum 280×232-point card. Switching layers never changes that frame or creates another window.

## Experience

- **Off:** no preview loads or cards.
- **On Demand:** hover opens Preview. Swipe left within the card for Details; swipe right to return.
- **Automatic:** hover opens Details, with Preview still available.

Settings → General → Peek controls the mode. A shared top bar provides Preview and Details buttons in both layers. The existing Escape and outside-click dismissal remain. Open in a new tab explicitly promotes the preview.

Preview fits the original webpage viewport ratio inside a rounded content frame below the shared top bar. Details shows the loaded destination domain, title, description, available author/date/category metadata, approximate reading time, and up to six headings. Optional images remain small, preserve their aspect ratio, and are never enlarged beyond their natural size. Missing fields disappear. Publication dates are formatted for the current locale; authors and dates have icons, and headings use bullets. Loading and empty states are centered below the top bar. Text and scrolling stay bounded to the card; this is not an article reader.

Documents use their own metadata presentation. PDFs can show title, author, page count, size, and an excerpt from the first page. Office/iWork links show filename, type, and size when the server supplies it. They are not downloaded and unpacked for deeper inspection. Extensionless documents are recognized when WebKit supplies a supported MIME type. Authenticated document requests may have less metadata because the auxiliary loader does not copy browser cookies.

## Components and state

- `PeekMode` and `BrowserPreferences`: persisted Off / On Demand / Automatic preference.
- `BrowserStore`: owns preview lifecycle, source link, selected mode, and promotion; turning Off dismisses existing cards.
- `PeekPreview` / `PeekExtraction`: bounded native model and deterministic isolated-world extraction of meta/Open Graph, Schema.org, article text, and headings.
- `PeekDocumentLoader`: ephemeral, cookie-free PDF requests, 8 MiB cap and a 10-second resource timeout. No filesystem URLs, archive extraction, shell execution, or AI calls.
- `PeekCard`: fixed glass container, aspect-fitted webpage thumbnail and horizontally adjacent scrollable Details layer, optional bounded preview-image loading.
- `PeekSwipeMonitor`: local AppKit trackpad event handling, confined to the card; locks to horizontal or vertical movement and ignores momentum for page changes.

State starts at `mode.initialLayer`. Loading updates content without replacing the container. New links get a fresh card identity; cancelled work cannot overwrite the next link. Preview loads do not record browsing history. There is no persistent extracted-content cache or AI result panel.

## Motion and interaction

Horizontal motion tracks the gesture inside the clipped card. On release, 36 points of dominant horizontal movement advances to the adjacent layer; otherwise it settles back. Vertical scrolling never changes layers. The settle uses a restrained spring (0.3-second response, 0.9 damping). Image arrival uses a 0.18-second fade. Reduce Motion removes translation and animation; Reduce Transparency uses an opaque system background.

macOS 26 uses the native glass effect. Earlier supported macOS versions use system material. System fonts, native buttons, accessibility labels, bounded content, and the existing hover grace period keep the feature integrated with browser chrome.

The implementation follows this sequence: persist modes and lifecycle guards; extract metadata; load bounded document information; render the fixed two-layer card; route horizontal gestures; verify extraction, layout, mode persistence, and document safety.

```swift
@State private var layer: PeekLayer = mode.initialLayer

// Both pages occupy the same measured viewport.
HStack(spacing: 0) {
    normal.frame(width: width, height: height)
    structured.frame(width: width, height: height)
}
.offset(x: (layer == .normal ? 0 : -width) + boundedGestureTranslation)
.clipped()

// On horizontal gesture completion:
withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
    layer = layer.moved(horizontal: deltaX, vertical: deltaY)
    gestureTranslation = 0
}
```

No GitHub API enrichment or site-specific network integration is included. Such pages use their published metadata. Live-site metadata quality, physical trackpad feel, and visual appearance across macOS versions still require manual validation; synthetic extraction tests do not establish those results.
