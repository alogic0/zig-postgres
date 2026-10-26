//! Public-API regressions using authenticated loopback peers, without Docker.
const std = @import("std");
const pg = @import("postgres");
const Io = std.Io;
const A = std.mem.Allocator;
const t = std.testing;
pub const Peer = struct {
    io: Io,
    listener: Io.net.Server,
    handlers: Io.Group = .init,
    connections: std.atomic.Value(usize) = .init(0),
    auth_limit: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),
    failed: std.atomic.Value(bool) = .init(false),
    query_delay_ms: std.atomic.Value(u32) = .init(0),
    query_seen: Io.Event = .unset,
    pub fn init(io: Io, limit: usize) !Peer {
        return .{ .io = io, .listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .auth_limit = .init(limit) };
    }
    pub fn config(self: *Peer, size: u32) pg.PoolConfig {
        return .{ .port = self.listener.socket.address.getPort(), .user = "owned", .password = "owned", .database = "pool-regression", .size = size, .connect_timeout_ms = 150 };
    }
    pub fn serve(self: *Peer) !void {
        while (true) {
            const stream = try self.listener.accept(self.io);
            const ordinal = self.connections.fetchAdd(1, .acq_rel);
            self.handlers.concurrent(self.io, session, .{ self, stream, ordinal }) catch |err| {
                stream.close(self.io);
                return err;
            };
        }
    }
    pub fn close(self: *Peer) void {
        self.handlers.cancel(self.io);
        self.listener.deinit(self.io);
    }
    fn session(self: *Peer, stream: Io.net.Stream, ordinal: usize) void {
        defer stream.close(self.io);
        self.exchange(stream, ordinal) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed, error.WriteFailed, error.Canceled => {},
            else => self.failed.store(true, .release),
        };
    }
    fn exchange(self: *Peer, stream: Io.net.Stream, ordinal: usize) !void {
        var rb: [2048]u8 = undefined;
        var wb: [2048]u8 = undefined;
        var r = stream.reader(self.io, &rb);
        var w = stream.writer(self.io, &wb);
        const startup = try r.interface.takeInt(u32, .big);
        if (startup < 8 or startup > rb.len) return error.InvalidStartup;
        try r.interface.discardAll(startup - 4);
        if (ordinal >= self.auth_limit.load(.acquire)) {
            _ = try r.interface.takeByte();
            return error.UnexpectedInput;
        }
        try w.interface.writeAll("R\x00\x00\x00\x08\x00\x00\x00\x00Z\x00\x00\x00\x05I");
        try w.interface.flush();
        while (true) {
            const tag = try r.interface.takeByte();
            const length = try r.interface.takeInt(u32, .big);
            if (length < 4 or length > rb.len) return error.InvalidQuery;
            try r.interface.discardAll(length - 4);
            if (tag == 'X') return;
            if (tag != 'Q') return error.InvalidQuery;
            self.query_seen.set(self.io);
            const delay = self.query_delay_ms.load(.acquire);
            if (delay != 0) try self.io.sleep(.fromMilliseconds(delay), .awake);
            try w.interface.writeAll("T\x00\x00\x00\x1a\x00\x01v\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x17\x00\x04\xff\xff\xff\xff\x00\x00D\x00\x00\x00\x0b\x00\x01\x00\x00\x00\x011C\x00\x00\x00\x0dSELECT 1\x00Z\x00\x00\x00\x05I");
            try w.interface.flush();
        }
    }
};
fn end(io: Io, ms: i64) Io.Timestamp {
    return Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(ms));
}
fn query(client: *pg.PgClient) !void {
    var r = try client.queryOpts("SELECT 1", .{ .deadline = end(client.io, 500) });
    defer r.deinit();
    try t.expectEqualStrings("1", r.rows[0].get(0).?);
}
fn canceled(pool: *pg.Pool, started: *Io.Event) !void {
    started.set(pool.io);
    const client = try pool.acquire();
    defer pool.release(client);
    return error.UnexpectedAcquisition;
}
fn churn(pool: *pg.Pool) !void {
    for (0..12) |i| {
        const c = try pool.acquireOpts(.{ .deadline = end(pool.io, 2000) });
        if (i % 3 == 0) pool.discard(c) else {
            query(c) catch |err| {
                pool.release(c);
                return err;
            };
            pool.release(c);
        }
    }
}
test "ready idle connection wins over an earlier empty slot without reconnect" {
    const io = t.io;
    var peer = try Peer.init(io, 2);
    defer peer.close();
    var server = try io.concurrent(Peer.serve, .{&peer});
    defer server.cancel(io) catch {};
    const pool = try pg.Pool.init(t.allocator, io, peer.config(2));
    defer pool.deinit();
    const first = try pool.acquire();
    const second = try pool.acquire();
    pool.release(second);
    pool.discard(first);
    const ready = try pool.acquireOpts(.{ .deadline = end(io, 120) });
    defer pool.release(ready);
    try t.expect(ready == second);
    try query(ready);
    try t.expectEqual(@as(usize, 2), peer.connections.load(.acquire));
    try t.expect(!peer.failed.load(.acquire));
}
test "empty busy failed canceled and concurrent slots recover their ownership" {
    const io = t.io;
    var peer = try Peer.init(io, std.math.maxInt(usize));
    defer peer.close();
    var server = try io.concurrent(Peer.serve, .{&peer});
    defer server.cancel(io) catch {};
    const pool = try pg.Pool.initLazy(t.allocator, io, peer.config(2));
    defer pool.deinit();
    const first = try pool.acquire();
    const second = try pool.acquire();
    try t.expectError(error.Timeout, pool.acquireOpts(.{ .deadline = end(io, 30) }));
    var started: Io.Event = .unset;
    var waiter = try io.concurrent(canceled, .{ pool, &started });
    try started.wait(io);
    try t.expectError(error.Canceled, waiter.cancel(io));
    pool.release(first);
    pool.release(second);
    var left = try io.concurrent(churn, .{pool});
    defer left.cancel(io) catch {};
    var right = try io.concurrent(churn, .{pool});
    defer right.cancel(io) catch {};
    try left.await(io);
    try right.await(io);
    const a = try pool.acquire();
    const b = try pool.acquire();
    pool.discard(a);
    pool.discard(b);
    peer.auth_limit.store(0, .release);
    try t.expectError(error.Timeout, pool.acquireOpts(.{ .deadline = end(io, 30) }));
    try t.expect(!pool.in_use[0] and !pool.in_use[1]);
    const before_cancel = peer.connections.load(.acquire);
    started = .unset;
    var connecting = try io.concurrent(canceled, .{ pool, &started });
    defer connecting.cancel(io) catch {};
    const cancel_end = end(io, 2000);
    while (peer.connections.load(.acquire) == before_cancel) {
        if (Io.Timestamp.now(io, .awake).nanoseconds >= cancel_end.nanoseconds) return error.ConnectNotObserved;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try t.expectError(error.Canceled, connecting.cancel(io));
    try t.expect(!pool.in_use[0] and !pool.in_use[1]);
    peer.auth_limit.store(std.math.maxInt(usize), .release);
    const recovered = try pool.acquireOpts(.{ .deadline = end(io, 500) });
    try query(recovered);
    pool.release(recovered);
    try t.expect(!pool.in_use[0] and !pool.in_use[1] and !peer.failed.load(.acquire));
}

fn health(pool: *pg.Pool, started: *Io.Event) !void {
    started.set(pool.io);
    _ = try pool.healthCheckOpts(.{ .deadline = end(pool.io, 5000) });
    return error.ExpectedCanceled;
}
fn releaseAfter(pool: *pg.Pool, client: *pg.PgClient, ms: u32) !void {
    defer pool.release(client);
    try pool.io.sleep(.fromMilliseconds(ms), .awake);
}
test "health covers exhausted pool and canceled waiters and recovers" {
    const io = t.io;
    var peer = try Peer.init(io, std.math.maxInt(usize));
    defer peer.close();
    var server = try io.concurrent(Peer.serve, .{&peer});
    defer server.cancel(io) catch {};
    const pool = try pg.Pool.init(t.allocator, io, peer.config(1));
    defer pool.deinit();
    const held = try pool.acquire();
    try t.expectError(error.Timeout, pool.healthCheckOpts(.{ .deadline = end(io, 30) }));
    var started: Io.Event = .unset;
    var task = try io.concurrent(health, .{ pool, &started });
    try started.wait(io);
    try t.expectError(error.Canceled, task.cancel(io));
    pool.release(held);
    try t.expect(try pool.healthCheckOpts(.{ .deadline = end(io, 500) }));
    try t.expect(!pool.in_use[0]);
}
test "health query cancellation and stalled response release or discard borrower" {
    const io = t.io;
    var peer = try Peer.init(io, std.math.maxInt(usize));
    defer peer.close();
    var server = try io.concurrent(Peer.serve, .{&peer});
    defer server.cancel(io) catch {};
    const pool = try pg.Pool.init(t.allocator, io, peer.config(1));
    defer pool.deinit();
    peer.query_delay_ms.store(2000, .release);
    try t.expectError(error.Timeout, pool.healthCheckOpts(.{ .deadline = end(io, 30) }));
    try t.expect(!pool.in_use[0]);
    peer.query_seen = .unset;
    var started: Io.Event = .unset;
    var task = try io.concurrent(health, .{ pool, &started });
    defer task.cancel(io) catch {};
    try peer.query_seen.wait(io);
    try t.expectError(error.Canceled, task.cancel(io));
    try t.expect(!pool.in_use[0]);
    peer.query_delay_ms.store(0, .release);
    try t.expect(try pool.healthCheckOpts(.{ .deadline = end(io, 500) }));
}
test "health query receives remaining deadline rather than a renewed acquisition budget" {
    const io = t.io;
    var peer = try Peer.init(io, std.math.maxInt(usize));
    defer peer.close();
    var server = try io.concurrent(Peer.serve, .{&peer});
    defer server.cancel(io) catch {};
    const pool = try pg.Pool.init(t.allocator, io, peer.config(1));
    defer pool.deinit();
    const held = try pool.acquire();
    var release = try io.concurrent(releaseAfter, .{ pool, held, @as(u32, 80) });
    defer release.cancel(io) catch {};
    peer.query_delay_ms.store(80, .release);
    try t.expectError(error.Timeout, pool.healthCheckOpts(.{ .deadline = end(io, 120) }));
    try release.await(io);
    try t.expect(!pool.in_use[0]);
    peer.query_delay_ms.store(0, .release);
    try t.expect(try pool.healthCheckOpts(.{ .deadline = end(io, 500) }));
}
