//! Stable buffered interfaces over plaintext or verified memory-BIO TLS.
const std = @import("std");
const Io = std.Io;
const Tls = @import("tls.zig");
const enabled = @import("postgres_options").tls;
pub const Transport = struct {
    io: Io,
    stream: Io.net.Stream,
    allocator: std.mem.Allocator,
    context: ?Tls.Context = null,
    session: ?Tls.Session = null,
    identity: ?[]u8 = null,
    pub fn enableTls(t: *Transport, options: Tls.Options, host: []const u8) !void {
        if (comptime !enabled) return error.TlsUnavailable;
        const identity = try t.allocator.dupe(u8, options.server_name orelse host);
        errdefer t.allocator.free(identity);
        var context = try Tls.Context.init(t.allocator, t.io, options.ca_file);
        errdefer context.deinit();
        var session = try Tls.Session.init(&context, t.allocator, t.io, t.stream, identity);
        errdefer session.deinit();
        t.context = context;
        t.session = session;
        t.identity = identity;
    }
    pub fn deinit(t: *Transport) void {
        if (comptime enabled) {
            if (t.session) |*session| session.deinit();
            if (t.context) |*context| context.deinit();
        }
        if (t.identity) |name| t.allocator.free(name);
    }
    pub fn read(t: *Transport, bytes: []u8) !usize {
        if (comptime enabled) if (t.session) |*session| return session.read(bytes);
        var slices = [_][]u8{bytes};
        return (try t.stream.readWithControl(t.io, &slices, &.{})).data_len;
    }
    pub fn write(t: *Transport, bytes: []const u8) !usize {
        if (comptime enabled) if (t.session) |*session| return session.write(bytes);
        return try (try t.io.operate(.{ .net_write = .{ .socket_handle = t.stream.socket.handle, .header = bytes, .data = &.{""}, .splat = 1 } })).net_write;
    }
};
pub const Reader = struct {
    owner: *Transport,
    err: ?anyerror = null,
    interface: Io.Reader,
    pub fn init(owner: *Transport, buffer: []u8) Reader {
        return .{ .owner = owner, .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = buffer, .seek = 0, .end = 0 } };
    }
    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        var data: [1][]u8 = .{limit.slice(try w.writableSliceGreedy(1))};
        const n = try readVec(r, &data);
        w.advance(n);
        return n;
    }
    fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", r));
        var vec: [8][]u8 = undefined;
        const count, const size = try r.writableVector(&vec, data);
        for (vec[0..count]) |bytes| if (bytes.len != 0) {
            const n = self.owner.read(bytes) catch |err| {
                self.err = err;
                return error.ReadFailed;
            };
            if (n == 0) return error.EndOfStream;
            if (n > size) {
                r.end += n - size;
                return size;
            }
            return n;
        };
        return 0;
    }
};
pub const Writer = struct {
    owner: *Transport,
    err: ?anyerror = null,
    interface: Io.Writer,
    pub fn init(owner: *Transport, buffer: []u8) Writer {
        return .{ .owner = owner, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }
    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        if (w.buffered().len != 0) {
            const n = self.owner.write(w.buffered()) catch |err| {
                self.err = err;
                return error.WriteFailed;
            };
            return w.consume(n);
        }
        for (data, 0..) |bytes, index| if (bytes.len != 0 and (index + 1 < data.len or splat != 0)) return self.owner.write(bytes) catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        return 0;
    }
};
