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
    var result = try client.query("SELECT 1");
    defer result.deinit();
    if (result.rows.len != 1 or try result.rows[0].getInt(0, i64) != 1) return error.UnexpectedResult;
    try transaction.commit();
}
