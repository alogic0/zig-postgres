//! A separate, connection-owning text iterator. No network work in deinit.
const std = @import("std");
const C = @import("client.zig");
const wire = @import("protocol.zig");
const diagnostic = @import("diagnostic.zig");
const A = std.mem.Allocator;
pub const Options = struct {
    deadline: ?std.Io.Timestamp = null,
    /// Frame payload, column views and retained command tag, checked together.
    max_buffer_bytes: usize = 32 * 1024 * 1024,
};
pub const BorrowedRow = struct {
    owner: *Stream,
    generation: usize,
    fn check(row: BorrowedRow) !void {
        if (row.generation != row.owner.generation) return error.StaleRow;
    }
    /// Call only while the iterator is alive. Advancing/closing expires this row.
    /// Deprecated permissive bounds; use getChecked/getTyped (0.4 migration).
    pub fn get(row: BorrowedRow, index: usize) !?[]const u8 {
        try row.check();
        return if (index < row.owner.values.len) row.owner.values[index] else null;
    }
    pub fn getChecked(row: BorrowedRow, index: usize) !?[]const u8 {
        try row.check();
        if (index >= row.owner.values.len) return error.ColumnOutOfBounds;
        return row.owner.values[index];
    }
    /// Valid only until advancement/close, including when returning text.
    pub fn getTyped(row: BorrowedRow, comptime T: type, index: usize) !T {
        return @import("decode.zig").value(T, try row.getChecked(index));
    }
    pub fn copy(row: BorrowedRow, allocator: A) !C.PgRow {
        try row.check();
        const values = try allocator.alloc(?[]const u8, row.owner.values.len);
        @memset(values, null);
        errdefer {
            for (values) |value| if (value) |v| allocator.free(v);
            allocator.free(values);
        }
        for (row.owner.values, 0..) |value, i| if (value) |bytes| {
            values[i] = try allocator.dupe(u8, bytes);
        };
        return .{ .allocator = allocator, .values = values };
    }
};
pub const Stream = struct {
    allocator: A,
    /// Null after completion, close or the client's destruction. The iterator
    /// owns its buffers independently, so pool eviction cannot dangle this link.
    client: ?*C.PgClient,
    options: Options,
    body: []u8 = &.{},
    values: []?[]const u8 = &.{},
    command_tag: []const u8 = "",
    generation: usize = 0,
    rows: usize = 0,
    columns: ?u16 = null,
    phase: enum { parse, bind, describe, execute },
    extended: bool,
    command_complete: bool = false,
    has_error: bool = false,
    complete: bool = false,
    ready: bool = false,
    /// Counts are provisional until ReadyForQuery validates the whole exchange.
    pub fn commandCount(self: *Stream) !?u64 {
        if (!self.ready) return error.IncompleteResult;
        if (self.has_error) return error.DatabaseError;
        return @import("command.zig").count(self.command_tag);
    }
    /// Drain through ReadyForQuery. A later/deferred database error takes
    /// precedence over cardinality; any error closes the exchange. The caller
    /// still owns the iterator and connection borrow, and owns a returned row.
    pub fn singleRow(self: *Stream, allocator: A) !?C.PgRow {
        var first: ?C.PgRow = null;
        errdefer {
            if (first) |*row| row.deinit();
            self.close();
        }
        var many = false;
        while (try self.next()) |row| {
            if (first == null) first = try row.copy(allocator) else many = true;
        }
        if (many) return error.TooManyRows;
        return first;
    }
    pub fn start(c: *C.PgClient, bytes: []const u8, simple: bool, options: Options) !*Stream {
        try C.StreamAccess.admit(c);
        if (options.max_buffer_bytes == 0) return error.StreamBufferTooSmall;
        const self = try c.allocator.create(Stream);
        errdefer c.allocator.destroy(self);
        self.* = .{ .allocator = c.allocator, .client = c, .options = options, .phase = if (simple) .execute else .parse, .extended = !simple };
        self.options.deadline = @import("deadline.zig").minimum(c.operation_deadline, options.deadline);
        const scope = c.withDeadline(self.options.deadline);
        defer scope.deinit();
        try C.StreamAccess.check(c);
        C.StreamAccess.begin(c);
        c.active_stream = self;
        C.StreamAccess.write(c, bytes, simple) catch |err| {
            const cause = C.StreamAccess.fail(c, err);
            self.detach();
            return cause;
        };
        return self;
    }
    fn detach(self: *Stream) void {
        if (self.client) |c| c.active_stream = null;
        self.client = null;
    }
    /// Early close invalidates. The caller then releases/discards/closes its
    /// client. All next() I/O is joined before it returns; no concurrent client use.
    pub fn close(self: *Stream) void {
        self.generation +%= 1;
        if (self.client) |c| {
            c.reusable = false;
            c.transaction_status = .unknown;
        }
        self.detach();
    }
    pub fn deinit(self: *Stream) void {
        self.close();
        const a = self.allocator;
        a.free(self.body);
        a.free(self.values);
        a.free(self.command_tag);
        a.destroy(self);
    }
    fn capacity(self: *Stream, body: usize, columns: usize, tag: usize) !void {
        const views = std.math.mul(usize, columns, @sizeOf(?[]const u8)) catch return error.StreamBufferTooSmall;
        const subtotal = std.math.add(usize, body, views) catch return error.StreamBufferTooSmall;
        const total = std.math.add(usize, subtotal, tag) catch return error.StreamBufferTooSmall;
        if (total > self.options.max_buffer_bytes) return error.StreamBufferTooSmall;
    }
    pub fn next(self: *Stream) !?BorrowedRow {
        self.generation +%= 1;
        const c = self.client orelse return if (self.complete) null else error.StreamClosed;
        const scope = c.withDeadline(self.options.deadline);
        defer scope.deinit();
        return self.read(c) catch |err| {
            // A synchronized server error has already detached a healthy client.
            const cause = if (self.client != null) C.StreamAccess.fail(c, err) else err;
            self.detach();
            return cause;
        };
    }
    fn read(self: *Stream, c: *C.PgClient) !?BorrowedRow {
        try C.StreamAccess.check(c);
        while (true) {
            self.allocator.free(self.body);
            self.body = &.{};
            var header: [5]u8 = undefined;
            try C.StreamAccess.read(c, &header);
            const size = try wire.payloadSize(std.mem.readInt(u32, header[1..5], .big), c.limits);
            if (header[0] == 'E' and c.cleanup_deadline == null) c.cleanup_deadline = std.Io.Timestamp.now(c.io, .awake).addDuration(.fromMilliseconds(500));
            try self.capacity(size, self.values.len, self.command_tag.len);
            self.body = try self.allocator.alloc(u8, size);
            try C.StreamAccess.read(c, self.body);
            const body = self.body;
            var cursor: wire.Cursor = .{ .bytes = body };
            if (self.has_error and std.mem.indexOfScalar(u8, "ZNS", header[0]) == null) return error.ProtocolViolation;
            switch (header[0]) {
                '1' => {
                    if (!self.extended or self.phase != .parse or body.len != 0) return error.ProtocolViolation;
                    self.phase = .bind;
                },
                '2' => {
                    if (!self.extended or self.phase != .bind or body.len != 0) return error.ProtocolViolation;
                    self.phase = .describe;
                },
                'n' => {
                    if (!self.extended or self.phase != .describe or body.len != 0) return error.ProtocolViolation;
                    self.phase = .execute;
                },
                'T' => {
                    if (self.extended and self.phase != .describe) return error.ProtocolViolation;
                    if (self.columns != null) return error.ProtocolViolation;
                    const columns = try wire.description(body, c.limits);
                    try self.capacity(body.len, columns, self.command_tag.len);
                    self.allocator.free(self.values);
                    self.values = &.{};
                    self.values = try self.allocator.alloc(?[]const u8, columns);
                    self.columns = columns;
                    self.phase = .execute;
                    self.command_complete = false;
                },
                'D' => {
                    if (self.phase != .execute or self.command_complete) return error.ProtocolViolation;
                    const columns = try cursor.int(u16);
                    if (columns != (self.columns orelse return error.ProtocolViolation)) return error.ProtocolViolation;
                    if (self.rows >= c.limits.max_rows) return error.RowLimit;
                    @memset(self.values, null);
                    for (self.values) |*value| {
                        const length = try cursor.int(i32);
                        if (length == -1) continue;
                        if (length < 0) return error.ProtocolViolation;
                        const n: usize = @intCast(length);
                        if (n > c.limits.max_cell_bytes) return error.CellTooLarge;
                        value.* = try cursor.take(n);
                    }
                    try cursor.end();
                    self.rows += 1;
                    return .{ .owner = self, .generation = self.generation };
                },
                'C' => {
                    if (self.phase != .execute or (self.extended and self.command_complete)) return error.ProtocolViolation;
                    const tag = try cursor.string();
                    try cursor.end();
                    if (tag.len == 0) return error.ProtocolViolation;
                    try self.capacity(body.len, self.values.len, tag.len);
                    self.allocator.free(self.command_tag);
                    self.command_tag = "";
                    self.command_tag = try self.allocator.dupe(u8, tag);
                    self.columns = null;
                    self.command_complete = true;
                },
                'I' => {
                    if (self.phase != .execute or body.len != 0 or self.columns != null) return error.ProtocolViolation;
                    self.command_complete = true;
                },
                'E' => {
                    try wire.fields(body);
                    var parser: diagnostic.Parser = .{};
                    parser.feed(body);
                    c.last_diagnostic = parser.diagnostic;
                    self.has_error = true;
                },
                'N' => try wire.fields(body),
                'S' => {
                    _ = try cursor.string();
                    _ = try cursor.string();
                    try cursor.end();
                },
                'Z' => {
                    if (body.len != 1 or (!self.has_error and !self.command_complete)) return error.ProtocolViolation;
                    c.transaction_status = switch (body[0]) {
                        'I' => .idle,
                        'T' => .transaction,
                        'E' => .failed_transaction,
                        else => return error.ProtocolViolation,
                    };
                    self.ready = true;
                    self.complete = !self.has_error;
                    self.detach();
                    if (self.has_error) return error.DatabaseError;
                    return null;
                },
                else => return error.ProtocolViolation,
            }
        }
    }
};
