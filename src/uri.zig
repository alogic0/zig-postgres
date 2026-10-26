//! Owned PostgreSQL URI configuration; pool sizing and retry remain with callers.
const std = @import("std");
const A = std.mem.Allocator;
const PoolConfig = @import("pool.zig").PoolConfig;
pub const ParsedUri = struct {
    arena: std.heap.ArenaAllocator,
    config: PoolConfig,

    pub fn parse(a: A, text: []const u8) !ParsedUri {
        return fromUri(a, try std.Uri.parse(text));
    }

    pub fn fromUri(a: A, uri: std.Uri) !ParsedUri {
        if (!std.mem.eql(u8, uri.scheme, "postgresql") and !std.mem.eql(u8, uri.scheme, "postgres")) return error.InvalidUriScheme;
        if (uri.fragment != null) return error.UnsupportedConnectionParam;
        const path_bytes = switch (uri.path) {
            .raw, .percent_encoded => |bytes| bytes,
        };
        if (path_bytes.len > 0 and path_bytes[0] != '/') return error.InvalidDatabaseUri;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var host = try component(aa, uri.host orelse .{ .raw = "localhost" });
        if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
        const user = try component(aa, uri.user orelse .{ .raw = "postgres" });
        const password = try component(aa, uri.password orelse .{ .raw = "" });
        // Remove the URI separator before decoding: %2F belongs to the database
        // name, including a leading encoded slash.
        const path_part: std.Uri.Component = switch (uri.path) {
            .raw => |bytes| .{ .raw = if (std.mem.startsWith(u8, bytes, "/")) bytes[1..] else bytes },
            .percent_encoded => |bytes| .{ .percent_encoded = if (std.mem.startsWith(u8, bytes, "/")) bytes[1..] else bytes },
        };
        const path = try component(aa, path_part);
        if (uri.port == 0) return error.InvalidDatabaseUri;
        var config: PoolConfig = .{
            .host = host,
            .port = uri.port orelse 5432,
            .user = user,
            .password = password,
            .database = if (path.len == 0) user else path,
        };
        var mode_seen = false;
        var cert_seen = false;
        var name_seen = false;
        if (uri.query) |query| {
            const raw = switch (query) {
                .raw, .percent_encoded => |bytes| bytes,
            };
            var pairs = std.mem.splitScalar(u8, raw, '&');
            while (pairs.next()) |pair| {
                if (pair.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.UnsupportedConnectionParam;
                const key = try component(aa, .{ .percent_encoded = pair[0..eq] });
                const value = try component(aa, .{ .percent_encoded = pair[eq + 1 ..] });
                if (std.mem.eql(u8, key, "sslmode")) {
                    if (mode_seen) return error.DuplicateConnectionParam;
                    mode_seen = true;
                    if (std.mem.eql(u8, value, "disable")) {
                        config.tls.mode = .disable;
                    } else if (std.mem.eql(u8, value, "verify-full")) {
                        config.tls.mode = .verify_full;
                    } else return error.UnsupportedSSLModeValue;
                } else if (std.mem.eql(u8, key, "sslrootcert")) {
                    if (cert_seen or value.len == 0) return error.InvalidTlsConfiguration;
                    cert_seen = true;
                    config.tls.ca_file = value;
                } else if (std.mem.eql(u8, key, "sslservername")) {
                    if (name_seen or value.len == 0) return error.InvalidTlsConfiguration;
                    name_seen = true;
                    config.tls.server_name = value;
                } else return error.UnsupportedConnectionParam;
            }
        }
        if (cert_seen or name_seen) {
            if (mode_seen and config.tls.mode == .disable) return error.InvalidTlsConfiguration;
            config.tls.mode = .verify_full;
        }
        if (host.len == 0 or user.len == 0) return error.InvalidDatabaseUri;
        return .{ .arena = arena, .config = config };
    }

    pub fn deinit(self: *ParsedUri) void {
        self.arena.deinit();
    }
};

fn component(a: A, value: std.Uri.Component) ![]const u8 {
    // Uri decoding tolerates malformed escapes; connection configuration does not.
    if (value == .percent_encoded) {
        const bytes = value.percent_encoded;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] != '%') continue;
            if (i + 2 >= bytes.len) return error.InvalidDatabaseUri;
            for (bytes[i + 1 ..][0..2]) |digit| {
                if (!std.ascii.isHex(digit)) return error.InvalidDatabaseUri;
            }
            i += 2;
        }
    }
    const raw = try value.toRawMaybeAlloc(a);
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidDatabaseUri;
    return a.dupe(u8, raw);
}

test "URI owns decoded strings IPv6 defaults paths TLS and rejects unsafe options" {
    const t = std.testing;
    const a = t.allocator;
    const input = try a.dupe(u8, "postgresql://us%65r:p%40ss@[::1]:5444/%2Fdb%20name?sslmode=verify-full&sslrootcert=%2Ftmp%2Fa%26b.pem&sslservername=database.local");
    var uri = try ParsedUri.parse(a, input);
    defer uri.deinit();
    a.free(input);
    try t.expectEqualStrings("::1", uri.config.host);
    try t.expectEqualStrings("user", uri.config.user);
    try t.expectEqualStrings("p@ss", uri.config.password);
    try t.expectEqualStrings("/db name", uri.config.database);
    try t.expectEqualStrings("/tmp/a&b.pem", uri.config.tls.ca_file);
    try t.expectEqualStrings("database.local", uri.config.tls.server_name.?);
    try t.expect(uri.config.port == 5444 and uri.config.tls.mode == .verify_full);
    var defaults = try ParsedUri.parse(a, "postgres://127.0.0.1");
    defer defaults.deinit();
    try t.expectEqualStrings("postgres", defaults.config.database);
    try t.expect(defaults.config.port == 5432);
    for ([_][]const u8{ "postgres://u:p%00ss@localhost/db", "postgres://host/db%xx", "postgres://host/db%+F", "postgres://host/db%_F", "postgres://host/db?sslmode=disable&ssl%6dode=disable", "postgres://host/db?sslmode=require", "postgres://host/db?sslrootcert=", "postgres://host/db?sslmode=disable&sslrootcert=ca", "postgres://host/db?unknown=x", "postgres://host/db#fragment", "postgres://host:0/db" }) |text| {
        if (ParsedUri.parse(a, text)) |parsed| {
            var owned = parsed;
            owned.deinit();
            return error.ExpectedInvalidUri;
        } else |_| {}
    }
}
