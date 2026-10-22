# Stream startup callback regression

Run on macOS with the Xcode command-line tools:

```sh
python3 tests/stale-connection-start/run.py
EXTRA_CFLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' python3 tests/stale-connection-start/run.py
```

The fixture compiles the complete production scoped callback, `connectionStarted`,
input-stage completion, delayed binding and first-frame methods. It controls the
main queue and delayed queue independently; the external session, input and UI
objects record mutations. It does not open a stream, create an application window,
post input, access the clipboard or record microphone audio.

Coverage:

- Close/reconnect between callback dispatch and main-queue execution.
- Connection replacement even when the generation has not changed.
- Terminal/missing connection rejection before looking up the input context.
- Generation changes between the proxy's initial check and owner invocation.
- Input-stage completion after close/connection replacement/termination.
- Every startup continuation after invalidation: input retry, renderer callback,
  frame polling, clipboard binding, audio notice, display mode and recapture.
- Normal startup, delayed context initialization and bounded retry exhaustion.
- A microphone start queued before termination but executed after cleanup, and
  termination between microphone setup and its nested engine-start queue hop.

`microphone.py` independently compiles the production `ClConnectionTerminated`,
`startMicrophoneIfNeeded` and terminal-state accessor. Audio permission and engine
calls are fakes. A separate process runs this test as part of `run.py`.

Both failures can be reproduced against the original upstream revision:

```sh
python3 tests/stale-connection-start/run.py --source-ref 259307d
python3 tests/stale-connection-start/microphone.py --source-ref 259307d
```

Both commands must fail a behavioral assertion on that revision. These are queue
ordering regressions, not real network/audio stress tests. They do not establish
that every callback family or all simultaneous AVAudioEngine start/stop races are
safe. A Release build and a real connect/close/reconnect check remain necessary.
