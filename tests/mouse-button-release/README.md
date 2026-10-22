# Mouse button release ordering regression

Run on macOS with the Xcode command-line tools:

```sh
python3 tests/mouse-button-release/run.py
SANITIZE=1 python3 tests/mouse-button-release/run.py
```

The fixture compiles the production button methods, input-context access and
validation helpers, mouse-specific queue dispatcher, capture/context setters, and absolute-position diagnostic/cache updates.
Only external packet delivery, settings, touchpad consumption, controller state,
and diagnostic logging are isolated. No stream, hardware, user preferences, or network
connection is opened.

A real serial dispatch queue is held behind a semaphore to exercise backlog.
Assertions cover:

- A queued press followed by uncapture and pause must not leave a pressed button.
- Normal press/release ordering, all five buttons, repeated cleanup, and cleanup
  of buttons whose presses have already reached the packet sink.
- Pause followed immediately by recapture must not revive an old queued press.
- Current-context checks, uninitialized contexts, context replacement and pointer
  reuse, and safe rejection after the old context has been freed.
- Absolute position/button ordering, same-position recapture after a cancelled
  synchronized press, swapped buttons, AppKit suppression when
  GCMouse owns input, and precision touchpad consumption.
- An in-flight packet send concurrent with pause, and the unchanged generic
  keyboard/controller cleanup dispatcher.

The assertions fail against the original implementation after successful
compilation:

```sh
python3 tests/mouse-button-release/run.py --source-ref 259307d
```

It emits `RELEASE, PRESS` for the initial backlog test. The fixed path discards
that stale press and sends the cleanup release on the input queue. Releases are
not gated on capture remaining enabled. A context epoch also prevents an old
release reaching a newly bound connection at the same address.

The fixture validates queue and state logic, not physical mouse feel or the
GameController/precision-touchpad implementations. Input contexts must continue
to be detached before their owning connection is destroyed, as in stream
shutdown. This change does not alter unrelated keyboard or motion queue lifetime
handling.
