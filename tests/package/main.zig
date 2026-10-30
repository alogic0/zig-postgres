const std = @import("std");
const pg = @import("postgres");

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    const pool = try pg.Pool.initLazy(init.gpa, init.io, .{
        .host = env.get("PGHOST") orelse "127.0.0.1",
        .port = try std.fmt.parseInt(u16, env.get("PGPORT") orelse "5432", 10),
        .user = env.get("PGUSER") orelse return error.PGUSERRequired,
        .password = env.get("PGPASSWORD") orelse return error.PGPASSWORDRequired,
        .database = env.get("PGDATABASE") orelse return error.PGDATABASERequired,
        .size = 4,
        .connect_timeout_ms = 5000,
    });
    defer pool.deinit();

    const end = std.Io.Timestamp.now(init.io, .awake)
        .addDuration(.fromMilliseconds(5000));
    const client = try pool.acquireOpts(.{ .deadline = end });
    defer pool.release(client);

    var result = try client.queryParamsOpts(
        "SELECT $1::bigint, $2::text",
        .{ @as(i64, 42), "hello" },
        .{ .deadline = end },
    );
    defer result.deinit();

    const id = try result.rows[0].getTyped(i64, 0);
    const text = try result.rows[0].getTyped([]const u8, 1);
    std.debug.print("{d}: {s}\n", .{ id, text });
}
