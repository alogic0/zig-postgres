const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tls_enabled = b.option(bool, "tls", "Enable verified PostgreSQL TLS through system OpenSSL3") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "tls", tls_enabled);
    const postgres = b.addModule("postgres", .{
        .root_source_file = b.path("src/root.zig"),
        .link_libc = tls_enabled,
        .target = target,
        .optimize = optimize,
    });
    postgres.addOptions("postgres_options", options);
    const tls_fixture = b.addModule("tls_fixture", .{ .root_source_file = b.path("examples/tls_fixture.zig"), .target = target, .optimize = optimize, .link_libc = tls_enabled, .imports = &.{.{ .name = "postgres", .module = postgres }} });
    const tests = b.addTest(.{ .root_module = postgres });
    b.step("test", "Run offline PostgreSQL declaration and SCRAM tests").dependOn(&b.addRunArtifact(tests).step);

    const probe = b.addExecutable(.{
        .name = "postgres-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "postgres", .module = postgres }},
        }),
    });
    b.installArtifact(probe);
    const check = b.step("check", "Compile the public consumer and offline tests");
    check.dependOn(&probe.step);
    check.dependOn(&tests.step);

    _ = b.addModule("measurement_support", .{ .root_source_file = b.path("examples/heap_tracker.zig"), .target = target, .optimize = optimize });
    const measure = b.addExecutable(.{ .name = "postgres-measure", .root_module = b.createModule(.{ .root_source_file = b.path("examples/measure.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "postgres", .module = postgres }} }) });
    b.step("build-measure", "Compile the frozen opt-in export-page heap comparison").dependOn(&b.addInstallArtifact(measure, .{}).step);
    check.dependOn(&measure.step);
    const certs = b.addExecutable(.{ .name = "postgres-tls-certs", .root_module = b.createModule(.{ .root_source_file = b.path("examples/tls_certs.zig"), .target = target, .optimize = optimize }) });
    b.step("build-tls-certs", "Compile the owned local TLS certificate adapter").dependOn(&b.addInstallArtifact(certs, .{}).step);
    const wire = b.addExecutable(.{ .name = "postgres-wire-check", .root_module = b.createModule(.{ .root_source_file = b.path("examples/wire_check.zig"), .target = target, .optimize = optimize }) });
    b.step("build-wire-check", "Compile the independent opt-in wire receipt checker").dependOn(&b.addInstallArtifact(wire, .{}).step);
    const live = b.addExecutable(.{
        .name = "postgres-verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/verify.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "postgres", .module = postgres }},
        }),
    });
    live.root_module.addImport("tls_fixture", tls_fixture);
    b.step("build-live", "Compile the opt-in disposable PostgreSQL verifier").dependOn(&b.addInstallArtifact(live, .{}).step);
    // The CI entrypoint always checks both supported profiles and TLS settings.
    // These compile the opt-in network fixtures but never execute them.
    const ci = b.step("ci", "Offline format/public/live-consumer/test matrix: Debug/Safe, plaintext/TLS");
    const format = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "src", "examples" });
    format.setCwd(b.path("."));
    ci.dependOn(&format.step);
    inline for ([_]@TypeOf(optimize){ .debug, .safe }) |mode| {
        inline for (.{ false, true }) |with_tls| {
            const suffix = @tagName(mode) ++ (if (with_tls) "-tls" else "-plain");
            const matrix_options = b.addOptions();
            matrix_options.addOption(bool, "tls", with_tls);
            const matrix = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .link_libc = with_tls, .target = target, .optimize = mode });
            matrix.addOptions("postgres_options", matrix_options);
            const matrix_tests = b.addTest(.{ .name = "postgres-test-" ++ suffix, .root_module = matrix });
            ci.dependOn(&b.addRunArtifact(matrix_tests).step);
            const matrix_probe = b.addExecutable(.{ .name = "postgres-probe-" ++ suffix, .root_module = b.createModule(.{ .root_source_file = b.path("examples/probe.zig"), .target = target, .optimize = mode, .imports = &.{.{ .name = "postgres", .module = matrix }} }) });
            ci.dependOn(&matrix_probe.step);
            const matrix_fixture = b.createModule(.{ .root_source_file = b.path("examples/tls_fixture.zig"), .target = target, .optimize = mode, .link_libc = with_tls, .imports = &.{.{ .name = "postgres", .module = matrix }} });
            const matrix_live = b.addExecutable(.{ .name = "postgres-verify-" ++ suffix, .root_module = b.createModule(.{ .root_source_file = b.path("examples/verify.zig"), .target = target, .optimize = mode, .imports = &.{ .{ .name = "postgres", .module = matrix }, .{ .name = "tls_fixture", .module = matrix_fixture } } }) });
            ci.dependOn(&matrix_live.step);
            const matrix_measure = b.addExecutable(.{ .name = "postgres-measure-" ++ suffix, .root_module = b.createModule(.{ .root_source_file = b.path("examples/measure.zig"), .target = target, .optimize = mode, .imports = &.{.{ .name = "postgres", .module = matrix }} }) });
            ci.dependOn(&matrix_measure.step);
        }
        const wire_ci = b.addExecutable(.{ .name = "postgres-wire-check-" ++ @tagName(mode), .root_module = b.createModule(.{ .root_source_file = b.path("examples/wire_check.zig"), .target = target, .optimize = mode }) });
        const cert_ci = b.addExecutable(.{ .name = "postgres-tls-certs-" ++ @tagName(mode), .root_module = b.createModule(.{ .root_source_file = b.path("examples/tls_certs.zig"), .target = target, .optimize = mode }) });
        ci.dependOn(&wire_ci.step);
        ci.dependOn(&cert_ci.step);
    }
}
