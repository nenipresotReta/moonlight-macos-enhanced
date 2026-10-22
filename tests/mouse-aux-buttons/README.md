# GCMouse auxiliary button regression

Run on macOS with Command Line Tools or Xcode:

```sh
python3 tests/mouse-aux-buttons/run.py
EXTRA_CFLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' python3 tests/mouse-aux-buttons/run.py
```

The runner extracts the actual `registerMouseCallbacks:` and
`unregisterMouseCallbacks:` methods and compiles them against Foundation-backed
mouse, button, scroll, and input-context doubles. It executes the installed
callbacks rather than inspecting source strings. It covers:

- A nil auxiliary array, and nonnil arrays containing zero through four buttons.
- Left/middle/right and X1/X2 press/release mappings, context identity, paused
  input, missing input context, and left/right touchpad interception.
- Movement and scroll callback forwarding, absent optional middle button/scroll,
  disabled-driver cleanup, complete cleanup including extra buttons, repeated
  cleanup, re-registration, and callback-owner lifetime.
- On branches containing the shared-device ownership guard: late cleanup from
  the previous stream preserves the current stream's callbacks and input context
  for every auxiliary button count. Use `--require-ownership` on `testing` to
  make this coverage mandatory.

To test another checkout without copying the harness:

```sh
python3 tests/mouse-aux-buttons/run.py --source-root /path/to/testing --require-ownership
```

To reproduce the original failure:

```sh
python3 tests/mouse-aux-buttons/run.py --source-ref 259307d
```

That revision terminates with `NSRangeException` when registration indexes the
empty auxiliary array. A nil array does not reproduce the fault because sending
`objectAtIndexedSubscript:` to nil returns nil.

No hardware, network session, or running application is touched. These tests do
not exercise GameController discovery, physical device delivery, display-link
scheduling, or scroll processing beyond the callback's existing forwarding
contract. Extra auxiliary buttons remain unmapped, matching existing behavior.
