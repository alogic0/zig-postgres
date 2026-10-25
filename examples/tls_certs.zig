//! Owned, bounded OpenSSL CLI adapter. Creates no network resources.
const std = @import("std");
fn run(a: std.mem.Allocator, io: std.Io, root: []const u8, args: []const []const u8) !void {
    const result = try std.process.run(a, io, .{ .argv = args, .cwd = .{ .path = root }, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536), .timeout = (std.Io.Timeout{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } }).toDeadline(io) });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("certificate command failed: {s}\n", .{result.stderr});
            return error.CertificateCommandFailed;
        },
        else => return error.CertificateCommandFailed,
    }
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2 or !std.fs.path.isAbsolute(args[1]) or !std.mem.startsWith(u8, std.fs.path.basename(args[1]), "zg-postgres-tls-")) return error.OwnedCertificateDirectoryRequired;
    const root = args[1];
    try std.Io.Dir.cwd().createDirPath(init.io, root);
    try run(a, init.io, root, &.{ "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650", "-subj", "/CN=zig-postgres fixture CA", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-keyout", "ca.key", "-out", "ca.crt" });
    try run(a, init.io, root, &.{ "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650", "-subj", "/CN=other fixture CA", "-keyout", "other-ca.key", "-out", "other-ca.crt" });
    try run(a, init.io, root, &.{ "openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=localhost", "-keyout", "leaf.key", "-out", "leaf.csr" });
    const config =
        \\[ca]
        \\default_ca=fixture
        \\[fixture]
        \\database=index.txt
        \\serial=serial
        \\new_certs_dir=.
        \\private_key=ca.key
        \\certificate=ca.crt
        \\default_md=sha256
        \\policy=policy
        \\unique_subject=no
        \\x509_extensions=leaf
        \\[policy]
        \\commonName=supplied
        \\[leaf]
        \\basicConstraints=critical,CA:FALSE
        \\keyUsage=critical,digitalSignature,keyEncipherment
        \\extendedKeyUsage=serverAuth
        \\subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1
    ;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try a.print("{s}/ca.cnf", .{root}), .data = config });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try a.print("{s}/index.txt", .{root}), .data = "" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try a.print("{s}/serial", .{root}), .data = "1000\n" });
    try run(a, init.io, root, &.{ "openssl", "ca", "-batch", "-notext", "-config", "ca.cnf", "-in", "leaf.csr", "-out", "leaf.crt", "-startdate", "20000101000000Z", "-enddate", "20500101000000Z" });
    try run(a, init.io, root, &.{ "openssl", "ca", "-batch", "-notext", "-config", "ca.cnf", "-in", "leaf.csr", "-out", "expired.crt", "-startdate", "20000101000000Z", "-enddate", "20010101000000Z" });
    std.debug.print("PASS owned TLS fixture certificates: {s}\n", .{root});
}
