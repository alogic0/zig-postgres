//! Optional live consumer. Build requires no database; running needs PG* settings.
const std = @import("std");
const postgres = @import("postgres");

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    const pool = try postgres.Pool.init(init.arena.allocator(), init.io, .{
        .host = env.get("PGHOST") orelse "127.0.0.1",
        .port = try std.fmt.parseInt(u16, env.get("PGPORT") orelse "5432", 10),
        .user = env.get("PGUSER") orelse return error.PGUSERRequired,
        .password = env.get("PGPASSWORD") orelse return error.PGPASSWORDRequired,
        .database = env.get("PGDATABASE") orelse return error.PGDATABASERequired,
        .size = 1,
    });
    defer pool.deinit();
    const client = try pool.acquire();
    defer pool.release(client);
    var transaction = try postgres.Transaction.begin(client);
    defer transaction.deinit();
    var result = try client.queryParams("SELECT $1::bigint, $2::text, $3::boolean", .{ @as(i64, 1), "prospect's follow-up", true });
    defer result.deinit();
    if (result.rows.len != 1 or try result.rows[0].getTyped(?i64, 0) != 1) return error.UnexpectedResult;
    if (!std.mem.eql(u8, result.rows[0].get(1).?, "prospect's follow-up") or try result.rows[0].getTyped(?bool, 2) != true) return error.UnexpectedResult;
    const rows = try client.streamParams("SELECT $1::bigint", .{@as(i64, 2)}, .{});
    defer rows.deinit();
    var count: usize = 0;
    while (try rows.next()) |borrowed| {
        var owned = try borrowed.copy(init.gpa);
        defer owned.deinit();
        if (try owned.getTyped(?i64, 0) != 2) return error.UnexpectedResult;
        count += 1;
    }
    if (count != 1) return error.UnexpectedResult;
    try transaction.commit();
}
