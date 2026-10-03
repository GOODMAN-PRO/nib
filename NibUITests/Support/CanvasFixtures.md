# Canvas recovery prerequisites

`try ui.launchFixture(scenario: ...)` selects an opt-in scenario using
`-NibUITestFixture -NibUITestScenario <name>`. The default remains `standard`
(four notebook pages, one board). Extra arguments without `-NibUITestFixture`
cannot enable a scenario. Fixtures use an isolated library and preferences.

- `failedRender`: the first visible tile request on Physics — Motion's first
  page throws a transient error. All subsequent requests use the real renderer.
  The canvas owns the error state and the existing Try Again / Restore from
  Backup actions. `renderFailureCount == 1` confirms the prerequisite occurred.
  Wait for the recovery control before acting; opening a document precedes tile
  rendering. After Try Again, verify the error disappears and ink, document,
  page count and history remain unchanged. Restore must open Cloud & Backup.
- `largeDocument`: Physics — Motion has 300 pages. Backgrounding delivers a
  simulated UIKit memory-warning notification to the production observers.
  `memoryWarningCount` records delivered warnings; `rendererCachePurgeCount`
  records actual forwarded renderer purges; `cachedPageCount` reads the current
  workspace cache. Capture counters before backgrounding and assert increases
  after resuming, then return to the inked page and verify content and undo.
  Navigation assertions must use the actual page count instead of "of 4".
  This exercises notification-driven recovery, not OS memory exhaustion/jetsam.
- `unseenBoards`: Concept map has three boards. Board 1 retains the three local
  items; boards 2 and 3 have persisted remote page revisions newer than the
  device's seen baseline. Opening Board 1 cannot auto-acknowledge the offscreen
  changes. `unseenFixturePages` lists those remote page IDs still newer than
  the receipts, and `boardReadReceipts` maps raw page IDs to persisted marks
  (null before acknowledgement). In Select mode, mark Board 2 seen and verify
  its receipt advances while Board 3 remains unseen; Select All / Mark as Seen
  must clear both. Verify content and history as well. These fields inspect
  persisted receipts; they do not simulate F108's tracker or command results.

The round-1 Canvas tests must explicitly launch the relevant scenario. The
Mark as Seen test currently ends in an unconditional prerequisite `XCTFail`;
replace that placeholder with receipt assertions. The large-document test's
`go` helper currently hard-codes four pages; use `QAState.pageCount` in its HUD
assertion and pass that count to its paper lookup. These test-file edits are
outside this app-shell change's permitted scope. Export cancellation and the
writing-pane slider already have test-side corrections; neither requires a
new fixture scenario. No UI tests were run as part of this change.
