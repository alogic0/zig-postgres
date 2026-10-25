const std = @import("std");
const pg = @import("postgres");
const Io = std.Io;
const A = std.mem.Allocator;
const Tracker = @import("heap_tracker.zig").Tracker;

const sql = "SELECT to_jsonb(r)::text FROM pg5_export_rows r ORDER BY r.row_number LIMIT 500";
fn exec(c: *pg.PgClient, s: []const u8) !void {
    var r = try c.query(s);
    r.deinit();
}
fn measure(a: A, io: Io, config: pg.ConnectOptions, expected: []const u8, limit: usize, comptime streamed: bool) !struct { limit: usize, peak_bytes: usize, elapsed_ms: i64, rows: usize, bytes: usize, sha256: [64]u8, failure: ?[]const u8 } {
    var t: Tracker = .{ .parent = a };
    defer std.debug.assert(t.live == 0);
    const c = try pg.PgClient.connectOpts(t.allocator(), io, config);
    defer c.close();
    var marker = try c.query("SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname=current_database()");
    const ok = marker.rows.len == 1 and std.mem.eql(u8, marker.rows[0].get(0) orelse "", expected);
    marker.deinit();
    if (!ok) return error.UnownedDatabase;
    try exec(c, "CREATE TEMP TABLE pg5_export_rows(row_number bigint,payload jsonb,raw_payload jsonb,status text)");
    try exec(c, "INSERT INTO pg5_export_rows SELECT i,'{}',jsonb_build_object('Name',repeat('x',147456)),'success' FROM generate_series(1,500) i");
    c.limits.max_result_bytes = limit;
    t.peak = t.live;
    const start = Io.Timestamp.now(io, .awake);
    var count: usize = 0;
    var bytes: usize = 0;
    var failure: ?[]const u8 = null;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    if (streamed) {
        const rows = try c.streamQuery(sql, .{ .max_buffer_bytes = 1024 * 1024 });
        defer rows.deinit();
        while (try rows.next()) |row| {
            const raw = (try row.get(0)).?;
            count += 1;
            bytes += raw.len;
            digest.update(raw);
        }
    } else if (c.query(sql)) |v| {
        var r = v;
        defer r.deinit();
        for (r.rows) |row| {
            const raw = row.get(0).?;
            count += 1;
            bytes += raw.len;
            digest.update(raw);
        }
    } else |err| failure = @errorName(err);
    const elapsed = start.untilNow(io, .awake).toMilliseconds();
    var hash: [32]u8 = undefined;
    digest.final(&hash);
    return .{ .limit = limit, .peak_bytes = t.peak, .elapsed_ms = elapsed, .rows = count, .bytes = bytes, .sha256 = std.fmt.bytesToHex(hash, .lower), .failure = failure };
}
pub fn main(init: std.process.Init) !void {
    const db = init.environ_map.get("POSTGRES_TEST_DATABASE") orelse return error.OwnedDatabaseRequired;
    if (!std.mem.startsWith(u8, db, "zg_parity_upgrade_") or db.len != 30) return error.OwnedDatabaseRequired;
    const expected = init.environ_map.get("POSTGRES_TEST_MARKER") orelse try std.fmt.allocPrint(init.arena.allocator(), "zig-postgres disposable schema fixture {s}", .{db});
    if (expected.len == 0) return error.OwnedDatabaseRequired;
    const config: pg.ConnectOptions = .{
        .host = "127.0.0.1",
        .port = try std.fmt.parseInt(u16, init.environ_map.get("POSTGRES_TEST_PORT") orelse "5433", 10),
        .user = init.environ_map.get("PGUSER") orelse return error.PGUSERRequired,
        .password = init.environ_map.get("PGPASSWORD") orelse return error.PGPASSWORDRequired,
        .database = db,
        .tls = .{ .mode = .disable },
    };
    const out = init.environ_map.get("POSTGRES_TEST_REPORT") orelse return error.ReportRequired;
    var checked = std.heap.SafeAllocator.init(std.heap.page_allocator, .{});
    defer if (checked.deinitLog(false) != 0) @panic("measurement leak");
    const normal = try measure(checked.allocator(), init.io, config, expected, 64 * 1024 * 1024, false);
    const large = try measure(checked.allocator(), init.io, config, expected, 128 * 1024 * 1024, false);
    if (normal.failure == null or !std.mem.eql(u8, normal.failure.?, "ResultTooLarge") or large.rows != 500 or large.failure != null) return error.InvalidBaseline;
    const streamed = try measure(checked.allocator(), init.io, config, expected, 64 * 1024 * 1024, true);
    if (streamed.rows != 500 or streamed.failure != null or streamed.peak_bytes > 5 * 1024 * 1024 or !std.mem.eql(u8, &streamed.sha256, &large.sha256)) return error.StreamMemoryGate;
    const report = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{ .consumer = "results.csv 500-row JSON page", .source = "examples/measure.zig", .compiler = @import("builtin").zig_version_string, .profile = @tagName(@import("builtin").mode), .payload_bytes_per_row = 147456, .rows = 500, .concurrency = 1, .heap_budget_bytes = 5 * 1024 * 1024, .comparison_sql = sql, .default = normal, .expanded = large, .streamed = streamed }, .{ .whitespace = .indent_2 });
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out, .data = report });
}
