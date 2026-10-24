# PostgreSQL module

Local Zig 0.17.0 package exporting `postgres`. It builds with the Zig standard library.

From this directory:

```sh
zig build
zig build check test
zig build check test -Doptimize=ReleaseSafe
```

The default builds `zig-out/bin/postgres-probe`, a public-API consumer. Building
and offline tests open no database connections. Running the probe explicitly
uses `PGUSER`, `PGPASSWORD`, `PGDATABASE` and optional `PGHOST`/`PGPORT`; it executes
`BEGIN`, `SELECT 1`, `COMMIT`. Live authentication and cancellation regressions
remain owned by the backend fixtures.

Consumers add a `postgres` path dependency on this directory and import
`b.dependency("postgres", .{ .target = target, .optimize = optimize }).module("postgres")`.
The public root exports `PgClient`, `PgError`, `PgRow`, `PgResult`, `Pool`,
`PoolConfig`, `Transaction` and the `client`, `pool`, `scram`, `diagnostic`,
`cancel`, `transaction` namespaces. Backend compatibility adapters re-export
these declarations; they do not introduce distinct client or transaction types.

Client/result allocations belong to their supplied allocator. Destroy results
with `deinit`, close directly owned clients with `close`, and release or discard
pool borrowers before destroying the pool. Pool configuration strings outlive
the pool. Cancellation invalidates an incomplete connection exchange; pool
release automatically discards non-reusable clients and sessions still inside
an open or failed transaction. `transaction_status` records the last validated
ReadyForQuery state; an incomplete exchange is unknown. Explicit `discard` also
invalidates a borrower. Transaction cleanup rolls back an uncommitted reusable
client under one joined 500 ms budget, including an already-canceled caller. A
failed or expired cleanup invalidates the connection. A lost COMMIT response
remains ambiguous; successful commit waiting does not use the cleanup timeout.

This is the existing bounded wire-v3 client, not a complete PostgreSQL driver.
It supports text simple queries and trust/cleartext/SCRAM-SHA-256 authentication.
MD5 authentication is unsupported and returns `UnsupportedAuthType`.
It has no parameter binding, TLS/channel binding, DNS resolution beyond the
existing localhost/numeric-address support, or general retry policy. Startup
authentication payloads retain their 1024-byte bound; SASLprep, iteration CPU
budgets and broader malformed query-frame acceptance remain unproved. Packaging
adds no new protocol or production acceptance.

Application SQL, schemas, repositories, startup policy, after-commit effects and
disposable database ownership remain outside this package.

`query` fully consumes the response and allocates owned text/null cells. Results
remain valid across subsequent queries until `deinit`; the current row API has
no column metadata. Pool destruction requires all borrowers to have returned.
Borrowers that change session settings, create temporary objects or hold session
advisory locks must restore their state or call `Pool.discard`. The pool does not
perform a full session reset. Current development evidence and remaining driver
gaps are recorded in the [development receipt](../../scripts/postgres_development.md).

`zig build build-live` compiles `zig-out/bin/postgres-verify` without executing it.
The opt-in verifier requires `POSTGRES_TEST_DATABASE` from the backend's existing
disposable schema lease and `POSTGRES_TEST_REPORT` for its JSON report. It checks
the exact database ownership marker before writes, uses the local acceptance
PostgreSQL endpoint, and rejects unowned databases. Run one verifier per lease at
a time. The verifier owns only its `pg_development_rows` table and loopback peers;
the existing schema process owns database creation, migration and removal.
