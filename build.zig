const std = @import("std");

const executables = [_]struct { name: []const u8, root: []const u8 }{
    .{ .name = "zcube", .root = "src/zcube.zig" },
    .{ .name = "zcube-server", .root = "src/zcube_server.zig" },
    .{ .name = "zcube-agent", .root = "src/zcube_agent.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The version has one source of truth, build.zig.zon, handed to the code as an option.
    const manifest = @import("build.zig.zon");
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    for (executables) |executable| {
        const exe = b.addExecutable(.{
            .name = executable.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(executable.root),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
            }),
        });
        b.installArtifact(exe);
    }

    const test_step = b.step("test", "Run unit and snapshot tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
