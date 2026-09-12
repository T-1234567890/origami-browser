# Origami Roadmap

Origami will continue focusing on native macOS browsing, useful built-in tools, contextual intelligence, and an open-source development model.

> This roadmap is directional, not a commitment. Features, scope, and target versions may change as Origami evolves.

## v1.0.x — Ship & Polish

Focus on improving the existing browser rather than expanding scope.

- Stability, performance, and bug fixes
- Reader Mode improvements
- Peek / Split View polish
- RSS and JSON Reader fixes
- Media detection improvements
- Compact Mode refinement
- Release, update, and distribution pipeline polish

## v1.1 — Better Browsing

- Peek 2.0 with structured, non-AI previews
- Content and ad blocking
- Migration from other browsers
- Connection security indicators
- Certificate information
- Profiles 2.0 / configurable profile sharing

Migration should prioritize bookmarks, history, tabs, and sessions. Password importing is optional; Origami may instead rely on Apple Passwords where appropriate.

Profiles should remain a single concept, with no separate Spaces system. They may provide isolated browsing contexts or lighter context switches, with configurable sharing or isolation for website data / sign-ins, history, bookmarks, appearance, and tab layout. Pinned tabs, tab groups, and open tabs can remain profile-specific. AI and search settings remain global.

## v1.2 — Everyday Tools

- Translate
- Dictionary
- Page Simplifier
- Task Widget
- Network / Connection tools
  - Public IP information
  - DNS lookup
  - Certificate details
  - Site network information
  - Connection diagnostics
- Quick Weather

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
