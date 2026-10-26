//! Controlled PostgreSQL SSLRequest relay. Test-only; no production SQL policy.
//! The relay drives the server side of TLS with OpenSSL memory BIOs.
const std = @import("std");
const pg = @import("postgres");
const Io = std.Io;
const A = std.mem.Allocator;
const Tls = pg.tls;
const Counter = std.atomic.Value(usize);
fn require(ok: bool) !void {
    if (!ok) return error.BadTlsFixtureProtocol;
}
const Server = struct {
    context: Tls.Context,
    fn init(a: A, io: Io, ca: []const u8, cert: []const u8, key: []const u8) !Server {
        if (comptime !pg.tls_enabled) return error.TlsUnavailable;
        var context = try Tls.Context.init(a, io, ca);
        errdefer context.deinit();
        const f = context.api;
        const handle = f.SSL_CTX_new(f.TLS_server_method()) orelse return error.OutOfMemory;
        f.SSL_CTX_free(context.handle);
        context.handle = handle;
        const certificate = try a.dupeSentinel(u8, cert, 0);
        defer a.free(certificate);
        const private_key = try a.dupeSentinel(u8, key, 0);
        defer a.free(private_key);
        if (f.SSL_CTX_use_certificate_chain_file(handle, certificate) != 1 or f.SSL_CTX_use_PrivateKey_file(handle, private_key, 1) != 1) return error.InvalidFixtureCertificate;
        return .{ .context = context };
    }
    fn deinit(self: *Server) void {
        self.context.deinit();
    }
    fn session(self: *Server, io: Io, stream: Io.net.Stream) !Tls.Session {
        const f = self.context.api;
        const ssl = f.SSL_new(self.context.handle) orelse return error.OutOfMemory;
        errdefer f.SSL_free(ssl);
        const input = f.BIO_new(f.BIO_s_mem()) orelse return error.OutOfMemory;
        f.SSL_set0_rbio(ssl, input);
        const output = f.BIO_new(f.BIO_s_mem()) orelse return error.OutOfMemory;
        f.SSL_set0_wbio(ssl, output);
        _ = f.BIO_ctrl(input, 130, -1, null);
        f.SSL_set_accept_state(ssl);
        return .{ .api = f, .handle = ssl, .input = input, .output = output, .stream = stream, .io = io };
    }
};
const Channel = struct {
    session: *Tls.Session,
    fn read(c: Channel, bytes: []u8) !void {
        var rest = bytes;
        while (rest.len != 0) {
            const n = try c.session.read(rest);
            if (n == 0) return error.EndOfStream;
            rest = rest[n..];
        }
    }
    fn write(c: Channel, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len != 0) {
            const n = try c.session.write(rest);
            if (n == 0) return error.EndOfStream;
            rest = rest[n..];
        }
    }
};
pub const Options = struct {
    database: []const u8,
    ca: []const u8,
    certificate: []const u8,
    key: []const u8,
    upstream_port: u16 = 5433,
    mode: enum { relay, refuse, stall, truncated } = .relay,
};
pub const Relay = struct {
    allocator: A,
    io: Io,
    options: Options,
    listener: Io.net.Server,
    server: Server,
    tasks: Io.Group = .init,
    connections: Counter = .init(0),
    ssl_requests: Counter = .init(0),
    startups: Counter = .init(0),
    encrypted_cancels: Counter = .init(0),
    closed: Counter = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    drop_commit: std.atomic.Value(bool) = .init(false),
    stall_rollback: std.atomic.Value(bool) = .init(false),
    dropped: Counter = .init(0),
    rollbacks_stalled: Counter = .init(0),
    pub fn init(a: A, io: Io, options: Options) !Relay {
        if (!std.mem.startsWith(u8, options.database, "zg_parity_upgrade_") and !std.mem.startsWith(u8, options.database, "zg_parity_contact_access_") and !standaloneDatabase(options.database)) return error.OwnedDatabaseRequired;
        var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
        errdefer listener.deinit(io);
        return .{ .allocator = a, .io = io, .options = options, .listener = listener, .server = try Server.init(a, io, options.ca, options.certificate, options.key) };
    }
    pub fn port(self: *const Relay) u16 {
        return self.listener.socket.address.getPort();
    }
    pub fn start(self: *Relay) !void {
        try self.tasks.concurrent(self.io, listen, .{self});
    }
    pub fn stop(self: *Relay) void {
        self.tasks.cancel(self.io);
        self.listener.deinit(self.io);
        self.server.deinit();
    }
    fn listen(self: *Relay) Io.Cancelable!void {
        while (true) {
            const stream = self.listener.accept(self.io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                self.failed.store(true, .release);
                return;
            };
            self.tasks.concurrent(self.io, connection, .{ self, stream }) catch |err| {
                stream.close(self.io);
                if (err == error.Canceled) return error.Canceled;
                self.failed.store(true, .release);
                return;
            };
        }
    }
    fn connection(self: *Relay, stream: Io.net.Stream) void {
        defer stream.close(self.io);
        _ = self.connections.fetchAdd(1, .monotonic);
        defer _ = self.closed.fetchAdd(1, .release);
        self.serve(stream) catch |err| switch (err) {
            error.Canceled, error.EndOfStream, error.ReadFailed, error.WriteFailed, error.ConnectionResetByPeer, error.TlsVerificationOrProtocolError, error.TlsIoError => {},
            else => {
                self.failed.store(true, .release);
                std.debug.print("TLS fixture failure: {s}\n", .{@errorName(err)});
            },
        };
    }
    fn serve(self: *Relay, stream: Io.net.Stream) !void {
        var rb: [4096]u8 = undefined;
        var wb: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &rb);
        var writer = stream.writer(self.io, &wb);
        const request = try reader.interface.takeArray(8);
        try require(std.mem.eql(u8, request, "\x00\x00\x00\x08\x04\xd2\x16\x2f"));
        _ = self.ssl_requests.fetchAdd(1, .monotonic);
        if (self.options.mode == .refuse) {
            try writer.interface.writeAll("N");
            try writer.interface.flush();
            _ = try reader.interface.takeByte();
            return error.PlaintextFallback;
        }
        try writer.interface.writeAll("S");
        try writer.interface.flush();
        if (self.options.mode == .stall) {
            try self.io.sleep(.fromSeconds(60), .awake);
            return;
        }
        if (self.options.mode == .truncated) {
            try writer.interface.writeAll("\x16\x03");
            try writer.interface.flush();
            return;
        }
        var session = try self.server.session(self.io, stream);
        defer session.deinit();
        try session.handshake();
        const channel: Channel = .{ .session = &session };
        const upstream = try (try Io.net.IpAddress.parse("127.0.0.1", self.options.upstream_port)).connect(self.io, .{ .mode = .stream });
        defer upstream.close(self.io);
        var urbuf: [8192]u8 = undefined;
        var uwbuf: [8192]u8 = undefined;
        var ur = upstream.reader(self.io, &urbuf);
        var uw = upstream.writer(self.io, &uwbuf);
        var length: [4]u8 = undefined;
        try channel.read(&length);
        const size = std.mem.readInt(u32, &length, .big);
        try require(size >= 8 and size <= 1024);
        const startup = try self.allocator.alloc(u8, size);
        defer self.allocator.free(startup);
        @memcpy(startup[0..4], &length);
        try channel.read(startup[4..]);
        if (size == 16 and std.mem.readInt(u32, startup[4..8], .big) == 80877102) {
            _ = self.encrypted_cancels.fetchAdd(1, .release);
            try uw.interface.writeAll(startup);
            try uw.interface.flush();
            _ = try ur.interface.takeByte();
            return error.InvalidCancelReply;
        }
        try require(std.mem.readInt(u32, startup[4..8], .big) == 196608);
        const label = "database\x00";
        const at = std.mem.indexOf(u8, startup[8..], label) orelse return error.MissingDatabase;
        const begin = 8 + at + label.len;
        const zero = std.mem.indexOfScalar(u8, startup[begin..], 0) orelse return error.MissingDatabase;
        try require(std.mem.eql(u8, startup[begin..][0..zero], self.options.database));
        _ = self.startups.fetchAdd(1, .release);
        try uw.interface.writeAll(startup);
        try uw.interface.flush();
        while (true) {
            const frame = try serverFrame(self.allocator, &ur.interface);
            defer self.allocator.free(frame);
            try channel.write(frame);
            if (frame[0] == 'Z') break;
            if (frame[0] == 'R') {
                try require(frame.len >= 9);
                const auth = std.mem.readInt(u32, frame[5..9], .big);
                if (auth == 3 or auth == 5 or auth == 10 or auth == 11) {
                    const response = try clientFrame(self.allocator, channel);
                    defer self.allocator.free(response);
                    try require(response[0] == 'p');
                    try uw.interface.writeAll(response);
                    try uw.interface.flush();
                }
            }
        }
        while (true) {
            const frame = try clientFrame(self.allocator, channel);
            defer self.allocator.free(frame);
            if (frame[0] == 'Q' and self.stall_rollback.load(.acquire) and std.mem.eql(u8, frame[5..], "ROLLBACK\x00")) {
                _ = self.rollbacks_stalled.fetchAdd(1, .release);
                var abandoned: [1]u8 = undefined;
                try channel.read(&abandoned);
                return error.UnexpectedRollbackRetry;
            }
            try uw.interface.writeAll(frame);
            if (frame[0] == 'X') {
                try uw.interface.flush();
                return;
            }
            if (frame[0] != 'Q' and frame[0] != 'S') continue;
            try uw.interface.flush();
            while (true) {
                const reply = try serverFrame(self.allocator, &ur.interface);
                defer self.allocator.free(reply);
                if (reply[0] == 'C' and std.mem.eql(u8, reply[5..], "COMMIT\x00") and self.drop_commit.swap(false, .acq_rel)) {
                    _ = self.dropped.fetchAdd(1, .release);
                    return;
                }
                try channel.write(reply);
                if (reply[0] == 'Z') break;
            }
        }
    }
};

fn standaloneDatabase(name: []const u8) bool {
    const prefix = "zig_postgres_live_";
    if (!std.mem.startsWith(u8, name, prefix) or name.len != prefix.len + 12) return false;
    for (name[prefix.len..]) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    return true;
}
fn serverFrame(a: A, r: *Io.Reader) ![]u8 {
    const header = try r.takeArray(5);
    const size = std.mem.readInt(u32, header[1..5], .big);
    try require(size >= 4 and size <= 16 * 1024 * 1024);
    const frame = try a.alloc(u8, size + 1);
    errdefer a.free(frame);
    @memcpy(frame[0..5], header);
    try r.readSliceAll(frame[5..]);
    return frame;
}
fn clientFrame(a: A, c: Channel) ![]u8 {
    var header: [5]u8 = undefined;
    try c.read(&header);
    const size = std.mem.readInt(u32, header[1..5], .big);
    try require(size >= 4 and size <= 32 * 1024 * 1024);
    const frame = try a.alloc(u8, size + 1);
    errdefer a.free(frame);
    @memcpy(frame[0..5], &header);
    try c.read(frame[5..]);
    return frame;
}
