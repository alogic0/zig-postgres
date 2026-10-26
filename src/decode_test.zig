const std = @import("std");
const C = @import("client.zig");
const S = @import("stream.zig");
const t = std.testing;
fn matrix(row: anytype) !void {
    try t.expect(try row.getTyped(bool, 0));
    try t.expect(!try row.getTyped(bool, 1));
    try t.expectEqual(@as(?bool, null), try row.getTyped(?bool, 2));
    try t.expectError(error.UnexpectedNull, row.getTyped(bool, 2));
    try t.expectEqualStrings("", try row.getTyped([]const u8, 3));
    try t.expectEqual(@as(?[]const u8, null), try row.getTyped(?[]const u8, 2));
    for ([_]usize{ 3, 4, 5, 6, 7 }) |i| try t.expectError(error.InvalidBoolean, row.getTyped(bool, i));
    try t.expectError(error.ColumnOutOfBounds, row.getChecked(99));
    try t.expectError(error.ColumnOutOfBounds, row.getTyped(?i64, 99));
    try t.expectEqual(std.math.minInt(i64), try row.getTyped(i64, 8));
    try t.expectEqual(std.math.maxInt(i64), try row.getTyped(i64, 9));
    try t.expectError(error.Overflow, row.getTyped(i64, 10));
    try t.expectError(error.Overflow, row.getTyped(i64, 11));
    try t.expectError(error.InvalidInteger, row.getTyped(i64, 12));
    try t.expectError(error.InvalidInteger, row.getTyped(i64, 3));
    try t.expectEqual(@as(f64, 1.2345678901234567), try row.getTyped(f64, 13));
    try t.expect(std.math.isNan(try row.getTyped(f64, 14)));
    try t.expectEqual(std.math.inf(f64), try row.getTyped(f64, 15));
    try t.expectEqual(-std.math.inf(f64), try row.getTyped(f64, 16));
    try t.expectError(error.Overflow, row.getTyped(f64, 17));
    try t.expectError(error.InvalidFloat, row.getTyped(f64, 4));
    try t.expectEqual(@as(f64, -0.0), try row.getTyped(f64, 18));
}
test "owned and borrowed cells share strict null bounds bool integer and float conversion" {
    var values = [_]?[]const u8{ "t", "f", null, "", "tomato", "not-boolean", "true", "1", "-9223372036854775808", "9223372036854775807", "9223372036854775808", "-9223372036854775809", "1_0", "1.2345678901234567", "NaN", "Infinity", "-Infinity", "1e999", "-0.0" };
    const row: C.PgRow = .{ .allocator = t.allocator, .values = &values };
    try matrix(row);
    var owner: S.Stream = .{ .allocator = t.allocator, .client = null, .options = .{}, .values = &values, .phase = .execute, .extended = false };
    const borrowed: S.BorrowedRow = .{ .owner = &owner, .generation = 0 };
    try matrix(borrowed);
    owner.generation += 1;
    try t.expectError(error.StaleRow, borrowed.getChecked(99));
    try t.expectError(error.StaleRow, borrowed.getTyped([]const u8, 0));
    try t.expectError(error.StaleRow, borrowed.getTyped(?bool, 2));
    // 0.3 compatibility is explicit, rather than silently changed by the new API.
    try t.expect((try row.getBool(4)).?);
    try t.expect(row.get(99) == null);
}
