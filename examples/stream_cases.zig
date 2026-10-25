//! Iterator ownership/recovery against the owned database; malformed peers reused.
const std = @import("std");
const pg = @import("postgres");
const A = std.mem.Allocator;
const Io = std.Io;
fn require(ok: bool) !void {
    if (!ok) return error.StreamCaseFailed;
}
fn exec(c: *pg.PgClient, sql: []const u8) !void {
    var r = try c.query(sql);
    r.deinit();
}
fn end(io: Io, ms: u32) Io.Timestamp {
    return Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(ms));
}
pub fn basic(c: *pg.PgClient, a: A) !void {
    const empty = try c.streamQuery("SELECT 1 WHERE false", .{});
    defer empty.deinit();
    try require(try empty.next() == null and empty.complete);
    const s = try c.streamParams("SELECT i::text,NULL::text,'owned'::text FROM generate_series(1,$1::int) i", .{@as(i32, 3)}, .{});
    var stream_alive = true;
    defer if (stream_alive) s.deinit();
    try std.testing.expectError(error.ConnectionBusy, c.query("SELECT 1"));
    try std.testing.expectError(error.ConnectionBusy, c.queryParams("SELECT $1::int", .{1}));
    try std.testing.expectError(error.ConnectionBusy, c.streamQuery("SELECT 1", .{}));
    const first = (try s.next()).?;
    try require(std.mem.eql(u8, (try first.get(0)).?, "1") and try first.get(1) == null);
    for (0..3) |index| {
        var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        try std.testing.expectError(error.OutOfMemory, first.copy(fail.allocator()));
        try require(fail.has_induced_failure and c.reusable and c.active_stream != null);
    }
    var owned = try first.copy(a);
    defer owned.deinit();
    const second = (try s.next()).?;
    try std.testing.expectError(error.StaleRow, first.get(0));
    try require(std.mem.eql(u8, (try second.get(0)).?, "2"));
    _ = (try s.next()).?;
    try require(try s.next() == null and s.complete and s.rows == 3);
    try exec(c, "SELECT 1");
    s.deinit();
    stream_alive = false;
    try require(std.mem.eql(u8, owned.get(0).?, "1"));
    const large = try c.streamParams("SELECT repeat('x',$1::int)", .{131072}, .{});
    defer large.deinit();
    const row = (try large.next()).?;
    const bytes = (try row.get(0)).?;
    try require(bytes.len == 131072);
    for (bytes) |ch| try require(ch == 'x');
    try require(try large.next() == null);
}
fn failed(c: *pg.PgClient, sql: []const u8, values: anytype, state: []const u8) !usize {
    const s = try c.streamParams(sql, values, .{});
    defer s.deinit();
    var rows: usize = 0;
    while (true) {
        if (s.next()) |value| {
            if (value == null) return error.ExpectedStreamFailure;
            rows += 1;
        } else |err| {
            try require(err == error.DatabaseError);
            break;
        }
    }
    try require(c.reusable and std.mem.eql(u8, &c.last_diagnostic.?.sqlstate.?, state));
    try std.testing.expectError(error.StreamClosed, s.next());
    return rows;
}
fn canceled(c: *pg.PgClient) !void {
    const s = try c.streamQuery("SELECT pg_sleep(60)", .{});
    defer s.deinit();
    try std.testing.expectError(error.Canceled, s.next());
}
pub const Outcome = struct { groups: usize = 12, malformed_groups: usize = 31, allocation_failures: usize, copy_allocation_failures: usize = 3, delayed_commit_ms: i64, timeout_ms: i64 };
pub fn run(a: A, io: Io, config: pg.PoolConfig) !Outcome {
    const raw = try @import("protocol_cases.zig").runStreaming(a, io, config);
    const pool = try pg.Pool.init(a, io, config);
    defer pool.deinit();
    var delayed_commit_ms: i64 = 0;
    {
        const c = try pool.acquire();
        defer pool.release(c);
        try basic(c, a);
        inline for (.{ false, true }) |inside| {
            if (inside) try exec(c, "BEGIN");
            _ = try failed(c, "SELECT missing_column", .{}, "42703");
            if (inside) try exec(c, "ROLLBACK");
            if (inside) try exec(c, "BEGIN");
            _ = try failed(c, "SELECT $1::int", .{"invalid"}, "22P02");
            if (inside) try exec(c, "ROLLBACK");
            if (inside) try exec(c, "BEGIN");
            _ = try failed(c, "SELECT 1/$1::int", .{0}, "22012");
            if (inside) try exec(c, "ROLLBACK");
            try exec(c, "SELECT 1");
        }
        try exec(c, "CREATE TEMP TABLE pg5_deferred(id int UNIQUE DEFERRABLE INITIALLY DEFERRED)");
        const provisional = try failed(c, "/* PG5-SYNC */ INSERT INTO pg5_deferred VALUES($1::int),($1::int) RETURNING id", .{1}, "23505");
        try require(provisional == 2 and c.transaction_status == .idle);
        var count = try c.query("SELECT count(*) FROM pg5_deferred");
        try require(try count.rows[0].getInt(0, i64) == 0);
        count.deinit();
        try exec(c, "CREATE FUNCTION pg_temp.pg5_commit_delay() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(0.75); RETURN NEW; END $$; CREATE CONSTRAINT TRIGGER pg5_delay AFTER INSERT ON pg5_deferred DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pg_temp.pg5_commit_delay()");
        const before_commit = Io.Timestamp.now(io, .awake);
        const commit_rows = try c.streamParams("/* PG5-COMMIT */ INSERT INTO pg5_deferred VALUES($1::int) RETURNING id", .{7}, .{ .deadline = end(io, 3000) });
        defer commit_rows.deinit();
        try require(try commit_rows.next() != null and try commit_rows.next() == null);
        delayed_commit_ms = before_commit.untilNow(io, .awake).toMilliseconds();
        try require(delayed_commit_ms >= 650 and delayed_commit_ms <= 2500 and c.transaction_status == .idle);
        var committed = try c.query("SELECT count(*) FROM pg5_deferred WHERE id=7");
        try require(try committed.rows[0].getInt(0, i64) == 1);
        committed.deinit();
        try exec(c, "DROP TABLE pg5_deferred; DROP FUNCTION pg_temp.pg5_commit_delay()");
    }
    {
        const c = try pool.acquire();
        const s = try c.streamQuery("SELECT generate_series(1,100)", .{});
        defer s.deinit();
        _ = try s.next();
        s.close();
        try std.testing.expectError(error.StreamClosed, s.next());
        try require(!c.reusable);
        pool.release(c);
        try require(pool.clients[0] == null and !pool.in_use[0]);
    }
    {
        const c = try pool.acquire();
        const s = try c.streamQuery("SELECT 1", .{});
        defer s.deinit();
        const row = (try s.next()).?;
        var retained = try row.copy(a);
        defer retained.deinit();
        pool.release(c);
        try require(std.mem.eql(u8, retained.get(0).?, "1"));
        try std.testing.expectError(error.StaleRow, row.get(0));
        try std.testing.expectError(error.StreamClosed, s.next());
        const fresh = try pool.acquire();
        defer pool.release(fresh);
        try exec(fresh, "SELECT 1");
    }
    {
        const c = try pool.acquire();
        var tx = try pg.Transaction.begin(c);
        const s = try c.streamQuery("SELECT 1", .{});
        defer s.deinit();
        _ = try s.next();
        tx.deinit();
        pool.release(c);
        try std.testing.expectError(error.StreamClosed, s.next());
    }
    var elapsed: i64 = 0;
    {
        const c = try pool.acquire();
        defer pool.release(c);
        const start = Io.Timestamp.now(io, .awake);
        const s = try c.streamQuery("SELECT pg_sleep(60)", .{ .deadline = end(io, 100) });
        defer s.deinit();
        try std.testing.expectError(error.Timeout, s.next());
        elapsed = start.untilNow(io, .awake).toMilliseconds();
        try require(elapsed >= 90 and elapsed <= 850 and !c.reusable);
    }
    {
        const c = try pool.acquire();
        defer pool.release(c);
        var task = try io.concurrent(canceled, .{c});
        defer task.cancel(io) catch {};
        try io.sleep(.fromMilliseconds(30), .awake);
        try task.cancel(io);
        try require(!c.reusable);
    }
    const fresh = try pool.acquire();
    defer pool.release(fresh);
    try exec(fresh, "SELECT 1");
    return .{ .allocation_failures = raw.allocation_failures, .delayed_commit_ms = delayed_commit_ms, .timeout_ms = elapsed };
}
