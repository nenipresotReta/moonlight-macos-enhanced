# Database open failure regression

Run on macOS with Xcode Command Line Tools:

```sh
python3 tests/database-open-failure/run.py
```

The runner compiles the production `DatabaseSingleton` implementation and selected production `DataManager`/`IdManager` methods against Foundation and Core Data. It overrides only the test store URL/model, store-attachment failure injection, and ID generation. All SQLite fixtures live in a temporary directory owned by the runner, including on assertion failure. It never opens the user's Moonlight database.

Coverage:

- An injected access failure preserves the original SQLite, WAL, and SHM bytes. No coordinator or context is published without a persistent store.
- A missing model creates no database; a later access after a temporary failure performs a real retry.
- Twenty-four concurrent callers share one successfully initialized coordinator and context.
- Successful creation and saving still work with Core Data's concurrency assertions enabled.
- A real incompatible-model migration failure leaves the original host record readable using the original model.
- A `DataManager` instance remains usable after an open failure. Unavailable reads return empty/nil, writes are skipped, and later calls retry initialization.
- Unavailable storage does not generate transient client UUIDs. First-run generation and retrieval from a working store still work.

Fail-before check against the upstream baseline:

```sh
python3 tests/database-open-failure/run.py --source-ref 259307d
```

This intentionally fails the first assertion: the original implementation returns a cached coordinator with no stores after deleting the database. The incompatible-model test emits an expected Core Data migration error; its following `PASS` verifies the original record survived.

## Scope and remaining limits

This change preserves data and makes subsequent calls retry; it does not repair corruption, add a database-recovery UI, or automatically refresh already populated views after recovery. Operations skipped while the database is unavailable are logged and are not queued for replay. Core Data's existing automatic migration policy is unchanged.

`IdManager` returns nil when storage is unavailable. `HttpManager` already handles nil by using its historical shared session ID, and this patch leaves that network behavior unchanged. A separate change would be needed to prevent all pairing/discovery requests during a database outage. The tests do not exercise HTTP requests or the real application UI.
