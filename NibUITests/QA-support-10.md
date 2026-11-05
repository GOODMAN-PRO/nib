# QA support 10

## Round 10a

Base: 503f337 integration lineage, work/ui-round-10. Read both parts of QA-support-9, README and r10 findings/verdicts; verifier corrections win. Windows has no Swift/Objective-C compiler or simulator. All runtime targets below require macOS CI; no measured speedup or pass is claimed.

### H1 - bounded lazy-list reveal

Confirmed chrome-timeouts#0: 18 ApplySaved drags, 4.6–5.7 seconds per cycle, short 48-point row-gap move and wrong-way end probes. Current reveal retained these mechanics (the current container ranking already prefers hittable candidates). An absent target now homes toward the top with at most six gestures, requires a repeated visible range to establish the edge, then scans toward the bottom without reversal. It re-queries after every page. Slider-bearing forms retain slow delivery; other forms use fast homing and default-velocity page gestures, cached app geometry, and row-gap/plain-row starts spanning at least half the viewport. Existing clipping, value guards and transient-container checks remain. Reset/Apply/Delete/Save layout callers should spend less time traversing; CI must show a confirmed edge, no short gap drags, exact original assertions, and timings within the unchanged allowance. Savings are unmeasured and cannot be added independently to H2 estimates.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| All reveal callers; Chrome layout/reset tests | Form reveal timing / Form move timing / Form lazy edge | How many moves and seconds, and was the edge confirmed before the one-direction scan? |
