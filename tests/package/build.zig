const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tls = b.option(bool, "tls", "Enable verified TLS") orelse false;
    const postgres = b.dependency("postgres", .{
        .target = target,
        .optimize = optimize,
        .tls = tls,
    });
    const exe = b.addExecutable(.{
        .name = "postgres-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "postgres", .module = postgres.module("postgres") }},
        }),
    });
    b.installArtifact(exe);
}
