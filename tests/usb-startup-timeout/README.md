# USB startup timeout and cancellation regressions

Run on macOS with Xcode's command-line tools:

```sh
python3 tests/usb-startup-timeout/run.py
SANITIZE=1 python3 tests/usb-startup-timeout/run.py
```

The fixture compiles the **entire production `RemoteUSBForwardingSession.m`**;
only the reverse tunnel is replaced with a controllable double. A compiled C
child stands in for `moonlight-usbd`. The Swift fixture compiles the unchanged
production ViewModel against host/UI/session doubles. An additional typecheck
imports the real Objective-C session header and requires warning-free main-actor
isolation using the project's Swift 5 language mode. No USB devices, network,
installed application, or saved settings are accessed. Compilation products and
helper executables live in a temporary directory.

Coverage includes:

- silent/partial stdout, split newline, EOF without final newline, and oversized
  lines using real pipes and the production reader;
- the real 12-second startup deadline with silent and partial-line child helpers;
- Stop while the worker queue is occupied and while READY is pending;
- replacement startup and an already queued main-thread READY completion;
- stderr flood, invalid output, and a helper that ignores SIGTERM;
- cancellation after enumeration has reached EOF but its helper has not exited;
- stale reverse-tunnel completion after a replacement has started, and tunnel
  deallocation with a retained completion;
- stale capability, enumeration, and forwarding callbacks in the ViewModel;
- Start disabled during host refresh so a previous host token cannot be reused.

The timeout integration cases run concurrently, so the suite takes roughly
12 seconds plus compilation. The sanitizer option instruments the Objective-C
session/fixture with AddressSanitizer and UndefinedBehaviorSanitizer.

To reproduce the original failure with the exact reader extracted from a Git
revision (this command **must fail**):

```sh
python3 tests/usb-startup-timeout/baseline.py 259307d
```

A pipe writer remains open without sending bytes. The original reader remains
blocked beyond five times its requested timeout; the fixture closes the pipe
before exiting so no blocked task is left behind.

These tests establish timeout, ordering, cancellation and child-process cleanup.
They do not establish real USB claim/release behavior or reverse-tunnel TLS/I/O
correctness. Physical forwarding remains a separate integration check.
