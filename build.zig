const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const postgres = b.addModule("postgres", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
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
}
