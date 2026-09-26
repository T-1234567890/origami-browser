# Native PDF viewing

Origami displays top-level inline PDF navigations with PDFKit. Embedded PDFs inside
webpages remain WebKit content. Explicit downloads (`Content-Disposition: attachment`,
download links and Option-click) continue through the existing DownloadService.

## Response handoff

`TabPage` recognizes `application/pdf` and `application/x-pdf`. A `.pdf` URL is only a
fallback for absent MIME or `application/octet-stream`; it never overrides HTML.
The navigation-response policy becomes `.download`, and its `WKDownload` is handed
to `PDFTabContent`. There is no URLSession request or second GET: WebKit supplies the
original response, including session-bound, redirected and POST-generated bodies.
The response object identifies the pending handoff; a stale handoff is cancelled.

The transfer writes into a random, owner-only directory beneath the application's
temporary directory. `PDFDocument(url:)` opens the completed file off the UI thread;
the resulting document is subsequently owned by the main actor. PDFKit performs
text search asynchronously. There is no progressive-loading implementation.

Public API references:
- [Navigation response download policy](https://developer.apple.com/documentation/webkit/wknavigationresponsepolicy/download)
- [Navigation response download handoff](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webview(_:navigationresponse:didbecome:))
- [PDFKit printing](https://developer.apple.com/documentation/pdfkit/pdfview/print(with:autorotate:))

## Viewer and commands

`PDFViewerView` provides thumbnails, current/total page count, page navigation,
zoom, Fit Width (including resize), Fit Page, search with result navigation,
rotation, Save PDF, Print, Share and Open in Preview. A compact bottom-floating
Liquid Glass capsule matches the highlighter tools, with material/opaque fallbacks.
Neutral-colored controls open native popovers. View Options groups zoom, fitting,
rotation and Reset View; Document Actions groups saving, printing, sharing and
Preview. Reset View restores original page rotations and the default continuous
auto-fit view. In narrow panes, page navigation remains available in View Options.
Search appears in a separate floating capsule above the toolbar.

- Save PDF copies the original file, including encryption, without serializing or
  rendering PDFKit's document. Rotation is a viewing change, not an edit to saved bytes.
- The standard save panel handles destination/overwrite confirmation. A staged copy
  receives existing Origami quarantine protection before replacing the destination.
  Foundation supplies an item-replacement directory on the destination volume; the
  implementation does not assume permission to create arbitrary sibling files.
- Print and Command-P use PDFKit/AppKit, respecting the document's print permission.
- Command-F opens PDF search; Command-plus/minus use PDFView zoom.
- Save Page remains a webpage-only operation. No Command-S shortcut was added.
- Quick Tools' existing Save PDF action routes to the original PDF when appropriate.
- Password-protected PDFs show an unlock field. Failed passwords can be retried;
  the input is cleared after each attempt and is never persisted.
- Invalid or failed downloads show a native error with Retry, without falling back
  to WebKit's PDF viewer.

## Navigation, privacy and lifetime

The viewer uses existing `TabDestinationHistory` entries. It retains PDF content
while its entry remains reachable through Back/Forward. URL and title updates use
the original response URL and sanitized filename, not the temporary file path.
Normal history records successful viewing; private viewing creates no history or
Download Manager records. Duplicate Tab copies the cached original into an
independent temporary directory; closing either tab does not invalidate the other.

GET-based Reload/Retry uses WebKit again. A known non-GET PDF requires returning to
the source page and submitting again instead of silently replaying a form or doing
a different GET. Cached Back/Forward and duplication need no network replay.

Tab disposal, private-tab closure, reload replacement and pruning forward history
release the associated files. Failed loads remove their temporary files immediately.
Cancellation waits for WebKit's cancellation callback before removing a transfer's
directory. Crash/force-quit leftovers remain subject to OS temporary-file cleanup.

PDF actions allow only internal page destinations and HTTP(S) links routed through
Origami. Local-file links, remote-document actions, arbitrary schemes and other
PDF actions are not forwarded. There is no JavaScript bridge or PDF scripting
implementation. A separate PDFView delegate handles links: using PDFView itself as
its delegate recurses inside PDFKit's scale-factor dispatch.

## Validation and remaining manual checks

Targeted tests cover MIME/extension discrimination, real WKDownload response handoff,
byte-for-byte save and overwrite, Back/Forward, temporary-file disposal, corrupt
PDFs, 200-page loading/search, encrypted-document unlocking, private browsing,
print/save command eligibility, safe filenames and allowed link actions. Existing
download and native-destination regression suites are also run.

Still requires manual verification in a signed interactive build:

1. Open a public PDF directly, from a link, and through a redirect. Check title,
   address, thumbnails, page navigation, resize/fit, search, rotation and zoom.
2. Open a no-suffix PDF and an authenticated or POST-generated PDF. Check that the
   current session works, Back/Forward restores it, and Duplicate works offline.
3. Open a genuinely large PDF (the automated 200-page fixture is not a large-byte
   stress test), a corrupt PDF, and a password-protected PDF with wrong/right passwords.
4. Save, cancel Save, overwrite an existing file, and compare original bytes.
5. Print with both the toolbar and Command-P; verify the native dialog and output.
6. Share and Open in Preview. Keep the originating tab open until the receiving app
   finishes reading the temporary file; exported files are independent of the tab.
7. Repeat in a private window, close it, and confirm no history/download record or
   temporary viewing file remains.

Real-site authenticated/POST behavior, interactive print/save/share dialogs,
thumbnail appearance and Preview launch are not claimed as manually verified.
Embedded PDFs, streaming, OCR, editing/saving rotations, outline navigation and
persistent offline PDF caches are outside this implementation. Restored sessions
reload network URLs; cached POST bodies do not survive relaunch.
