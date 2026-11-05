# QA support 7

Baseline: work/ui-round-7 at 31adf71; run 41924805545 built from 3179563. Read the complete `G:/Projects/Nib-ci-logs/r4-diagnosis.json`, pairing findings with verifier verdicts; corrections win. Current sources were compared before edits. Windows has no Swift/Objective-C compiler or simulator. All runtime outcomes below remain unverified until macos-26 CI. Only NibUITests changes; no push.

## N - notification isolation

Confirmed not-hittable-document finding 0 and missing-form-controls G against the unchanged predicate and timer helper. The first Time Keeper test's screenshot has the notification alert over the running clock; the next twelve Timer/Title/Tool tests fail to open Physics — Motion. The current launch and Chrome teardown already call the shared drain, but it omitted notifications. Match notification titles or alert descendants in SpringBoard and Nib, deterministically choose Don't Allow, and wait for disappearance. Start Timer now waits for authorization OR countdown, drains, retains the running-clock wait, then drains again; the preset path uses the same wait. Launch additionally drains after final placement; existing teardown now handles the same alert. Next run must show no permission prompt surviving into the next fixture and all thirteen tests proceeding beyond their blocked control. No permission reset or unrelated alert acceptance.
