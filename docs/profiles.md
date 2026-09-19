# Profiles

Profiles keep their own open tabs, pinned tabs, tab groups and saved sessions. There is no separate Spaces concept.

Open **Settings → General → Profiles → Manage…**, then create or edit a profile. Each category can use the profile’s own storage or share with Personal:

- Website data and sign-ins
- History
- Bookmarks
- Appearance
- Tab layout

Personal is the shared destination and cannot be deleted. Two profiles sharing a category both use Personal’s data for that category.

## Existing profiles and switching

Existing website data, history and bookmarks remain isolated. Appearance and tab layout retain their previous shared behavior until changed.

Turning sharing on does not merge, move or delete the profile’s own data. Turning it off restores that data. Changes made while sharing remain in Personal. Shared bookmark edits and shared-history deletion affect every profile using those categories.

Changing website sharing recreates the affected profile’s WebViews. Open tab identities and URLs remain, but pages reload; save unfinished forms before applying the change. The browser does not attempt to merge cookies or signed-in sessions.

Appearance and layout initially copy the shared settings when separated, then persist independently. AI and search settings remain global. Permissions, downloads, RSS, scripts and highlights retain their existing profile boundaries.

## Privacy and deletion

Private windows always use nonpersistent website storage and in-memory history, even when the source profile shares those categories. Their existing bookmark access remains available.

Deleting a profile removes its own data and closes its windows. It does not delete shared Personal data or downloaded files.

## Implementation

ProfileSharing is persisted with each profile. History and bookmark repositories resolve the effective category owner at their public boundaries, including imports, folders, suggestions and deletion. Website storage resolves to either the profile’s original WebKit store or Personal’s default store; private windows override both with an ephemeral store.

Appearance flows through the SwiftUI environment per window. Tab layout resolves separately from the profile-specific tab/session collection. Tests use temporary preference domains, in-memory databases and synthetic URLs rather than a developer checkout or account.
