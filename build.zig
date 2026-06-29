const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const native_target = b.resolveTargetQuery(.{});

    const optimize = b.standardOptimizeOption(.{});

    const elfy = b.dependency("elfy", .{}).module("elfy");
    const ucl = b.dependency("ucl", .{}).module("ucl");

    const generate_decompressors = b.addExecutable(.{
        .name = "gendecomp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gendecomp.zig"),
            .imports = &.{.{ .name = "elfy", .module = elfy }},
            .target = native_target,
            .optimize = .Debug,
        }),
    });
    const run_generate_decompressors = b.addRunArtifact(generate_decompressors);
    run_generate_decompressors.has_side_effects = false;
    const arch_src = run_generate_decompressors.addOutputFileArg("decompress.zig");

    const Arch = struct {
        name: []const u8,
        cpu_arch: std.Target.Cpu.Arch,
    };
    const archs: []const Arch = &.{
        .{ .name = "x86", .cpu_arch = .x86 },
        .{ .name = "aarch64", .cpu_arch = .aarch64 },
    };
    for (archs) |arch| {
        const arch_decompress = b.addObject(.{
            .name = b.fmt("{s}_decompress", .{arch.name}),
            .root_module = b.createModule(.{
                .target = b.resolveTargetQuery(.{ .cpu_arch = arch.cpu_arch }),
                .strip = true,
            }),
        });
        arch_decompress.root_module.addCSourceFile(.{
            .file = b.path(b.fmt("src/arch/{s}/decompress.S", .{arch.name})),
            .language = .assembly_with_preprocessor,
        });
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            arch_decompress.getEmittedBin(),
            b.fmt("{s}_decompress.o", .{@tagName(arch.cpu_arch)}),
        ).step);

        run_generate_decompressors.addFileArg(arch_decompress.getEmittedBin());
    }

    const arch = b.createModule(.{
        .root_source_file = arch_src,
        .imports = &.{
            .{ .name = "elfy", .module = elfy },
        },
    });

    const mod = b.addModule("packer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,

        .imports = &.{
            .{ .name = "arch", .module = arch },
            .{ .name = "elfy", .module = elfy },
            .{ .name = "ucl", .module = ucl },
        },
    });

    const exe = b.addExecutable(.{
        .name = "packer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,

            .imports = &.{.{ .name = "packer", .module = mod }},
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const testing = b.addObject(.{
        .name = "testing",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64 }),
            .optimize = .ReleaseSmall,
        }),
    });
    b.getInstallStep().dependOn(&b.addInstallBinFile(
        testing.getEmittedBin(),
        "test.o",
    ).step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(
        testing.getEmittedLlvmIr(),
        "test.ll",
    ).step);
}
