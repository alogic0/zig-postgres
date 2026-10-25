//! Independent receipt parser. Does not import the client or its protocol cursor.
const std = @import("std");
const V = std.json.Value;
fn require(ok: bool) !void {
    if (!ok) return error.InvalidWireReceipt;
}
fn decode(a: std.mem.Allocator, v: V) ![]u8 {
    const hex = v.object.get("hex").?.string;
    try require(hex.len % 2 == 0);
    const b = try a.alloc(u8, hex.len / 2);
    for (b, 0..) |*byte, i| byte.* = try std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16);
    try require(b.len >= 5 and std.mem.readInt(u32, b[1..5], .big) == b.len - 1);
    return b;
}
const Mutation = enum { none, extra_sync, drop_error, bad_state, drop_ready };
fn check(a: std.mem.Allocator, root: V, marker: []const u8, late_error: bool) !void {
    var matches: usize = 0;
    for (root.object.get("records").?.array.items) |record| {
        const client = record.object.get("client").?.array.items;
        const server = record.object.get("server").?.array.items;
        for (client, 0..) |item, index| {
            const bytes = try decode(a, item);
            if (bytes[0] != 'P' or std.mem.indexOf(u8, bytes, marker) == null) continue;
            matches += 1;
            const start = item.object.get("ordinal").?.integer;
            var end: i64 = std.math.maxInt(i64);
            var syncs: usize = 0;
            var request: std.ArrayList(u8) = .empty;
            for (client[index..], 0..) |frame, i| {
                const b = try decode(a, frame);
                if (i > 0 and (b[0] == 'P' or b[0] == 'Q' or b[0] == 'X')) {
                    end = frame.object.get("ordinal").?.integer;
                    break;
                }
                try request.append(a, b[0]);
                if (b[0] == 'S') syncs += 1;
            }
            try require(syncs == 1 and std.mem.eql(u8, request.items, "PBDES"));
            var commands: usize = 0;
            var errors: usize = 0;
            var ready: usize = 0;
            var after_command = false;
            var after_error = false;
            var rows: usize = 0;
            for (server) |frame| {
                const ordinal = frame.object.get("ordinal").?.integer;
                if (ordinal <= start or ordinal >= end) continue;
                const b = try decode(a, frame);
                switch (b[0]) {
                    'C' => {
                        commands += 1;
                        after_command = true;
                    },
                    'D' => {
                        try require(!after_command);
                        rows += 1;
                    },
                    'E' => {
                        errors += 1;
                        try require(after_command and !after_error);
                        after_error = true;
                        try require(std.mem.indexOf(u8, b[5..], "C23505\x00") != null);
                    },
                    'Z' => {
                        ready += 1;
                        try require(b.len == 6 and b[5] == 'I' and after_command and (if (late_error) after_error else !after_error));
                    },
                    else => {},
                }
            }
            try require(commands == 1 and rows > 0 and ready == 1 and errors == (if (late_error) @as(usize, 1) else 0));
        }
    }
    try require(matches == 1);
}
// Mutate retained input before invoking the ordinary acceptance parser.
fn corrupt(a: std.mem.Allocator, root: V, mutation: Mutation) !void {
    for (root.object.get("records").?.array.items) |record| {
        const client = record.object.getPtr("client").?;
        const server = record.object.getPtr("server").?;
        for (client.array.items, 0..) |frame, index| {
            const b = try decode(a, frame);
            if (b[0] != 'P' or std.mem.indexOf(u8, b, "PG3-R14") == null) continue;
            const start = frame.object.get("ordinal").?.integer;
            if (mutation == .extra_sync) {
                try client.array.insert(index + 5, client.array.items[index + 4]);
                return;
            }
            for (server.array.items, 0..) |reply, i| {
                if (reply.object.get("ordinal").?.integer <= start) continue;
                const bytes = try decode(a, reply);
                if (bytes[0] == 'E' and mutation == .drop_error) {
                    _ = server.array.orderedRemove(i);
                    return;
                }
                if (bytes[0] == 'Z' and mutation == .drop_ready) {
                    _ = server.array.orderedRemove(i);
                    return;
                }
                if (bytes[0] == 'E' and mutation == .bad_state) {
                    const field = reply.object.getPtr("hex").?;
                    const offset = std.mem.indexOf(u8, field.string, "43323335303500") orelse return error.MissingErrorField;
                    const changed = try a.dupe(u8, field.string);
                    @memcpy(changed[offset..][0..14], "43323335303400");
                    field.* = .{ .string = changed };
                    return;
                }
            }
            return error.MissingMutationTarget;
        }
    }
    return error.MissingMutationTarget;
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    try require(args.len == 2);
    const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(16 * 1024 * 1024));
    const root = try std.json.parseFromSliceLeaky(V, a, raw, .{});
    try require(root.object.get("active").?.integer == 0 and !root.object.get("failed").?.bool);
    try check(a, root, "PG3-R13", false);
    try check(a, root, "PG3-R14", true);
    try check(a, root, "PG5-SYNC", true);
    try check(a, root, "PG5-COMMIT", false);
    inline for (.{ Mutation.extra_sync, .drop_error, .bad_state, .drop_ready }) |mutation| {
        const corrupted = try std.json.parseFromSliceLeaky(V, a, raw, .{});
        try corrupt(a, corrupted, mutation);
        if (check(a, corrupted, "PG3-R14", true)) |_| return error.AcceptedCorruption else |err| try require(err == error.InvalidWireReceipt);
    }
    std.debug.print("PASS wire: materialized/streamed delayed commit and deferred Sync failure; one Sync/Ready each; four corruptions rejected\n", .{});
}
