# GCMouse button cleanup regression

Run on macOS:

```sh
python3 tests/gcmouse-button-release/run.py
EXTRA_CFLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' python3 tests/gcmouse-button-release/run.py
```

The runner shares the auxiliary-button fixture and compiles the production
registration, callbacks, per-device bookkeeping, teardown, capture/context
setters, release-all method and ordered mouse dispatcher against fake devices
and a packet sink. No installed app, network, or physical device is touched.

Coverage includes all five buttons, standalone uncapture, pause/resume, blocked
queues, an in-flight send racing pause, disconnect, re-registration, driver
changes, copied stale callbacks, cross-stream takeover, two mice holding the
same button, context replacement/ABA/freed contexts, and touchpad interception.
The existing nil/zero/one/two/extra side-button and ownership cases also run.

`--source-ref 30cc36b` compiles the previous production code and fails because a
forwarded GCMouse press is not visible to capture cleanup. After repair, the
same scenario observes a matching release while paused.

Already admitted button events stay ordered on inputQueue. Device teardown
pairs them with releases; capture/context epochs reject work invalidated by
uncapture or rebinding. This does not change mouse sensitivity, scrolling,
button mapping, controller policy, or the deferred automatic-address logic.

Real hardware capture/release and unplugging still need validation before a
stable promotion. Other pointer/controller fixtures stub the external GC
bookkeeping hooks; this suite executes their real implementation.
