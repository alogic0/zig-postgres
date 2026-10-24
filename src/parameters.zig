//! Unnamed, text-format extended requests. Admission completes before any I/O.
const std = @import("std");
const Limits = @import("protocol.zig").Limits;
pub const Uuid = struct { bytes: [16]u8 };
pub const Binary = struct { bytes: []const u8 };
pub const Error = error{ UnsupportedParameter, IntegerRange, InvalidText, ParameterLimit, RequestTooLarge };

const Sink = struct {
    bytes: ?[]u8 = null,
    offset: usize = 0,
    limit: usize,
    fn put(self: *Sink, bytes: []const u8) Error!void {
        const end = std.math.add(usize, self.offset, bytes.len) catch return error.RequestTooLarge;
        if (end > self.limit) return error.RequestTooLarge;
        if (self.bytes) |buffer| @memcpy(buffer[self.offset..end], bytes);
        self.offset = end;
    }
    fn int(self: *Sink, comptime T: type, number: T) Error!void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, number, .big);
        try self.put(&buffer);
    }
    fn text(self: *Sink, bytes: []const u8) Error!void {
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidText;
        const length = std.math.cast(i32, bytes.len) orelse return error.RequestTooLarge;
        try self.int(i32, length);
        try self.put(bytes);
    }
};

fn value(s: *Sink, v: anytype) Error!void {
    const T = @TypeOf(v);
    if (T == Uuid) {
        var text: [36]u8 = undefined;
        const hex = "0123456789abcdef";
        var pos: usize = 0;
        for (v.bytes, 0..) |byte, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                text[pos] = '-';
                pos += 1;
            }
            text[pos] = hex[byte >> 4];
            text[pos + 1] = hex[byte & 15];
            pos += 2;
        }
        return s.text(&text);
    }
    if (T == Binary) {
        const length = std.math.mul(usize, v.bytes.len, 2) catch return error.RequestTooLarge;
        const size = std.math.add(usize, length, 2) catch return error.RequestTooLarge;
        try s.int(i32, std.math.cast(i32, size) orelse return error.RequestTooLarge);
        try s.put("\\x");
        const hex = "0123456789abcdef";
        for (v.bytes) |byte| try s.put(&.{ hex[byte >> 4], hex[byte & 15] });
        return;
    }
    switch (@typeInfo(T)) {
        .null => try s.int(i32, -1),
        .optional => if (v) |present| try value(s, present) else try s.int(i32, -1),
        .bool => try s.text(if (v) "true" else "false"),
        .int, .comptime_int => {
            const n = std.math.cast(i64, v) orelse return error.IntegerRange;
            var buffer: [32]u8 = undefined;
            try s.text(std.fmt.bufPrint(&buffer, "{d}", .{n}) catch unreachable);
        },
        .array => |info| if (info.child == u8) {
            try s.text(&v);
        } else return error.UnsupportedParameter,
        .pointer => |info| {
            if (info.size == .slice and info.child == u8) return s.text(v);
            if (info.size == .one) switch (@typeInfo(info.child)) {
                .array => |arr| if (arr.child == u8) {
                    return s.text(v);
                },
                else => {},
            };
            return error.UnsupportedParameter;
        },
        else => return error.UnsupportedParameter,
    }
}

fn encode(s: *Sink, sql: []const u8, values: anytype, count: u16) Error!void {
    // Parse: unnamed statement, infer parameter types.
    try s.put("P");
    try s.int(i32, std.math.cast(i32, sql.len + 8) orelse return error.RequestTooLarge);
    try s.put("\x00");
    try s.put(sql);
    try s.put("\x00\x00\x00");
    // Bind: unnamed portal/statement, all parameter and result formats text.
    try s.put("B");
    const length_at = s.offset;
    try s.int(i32, 0);
    try s.put("\x00\x00\x00\x00");
    try s.int(u16, count);
    inline for (values) |v| try value(s, v);
    try s.int(u16, 0);
    const bind_length = std.math.cast(i32, s.offset - length_at) orelse return error.RequestTooLarge;
    if (s.bytes) |buffer| std.mem.writeInt(i32, buffer[length_at..][0..4], bind_length, .big);
    // Describe portal, Execute all rows, exactly one Sync.
    try s.put("D\x00\x00\x00\x06P\x00E\x00\x00\x00\x09\x00\x00\x00\x00\x00S\x00\x00\x00\x04");
}

pub fn request(a: std.mem.Allocator, limits: Limits, sql: []const u8, values: anytype) ![]u8 {
    try limits.sql(sql);
    const info = @typeInfo(@TypeOf(values));
    if (info != .@"struct" or !info.@"struct".is_tuple) return error.UnsupportedParameter;
    const count = info.@"struct".field_names.len;
    if (count > limits.max_parameters or count > std.math.maxInt(u16)) return error.ParameterLimit;
    var sizing: Sink = .{ .limit = limits.max_request_bytes };
    try encode(&sizing, sql, values, @intCast(count));
    const bytes = try a.alloc(u8, sizing.offset);
    errdefer a.free(bytes);
    var output: Sink = .{ .bytes = bytes, .limit = bytes.len };
    try encode(&output, sql, values, @intCast(count));
    return bytes;
}

test "admission counts complete wire bytes and rejects unsupported or oversized values" {
    const a = std.testing.allocator;
    const packet = try request(a, .{ .max_request_bytes = 66 }, "SELECT $1::text", .{"one"});
    defer a.free(packet);
    try std.testing.expectEqual(@as(usize, 66), packet.len);
    try std.testing.expectError(error.RequestTooLarge, request(a, .{ .max_request_bytes = 65 }, "SELECT $1::text", .{"one"}));
    try std.testing.expectError(error.ParameterLimit, request(a, .{ .max_parameters = 0 }, "SELECT $1", .{1}));
    try std.testing.expectError(error.IntegerRange, request(a, .{}, "SELECT $1", .{@as(u64, std.math.maxInt(u64))}));
    try std.testing.expectError(error.UnsupportedParameter, request(a, .{}, "SELECT $1", .{@as(f64, 1.0)}));
    try std.testing.expectError(error.InvalidText, request(a, .{}, "SELECT $1", .{"zero\x00byte"}));
    var sink: Sink = .{ .offset = std.math.maxInt(usize), .limit = std.math.maxInt(usize) };
    try std.testing.expectError(error.RequestTooLarge, sink.put("x"));
}
