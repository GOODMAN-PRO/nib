# ui-app7b-library review, round 1

## F1: required integration changes outside this lane

The catalog visibility fix is **not an end-to-end data preservation fix**.
`CatalogScanner.isHandoffInbox` only affects catalog enumeration. FeatImport still
offers visible children of a recorded `Documents/Inbox` for import, and
`ImportEngine.consumeInboxCopy` can remove the originals after import or decline.
FeatAbout also schedules `Documents/Inbox` for removal by name. These are existing
risks, not verified-safe behavior. The lane cannot change their files or NibContracts.

The integration owners must make the following coordinated change before claiming
that a recorded user Inbox is safe:

1. In `NibKit/Sources/NibContracts/Model/Primitives.swift`, expose a public shared
   predicate, for example `NibFormat.isHandoffInbox(_ directory: URL) -> Bool`.
   Return true only after successfully listing the directory and finding **no**
   folder record. Use the record-name recognition currently in
   `LibraryLayout.isFolderFile` / `device(of:prefix:suffix:)`: `.nibfolder.` plus
   an eight-lowercase-hex device id, optional conflict-copy suffix, and `.json`.
   Do not parse the record JSON to establish ownership: damaged records still
   protect a user folder. Preserve user ownership for evicted record placeholders
   too (`..nibfolder.<device>.json.icloud`). Listing failure must return false
   (do not consume, hide, or delete unclassified contents). The caller still checks
   that this is the app's default Documents/Inbox, not an arbitrary named folder.
   Features may import NibContracts, not NibLibrary; merely making the scanner's
   internal method public is insufficient. Move the implementation to this shared
   helper and make `CatalogScanner.isHandoffInbox` delegate to it in the same
   integration change so the classifiers cannot drift.
2. `NibKit/Sources/FeatImport/InboxScanner.swift`, `InboxFiles.entries`: before
   enumerating the candidate equal to `documents/Inbox`, require the shared
   predicate. Skip that directory entirely when recorded or unreadable; do not
   relabel its children as loose Documents imports. Preserve the separate App
   Group inbox behavior. In `ImportLocations.isInConsumableInbox`, require both
   canonical containment under `openInInbox` and the same predicate on that inbox.
   Keep the App Group branch separate. Recheck on every call, including at consume
   time, rather than trusting a cached scan result.
   `NibKit/Sources/FeatImport/ImportCommands.swift`,
   `ImportEngine.consumeInboxCopy` already calls this predicate immediately before
   `removeItem`, so fixing that guard protects both successful imports and declines.
3. `NibKit/Sources/NibSync/FolderWatcher.swift`, `Walker.walk` (the root
   `skipInbox && name == SyncFiles.inboxName` branch): skip only when the shared
   predicate is true. In `NibKit/Sources/NibSync/LibraryLocationPicker.swift`,
   `LibraryCopier.topLevelItems(of:)`, apply the same guard to the Inbox exclusion
   so recorded user folders move with the library.
4. `NibKit/Sources/FeatAbout/DataDeletion.swift`, `DeletionPlanner.plan`: add
   `documents/Inbox` to `remove` only when the shared predicate is true. A recorded
   folder must remain when `includeLibrary == false`; when true, let the existing
   library-ownership deletion pass handle it. Do not unconditionally delete it as
   staging merely because the active library has moved elsewhere.
5. `NibKit/Sources/FeatWebDAV/FeatWebDAVFeature.swift`,
   `WebDAVSyncEngine.excludedTopLevel`: for the default Documents root, include `Inbox`
   in the exclusion set only when the shared predicate is true. Retain the existing
   diagnostics exclusion. Recorded user Inbox folders must be eligible for sync.

Integration tests must cover a recorded Inbox containing a notebook and subfolder,
damaged/conflict/evicted folder records, an unreadable directory, a genuine unmarked
handoff inbox, and the independent App Group inbox. Assert no recorded children are
offered, import/decline cannot consume them, keep-library deletion preserves them,
and sync/location moves include them. Existing lane tests reviewed:
`testExistingUserInboxAndItsContentsRemainVisibleAndUntouched` and
`testSystemHandoffInboxIsSkippedWithoutConsumingIncomingFiles` in
`ReservedFolderNameTests.swift`. They prove catalog behavior only.

## F2: compact empty-state height

`content(compact:compactHeight:)` still places the ScrollView directly under
NavigationStack. A noninteractive background **inside** its content uses iOS 17
`containerRelativeFrame(.vertical)` to measure the nearest scroll container and
feeds a minimum grid height. The container length excludes safe-area insets,
including the bottom control reservation, so that reservation is not subtracted
twice. Header height and top spacing are subtracted once. Minimum height lets
large-text empty content grow and scroll. The regular-width GeometryReader and
width pin are unchanged; the compact VStack receives NavigationStack's width.

Apple's sizing contract:
https://developer.apple.com/documentation/swiftui/view/containerrelativeframe(_:alignment:)

Added `testCompactEmptyFoldersAndCollectionsFillTheScrollViewport` for an empty
folder, Recents, and Study Sets on phone and narrow iPad layouts, including a width
assertion. Reviewed `testEmptyStateUsesSpaceBelowHeaderAndAboveControls`,
`testContentWidthUsesCurrentViewportAndOnlyTheInlineSidebar`, and
`testPhonePresentationSurvivesRotationAndShortWindowsStayCompact`.
These Swift tests are authored, not executed on this Windows machine.

## F4: explicit coordinate conversion and service wiring

Only `content.column` is now measured in SwiftUI `.global`; all existing chrome,
menu-anchor and drop measurements retain their original spaces.
`LibraryModels.get` publishes the global rectangle after the existing top-chrome
clearance through `libraryui.searchContentBounds`. The floating search host
subtracts its own `GeometryReader.frame(in: .global).origin` before intersecting
with its local visible bounds. There is no assumption that the library root and
floating host share an origin. The bounds remain window-local through the
session-specific publisher.

Added `testLibraryModelsPublishesSearchBoundsThroughTheServiceKey` to exercise the
actual `@MainActor` closure cast, initial emission, live updates, duplicate
suppression, reset, and session isolation. Added
`testLibrarySearchConvertsGlobalColumnIntoInsetFloatingHost`; retained and updated
`testLibrarySearchSurfaceStaysInsideMeasuredContentColumn`. Reviewed
`testLibrarySearchForegroundFitsFloatingHostAfterResize` and
`testLibrarySearchCentresInsideVisibleHostIntersection`.

Inspected the light/dark landscape `test02LibrarySearch*` captures under
`G:/Projects/Nib-ci-logs/ui-ci/41961796255/ui-CaptureUITests/shots/`. They show the
original banner/title text surrounding the field, before these branch fixes.
There are no re-shot round-1 captures available in this lane. The narrow band
above the replacement surface remains uncovered to preserve the top toolbar's
paint and hit testing. Whether scrolled page words appear between toolbar buttons
there is **unverified**. The clearance remains the tallest `top.*` chrome height
plus `NibSpacing.l + minimumRestingGap`. Capture CI must check this band, sidebar
interaction, keyboard resize and Stage Manager in both themes. If words remain,
extend opaque paint to the column's minY **behind** the toolbar, retain the field
offset at clearance and keep the tap catcher below the toolbar. Simply extending
the current floating layer's opaque background upward would cover the toolbar.

## F3: remaining runtime check

First-layout overflow still comes from one anchor/content/viewport preference
resolution. End-of-scroll updates of that anchor are **unverified at runtime**;
the pure tests `testSearchContinuationExplainsClippedRowsAndDisappearsAtTheEnd`
and `testContinuationUsesContentAndViewportFromTheSameLayout` do not prove SwiftUI
re-resolves the anchor on every offset change. Capture/UI CI must scroll to the
end and check the hint disappears. If it sticks, add an iOS 18+
`onScrollGeometryChange` path behind `#available(iOS 18, *)` observing content
extent and visible rect together; retain the preference path on iOS 17.

## Callers and verification limits

Traced `content` / `contentScroll` from `LibraryRootView.body`,
`emptyContentHeight` from the grid frame and tests, `libraryChromeFrame` across
library controls/layout tests, `LibraryModels.get` across library feature/command
registration and tests, and `SearchViewport.libraryContentBounds` from
`LibrarySearchFloatingContent` and its tests. `DocumentSearchFloatingContent`
does not call the library-specific bounds helper. No new commands or feature
dependencies. No Swift compiler or simulator is installed here; Debug/Release
compilation, Swift tests, large-title collapse, centring and visual re-captures
remain GitHub Actions work.

Local validation: `python Scripts/lint.py` exited 0 (0 errors, 25 warnings);
`python Scripts/a11y_lint.py` exited 0 (0 warnings, matching the pre-edit baseline);
`git diff --check` exited 0. All edited paths are in the lane's owned source/test
directories. No push and no earlier commit amended.
