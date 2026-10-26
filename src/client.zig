//! Native PostgreSQL wire protocol v3 client with trust, password and SCRAM authentication.
const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const Scram = @import("scram.zig");
const protocol = @import("protocol.zig");
const parameters = @import("parameters.zig");
const deadline = @import("deadline.zig");
const Transport = @import("transport.zig");
const Tls = @import("tls.zig");
pub const Limits = protocol.Limits;
pub const QueryOptions = struct { deadline: ?std.Io.Timestamp = null };
pub const ConnectOptions = struct {
    host: []const u8 = "localhost",
    port: u16 = 5432,
    user: []const u8 = "postgres",
    password: []const u8 = "",
    database: []const u8 = "postgres",
    deadline: ?std.Io.Timestamp = null,
    max_scram_iterations: u32 = 100000,
    tls: Tls.Options = .{},
};

pub const PgError = error{
    ConnectionFailed,
    AuthenticationFailed,
    UnsupportedAuthType,
    DatabaseError,
    ProtocolViolation,
    UnexpectedEof,
    BufferTooSmall,
} || protocol.Error;

pub const TransactionStatus = enum { unknown, idle, transaction, failed_transaction };

pub const PgRow = struct {
    allocator: std.mem.Allocator,
    values: []const ?[]const u8,

    pub fn deinit(self: *PgRow) void {
        for (self.values) |val| {
            if (val) |v| self.allocator.free(v);
        }
        self.allocator.free(self.values);
    }

    /// Deprecated permissive bounds behavior; use getChecked/getTyped. 0.4
    /// changes this signature; 0.3 retains compatibility with existing callers.
    pub fn get(self: PgRow, index: usize) ?[]const u8 {
        if (index >= self.values.len) return null;
        return self.values[index];
    }

    pub fn getChecked(self: PgRow, index: usize) error{ColumnOutOfBounds}!?[]const u8 {
        if (index >= self.values.len) return error.ColumnOutOfBounds;
        return self.values[index];
    }

    /// Required T or nullable ?T; text remains owned by this row.
    pub fn getTyped(self: PgRow, comptime T: type, index: usize) !T {
        return @import("decode.zig").value(T, try self.getChecked(index));
    }

    /// Deprecated in 0.3: use getTyped(?T, index); removal scheduled for 0.4.
    pub fn getInt(self: PgRow, index: usize, comptime T: type) !?T {
        const str = self.get(index) orelse return null;
        return try std.fmt.parseInt(T, str, 10);
    }

    /// Deprecated in 0.3: use getTyped(?bool, index); removal scheduled for 0.4.
    pub fn getBool(self: PgRow, index: usize) !?bool {
        const str = self.get(index) orelse return null;
        if (str.len == 0) return null;
        return (str[0] == 't' or str[0] == 'T' or str[0] == '1');
    }
};

pub const PgResult = struct {
    allocator: std.mem.Allocator,
    rows: []PgRow,
    command_tag: []const u8,

    pub fn deinit(self: *PgResult) void {
        for (self.rows) |*row| {
            row.deinit();
        }
        self.allocator.free(self.rows);
        self.allocator.free(self.command_tag);
    }
};

pub const PgClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    transport: Transport.Transport,
    net_reader: Transport.Reader,
    net_writer: Transport.Writer,
    /// Owned error fields for the last query; cleared before each new exchange.
    last_diagnostic: ?diagnostic.Diagnostic = null,
    /// An incomplete exchange cannot safely be returned to a connection pool.
    reusable: bool = true,
    transaction_status: TransactionStatus = .unknown,
    limits: Limits = .{},
    cleanup_deadline: ?std.Io.Timestamp = null,
    operation_deadline: ?std.Io.Timestamp = null,
    address: ?std.Io.net.IpAddress = null,
    cancel_key: ?@import("cancel.zig").Key = null,
    max_scram_iterations: u32 = 100000,
    active_stream: ?*@import("stream.zig").Stream = null,

    const BUFFER_SIZE = 16384;

    pub fn connect(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
        user: []const u8,
        password: []const u8,
        database: []const u8,
    ) !*PgClient {
        return connectOpts(allocator, io, .{ .host = host, .port = port, .user = user, .password = password, .database = database, .tls = .{ .mode = .disable } });
    }

    const ConnectWork = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        options: ConnectOptions,
        result: ?*PgClient = null,
        fn run(self: *ConnectWork) !void {
            self.result = try connectInternal(self.allocator, self.io, self.options);
        }
    };
    pub fn connectOpts(allocator: std.mem.Allocator, io: std.Io, options: ConnectOptions) !*PgClient {
        if (options.tls.mode == .verify_full) {
            if (comptime !@import("postgres_options").tls) return error.TlsUnavailable;
            const name = options.tls.server_name orelse options.host;
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidTlsIdentity;
            if (std.Io.net.IpAddress.parse(name, 0)) |_| {} else |_| {
                _ = std.Io.net.HostName.init(name) catch return error.InvalidTlsIdentity;
            }
        }
        if (options.max_scram_iterations == 0 or options.max_scram_iterations > 1000000) return error.InvalidScramLimit;
        var work: ConnectWork = .{ .allocator = allocator, .io = io, .options = options };
        errdefer if (work.result) |client| client.disconnect();
        try deadline.run(io, options.deadline, ConnectWork.run, .{&work});
        return work.result.?;
    }

    const Endpoint = struct { stream: std.Io.net.Stream, address: std.Io.net.IpAddress };
    fn connectEndpoint(io: std.Io, host: []const u8, port: u16) !Endpoint {
        if (std.Io.net.IpAddress.parse(host, port)) |address| {
            return .{ .stream = address.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
                error.Canceled, error.Timeout => return err,
                else => return error.ConnectionFailed,
            }, .address = address };
        } else |_| {}
        const name = std.Io.net.HostName.init(host) catch return error.ConnectionFailed;
        var storage: [32]std.Io.net.HostName.LookupResult = undefined;
        var resolved: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&storage);
        var lookup = io.async(std.Io.net.HostName.lookup, .{ name, io, &resolved, .{ .port = port } });
        defer lookup.cancel(io) catch {};
        // Resolver order, one shared deadline. Socket.address is the *local*
        // endpoint in Zig0.17; retain the selected remote address explicitly.
        while (resolved.getOne(io)) |result| switch (result) {
            .canonical_name => {},
            .address => |address| {
                const stream = address.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
                    error.Canceled, error.Timeout => return err,
                    else => continue,
                };
                return .{ .stream = stream, .address = address };
            },
        } else |err| switch (err) {
            error.Canceled => return err,
            error.Closed => {},
        }
        lookup.await(io) catch |err| switch (err) {
            error.Canceled => return err,
            else => return error.ConnectionFailed,
        };
        return error.ConnectionFailed;
    }

    fn connectInternal(allocator: std.mem.Allocator, io: std.Io, options: ConnectOptions) !*PgClient {
        const endpoint = try connectEndpoint(io, options.host, options.port);
        const stream = endpoint.stream;
        errdefer stream.close(io);

        const read_buf = try allocator.alloc(u8, BUFFER_SIZE);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, BUFFER_SIZE);
        errdefer allocator.free(write_buf);

        const self = try allocator.create(PgClient);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .transport = .{ .io = io, .stream = stream, .allocator = allocator },
            .net_reader = undefined,
            .net_writer = undefined,
            .address = endpoint.address,
            .max_scram_iterations = options.max_scram_iterations,
        };

        self.net_reader = Transport.Reader.init(&self.transport, read_buf);
        self.net_writer = Transport.Writer.init(&self.transport, write_buf);
        errdefer self.transport.deinit();
        if (options.tls.mode == .verify_full) self.startTls(options) catch |err| return self.ioError(err);
        self.handshake(options.user, options.password, options.database) catch |err| return self.ioError(err);
        return self;
    }

    fn startTls(self: *PgClient, options: ConnectOptions) !void {
        const packet = [_]u8{ 0, 0, 0, 8, 4, 210, 22, 47 };
        try self.net_writer.interface.writeAll(&packet);
        try self.net_writer.interface.flush();
        if (try self.net_reader.interface.takeByte() != 'S') return error.TlsRefused;
        try self.transport.enableTls(options.tls, options.host);
    }
    fn terminateTask(self: *PgClient) !void {
        try self.net_writer.interface.writeAll("X\x00\x00\x00\x04");
        try self.net_writer.interface.flush();
    }
    pub fn close(self: *PgClient) void {
        if (self.active_stream != null) self.reusable = false;
        if (self.reusable) {
            const protection = self.io.swapCancelProtection(.blocked);
            defer _ = self.io.swapCancelProtection(protection);
            deadline.run(self.io, std.Io.Timestamp.now(self.io, .awake).addDuration(.fromMilliseconds(500)), terminateTask, .{self}) catch {};
        }
        self.disconnect();
    }

    /// Abort without writing into a failed or canceled protocol exchange.
    pub fn disconnect(self: *PgClient) void {
        if (self.active_stream) |active| {
            active.generation +%= 1;
            active.client = null;
        }
        self.active_stream = null;
        self.transport.deinit();
        self.stream.close(self.io);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.allocator.destroy(self);
    }

    fn readByte(self: *PgClient) !u8 {
        var b: [1]u8 = undefined;
        try self.net_reader.interface.readSliceAll(&b);
        return b[0];
    }

    fn handshake(self: *PgClient, user: []const u8, password: []const u8, database: []const u8) !void {
        const writer = &self.net_writer.interface;

        // 1. Send StartupMessage
        var startup_buf: [512]u8 = undefined;
        if (user.len > 487 or database.len > 487 or user.len + database.len > 487) return PgError.BufferTooSmall;
        var cursor: usize = 4;
        std.mem.writeInt(u32, startup_buf[cursor..][0..4], 0x00030000, .big);
        cursor += 4;

        @memcpy(startup_buf[cursor..][0..5], "user\x00");
        cursor += 5;
        @memcpy(startup_buf[cursor..][0..user.len], user);
        startup_buf[cursor + user.len] = 0;
        cursor += user.len + 1;

        @memcpy(startup_buf[cursor..][0..9], "database\x00");
        cursor += 9;
        @memcpy(startup_buf[cursor..][0..database.len], database);
        startup_buf[cursor + database.len] = 0;
        cursor += database.len + 1;

        startup_buf[cursor] = 0;
        cursor += 1;

        std.mem.writeInt(u32, startup_buf[0..4], @intCast(cursor), .big);
        try writer.writeAll(startup_buf[0..cursor]);
        try writer.flush();

        // Bound frames before slicing, and require authentication before ReadyForQuery.
        var authenticated = false;
        var storage: [1024]u8 = undefined;
        while (true) {
            const frame = try self.readStartupFrame(&storage);
            switch (frame.tag) {
                'R' => {
                    if (authenticated or frame.body.len < 4) return PgError.ProtocolViolation;
                    const auth_type = std.mem.readInt(u32, frame.body[0..4], .big);
                    switch (auth_type) {
                        0 => {
                            if (frame.body.len != 4) return PgError.ProtocolViolation;
                            authenticated = true;
                        },
                        3 => {
                            if (frame.body.len != 4 or password.len > 250) return PgError.ProtocolViolation;
                            var pw_msg: [256]u8 = undefined;
                            pw_msg[0] = 'p';
                            std.mem.writeInt(u32, pw_msg[1..5], @intCast(5 + password.len), .big);
                            @memcpy(pw_msg[5..][0..password.len], password);
                            pw_msg[5 + password.len] = 0;
                            try writer.writeAll(pw_msg[0 .. 6 + password.len]);
                            try writer.flush();
                        },
                        10 => {
                            if (!Scram.supportsSha256(frame.body[4..])) return PgError.UnsupportedAuthType;
                            try self.handleScramAuth(user, password);
                            authenticated = true;
                        },
                        else => return PgError.UnsupportedAuthType,
                    }
                },
                'S' => {
                    if (!authenticated) return PgError.ProtocolViolation;
                },
                'K' => {
                    if (!authenticated or frame.body.len != 8) return PgError.ProtocolViolation;
                    self.cancel_key = .{ .pid = std.mem.readInt(u32, frame.body[0..4], .big), .secret = std.mem.readInt(u32, frame.body[4..8], .big) };
                },
                'Z' => {
                    if (!authenticated or frame.body.len != 1 or frame.body[0] != 'I') return PgError.ProtocolViolation;
                    self.transaction_status = .idle;
                    return;
                },
                'E' => return PgError.AuthenticationFailed,
                'N' => {},
                else => return PgError.ProtocolViolation,
            }
        }
    }

    const StartupFrame = struct { tag: u8, body: []const u8 };
    fn readStartupFrame(self: *PgClient, storage: []u8) !StartupFrame {
        const tag = try self.readByte();
        var length: [4]u8 = undefined;
        try self.net_reader.interface.readSliceAll(&length);
        const size = std.mem.readInt(u32, &length, .big);
        if (size < 4 or size - 4 > storage.len) return PgError.ProtocolViolation;
        const body = storage[0 .. size - 4];
        try self.net_reader.interface.readSliceAll(body);
        return .{ .tag = tag, .body = body };
    }
    fn readScramMessage(self: *PgClient, storage: []u8, expected: u32) ![]const u8 {
        const frame = try self.readStartupFrame(storage);
        if (frame.tag == 'E') return PgError.AuthenticationFailed;
        if (frame.tag != 'R' or frame.body.len < 4 or std.mem.readInt(u32, frame.body[0..4], .big) != expected) return PgError.ProtocolViolation;
        return frame.body[4..];
    }

    fn handleScramAuth(self: *PgClient, user: []const u8, password: []const u8) !void {
        const writer = &self.net_writer.interface;

        var nonce_bytes: [24]u8 = undefined;
        try self.io.randomSecure(&nonce_bytes);
        var nonce_encoded: [32]u8 = undefined;
        const client_nonce = std.base64.standard.Encoder.encode(&nonce_encoded, &nonce_bytes);
        var username: std.ArrayList(u8) = .empty;
        defer username.deinit(self.allocator);
        for (user) |byte| switch (byte) {
            '=' => try username.appendSlice(self.allocator, "=3D"),
            ',' => try username.appendSlice(self.allocator, "=2C"),
            else => try username.append(self.allocator, byte),
        };
        const client_first_bare = try std.fmt.allocPrint(self.allocator, "n={s},r={s}", .{ username.items, client_nonce });
        defer self.allocator.free(client_first_bare);
        const client_first_msg = try std.fmt.allocPrint(self.allocator, "n,,{s}", .{client_first_bare});
        defer self.allocator.free(client_first_msg);

        // Send SASLInitialResponse
        const mech = "SCRAM-SHA-256";
        var header: [5]u8 = undefined;
        header[0] = 'p';
        std.mem.writeInt(u32, header[1..5], @intCast(4 + mech.len + 1 + 4 + client_first_msg.len), .big);
        try writer.writeAll(&header);
        try writer.writeAll(mech ++ "\x00");
        var message_size: [4]u8 = undefined;
        std.mem.writeInt(u32, &message_size, @intCast(client_first_msg.len), .big);
        try writer.writeAll(&message_size);
        try writer.writeAll(client_first_msg);
        try writer.flush();

        var first_storage: [1024]u8 = undefined;
        const server_first_msg = try self.readScramMessage(&first_storage, 11);
        const first = try Scram.firstBounded(server_first_msg, client_nonce, self.max_scram_iterations);
        const combined_nonce = first.nonce;
        var salt: [768]u8 = undefined;
        const salt_len = std.base64.standard.Decoder.calcSizeForSlice(first.salt) catch return PgError.AuthenticationFailed;
        if (salt_len == 0 or salt_len > salt.len) return PgError.AuthenticationFailed;
        std.base64.standard.Decoder.decode(salt[0..salt_len], first.salt) catch return PgError.AuthenticationFailed;

        var salted_password: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &salted_password);
        try std.crypto.pwhash.pbkdf2(
            &salted_password,
            password,
            salt[0..salt_len],
            first.iterations,
            std.crypto.auth.hmac.sha2.HmacSha256,
        );

        var client_key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &client_key);
        std.crypto.auth.hmac.sha2.HmacSha256.create(&client_key, "Client Key", &salted_password);

        var stored_key: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&client_key, &stored_key, .{});

        const client_final_without_proof = try std.fmt.allocPrint(self.allocator, "c=biws,r={s}", .{combined_nonce});
        defer self.allocator.free(client_final_without_proof);

        const auth_message = try std.fmt.allocPrint(
            self.allocator,
            "{s},{s},{s}",
            .{ client_first_bare, server_first_msg, client_final_without_proof },
        );
        defer self.allocator.free(auth_message);

        var client_signature: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&client_signature, auth_message, &stored_key);

        var client_proof: [32]u8 = undefined;
        for (0..32) |idx| {
            client_proof[idx] = client_key[idx] ^ client_signature[idx];
        }

        var client_proof_b64: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&client_proof_b64, &client_proof);

        const client_final_msg = try std.fmt.allocPrint(
            self.allocator,
            "{s},p={s}",
            .{ client_final_without_proof, client_proof_b64 },
        );
        defer self.allocator.free(client_final_msg);

        // Send SASLResponse, then authenticate the peer before accepting its OK.
        std.mem.writeInt(u32, header[1..5], @intCast(4 + client_final_msg.len), .big);
        try writer.writeAll(&header);
        try writer.writeAll(client_final_msg);
        try writer.flush();
        var server_key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &server_key);
        std.crypto.auth.hmac.sha2.HmacSha256.create(&server_key, "Server Key", &salted_password);
        var server_signature: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&server_signature, auth_message, &server_key);
        var final_storage: [1024]u8 = undefined;
        try Scram.final(try self.readScramMessage(&final_storage, 12), server_signature);
        const ok = try self.readScramMessage(&final_storage, 0);
        if (ok.len != 0) return PgError.ProtocolViolation;
    }

    pub fn query(self: *PgClient, sql: []const u8) !PgResult {
        return self.queryOpts(sql, .{});
    }

    pub const DeadlineScope = struct {
        client: *PgClient,
        previous: ?std.Io.Timestamp,
        pub fn deinit(self: DeadlineScope) void {
            self.client.operation_deadline = self.previous;
        }
    };

    /// Scopes a sequence, including a legacy COMMIT, without resetting its clock.
    pub fn withDeadline(self: *PgClient, end: ?std.Io.Timestamp) DeadlineScope {
        const scope: DeadlineScope = .{ .client = self, .previous = self.operation_deadline };
        if (end) |next| {
            if (self.operation_deadline == null or next.nanoseconds < self.operation_deadline.?.nanoseconds) self.operation_deadline = next;
        }
        return scope;
    }

    fn checkDeadline(self: *PgClient) !void {
        if (self.operation_deadline) |end| if (std.Io.Timestamp.now(self.io, .awake).nanoseconds >= end.nanoseconds) return error.Timeout;
    }

    pub fn queryOpts(self: *PgClient, sql: []const u8, options: QueryOptions) !PgResult {
        if (self.active_stream != null) return error.ConnectionBusy;
        const scope = self.withDeadline(options.deadline);
        defer scope.deinit();
        try self.checkDeadline();
        if (!self.reusable) return error.ConnectionFailed;
        try self.limits.sql(sql);
        return self.queryInternal(sql) catch |err| return self.exchangeError(err);
    }

    pub fn queryParams(self: *PgClient, sql: []const u8, values: anytype) !PgResult {
        return self.queryParamsOpts(sql, values, .{});
    }

    pub fn queryParamsOpts(self: *PgClient, sql: []const u8, values: anytype, options: QueryOptions) !PgResult {
        if (self.active_stream != null) return error.ConnectionBusy;
        const scope = self.withDeadline(options.deadline);
        defer scope.deinit();
        try self.checkDeadline();
        if (!self.reusable) return error.ConnectionFailed;
        const packet = try parameters.request(self.allocator, self.limits, sql, values);
        defer self.allocator.free(packet);
        try self.checkDeadline();
        self.beginExchange();
        self.writeQuery(packet, false) catch |err| return self.exchangeError(err);
        return self.readResult(true) catch |err| return self.exchangeError(err);
    }

    /// The returned iterator owns the exchange until ReadyForQuery or close.
    pub fn streamQuery(self: *PgClient, sql: []const u8, options: @import("stream.zig").Options) !*@import("stream.zig").Stream {
        try StreamAccess.admit(self);
        try self.limits.sql(sql);
        return @import("stream.zig").Stream.start(self, sql, true, options);
    }
    pub fn streamParams(self: *PgClient, sql: []const u8, values: anytype, options: @import("stream.zig").Options) !*@import("stream.zig").Stream {
        try StreamAccess.admit(self);
        const packet = try parameters.request(self.allocator, self.limits, sql, values);
        defer self.allocator.free(packet);
        return @import("stream.zig").Stream.start(self, packet, false, options);
    }

    fn exchangeError(self: *PgClient, err: anyerror) anyerror {
        const cause = self.ioError(err);
        if (cause != error.DatabaseError) self.reusable = false;
        if (!self.reusable) self.transaction_status = .unknown;
        if (cause == error.Canceled or cause == error.Timeout) @import("cancel.zig").runTransport(self.io, self.address, self.cancel_key, &self.transport, self.cleanup_deadline orelse std.Io.Timestamp.now(self.io, .awake).addDuration(.fromMilliseconds(500)));
        return cause;
    }

    /// One joined cleanup owner, including an already-canceled caller. The
    /// rollback task bypasses query's separate cancellation helper so expiry
    /// cannot start a second cleanup budget. The borrower releases/discards.
    pub fn rollbackCleanup(self: *PgClient) void {
        if (self.active_stream) |active| active.close();
        if (!self.reusable) return;
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        const saved = self.last_diagnostic;
        defer self.last_diagnostic = saved;
        const operation_end = self.operation_deadline;
        self.operation_deadline = null;
        defer self.operation_deadline = operation_end;
        const end = std.Io.Timestamp.now(self.io, .awake).addDuration(.fromMilliseconds(500));
        const Done = union(enum) { rollback: anyerror!void, timeout: std.Io.Cancelable!void };
        const completed = done: {
            var storage: [2]Done = undefined;
            var select = std.Io.Select(Done).init(self.io, &storage);
            defer select.cancelDiscard();
            select.concurrent(.rollback, rollbackTask, .{self}) catch break :done false;
            select.concurrent(.timeout, waitUntil, .{ self.io, end }) catch break :done false;
            switch (select.await() catch break :done false) {
                .rollback => |result| {
                    result catch break :done false;
                    break :done true;
                },
                .timeout => break :done false,
            }
        };
        if (!completed) {
            self.reusable = false;
            self.transaction_status = .unknown;
        }
    }

    fn rollbackTask(self: *PgClient) !void {
        const protection = self.io.swapCancelProtection(.unblocked);
        defer _ = self.io.swapCancelProtection(protection);
        var result = try self.queryInternal("ROLLBACK");
        defer result.deinit();
        if (self.transaction_status != .idle or !std.mem.eql(u8, result.command_tag, "ROLLBACK")) return error.ProtocolViolation;
    }

    fn waitUntil(io: std.Io, end: std.Io.Timestamp) std.Io.Cancelable!void {
        const now = std.Io.Timestamp.now(io, .awake);
        if (now.nanoseconds < end.nanoseconds) try io.sleep(now.durationTo(end), .awake);
    }

    fn ioError(self: *PgClient, err: anyerror) anyerror {
        if (err == error.ReadFailed) {
            if (self.net_reader.err) |cause| if (cause == error.Canceled) return error.Canceled;
        }
        if (err == error.WriteFailed) {
            if (self.net_writer.err) |cause| if (cause == error.Canceled) return error.Canceled;
        }
        return err;
    }

    fn queryInternal(self: *PgClient, sql: []const u8) !PgResult {
        self.beginExchange();
        try self.writeQuery(sql, true);
        return self.readResult(false);
    }

    fn beginExchange(self: *PgClient) void {
        self.last_diagnostic = null;
        self.cleanup_deadline = null;
        self.transaction_status = .unknown;
    }

    fn writeTask(self: *PgClient, bytes: []const u8, simple: bool) !void {
        const protection = self.io.swapCancelProtection(.unblocked);
        defer _ = self.io.swapCancelProtection(protection);
        const writer = &self.net_writer.interface;
        if (simple) {
            var header: [5]u8 = undefined;
            header[0] = 'Q';
            std.mem.writeInt(u32, header[1..5], @intCast(5 + bytes.len), .big);
            try writer.writeAll(&header);
        }
        try writer.writeAll(bytes);
        if (simple) try writer.writeByte(0);
        try writer.flush();
    }

    fn writeQuery(self: *PgClient, bytes: []const u8, simple: bool) !void {
        const end = self.operation_deadline orelse return self.writeTask(bytes, simple);
        const Done = union(enum) { write: anyerror!void, timeout: std.Io.Cancelable!void };
        var storage: [2]Done = undefined;
        var select = std.Io.Select(Done).init(self.io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.write, writeTask, .{ self, bytes, simple });
        try select.concurrent(.timeout, waitUntil, .{ self.io, end });
        return switch (try select.await()) {
            .write => |result| result,
            .timeout => error.Timeout,
        };
    }

    fn readQueryBytes(self: *PgClient, bytes: []u8) !void {
        const end = self.cleanup_deadline orelse self.operation_deadline orelse return self.net_reader.interface.readSliceAll(bytes);
        if (std.Io.Timestamp.now(self.io, .awake).nanoseconds >= end.nanoseconds) return error.Timeout;
        const Done = union(enum) { read: anyerror!void, timeout: std.Io.Cancelable!void };
        var storage: [2]Done = undefined;
        var select = std.Io.Select(Done).init(self.io, &storage);
        defer select.cancelDiscard();
        try select.concurrent(.read, readTask, .{ self, bytes });
        try select.concurrent(.timeout, waitUntil, .{ self.io, end });
        return switch (try select.await()) {
            .read => |result| result,
            .timeout => error.Timeout,
        };
    }

    fn readTask(self: *PgClient, bytes: []u8) !void {
        const protection = self.io.swapCancelProtection(.unblocked);
        defer _ = self.io.swapCancelProtection(protection);
        try self.net_reader.interface.readSliceAll(bytes);
    }

    fn readResult(self: *PgClient, extended: bool) !PgResult {
        var rows_list: std.ArrayList(PgRow) = .empty;
        errdefer {
            for (rows_list.items) |*row| row.deinit();
            rows_list.deinit(self.allocator);
        }

        var command_tag: []const u8 = "";
        errdefer self.allocator.free(command_tag);
        var has_error = false;
        var completed = false;
        var columns: ?u16 = null;
        var owned_bytes: usize = 0;
        var phase: enum { parse, bind, describe, execute } = if (extended) .parse else .execute;
        while (true) {
            var header: [5]u8 = undefined;
            try self.readQueryBytes(&header);
            const length = try protocol.payloadSize(std.mem.readInt(u32, header[1..5], .big), self.limits);
            if (header[0] == 'E' and self.cleanup_deadline == null) self.cleanup_deadline = std.Io.Timestamp.now(self.io, .awake).addDuration(.fromMilliseconds(500));
            const body = try self.allocator.alloc(u8, length);
            defer self.allocator.free(body);
            try self.readQueryBytes(body);
            var cursor: protocol.Cursor = .{ .bytes = body };
            if (has_error and std.mem.indexOfScalar(u8, "ZNS", header[0]) == null) return error.ProtocolViolation;
            switch (header[0]) {
                '1' => {
                    if (!extended or phase != .parse or body.len != 0) return error.ProtocolViolation;
                    phase = .bind;
                },
                '2' => {
                    if (!extended or phase != .bind or body.len != 0) return error.ProtocolViolation;
                    phase = .describe;
                },
                'n' => {
                    if (!extended or phase != .describe or body.len != 0) return error.ProtocolViolation;
                    phase = .execute;
                },
                'T' => {
                    if (extended and phase != .describe) return error.ProtocolViolation;
                    if (columns != null) return error.ProtocolViolation;
                    columns = try protocol.description(body, self.limits);
                    phase = .execute;
                    completed = false;
                },
                'D' => {
                    if (phase != .execute or completed) return error.ProtocolViolation;
                    const num_cols = try cursor.int(u16);
                    if (num_cols != (columns orelse return error.ProtocolViolation)) return error.ProtocolViolation;
                    if (num_cols > self.limits.max_columns) return error.ColumnLimit;
                    if (rows_list.items.len >= self.limits.max_rows) return error.RowLimit;
                    owned_bytes = try self.limits.add(owned_bytes, @sizeOf(PgRow) + @as(usize, num_cols) * @sizeOf(?[]const u8));
                    const col_values = try self.allocator.alloc(?[]const u8, num_cols);
                    @memset(col_values, null);
                    errdefer {
                        for (col_values) |value| if (value) |bytes| self.allocator.free(bytes);
                        self.allocator.free(col_values);
                    }
                    for (0..num_cols) |col_idx| {
                        const size = try cursor.int(i32);
                        if (size == -1) continue;
                        if (size < 0) return error.ProtocolViolation;
                        const cell_size: usize = @intCast(size);
                        if (cell_size > self.limits.max_cell_bytes) return error.CellTooLarge;
                        const value = try cursor.take(cell_size);
                        owned_bytes = try self.limits.add(owned_bytes, cell_size);
                        col_values[col_idx] = try self.allocator.dupe(u8, value);
                    }
                    try cursor.end();
                    try rows_list.append(self.allocator, PgRow{
                        .allocator = self.allocator,
                        .values = col_values,
                    });
                },
                'C' => {
                    if (phase != .execute or (extended and completed)) return error.ProtocolViolation;
                    const tag = try cursor.string();
                    try cursor.end();
                    if (tag.len == 0) return error.ProtocolViolation;
                    owned_bytes = try self.limits.add(owned_bytes - command_tag.len, tag.len);
                    const next_tag = try self.allocator.dupe(u8, tag);
                    self.allocator.free(command_tag);
                    command_tag = next_tag;
                    columns = null;
                    completed = true;
                },
                'Z' => {
                    if (body.len != 1 or (!has_error and !completed)) return error.ProtocolViolation;
                    self.transaction_status = switch (body[0]) {
                        'I' => .idle,
                        'T' => .transaction,
                        'E' => .failed_transaction,
                        else => return PgError.ProtocolViolation,
                    };
                    if (has_error) return error.DatabaseError;
                    return .{ .allocator = self.allocator, .rows = try rows_list.toOwnedSlice(self.allocator), .command_tag = command_tag };
                },
                'E' => {
                    try protocol.fields(body);
                    var parser: diagnostic.Parser = .{};
                    parser.feed(body);
                    self.last_diagnostic = parser.diagnostic;
                    has_error = true;
                },
                'N' => try protocol.fields(body),
                'S' => {
                    _ = try cursor.string();
                    _ = try cursor.string();
                    try cursor.end();
                },
                'I' => {
                    if (phase != .execute) return error.ProtocolViolation;
                    if (body.len != 0 or columns != null) return error.ProtocolViolation;
                    completed = true;
                },
                else => return error.ProtocolViolation,
            }
        }
    }
};

/// Internal bridge keeps streaming on the same I/O/deadline/recovery owner.
pub const StreamAccess = struct {
    pub fn admit(c: *PgClient) !void {
        if (c.active_stream != null) return error.ConnectionBusy;
        if (!c.reusable) return error.ConnectionFailed;
        try c.checkDeadline();
    }
    pub fn check(c: *PgClient) !void {
        try c.checkDeadline();
    }
    pub fn begin(c: *PgClient) void {
        c.beginExchange();
    }
    pub fn read(c: *PgClient, b: []u8) !void {
        try c.readQueryBytes(b);
    }
    pub fn write(c: *PgClient, b: []const u8, simple: bool) !void {
        try c.writeQuery(b, simple);
    }
    pub fn fail(c: *PgClient, err: anyerror) anyerror {
        return c.exchangeError(err);
    }
};
