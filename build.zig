const std = @import("std");

const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const vk_headers_dep = b.dependency("vulkan_headers", .{});
    const vkzig_dep = b.dependency("vulkan", .{
        .target = target,
        .optimize = optimize,
    });
    const vma_dep = b.dependency("zig_vma", .{
        .target = target,
        .optimize = optimize,
    });

    // Generate vk.zig
    const vk_gen = vkzig_dep.artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(
        vk_headers_dep.path("registry/vk.xml"),
    );
    const vk_out = vk_generate_cmd.addOutputFileArg("vk.zig");
    const vk_mod = b.createModule(.{
        .root_source_file = vk_out,
        .target = target,
        .optimize = optimize,
    });

    // Generate wayland module
    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_seat", 1);
    scanner.generate("xdg_wm_base", 1);

    const wayland_mod = b.createModule(.{
        .root_source_file = scanner.result,
    });

    // Library modules
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const math_mod = b.addModule("math", .{
        .root_source_file = b.path("src/math/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gui_mod = b.addModule("gui", .{
        .root_source_file = b.path("src/gui/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("math", math_mod);

    const gpu_mod = b.addModule("gpu", .{
        .root_source_file = b.path("src/gpu/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_mod.addImport("core", core_mod);
    gpu_mod.addImport("math", math_mod);
    gpu_mod.addImport("gui", gui_mod);
    gpu_mod.addImport("vulkan", vk_mod);
    gpu_mod.addImport("vma", vma_dep.module("vma"));

    const os_mod = b.addModule("os", .{
        .root_source_file = b.path("src/os/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    os_mod.addImport("wayland", wayland_mod);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const ModuleEntry = struct {
        test_name: []const u8,
        module: *std.Build.Module,
    };

    const test_modules = [_]ModuleEntry{
        .{ .test_name = "test_core", .module = core_mod },
        .{ .test_name = "test_math", .module = math_mod },
        .{ .test_name = "test_gpu", .module = gpu_mod },
        .{ .test_name = "test_gui", .module = gui_mod },
        // TODO: Add OS
    };

    inline for (test_modules) |mod| {
        const test_exe = b.addTest(.{
            .name = mod.test_name,
            .root_module = mod.module,
        });

        b.installArtifact(test_exe);

        const run_test = b.addRunArtifact(test_exe);
        run_test.step.dependOn(b.getInstallStep());
        test_step.dependOn(&run_test.step);
    }
}

pub fn linkSystemLibraries(exe: *std.Build.Step.Compile) void {
    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("vulkan");
    exe.linkSystemLibrary("xkbcommon");
}
