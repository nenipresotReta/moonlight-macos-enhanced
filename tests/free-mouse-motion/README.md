# Free mouse motion regression tests

Run on macOS with Python 3, Clang and the AppKit SDK:

```sh
python3 tests/free-mouse-motion/run.py
SANITIZE=1 python3 tests/free-mouse-motion/run.py
```

The harness extracts production methods, coordinate conversion helpers and
property declarations. It replaces the network input context with a packet
collector; it does not move the local cursor, send PC input or change preferences.
No Xcode test target or third-party dependencies are required.

Coverage includes delayed AppKit observations during raw movement and dragging,
fixed sensitivity, geometry changes, recapture, explicit handoff, Y inversion,
bounds, invalid reports, absolute queue ordering, duplicate positions, both
synced and unsynced buttons, button swapping, touchpad suppression, input gates,
Desktop Sync, locked mouse, GameController and CoreHID runtime fallback.
A concurrent replay checks that 1,000 positive raw reports retain every delta and
never emit a position behind a previously emitted position.

The two original failures can be reproduced against the upstream baseline:

```sh
# Both commands must fail on RC5 (259307d4).
python3 tests/free-mouse-motion/run.py --source-ref 259307d4 --case motion
python3 tests/free-mouse-motion/run.py --source-ref 259307d4 --case queue
```

For the baseline only, the harness maps the renamed seed API to the original
reconciliation method. It does not change its behavior. The motion test catches
the delayed observation rewinding an integrated cursor; the queue test catches
requests 100 -> 110 -> 120 being emitted as 120 -> 110 (scaled by eight in the
wire format).

Automatic still selects CoreHID where available. During capture, raw reports
own a fixed-sensitivity virtual trajectory; AppKit positions seed it at entry,
focus regain and geometry changes. Desktop Sync continues to follow macOS pointer
speed and acceleration. The two modes can therefore feel different even when
neither produces event-order reversals.

## Native handoff and live mode regression checks

The default runner also executes `handoff.py`. It extracts the production edge,
native synchronization, mode-reset and callback scheduling methods, substituting
native cursor movement and window state. It covers an accelerated system pointer
leaving before the remote pointer, all four virtual edges, dragging and release,
windowed operation, entry suppression, AppKit takeover after raw-device idle,
failed native positioning, and cancellation/coalescing of pending callbacks.
These checks exercise control flow, not real display scaling or event delivery.

Both follow-up failures reproduce against the first mouse-fix commit:

```sh
python3 tests/free-mouse-motion/handoff.py --source-ref 1ae66e3 --case mode
python3 tests/free-mouse-motion/handoff.py --source-ref 1ae66e3 --case handoff
```

Native cursor alignment is coalesced separately from remote packets. Mode changes
clear the virtual anchor and cancel pending native alignment; the next seed uses
the current pointer. Desktop Sync and locked mode do not run native alignment.

## Manual checks

Automated packet replay cannot establish physical mouse feel or cross-display
handoff behavior. Before promoting the test build, compare Desktop Sync with
Automatic/Fast Response while moving continuously and dragging windows. Check
slow and fast movement, left/right/middle buttons, leaving and re-entering the
stream, focus changes, resize/fullscreen transitions and locked mouse mode.

Also switch Desktop Sync → Automatic while captured, use a trackpad after the
external mouse becomes idle, and cross each edge on mixed-scale displays. Check
that native cursor alignment does not suppress clicks or scroll events.

## AppKit takeover event-chain regression checks

The default runner also executes `takeover.py`. It replays each production
`mouseMoved`, `mouseDragged`, `rightMouseDragged` and `otherMouseDragged` route
through anchor reconciliation, final movement admission, and the actual HID
absolute/relative dispatch methods. A fake raw driver supplies elapsed movement
time to the production 250 ms recency predicate. One idle-device AppKit event
must emit exactly one absolute position and no relative delta; the next raw
report must continue from that position.

The tests also cover raw reports immediately before and after takeover admission,
queued packet ordering, disabled input, inactive capture, precision-touchpad
suppression, invalid context, capture/menu blockers, and consumed event routes
with and without an existing anchor. Desktop Sync, locked mouse, GameController,
CoreHID failure, non-CoreHID fallback and touchscreen absolute override retain
their original routing. Native windows, capture-policy decisions and consumed
route decisions are controlled fakes; these checks do not test actual AppKit
scheduling or physical device coexistence.

The duplicate-dispatch regression must fail against the pre-fix testing commit:

```sh
python3 tests/free-mouse-motion/takeover.py --source-ref f59af61 --case takeover
```

That revision sends absolute x=110 followed by relative x=10 for a single AppKit
movement from x=100 to x=110 (absolute coordinates are scaled by eight on the
wire). The regression requires only the absolute packet. Anchor reconciliation
alone must have no transmission or anchor mutation when the raw device is idle;
movement is admitted after the outer capture and event-consumption checks.
