const stable_protos: []const []const u8 = &.{
    "nrmpb/cs_proto/head.proto",
};

pub fn build(b: *Build) void {
    const nrmio = b.createModule(.{ .root_source_file = b.path("nrmio/src/root.zig") });
    const nrmcli = b.createModule(.{ .root_source_file = b.path("nrmcli/src/root.zig") });
    const nrmcrypt = b.createModule(.{ .root_source_file = b.path("nrmcrypt/src/root.zig") });

    const nrmpb = b.createModule(.{ .root_source_file = b.path("nrmpb/src/root.zig") });

    const host = b.graph.host;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const io = b.graph.io;
    const cwd: Io.Dir = .cwd();

    const nrmprotoc = b.addExecutable(.{
        .name = "nrmprotoc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("nrmpb/compiler/main.zig"),
            .target = host,
            .optimize = optimize,
            .single_threaded = true,
        }),
    });

    const compile_main_structs = b.addUpdateSourceFiles();
    const compile_main_descriptors = b.addUpdateSourceFiles();
    const compile_stable_definitions = b.addUpdateSourceFiles();

    if (cwd.access(io, "nrmpb/cs_proto/main.proto", .{ .read = true })) {
        const nrmprotoc_descs_pass = b.addRunArtifact(nrmprotoc);
        nrmprotoc_descs_pass.expectExitCode(0);
        nrmprotoc_descs_pass.addArg("-descriptors");
        nrmprotoc_descs_pass.addFileArg(b.path("nrmpb/cs_proto/main.proto"));

        compile_main_descriptors.addCopyFileToSource(
            nrmprotoc_descs_pass.captureStdOut(.{ .basename = "pb.main.desc.zig" }),
            "nrmpb/src/pb.main.desc.zig",
        );

        const nrmprotoc_structs_pass = b.addRunArtifact(nrmprotoc);
        nrmprotoc_structs_pass.expectExitCode(0);
        nrmprotoc_structs_pass.addArg("-structures");
        nrmprotoc_structs_pass.addFileArg(b.path("nrmpb/cs_proto/main.proto"));

        compile_main_structs.addCopyFileToSource(
            nrmprotoc_structs_pass.captureStdOut(.{ .basename = "pb.main.zig" }),
            "nrmpb/src/pb.main.zig",
        );
    } else |_| {}

    if (filesReadable(io, cwd, stable_protos)) {
        const nrmprotoc_stable_pass = b.addRunArtifact(nrmprotoc);
        nrmprotoc_stable_pass.expectExitCode(0);
        nrmprotoc_stable_pass.addArg("-full");

        for (stable_protos) |sub_path|
            nrmprotoc_stable_pass.addFileArg(b.path(sub_path));

        compile_stable_definitions.addCopyFileToSource(
            nrmprotoc_stable_pass.captureStdOut(.{ .basename = "pb.stable.zig" }),
            "nrmpb/src/pb.stable.zig",
        );
    }

    const dpsv = b.addExecutable(.{
        .name = "hollowell-dpsv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dpsv/src/main.zig"),
            .imports = &.{
                .{ .name = "nrmio", .module = nrmio },
                .{ .name = "nrmcli", .module = nrmcli },
                .{ .name = "nrmcrypt", .module = nrmcrypt },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    dpsv.root_module.addAnonymousImport("config", .{
        .root_source_file = b.path("dpsv/config.zon"),
    });

    const gamesv = b.addExecutable(.{
        .name = "hollowell-gamesv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("gamesv/src/main.zig"),
            .imports = &.{
                .{ .name = "nrmio", .module = nrmio },
                .{ .name = "nrmcli", .module = nrmcli },
                .{ .name = "nrmcrypt", .module = nrmcrypt },
                .{ .name = "nrmpb", .module = nrmpb },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    gamesv.step.dependOn(&compile_main_descriptors.step);
    gamesv.step.dependOn(&compile_stable_definitions.step);

    gamesv.root_module.addAnonymousImport("config", .{
        .root_source_file = b.path("gamesv/config.zon"),
    });

    gamesv.root_module.addAnonymousImport("initial_xorpad", .{
        .root_source_file = b.path("gamesv/initial_xorpad.bytes"),
    });

    b.step(
        "pb",
        "run a struct generation pass on `main.proto`",
    ).dependOn(&compile_main_structs.step);

    const serve_dp = b.addRunArtifact(dpsv);
    const serve_game = b.addRunArtifact(gamesv);
    if (b.args) |args| {
        serve_dp.addArgs(args);
        serve_game.addArgs(args);
    }

    b.step(
        "serve-dp",
        "start the dispatch server",
    ).dependOn(&serve_dp.step);

    b.step(
        "serve-game",
        "start the game server",
    ).dependOn(&serve_game.step);

    b.installArtifact(dpsv);
    b.installArtifact(gamesv);
}

fn filesReadable(io: Io, dir: Io.Dir, path_list: []const []const u8) bool {
    for (path_list) |sub_path|
        dir.access(io, sub_path, .{ .read = true }) catch return false;

    return true;
}

const Io = std.Io;
const Build = std.Build;

const std = @import("std");
