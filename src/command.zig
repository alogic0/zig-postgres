//! A count describes only the final CommandComplete operation, never row writes.
const std = @import("std");
pub fn count(tag: []const u8) error{ InvalidCommandTag, Overflow }!?u64 {
    if (tag.len == 0) return null;
    const space = std.mem.indexOfScalar(u8, tag, ' ') orelse tag.len;
    const name = tag[0..space];
    var recognized = false;
    for ([_][]const u8{ "INSERT", "UPDATE", "DELETE", "MERGE", "SELECT", "MOVE", "FETCH", "COPY" }) |op| if (std.mem.eql(u8, name, op)) {
        recognized = true;
    };
    if (!recognized) return null;
    if (space == tag.len) return error.InvalidCommandTag;
    var digits = tag[space + 1 ..];
    if (std.mem.eql(u8, name, "INSERT")) {
        if (!std.mem.startsWith(u8, digits, "0 ")) return error.InvalidCommandTag;
        digits = digits[2..];
    }
    if (digits.len == 0) return error.InvalidCommandTag;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidCommandTag;
    return std.fmt.parseInt(u64, digits, 10) catch return error.Overflow;
}
test "only final supported command forms carry checked nonnegative counts" {
    const t = std.testing;
    for ([_][]const u8{ "INSERT 0 2", "UPDATE 2", "DELETE 2", "MERGE 2", "SELECT 2", "MOVE 2", "FETCH 2", "COPY 2" }) |tag| try t.expectEqual(@as(?u64, 2), try count(tag));
    for ([_][]const u8{ "", "CREATE TABLE", "COMMIT", "CREATE TABLE 7", "EXPLAIN 2" }) |tag| try t.expect(try count(tag) == null);
    try t.expectEqual(@as(?u64, 0), try count("UPDATE 0"));
    for ([_][]const u8{ "UPDATE", "UPDATE ", "UPDATE -1", "UPDATE +1", "UPDATE 1 2", "INSERT 1 2", "INSERT 0 ", "SELECT 1_0" }) |tag| try t.expectError(error.InvalidCommandTag, count(tag));
    try t.expectError(error.Overflow, count("COPY 18446744073709551616"));
}
