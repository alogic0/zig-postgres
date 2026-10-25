//! Protocol 3.0 cancellation of an exchange that will never be reused.
//! CancelRequest uses a separate connection. Its close does not prove rollback;
//! half-close and drain the original stream before returning, bounded to 500ms.
//! A lost COMMIT response remains ambiguous even after successful termination.
const std = @import("std");
pub const Key = struct { pid: u32, secret: u32 };

fn request(io: std.Io, address: std.Io.net.IpAddress, key: Key) !void {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var packet: [16]u8 = undefined;
    std.mem.writeInt(u32, packet[0..4], 16, .big);
    std.mem.writeInt(u32, packet[4..8], 80877102, .big);
    std.mem.writeInt(u32, packet[8..12], key.pid, .big);
    std.mem.writeInt(u32, packet[12..16], key.secret, .big);
    var buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(&packet);
    try writer.interface.flush();
    var byte: [1]u8 = undefined;
    var slices = [_][]u8{&byte};
    if ((try stream.readWithControl(io, &slices, &.{})).data_len != 0) return error.InvalidCancelResponse;
}
fn terminate(io: std.Io, address: ?std.Io.net.IpAddress, key: ?Key, original: std.Io.net.Stream) anyerror!void {
    if (address) |addr| if (key) |k| try request(io, addr, k);
    try original.shutdown(io, .send);
    // A fresh raw reader avoids reusing a buffered reader interrupted mid-frame.
    var buffer: [4096]u8 = undefined;
    var slices = [_][]u8{&buffer};
    while ((try original.readWithControl(io, &slices, &.{})).data_len != 0) {}
}
fn deadline(io: std.Io, end: std.Io.Timestamp) std.Io.Cancelable!void {
    const now = std.Io.Timestamp.now(io, .awake);
    if (now.nanoseconds < end.nanoseconds) try io.sleep(now.durationTo(end), .awake);
}
pub fn run(io: std.Io, address: ?std.Io.net.IpAddress, key: ?Key, original: std.Io.net.Stream) void {
    runUntil(io, address, key, original, std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(500)));
}
pub fn runUntil(io: std.Io, address: ?std.Io.net.IpAddress, key: ?Key, original: std.Io.net.Stream, end: std.Io.Timestamp) void {
    if (std.Io.Timestamp.now(io, .awake).nanoseconds >= end.nanoseconds) return;
    // Query cancellation has already been acknowledged. Cleanup tasks are
    // cancellable by their own joined deadline even if their caller is protected.
    const Result = union(enum) { terminated: anyerror!void, timeout: std.Io.Cancelable!void };
    var storage: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &storage);
    defer select.cancelDiscard();
    select.concurrent(.terminated, terminate, .{ io, address, key, original }) catch return;
    select.concurrent(.timeout, deadline, .{ io, end }) catch return;
    switch (select.await() catch return) {
        .terminated => |result| result catch {},
        .timeout => |result| result catch {},
    }
}

const Transport = @import("transport.zig").Transport;
fn requestTls(io: std.Io, address: std.Io.net.IpAddress, key: Key, original: *Transport) !void {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var rb: [64]u8 = undefined;
    var wb: [64]u8 = undefined;
    var reader = stream.reader(io, &rb);
    var writer = stream.writer(io, &wb);
    try writer.interface.writeAll("\x00\x00\x00\x08\x04\xd2\x16\x2f");
    try writer.interface.flush();
    if (try reader.interface.takeByte() != 'S') return error.TlsRefused;
    var session = try @import("tls.zig").Session.init(&original.context.?, original.allocator, io, stream, original.identity.?);
    defer session.deinit();
    var packet: [16]u8 = undefined;
    std.mem.writeInt(u32, packet[0..4], 16, .big);
    std.mem.writeInt(u32, packet[4..8], 80877102, .big);
    std.mem.writeInt(u32, packet[8..12], key.pid, .big);
    std.mem.writeInt(u32, packet[12..16], key.secret, .big);
    var rest: []const u8 = &packet;
    while (rest.len != 0) {
        const n = try session.write(rest);
        if (n == 0) return error.TlsIoError;
        rest = rest[n..];
    }
    var byte: [1]u8 = undefined;
    _ = session.read(&byte) catch |err| switch (err) {
        error.EndOfStream, error.TlsVerificationOrProtocolError => return,
        else => return err,
    };
    return error.InvalidCancelResponse;
}
fn terminateTransport(io: std.Io, address: ?std.Io.net.IpAddress, key: ?Key, original: *Transport) !void {
    const protection = io.swapCancelProtection(.unblocked);
    defer _ = io.swapCancelProtection(protection);
    if (comptime @import("postgres_options").tls) {
        if (original.context != null) {
            if (address) |addr| if (key) |k| try requestTls(io, addr, k, original);
            try original.stream.shutdown(io, .send);
            var bytes: [4096]u8 = undefined;
            var slices = [_][]u8{&bytes};
            while ((try original.stream.readWithControl(io, &slices, &.{})).data_len != 0) {}
            return;
        }
    }
    try terminate(io, address, key, original.stream);
}
pub fn runTransport(io: std.Io, address: ?std.Io.net.IpAddress, key: ?Key, original: *Transport, end: std.Io.Timestamp) void {
    if (std.Io.Timestamp.now(io, .awake).nanoseconds >= end.nanoseconds) return;
    const Result = union(enum) { terminated: anyerror!void, timeout: std.Io.Cancelable!void };
    var storage: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &storage);
    defer select.cancelDiscard();
    select.concurrent(.terminated, terminateTransport, .{ io, address, key, original }) catch return;
    select.concurrent(.timeout, deadline, .{ io, end }) catch return;
    switch (select.await() catch return) {
        .terminated => |result| result catch {},
        .timeout => |result| result catch {},
    }
}
