const std = @import("std");
const sg = @import("sgpu");
const so = @import("sos");
const vk = sg.vk;

const Allocator = std.mem.Allocator;
const Gpu = sg.Gpu;
const Window = so.Window;

const Vertex = extern struct {
    position: [3]f32,
    _padding: f32 = 0, // GLSL std430 vec3[] has 16-byte stride
};

const RayPushConstants = extern struct {
    output_image: u32,
    accel_index: u32,
    vertex_address: u64,
    index_address: u64,
    time: f32,
    _pad: [3]f32 = .{ 0, 0, 0 },
};

// Helper to create a cube at a position with a scale
fn makeCube(comptime cx: f32, comptime cy: f32, comptime cz: f32, comptime s: f32) [24]Vertex {
    return .{
        // Front face
        .{ .position = .{ cx - s, cy - s, cz + s } },
        .{ .position = .{ cx + s, cy - s, cz + s } },
        .{ .position = .{ cx + s, cy + s, cz + s } },
        .{ .position = .{ cx - s, cy + s, cz + s } },
        // Back face
        .{ .position = .{ cx - s, cy - s, cz - s } },
        .{ .position = .{ cx - s, cy + s, cz - s } },
        .{ .position = .{ cx + s, cy + s, cz - s } },
        .{ .position = .{ cx + s, cy - s, cz - s } },
        // Top face
        .{ .position = .{ cx - s, cy + s, cz - s } },
        .{ .position = .{ cx - s, cy + s, cz + s } },
        .{ .position = .{ cx + s, cy + s, cz + s } },
        .{ .position = .{ cx + s, cy + s, cz - s } },
        // Bottom face
        .{ .position = .{ cx - s, cy - s, cz - s } },
        .{ .position = .{ cx + s, cy - s, cz - s } },
        .{ .position = .{ cx + s, cy - s, cz + s } },
        .{ .position = .{ cx - s, cy - s, cz + s } },
        // Right face
        .{ .position = .{ cx + s, cy - s, cz - s } },
        .{ .position = .{ cx + s, cy + s, cz - s } },
        .{ .position = .{ cx + s, cy + s, cz + s } },
        .{ .position = .{ cx + s, cy - s, cz + s } },
        // Left face
        .{ .position = .{ cx - s, cy - s, cz - s } },
        .{ .position = .{ cx - s, cy - s, cz + s } },
        .{ .position = .{ cx - s, cy + s, cz + s } },
        .{ .position = .{ cx - s, cy + s, cz - s } },
    };
}

const cube_indices_template = [_]u32{
    0, 1, 2, 0, 2, 3, // front
    4, 5, 6, 4, 6, 7, // back
    8, 9, 10, 8, 10, 11, // top
    12, 13, 14, 12, 14, 15, // bottom
    16, 17, 18, 16, 18, 19, // right
    20, 21, 22, 20, 22, 23, // left
};

// Ground plane at y = -2
const ground_vertices = [_]Vertex{
    .{ .position = .{ -15, -2, -15 } },
    .{ .position = .{ 15, -2, -15 } },
    .{ .position = .{ 15, -2, 15 } },
    .{ .position = .{ -15, -2, 15 } },
};

const ground_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

// Three cubes at different positions
const cube1 = makeCube(-3.0, 0.0, 2.0, 0.8); // Red metallic
const cube2 = makeCube(0.0, 0.3, 0.0, 1.0); // Blue reflective
const cube3 = makeCube(3.0, -0.5, -1.5, 0.6); // Green

// Combined scene vertices
const scene_vertices = ground_vertices ++ cube1 ++ cube2 ++ cube3;

// Combined indices with proper offsets
const scene_indices = blk: {
    const num_cube_indices = cube_indices_template.len;
    var indices: [ground_indices.len + num_cube_indices * 3]u32 = undefined;

    // Ground
    for (ground_indices, 0..) |idx, i| {
        indices[i] = idx;
    }

    // Cubes with offset
    const base = ground_indices.len;
    const cube_verts = 24;
    for (0..3) |c| {
        const idx_offset = base + c * num_cube_indices;
        const vert_offset = ground_vertices.len + c * cube_verts;
        for (cube_indices_template, 0..) |idx, i| {
            indices[idx_offset + i] = idx + vert_offset;
        }
    }
    break :blk indices;
};

const num_instances = 1; // Single instance with all geometry

const BlitPushConstants = extern struct {
    texture_index: u32,
    sampler_index: u32,
};

const RayState = struct {
    raygen_shader: sg.Shader,
    miss_shader: sg.Shader,
    shadow_miss_shader: sg.Shader,
    hit_shader: sg.Shader,
    rt_pipeline: sg.RayTracingPipeline,

    blit_vs: sg.Shader,
    blit_fs: sg.Shader,
    blit_pipeline: sg.RenderPipeline,

    vertex_buffer: sg.Buffer,
    index_buffer: sg.Buffer,
    instance_buffer: sg.Buffer,
    scratch_buffer: sg.Buffer,
    sbt_buffer: sg.Buffer,

    blas: sg.AccelerationStructure,
    tlas: sg.AccelerationStructure,
    sbt: sg.ShaderBindingTable,

    output_texture: sg.Texture,
    output_view: sg.TextureView,
    sampler: sg.Sampler,
    output_size: sg.Extent2D,
    output_initialized: bool = false,
    accel_built: bool = false,
    time: f32 = 0,
    timer: std.time.Timer,

    pub fn init(gpu: *Gpu, arena: Allocator) !RayState {
        const raygen_shader = try loadShader(arena, gpu, "rt.rgen.spv");
        errdefer gpu.releaseShader(raygen_shader);
        const miss_shader = try loadShader(arena, gpu, "rt.rmiss.spv");
        errdefer gpu.releaseShader(miss_shader);
        const shadow_miss_shader = try loadShader(arena, gpu, "rt_shadow.rmiss.spv");
        errdefer gpu.releaseShader(shadow_miss_shader);
        const hit_shader = try loadShader(arena, gpu, "rt.rchit.spv");
        errdefer gpu.releaseShader(hit_shader);

        const rt_pipeline = try gpu.createRayTracingPipeline(&.{
            .label = "rt_pipeline",
            .shaders = &.{
                .{ .stage = .raygen, .shader = raygen_shader },
                .{ .stage = .miss, .shader = miss_shader },
                .{ .stage = .miss, .shader = shadow_miss_shader },
                .{ .stage = .closest_hit, .shader = hit_shader },
            },
            .groups = &.{
                .{ .type = .general, .general = 0 }, // raygen
                .{ .type = .general, .general = 1 }, // miss
                .{ .type = .general, .general = 2 }, // shadow miss
                .{ .type = .triangles_hit, .closest_hit = 3 }, // hit
            },
            .payload_size = 16,
            .push_constant_size = @sizeOf(RayPushConstants),
        });
        errdefer gpu.releaseRayTracingPipeline(rt_pipeline);

        const blit_vs = try loadShader(arena, gpu, "blit.vert.spv");
        errdefer gpu.releaseShader(blit_vs);
        const blit_fs = try loadShader(arena, gpu, "blit.frag.spv");
        errdefer gpu.releaseShader(blit_fs);

        const blit_pipeline = try gpu.createRenderPipeline(&.{
            .label = "rt_blit",
            .vertex_shader = blit_vs,
            .fragment_shader = blit_fs,
            .color_attachments = .init(&.{
                .{ .format = gpu.surfaceFormat() },
            }),
            .push_constant_size = @sizeOf(BlitPushConstants),
        });
        errdefer gpu.releaseRenderPipeline(blit_pipeline);

        const vertex_buffer = try gpu.createBuffer(&.{
            .label = "rt_vertices",
            .size = @sizeOf(@TypeOf(scene_vertices)),
            .usage = .{ .vertex_buffer = true, .storage = true, .acceleration_structure_build_input = true },
            .memory = .cpu_write,
        });
        errdefer gpu.releaseBuffer(vertex_buffer);
        std.mem.copyForwards(u8, gpu.mappedData(vertex_buffer), std.mem.asBytes(&scene_vertices));

        const index_buffer = try gpu.createBuffer(&.{
            .label = "rt_indices",
            .size = @sizeOf(@TypeOf(scene_indices)),
            .usage = .{ .index_buffer = true, .storage = true, .acceleration_structure_build_input = true },
            .memory = .cpu_write,
        });
        errdefer gpu.releaseBuffer(index_buffer);
        std.mem.copyForwards(u8, gpu.mappedData(index_buffer), std.mem.asBytes(&scene_indices));

        var blas_geometry = [_]sg.AccelerationStructureGeometry{.{ .triangles = .{
            .vertex_buffer = vertex_buffer,
            .vertex_stride = @sizeOf(Vertex),
            .index_buffer = index_buffer,
        } }};
        const num_triangles = scene_indices.len / 3;
        var blas_ranges = [_]sg.AccelerationStructureBuildRange{.{ .primitive_count = num_triangles }};
        const blas_build_desc = sg.AccelerationStructureBuildDesc{
            .type = .bottom_level,
            .geometries = &blas_geometry,
            .ranges = &blas_ranges,
        };

        const blas_sizes = try gpu.getAccelerationStructureBuildSizes(&blas_build_desc);
        const blas = try gpu.createAccelerationStructure(&.{
            .label = "triangle_blas",
            .size = blas_sizes.acceleration_size,
            .type = .bottom_level,
        });
        errdefer gpu.releaseAccelerationStructure(blas);

        const instance_buffer = try gpu.createBuffer(&.{
            .label = "rt_instances",
            .size = 64 * num_instances,
            .usage = .{ .storage = true, .acceleration_structure_build_input = true },
            .memory = .cpu_write,
        });
        errdefer gpu.releaseBuffer(instance_buffer);

        const blas_addr = @intFromEnum(gpu.accelerationStructureDeviceAddress(blas));
        const instance_data = gpu.mappedData(instance_buffer);

        // Single instance with identity transform - geometry positions are baked in
        writeInstanceWithTransform(instance_data[0..64], blas_addr, .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
        }, 0);

        var tlas_geometry = [_]sg.AccelerationStructureGeometry{.{ .instances = .{
            .buffer = instance_buffer,
            .stride = 64,
        } }};
        var tlas_ranges = [_]sg.AccelerationStructureBuildRange{.{ .primitive_count = num_instances }};
        const tlas_build_desc = sg.AccelerationStructureBuildDesc{
            .type = .top_level,
            .geometries = &tlas_geometry,
            .ranges = &tlas_ranges,
        };

        const tlas_sizes = try gpu.getAccelerationStructureBuildSizes(&tlas_build_desc);
        const tlas = try gpu.createAccelerationStructure(&.{
            .label = "scene_tlas",
            .size = tlas_sizes.acceleration_size,
            .type = .top_level,
        });
        errdefer gpu.releaseAccelerationStructure(tlas);

        const scratch_size = @max(blas_sizes.build_scratch_size, tlas_sizes.build_scratch_size);
        const scratch_buffer = try gpu.createBuffer(&.{
            .label = "rt_scratch",
            .size = scratch_size,
            .usage = .{ .storage = true },
            .memory = .gpu_only,
        });
        errdefer gpu.releaseBuffer(scratch_buffer);

        const sbt_build = try createShaderBindingTable(gpu, arena, rt_pipeline);
        errdefer gpu.releaseBuffer(sbt_build.buffer);
        const sbt_layout = sbt_build.layout;
        const sbt_buffer = sbt_build.buffer;
        const sbt = try gpu.createShaderBindingTable(&.{
            .label = "rt_sbt",
            .pipeline = rt_pipeline,
            .buffer = sbt_buffer,
            .raygen = .{ .offset = sbt_layout.raygen, .stride = sbt_layout.stride, .count = 1 },
            .miss = .{ .offset = sbt_layout.miss, .stride = sbt_layout.stride, .count = sbt_layout.miss_count },
            .hit = .{ .offset = sbt_layout.hit, .stride = sbt_layout.stride, .count = 1 },
        });
        errdefer gpu.releaseShaderBindingTable(sbt);

        const sampler = try gpu.createSampler(&.{});
        errdefer gpu.releaseSampler(sampler);

        const output_size = gpu.frameSize();
        const output_texture = try gpu.createTexture(&.{
            .label = "rt_output",
            .type = .d2,
            .usage = .{ .sampled = true, .storage = true },
            .size = .{ .width = output_size.width, .height = output_size.height },
            .format = .rgba8_unorm,
        });
        errdefer gpu.releaseTexture(output_texture);
        const output_view = try gpu.createTextureView(output_texture, &.{ .type = .d2 });
        errdefer gpu.releaseTextureView(output_view);

        const state = RayState{
            .raygen_shader = raygen_shader,
            .miss_shader = miss_shader,
            .shadow_miss_shader = shadow_miss_shader,
            .hit_shader = hit_shader,
            .rt_pipeline = rt_pipeline,
            .blit_vs = blit_vs,
            .blit_fs = blit_fs,
            .blit_pipeline = blit_pipeline,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .instance_buffer = instance_buffer,
            .scratch_buffer = scratch_buffer,
            .sbt_buffer = sbt_buffer,
            .blas = blas,
            .tlas = tlas,
            .sbt = sbt,
            .output_texture = output_texture,
            .output_view = output_view,
            .sampler = sampler,
            .output_size = output_size,
            .output_initialized = false,
            .accel_built = false,
            .time = 0,
            .timer = std.time.Timer.start() catch unreachable,
        };

        return state;
    }

    pub fn deinit(self: *RayState, gpu: *Gpu) void {
        gpu.releaseTextureView(self.output_view);
        gpu.releaseTexture(self.output_texture);
        gpu.releaseSampler(self.sampler);
        gpu.releaseShaderBindingTable(self.sbt);
        gpu.releaseBuffer(self.sbt_buffer);
        gpu.releaseBuffer(self.scratch_buffer);
        gpu.releaseAccelerationStructure(self.tlas);
        gpu.releaseAccelerationStructure(self.blas);
        gpu.releaseBuffer(self.instance_buffer);
        gpu.releaseBuffer(self.index_buffer);
        gpu.releaseBuffer(self.vertex_buffer);
        gpu.releaseRenderPipeline(self.blit_pipeline);
        gpu.releaseShader(self.blit_fs);
        gpu.releaseShader(self.blit_vs);
        gpu.releaseRayTracingPipeline(self.rt_pipeline);
        gpu.releaseShader(self.hit_shader);
        gpu.releaseShader(self.shadow_miss_shader);
        gpu.releaseShader(self.miss_shader);
        gpu.releaseShader(self.raygen_shader);
    }

    pub fn ensureOutput(self: *RayState, gpu: *Gpu, size: sg.Extent2D) !void {
        if (self.output_size.width == size.width and self.output_size.height == size.height) {
            return;
        }

        gpu.releaseTextureView(self.output_view);
        gpu.releaseTexture(self.output_texture);

        const texture = try gpu.createTexture(&.{
            .label = "rt_output",
            .type = .d2,
            .usage = .{ .sampled = true, .storage = true },
            .size = .{ .width = size.width, .height = size.height },
            .format = .rgba8_unorm,
        });
        const view = try gpu.createTextureView(texture, &.{ .type = .d2 });

        self.output_texture = texture;
        self.output_view = view;
        self.output_size = size;
        self.output_initialized = false;
    }

    pub fn buildOnce(self: *RayState, cmd: *sg.CommandEncoder) void {
        if (self.accel_built) return;

        cmd.barrier(&.{
            .buffers = &.{
                // Use .general for AS build inputs - .shader_read_only doesn't include AS build stage
                .{ .buffer = self.vertex_buffer, .before = .undefined, .after = .general, .offset = 0, .size = .whole_size },
                .{ .buffer = self.index_buffer, .before = .undefined, .after = .general, .offset = 0, .size = .whole_size },
                .{ .buffer = self.instance_buffer, .before = .undefined, .after = .general, .offset = 0, .size = .whole_size },
                .{ .buffer = self.sbt_buffer, .before = .undefined, .after = .general, .offset = 0, .size = .whole_size },
                .{ .buffer = self.scratch_buffer, .before = .undefined, .after = .general, .offset = 0, .size = .whole_size },
            },
        });

        // Construct geometry data fresh from stored buffer handles
        var blas_geometry = [_]sg.AccelerationStructureGeometry{.{ .triangles = .{
            .vertex_buffer = self.vertex_buffer,
            .vertex_stride = @sizeOf(Vertex),
            .index_buffer = self.index_buffer,
        } }};
        const num_triangles = scene_indices.len / 3;
        var blas_ranges = [_]sg.AccelerationStructureBuildRange{.{ .primitive_count = num_triangles }};
        const blas_build = sg.AccelerationStructureBuildDesc{
            .type = .bottom_level,
            .geometries = &blas_geometry,
            .ranges = &blas_ranges,
        };

        var tlas_geometry = [_]sg.AccelerationStructureGeometry{.{ .instances = .{
            .buffer = self.instance_buffer,
            .stride = 64,
        } }};
        var tlas_ranges = [_]sg.AccelerationStructureBuildRange{.{ .primitive_count = num_instances }};
        const tlas_build = sg.AccelerationStructureBuildDesc{
            .type = .top_level,
            .geometries = &tlas_geometry,
            .ranges = &tlas_ranges,
        };

        cmd.buildAccelerationStructure(self.blas, &blas_build, self.scratch_buffer, 0);

        // Barrier between BLAS and TLAS build - they share scratch buffer
        cmd.barrier(&.{
            .acceleration_structures = &.{
                .{ .accel = self.blas, .before = .build, .after = .read },
            },
            .buffers = &.{
                .{ .buffer = self.scratch_buffer, .before = .general, .after = .general, .offset = 0, .size = .whole_size },
            },
        });

        cmd.buildAccelerationStructure(self.tlas, &tlas_build, self.scratch_buffer, 0);

        cmd.barrier(&.{ .acceleration_structures = &.{
            .{ .accel = self.tlas, .before = .build, .after = .read },
        } });

        self.accel_built = true;
    }

    pub fn trace(self: *RayState, gpu: *Gpu, cmd: *sg.CommandEncoder, frame_size: sg.Extent2D) void {
        // Update time
        self.time = @as(f32, @floatFromInt(self.timer.read())) / 1_000_000_000.0;

        const before_layout: sg.TextureLayout = if (self.output_initialized) .shader_read_only else .undefined;
        cmd.barrier(&.{ .textures = &.{
            .{
                .texture = self.output_texture,
                .before = before_layout,
                .after = .general,
                .aspect = .{ .color = true },
            },
        } });

        var pc: RayPushConstants = .{
            .output_image = self.output_view.index,
            .accel_index = self.tlas.index,
            .vertex_address = @intFromEnum(gpu.deviceAddress(self.vertex_buffer)),
            .index_address = @intFromEnum(gpu.deviceAddress(self.index_buffer)),
            .time = self.time,
        };

        pushRayConstants(gpu, cmd, self.rt_pipeline, &pc);
        cmd.traceRays(self.rt_pipeline, self.sbt, frame_size.width, frame_size.height, 1);

        cmd.barrier(&.{ .textures = &.{
            .{
                .texture = self.output_texture,
                .before = .general,
                .after = .shader_read_only,
                .aspect = .{ .color = true },
            },
        } });

        self.output_initialized = true;
    }

    pub fn blit(self: *RayState, gpu: *Gpu, cmd: *sg.CommandEncoder, frame: sg.Frame) void {
        cmd.barrier(&.{ .textures = &.{
            .{
                .texture = frame.texture,
                .before = .undefined,
                .after = .color_attachment,
                .aspect = .{ .color = true },
            },
        } });

        var pass = cmd.beginRenderPass("rt_blit", &.{
            .color_attachments = &.{
                .{
                    .view = frame.view,
                    .load_op = .clear,
                    .clear_value = .{ 0.02, 0.02, 0.03, 1.0 },
                },
            },
        });

        pass.bindPipeline(self.blit_pipeline);

        const size = gpu.frameSize();
        pass.setViewport(.{ .width = @floatFromInt(size.width), .height = @floatFromInt(size.height) });
        pass.setScissor(.{ .x = 0, .y = 0, .width = size.width, .height = size.height });

        const blit_pc: BlitPushConstants = .{
            .texture_index = self.output_view.index,
            .sampler_index = self.sampler.index,
        };
        pass.pushConstantsTyped(&blit_pc);
        pass.draw(3, 1, 0, 0);

        cmd.endRenderPass(pass);

        cmd.barrier(&.{ .textures = &.{
            .{
                .texture = frame.texture,
                .before = .color_attachment,
                .after = .present,
                .aspect = .{ .color = true },
            },
        } });
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .{};
    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var window: Window = try .init(gpa, "raytrace");
    defer window.deinit(gpa);

    var gpu: *Gpu = try .create(
        gpa,
        .{
            .wayland = .{
                .display = window.display,
                .surface = window.surface,
            },
        },
        .{ 800, 600 },
    );
    defer gpu.destroy();

    var ray_state = try RayState.init(gpu, arena);
    defer ray_state.deinit(gpu);

    while (window.isOpen()) {
        window.poll();

        const window_size = window.getSize();
        const frame = try gpu.beginFrame(.{ @intCast(window_size[0]), @intCast(window_size[1]) });
        const cmd = try gpu.beginCommandEncoder();
        const frame_size = gpu.frameSize();

        try ray_state.ensureOutput(gpu, frame_size);
        ray_state.buildOnce(cmd);
        ray_state.trace(gpu, cmd, frame_size);
        ray_state.blit(gpu, cmd, frame);

        cmd.end();
        try gpu.submit(cmd);
        try gpu.present();
    }
}

fn loadShader(arena: Allocator, gpu: *Gpu, path: []const u8) !sg.Shader {
    const exe_path = try std.fs.selfExeDirPathAlloc(arena);
    defer arena.free(exe_path);

    const shader_path = try std.fs.path.join(arena, &.{ exe_path, path });
    defer arena.free(shader_path);

    const f = try std.fs.openFileAbsolute(shader_path, .{});
    defer f.close();

    const spv = try f.readToEndAllocOptions(arena, 1024 * 1024, null, .@"4", null);
    defer arena.free(spv);

    return try gpu.createShader(&.{
        .data = spv,
        .entry = "main",
    });
}

fn writeInstanceWithTransform(dst: []u8, blas_addr: u64, transform: [12]f32, custom_index: u24) void {
    std.mem.copyForwards(u8, dst[0..48], std.mem.asBytes(&transform));

    const custom_and_mask: u32 = (@as(u32, custom_index) & 0x00ff_ffff) | (0xff << 24);
    const sbt_and_flags: u32 = (0 & 0x00ff_ffff) | (0x5 << 24);

    std.mem.writeInt(u32, dst[48..52], custom_and_mask, .little);
    std.mem.writeInt(u32, dst[52..56], sbt_and_flags, .little);
    std.mem.writeInt(u64, dst[56..64], blas_addr, .little);
}

fn pushRayConstants(gpu: *Gpu, cmd: *sg.CommandEncoder, pipeline: sg.RayTracingPipeline, pc: *const RayPushConstants) void {
    const layout = gpu.pools.ray_tracing_pipelines.getField(pipeline, .layout) orelse
        @panic("missing ray tracing pipeline");

    gpu.device.cmdPushConstants(
        cmd.cb,
        layout,
        .fromInt(0x7fff_ffff), // VK_SHADER_STAGE_ALL to match pipeline layout
        0,
        @sizeOf(RayPushConstants),
        @ptrCast(pc),
    );
}

const SbtLayout = struct {
    stride: u64,
    raygen: u64,
    miss: u64,
    hit: u64,
    miss_count: u32,
};

fn computeSbtLayout(props: vk.PhysicalDeviceRayTracingPipelinePropertiesKHR, miss_count: u32) SbtLayout {
    const stride = std.mem.alignForward(u64, props.shader_group_handle_size, props.shader_group_handle_alignment);
    const miss = std.mem.alignForward(u64, stride, props.shader_group_base_alignment);
    const hit = std.mem.alignForward(u64, miss + stride * miss_count, props.shader_group_base_alignment);
    return .{ .stride = stride, .raygen = 0, .miss = miss, .hit = hit, .miss_count = miss_count };
}

fn createShaderBindingTable(gpu: *Gpu, arena: Allocator, pipeline: sg.RayTracingPipeline) !struct { buffer: sg.Buffer, layout: SbtLayout } {
    const props = gpu.ray_tracing_props;
    const miss_count: u32 = 2; // primary miss + shadow miss
    const layout = computeSbtLayout(props, miss_count);
    const handle_size: usize = props.shader_group_handle_size;
    const group_count: usize = 4; // raygen, miss, shadow_miss, hit

    var handles = try arena.alloc(u8, handle_size * group_count);
    defer arena.free(handles);
    try gpu.getRayTracingShaderGroupHandles(pipeline, 0, @intCast(group_count), handles);

    const sbt_size = layout.hit + layout.stride;
    const sbt_buffer = try gpu.createBuffer(&.{
        .label = "rt_sbt_buffer",
        .size = sbt_size,
        .usage = .{ .storage = true },
        .memory = .cpu_write,
    });

    const data = gpu.mappedData(sbt_buffer);
    @memset(data[0..@intCast(sbt_size)], 0);

    const raygen_offset: usize = @intCast(layout.raygen);
    const miss_offset: usize = @intCast(layout.miss);
    const shadow_miss_offset: usize = @intCast(layout.miss + layout.stride);
    const hit_offset: usize = @intCast(layout.hit);

    // Copy shader handles: raygen(0), miss(1), shadow_miss(2), hit(3)
    std.mem.copyForwards(u8, data[raygen_offset .. raygen_offset + handle_size], handles[0..handle_size]);
    std.mem.copyForwards(u8, data[miss_offset .. miss_offset + handle_size], handles[handle_size .. handle_size * 2]);
    std.mem.copyForwards(u8, data[shadow_miss_offset .. shadow_miss_offset + handle_size], handles[handle_size * 2 .. handle_size * 3]);
    std.mem.copyForwards(u8, data[hit_offset .. hit_offset + handle_size], handles[handle_size * 3 .. handle_size * 4]);

    return .{ .buffer = sbt_buffer, .layout = layout };
}
