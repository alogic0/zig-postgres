//! Opt-in public API consumer. Requires the existing backend disposable schema
//! lease; default package checks neither connect nor execute this program.
const std = @import("std");
const pg = @import("postgres");
const Io = std.Io;
const A = std.mem.Allocator;
const protocol_cases = @import("protocol_cases.zig");

fn require(ok: bool) !void {
    if (!ok) return error.AssertionFailed;
}
fn execute(c: *pg.PgClient, sql: []const u8) !void {
    var result = try c.query(sql);
    defer result.deinit();
}
fn integer(c: *pg.PgClient, sql: []const u8) !i64 {
    var result = try c.query(sql);
    defer result.deinit();
    try require(result.rows.len == 1);
    return (try result.rows[0].getInt(0, i64)) orelse error.NullResult;
}
fn databaseError(c: *pg.PgClient) !void {
    if (c.query("SELECT 1/0")) |value| {
        var result = value;
        result.deinit();
        return error.ExpectedDatabaseError;
    } else |err| try require(err == error.DatabaseError);
    try require(std.mem.eql(u8, &(c.last_diagnostic orelse return error.MissingDiagnostic).sqlstate.?, "22012"));
}

const Peer = struct {
    io: Io,
    listener: Io.net.Server,
    mode: enum { rollback_failure, rollback_stall, commit_loss },
    closed: bool = false,
    queries: usize = 0,

    fn init(io: Io, mode: @FieldType(Peer, "mode")) !Peer {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .io = io, .listener = try address.listen(io, .{ .reuse_address = true }), .mode = mode };
    }
    fn serve(self: *Peer) !void {
        const stream = try self.listener.accept(self.io);
        defer stream.close(self.io);
        defer self.closed = true;
        var rb: [2048]u8 = undefined;
        var wb: [2048]u8 = undefined;
        var reader = stream.reader(self.io, &rb);
        var writer = stream.writer(self.io, &wb);
        const r = &reader.interface;
        const w = &writer.interface;
        const startup = try r.takeInt(u32, .big);
        if (startup < 8 or startup > rb.len) return error.InvalidStartup;
        try r.discardAll(startup - 4);
        try w.writeAll("R\x00\x00\x00\x08\x00\x00\x00\x00Z\x00\x00\x00\x05I");
        try w.flush();
        var sql: [128]u8 = undefined;
        while (true) {
            const tag = r.takeByte() catch |err| {
                if (err == error.EndOfStream) return;
                return err;
            };
            const size = try r.takeInt(u32, .big);
            if (size < 4 or size - 4 > sql.len) return error.InvalidQuery;
            try r.readSliceAll(sql[0 .. size - 4]);
            if (tag == 'X') return;
            if (tag != 'Q') return error.UnexpectedQuery;
            self.queries += 1;
            const text = sql[0 .. size - 4];
            if (std.mem.eql(u8, text, "BEGIN\x00")) {
                try w.writeAll("C\x00\x00\x00\x0aBEGIN\x00Z\x00\x00\x00\x05T");
                try w.flush();
            } else if (std.mem.eql(u8, text, "COMMIT\x00") and self.mode == .commit_loss) {
                return;
            } else if (std.mem.eql(u8, text, "ROLLBACK\x00")) {
                if (self.mode == .rollback_failure) {
                    const body = "C57014\x00Mowned rollback failure\x00\x00";
                    try w.writeByte('E');
                    try w.writeInt(u32, body.len + 4, .big);
                    try w.writeAll(body);
                    try w.writeAll("Z\x00\x00\x00\x05T");
                    try w.flush();
                }
                // A stalled rollback accepts the request but never answers.
                // EOF proves the borrower closed its invalidated connection.
                _ = r.takeByte() catch |err| {
                    if (err == error.EndOfStream) return;
                    return err;
                };
                return error.UnexpectedRetry;
            } else return error.UnexpectedQuery;
        }
    }
};

fn canceledCleanup(tx: *pg.Transaction) !void {
    tx.client.io.sleep(.fromSeconds(60), .awake) catch |err| {
        if (err != error.Canceled) return err;
        // The cancellation is already acknowledged before protected cleanup.
        tx.deinit();
        return;
    };
    return error.CallerWasNotCanceled;
}

fn fault(a: A, io: Io, config: pg.PoolConfig, mode: @FieldType(Peer, "mode"), canceled: bool) !i64 {
    var peer = try Peer.init(io, mode);
    defer peer.listener.deinit(io);
    var serving = try io.concurrent(Peer.serve, .{&peer});
    defer serving.cancel(io) catch {};
    var fault_config = config;
    fault_config.port = peer.listener.socket.address.getPort();
    const pool = try pg.Pool.initLazy(a, io, fault_config);
    defer pool.deinit();
    const client = try pool.acquire();
    var tx = try pg.Transaction.begin(client);
    const start = Io.Timestamp.now(io, .awake);
    if (mode == .commit_loss) {
        if (tx.commit()) |_| return error.CommitLossWasAccepted else |err| try require(err != error.TransactionRolledBack);
        try require(!client.reusable and !tx.committed and client.transaction_status == .unknown);
        tx.deinit();
    } else if (canceled) {
        var cleanup = try io.concurrent(canceledCleanup, .{&tx});
        try cleanup.cancel(io);
    } else tx.deinit();
    try require(!client.reusable and client.transaction_status == .unknown);
    pool.release(client);
    const elapsed = start.untilNow(io, .awake).toMilliseconds();
    try require(pool.clients[0] == null and !pool.in_use[0]);
    try serving.await(io);
    try require(peer.closed and peer.queries == 2);
    if (mode == .rollback_stall) try require(elapsed >= 400 and elapsed <= 750);
    // A fresh acquisition must work after the old slot has been returned.
    pool.config = config;
    const replacement = try pool.acquire();
    defer pool.release(replacement);
    try require(replacement.transaction_status == .idle);
    try require(try integer(replacement, "SELECT 1") == 1);
    return elapsed;
}

fn verify(a: A, io: Io, config: pg.PoolConfig, expected: []const u8) ![2]i64 {
    const pool = try pg.Pool.init(a, io, config);
    defer pool.deinit();
    const observer = try pg.PgClient.connect(a, io, config.host, config.port, config.user, config.password, config.database);
    defer observer.close();
    // Require the existing schema owner's exact marker before fixture writes.
    var marker = try observer.query("SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname=current_database()");
    defer marker.deinit();
    try require(marker.rows.len == 1 and std.mem.eql(u8, marker.rows[0].get(0) orelse "", expected));
    try execute(observer, "DROP TABLE IF EXISTS pg_development_rows; CREATE TABLE pg_development_rows(id integer PRIMARY KEY, body text)");
    defer execute(observer, "DROP TABLE pg_development_rows") catch @panic("Fixture table cleanup failed");

    // PG1-01: successful query and reuse of the same server session.
    var c = try pool.acquire();
    var pid = try integer(c, "SELECT pg_backend_pid()");
    try require(c.transaction_status == .idle);
    pool.release(c);
    c = try pool.acquire();
    try require(try integer(c, "SELECT pg_backend_pid()") == pid);
    pool.release(c);

    // PG1-02: an open transaction is closed, not handed to another borrower.
    c = try pool.acquire();
    try execute(c, "BEGIN; INSERT INTO pg_development_rows VALUES(2,'uncommitted')");
    try require(c.transaction_status == .transaction);
    pool.release(c);
    try require(pool.clients[0] == null);
    c = try pool.acquire();
    try require(try integer(c, "SELECT pg_backend_pid()") != pid);
    try require(try integer(observer, "SELECT count(*) FROM pg_development_rows WHERE id=2") == 0);
    pool.release(c);

    // PG1-03: failed explicit transaction is discarded and rolls back its write.
    c = try pool.acquire();
    pid = try integer(c, "SELECT pg_backend_pid()");
    try execute(c, "BEGIN; INSERT INTO pg_development_rows VALUES(3,'failed')");
    try databaseError(c);
    try require(c.transaction_status == .failed_transaction);
    pool.release(c);
    c = try pool.acquire();
    try require(try integer(c, "SELECT pg_backend_pid()") != pid);
    try require(try integer(observer, "SELECT count(*) FROM pg_development_rows WHERE id=3") == 0);
    pool.release(c);

    // PG1-04: an ordinary SQL failure ending idle does not destroy the session.
    c = try pool.acquire();
    pid = try integer(c, "SELECT pg_backend_pid()");
    try databaseError(c);
    try require(c.reusable and c.transaction_status == .idle);
    pool.release(c);
    c = try pool.acquire();
    try require(try integer(c, "SELECT pg_backend_pid()") == pid);
    pool.release(c);

    // PG1-05: rollback owns cleanup, retains the diagnostic and removes the write.
    c = try pool.acquire();
    var tx = try pg.Transaction.begin(c);
    try execute(c, "INSERT INTO pg_development_rows VALUES(5,'rolled back')");
    try databaseError(c);
    tx.deinit();
    try require(c.reusable and c.transaction_status == .idle);
    try require(std.mem.eql(u8, &(c.last_diagnostic orelse return error.MissingDiagnostic).sqlstate.?, "22012"));
    try require(try integer(observer, "SELECT count(*) FROM pg_development_rows WHERE id=5") == 0);
    pool.release(c);

    // PG1-06 also owns rollback's allocation-failure path after the server
    // accepts ROLLBACK. It must poison the client rather than return stale state.
    {
        var failing = std.testing.FailingAllocator.init(a, .{});
        const failed_pool = try pg.Pool.init(failing.allocator(), io, config);
        defer failed_pool.deinit();
        const owned = try failed_pool.acquire();
        var rollback = try pg.Transaction.begin(owned);
        try execute(owned, "INSERT INTO pg_development_rows VALUES(6,'allocation failure')");
        failing.fail_index = failing.alloc_index;
        rollback.deinit();
        try require(failing.has_induced_failure and !owned.reusable);
        failed_pool.release(owned);
        try require(failed_pool.clients[0] == null and !failed_pool.in_use[0]);
        failing.fail_index = std.math.maxInt(usize);
        const fresh = try failed_pool.acquire();
        defer failed_pool.release(fresh);
        try require(try integer(fresh, "SELECT 1") == 1);
        try require(try integer(observer, "SELECT count(*) FROM pg_development_rows WHERE id=6") == 0);
    }

    // PG1-07: COMMIT answering ROLLBACK must never report success.
    c = try pool.acquire();
    tx = try pg.Transaction.begin(c);
    try execute(c, "INSERT INTO pg_development_rows VALUES(7,'aborted')");
    try databaseError(c);
    if (tx.commit()) |_| return error.AbortedCommitWasAccepted else |err| try require(err == error.TransactionRolledBack);
    try require(!tx.committed and c.transaction_status == .idle);
    tx.deinit();
    try require(try integer(observer, "SELECT count(*) FROM pg_development_rows WHERE id=7") == 0);
    pool.release(c);

    _ = try fault(a, io, config, .rollback_failure, false); // PG1-06
    _ = try fault(a, io, config, .commit_loss, false); // PG1-08
    return .{
        try fault(a, io, config, .rollback_stall, false),
        try fault(a, io, config, .rollback_stall, true),
    }; // PG1-09, ordinary and already-canceled caller.
}

pub fn main(init: std.process.Init) !void {
    const database = init.environ_map.get("POSTGRES_TEST_DATABASE") orelse return error.OwnedDatabaseRequired;
    if (!std.mem.startsWith(u8, database, "zg_parity_upgrade_") or database.len != 30) return error.OwnedDatabaseRequired;
    for (database[18..]) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.OwnedDatabaseRequired;
    const report_path = init.environ_map.get("POSTGRES_TEST_REPORT") orelse return error.ReportPathRequired;
    var checked = std.heap.SafeAllocator.init(std.heap.page_allocator, .{});
    defer if (checked.deinitLog(false) != 0) @panic("PostgreSQL verifier leaked allocations");
    const config: pg.PoolConfig = .{
        .host = "127.0.0.1",
        .port = 5433,
        .user = init.environ_map.get("PGUSER") orelse return error.PGUSERRequired,
        .password = init.environ_map.get("PGPASSWORD") orelse return error.PGPASSWORDRequired,
        .database = database,
        .size = 1,
    };
    const expected = init.environ_map.get("POSTGRES_TEST_MARKER") orelse try std.fmt.allocPrint(init.arena.allocator(), "zig-postgres disposable schema fixture {s}", .{database});
    if (expected.len == 0) return error.OwnedDatabaseRequired;
    const elapsed = try verify(checked.allocator(), init.io, config, expected);
    const protocol_result = try protocol_cases.run(checked.allocator(), init.io, config);
    const report = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
        .milestone = "PG2",
        .database = database,
        .compiler = @import("builtin").zig_version_string,
        .optimize = @tagName(@import("builtin").mode),
        .cases = .{ "PG1-01", "PG1-02", "PG1-03", "PG1-04", "PG1-05", "PG1-06-server", "PG1-06-allocation", "PG1-07", "PG1-08", "PG1-09-ordinary", "PG1-09-canceled" },
        .rollback_elapsed_ms = elapsed,
        .cleanup_budget_ms = 500,
        .fixture_scheduling_allowance_ms = 250,
        .client_leaks = @as(usize, 0),
        .protocol = protocol_result,
    }, .{ .whitespace = .indent_2 });
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = report_path, .data = report });
    std.debug.print("PASS PG1/PG2: 9 ownership and 31 protocol case groups, zero owned leaks\n", .{});
}
