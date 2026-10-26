//! Generic helper acceptance on a marked disposable PostgreSQL, with no app SQL.
const std = @import("std");
const pg = @import("postgres");
const t = std.testing;
fn exec(c: *pg.PgClient, sql: []const u8) !void {
    var r = try c.query(sql);
    defer r.deinit();
}
fn counted(c: *pg.PgClient, sql: []const u8, expected: ?u64) !void {
    var r = try c.query(sql);
    defer r.deinit();
    try t.expectEqual(expected, try r.commandCount());
}
pub fn run(a: std.mem.Allocator, io: std.Io, config: pg.PoolConfig) !struct { mixed_paths: usize, float_roundtrips: usize, cardinality_paths: usize } {
    const pool = try pg.Pool.init(a, io, config);
    defer pool.deinit();
    const c = try pool.acquire();
    defer pool.release(c);
    var restored = false;
    defer if (!restored) {
        c.reusable = false;
    };
    try counted(c, "CREATE TEMP TABLE helper_counts(id int);INSERT INTO helper_counts VALUES(1),(2)", 2);
    const cases = .{ .{ "UPDATE helper_counts SET id=id;SELECT 1", @as(?u64, 1) }, .{ "SELECT generate_series(1,3);UPDATE helper_counts SET id=id WHERE false", @as(?u64, 0) }, .{ "UPDATE helper_counts SET id=id;CREATE TEMP TABLE helper_extra(id int)", @as(?u64, null) } };
    inline for (cases) |case| {
        try counted(c, case[0], case[1]);
        if (case[1] == null) try exec(c, "DROP TABLE helper_extra");
        const s = try c.streamQuery(case[0], .{});
        defer s.deinit();
        try t.expectError(error.IncompleteResult, s.commandCount());
        while (try s.next()) |_| {}
        try t.expectEqual(case[1], try s.commandCount());
        if (case[1] == null) try exec(c, "DROP TABLE helper_extra");
    }
    try counted(c, "MERGE INTO helper_counts t USING(VALUES(1),(4)) s(id) ON t.id=s.id WHEN MATCHED THEN UPDATE SET id=s.id WHEN NOT MATCHED THEN INSERT VALUES(s.id)", 2);
    try t.expectError(error.DatabaseError, c.query("UPDATE helper_counts SET id=id+10;SELECT 1/0"));
    const later_error = try c.streamQuery("UPDATE helper_counts SET id=id+10;SELECT 1/0", .{});
    defer later_error.deinit();
    try t.expectError(error.DatabaseError, later_error.next());
    try t.expectError(error.DatabaseError, later_error.commandCount());
    try counted(c, "DELETE FROM helper_counts WHERE id=4", 1);
    try counted(c, "BEGIN;DECLARE helper_cursor CURSOR FOR SELECT generate_series(1,5);MOVE 2 FROM helper_cursor", 2);
    try counted(c, "FETCH 1 FROM helper_cursor", 1);
    try exec(c, "CLOSE helper_cursor;ROLLBACK");
    const floats = [_]f64{ 0.0, -0.0, 0.1, 1.2345678901234567, std.math.floatMax(f64), @bitCast(@as(u64, 1)) };
    for (floats) |number| {
        var row = (try c.queryRowParams("SELECT $1::double precision", .{try pg.finiteFloat(number)})).?;
        defer row.deinit();
        try t.expectEqual(@as(u64, @bitCast(number)), @as(u64, @bitCast(try row.getTyped(f64, 0))));
    }
    try t.expectError(error.InvalidFloatParameter, c.queryParams("SELECT $1::double precision", .{pg.FiniteFloat{ .value = std.math.inf(f64) }}));
    try exec(c, "SELECT 1");
    try t.expect(try c.queryRow("SELECT 1 WHERE false") == null);
    var one = (try c.queryRowParams("SELECT $1::text", .{"owned row"})).?;
    defer one.deinit();
    try exec(c, "SELECT 2");
    try t.expectEqualStrings("owned row", try one.getTyped([]const u8, 0));
    try t.expectError(error.TooManyRows, c.queryRow("SELECT generate_series(1,2)"));
    for ([_]usize{ 0, 1, 2 }) |n| {
        const stream = try c.streamParams("SELECT generate_series(1,$1::int)", .{n}, .{});
        defer stream.deinit();
        if (n == 2) {
            try t.expectError(error.TooManyRows, stream.singleRow(a));
        } else {
            var row = try stream.singleRow(a);
            defer if (row) |*r| r.deinit();
            try t.expect((row != null) == (n == 1));
        }
        try t.expect(stream.complete);
        try exec(c, "SELECT 1");
    }
    try exec(c, "CREATE TEMP TABLE helper_deferred(v int UNIQUE DEFERRABLE INITIALLY DEFERRED);CREATE FUNCTION pg_temp.helper_write() RETURNS int LANGUAGE plpgsql AS $$ BEGIN INSERT INTO helper_deferred VALUES(1),(1);RETURN 1;END $$");
    try t.expectError(error.DatabaseError, c.queryRowParams("SELECT pg_temp.helper_write(),$1::int", .{1}));
    const deferred = try c.streamParams("SELECT pg_temp.helper_write(),$1::int", .{1}, .{});
    defer deferred.deinit();
    try t.expectError(error.DatabaseError, deferred.singleRow(a));
    try t.expectError(error.DatabaseError, deferred.commandCount());
    try t.expectEqualStrings("23505", &c.last_diagnostic.?.sqlstate.?);
    const late = try c.streamQuery("INSERT INTO helper_deferred VALUES(1),(1);SELECT generate_series(1,2)", .{});
    defer late.deinit();
    try t.expectError(error.DatabaseError, late.singleRow(a));
    try t.expectError(error.DatabaseError, late.commandCount());
    var empty = (try c.queryRow("SELECT count(*) FROM helper_deferred")).?;
    defer empty.deinit();
    try t.expectEqual(@as(i64, 0), try empty.getTyped(i64, 0));
    const copy_fault = try c.streamQuery("SELECT 'copy failure'::text", .{});
    defer copy_fault.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, copy_fault.singleRow(failing.allocator()));
    try t.expect(!c.reusable); // Abandonment on allocation failure cannot reenter a pool.
    // The session is discarded, removing all its temporary state. Other owned
    // result rows remain valid until their individual deinit calls above.
    restored = true;
    return .{ .mixed_paths = 6, .float_roundtrips = floats.len, .cardinality_paths = 8 };
}
