//! Additional actual-server decoding and bounded-memory cases. No app schema.
const std = @import("std");
const pg = @import("postgres");
const t = std.testing;
pub fn rows(a: std.mem.Allocator, io: std.Io, config: pg.PoolConfig) !struct { owned_and_streamed: bool, columns: usize, stale_checks: usize } {
    const pool = try pg.Pool.init(a, io, config);
    defer pool.deinit();
    const c = try pool.acquire();
    defer pool.release(c);
    const sql = "SELECT 't'::text,'f'::text,NULL::text,''::text,'tomato'::text,'not-boolean'::text,'-9223372036854775808'::text,'9223372036854775807'::text,'9223372036854775808'::text,'1.2345678901234567'::text,'NaN'::text,'Infinity'::text,'-Infinity'::text";
    var owned = try c.query(sql);
    defer owned.deinit();
    try check(owned.rows[0]);
    const stream = try c.streamQuery(sql, .{});
    defer stream.deinit();
    const borrowed = (try stream.next()).?;
    try check(borrowed);
    try t.expect(try stream.next() == null);
    try t.expectError(error.StaleRow, borrowed.getTyped(?bool, 2));
    try t.expectError(error.StaleRow, borrowed.getChecked(999));
    return .{ .owned_and_streamed = true, .columns = 13, .stale_checks = 2 };
}
fn check(row: anytype) !void {
    try t.expect(try row.getTyped(bool, 0));
    try t.expect(!try row.getTyped(bool, 1));
    try t.expect(try row.getTyped(?bool, 2) == null);
    try t.expectError(error.UnexpectedNull, row.getTyped(bool, 2));
    try t.expectEqualStrings("", try row.getTyped([]const u8, 3));
    for ([_]usize{ 3, 4, 5 }) |i| try t.expectError(error.InvalidBoolean, row.getTyped(bool, i));
    try t.expectError(error.ColumnOutOfBounds, row.getTyped(?bool, 999));
    try t.expectEqual(std.math.minInt(i64), try row.getTyped(i64, 6));
    try t.expectEqual(std.math.maxInt(i64), try row.getTyped(i64, 7));
    try t.expectError(error.Overflow, row.getTyped(i64, 8));
    try t.expectEqual(@as(f64, 1.2345678901234567), try row.getTyped(f64, 9));
    try t.expect(std.math.isNan(try row.getTyped(f64, 10)));
    try t.expectEqual(std.math.inf(f64), try row.getTyped(f64, 11));
    try t.expectEqual(-std.math.inf(f64), try row.getTyped(f64, 12));
}
pub const Measurement = struct { rows: usize, bytes: usize, driver_peak_bytes: usize, driver_retained_bytes: usize };
pub fn measure(a: std.mem.Allocator, io: std.Io, config: pg.PoolConfig) !Measurement {
    var tracker: @import("heap_tracker.zig").Tracker = .{ .parent = a };
    var result: Measurement = .{ .rows = 0, .bytes = 0, .driver_peak_bytes = 0, .driver_retained_bytes = 0 };
    {
        const pool = try pg.Pool.init(tracker.allocator(), io, config);
        defer pool.deinit();
        const c = try pool.acquire();
        defer pool.release(c);
        const stream = try c.streamQuery("SELECT repeat('x',147456) FROM generate_series(1,500)", .{});
        defer stream.deinit();
        while (try stream.next()) |row| {
            const bytes = try row.getTyped([]const u8, 0);
            try t.expect(bytes.len == 147456 and bytes[0] == 'x');
            result.rows += 1;
            result.bytes += bytes.len;
        }
    }
    try t.expect(result.rows == 500 and tracker.live == 0 and tracker.peak < 1024 * 1024);
    result.driver_peak_bytes = tracker.peak;
    result.driver_retained_bytes = tracker.live;
    return result;
}
