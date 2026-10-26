//! Scalar conversion shared by owned and generation-checked borrowed rows.
const std = @import("std");
pub const Error = error{ UnexpectedNull, InvalidBoolean, InvalidInteger, InvalidFloat, Overflow };
/// Required T rejects SQL NULL; ?T preserves it. Text is borrowed from the row.
/// Floating getters accept PostgreSQL's canonical NaN/Infinity/-Infinity;
/// finite decimal overflow is an error, independently of finite-only binding.
pub fn value(comptime T: type, cell: ?[]const u8) Error!T {
    if (@typeInfo(T) == .optional) return if (cell) |bytes| try value(@typeInfo(T).optional.child, bytes) else null;
    const bytes = cell orelse return error.UnexpectedNull;
    return switch (@typeInfo(T)) {
        .bool => if (std.mem.eql(u8, bytes, "t")) true else if (std.mem.eql(u8, bytes, "f")) false else error.InvalidBoolean,
        .int => blk: {
            var digits = bytes;
            if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) digits = digits[1..];
            if (digits.len == 0) return error.InvalidInteger;
            for (digits) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidInteger;
            break :blk std.fmt.parseInt(T, bytes, 10) catch |err| return if (err == error.Overflow) error.Overflow else error.InvalidInteger;
        },
        .float => blk: {
            if (std.mem.eql(u8, bytes, "NaN")) break :blk std.math.nan(T);
            if (std.mem.eql(u8, bytes, "Infinity")) break :blk std.math.inf(T);
            if (std.mem.eql(u8, bytes, "-Infinity")) break :blk -std.math.inf(T);
            for (bytes) |byte| if (!std.ascii.isDigit(byte) and std.mem.indexOfScalar(u8, "+-.eE", byte) == null) return error.InvalidFloat;
            const parsed = std.fmt.parseFloat(T, bytes) catch return error.InvalidFloat;
            if (std.math.isInf(parsed)) return error.Overflow;
            break :blk parsed;
        },
        .pointer => |info| if (info.size == .slice and info.child == u8 and info.attrs.@"const") bytes else @compileError("Unsupported checked cell type: " ++ @typeName(T)),
        else => @compileError("Unsupported checked cell type: " ++ @typeName(T)),
    };
}
