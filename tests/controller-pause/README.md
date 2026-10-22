# Controller pause regression

This fix depends on the queued mouse-button dispatch and invalidation helper in
the mouse-release fix. Run from the repository root:

```sh
python3 tests/controller-pause/run.py
EXTRA_CFLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' python3 tests/controller-pause/run.py
```

The Objective-C fixtures compile the production GameController pause setter,
A/B callback section, mouse-mode transition, mouse-button delivery helper, and
normal gamepad output method. The raw HID fixture compiles its production pause
setter, button callback, mode transition, cleanup, and the same queued mouse
input dispatch helper used by the application. The tests use a real serial
input queue, Foundation locks, and controlled semaphores; they do not connect to
hardware or send real input.

Coverage:

- Paused A/B changes stay local; held mouse buttons release on pause and
  standalone uncapture. Paused or normal-mode callbacks do not look up the mouse
  input context.
- Resume resamples physical buttons, with matching subsequent releases. Released
  or shortcut-consumed paused holds are not replayed.
- Shortcut-consumed buttons do not become mouse clicks.
- Missing or uninitialized contexts do not record unsent button presses; pause
  still clears bookkeeping when a connection has already disappeared. Context
  replacement also clears held-button bookkeeping without reading the retired
  context. Empty controller-button cleanup does not access the input context.
- Switching out of mouse mode while paused restores physical A/B gamepad state.
- Normal GameController buttons, triggers, sticks, and duplicate suppression
  retain their existing behavior; trackpad-click and gyro pause cleanup remain.
- A callback already sending a press must finish before pause releases it. The
  test has a bounded wait so a lock-order regression fails rather than hangs.
- A blocked HID input queue discards the pre-pause press even if input resumes
  before the queue drains; the new press follows the cleanup release.
- The raw HID path does not duplicate mouse clicks when GameController owns input.

Both fixtures fail behaviorally on the original upstream implementation:

```sh
python3 tests/controller-pause/run.py --source-ref 259307d --backend gc
python3 tests/controller-pause/run.py --source-ref 259307d --backend hid
```

The GameController fixture models an already-announced controller. Its host
capability negotiation block is replaced by an assertion of that precondition;
all normal gamepad admission, shortcut, deduplication, and send logic is retained.
External hardware classes, protocol sends, touchpad reset, and shortcut routing
are isolated test sinks. The raw fixture models normal gamepad sending outside
its mouse-mode path; changes to that output path are not part of this fix.

These tests do not replace physical testing of controller models, haptics,
touchpad gestures, or Bluetooth reconnect behavior. Global multi-session
callback ownership and other asynchronous controller event families are outside
this regression's scope.
