//! Public API cases: real PostgreSQL semantics and independent wire peers.
const std = @import("std");
const pg = @import("postgres");
const Io = std.Io;
const A = std.mem.Allocator;
fn require(ok: bool) !void {
    if (!ok) return error.ParameterCaseFailed;
}
fn execute(c: *pg.PgClient, sql: []const u8) !void {
    var r = try c.query(sql);
    defer r.deinit();
}
fn next(c: *pg.PgClient) !void {
    var r = try c.query("SELECT 1");
    defer r.deinit();
    var p = try c.queryParams("SELECT $1::bigint", .{@as(i64, 2)});
    defer p.deinit();
    try require(try r.rows[0].getTyped(?i64, 0) == 1 and try p.rows[0].getTyped(?i64, 0) == 2);
}
fn failed(c: *pg.PgClient, sql: []const u8, args: anytype, state: []const u8) !void {
    if (c.queryParams(sql, args)) |v| {
        var r = v;
        r.deinit();
        return error.ExpectedDatabaseError;
    } else |err| try require(err == error.DatabaseError);
    try require(std.mem.eql(u8, &(c.last_diagnostic orelse return error.MissingSqlstate).sqlstate.?, state));
}
fn admission(c: *pg.PgClient, inside: bool) !void {
    if (inside) try execute(c, "BEGIN");
    const original = c.transaction_status;
    const limits = c.limits;
    defer c.limits = limits;
    c.limits.max_parameters = 1;
    var r = try c.queryParams("SELECT $1::text", .{"one"});
    r.deinit();
    try std.testing.expectError(error.ParameterLimit, c.queryParams("SELECT $1,$2", .{ 1, 2 }));
    c.limits.max_request_bytes = 66;
    var exact = try c.queryParams("SELECT $1::text", .{"one"});
    exact.deinit();
    c.limits.max_request_bytes = 65;
    try std.testing.expectError(error.RequestTooLarge, c.queryParams("SELECT $1::text", .{"one"}));
    c.limits = limits;
    try std.testing.expectError(error.InvalidText, c.queryParams("SELECT $1", .{"a\x00b"}));
    try std.testing.expectError(error.InvalidSql, c.queryParams("SELECT\x00 1", .{}));
    try std.testing.expectError(error.UnsupportedParameter, c.queryParams("SELECT $1", .{@as(f64, 1.0)}));
    try std.testing.expectError(error.IntegerRange, c.queryParams("SELECT $1", .{@as(u64, std.math.maxInt(u64))}));
    try std.testing.expectError(error.Timeout, c.queryParamsOpts("SELECT 1", .{}, .{ .deadline = Io.Timestamp.now(c.io, .awake) }));
    var failing = std.testing.FailingAllocator.init(c.allocator, .{ .fail_index = 0 });
    const owner = c.allocator;
    c.allocator = failing.allocator();
    const outcome = c.queryParams("SELECT 1", .{});
    c.allocator = owner;
    try std.testing.expectError(error.OutOfMemory, outcome);
    try require(c.reusable and c.transaction_status == original);
    try next(c);
    if (inside) try execute(c, "COMMIT");
}
const Peer = struct {
    io: Io,
    listener: Io.net.Server,
    mode: enum { invalid, truncated, normal_stall, partial_ready, error_stall, write_stall, read_cancel, success },
    requested: Io.Event = .unset,
    syncs: usize = 0,
    fn serve(self: *Peer) !void {
        const stream = try self.listener.accept(self.io);
        defer stream.close(self.io);
        var rb: [2048]u8 = undefined;
        var wb: [2048]u8 = undefined;
        var reader = stream.reader(self.io, &rb);
        var writer = stream.writer(self.io, &wb);
        const r = &reader.interface;
        const w = &writer.interface;
        const size = try r.takeInt(u32, .big);
        if (size < 8 or size > 2048) return error.BadStartup;
        try r.discardAll(size - 4);
        try w.writeAll("R\x00\x00\x00\x08\x00\x00\x00\x00Z\x00\x00\x00\x05I");
        try w.flush();
        while (true) {
            const tag = try r.takeByte();
            const len = try r.takeInt(u32, .big);
            if (len < 4 or len > 32 * 1024 * 1024) return error.BadRequest;
            try r.discardAll(len - 4);
            if (tag == 'X') return;
            if (tag == 'P' and self.mode == .write_stall) {
                self.requested.set(self.io);
                try self.io.sleep(.fromSeconds(60), .awake);
                return error.UnexpectedWake;
            }
            if (tag == 'S') {
                self.syncs += 1;
                break;
            }
        }
        self.requested.set(self.io);
        if (self.mode == .success) {
            try w.writeAll("1\x00\x00\x00\x04" ++ "2\x00\x00\x00\x04n\x00\x00\x00\x04C\x00\x00\x00\x0fINSERT 0 1\x00Z\x00\x00\x00\x05I");
            try w.flush();
            return;
        }
        if (self.mode == .invalid) {
            try w.writeAll("E\x00\x00\x00\x0cC23505\x00\x00Z\x00\x00\x00\x05?");
            try w.flush();
            return;
        }
        if (self.mode == .truncated) {
            try w.writeAll("E\x00\x00\x00\x0cC23505\x00\x00Z\x00\x00");
            try w.flush();
            return;
        }
        if (self.mode == .error_stall) try w.writeAll("E\x00\x00\x00\x0cC23505\x00\x00") else {
            try w.writeAll("1\x00\x00\x00\x04" ++ "2\x00\x00\x00\x04n\x00\x00\x00\x04C\x00\x00\x00\x0fINSERT 0 1\x00");
            if (self.mode == .partial_ready) try w.writeAll("Z\x00\x00\x00");
        }
        try w.flush();
        try self.io.sleep(.fromSeconds(60), .awake);
        return error.UnexpectedWake;
    }
};
fn canceled(c: *pg.PgClient, bytes: []const u8) !void {
    if (c.queryParams("SELECT $1::text", .{bytes})) |v| {
        var r = v;
        r.deinit();
        return error.ExpectedCancellation;
    } else |err| try require(err == error.Canceled);
}
fn fault(a: A, io: Io, config: pg.PoolConfig, mode: @FieldType(Peer, "mode")) !i64 {
    var peer: Peer = .{ .io = io, .listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true }), .mode = mode };
    defer peer.listener.deinit(io);
    var serving = try io.concurrent(Peer.serve, .{&peer});
    defer serving.cancel(io) catch {};
    var cfg = config;
    cfg.port = peer.listener.socket.address.getPort();
    const pool = try pg.Pool.init(a, io, cfg);
    defer pool.deinit();
    const c = try pool.acquire();
    var released = false;
    defer if (!released) pool.release(c);
    const start = Io.Timestamp.now(io, .awake);
    var elapsed: i64 = 0;
    if (mode == .read_cancel or mode == .write_stall) {
        const bytes = try a.alloc(u8, if (mode == .write_stall) 24 * 1024 * 1024 else 1);
        defer a.free(bytes);
        @memset(bytes, 'x');
        var calling = try io.concurrent(canceled, .{ c, bytes });
        defer calling.cancel(io) catch {};
        try peer.requested.wait(io);
        try io.sleep(.fromMilliseconds(25), .awake);
        const cancel_start = Io.Timestamp.now(io, .awake);
        try calling.cancel(io);
        elapsed = cancel_start.untilNow(io, .awake).toMilliseconds();
        try require(elapsed >= 400 and elapsed <= 750);
    } else {
        const want: anyerror = switch (mode) {
            .invalid => error.ProtocolViolation,
            .truncated => error.EndOfStream,
            else => error.Timeout,
        };
        try std.testing.expectError(want, c.queryParamsOpts("INSERT fixture", .{}, .{ .deadline = Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(100)) }));
        elapsed = start.untilNow(io, .awake).toMilliseconds();
        if (mode == .normal_stall or mode == .partial_ready) try require(elapsed >= 500 and elapsed <= 850);
        if (mode == .error_stall) try require(elapsed >= 400 and elapsed <= 750);
    }
    try require(!c.reusable and c.transaction_status == .unknown);
    pool.release(c);
    released = true;
    try require(pool.clients[0] == null and !pool.in_use[0]);
    serving.cancel(io) catch |err| if (err != error.Canceled) return err;
    try require(peer.syncs == (if (mode == .write_stall) @as(usize, 0) else 1));
    pool.config.port = config.port;
    const replacement = try pool.acquire();
    defer pool.release(replacement);
    try next(replacement);
    return elapsed;
}
pub const Outcome = struct { recovery_cases: usize = 14, scalar_columns: usize = 13, delayed_commit_ms: i64, explicit_commit_ms: i64, fault_elapsed_ms: [7]i64, allocation_failures: usize };
pub fn run(a: A, io: Io, config: pg.PoolConfig) !Outcome {
    const c = try pg.PgClient.connect(a, io, config.host, config.port, config.user, config.password, config.database);
    defer c.close();
    const observer = try pg.PgClient.connect(a, io, config.host, config.port, config.user, config.password, config.database);
    defer observer.close();
    var zero = try c.queryParams("SELECT 1", .{});
    zero.deinit();
    const text = "prospect's \\ follow-up 医療; DROP TABLE pg3_values; --";
    var scalars = try c.queryParams("SELECT $1::text,$2::text,$3::text,$4::boolean,$5::boolean,$6::bigint,$7::bigint,$8::text,$9::uuid,$10::bytea,$11::numeric::text,$12::timestamp::text,$13::bigint", .{ null, @as(?[]const u8, null), "", true, false, std.math.minInt(i64), @as(u64, std.math.maxInt(i64)), text, pg.Uuid{ .bytes = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } }, pg.Binary{ .bytes = "\x00\xff'\\" }, "1234567890.123456789", "2030-01-02 03:04:05.123456", @as(?i32, 42) });
    defer scalars.deinit();
    const row = scalars.rows[0];
    try require(row.get(0) == null and row.get(1) == null and row.get(2).?.len == 0);
    try require(try row.getTyped(?bool, 3) == true and try row.getTyped(?bool, 4) == false);
    try require(try row.getTyped(?i64, 5) == std.math.minInt(i64) and try row.getTyped(?i64, 6) == std.math.maxInt(i64));
    try std.testing.expectEqualStrings(text, row.get(7).?);
    try std.testing.expectEqualStrings("00010203-0405-0607-0809-0a0b0c0d0e0f", row.get(8).?);
    try std.testing.expectEqualStrings("\\x00ff275c", row.get(9).?);
    try std.testing.expectEqualStrings("1234567890.123456789", row.get(10).?);
    try std.testing.expectEqualStrings("2030-01-02 03:04:05.123456", row.get(11).?);
    try require(try row.getTyped(?i64, 12) == 42);
    for ([_]bool{ false, true }) |inside| {
        inline for (.{ .{ "SELEC 1", .{}, "42601" }, .{ "SELECT $1::integer", .{"invalid-integer"}, "22P02" }, .{ "SELECT 1/$1::integer", .{0}, "22012" } }) |case| {
            if (inside) try execute(c, "BEGIN");
            try failed(c, case[0], case[1], case[2]);
            if (inside) {
                try require(c.reusable and c.transaction_status == .failed_transaction);
                try std.testing.expectError(error.DatabaseError, c.query("SELECT 1"));
                try execute(c, "ROLLBACK");
            } else try require(c.reusable and c.transaction_status == .idle);
            try next(c);
        }
    }
    try failed(c, "SELECT $1::integer", .{}, "08P01");
    try next(c);
    try failed(c, "SELECT 1; SELECT 2", .{}, "42601");
    try next(c);
    var semi = try c.queryParams("SELECT ';'::text,$1::text", .{";"});
    semi.deinit();
    try admission(c, false);
    try admission(c, true);
    try execute(c, "CREATE TABLE pg3_values (id integer UNIQUE DEFERRABLE INITIALLY DEFERRED, content text)");
    defer execute(c, "DROP TABLE IF EXISTS pg3_values CASCADE; DROP FUNCTION IF EXISTS pg3_commit_delay()") catch {};
    try execute(c, "CREATE FUNCTION pg3_commit_delay() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id IN (1,3) THEN PERFORM pg_sleep(0.75); END IF; RETURN NEW; END $$");
    try execute(c, "CREATE CONSTRAINT TRIGGER pg3_delay AFTER INSERT ON pg3_values DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pg3_commit_delay()");
    const start = Io.Timestamp.now(io, .awake);
    var delayed = try c.queryParamsOpts("/* PG3-R13 */ INSERT INTO pg3_values VALUES ($1::integer,$2::text) RETURNING content", .{ 1, text }, .{ .deadline = start.addDuration(.fromSeconds(3)) });
    defer delayed.deinit();
    const elapsed = start.untilNow(io, .awake).toMilliseconds();
    try require(elapsed >= 650 and elapsed < 3000 and c.transaction_status == .idle);
    try std.testing.expectEqualStrings(text, delayed.rows[0].get(0).?);
    try next(c);
    const commit_start = Io.Timestamp.now(io, .awake);
    const commit_deadline = c.withDeadline(commit_start.addDuration(.fromSeconds(3)));
    var tx = try pg.Transaction.begin(c);
    defer tx.deinit();
    var explicit = try c.queryParams("INSERT INTO pg3_values VALUES (3,'explicit')", .{});
    explicit.deinit();
    const before_commit = Io.Timestamp.now(io, .awake);
    try tx.commit();
    const explicit_elapsed = before_commit.untilNow(io, .awake).toMilliseconds();
    commit_deadline.deinit();
    try require(explicit_elapsed >= 650 and explicit_elapsed < 3000);
    try next(c);
    // Expired normal scope cannot prevent bounded rollback from reaching idle.
    try execute(c, "BEGIN");
    try execute(c, "INSERT INTO pg3_values VALUES (4,'rollback')");
    const expired = c.withDeadline(Io.Timestamp.now(io, .awake));
    c.rollbackCleanup();
    expired.deinit();
    try require(c.reusable and c.transaction_status == .idle);
    try next(c);
    try failed(c, "/* PG3-R14 */ INSERT INTO pg3_values VALUES (2,$1::text),(2,$1::text) RETURNING id", .{text}, "23505");
    try require(c.reusable and c.transaction_status == .idle);
    var persisted = try observer.query("SELECT count(*),count(*) FILTER (WHERE id=1),count(*) FILTER (WHERE id=2),count(*) FILTER (WHERE id=4) FROM pg3_values");
    defer persisted.deinit();
    try require(try persisted.rows[0].getTyped(?i64, 0) == 2 and try persisted.rows[0].getTyped(?i64, 1) == 1 and try persisted.rows[0].getTyped(?i64, 2) == 0 and try persisted.rows[0].getTyped(?i64, 3) == 0);
    try next(c);
    var times: [7]i64 = undefined;
    inline for (std.meta.tags(@FieldType(Peer, "mode"))[0..7], 0..) |mode, index| times[index] = try fault(a, io, config, mode);
    return .{ .delayed_commit_ms = elapsed, .explicit_commit_ms = explicit_elapsed, .fault_elapsed_ms = times, .allocation_failures = try allocationCases(a, io) };
}

fn allocationCases(a: A, io: Io) !usize {
    for (0..128) |index| {
        var peer: Peer = .{ .io = io, .listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .mode = .success };
        defer peer.listener.deinit(io);
        var serving = try io.concurrent(Peer.serve, .{&peer});
        defer serving.cancel(io) catch {};
        var failing = std.testing.FailingAllocator.init(a, .{});
        const c = try pg.PgClient.connect(failing.allocator(), io, "127.0.0.1", peer.listener.socket.address.getPort(), "owned", "owned", "owned");
        var closed = false;
        defer if (!closed) c.close();
        failing.fail_index = failing.alloc_index + index;
        if (c.queryParams("INSERT fixture", .{ true, @as(?i64, null), pg.Binary{ .bytes = "\x00" } })) |v| {
            var r = v;
            r.deinit();
            try require(!failing.has_induced_failure);
        } else |err| {
            try require(err == error.OutOfMemory and failing.has_induced_failure);
            try require(if (index == 0) c.reusable and c.transaction_status == .idle else !c.reusable);
        }
        c.close();
        closed = true;
        serving.await(io) catch |err| if (err != error.WriteFailed and err != error.ReadFailed and err != error.EndOfStream) return err;
        if (!failing.has_induced_failure) return index;
    }
    return error.AllocationCaseLimit;
}
