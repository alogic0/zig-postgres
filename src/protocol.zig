//! Checked wire cursors and explicit resource admission. No I/O or SQL policy.
const std = @import("std");
pub const Error = error{ ProtocolViolation, SqlTooLarge, MessageTooLarge, CellTooLarge, ColumnLimit, RowLimit, ResultTooLarge, InvalidSql, Timeout };
pub const Limits = struct {
    max_sql_bytes: usize = 16 * 1024 * 1024,
    /// Whole wire message, including tag and length field.
    max_message_bytes: usize = 16 * 1024 * 1024,
    max_cell_bytes: usize = 8 * 1024 * 1024,
    /// Logical owned row/cell/tag bytes. List spare capacity and the one bounded
    /// transient frame buffer are additional, bounded allocations.
    max_result_bytes: usize = 64 * 1024 * 1024,
    max_rows: usize = 100000,
    max_columns: usize = 1024,

    pub fn sql(self: Limits, value: []const u8) Error!void {
        if (value.len > self.max_sql_bytes or value.len > std.math.maxInt(i32) - 5) return error.SqlTooLarge;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSql;
    }
    pub fn add(self: Limits, current: usize, amount: usize) Error!usize {
        const result = std.math.add(usize, current, amount) catch return error.ResultTooLarge;
        if (result > self.max_result_bytes) return error.ResultTooLarge;
        return result;
    }
};

pub fn payloadSize(declared: u32, limits: Limits) Error!usize {
    if (declared < 4) return error.ProtocolViolation;
    if (declared > std.math.maxInt(i32)) return error.MessageTooLarge;
    const whole = std.math.add(usize, declared, 1) catch return error.MessageTooLarge;
    if (whole > limits.max_message_bytes) return error.MessageTooLarge;
    return declared - 4;
}

pub const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,
    pub fn take(self: *Cursor, length: usize) Error![]const u8 {
        if (length > self.bytes.len - self.offset) return error.ProtocolViolation;
        const result = self.bytes[self.offset..][0..length];
        self.offset += length;
        return result;
    }
    pub fn int(self: *Cursor, comptime T: type) Error!T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
    }
    pub fn string(self: *Cursor) Error![]const u8 {
        const remaining = self.bytes[self.offset..];
        const size = std.mem.indexOfScalar(u8, remaining, 0) orelse return error.ProtocolViolation;
        const value = try self.take(size);
        _ = try self.take(1);
        return value;
    }
    pub fn end(self: Cursor) Error!void {
        if (self.offset != self.bytes.len) return error.ProtocolViolation;
    }
};

pub fn description(bytes: []const u8, limits: Limits) Error!u16 {
    var cursor: Cursor = .{ .bytes = bytes };
    const columns = try cursor.int(u16);
    if (columns > limits.max_columns) return error.ColumnLimit;
    for (0..columns) |_| {
        _ = try cursor.string();
        const descriptor = try cursor.take(18);
        // Existing public getters expose text; binary rows require a distinct API.
        if (std.mem.readInt(u16, descriptor[16..18], .big) != 0) return error.ProtocolViolation;
    }
    try cursor.end();
    return columns;
}

pub fn fields(bytes: []const u8) Error!void {
    var cursor: Cursor = .{ .bytes = bytes };
    while (try cursor.int(u8) != 0) _ = try cursor.string();
    try cursor.end();
}

test "wire lengths reject underflow and oversized declared messages before allocation" {
    try std.testing.expectError(error.ProtocolViolation, payloadSize(3, .{}));
    try std.testing.expectError(error.MessageTooLarge, payloadSize(0xffffffff, .{}));
    try std.testing.expectError(error.MessageTooLarge, payloadSize(0x80000000, .{ .max_message_bytes = std.math.maxInt(usize) }));
    try std.testing.expectEqual(@as(usize, 1), try payloadSize(5, .{ .max_message_bytes = 6 }));
    try std.testing.expectError(error.MessageTooLarge, payloadSize(5, .{ .max_message_bytes = 5 }));
}
test "cursor requires complete strings fields and fixed width data" {
    try fields("C23505\x00Mfixture\x00\x00");
    try std.testing.expectError(error.ProtocolViolation, fields("C23505\x00Munterminated"));
    try std.testing.expectError(error.ProtocolViolation, fields("\x00extra"));
    var cursor: Cursor = .{ .bytes = "\x00" };
    try std.testing.expectError(error.ProtocolViolation, cursor.int(u16));
}
test "query and retained result limits include checked arithmetic" {
    const limits: Limits = .{ .max_sql_bytes = 8, .max_result_bytes = 5 };
    try limits.sql("SELECT 1");
    try std.testing.expectError(error.SqlTooLarge, limits.sql("SELECT 10"));
    try std.testing.expectError(error.InvalidSql, limits.sql("\x00"));
    try std.testing.expectEqual(@as(usize, 5), try limits.add(2, 3));
    try std.testing.expectError(error.ResultTooLarge, limits.add(2, 4));
    try std.testing.expectError(error.ResultTooLarge, limits.add(std.math.maxInt(usize), 1));
}
