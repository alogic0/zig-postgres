//! RFC 5802 attribute validation shared by the PostgreSQL SCRAM exchange.
const std = @import("std");
const Invalid = error{AuthenticationFailed};
const Parts = std.mem.SplitIterator(u8, .scalar);
pub const First = struct { nonce: []const u8, salt: []const u8, iterations: u32 };

fn extensions(parts: *Parts, reserved: []const u8) Invalid!void {
    var seen: [128]bool = @splat(false);
    for (reserved) |key| seen[key] = true;
    while (parts.next()) |part| {
        if (part.len < 3 or !std.ascii.isAlphabetic(part[0]) or part[1] != '=' or part[0] == 'm') return error.AuthenticationFailed;
        const key = part[0];
        if (seen[key] or std.mem.indexOfScalar(u8, part, 0) != null) return error.AuthenticationFailed;
        seen[key] = true;
    }
}
pub fn first(message: []const u8, client_nonce: []const u8) Invalid!First {
    var parts = std.mem.splitScalar(u8, message, ',');
    const r = parts.next() orelse return error.AuthenticationFailed;
    const s = parts.next() orelse return error.AuthenticationFailed;
    const i = parts.next() orelse return error.AuthenticationFailed;
    if (!std.mem.startsWith(u8, r, "r=") or !std.mem.startsWith(u8, s, "s=") or !std.mem.startsWith(u8, i, "i=")) return error.AuthenticationFailed;
    const nonce = r[2..];
    if (nonce.len <= client_nonce.len or !std.mem.startsWith(u8, nonce, client_nonce)) return error.AuthenticationFailed;
    for (nonce) |byte| if (byte < 33 or byte > 126) return error.AuthenticationFailed;
    const salt = s[2..];
    if (salt.len == 0 or i.len < 3 or i[2] < '1' or i[2] > '9') return error.AuthenticationFailed;
    for (i[2..]) |byte| if (!std.ascii.isDigit(byte)) return error.AuthenticationFailed;
    const iterations = std.fmt.parseInt(u32, i[2..], 10) catch return error.AuthenticationFailed;
    try extensions(&parts, "rsi");
    return .{ .nonce = nonce, .salt = salt, .iterations = iterations };
}
pub fn final(message: []const u8, expected: [32]u8) Invalid!void {
    var parts = std.mem.splitScalar(u8, message, ',');
    const v = parts.next() orelse return error.AuthenticationFailed;
    if (!std.mem.startsWith(u8, v, "v=")) return error.AuthenticationFailed;
    const encoded = v[2..];
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.AuthenticationFailed;
    if (size != 32) return error.AuthenticationFailed;
    var signature: [32]u8 = undefined;
    std.base64.standard.Decoder.decode(&signature, encoded) catch return error.AuthenticationFailed;
    try extensions(&parts, "ve");
    if (!std.crypto.timing_safe.eql([32]u8, signature, expected)) return error.AuthenticationFailed;
}
pub fn supportsSha256(mechanisms: []const u8) bool {
    var remaining = mechanisms;
    var found = false;
    while (remaining.len > 1) {
        const end = std.mem.indexOfScalar(u8, remaining, 0) orelse return false;
        if (end == 0) return false;
        if (std.mem.eql(u8, remaining[0..end], "SCRAM-SHA-256")) found = true;
        remaining = remaining[end + 1 ..];
    }
    return found and remaining.len == 1 and remaining[0] == 0;
}

test "SCRAM requires an extended bound nonce and valid unique attributes" {
    const good = try first("r=clientserver,s=c2FsdA==,i=4096,x=optional", "client");
    try std.testing.expectEqual(@as(u32, 4096), good.iterations);
    for ([_][]const u8{
        "r=wrong,s=c2FsdA==,i=4096",                "r=client,s=c2FsdA==,i=4096",
        "r=clientserver,s=,i=4096",                 "r=clientserver,s=c2FsdA==,i=0",
        "r=clientserver,s=c2FsdA==,i=01",           "r=clientserver,s=c2FsdA==,i=+1",
        "r=clientserver,s=c2FsdA==,i=4294967296",   "r=clientserver,s=c2FsdA==",
        "r=clientserver,s=c2FsdA==,i=4096,r=again", "r=clientserver,s=c2FsdA==,i=4096,m=required",
        "r=clientserver,s=c2FsdA==,i=4096,x=a,x=b", "r=clientserver,s=c2FsdA==,i=4096,",
    }) |message| try std.testing.expectError(error.AuthenticationFailed, first(message, "client"));
}

test "SCRAM verifies the exact proof and preserves optional extensions" {
    const expected: [32]u8 = @splat(0);
    const valid = "v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    try final(valid, expected);
    try final(valid ++ ",x=optional", expected);
    for ([_][]const u8{ "", "e=invalid-proof", "v=bad", valid ++ ",v=duplicate", valid ++ ",e=bad", valid ++ ",m=required" }) |message| try std.testing.expectError(error.AuthenticationFailed, final(message, expected));
    const other: [32]u8 = @splat(1);
    try std.testing.expectError(error.AuthenticationFailed, final(valid, other));
    try std.testing.expect(supportsSha256("SCRAM-SHA-256\x00\x00"));
    try std.testing.expect(supportsSha256("SCRAM-SHA-256-PLUS\x00SCRAM-SHA-256\x00\x00"));
    try std.testing.expect(!supportsSha256("SCRAM-SHA-256\x00"));
    try std.testing.expect(!supportsSha256("SCRAM-SHA-256-PLUS\x00\x00"));
}
