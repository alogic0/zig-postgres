//! Standalone, opt-in Docker owner. All resource identities are registered before
//! creation; subprocess groups, phases, driver cases and cleanup have deadlines.
const std = @import("std");
const pg = @import("postgres");
const process = @import("process");
const Io = std.Io;
const A = std.mem.Allocator;
const image = "docker.io/library/postgres@sha256:20edbde7749f822887a1a022ad526fde0a47d6b2be9a8364433605cf65099416";
const platform = "linux/amd64";
const Control = enum { none, startup_failure, stalled_command, hung_case, outer_timeout, cleanup_failure, interrupt };
const Limits = struct { pull_ms: u32 = 180000, command_ms: u32 = 30000, startup_ms: u32 = 60000, case_ms: u32 = 30000, test_ms: u32 = 300000, run_ms: u32 = 600000, cleanup_ms: u32 = 30000 };
var stopping: std.atomic.Value(bool) = .init(false);
fn signal(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .release);
}
fn waitSignal(io: Io) !void {
    while (!stopping.load(.acquire)) try io.sleep(.fromMilliseconds(10), .awake);
}
fn end(io: Io, ms: u32) Io.Timestamp {
    return Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(ms));
}
fn minimum(a: Io.Timestamp, b: Io.Timestamp) Io.Timestamp {
    return if (a.nanoseconds < b.nanoseconds) a else b;
}
fn remaining(io: Io, at: Io.Timestamp, cap: u32) !u32 {
    const now = Io.Timestamp.now(io, .awake);
    if (now.nanoseconds >= at.nanoseconds) return error.PhaseTimeout;
    return @intCast(@min(@as(i64, cap), @max(1, now.durationTo(at).toMilliseconds())));
}
fn bounded(io: Io, at: Io.Timestamp, comptime function: anytype, args: anytype) !void {
    const Done = union(enum) { work: anyerror!void, timeout: Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select = Io.Select(Done).init(io, &storage);
    defer select.cancelDiscard();
    const Worker = struct {
        fn run(work_io: Io, arguments: @TypeOf(args)) anyerror!void {
            const old = work_io.swapCancelProtection(.unblocked);
            defer _ = work_io.swapCancelProtection(old);
            try @call(.auto, function, arguments);
        }
    };
    try select.concurrent(.work, Worker.run, .{ io, args });
    try select.concurrent(.timeout, Io.sleep, .{ io, Io.Duration.fromMilliseconds(try remaining(io, at, std.math.maxInt(u32))), .awake });
    switch (try select.await()) {
        .work => |result| try result,
        .timeout => return error.PhaseTimeout,
    }
}
fn Payload(comptime F: type) type {
    return @typeInfo(@typeInfo(F).@"fn".return_type.?).error_union.payload;
}
fn valueWithin(io: Io, at: Io.Timestamp, comptime function: anytype, args: anytype) !Payload(@TypeOf(function)) {
    const R = Payload(@TypeOf(function));
    const Work = struct {
        result: ?R = null,
        arguments: @TypeOf(args),
        fn run(self: *@This()) !void {
            self.result = try @call(.auto, function, self.arguments);
        }
    };
    var work: Work = .{ .arguments = args };
    try bounded(io, at, Work.run, .{&work});
    return work.result.?;
}
fn limitsFrom(env: *const std.process.Environ.Map) !Limits {
    var limits: Limits = .{};
    inline for (@typeInfo(Limits).@"struct".field_names) |key| {
        const name = comptime blk: {
            var buffer: [key.len]u8 = undefined;
            break :blk "POSTGRES_LIVE_" ++ std.ascii.upperString(&buffer, key);
        };
        if (env.get(name)) |text| {
            @field(limits, key) = try std.fmt.parseInt(u32, text, 10);
            if (@field(limits, key) == 0) return error.InvalidDeadline;
        }
    }
    return limits;
}
const State = struct {
    a: A,
    io: Io,
    env: *const std.process.Environ.Map,
    executable: []const u8,
    cert_tool: []const u8,
    report: []const u8,
    limits: Limits,
    control: Control,
    nonce: []const u8,
    name: []const u8,
    volume: []const u8,
    database: []const u8,
    root: []const u8,
    certs: []const u8,
    marker: []const u8,
    run_end: Io.Timestamp,
    phase: []const u8 = "registered",
    injected: bool = false,
    root_owned: bool = false,
    port: u16 = 0,
    image_id: []const u8 = "",
    server_version: []const u8 = "",
    groups: std.json.Array,
    cleanup_passed: bool = false,
    cleanup_error: ?[]const u8 = null,
    driver_heap: ?@import("live_cases.zig").Measurement = null,
    fn make(init: std.process.Init, cert_tool: []const u8, report: []const u8, control: Control, limits: Limits) !State {
        const a = init.arena.allocator();
        var bytes: [6]u8 = undefined;
        init.io.random(&bytes);
        const nonce = init.environ_map.get("POSTGRES_LIVE_NONCE") orelse try a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
        if (nonce.len != 12) return error.InvalidOwner;
        for (nonce) |ch| if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return error.InvalidOwner;
        const name = try a.print("zig-postgres-live-{s}", .{nonce});
        const root = try a.print("/tmp/{s}", .{name});
        return .{ .a = a, .io = init.io, .env = init.environ_map, .executable = try std.process.executablePathAlloc(init.io, a), .cert_tool = cert_tool, .report = report, .limits = limits, .control = control, .nonce = nonce, .name = name, .volume = try a.print("{s}-data", .{name}), .database = try a.print("zig_postgres_live_{s}", .{nonce}), .root = root, .certs = try a.print("{s}/zg-postgres-tls-{s}", .{ root, nonce }), .marker = try a.print("zig-postgres standalone fixture {s}", .{nonce}), .run_end = end(init.io, limits.run_ms), .groups = std.json.Array.init(a) };
    }
    fn command(self: *State, args: []const []const u8, at: Io.Timestamp, cap: u32) !process.Report {
        const ms = try remaining(self.io, at, cap);
        return process.runReport(self.a, self.io, .{ .spawn = .{ .argv = args, .search_path = true, .environ_map = self.env, .launch_timeout_ms = ms }, .timeout_ms = ms, .stdout_limit = 65536, .stderr_limit = 65536 });
    }
    fn checked(self: *State, args: []const []const u8, at: Io.Timestamp, cap: u32) ![]const u8 {
        const result = try self.command(args, at, cap);
        defer result.deinit(self.a);
        if (!result.success()) {
            std.debug.print("live phase {s}: {s} ({s})\n", .{ self.phase, args[0], @tagName(result.outcome) });
            return error.FixtureCommandFailed;
        }
        return self.a.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }
    fn registerRoot(self: *State) !void {
        try Io.Dir.cwd().createDir(self.io, self.root, .fromMode(0o700));
        self.root_owned = true;
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = try self.a.print("{s}/owner", .{self.root}), .data = self.nonce });
    }
    fn execute(self: *State) !void {
        try self.registerRoot();
        // Exercise the outer watchdog independently of image/startup speed.
        // Active-driver cancellation and Docker cleanup have separate controls.
        if (self.control == .outer_timeout) {
            self.phase = "outer-timeout-control";
            try self.io.sleep(.fromSeconds(60), .awake);
            return error.FaultDidNotFail;
        }
        self.phase = "image";
        if (self.control == .stalled_command) {
            _ = try self.checked(&.{ self.executable, "--hang-child" }, minimum(self.run_end, end(self.io, self.limits.command_ms)), self.limits.command_ms);
            return error.FaultDidNotFail;
        }
        const inspected = try self.command(&.{ "docker", "image", "inspect", image, "--format", "{{.Id}} {{.Os}}/{{.Architecture}}" }, self.run_end, self.limits.command_ms);
        const available = inspected.success();
        inspected.deinit(self.a);
        if (!available) _ = try self.checked(&.{ "docker", "pull", "--platform", platform, image }, minimum(self.run_end, end(self.io, self.limits.pull_ms)), self.limits.pull_ms);
        const image_details = try self.checked(&.{ "docker", "image", "inspect", image, "--format", "{{.Id}} {{.Os}}/{{.Architecture}}" }, self.run_end, self.limits.command_ms);
        if (!std.mem.endsWith(u8, image_details, platform)) return error.WrongImagePlatform;
        self.image_id = image_details[0 .. std.mem.indexOfScalar(u8, image_details, ' ') orelse return error.InvalidImageIdentity];
        self.phase = "create";
        var password_bytes: [16]u8 = undefined;
        try self.io.randomSecure(&password_bytes);
        const password = std.fmt.bytesToHex(password_bytes, .lower);
        const label = try self.a.print("zig-postgres.owner={s}", .{self.nonce});
        _ = try self.checked(&.{ "docker", "volume", "create", "--label", label, self.volume }, self.run_end, self.limits.command_ms);
        _ = try self.checked(&.{ "docker", "create", "--name", self.name, "--label", label, "--publish", "127.0.0.1::5432", "--platform", platform, "--env", "POSTGRES_USER=postgres", "--env", try self.a.print("POSTGRES_PASSWORD={s}", .{password}), "--env", try self.a.print("POSTGRES_DB={s}", .{self.database}), "--env", if (self.control == .startup_failure) "POSTGRES_INITDB_ARGS=--invalid-owned-fixture" else "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256", "--mount", try self.a.print("type=volume,source={s},target=/var/lib/postgresql/data", .{self.volume}), image }, self.run_end, self.limits.command_ms);
        _ = try self.checked(&.{ "docker", "start", self.name }, self.run_end, self.limits.command_ms);
        self.phase = "startup";
        const startup_end = minimum(self.run_end, end(self.io, self.limits.startup_ms));
        while (true) {
            var ready = try self.command(&.{ "docker", "exec", self.name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres", "-d", self.database }, startup_end, @min(3000, self.limits.command_ms));
            const ok = ready.success();
            ready.deinit(self.a);
            if (ok) break;
            const running = try self.checked(&.{ "docker", "inspect", "--format", "{{.State.Running}}", self.name }, startup_end, self.limits.command_ms);
            if (std.mem.eql(u8, running, "false")) return error.DatabaseStartupFailed;
            try self.io.sleep(.fromMilliseconds(try remaining(self.io, startup_end, 20)), .awake);
        }
        const address = try self.checked(&.{ "docker", "port", self.name, "5432/tcp" }, startup_end, self.limits.command_ms);
        self.port = try std.fmt.parseInt(u16, address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidPort) + 1 ..], 10);
        const config: pg.PoolConfig = .{ .port = self.port, .user = "postgres", .password = &password, .database = self.database, .size = 1, .connect_timeout_ms = 3000 };
        {
            const c = try pg.PgClient.connectOpts(self.a, self.io, .{ .host = "127.0.0.1", .port = self.port, .user = "postgres", .password = &password, .database = self.database, .deadline = startup_end, .tls = .{ .mode = .disable } });
            defer c.close();
            var marked = try c.queryOpts(try self.a.print("COMMENT ON DATABASE {s} IS '{s}'", .{ self.database, self.marker }), .{ .deadline = startup_end });
            marked.deinit();
            var version = try c.queryOpts("SELECT version()", .{ .deadline = startup_end });
            defer version.deinit();
            self.server_version = try self.a.dupe(u8, try version.rows[0].getTyped([]const u8, 0));
        }
        if (comptime pg.tls_enabled) {
            self.phase = "certificates";
            _ = try self.checked(&.{ self.cert_tool, self.certs }, self.run_end, self.limits.command_ms);
        }
        if (self.control != .interrupt) try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = try self.a.print("{s}.started", .{self.report}), .data = self.name });
        if (self.control == .cleanup_failure) return;
        if (self.control == .interrupt) {
            self.phase = "interrupt-control";
            const client = try pg.PgClient.connectOpts(self.a, self.io, .{ .port = self.port, .user = "postgres", .password = &password, .database = self.database, .tls = .{ .mode = .disable }, .deadline = minimum(self.run_end, end(self.io, 3000)) });
            defer client.close();
            var transaction = try pg.Transaction.begin(client);
            defer transaction.deinit();
            try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = try self.a.print("{s}.started", .{self.report}), .data = self.name });
            var sleeping = try client.query("SELECT pg_sleep(60)");
            sleeping.deinit();
            return error.FaultDidNotFail;
        }
        const test_end = minimum(self.run_end, end(self.io, self.limits.test_ms));
        if (self.control == .hung_case) {
            self.phase = "hung-case";
            try bounded(self.io, minimum(test_end, end(self.io, self.limits.case_ms)), Io.sleep, .{ self.io, Io.Duration.fromSeconds(60), .awake });
            return error.FaultDidNotFail;
        }
        var driver_owner = std.heap.SafeAllocator.init(std.heap.page_allocator, .{});
        const result = self.driverCases(driver_owner.allocator(), config, test_end);
        if (driver_owner.deinitLog(false) != 0) return error.DriverAllocationLeak;
        try result;
    }
    fn driverCases(self: *State, a: A, config: pg.PoolConfig, test_end: Io.Timestamp) !void {
        try self.group("transactions", @import("verify.zig").transactionCases, .{ a, self.io, config, self.marker }, test_end);
        try self.group("protocol", @import("protocol_cases.zig").run, .{ a, self.io, config }, test_end);
        try self.group("parameters", @import("parameter_cases.zig").run, .{ a, self.io, config }, test_end);
        try self.group("network", @import("network_cases.zig").run, .{ a, self.io, config }, test_end);
        try self.group("streaming", @import("stream_cases.zig").run, .{ a, self.io, config }, test_end);
        try self.group("checked-rows", @import("live_cases.zig").rows, .{ a, self.io, config }, test_end);
        try self.group("common-helpers", @import("common_cases.zig").run, .{ a, self.io, config }, test_end);
        var env = try self.env.clone(self.a);
        defer env.deinit();
        try env.put("POSTGRES_TEST_TLS_CERTS", self.certs);
        try self.group("tls", @import("tls_cases.zig").run, .{ a, self.io, config, &env }, test_end);
        self.phase = "driver-memory";
        self.driver_heap = try valueWithin(self.io, minimum(test_end, end(self.io, self.limits.case_ms)), @import("live_cases.zig").measure, .{ a, self.io, config });
    }
    fn group(self: *State, name: []const u8, comptime function: anytype, args: anytype, test_end: Io.Timestamp) !void {
        self.phase = name;
        const result = try valueWithin(self.io, minimum(test_end, end(self.io, self.limits.case_ms)), function, args);
        const bytes = try std.json.Stringify.valueAlloc(self.a, .{ .name = name, .passed = true, .result = result }, .{});
        try self.groups.append(try std.json.parseFromSliceLeaky(std.json.Value, self.a, bytes, .{}));
    }
    fn remove(self: *State, kind: []const u8, name: []const u8, at: Io.Timestamp) !void {
        const args = if (std.mem.eql(u8, kind, "volume")) &[_][]const u8{ "docker", "volume", "inspect", "--format", "{{index .Labels \"zig-postgres.owner\"}}", name } else &[_][]const u8{ "docker", "inspect", "--format", "{{index .Config.Labels \"zig-postgres.owner\"}}", name };
        var inspection = try self.command(args, at, self.limits.command_ms);
        defer inspection.deinit(self.a);
        if (!inspection.success()) {
            if (std.mem.indexOf(u8, inspection.stderr, "No such") != null or std.mem.indexOf(u8, inspection.stderr, "no such") != null) return;
            return error.CleanupInspectionFailed;
        }
        if (!std.mem.eql(u8, std.mem.trim(u8, inspection.stdout, " \t\r\n"), self.nonce)) return error.UnownedResource;
        if (std.mem.eql(u8, kind, "volume")) _ = try self.checked(&.{ "docker", "volume", "rm", name }, at, self.limits.command_ms) else _ = try self.checked(&.{ "docker", "rm", "--force", "--volumes", name }, at, self.limits.command_ms);
    }
    fn cleanup(self: *State) !void {
        self.phase = "cleanup";
        const at = end(self.io, self.limits.cleanup_ms);
        if (self.control == .cleanup_failure) {
            _ = try self.checked(&.{ self.executable, "--hang-child" }, at, @min(150, self.limits.command_ms));
            return error.CleanupFailureNotInjected;
        }
        try self.remove("container", self.name, at);
        try self.remove("volume", self.volume, at);
        const owner_path = try self.a.print("{s}/owner", .{self.root});
        const owner = Io.Dir.cwd().readFileAlloc(self.io, owner_path, self.a, .limited(64)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (owner) |bytes| {
            if (!std.mem.eql(u8, bytes, self.nonce)) return error.UnownedDirectory;
            try Io.Dir.cwd().deleteTree(self.io, self.root);
        } else if (self.root_owned) try Io.Dir.cwd().deleteTree(self.io, self.root);
        Io.Dir.cwd().deleteFile(self.io, try self.a.print("{s}.started", .{self.report})) catch |err| if (err != error.FileNotFound) return err;
        self.cleanup_passed = true;
    }
    fn save(self: *State, failure: ?[]const u8, failed_phase: []const u8) !void {
        const revision = self.checked(&.{ "git", "rev-parse", "HEAD" }, end(self.io, 1000), 1000) catch "unavailable";
        // procfs reports size zero; use streaming reads instead of the regular
        // file-size optimization, which otherwise returns an empty measurement.
        const rss = blk: {
            const file = Io.Dir.cwd().openFile(self.io, "/proc/self/status", .{}) catch break :blk "";
            defer file.close(self.io);
            var buffer: [4096]u8 = undefined;
            var reader = file.readerStreaming(self.io, &buffer);
            break :blk reader.interface.allocRemaining(self.a, .limited(65536)) catch "";
        };
        var peak_rss_kib: ?usize = null;
        var lines = std.mem.splitScalar(u8, rss, '\n');
        while (lines.next()) |line| if (std.mem.startsWith(u8, line, "VmHWM:")) {
            var parts = std.mem.tokenizeAny(u8, line[6..], " \t");
            peak_rss_kib = std.fmt.parseInt(usize, parts.next() orelse "0", 10) catch null;
            break;
        };
        const report = try std.json.Stringify.valueAlloc(self.a, .{ .library_version = "0.3.0", .library_revision = revision, .compiler = @import("builtin").zig_version_string, .optimize = @tagName(@import("builtin").mode), .tls_enabled = pg.tls_enabled, .image_digest = image, .image_id = self.image_id, .platform = platform, .server_version = self.server_version, .deadlines = self.limits, .passed = failure == null and self.cleanup_passed, .failure = failure, .failed_phase = failed_phase, .control = self.control, .cases = self.groups.items, .driver_memory = self.driver_heap, .process_peak_rss_kib = peak_rss_kib, .resources = .{ .owner = self.nonce, .container = self.name, .volume = self.volume, .database = self.database, .directory = self.root }, .cleanup = .{ .passed = self.cleanup_passed, .failure = self.cleanup_error } }, .{ .whitespace = .indent_2 });
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.report, .data = report });
    }
};
fn executeMain(init: std.process.Init, cert_tool: []const u8, control: Control) !void {
    const a = init.arena.allocator();
    const report = init.environ_map.get("POSTGRES_LIVE_REPORT") orelse try a.print("zig-out/live-{s}-{s}.json", .{ @tagName(@import("builtin").mode), if (pg.tls_enabled) @as([]const u8, "tls") else "plain" });
    if (std.fs.path.dirname(report)) |parent| try Io.Dir.cwd().createDirPath(init.io, parent);
    var state = try State.make(init, cert_tool, report, control, try limitsFrom(init.environ_map));
    var cleanup_attempted = false;
    defer if (!cleanup_attempted) {
        const old = init.io.swapCancelProtection(.blocked);
        defer _ = init.io.swapCancelProtection(old);
        bounded(init.io, end(init.io, state.limits.cleanup_ms), State.cleanup, .{&state}) catch |err| {
            state.cleanup_error = @errorName(err);
        };
        state.save("RunnerPreparationFailed", state.phase) catch |err| std.debug.print("report failure {s}; owned resources {s}, {s}, {s}\n", .{ @errorName(err), state.name, state.volume, state.root });
    };
    const Done = union(enum) { work: anyerror!void, signal: anyerror!void, timeout: Io.Cancelable!void };
    var storage: [3]Done = undefined;
    var select = Io.Select(Done).init(init.io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.work, State.execute, .{&state});
    try select.concurrent(.signal, waitSignal, .{init.io});
    try select.concurrent(.timeout, Io.sleep, .{ init.io, Io.Duration.fromMilliseconds(state.limits.run_ms), .awake });
    const outcome: anyerror!void = switch (try select.await()) {
        .work => |result| result,
        .signal => error.Interrupted,
        .timeout => error.RunTimeout,
    };
    select.cancelDiscard();
    const failed_phase = state.phase;
    const protected = init.io.swapCancelProtection(.blocked);
    defer _ = init.io.swapCancelProtection(protected);
    cleanup_attempted = true;
    bounded(init.io, end(init.io, state.limits.cleanup_ms), State.cleanup, .{&state}) catch |err| {
        state.cleanup_error = @errorName(err);
    };
    const failure: ?[]const u8 = if (outcome) |_| null else |err| @errorName(err);
    try state.save(failure, failed_phase);
    if (!state.cleanup_passed) return error.LiveCleanupFailed;
    try outcome;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--hang-child")) {
        try init.io.sleep(.fromSeconds(60), .awake);
        return error.UnexpectedWake;
    }
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = signal }, .mask = std.mem.zeroes(std.posix.sigset_t), .flags = 0 };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
    if (args.len < 2 or args.len > 3) return error.ExpectedCertificateTool;
    if (args.len == 3 and std.mem.eql(u8, args[2], "--controls")) return controls(init, args[1]);
    const control: Control = if (args.len == 3) std.meta.stringToEnum(Control, args[2]) orelse return error.UnknownControl else .none;
    try executeMain(init, args[1], control);
}

fn controls(init: std.process.Init, cert_tool: []const u8) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var rows = std.json.Array.init(a);
    const exe = try std.process.executablePathAlloc(io, a);
    for ([_]Control{ .startup_failure, .stalled_command, .hung_case, .cleanup_failure, .interrupt, .interrupt, .outer_timeout }, 0..) |control, index| {
        var nonce_bytes: [6]u8 = undefined;
        io.random(&nonce_bytes);
        const nonce = try a.dupe(u8, &std.fmt.bytesToHex(nonce_bytes, .lower));
        const report = try a.print("/tmp/zig-postgres-control-{s}.json", .{nonce});
        const log = try a.print("/tmp/zig-postgres-control-{s}.log", .{nonce});
        var env = try init.environ_map.clone(a);
        defer env.deinit();
        try env.put("POSTGRES_LIVE_NONCE", nonce);
        try env.put("POSTGRES_LIVE_REPORT", report);
        inline for (.{ .{ "COMMAND_MS", "1500" }, .{ "CASE_MS", "100" }, .{ "STARTUP_MS", "15000" }, .{ "RUN_MS", "30000" }, .{ "CLEANUP_MS", "5000" } }) |pair| try env.put("POSTGRES_LIVE_" ++ pair[0], pair[1]);
        if (control == .stalled_command) try env.put("POSTGRES_LIVE_COMMAND_MS", "100");
        if (control == .outer_timeout) {
            try env.put("POSTGRES_LIVE_RUN_MS", "5000");
            try env.put("POSTGRES_LIVE_CASE_MS", "30000");
        }
        var owner_init = init;
        owner_init.environ_map = &env;
        var recovery = try State.make(owner_init, cert_tool, report, .none, .{});
        var recovered = false;
        defer if (!recovered) {
            const old = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(old);
            recovery.cleanup() catch {};
        };
        const file = try Io.Dir.cwd().createFile(io, log, .{});
        defer file.close(io);
        var child = try process.Child.spawn(init.gpa, io, .{ .argv = &.{ exe, cert_tool, @tagName(control) }, .environ_map = &env, .stdout = .{ .file = file }, .stderr = .{ .file = file } });
        defer child.deinit();
        var joined = false;
        defer if (!joined) {
            _ = child.stop(100) catch {};
        };
        const begin = Io.Timestamp.now(io, .awake);
        if (control == .interrupt) {
            const until = end(io, 20000);
            while (true) {
                const f = Io.Dir.cwd().openFile(io, try a.print("{s}.started", .{report}), .{}) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => return err,
                };
                if (f) |ready| {
                    ready.close(io);
                    break;
                }
                if (try child.poll() != null) return error.ControlExitedBeforeInterrupt;
                try io.sleep(.fromMilliseconds(try remaining(io, until, 10)), .awake);
            }
            try child.signal(if (index == 4) .INT else .TERM);
        }
        const term = try child.wait(40000);
        joined = true;
        if (term.success()) return error.ControlUnexpectedSuccess;
        const raw = try Io.Dir.cwd().readFileAlloc(io, report, a, .limited(1024 * 1024));
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
        if (parsed.object.get("passed").?.bool) return error.ControlFalseSuccess;
        const cleanup_ok = parsed.object.get("cleanup").?.object.get("passed").?.bool;
        if (control == .cleanup_failure) {
            if (cleanup_ok) return error.CleanupFaultNotDetected;
        } else if (!cleanup_ok) return error.ControlCleanupFailed;
        try bounded(io, end(io, 30000), State.cleanup, .{&recovery});
        recovered = true;
        if (control == .interrupt and !std.mem.eql(u8, parsed.object.get("failure").?.string, "Interrupted")) return error.InterruptNotObserved;
        if (control == .outer_timeout and !std.mem.eql(u8, parsed.object.get("failure").?.string, "RunTimeout")) return error.OuterDeadlineNotObserved;
        if (begin.untilNow(io, .awake).toMilliseconds() > 40000) return error.ControlUnbounded;
        try rows.append(try std.json.parseFromSliceLeaky(std.json.Value, a, try std.json.Stringify.valueAlloc(a, .{ .control = control, .signal = if (control == .interrupt) @as(u8, if (index == 4) 2 else 15) else 0, .bounded_failure = true, .recovered = true, .elapsed_ms = begin.untilNow(io, .awake).toMilliseconds(), .report = parsed }, .{}), .{}));
        try Io.Dir.cwd().deleteFile(io, report);
        try Io.Dir.cwd().deleteFile(io, log);
    }
    const report = init.environ_map.get("POSTGRES_LIVE_REPORT") orelse "zig-out/live-controls.json";
    if (std.fs.path.dirname(report)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = report, .data = try std.json.Stringify.valueAlloc(a, .{ .passed = true, .cases = rows.items }, .{ .whitespace = .indent_2 }) });
}
