# Fork maintenance

This fork prioritizes a dependable daily-use client. Upstream remains
https://github.com/skyhua0224/moonlight-macos-enhanced.

## Branches

- `stable`: default branch and daily-use baseline. Currently contains the verified
  Caps Lock, stream-window cleanup, and startup/retry fixes. Experimental mouse
  changes are excluded.
- `testing`: integration branch for candidate fixes, including free-mouse work.
  Passing automated tests alone does not qualify a candidate for `stable`.
- `fix/*`: focused changes for review and upstream pull requests. Keep these
  independent of fork-only documentation and unrelated fixes.
- `test/caps-lock-window-cleanup`: historical integration branch, retained as a
  reference. New integration work goes to `testing`.

## Promotion and upstream updates

1. Review the implementation and interactions with existing input/lifecycle paths.
2. Run the relevant regression suites and compile a Release build.
3. Verify the signed app and test the changed behavior on a real streaming session.
   Input changes also require dragging, buttons, capture/release, mode changes,
   and cross-display checks. Record hardware limits instead of implying coverage.
4. Merge reviewed, verified fixes into `stable`; keep experimental changes in
   `testing`. Merge `stable` into `testing` after stable-only updates.
5. Preserve commit history. Do not force-push shared branches or automatically
   merge upstream releases. Review upstream changes and dependencies before
   selectively integrating them through `testing`.

Use English Conventional Commit messages and focused English upstream PRs.
Keep app/configuration backups before local installation. Build products and
machine-specific settings do not belong in Git.

## Regression commands

Run on macOS with Xcode or Command Line Tools:

```sh
python3 tests/capslock/run.py
python3 tests/window-cleanup/run.py
python3 tests/startup-endpoint/run.py
# On testing when present:
python3 tests/free-mouse-motion/run.py
python3 tests/database-open-failure/run.py
python3 tests/stale-connection-start/run.py
python3 tests/usb-startup-timeout/run.py
```

The database suite uses temporary SQLite stores; the lifecycle and USB suites
use controlled callbacks and helper processes. These cover failure timing and
cleanup without touching the installed app, saved hosts, or physical devices.
Real stream reconnects, pointer behavior, and USB forwarding still require
manual validation before promotion.

Open upstream contributions: [Caps Lock #68](https://github.com/skyhua0224/moonlight-macos-enhanced/pull/68),
[window cleanup #69](https://github.com/skyhua0224/moonlight-macos-enhanced/pull/69),
[startup/retry #70](https://github.com/skyhua0224/moonlight-macos-enhanced/pull/70).
