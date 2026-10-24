# PostgreSQL module

Version0.2.0, Zig0.17.0 package exporting `postgres`. It builds with the Zig standard library.

From this directory:

```sh
zig build
zig build check test
zig build check test -Doptimize=ReleaseSafe
```

The default builds `zig-out/bin/postgres-probe`, a public-API consumer. Building
and offline tests open no database connections. Running the probe explicitly
uses `PGUSER`, `PGPASSWORD`, `PGDATABASE` and optional `PGHOST`/`PGPORT`; it executes
`BEGIN`, bound `SELECT $1::bigint`, `COMMIT`. Live authentication and cancellation regressions
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
It supports text simple/parameterized queries and trust/cleartext/SCRAM-SHA-256 authentication.
MD5 authentication is unsupported and returns `UnsupportedAuthType`.
It has no TLS/channel binding, DNS resolution beyond the
existing localhost/numeric-address support, or general retry policy. Startup
authentication payloads retain their 1024-byte bound; SASLprep and iteration CPU
budgets remain unsupported. Simple-query frames now validate lengths, row
descriptions, text cells, command/error terminators and ready status. Unsupported
protocol states invalidate the connection. Raw server message bytes are not
printed; diagnostics retain only owned SQLSTATE and the existing cached-query
signal. Error-response recovery has its own joined 500 ms bound. Normal successful
query/commit waiting has no cleanup timeout. Selected acceptance is recorded in
the development receipt; broader protocol and product acceptance remain separate.

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
PostgreSQL endpoint (optional `POSTGRES_TEST_PORT` for its owned relay), and
rejects unowned databases. Run one verifier per lease at
a time. The verifier owns its `pg_development_rows`/`pg3_values` tables, commit-delay
function and loopback peers;
the existing schema process owns database creation, migration and removal.

Set `client.limits` before queries or pass `.limits` in `PoolConfig`. SQL admission
fails before sending and preserves connection/transaction state. Response limit,
allocation, framing or incomplete-I/O failures invalidate the connection; pool
release discards it. The defaults are:

| Limit | Default |
| --- | --- |
| SQL text | 16 MiB |
| Whole message including tag/length | 16 MiB |
| One text cell | 8 MiB |
| Logical retained row/cell/command-tag bytes | 64 MiB |
| Rows across all results in a simple query | 100000 |
| Columns in one row set | 1024 |

The transient frame buffer and row-list spare capacity are additional bounded
allocations. SQL and message limits also respect the wire's signed length fields
even if configured higher. The materialized simple-query API continues to
concatenate rows from multiple statements and returns the last command tag.
An error returns no partial result, including a later failure after earlier
statements completed. Notices and parameter status are consumed without retaining
server message text. Binary-format results and COPY are explicitly unsupported.

`queryParams(sql, tuple)` binds a single statement using unnamed Parse/Bind/
Describe/Execute and exactly one Sync. SQL and values travel separately. The
server rejects multiple statements; semicolons inside literals/values work.
The API returns the same owned `PgResult` and waits through ReadyForQuery,
including implicit commit and deferred constraints. Parse/Bind/Execute/Sync errors
retain SQLSTATE. A synchronized error inside a transaction remains failed until
explicit rollback; Sync does not roll back that transaction. No request is replayed.

```zig
var result = try client.queryParams(
    "SELECT $1::text, $2::boolean",
    .{ "prospect's follow-up", true },
);
defer result.deinit();
```

Values admit null/typed null, bool, integers representable by signed bigint,
byte strings, `Uuid{ .bytes = [16]u8{...} }` and `Binary{ .bytes = bytes }`.
Binary binds bytea hex text, including zero bytes; ordinary text/SQL reject NUL.
Use explicit SQL casts for null/custom types, exact decimal and timestamp text.
Floats, general arrays and arbitrary structs are unsupported. Preflight checks
all types/counts/encoded lengths and allocates the complete request before I/O;
rejection leaves transaction state unchanged. Defaults:1024parameters and32MiB
for all encoded request bytes, configurable through `Limits`. Each wire length
also fits its signed field. Result format remains text.

`queryParamsOpts(sql, tuple, .{ .deadline = end })` accepts an optional absolute
`std.Io.Timestamp` from the awake clock. The operation deadline covers admission,
request write and the final validated ReadyForQuery. The convenience call imposes
no operation timeout. `queryOpts` provides the same bound for legacy SQL;
`const scope = client.withDeadline(end); defer scope.deinit();` bounds a sequence,
including explicit COMMIT. Nested scopes/options can only tighten the deadline.
Bounded in-memory admission finishes before its deadline is checked again.

Normal Execute/CommandComplete never starts a cleanup timer. A slow successful
commit may exceed500ms within the operation deadline. On observed server error,
cancellation or operation expiry, cleanup gets its separate absolute500ms bound;
partial reads/helpers cannot restart it. Error recovery can therefore outlast the
operation deadline by that allowance. Failed/incomplete recovery invalidates;
response loss during commit remains an unknown outcome. Rollback cleanup ignores
an expired normal scope and uses its own joined budget. All joined I/O tasks finish
before buffers/client ownership return to the caller.

`zig build build-wire-check` compiles an independent opt-in receipt checker for
the backend's framed protocol relay. It checks the real delayed commit and
Execute-success/Sync-failure sequence and rejects four receipt corruptions.


Accepted capability set for0.2.0 (PG0–PG3):

| Capability | Status |
| --- | --- |
| Numeric/localhost TCP; trust/password/SCRAM-SHA-256 | Supported |
| Owned text/null results, simple multi-statements | Supported |
| Single-statement bound scalar/UUID/bytea parameters | Supported |
| Transaction-aware pool release and bounded rollback | Supported |
| Query/sequence operation deadlines; separate error cleanup | Supported |
| DNS/TLS/general connect-pool-auth deadlines | Later consumer milestones |
| Streaming/column metadata/binary results/COPY | Outside this release |

Debug/ReleaseSafe driver and selected native note API/SQL checks use PostgreSQL16.13.
This records one tested server version. The [changelog](CHANGELOG.md) identifies
feature boundaries and the consumer rollback requirement. Pin the source archive with its package hash.
