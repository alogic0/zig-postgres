//! Real encrypted SQL, independent TLS relay, identity and recovery boundaries.
const std = @import("std");
const pg = @import("postgres");
const F = @import("tls_fixture");
const Io = std.Io;
const A = std.mem.Allocator;
fn require(ok: bool) !void {
    if (!ok) return error.TlsCaseFailed;
}
fn end(io: Io, ms: u32) Io.Timestamp {
    return Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(ms));
}
fn execute(c: *pg.PgClient, sql: []const u8) !void {
    var r = try c.query(sql);
    r.deinit();
}
fn integer(c: *pg.PgClient, sql: []const u8) !i64 {
    var r = try c.query(sql);
    defer r.deinit();
    return (try r.rows[0].getTyped(?i64, 0)).?;
}
var attempted = std.atomic.Value(usize).init(0);
fn forbiddenConnect(_: ?*anyopaque, _: *const Io.net.IpAddress, _: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
    _ = attempted.fetchAdd(1, .monotonic);
    return error.ConnectionRefused;
}
pub const Outcome = struct { enabled: bool, groups: usize, openssl: []const u8 = "disabled", encrypted_cancel_requests: usize = 0, rollback_ms: i64 = 0, unknown_commit_rows: i64 = 0, disabled_connect_attempts: usize = 0, allocation_failures: usize = 0 };
fn options(config: pg.PoolConfig, relay: *F.Relay, ca: []const u8) pg.ConnectOptions {
    return .{ .host = "localhost", .port = relay.port(), .user = config.user, .password = config.password, .database = config.database, .deadline = end(relay.io, 3000), .tls = .{ .ca_file = ca } };
}
fn queryCanceled(c: *pg.PgClient) !void {
    if (c.query("SELECT pg_sleep(60)")) |v| {
        var r = v;
        r.deinit();
        return error.ExpectedCanceled;
    } else |err| try require(err == error.Canceled);
}
fn negative(a: A, io: Io, config: pg.PoolConfig, fixture: F.Options, name: ?[]const u8, ca: []const u8, expected: anyerror, cancel: bool) !void {
    var relay = try F.Relay.init(a, io, fixture);
    defer relay.stop();
    try relay.start();
    var opt = options(config, &relay, ca);
    opt.tls.server_name = name;
    opt.deadline = end(io, 100);
    if (cancel) {
        opt.deadline = end(io, 3000);
        const Work = struct {
            fn run(allocator: A, work_io: Io, work_opt: pg.ConnectOptions) !void {
                if (pg.PgClient.connectOpts(allocator, work_io, work_opt)) |c| {
                    c.close();
                    return error.ExpectedCanceled;
                } else |err| try require(err == error.Canceled);
            }
        };
        var task = try io.concurrent(Work.run, .{ a, io, opt });
        defer task.cancel(io) catch {};
        while (relay.ssl_requests.load(.acquire) == 0) try io.sleep(.fromMilliseconds(1), .awake);
        try task.cancel(io);
    } else {
        if (pg.PgClient.connectOpts(a, io, opt)) |c| {
            c.close();
            return error.ExpectedTlsFailure;
        } else |err| try require(err == expected or (expected == error.EndOfStream and err == error.TlsVerificationOrProtocolError));
    }
    try require(relay.startups.load(.acquire) == 0 and relay.connections.load(.acquire) == 1 and !relay.failed.load(.acquire));
}
pub fn run(a: A, io: Io, config: pg.PoolConfig, env: anytype) !Outcome {
    if (comptime !pg.tls_enabled) {
        var table = io.vtable.*;
        table.netConnectIp = forbiddenConnect;
        var guard = io;
        guard.vtable = &table;
        attempted.store(0, .release);
        try std.testing.expectError(error.TlsUnavailable, pg.PgClient.connectOpts(a, guard, .{ .host = "127.0.0.1", .port = config.port, .database = config.database }));
        try require(attempted.load(.acquire) == 0);
        return .{ .enabled = false, .groups = 1, .disabled_connect_attempts = attempted.load(.acquire) };
    }
    const root = env.get("POSTGRES_TEST_TLS_CERTS") orelse return error.TlsCertificatesRequired;
    const ca = try std.fmt.allocPrint(a, "{s}/ca.crt", .{root});
    defer a.free(ca);
    const leaf = try std.fmt.allocPrint(a, "{s}/leaf.crt", .{root});
    defer a.free(leaf);
    const key = try std.fmt.allocPrint(a, "{s}/leaf.key", .{root});
    defer a.free(key);
    const expired = try std.fmt.allocPrint(a, "{s}/expired.crt", .{root});
    defer a.free(expired);
    const other = try std.fmt.allocPrint(a, "{s}/other-ca.crt", .{root});
    defer a.free(other);
    var fixture: F.Options = .{ .database = config.database, .ca = ca, .certificate = leaf, .key = key };
    var relay = try F.Relay.init(a, io, fixture);
    defer relay.stop();
    try relay.start();
    var opt = options(config, &relay, ca);
    const c = try pg.PgClient.connectOpts(a, io, opt);
    defer c.close();
    const scope = c.withDeadline(end(io, 20000));
    defer scope.deinit();
    try require(c.transport.session != null);
    try @import("stream_cases.zig").basic(c, a);
    try require(try integer(c, "SELECT 1") == 1);
    var params = try c.queryParams("SELECT $1::text", .{"encrypted prospect's follow-up 医療"});
    defer params.deinit();
    try std.testing.expectEqualStrings("encrypted prospect's follow-up 医療", params.rows[0].get(0).?);
    var allocation_failures: usize = 0;
    for (0..128) |index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        if (pg.PgClient.connectOpts(failing.allocator(), io, options(config, &relay, ca))) |owned| {
            owned.close();
            try require(!failing.has_induced_failure);
            allocation_failures = index;
            break;
        } else |err| try require(err == error.OutOfMemory and failing.has_induced_failure);
    } else return error.TlsAllocationFailureCaseLimit;
    try require(allocation_failures > 0);
    opt.host = "127.0.0.1";
    const ip = try pg.PgClient.connectOpts(a, io, opt);
    defer ip.close();
    const observer_scope = ip.withDeadline(end(io, 20000));
    defer observer_scope.deinit();
    try require(try integer(ip, "SELECT 2") == 2);
    try negative(a, io, config, fixture, "wrong.invalid", ca, error.TlsVerificationOrProtocolError, false);
    try negative(a, io, config, fixture, "127.0.0.2", ca, error.TlsVerificationOrProtocolError, false);
    try negative(a, io, config, fixture, null, other, error.TlsVerificationOrProtocolError, false);
    fixture.certificate = expired;
    try negative(a, io, config, fixture, null, ca, error.TlsVerificationOrProtocolError, false);
    fixture.certificate = leaf;
    fixture.mode = .refuse;
    try negative(a, io, config, fixture, null, ca, error.TlsRefused, false);
    fixture.mode = .truncated;
    try negative(a, io, config, fixture, null, ca, error.EndOfStream, false);
    fixture.mode = .stall;
    try negative(a, io, config, fixture, null, ca, error.Timeout, false);
    try negative(a, io, config, fixture, null, ca, error.Canceled, true);
    fixture.mode = .relay;
    // All SQL effects belong to the already verified disposable database.
    try execute(c, "CREATE TABLE pg4_tls_rows(id integer PRIMARY KEY)");
    defer execute(c, "DROP TABLE IF EXISTS pg4_tls_rows") catch {};
    {
        var tx = try pg.Transaction.begin(c);
        defer tx.deinit();
        try execute(c, "INSERT INTO pg4_tls_rows VALUES(1)");
    }
    try require(try integer(ip, "SELECT count(*) FROM pg4_tls_rows") == 0);
    var cfg = config;
    cfg.host = "localhost";
    cfg.port = relay.port();
    cfg.tls = .{ .ca_file = ca };
    const pool = try pg.Pool.init(a, io, cfg);
    defer pool.deinit();
    const blocked = try pool.acquire();
    try std.testing.expectError(error.Timeout, blocked.queryOpts("SELECT pg_sleep(60)", .{ .deadline = end(io, 100) }));
    try require(!blocked.reusable and blocked.transaction_status == .unknown);
    pool.release(blocked);
    try require(!pool.in_use[0] and pool.clients[0] == null);
    const canceled = try pool.acquire();
    var task = try io.concurrent(queryCanceled, .{canceled});
    defer task.cancel(io) catch {};
    try io.sleep(.fromMilliseconds(30), .awake);
    try task.cancel(io);
    pool.release(canceled);
    try require(relay.encrypted_cancels.load(.acquire) >= 2);
    const streaming = try pool.acquire();
    const rows = try streaming.streamQuery("SELECT pg_sleep(60)", .{ .deadline = end(io, 100) });
    try std.testing.expectError(error.Timeout, rows.next());
    rows.deinit();
    pool.release(streaming);
    try require(relay.encrypted_cancels.load(.acquire) >= 3);
    const rollback = try pool.acquire();
    var tx = try pg.Transaction.begin(rollback);
    try execute(rollback, "INSERT INTO pg4_tls_rows VALUES(2)");
    relay.stall_rollback.store(true, .release);
    const before = Io.Timestamp.now(io, .awake);
    tx.deinit();
    const rollback_time = before.untilNow(io, .awake).toMilliseconds();
    try require(rollback_time >= 400 and rollback_time <= 750 and !rollback.reusable);
    pool.release(rollback);
    relay.stall_rollback.store(false, .release);
    const lost = try pool.acquire();
    var unknown = try pg.Transaction.begin(lost);
    var lost_released = false;
    defer if (!lost_released) {
        unknown.deinit();
        pool.release(lost);
    };
    try execute(lost, "INSERT INTO pg4_tls_rows VALUES(3)");
    relay.drop_commit.store(true, .release);
    if (unknown.commit()) |_| return error.ExpectedUnknownCommit else |err| try require(err == error.EndOfStream or err == error.ReadFailed or err == error.TlsVerificationOrProtocolError);
    try require(!lost.reusable and lost.transaction_status == .unknown and !unknown.committed);
    unknown.deinit();
    pool.release(lost);
    lost_released = true;
    try require(relay.dropped.load(.acquire) == 1);
    const persisted = try integer(ip, "SELECT count(*) FROM pg4_tls_rows WHERE id=3");
    try require(persisted == 1);
    const next = try pool.acquireOpts(.{ .deadline = end(io, 1000) });
    defer pool.release(next);
    try require(try integer(next, "SELECT 7") == 7);
    try require(!relay.failed.load(.acquire));
    return .{ .enabled = true, .groups = 12, .allocation_failures = allocation_failures, .openssl = try pg.tls.version(io), .encrypted_cancel_requests = relay.encrypted_cancels.load(.acquire), .rollback_ms = rollback_time, .unknown_commit_rows = persisted };
}
