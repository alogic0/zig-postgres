//! Independent raw-wire cases for the public consumer, plus real SQL recovery.
const std = @import("std");
const pg = @import("postgres");
const Io = std.Io;
const A = std.mem.Allocator;
fn require(ok: bool) !void {
    if (!ok) return error.ProtocolCaseFailed;
}

const Reply = struct {
    a: A,
    bytes: std.ArrayList(u8) = .empty,
    fn deinit(self: *Reply) void {
        self.bytes.deinit(self.a);
    }
    fn frame(self: *Reply, tag: u8, body: []const u8) !void {
        try self.bytes.append(self.a, tag);
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(body.len + 4), .big);
        try self.bytes.appendSlice(self.a, &size);
        try self.bytes.appendSlice(self.a, body);
    }
    fn finish(self: *Reply) !void {
        try self.frame('C', "SELECT 1\x00");
        try self.frame('Z', "I");
    }
};
// One named text column with int4 metadata, as specified independently on wire.
const description = "\x00\x01x\x00" ++ "\x00\x00\x00\x00\x00\x00" ++ "\x00\x00\x00\x17\x00\x04\xff\xff\xff\xff\x00\x00";
const row = "\x00\x01\x00\x00\x00\x011";

const Peer = struct {
    io: Io,
    listener: Io.net.Server,
    reply: []const u8,
    hold: bool,
    queries: usize = 0,
    fn serve(self: *Peer) !void {
        const stream = try self.listener.accept(self.io);
        defer stream.close(self.io);
        var rb: [2048]u8 = undefined;
        var wb: [2048]u8 = undefined;
        var reader = stream.reader(self.io, &rb);
        var writer = stream.writer(self.io, &wb);
        const r = &reader.interface;
        const w = &writer.interface;
        const length = r.takeInt(u32, .big) catch |err| {
            if (err == error.EndOfStream) return;
            return err;
        };
        if (length < 8 or length > 2048) return error.InvalidStartup;
        try r.discardAll(length - 4);
        try w.writeAll("R\x00\x00\x00\x08\x00\x00\x00\x00Z\x00\x00\x00\x05I");
        try w.flush();
        const tag = r.takeByte() catch |err| {
            if (err == error.EndOfStream) return;
            return err;
        };
        const size = try r.takeInt(u32, .big);
        if (size < 4 or size > 128) return error.InvalidRequest;
        try r.discardAll(size - 4);
        if (tag == 'X') return;
        if (tag != 'Q') return error.InvalidRequest;
        self.queries += 1;
        try w.writeAll(self.reply);
        try w.flush();
        if (self.hold) {
            _ = r.takeByte() catch |err| {
                if (err == error.EndOfStream) return;
                return err;
            };
            return error.UnexpectedRetry;
        }
    }
};

fn wire(a: A, io: Io, bytes: []const u8, limits: pg.Limits, expected: ?anyerror, hold: bool, fail_at: ?usize) !bool {
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var peer: Peer = .{ .io = io, .listener = try address.listen(io, .{ .reuse_address = true }), .reply = bytes, .hold = hold };
    defer peer.listener.deinit(io);
    var serving = try io.concurrent(Peer.serve, .{&peer});
    defer serving.cancel(io) catch {};
    var failing = std.testing.FailingAllocator.init(a, .{});
    const client = try pg.PgClient.connect(failing.allocator(), io, "127.0.0.1", peer.listener.socket.address.getPort(), "owned", "owned", "owned-fixture");
    var closed = false;
    defer if (!closed) client.close();
    client.limits = limits;
    if (fail_at) |index| failing.fail_index = failing.alloc_index + index;
    const start = Io.Timestamp.now(io, .awake);
    if (client.query("SELECT 1")) |value| {
        var result = value;
        defer result.deinit();
        if (expected != null and fail_at == null) return error.ExpectedFailure;
        try require(client.reusable and client.transaction_status == .idle);
        for (result.rows) |result_row| try require(std.mem.eql(u8, result_row.get(0) orelse "", "1"));
    } else |err| {
        if (fail_at != null) {
            try require(err == error.OutOfMemory and failing.has_induced_failure);
        } else if (expected) |want| {
            if (err != want) {
                std.debug.print("wire error: expected {s}, got {s}\n", .{ @errorName(want), @errorName(err) });
                return error.WrongProtocolError;
            }
        } else return err;
        if (err == error.SqlTooLarge) {
            try require(client.reusable and client.transaction_status == .idle);
        } else if (err == error.DatabaseError) {
            try require(client.reusable and client.transaction_status == .idle);
            try require(std.mem.eql(u8, &(client.last_diagnostic orelse return error.MissingDiagnostic).sqlstate.?, "23505"));
        } else try require(!client.reusable and client.transaction_status == .unknown);
    }
    client.close();
    closed = true;
    try serving.await(io);
    const preflight = if (expected) |err| err == error.SqlTooLarge else false;
    try require(peer.queries == (if (preflight) @as(usize, 0) else 1));
    if (hold) {
        const elapsed = start.untilNow(io, .awake).toMilliseconds();
        try require(elapsed >= 400 and elapsed <= 750);
    }
    return failing.has_induced_failure;
}

pub const Outcome = struct {
    cases: []const []const u8 = &.{
        "PG2-F01", "PG2-F02", "PG2-F03", "PG2-F04", "PG2-F05", "PG2-F06", "PG2-F07", "PG2-F08", "PG2-F09", "PG2-F10", "PG2-F11", "PG2-F12", "PG2-F13", "PG2-F14",
        "PG2-L01", "PG2-L02", "PG2-L03", "PG2-L04", "PG2-L05", "PG2-L06", "PG2-L07", "PG2-L08", "PG2-L09", "PG2-L10", "PG2-L11", "PG2-L12", "PG2-V01", "PG2-V02",
        "PG2-V03", "PG2-V04", "PG2-A01",
    },
    allocation_failures: usize,
    error_cleanup_elapsed_ms: i64,
};

pub fn run(a: A, io: Io, config: pg.PoolConfig) !Outcome {
    var good: Reply = .{ .a = a };
    defer good.deinit();
    try good.frame('T', description);
    try good.frame('D', row);
    try good.finish();
    _ = try wire(a, io, "Z\x00\x00\x00\x03", .{}, error.ProtocolViolation, false, null); // F01
    _ = try wire(a, io, "T\x01\x00\x00\x00", .{}, error.MessageTooLarge, false, null); // F02
    _ = try wire(a, io, "T\x00\x00", .{}, error.EndOfStream, false, null); // F03
    _ = try wire(a, io, "T\x00\x00\x00\x10short", .{}, error.EndOfStream, false, null); // F04
    const error_start = Io.Timestamp.now(io, .awake);
    _ = try wire(a, io, "E\x00\x00\x00\x10C23505", .{}, error.Timeout, true, null);
    const error_elapsed = error_start.untilNow(io, .awake).toMilliseconds();
    const malformed = .{
        .{ 'T', "\x00\x01x" }, // F05 missing name terminator
        .{ 'T', "\x00\x01x\x00" }, // F05 missing descriptor
        .{ 'D', "\x00\x02" }, // F06 count mismatch
        .{ 'D', "\x00\x01\xff\xff\xff\xfe" }, // F07 invalid null
        .{ 'D', "\x00\x01\x00\x00\x00\x02x" }, // F08 beyond payload
        .{ 'D', row ++ "!" }, // F09 trailing bytes after allocated cell
        .{ 'C', "SELECT 1" }, // F10 missing terminator
        .{ 'Z', "" }, // F11 bad payload length
        .{ 'Z', "?" }, // F11 invalid status
        .{ 'G', "" }, // F12 unsupported COPY state
        .{ 'E', "C23505\x00" }, // F13 missing final terminator
    };
    inline for (malformed) |item| {
        var bad: Reply = .{ .a = a };
        defer bad.deinit();
        if (item[0] != 'T') try bad.frame('T', description);
        try bad.frame(item[0], item[1]);
        _ = try wire(a, io, bad.bytes.items, .{}, error.ProtocolViolation, false, null);
    }
    // A ReadyForQuery without any completed command cannot turn into success.
    _ = try wire(a, io, "Z\x00\x00\x00\x05I", .{}, error.ProtocolViolation, false, null);
    var private_error: Reply = .{ .a = a };
    defer private_error.deinit();
    try private_error.frame('E', "C23505\x00Mpg-private-secret-marker\x00\x00");
    try private_error.frame('Z', "I");
    _ = try wire(a, io, private_error.bytes.items, .{}, error.DatabaseError, false, null); // F14

    // Six limits at their exact contract boundaries and one beyond (L01-L12).
    _ = try wire(a, io, good.bytes.items, .{ .max_sql_bytes = 8 }, null, false, null);
    _ = try wire(a, io, good.bytes.items, .{ .max_sql_bytes = 7 }, error.SqlTooLarge, false, null);
    _ = try wire(a, io, good.bytes.items, .{ .max_message_bytes = description.len + 5 }, null, false, null);
    _ = try wire(a, io, good.bytes.items, .{ .max_message_bytes = description.len + 4 }, error.MessageTooLarge, false, null);
    _ = try wire(a, io, good.bytes.items, .{ .max_columns = 1 }, null, false, null);
    _ = try wire(a, io, good.bytes.items, .{ .max_columns = 0 }, error.ColumnLimit, false, null);
    _ = try wire(a, io, good.bytes.items, .{ .max_cell_bytes = 1 }, null, false, null);
    _ = try wire(a, io, good.bytes.items, .{ .max_cell_bytes = 0 }, error.CellTooLarge, false, null);
    _ = try wire(a, io, good.bytes.items, .{ .max_rows = 1 }, null, false, null);
    _ = try wire(a, io, good.bytes.items, .{ .max_rows = 0 }, error.RowLimit, false, null);
    const logical_bytes = @sizeOf(pg.PgRow) + @sizeOf(?[]const u8) + 1 + "SELECT 1".len;
    _ = try wire(a, io, good.bytes.items, .{ .max_result_bytes = logical_bytes }, null, false, null);
    _ = try wire(a, io, good.bytes.items, .{ .max_result_bytes = logical_bytes - 1 }, error.ResultTooLarge, false, null);

    var empty: Reply = .{ .a = a };
    defer empty.deinit();
    try empty.frame('I', "");
    try empty.frame('Z', "I");
    _ = try wire(a, io, empty.bytes.items, .{}, null, false, null); // V01
    var notices: Reply = .{ .a = a };
    defer notices.deinit();
    try notices.frame('N', "SNOTICE\x00Mfixture\x00\x00");
    try notices.frame('S', "application_name\x00owned\x00");
    try notices.bytes.appendSlice(a, good.bytes.items);
    _ = try wire(a, io, notices.bytes.items, .{}, null, false, null); // V04

    const c = try pg.PgClient.connect(a, io, config.host, config.port, config.user, config.password, config.database);
    defer c.close();
    var multiple = try c.query("SELECT 'first'; SELECT 'second'");
    defer multiple.deinit();
    try require(multiple.rows.len == 2);
    var next = try c.query("SELECT 3");
    next.deinit();
    try require(std.mem.eql(u8, multiple.rows[0].get(0).?, "first") and std.mem.eql(u8, multiple.rows[1].get(0).?, "second")); // V02
    if (c.query("SELECT 1/0")) |value| {
        var result = value;
        result.deinit();
        return error.ExpectedDatabaseError;
    } else |err| try require(err == error.DatabaseError);
    try require(c.reusable and c.transaction_status == .idle);
    var recovered = try c.query("SELECT 1");
    recovered.deinit(); // V03

    // Exercise configured pool admission and recovery as well as direct clients.
    var limited = config;
    limited.limits.max_rows = 1;
    const pool = try pg.Pool.init(a, io, limited);
    defer pool.deinit();
    const borrower = try pool.acquire();
    if (borrower.query("SELECT generate_series(1,2)")) |value| {
        var result = value;
        result.deinit();
        return error.PoolIgnoredLimits;
    } else |err| try require(err == error.RowLimit);
    pool.release(borrower);
    try require(pool.clients[0] == null and !pool.in_use[0]);
    const replacement = try pool.acquire();
    defer pool.release(replacement);
    var single = try replacement.query("SELECT 1");
    single.deinit();

    for (0..128) |index| {
        const failed = try wire(a, io, good.bytes.items, .{}, null, false, index);
        if (!failed) {
            try require(index > 0);
            return .{ .allocation_failures = index, .error_cleanup_elapsed_ms = error_elapsed };
        }
    }
    return error.AllocationFailureCaseLimit;
}
