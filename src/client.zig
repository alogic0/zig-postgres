//! Native PostgreSQL wire protocol v3 client with trust, password and SCRAM authentication.
const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const Scram = @import("scram.zig");
const protocol = @import("protocol.zig");
pub const Limits = protocol.Limits;

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

    pub fn get(self: PgRow, index: usize) ?[]const u8 {
        if (index >= self.values.len) return null;
        return self.values[index];
    }

    pub fn getInt(self: PgRow, index: usize, comptime T: type) !?T {
        const str = self.get(index) orelse return null;
        return try std.fmt.parseInt(T, str, 10);
    }

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
    net_reader: std.Io.net.Stream.Reader,
    net_writer: std.Io.net.Stream.Writer,
    /// Owned error fields for the last query; cleared before each new exchange.
    last_diagnostic: ?diagnostic.Diagnostic = null,
    /// An incomplete exchange cannot safely be returned to a connection pool.
    reusable: bool = true,
    transaction_status: TransactionStatus = .unknown,
    limits: Limits = .{},
    cleanup_deadline: ?std.Io.Timestamp = null,
    address: ?std.Io.net.IpAddress = null,
    cancel_key: ?@import("cancel.zig").Key = null,

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
        const addr = if (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost"))
            try std.Io.net.IpAddress.parse("127.0.0.1", port)
        else
            std.Io.net.IpAddress.parse(host, port) catch return PgError.ConnectionFailed;

        const stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return PgError.ConnectionFailed;
        };
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
            .net_reader = stream.reader(io, read_buf),
            .net_writer = stream.writer(io, write_buf),
            .address = addr,
        };

        self.handshake(user, password, database) catch |err| return self.ioError(err);
        return self;
    }

    pub fn close(self: *PgClient) void {
        if (!self.reusable) return self.disconnect();
        // Send terminate ('X')
        var term: [5]u8 = undefined;
        term[0] = 'X';
        std.mem.writeInt(u32, term[1..5], 4, .big);
        _ = self.net_writer.interface.writeAll(&term) catch {};
        _ = self.net_writer.interface.flush() catch {};

        self.disconnect();
    }

    /// Abort without writing into a failed or canceled protocol exchange.
    pub fn disconnect(self: *PgClient) void {
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
        const first = try Scram.first(server_first_msg, client_nonce);
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
        if (!self.reusable) return error.ConnectionFailed;
        try self.limits.sql(sql);
        return self.queryInternal(sql) catch |err| {
            const cause = self.ioError(err);
            // DatabaseError is returned only after ReadyForQuery. Every other
            // failure may leave a partial frame; no later query may reuse it.
            if (cause != error.DatabaseError) self.reusable = false;
            if (!self.reusable) self.transaction_status = .unknown;
            if (cause == error.Canceled or cause == error.Timeout) @import("cancel.zig").runUntil(self.io, self.address, self.cancel_key, self.stream, self.cleanup_deadline orelse std.Io.Timestamp.now(self.io, .awake).addDuration(.fromMilliseconds(500)));
            return cause;
        };
    }

    /// One joined cleanup owner, including an already-canceled caller. The
    /// rollback task bypasses query's separate cancellation helper so expiry
    /// cannot start a second cleanup budget. The borrower releases/discards.
    pub fn rollbackCleanup(self: *PgClient) void {
        if (!self.reusable) return;
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        const saved = self.last_diagnostic;
        defer self.last_diagnostic = saved;
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
        self.last_diagnostic = null;
        self.cleanup_deadline = null;
        self.transaction_status = .unknown;
        const writer = &self.net_writer.interface;
        var header: [5]u8 = undefined;
        header[0] = 'Q';
        std.mem.writeInt(u32, header[1..5], @intCast(4 + sql.len + 1), .big);
        try writer.writeAll(&header);
        try writer.writeAll(sql);
        try writer.writeByte(0);
        try writer.flush();
        return self.readResult();
    }

    fn readQueryBytes(self: *PgClient, bytes: []u8) !void {
        const end = self.cleanup_deadline orelse return self.net_reader.interface.readSliceAll(bytes);
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

    fn readResult(self: *PgClient) !PgResult {
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
                'T' => {
                    if (columns != null) return error.ProtocolViolation;
                    columns = try protocol.description(body, self.limits);
                    completed = false;
                },
                'D' => {
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
                    if (body.len != 0 or columns != null) return error.ProtocolViolation;
                    completed = true;
                },
                else => return error.ProtocolViolation,
            }
        }
    }
};
