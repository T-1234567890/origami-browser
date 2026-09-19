# Content and ad blocking

Both options start off and are independent under Settings → Privacy. Site Information has independent switches for the current hostname; reload after a change. Turning a global switch off removes only that system’s compiled rule list. Exceptions match the exact hostname (all ports and paths), not lookalike names or every subdomain. Settings and saved exceptions are global across profiles. Private windows use the same protections, but cannot persist new site exceptions; change those in a regular window.

## Custom content rules

Content Blocking is off by default and starts empty. Excluded Sites provides an editable list of exact hostnames on which custom rules are bypassed. It shares the same saved exceptions as Site Information. Editing or clearing exclusions does not enable Content Blocking and does not affect Ad Blocking. Import Rules (directly below the toggle) merges UTF-8 text files up to 1 MB into the custom domains without enabling blocking; invalid imports leave existing rules intact. Edit Custom Rules accepts up to 500 hostnames, one per line, and blocks requests to each hostname and its subdomains. Invalid input is rejected without changing saved rules. Saving an empty list removes custom blocking. There are no pre-built domains or subscription lists in this system. The custom rule compiler is MPL-2.0 and uses public WebKit content-blocking APIs.

## Optional ad subscriptions

The first opt-in downloads directly from:

- https://easylist.to/easylist/easylist.txt
- https://easylist.to/easylist/easyprivacy.txt

`FilterDownloads` uses cookie-free, credential-free ephemeral HTTPS sessions, rejects redirects, validates the header, and bounds each response to 12 MB and 60 seconds. It never contacts a filter source while Ad Blocking has never been enabled. Checks happen at startup and hourly while running; successful data is refreshed after 24 hours. Failed attempts back off for an hour. Update Now allows a manual retry. A circular progress ring shows received bytes against the current file’s Content-Length; identity encoding is requested to make that total usable. Unknown-length downloads and local conversion/compilation use an indeterminate indicator with a stage label. Disabling stops an in-flight download and retains the local cache for future use.

`FilterConverter` supports plain network URL patterns, domain/start/end anchors, wildcards, separator characters, common positive resource types, first/third-party conditions, single-direction domain inclusion/exclusion, network exceptions, and trailing `badfilter` cancellation. Network exceptions follow blocking rules from both lists. Unsupported exception options are conservatively broadened to the URL pattern to avoid silently dropping allow rules.

This is a supported subset, not full Adblock Plus/uBlock compatibility. Cosmetic selectors, scriptlets, redirects, regular-expression filters, mixed positive/negative domain conditions, negated resource types, and other unsupported blocking options are skipped. A separator matches an actual separator, not an end-of-string alternative (WebKit’s regex subset cannot express that alternative); this can underblock. Unsupported counts are shown in settings. Rules are capped at 120,000; oversized or uncompileable updates fail rather than silently truncating.

`BlockingService` compiles the two systems separately with `WKContentRuleListStore`, adds/removes only its own lists, and retains the old active lists until replacements compile successfully. Site exceptions are last-rule `if-top-url` exemptions within the appropriate list, so redirects and frame loads use WebKit’s actual top document rather than a stale tab URL. Navigation awaits local preparation, never a network update. New and popup tab configurations attach to the same service. Specialized generated-visual sandboxes are unchanged.

## Cache and licensing boundary

Runtime data lives in Origami’s sandbox Application Support, under `Origami/DownloadedFilters`. An atomic `filters.json` snapshot contains the untouched downloaded texts, converted derivative rules, timestamp, skipped-rule count, and attribution/license information. Compiled files are disposable cache. Tests use temporary directories and synthetic filters, never real downloaded lists. No filter data is bundled or committed. A failed download, conversion, compilation, or snapshot write leaves the last successful snapshot and rules intact. Open pages may need reloading after the first download or a policy change.

The EasyList authors (https://easylist.to/) retain the filter data’s licensing. Origami chooses **CC BY-SA 3.0 Unported or later**, as permitted by https://easylist.to/pages/licence.html. See https://creativecommons.org/licenses/by-sa/3.0/ and its legal code. The original and locally converted data are not MPL-2.0 source; conversions remain under the applicable CC BY-SA terms. Attribution identifies Origami’s local conversion as a modification. No filters are redistributed in the repository or app package. Third-Party Notices and About → Credits & Licenses document these sources and terms.

Implementation code remains MPL-2.0. Adding a new subscription requires a separate source/license review. Never paste downloaded lists or generated derivatives into resources, tests, or public source files.
