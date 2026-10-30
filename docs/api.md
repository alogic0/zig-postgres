# API and ownership guide

See the [README](../README.md) for installation and a complete runnable example.

## Ownership and protocol support

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

The bounded wire-v3 client supports text simple/parameterized queries and
trust/cleartext/SCRAM-SHA-256 authentication.
MD5 authentication is unsupported and returns `UnsupportedAuthType`.
Optional verified TLS is described below. Channel binding and automatic retries
remain unsupported. Hostname resolution and bounded connection/acquisition options
are supported. Startup authentication payloads retain their 1024-byte bound;
SASLprep remains unsupported. SCRAM iterations are capped before PBKDF2.
Simple-query frames validate lengths, row
descriptions, text cells, command/error terminators and ready status. Unsupported
protocol states invalidate the connection. Raw server message bytes are not
printed; diagnostics retain only owned SQLSTATE and the existing cached-query
signal. Error-response recovery has its own joined 500 ms bound. Normal successful
query/commit waiting has no cleanup timeout. The supported fixture tuple is
covered by the standalone live suite.

Application SQL, schemas, repositories, startup policy, after-commit effects and
disposable database ownership remain outside this package.

`query` fully consumes the response and allocates owned text/null cells. Results
remain valid across subsequent queries until `deinit`; the current row API has
no column metadata. Pool destruction requires all borrowers to have returned.
Borrowers that change session settings, create temporary objects or hold session
advisory locks must restore their state or call `Pool.discard`. The pool does not
perform a full session reset.

## Query limits and parameters

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
rejection leaves transaction state unchanged. Defaults: 1024 parameters and 32 MiB
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
commit may exceed 500 ms within the operation deadline. On observed server error,
cancellation or operation expiry, cleanup gets its separate absolute 500 ms bound;
partial reads/helpers cannot restart it. Error recovery can therefore outlast the
operation deadline by that allowance. Failed/incomplete recovery invalidates;
response loss during commit remains an unknown outcome. Rollback cleanup ignores
an expired normal scope and uses its own joined budget. All joined I/O tasks finish
before buffers/client ownership return to the caller.

## Connections and TLS

Connection options include `PgClient.connectOpts(allocator, io, options)`
and `Pool.acquireOpts(options)`. Supply an absolute awake-clock `deadline` for
one budget across DNS resolution, TCP connect and authentication, or across pool
mutex/wait/connect/authentication. Positional `connect` and plain `acquire` remain
caller-cancelable compatibility wrappers without an imposed timeout. Pool config
can set `connect_timeout_ms` for every newly opened slot; a caller acquisition
deadline can only shorten it. Connection options/credentials remain borrowed
until connect returns; PoolConfig strings outlive the pool.

Hostnames use Zig 0.17's resolver; numeric IPv4/IPv6 bypass DNS. Resolved addresses
are attempted in resolver order within the same budget. The selected remote
address is retained explicitly for CancelRequest, since Zig's socket address is
local. No write is automatically retried. Startup failures join work and free
sockets/allocations; an unsuccessful acquisition returns its reserved slot.

`max_scram_iterations` defaults to 100000, configurable from 1 through 1000000.
Server iterations above the selected cap fail before PBKDF2; the absolute upper
bound prevents arbitrarily expensive configured work. Derivation is synchronous
and finite; deadlines do not preempt individual crypto instructions. ASCII proof/
nonce behavior is preserved; this does not add SASLprep or channel binding.
Successful operation/commit deadlines remain separate from 500 ms cleanup.

Optional verified TLS uses `-Dtls=true` when building this package or
`.tls = true` in the dependency arguments. TLS builds link libc and dynamically
load `libssl.so.3`;
plaintext builds require neither OpenSSL nor libc for the driver. The supported
fixture tuple is Linux, Zig 0.17.0, OpenSSL 3.0.13 and PostgreSQL 16.13. Other platforms,
OpenSSL versions and server versions have no acceptance claim here.

`connectOpts` defaults to `.tls.mode = .verify_full`. TLS-disabled builds reject
that configuration with `TlsUnavailable` before any network or authentication.
Legacy positional `connect` and `PoolConfig` retain explicit plaintext defaults;
set `.tls = .{ .ca_file = "/path/to/ca.pem" }` on the pool to require TLS.
The default CA file is `/etc/ssl/certs/ca-certificates.crt`, bounded to 4 MiB.
`server_name` optionally separates the verified DNS/IP identity from the network
host. DNS identities also supply SNI; IP identities use IP certificate matching.
Chain/identity verification and a TLS 1.2 minimum are mandatory. TLS refusal,
bad certificates and failed handshakes never fall back to plaintext.

OpenSSL memory BIOs do CPU work while Zig owns all socket reads/writes and their
joined absolute deadlines. Handshake, queries and encrypted CancelRequest obey
the same operation/cleanup budgets as plaintext. CancelRequest uses a separate
verified encrypted connection. Closing a client sends Terminate within 500 ms and
then frees its socket/session without a blocking TLS shutdown. SSL/CTX/BIO
resources have per-owner destruction; the loaded library remains process-owned.

## Streaming

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
waiting; failures use the same joined 500 ms recovery budget. Closing or losing
an unfinished write leaves its outcome unknown; discarding
does not prove rollback. No request is replayed.

StreamOptions.max_buffer_bytes defaults to 32 MiB for one frame payload, column
views and the retained command tag. Normal message/cell/column/row/SQL/request
limits still apply; max_result_bytes applies only to materialized results.
The driver retains no accumulated row contents. The client I/O buffers, iterator
object and input request are additional bounded allocations. Existing text/null
values support text and SQL NULL; binary codecs and column metadata are unsupported.

## Checked rows

Use `row.getChecked(index)` for bounded nullable text, or
`row.getTyped(T, index)` for `[]const u8`, `bool`, integer or floating types.
Use `?T` for SQL NULL; required NULL raises `UnexpectedNull`. Empty text stays
empty; it is invalid as a boolean or number. Booleans accept exactly `t`/`f`.
Integer overflow, invalid values and column bounds are errors. Floating getters
accept PostgreSQL's `NaN`, `Infinity`, `-Infinity`; a finite decimal overflowing
the destination type is an error. This differs from finite-only binding.

Both PgRow and BorrowedRow share conversion. Borrowed getters check generation
before even checking bounds; strings expire on advancement/close and must be
copied to outlive the stream. The iterator itself must still be alive when a row
is accessed. `get`, `getInt`, `getBool` retain their permissive 0.3 behavior for
compatibility and are deprecated. Removal/signature changes are scheduled for
a breaking 0.4 release.

```zig
const id = try result.rows[0].getTyped(i64, 0);
const flag = try result.rows[0].getTyped(?bool, 1);
const text = try borrowed.getTyped([]const u8, 2); // until next()/close()
```

## Standalone live acceptance

`zig build ci -j4 --summary all` remains offline (loopback peers, no Docker or
PostgreSQL). `zig build test-live -j4` is opt-in and requires Linux/amd64, Docker,
Zig 0.17.0 and, for `-Dtls=true`, the OpenSSL 3 runtime and `openssl` CLI. Repeat
with `-Doptimize=safe`, `-Dtls=true`, and both. No application repository, schema
lease or existing application database is used. Zig fetches the verification
helper pinned in `build.zig.zon`.

The owner uses the digest-pinned PostgreSQL 16 image in `examples/live_fixture.zig`
and a dynamically published loopback port. A random exact label guards its named container/volume;
its database has a separate marker. Cleanup is registered before startup and
removes only these exact identities and its marked private certificate/work
directory. Reports are retained outputs, not temporary fixture resources.

Default limits are pull 180 s, command/certificate 30 s, startup 60 s, each case-group 30 s
(a stronger bound for every case within it), tests 300 s, whole run 600 s and
independent cleanup 30 s. Every command/poll uses its phase's remaining budget.
Driver operation/cleanup deadlines remain separate. SIGINT/SIGTERM cancel and
join work/subprocess groups before cleanup. Cleanup failure fails the run and
reports exact owner/container/volume/directory IDs for recovery; it is never
reported as successful cleanup. CI's explicit manual live job allows compilation
plus run/cleanup and uses the same four settings.

Set `POSTGRES_LIVE_REPORT` for a fresh report outside build outputs; otherwise it
uses `zig-out/live-<mode>-<plain|tls>.json`. Finite positive `u32` millisecond
overrides are `POSTGRES_LIVE_{PULL,COMMAND,STARTUP,CASE,TEST,RUN,CLEANUP}_MS` and are
recorded in each report. `test-live-controls` verifies failed startup, a controlled
stalled Docker-command boundary, hung case, outer timeout, failed cleanup with
exact-marker recovery and cooperative INT/TERM. Test-only controls use private
synthetic subprocesses; they never stop the host Docker daemon.

Reports contain package/compiler/server/OpenSSL identity, image digest/ID/platform,
settings/deadlines, generic protocol/parameter/transaction/network/stream/TLS and
checked-row results, resource IDs and cleanup. Pure driver heap measurements
(streaming 500 rows / 73.7 MB) are distinct from process peak RSS. The legacy
verifier and measurement tool read `PGUSER` and `PGPASSWORD` and check the
database comment before writing. The default comment is
`zig-postgres disposable schema fixture <database>`. For an existing fixture,
set `POSTGRES_TEST_MARKER` to the exact comment supplied by its creator.

## Bounded health

`try pool.healthCheckOpts(.{ .deadline = absolute_awake_timestamp })` gives one
budget to acquisition/connect/SELECT 1 and releases or discards the borrower on
every exit. Query recovery retains its separate joined cleanup allowance, so
return can follow the operation deadline by that bounded cleanup interval.
Timeout/cancellation are errors for the caller to map to its health response.
`healthCheck()` remains an unbounded compatibility wrapper returning false on
errors; use the bounded API for service endpoints. Waiting for acquisition never
renews the SELECT budget.

## Common helpers

`ParsedUri.parse(allocator, text)` (or `fromUri(allocator, std.Uri)`) owns every
configuration string until `deinit`; input can be freed immediately. It accepts
postgres/postgresql, percent encoding, IPv4/IPv6, default port 5432 and supported
TLS options (`sslmode=disable|verify-full`, `sslrootcert`, `sslservername`).
Malformed escapes, NUL, duplicate/unknown options and unsupported security modes
fail before network use. Application pool size, deadlines and retry policy remain
caller choices; keep the parsed owner alive until the pool is destroyed.

Bind `try finiteFloat(number)` for finite f64 values, including negative zero,
using round-trip-safe text. NaN/infinity and bypassed invalid wrappers fail during
request admission before any exchange. Exact decimals should remain decimal text
with explicit SQL casts, not be converted through f64. Raw floats remain unsupported.

`PgResult.commandCount()` and `commandCount(tag)` return `!?u64` for exactly
`INSERT 0 N`, UPDATE, DELETE, MERGE, SELECT, MOVE, FETCH and COPY count tags. They read
only the final CommandComplete tag, never sum counts or infer from result rows.
Zero is a count; empty/other commands return null; malformed recognized tags or
overflow fail. SELECT/FETCH counts describe returned rows, not modified rows;
COPY tag recognition does not implement the COPY streaming protocol.
`PgStream.commandCount()` requires validated ReadyForQuery (`IncompleteResult`
before completion, `DatabaseError` after server failure). Provisional tags cannot
turn a later statement or deferred commit failure into success.

`queryRow[Opts]` / `queryRowParams[Opts]` return an optional owned PgRow: zero rows
is null, one row transfers ownership to the caller (`row.deinit()`), multiple rows
is `TooManyRows`. They finish protocol/error processing before returning.
`PgResult.takeOne()` consumes the result on every exit, leaving it safe to deinit.
`stream.singleRow(allocator)` copies the first row, drains through ReadyForQuery,
and applies the same cardinality rule; late database errors take precedence.
The caller still owns and must deinit the iterator and release its connection.
Allocation failure invalidates the stream so release discards the connection.

## Pool statistics

`const snapshot = pool.stats();` returns a synchronized `PoolStats` containing
only numbers. `idle + borrowed + connecting + empty == capacity` at that instant.
Connected checked-out slots are borrowed; reserved slots still authenticating
are connecting. Waiters counts condition-variable waits, excluding mutex entry
and connection attempts; cancellation removes the waiter before returning.

Saturating u64 lifetime counters are `initial_connections` (first successful
connection for each slot), `reconnects` (successful replacements after discard),
`connection_failures` (failed/canceled establishment attempts, including initial
attempts on lazy pools) and `discards` (explicit or unsafe-release destruction).
A canceled pool waiter is not a connection failure. Failed eager initialization
returns no pool/snapshot. Snapshot/counter synchronization performs no network I/O;
connect/disconnect happen outside the lock. Join all borrowers/waiters before
pool deinit. Gauges expose no credentials, SQL, parameters or customer values.
