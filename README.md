# zig-postgres

Version 0.3.0, Zig 0.17.0 package exporting `postgres`. It builds with the Zig standard library.

The [improvement plan](docs/plans/2026-10-25.md) tracks pool availability, strict
row decoding, standalone live acceptance, bounded health checks, common helpers
and pool statistics.

The accepted capability set is PG0–PG5 with PG6 release gates. Tested with
Zig0.17.0, PostgreSQL16.13 and Linux x86_64; TLS additionally uses OpenSSL3.0.13.

| Capability | Delivered behavior |
| --- | --- |
| Transactions/pool | Validated ready state; busy/failed/open sessions discarded; joined500ms cleanup |
| Queries | Bounded owned text/null results; single-statement bound parameters |
| Deadlines | Absolute connect/auth/acquire/query/commit bounds; cleanup has its own budget |
| Addresses | DNS, IPv4 and IPv6; selected remote endpoint retained for cancellation |
| TLS | Optional verified CA/DNS/IP identity; encrypted cancellation; no fallback |
| Streaming | Separate iterators, expiring views, explicit copies and safe abandoned-stream release |
| Parameters | Null, bool, bigint-compatible integers, text, UUID and bytea hex |
| Retry/session state | Caller owns retry decisions and session restoration; unknown commits stay unknown |

From this directory:

```sh
zig build
zig build check test
zig build check test -Doptimize=ReleaseSafe
zig build ci --summary all
```

The default builds `zig-out/bin/postgres-probe`, a public-API consumer. Building
and offline tests open no database connections. Running the probe explicitly
uses `PGUSER`, `PGPASSWORD`, `PGDATABASE` and optional `PGHOST`/`PGPORT`; it executes
`BEGIN`, bound `SELECT $1::bigint`, `COMMIT`. Live authentication and cancellation regressions
remain owned by the backend fixtures.

Consumers add a `postgres` dependency pointing to this checkout, for example
`.postgres = .{ .path = "../zig-postgres" }` in `build.zig.zon`, and import
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
Optional verified TLS is described below. Channel binding and automatic retries
remain unsupported. PG4A adds hostname resolution and bounded connection/
acquisition options. Startup authentication payloads retain their 1024-byte bound;
SASLprep remains unsupported. SCRAM iterations are capped before PBKDF2. Simple-query frames now validate lengths, row
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
perform a full session reset.

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

Unreleased PG4A connection options add `PgClient.connectOpts(allocator, io, options)`
and `Pool.acquireOpts(options)`. Supply an absolute awake-clock `deadline` for
one budget across DNS resolution, TCP connect and authentication, or across pool
mutex/wait/connect/authentication. Positional `connect` and plain `acquire` remain
caller-cancelable compatibility wrappers without an imposed timeout. Pool config
can set `connect_timeout_ms` for every newly opened slot; a caller acquisition
deadline can only shorten it. Connection options/credentials remain borrowed
until connect returns; PoolConfig strings outlive the pool.

Hostnames use Zig0.17's resolver; numeric IPv4/IPv6 bypass DNS. Resolved addresses
are attempted in resolver order within the same budget. The selected remote
address is retained explicitly for CancelRequest, since Zig's socket address is
local. No write is automatically retried. Startup failures join work and free
sockets/allocations; an unsuccessful acquisition returns its reserved slot.

`max_scram_iterations` defaults to100000, configurable from1through1000000.
Server iterations above the selected cap fail before PBKDF2; the absolute upper
bound prevents arbitrarily expensive configured work. Derivation is synchronous
and finite; deadlines do not preempt individual crypto instructions. ASCII proof/
nonce behavior is preserved; this does not add SASLprep or channel binding.
Successful operation/commit deadlines remain separate from500ms cleanup.

Optional verified TLS (PG4B) uses `-Dtls=true` when building this package or
`.tls = true` in the dependency arguments. TLS builds link libc and dynamically load `libssl.so.3`;
plaintext builds require neither OpenSSL nor libc for the driver. The supported
fixture tuple is Linux, Zig0.17.0, OpenSSL3.0.13 and PostgreSQL16.13. Other platforms,
OpenSSL versions and server versions have no acceptance claim here.

`connectOpts` defaults to `.tls.mode = .verify_full`. TLS-disabled builds reject
that configuration with `TlsUnavailable` before any network or authentication.
Legacy positional `connect` and `PoolConfig` retain explicit plaintext defaults;
set `.tls = .{ .ca_file = "/path/to/ca.pem" }` on the pool to require TLS.
The default CA file is `/etc/ssl/certs/ca-certificates.crt`, bounded to4MiB.
`server_name` optionally separates the verified DNS/IP identity from the network
host. DNS identities also supply SNI; IP identities use IP certificate matching.
Chain/identity verification and a TLS1.2 minimum are mandatory. TLS refusal,
bad certificates and failed handshakes never fall back to plaintext.

OpenSSL memory BIOs do CPU work while Zig owns all socket reads/writes and their
joined absolute deadlines. Handshake, queries and encrypted CancelRequest obey
the same operation/cleanup budgets as plaintext. CancelRequest uses a separate
verified encrypted connection. Closing a client sends Terminate within500ms and
then frees its socket/session without a blocking TLS shutdown. SSL/CTX/BIO
resources have per-owner destruction; the loaded library remains process-owned.

`zig build build-tls-certs` builds an opt-in local certificate adapter; it accepts
only an absolute `zg-postgres-tls-*` directory and uses the installed OpenSSL CLI.
The TLS-enabled live verifier additionally requires `POSTGRES_TEST_TLS_CERTS`
pointing to that generated fixture. It exercises trusted DNS/IP identities,
negative certificate/handshake cases, encrypted cancellation, rollback and a
real committed write whose acknowledgement is lost. No production endpoint is
required. Client certificates and SCRAM-SHA-256-PLUS remain separately scoped.

`streamQuery(sql, options)` and `streamParams(sql, tuple, options)` return an owned
`*PgStream`. Call `deinit` exactly once. These are separate from the unchanged
materialized APIs. A client has one SQL owner: other queries/streams return
`ConnectionBusy` until completion or invalidation. Clients are not safe for
concurrent calls; cancel and join a reading task before releasing its borrower.

```zig
const rows = try client.streamParams("SELECT $1::text", .{"follow-up"}, .{});
defer rows.deinit();
while (try rows.next()) |row| {
    const value = (try row.get(0)).?; // valid until next/close/client destruction
    _ = value;
    var saved = try row.copy(allocator);
    defer saved.deinit(); // owned cells may outlive the iterator
}
```

A borrowed row requires its iterator to remain alive. `get`/`copy` return
`StaleRow` after advancing, closing or client destruction. Previously extracted
slices cannot check their own lifetime. The iterator owns frame/view/tag buffers
independently of the client: releasing an unfinished borrower discards that client,
and the iterator may then safely be destroyed (or `next` returns `StreamClosed`).
Its allocator must outlive it. Early `close` invalidates; neither close nor deinit
reads/drains/writes the network. Release/discard/close the client to close its
socket. Unfinished transaction cleanup also invalidates an active stream.

Rows are provisional until `next` returns null after validated ReadyForQuery.
Execute/CommandComplete is insufficient: a later Sync/deferred-constraint error
returns failure with SQLSTATE, even after rows were yielded. Synchronized errors
permit subsequent queries outside a transaction; failed transactions still need
rollback. Operation deadlines are absolute across all next calls and final commit
waiting; failures use the same joined500ms recovery budget. Closing or losing an unfinished write leaves its outcome unknown; discarding
does not prove rollback. No request is replayed.

StreamOptions.max_buffer_bytes defaults to32MiB for one frame payload, column
views and the retained command tag. Normal message/cell/column/row/SQL/request
limits still apply; max_result_bytes applies only to materialized results.
The driver retains no accumulated row contents. The client I/O buffers, iterator
object and input request are additional bounded allocations. Existing text/null
values support the selected CSV consumer; binary codecs and column metadata
remain outside this release's consumer requirements.

`zig build build-measure` compiles an opt-in frozen500-row/144KiB JSON-page
comparison. It requires the same owned database/report variables as the verifier.
The old default64MiB materialized limit fails; a128MiB comparison completes and
has the same ordered digest as streaming. Logical driver heap is 181114bytes (about177KiB);
the backend's actual CSV projection measures about1.43MB, below its declared5MiB
budget for that workload. Allocator metadata/shared I/O/HTTP/kernel/OpenSSL/server
memory are excluded; this is not process RSS or a universal bound for arbitrary
payloads/observations. The CSV owner stages a single streamed page in an immediately unlinked0600
temporary file (128MiB maximum per page), gathers phone keys and loads saved
observations, then releases its read transaction/slot before projecting CSV.
One row arena bounds output heap. Configured import temporary-directory candidates
select scratch storage; close/process exit removes the unlinked file. This preserves
snapshot/coercion behavior and SQL release under HTTP backpressure. Throughput and
scratch bytes are reported separately; no speedup is claimed.

`zig build ci` is the offline CI entrypoint. It checks formatting and compiles
public, live-verifier, measurement, wire-check and certificate-adapter consumers
in Debug/ReleaseSafe with TLS enabled/disabled; it runs32offline tests. Live
fixtures are compiled, never executed by CI. The same command works in a hosted
runner with the pinned toolchain; this local checkout has no configured remote
CI service, and the retained release receipt records local execution.

A local release archive is reproducible from its exact commit:

```sh
git archive --format=tar --prefix=postgres-0.3.0/ HEAD | gzip -n > postgres-0.3.0.tar.gz
zig fetch file:/absolute/path/postgres-0.3.0.tar.gz
```

Use the returned content hash in a dependency with that archive URL. Release
evidence builds independent consumers with initially empty caches in all four
profile/TLS combinations.

Returning a consumer to0.2.0 requires reverting streaming/export admission,
PG4A note-acquisition options and PG4B build/fixture options with the package pin.
The new APIs are absent from0.2.0. Revert those consumer commits in reverse order;
no database schema downgrade is needed. Borrower/row ownership, bounded cleanup
and uncertain-commit policy must remain consistent during a rollback.
