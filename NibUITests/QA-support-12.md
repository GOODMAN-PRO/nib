# QA support 12

## Round 12a

Windows source-only work from integration 5040b001. Read Round 11a/11b/11c, README and the complete V3 findings and paired verdicts; corrections take precedence. Only NibUITests changes. No local Swift/Objective-C compiler or simulator; CI owns runtime verification.

### G1 - mounted document editor

Confirmed V3:whiteboard#1 and its holds=true verdict: the light portrait attachment at 05:32:32.108 preceded editor chrome layout at 32.385. Current openDocument and capture predicates still accept the session model before mounting. openDocument now additionally waits up to 15 seconds for a visible editor surface and logs time from the opening tap. Canvas notebooks/whiteboards expose nib.canvas; TextDocViewController exposes the Text document collection. StudySetEditorView has no root accessibility identifier: its own Cards header plus Language menu identify its mounted root in both compact and regular layouts, including empty sets. This uses actual source-exposed elements, not a guessed identifier or a document title in the library.

Audited all openDocument callers in Canvas, Capture, Chrome, Create, Ink, Insert, KeyProbe, Library, Pages, Selection and Smoke. The signature and model predicate remain; Create's empty/reopened text and study sets, Library's every-kind loop and Capture's mixed-kind tabs do not require a canvas. Should unblock all whiteboard variants and protect every shared caller. Next CI must log the correct root before returning, preserve the non-canvas creation/reopen tests, and show the editor rather than the library. Visible AX geometry proves mounting, not rendered tiles (G2).

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| All openDocument callers, especially Capture test18 and Library every-kind | Document editor mount | Which actual editor mounted, and how long after the tap did it become visible? |

### G2 - rendered canvas content

Confirmed V3:whiteboard#0 with the verifier correction: grey placeholders and the missing render gate are proven; whether the renderer regressed is UNKNOWN. New dark portrait waited 4.7 seconds versus old 3.8 and still showed placeholders, so faster capture alone cannot explain all variants. Current capture() only reads model state; all notebook routes, direct whiteboard capture and presentation/tabs pass through it. After that predicate it now requires qa.canvasSettled == true for page-bearing documents, sharing the original 15-second deadline rather than adding another allowance. The companion app owns the fact (every visible tile has real content and none pending); tests do not reconstruct it. Missing/malformed facts fail, with the last value/error and the named reason 'canvas did not settle' in ui.log.

Text/study documents have no pages and retain their own content gates. The deliberate failedRender fixture is the explicit exception: capture33 must display the error, not await impossible successful rendering; its original scenario, failure-count and Try Again gates remain. The assistant's existing foreground contrast/geometry gate is retained unchanged. Should unblock capture18 and protect every page screenshot (04-14, 17, 21-22). Next CI must show true canvas facts before normal attachments, no normal attachment after a timeout, and the error fixture still captured. Compare app render timing before assigning a latency cause.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Every page-bearing Capture screenshot except intentional render error | Capture fact ready / Capture fact timeout | Did the app report settled tiles within the shared 15-second budget, or was the last fact false, malformed or missing? |

### G3 - sidebar thumbnail images

Confirmed V3:sidebar#0 and its holds=true verdict: the light landscape shot followed the tap at t=16.92 by about 1.75 seconds, between the cache probes at 05:25:16.086 and 16.273-16.372. Current capture12 waits only for sidebar.pages. The Pages screenshot now also requires qa.thumbnails visible > 0 and loaded == visible, after state/canvas readiness and within the same capture deadline. Missing/malformed facts fail with their last value; no test-side thumbnail reconstruction or retry. Outline keeps its separate No outline yet gate. Should unblock all four capture12 variants. Next CI must show a positive complete thumbnail count before attachment18, or a named failure rather than a blank-thumbnail review image. Why that pipeline started late and the app's nil-image retry policy remain app-owned questions.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Capture test12, all variants, Pages shot | Capture fact ready / Capture fact timeout (fact=thumbnails) | How many visible cells had images at the capture boundary; was the fact absent? |
