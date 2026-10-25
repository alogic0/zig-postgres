//! Connection/acquisition deadlines, independently framed peers and owned SQL.
const std = @import("std");
const pg = @import("postgres");
const Io = std.Io;
const A = std.mem.Allocator;
fn require(ok: bool) !void {
    if (!ok) return error.NetworkCaseFailed;
}
fn end(io: Io, ms: u32) Io.Timestamp {
    return Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(ms));
}
fn opts(config: pg.PoolConfig) pg.ConnectOptions {
    return .{ .host = config.host, .port = config.port, .user = config.user, .password = config.password, .database = config.database, .tls = config.tls };
}
fn execute(c: *pg.PgClient, sql: []const u8) !void {
    var r = try c.query(sql);
    r.deinit();
}
const Peer = struct {
    io: Io,
    listener: Io.net.Server,
    mode: enum { stall, partial_auth, query_partial, cap, good },
    seen: Io.Event = .unset,
    closed: bool = false,
    fn serve(p: *Peer) !void {
        const s = try p.listener.accept(p.io);
        defer s.close(p.io);
        defer p.closed = true;
        var rb: [2048]u8 = undefined;
        var wb: [2048]u8 = undefined;
        var r = s.reader(p.io, &rb);
        var w = s.writer(p.io, &wb);
        const n = try r.interface.takeInt(u32, .big);
        if (n < 8 or n > 2048) return error.BadStartup;
        try r.interface.discardAll(n - 4);
        p.seen.set(p.io);
        if (p.mode == .partial_auth) {
            try w.interface.writeAll("R\x00\x00");
            try w.interface.flush();
        }
        if (p.mode == .stall or p.mode == .partial_auth) {
            try p.io.sleep(.fromSeconds(60), .awake);
            return error.UnexpectedWake;
        }
        if (p.mode == .cap) {
            try w.interface.writeAll("R\x00\x00\x00\x17\x00\x00\x00\x0aSCRAM-SHA-256\x00\x00");
            try w.interface.flush();
            try require(try r.interface.takeByte() == 'p');
            const size = try r.interface.takeInt(u32, .big);
            try require(size >= 4 and size < 2048);
            var first: [2048]u8 = undefined;
            try r.interface.readSliceAll(first[0 .. size - 4]);
            const offset = std.mem.lastIndexOf(u8, first[0 .. size - 4], "r=") orelse return error.MissingNonce;
            var buffer: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buffer, "r={s}server,s=c2FsdA==,i=100001", .{first[offset + 2 .. size - 4]});
            try w.interface.writeByte('R');
            try w.interface.writeInt(u32, @intCast(text.len + 8), .big);
            try w.interface.writeInt(u32, 11, .big);
            try w.interface.writeAll(text);
            try w.interface.flush();
            _ = r.interface.takeByte() catch |err| {
                if (err == error.EndOfStream) return;
                return err;
            };
            return error.UnexpectedProof;
        }
        try w.interface.writeAll("R\x00\x00\x00\x08\x00\x00\x00\x00Z\x00\x00\x00\x05I");
        try w.interface.flush();
        const tag = try r.interface.takeByte();
        const size = try r.interface.takeInt(u32, .big);
        try require(size >= 4 and size <= 2048);
        try r.interface.discardAll(size - 4);
        if (tag == 'X') return;
        if (p.mode == .good) {
            try w.interface.writeAll("C\x00\x00\x00\x0dSELECT 1\x00Z\x00\x00\x00\x05I");
            try w.interface.flush();
            return;
        }
        try w.interface.writeAll("Z\x00\x00\x00");
        try w.interface.flush();
        try p.io.sleep(.fromSeconds(60), .awake);
    }
};
fn connectCanceled(a: A, io: Io, options: pg.ConnectOptions) !void {
    if (pg.PgClient.connectOpts(a, io, options)) |c| {
        c.close();
        return error.ExpectedCanceled;
    } else |err| try require(err == error.Canceled);
}
fn waiting(pool: *pg.Pool) !void {
    if (pool.acquireOpts(.{})) |c| {
        pool.release(c);
        return error.ExpectedCanceled;
    } else |err| try require(err == error.Canceled);
}
fn peerCase(a: A, io: Io, config: pg.PoolConfig, mode: @FieldType(Peer, "mode"), cancel: bool, ipv6: bool) !i64 {
    var p: Peer = .{ .io = io, .listener = try (try Io.net.IpAddress.parse(if (ipv6) "::1" else "127.0.0.1", 0)).listen(io, .{}), .mode = mode };
    defer p.listener.deinit(io);
    var serving = try io.concurrent(Peer.serve, .{&p});
    defer serving.cancel(io) catch {};
    var options = opts(config);
    options.host = if (ipv6) "::1" else "localhost";
    options.port = p.listener.socket.address.getPort();
    options.deadline = end(io, 100);
    const start = Io.Timestamp.now(io, .awake);
    if (cancel) {
        options.deadline = end(io, 3000);
        var calling = try io.concurrent(connectCanceled, .{ a, io, options });
        defer calling.cancel(io) catch {};
        try p.seen.wait(io);
        try calling.cancel(io);
    } else if (mode == .cap) {
        try std.testing.expectError(error.ScramIterationLimit, pg.PgClient.connectOpts(a, io, options));
    } else if (mode == .good) {
        const c = try pg.PgClient.connectOpts(a, io, options);
        defer c.close();
        try require(c.address != null and c.address.?.getPort() == options.port);
        try execute(c, "SELECT 1");
    } else if (mode == .query_partial) {
        const c = try pg.PgClient.connectOpts(a, io, options);
        defer c.close();
        try std.testing.expectError(error.Timeout, c.queryOpts("SELECT 1", .{ .deadline = end(io, 100) }));
        try require(!c.reusable);
    } else try std.testing.expectError(error.Timeout, pg.PgClient.connectOpts(a, io, options));
    const elapsed = start.untilNow(io, .awake).toMilliseconds();
    if (mode == .stall or mode == .partial_auth) try require(elapsed <= 350 and (cancel or elapsed >= 75));
    if (mode == .query_partial) try require(elapsed >= 500 and elapsed <= 850);
    serving.cancel(io) catch |err| if (err != error.Canceled) return err;
    try require(p.closed);
    return elapsed;
}
// Delayed resolver using the real Io scheduler. The real localhost lookup is
// separately exercised above; this isolates deadline/cancellation during lookup.
var resolver_io: Io = undefined;
fn stalledLookup(_: ?*anyopaque, _: Io.net.HostName, resolved: *Io.Queue(Io.net.HostName.LookupResult), _: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
    defer resolved.close(resolver_io);
    try resolver_io.sleep(.fromSeconds(60), .awake);
    return error.UnknownHostName;
}
pub const Outcome = struct { cases: usize = 12, auth_timeout_ms: i64, partial_auth_ms: i64, query_timeout_ms: i64, pool_timeout_ms: i64, dns_timeout_ms: i64, canceled_connect_ms: i64 };
pub fn run(a: A, io: Io, config: pg.PoolConfig) !Outcome {
    var options = opts(config);
    options.host = "localhost";
    options.deadline = end(io, 3000);
    options.max_scram_iterations = 4096;
    const c = try pg.PgClient.connectOpts(a, io, options);
    defer c.close();
    try execute(c, "SELECT 1");
    try require(c.address != null);
    const auth = try peerCase(a, io, config, .stall, false, false);
    const partial = try peerCase(a, io, config, .partial_auth, false, false);
    const query_time = try peerCase(a, io, config, .query_partial, false, false);
    const canceled_connect = try peerCase(a, io, config, .stall, true, false);
    _ = try peerCase(a, io, config, .good, false, true);
    _ = try peerCase(a, io, config, .cap, false, false);
    options = opts(config);
    options.host = "pg-client-nonexistent.invalid";
    options.deadline = end(io, 300);
    if (pg.PgClient.connectOpts(a, io, options)) |bad| {
        bad.close();
        return error.ExpectedDnsFailure;
    } else |err| try require(err == error.ConnectionFailed or err == error.Timeout);
    resolver_io = io;
    var table = io.vtable.*;
    table.netLookup = stalledLookup;
    var dns_io = io;
    dns_io.vtable = &table;
    const dns_start = Io.Timestamp.now(io, .awake);
    options.host = "stalled.invalid";
    options.deadline = end(io, 100);
    try std.testing.expectError(error.Timeout, pg.PgClient.connectOpts(a, dns_io, options));
    const dns_time = dns_start.untilNow(io, .awake).toMilliseconds();
    try require(dns_time >= 75 and dns_time <= 350);
    var unused = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    options = opts(config);
    options.port = unused.socket.address.getPort();
    unused.deinit(io);
    options.deadline = end(io, 300);
    try std.testing.expectError(error.ConnectionFailed, pg.PgClient.connectOpts(a, io, options));
    const pool = try pg.Pool.init(a, io, config);
    defer pool.deinit();
    const held = try pool.acquire();
    var held_released = false;
    defer if (!held_released) pool.release(held);
    const start = Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, pool.acquireOpts(.{ .deadline = end(io, 100) }));
    const pool_time = start.untilNow(io, .awake).toMilliseconds();
    try require(pool_time >= 75 and pool_time <= 350 and pool.in_use[0]);
    var caller = try io.concurrent(waiting, .{pool});
    defer caller.cancel(io) catch {};
    try io.sleep(.fromMilliseconds(20), .awake);
    try caller.cancel(io);
    try require(pool.in_use[0]);
    pool.release(held);
    held_released = true;
    const fresh = try pool.acquireOpts(.{ .deadline = end(io, 1000) });
    defer pool.release(fresh);
    try execute(fresh, "SELECT 1");
    // A lazy slot stalled in authentication must be freed before returning timeout.
    var peer: Peer = .{ .io = io, .listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .mode = .stall };
    defer peer.listener.deinit(io);
    var server = try io.concurrent(Peer.serve, .{&peer});
    defer server.cancel(io) catch {};
    var cfg = config;
    cfg.port = peer.listener.socket.address.getPort();
    cfg.connect_timeout_ms = 100;
    const lazy = try pg.Pool.initLazy(a, io, cfg);
    defer lazy.deinit();
    try std.testing.expectError(error.Timeout, lazy.acquire());
    try require(!lazy.in_use[0] and lazy.clients[0] == null);
    server.cancel(io) catch |err| if (err != error.Canceled) return err;
    lazy.config.port = config.port;
    const replacement = try lazy.acquireOpts(.{ .deadline = end(io, 1000) });
    defer lazy.release(replacement);
    try execute(replacement, "SELECT 1");
    // Genuine lock wait, canceled query, discarded slot and responsive replacement.
    try execute(c, "CREATE TABLE pg4_lock(id integer)");
    defer execute(c, "DROP TABLE IF EXISTS pg4_lock") catch {};
    try execute(c, "BEGIN; LOCK TABLE pg4_lock IN ACCESS EXCLUSIVE MODE");
    var locked = true;
    defer if (locked) c.rollbackCleanup();
    const lock_pool = try pg.Pool.init(a, io, config);
    defer lock_pool.deinit();
    const blocked = try lock_pool.acquire();
    try std.testing.expectError(error.Timeout, blocked.queryOpts("SELECT * FROM pg4_lock", .{ .deadline = end(io, 100) }));
    try require(!blocked.reusable and blocked.transaction_status == .unknown);
    lock_pool.release(blocked);
    try require(!lock_pool.in_use[0] and lock_pool.clients[0] == null);
    try execute(c, "ROLLBACK");
    locked = false;
    const recovered = try lock_pool.acquireOpts(.{ .deadline = end(io, 1000) });
    defer lock_pool.release(recovered);
    try execute(recovered, "SELECT * FROM pg4_lock");
    return .{ .auth_timeout_ms = auth, .partial_auth_ms = partial, .query_timeout_ms = query_time, .pool_timeout_ms = pool_time, .dns_timeout_ms = dns_time, .canceled_connect_ms = canceled_connect };
}
