# zig-postgres

A PostgreSQL wire protocol v3 client for Zig 0.17.0, with connection pooling,
bound parameters, transactions, streaming rows, and optional verified TLS.
The runtime is written in Zig and has no third-party Zig dependencies.

The package version is **0.3.0**. Changes since that release are listed under
[Unreleased](CHANGELOG.md). The supported test platform is Linux x86_64 with
PostgreSQL 16.13; TLS uses the system OpenSSL 3 runtime. Other platforms and
server versions have not been validated.

| Feature | Behavior |
| --- | --- |
| Queries | Owned text/null results and single-statement bound parameters |
| Pooling | Concurrent acquisition, bounded health checks, numeric statistics |
| Transactions | Validated session state and bounded rollback cleanup |
| Deadlines | Absolute connection, authentication, acquisition, and query budgets |
| Addresses | DNS, IPv4, and IPv6 |
| TLS | Optional CA and hostname/IP verification, encrypted cancellation |
| Streaming | Borrowed rows, checked lifetimes, and explicit owned copies |
| Helpers | URI parsing, checked scalar decoding, command counts, optional single rows |

## Build and test

Install the compiler version in [`.zigversion`](.zigversion) from
[Zig's downloads](https://ziglang.org/download/), then run:

```sh
zig build
zig build check test
zig build check test -Doptimize=safe
zig build ci -j4 --summary all
zig build check-package -j4 --summary all
```

The default build produces `zig-out/bin/postgres-probe`. Building it does not
connect to a database. `ci` checks formatting, runs offline tests (including
loopback protocol peers), and compiles the public examples and live fixtures in
Debug and Safe, with TLS enabled and disabled. It requires no running PostgreSQL
or Docker daemon. The first build fetches the verification dependency pinned in
`build.zig.zon`. GitHub Actions runs CI on pushes and pull requests.
`check-package` archives the current package paths and compiles the README example
from that archive with fresh caches in all four settings.

The [probe](examples/probe.zig) is a complete public-API example. To run it against
a local disposable database, provide `PGUSER`, `PGPASSWORD`, and `PGDATABASE`,
with optional `PGHOST` and `PGPORT`. It uses plaintext, bound SELECT queries,
streaming, and an explicit transaction.

## Install

For a local checkout, add this entry to your `build.zig.zon` dependencies:

```zig
.postgres = .{ .path = "../zig-postgres" },
```

After the repository is published, fetch an immutable commit archive with
`zig fetch --save=postgres <archive-url>` to record its URL and content hash.
For GitHub, the archive URL has the form
`https://github.com/<owner>/zig-postgres/archive/<full-commit-sha>.tar.gz`.
Use a commit or release tag when selecting a version.

In your `build.zig`, add the module to your executable:

```zig
const postgres = b.dependency("postgres", .{
    .target = target,
    .optimize = optimize,
    // .tls = true, // Enable verified TLS support.
});
exe.root_module.addImport("postgres", postgres.module("postgres"));
```

A small application can acquire a connection and read a bound query:

```zig
const std = @import("std");
const pg = @import("postgres");

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    const pool = try pg.Pool.initLazy(init.gpa, init.io, .{
        .host = env.get("PGHOST") orelse "127.0.0.1",
        .port = try std.fmt.parseInt(u16, env.get("PGPORT") orelse "5432", 10),
        .user = env.get("PGUSER") orelse return error.PGUSERRequired,
        .password = env.get("PGPASSWORD") orelse return error.PGPASSWORDRequired,
        .database = env.get("PGDATABASE") orelse return error.PGDATABASERequired,
        .size = 4,
        .connect_timeout_ms = 5000,
    });
    defer pool.deinit();

    const end = std.Io.Timestamp.now(init.io, .awake)
        .addDuration(.fromMilliseconds(5000));
    const client = try pool.acquireOpts(.{ .deadline = end });
    defer pool.release(client);

    var result = try client.queryParamsOpts(
        "SELECT $1::bigint, $2::text",
        .{ @as(i64, 42), "hello" },
        .{ .deadline = end },
    );
    defer result.deinit();

    const id = try result.rows[0].getTyped(i64, 0);
    const text = try result.rows[0].getTyped([]const u8, 1);
    std.debug.print("{d}: {s}\n", .{ id, text });
}
```

This example uses plaintext for a local database. To require TLS, build the
dependency with `.tls = true` and set the pool's
`.tls = .{ .ca_file = "/path/to/ca.pem" }`. TLS builds link libc and dynamically
load `libssl.so.3`; the plaintext runtime needs neither. TLS verification failures
never fall back to plaintext. `ConnectOptions` defaults to verified TLS, whereas
`PoolConfig` and the legacy positional `connect` default to plaintext.

## Ownership and limitations

Destroy owned results with `deinit`, close directly owned clients with `close`,
and release or discard pool borrowers before destroying the pool. Configuration
strings must outlive their pool. Each client permits one query or stream at a time.
Borrowed streaming values expire when the iterator advances or closes; copy them
when they must live longer. A stream is successful only after it reaches the
final validated ReadyForQuery message.

The driver supports trust, cleartext password, and SCRAM-SHA-256 authentication.
MD5, SASLprep, channel binding, COPY, binary result formats, and column metadata
are unsupported. There are no automatic retries. A lost COMMIT response leaves
its outcome unknown. Borrowers must restore changed session settings or discard
the connection; the pool does not perform a full session reset.

See the [API and ownership guide](docs/api.md) for query limits, deadline and
cleanup behavior, streaming contracts, TLS options, decoding, and helper APIs.

## Live PostgreSQL acceptance

The standalone suite creates and removes its own digest-pinned PostgreSQL 16
Docker container, volume, database, and local TLS certificates. It does not use
an existing application database. Linux/amd64 and Docker are required; TLS cases
also require OpenSSL 3 and the `openssl` CLI.

```sh
zig build test-live -j4
zig build test-live -Doptimize=safe -j4
zig build test-live -Dtls=true -j4
zig build test-live -Doptimize=safe -Dtls=true -j4
zig build test-live-controls -j4
```

Reports are written to `zig-out/live-*.json` and include test results, fixture
identity, deadlines, and cleanup status. The **PostgreSQL live acceptance**
workflow runs this suite when manually dispatched from GitHub Actions.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and
[the release guide](docs/releasing.md) for publishing a pinned package archive.
Historical implementation notes are in [the improvement plan](docs/plans/2026-10-25.md).

Licensed under the [MIT License](LICENSE), copyright zig-postgres developers.
