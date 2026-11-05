# ui-app9-sync review fixes, round 1

## Changes and regression coverage

- F069: `testAFileRewrittenAfterTheListingIsNotDeleted` expects two downloads
  without listing ETags (the newer original and the moved copy's verification),
  one with ETags, verifies both local files, and requires the following pass to
  have no downloads, uploads, conflicts or pending work. Reviewed every other
  `omitFileETags` use: `testPutValidatorFormsAndDateSizeListingsStayStable`,
  `testConcurrentWriteAfterPutWithETaglessListingIsDownloadedOnce`, and
  `testServerWithoutAnyETagsSettlesWithoutRepeatedDownloads`. Their assertions
  already allow the intended verification pass. Also checked
  `testServerWithoutPutETagsStaysStable`. No production WebDAV change was needed.
- F066: `BackgroundCache.drawImage` requires frame zero's ImageIO status to be
  complete after thumbnail decoding and before caching. A non-nil partial image
  now throws the existing unavailable error. `ExportImages.decode` stays lenient
  for image items and attachments. The truncated fixture tests keep their
  failure, temporary-file cleanup, background-disabled and successful-retry
  assertions; platform-dependent count/properties premise assertions were
  removed. Reviewed `testBackgroundDrawingReportsTruncatedPixelsAfterReadingTheHeader`,
  `testUnreadableImageBackgroundFailsInsteadOfExportingBlankPaper`,
  `testRepeatedImageBackgroundSnapshotsProbeOneContainerWithoutDecodingPixels`,
  and `testJPEGExportWritesOneImagePerPageNamedByPageNumber`.
- F068: `BackupQueue.pruneReports(keeping:formats:)` removes reports outside the
  eligible document set or configured export formats. It splits at the final
  slash so caller-supplied document IDs containing slashes still work.
  `BackupEngine.run` and `libraryChanged` both apply it after retaining eligible
  queue entries. Removing the final report also settles an omission-only warning
  when there is no work left for an automatic pass; cleanup preserves the last
  actual delivery time. `BackupConfiguration.exportFormats` supplies the same
  formats to pruning and exporting. New tests:
  `testReportsKeepOnlyEligibleDocumentsAndConfiguredFormats` and
  `testObsoleteOmissionReportsArePrunedByRunsAndLibraryChanges` cover both formats,
  trash, deletion, exclusions, format switches, direct runs, library events,
  empty automatic passes, persistence and the next successful manual run.
- F068: a delivered run with omissions still has warning status but now advances
  `lastSuccess`. `testAutomaticOmissionsSurviveRestartSuppressRepeatsAndClearOnlyAfterDelivery`
  verifies the first and repeated completion times and that failed delivery does
  not advance them. The test drains old writes and redirects the original
  subscribed engine to a throwaway store before reloading, preventing two engines
  from overwriting the same queue file. Its final persisted-report assertion stays.
  Also reviewed `testBothFormatsWebDAVAndLockedDocumentRetry`,
  `testFailedDeliveryRetainsQueueAndLaterRunRecovers`,
  `testClearDuringExportDoesNotSendOrConsumeNewQueue`,
  `testUnopenedLibraryRescanFiltersOutlineFavouritesAndDeletionsButQueuesContent`,
  `testOmissionReportsPersistAndOldQueuesStillDecode`, and
  `testQueueLookupSurvivesDecodingRemovalAndSnapshots`.

## Folders named Inbox: required shared API, outside this lane

The current `CatalogScanner.isHandoffInbox` in
`NibKit/Sources/NibLibrary/LibraryCatalog.swift` is internal. It lists the folder
and returns true only when no valid `.nibfolder.<device>.json` record is present,
using `LibraryLayout.isFolderFile`; failed directory enumeration returns false
to preserve potentially owned data. Neither helper is exposed by NibContracts.

The owning lane must expose a shared public predicate, for example
`NibFormat.isHandoffInbox(_ directory: URL) -> Bool` in NibContracts, or an
equivalent public library/catalog service predicate or flag accessible through
NibContracts. Move the exact record-filename validation there and make the
NibLibrary scanner delegate to it. A public NibLibrary helper alone also needs
an approved dependency or contract bridge, because features and NibSync cannot
import NibLibrary under the architecture rules.

Then apply the predicate at all three consumers:

- `NibKit/Sources/NibSync/FolderWatcher.swift:418`: skip a root named Inbox only
  if it is the hand-off inbox; watch recorded user folders normally.
- `NibKit/Sources/FeatWebDAV/FeatWebDAVFeature.swift`,
  `WebDAVSyncEngine.excludedTopLevel(root:)`: exclude Inbox only when the shared
  predicate identifies the hand-off inbox; mirror recorded user folders normally.
- `NibKit/Sources/FeatAbout/DataDeletion.swift`, `DeletionPlanner.inboxFolder`
  and its use in `plan`: use the predicate instead of treating Documents/Inbox
  unconditionally as disposable app data; preserve recorded user folders for
  keep-library deletion and count/remove their documents for Delete All Data.

NibLibrary and NibContracts are outside the original allowed edit paths, so these
three consumers remain unchanged as the original item 5 explicitly permits.
Integration must test both a real hand-off inbox and a recorded user Inbox at
each consumer. The existing catalog-only tests do not prove consumer behavior.

## Callers and validation

`BackupNow.run` routes manual and automatic commands to `BackupEngine.run`;
`automaticPass` uses that command. The library event subscription and backup tests
call `libraryChanged`. Both paths call the new pruning helper. Status exposes
the queue's warning and completion time to `BackupSettingsPage`. The image
background call comes from `ExportCompositor.drawBackground` in PDFExporter,
shared by PDF and raster exports; image items and attachment thumbnails call
the unchanged lenient decoder. No new commands, dependencies or localized keys.

Local checks: `python Scripts/lint.py` passed with 0 errors and 25 warnings;
`python Scripts/a11y_lint.py` passed with 0 warnings, matching the pre-edit
baseline; `git diff --check` passed. Only permitted source/test directories were
edited. Swift tests were reviewed and authored, not run: this Windows machine
has no Swift/iOS toolchain. ImageIO behavior and Debug/Release compilation still
require GitHub Actions. No push and no earlier commit amended.
