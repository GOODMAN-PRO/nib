# QA support 12

## Round 12a

Windows source-only work from integration 5040b001. Read Round 11a/11b/11c, README and the complete V3 findings and paired verdicts; corrections take precedence. Only NibUITests changes. No local Swift/Objective-C compiler or simulator; CI owns runtime verification.

### G1 - mounted document editor

Confirmed V3:whiteboard#1 and its holds=true verdict: the light portrait attachment at 05:32:32.108 preceded editor chrome layout at 32.385. Current openDocument and capture predicates still accept the session model before mounting. openDocument now additionally waits up to 15 seconds for a visible editor surface and logs time from the opening tap. Canvas notebooks/whiteboards expose nib.canvas; TextDocViewController exposes the Text document collection. StudySetEditorView has no root accessibility identifier: its own Cards header plus Language menu identify its mounted root in both compact and regular layouts, including empty sets. This uses actual source-exposed elements, not a guessed identifier or a document title in the library.

Audited all openDocument callers in Canvas, Capture, Chrome, Create, Ink, Insert, KeyProbe, Library, Pages, Selection and Smoke. The signature and model predicate remain; Create's empty/reopened text and study sets, Library's every-kind loop and Capture's mixed-kind tabs do not require a canvas. Should unblock all whiteboard variants and protect every shared caller. Next CI must log the correct root before returning, preserve the non-canvas creation/reopen tests, and show the editor rather than the library. Visible AX geometry proves mounting, not rendered tiles (G2).

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| All openDocument callers, especially Capture test18 and Library every-kind | Document editor mount | Which actual editor mounted, and how long after the tap did it become visible? |
