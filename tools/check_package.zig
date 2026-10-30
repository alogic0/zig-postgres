//! Build the README consumer from a source archive with initially empty caches.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

fn read(a: Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024));
}

fn checkReadme(a: Allocator, io: Io) !void {
    const readme = try read(a, io, "README.md");
    const fixture = try read(a, io, "tests/package/main.zig");
    var blocks = std.mem.splitSequence(u8, readme, "```zig\n");
    _ = blocks.next();
    while (blocks.next()) |block| {
        const end = std.mem.indexOf(u8, block, "```") orelse continue;
        const example = block[0..end];
        if (std.mem.indexOf(u8, example, "pub fn main(") == null) continue;
        if (!std.mem.eql(u8, fixture, example)) {
            std.debug.print("README application and tests/package/main.zig differ\n", .{});
            return error.ReadmeExampleMismatch;
        }
        return;
    }
    return error.ReadmeExampleMissing;
}

fn generated(name: []const u8) bool {
    inline for (.{ ".git", ".zig-cache", "zig-pkg", "zig-out" }) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidPackagePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.InvalidPackagePath;
    }
}

const Archive = struct {
    writer: std.tar.Writer,
    license: bool = false,

    fn add(self: *Archive, a: Allocator, io: Io, path: []const u8) anyerror!void {
        if (generated(std.fs.path.basename(path))) return;
        const cwd = Io.Dir.cwd();
        const stat = try cwd.statFile(io, path, .{ .follow_symlinks = false });
        switch (stat.kind) {
            .directory => {
                try self.writer.writeDir(path, .{});
                var dir = try cwd.openDir(io, path, .{ .iterate = true });
                defer dir.close(io);
                var entries = dir.iterate();
                while (try entries.next(io)) |entry| {
                    if (generated(entry.name)) continue;
                    try self.add(a, io, try std.fs.path.join(a, &.{ path, entry.name }));
                }
            },
            .file => {
                const file = try cwd.openFile(io, path, .{});
                defer file.close(io);
                var buffer: [8192]u8 = undefined;
                var reader = file.reader(io, &buffer);
                try self.writer.writeFile(path, &reader, 0);
                if (std.mem.eql(u8, path, "LICENSE")) self.license = true;
            },
            else => return error.UnsupportedPackageEntry,
        }
    }
};

fn createArchive(a: Allocator, io: Io, destination: []const u8) !void {
    const source = try a.dupeSentinel(u8, try read(a, io, "build.zig.zon"), 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(struct { paths: []const []const u8 }, .{
        .gpa = a,
        .arena = a,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| {
        if (err == error.ParseZon) diagnostics.log("build.zig.zon");
        return err;
    };
    const file = try Io.Dir.cwd().createFile(io, destination, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var archive: Archive = .{ .writer = .{ .underlying_writer = &writer.interface } };
    try archive.writer.setRoot("postgres/");
    for (manifest.paths) |path| {
        try validatePath(path);
        try archive.add(a, io, path);
    }
    if (!archive.license) return error.PackageLicenseMissing;
    try archive.writer.finishPedantically();
    try writer.interface.flush();
}

fn run(io: Io, env: *const std.process.Environ.Map, cwd: []const u8, args: []const []const u8) !void {
    std.debug.print("+", .{});
    for (args) |arg| std.debug.print(" {s}", .{arg});
    std.debug.print("\n", .{});
    var child = try std.process.spawn(io, .{
        .argv = args,
        .cwd = .{ .path = cwd },
        .environ_map = env,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("Package check command {f}\n", .{term});
        return error.PackageCommandFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.ZigExecutableRequired;
    const zig = args[1];
    try checkReadme(a, io);

    const cwd = Io.Dir.cwd();
    const root = try std.process.currentPathAlloc(io, a);
    var random: [16]u8 = undefined;
    io.random(&random);
    const work = try a.print("{s}/.zig-cache/package-check-{s}", .{ root, std.fmt.bytesToHex(random, .lower) });
    try cwd.createDirPath(io, ".zig-cache");
    try cwd.createDir(io, work, .default_dir);
    var cleanup_attempted = false;
    defer if (!cleanup_attempted) cwd.deleteTree(io, work) catch |err| {
        std.debug.print("Failed to remove package check directory {s}: {t}\n", .{ work, err });
    };
    const archive = try a.print("{s}/postgres.tar", .{work});
    try createArchive(a, io, archive);

    const consumer = try a.print("{s}/consumer", .{work});
    try cwd.createDir(io, consumer, .default_dir);
    inline for (.{ "build.zig", "build.zig.zon", "main.zig" }) |name| {
        const source = try read(a, io, "tests/package/" ++ name);
        const data = if (comptime std.mem.eql(u8, name, "build.zig.zon")) blk: {
            const dependency = ".postgres = .{ .path = \"../..\" },";
            if (std.mem.count(u8, source, dependency) != 1) return error.UnexpectedConsumerManifest;
            break :blk try std.mem.replaceOwned(u8, a, source, dependency, "");
        } else source;
        try cwd.writeFile(io, .{ .sub_path = try a.print("{s}/{s}", .{ consumer, name }), .data = data });
    }

    var env = try init.environ_map.clone(a);
    defer env.deinit();
    inline for (.{ .{ "ZIG_GLOBAL_CACHE_DIR", "global-cache" }, .{ "ZIG_LOCAL_CACHE_DIR", "local-cache" }, .{ "ZIG_LOCAL_PKG_DIR", "packages" } }) |setting| {
        try env.put(setting[0], try a.print("{s}/{s}", .{ work, setting[1] }));
    }
    try run(io, &env, consumer, &.{ zig, "fetch", "--save=postgres", archive });
    inline for (.{ "debug", "safe" }) |mode| {
        inline for (.{ "false", "true" }) |tls| {
            try run(io, &env, consumer, &.{ zig, "build", "-Doptimize=" ++ mode, "-Dtls=" ++ tls, "-j4", "--summary", "all" });
        }
    }
    cleanup_attempted = true;
    try cwd.deleteTree(io, work);
    std.debug.print("Package archive consumer passed all four build settings.\n", .{});
}
