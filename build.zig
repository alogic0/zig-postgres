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
}
