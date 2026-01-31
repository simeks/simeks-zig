const std = @import("std");
const simeks = @import("simeks");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const simeks_dep = b.dependency("simeks", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    simeks.linkSystemLibraries(exe);

    exe.root_module.addImport("score", simeks_dep.module("core"));
    exe.root_module.addImport("smath", simeks_dep.module("math"));
    exe.root_module.addImport("sgpu", simeks_dep.module("gpu"));
    exe.root_module.addImport("sgui", simeks_dep.module("gui"));
    exe.root_module.addImport("sos", simeks_dep.module("os"));

    b.installArtifact(exe);

    const rt_exe = b.addExecutable(.{
        .name = "raytrace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/raytracing.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    simeks.linkSystemLibraries(rt_exe);
    rt_exe.root_module.addImport("score", simeks_dep.module("core"));
    rt_exe.root_module.addImport("smath", simeks_dep.module("math"));
    rt_exe.root_module.addImport("sgpu", simeks_dep.module("gpu"));
    rt_exe.root_module.addImport("sos", simeks_dep.module("os"));

    b.installArtifact(rt_exe);

    const shader_step = b.step("shaders", "Build shaders");
    const shaders = .{
        "gui.vert",
        "gui.frag",
        "blit.vert",
        "blit.frag",
        "rt.rgen",
        "rt.rmiss",
        "rt_shadow.rmiss",
        "rt.rchit",
    };
    inline for (shaders) |shader| {
        const step = buildShader(b, b.path("src/shaders/" ++ shader), shader ++ ".spv");
        shader_step.dependOn(step);
    }
    b.getInstallStep().dependOn(shader_step);

    const run_rt_cmd = b.addRunArtifact(rt_exe);
    run_rt_cmd.step.dependOn(b.getInstallStep());
    const run_rt_step = b.step("run-rt", "Run the ray tracing example");
    run_rt_step.dependOn(&run_rt_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}

fn buildShader(
    b: *std.Build,
    glsl_path: std.Build.LazyPath,
    install_name: []const u8,
) *std.Build.Step {
    const cmd = b.addSystemCommand(&.{
        "glslc",
        "-fentry-point=main",
        "--target-env=vulkan1.2",
        "-o",
    });
    const spv = cmd.addOutputFileArg("shader.spv");
    cmd.addFileArg(glsl_path);

    const install = b.addInstallBinFile(spv, install_name);
    return &install.step;
}
