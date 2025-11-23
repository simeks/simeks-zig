const std = @import("std");
const Allocator = std.mem.Allocator;

const smath = @import("smath");
const sgui = @import("sgui");
const sgpu = @import("sgpu");
const sos = @import("sos");

const Gpu = sgpu.Gpu;
const Gui = sgui.Gui;
const Window = sos.Window;
const Vec2 = smath.Vec2;

fn handleMouse(state: ?*Gui.InputState, event: Window.MouseEvent) void {
    if (state) |s| {
        switch (event) {
            .enter => |enter| {
                s.mouse_position = .{
                    @floatCast(enter.x),
                    @floatCast(enter.y),
                };
            },
            .leave => {
                s.mouse_left_down = false;
            },
            .motion => |motion| {
                s.mouse_position = .{
                    @floatCast(motion.x),
                    @floatCast(motion.y),
                };
            },
            .button => |button| {
                if (button.button == .left) {
                    s.mouse_left_down = button.state == .pressed;
                }
            },
            .scroll => {},
        }
    }
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .{};

    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var window: Window = try .init(gpa, "boxelvox");
    defer window.deinit(gpa);

    var input: Gui.InputState = .{};
    window.setMouseListener(?*Gui.InputState, handleMouse, &input);

    var gpu: *Gpu = try .create(
        gpa,
        .{
            .wayland = .{
                .display = window.display,
                .surface = window.surface,
            },
        },
        .{ 400, 600 },
    );

    defer gpu.destroy();

    const gui: *Gui = try .create(gpa);
    defer gui.destroy();

    const gui_pass = try GuiPass.init(gpu, arena, gui);
    defer gui_pass.deinit(gpu);
    _ = arena_instance.reset(.retain_capacity);

    var frame_idx: usize = 0;

    var num_clicks: usize = 0;

    const selections1: []const []const u8 = &.{
        "One",
        "Two",
        "Three",
    };
    const selections2: []const []const u8 = &.{
        "Röd",
        "Grön",
        "Blå",
    };
    var selected1: usize = 0;
    var selected2: usize = 0;

    var slider_val: f32 = 0.0;

    var knob_val1: f32 = 0.0;
    var knob_val2: f32 = 0.0;
    var knob_val3: i32 = 0;

    while (window.isOpen()) {
        window.poll();

        const window_size = window.getSize();
        const frame = try gpu.beginFrame(.{
            @intCast(window_size[0]),
            @intCast(window_size[1]),
        });
        const cmd = try gpu.beginCommandEncoder();

        const frame_size = gpu.frameSize();

        gui.beginFrame(
            .{ @floatFromInt(frame_size.width), @floatFromInt(frame_size.height) },
            input,
        );

        {
            gui.beginPanel("root", .{});
            defer gui.endPanel();

            gui.label("EXAMPLE", .{ .size = 44, .color = gui.style.accent_color });

            gui.labelFmt("Frame: {d}", .{frame_idx}, .{});
            frame_idx +%= 1;

            {
                gui.beginPanel("button", .{});
                defer gui.endPanel();
                {
                    if (gui.button("Click me!", .{})) {
                        num_clicks +%= 1;
                    }
                    gui.labelFmt("Number of clicks: {d}", .{num_clicks}, .{});
                }
            }
            {
                gui.beginPanel("dropdown", .{ .color = gui.style.background_color });
                defer gui.endPanel();
                {
                    gui.beginPanel("horizontal", .{ .color = gui.style.background_color, .direction = .horizontal });
                    defer gui.endPanel();

                    _ = gui.dropdown("select1", selections1, &selected1, .{});
                    gui.spacer(.{ 10, 0 });
                    _ = gui.dropdown("select2", selections2, &selected2, .{});
                }

                gui.labelFmt("Selected: {s} {s}", .{
                    selections1[selected1],
                    selections2[selected2],
                }, .{});
            }
            {
                gui.beginPanel("slider", .{ .color = .rgb(22, 26, 24) });
                defer gui.endPanel();

                _ = gui.slider("slider", &slider_val, 0, 100, .{});

                gui.labelFmt("Slider: {d:.0}", .{slider_val}, .{});
            }

            {
                gui.beginPanel("knobs", .{ .color = gui.style.background_color, .direction = .horizontal });
                defer gui.endPanel();

                {
                    gui.beginPanel("knob1", .{});
                    defer gui.endPanel();

                    _ = gui.knob("knob1", &knob_val1, 0, 100, .{});
                    gui.labelFmt("{d:.0}", .{knob_val1}, .{});
                }

                {
                    gui.beginPanel("knob2", .{});
                    defer gui.endPanel();

                    _ = gui.knob("knob2", &knob_val2, 0, 100, .{});
                    gui.labelFmt("{d:.0}", .{knob_val2}, .{});
                }

                {
                    gui.beginPanel("knob3", .{});
                    defer gui.endPanel();

                    _ = gui.discreteKnob("knob3", &knob_val3, 5, .{});
                    gui.labelFmt("{d:.0}", .{knob_val3}, .{});
                }
            }
        }
        gui.endFrame();

        cmd.barrier(&.{ .textures = &.{
            .{
                .texture = frame.texture,
                .before = .undefined,
                .after = .color_attachment,
                .aspect = .{ .color = true },
            },
        } });

        gui_pass.render(gpu, cmd, frame, gui);

        cmd.barrier(&.{ .textures = &.{
            .{
                .texture = frame.texture,
                .before = .color_attachment,
                .after = .present,
                .aspect = .{ .color = true },
            },
        } });

        cmd.end();
        try gpu.submit(cmd);
        try gpu.present();
    }
}

pub const GuiPass = struct {
    const ShaderInput = extern struct {
        vbuf: sgpu.DeviceAddress,
        ibuf: sgpu.DeviceAddress,
        texture_index: u32,
        sampler_index: u32,
    };

    const Vertex = extern struct {
        position: smath.Vec4,
        color: smath.Vec4,
        uv: smath.Vec2,
    };

    vs: sgpu.Shader,
    fs: sgpu.Shader,

    pipeline: sgpu.RenderPipeline,
    atlas_texture: sgpu.Texture,
    atlas_view: sgpu.TextureView,
    sampler: sgpu.Sampler,

    pub fn init(
        gpu: *Gpu,
        arena: Allocator,
        gui: *const Gui,
    ) !GuiPass {
        const vs = try loadShader(arena, gpu, "gui.vert.spv");
        errdefer gpu.releaseShader(vs);

        const fs = try loadShader(arena, gpu, "gui.frag.spv");
        errdefer gpu.releaseShader(fs);

        const pipeline = try gpu.createRenderPipeline(&.{
            .vertex_shader = vs,
            .fragment_shader = fs,
            .color_attachments = .init(&.{
                .{
                    .format = gpu.surfaceFormat(),
                    .blend_enabled = true,
                    .blend_color = .{
                        .src_factor = .src_alpha,
                        .dst_factor = .one_minus_src_alpha,
                        .op = .add,
                    },
                    .blend_alpha = .{
                        .src_factor = .one,
                        .dst_factor = .one_minus_src_alpha,
                        .op = .add,
                    },
                },
            }),
            .push_constant_size = @sizeOf(ShaderInput),
        });
        errdefer gpu.releaseRenderPipeline(pipeline);

        const atlas_texture = try gpu.createTexture(&.{
            .label = "gui_atlas",
            .type = .d2,
            .usage = .{ .sampled = true },
            .size = .{
                .width = @intCast(gui.atlas.image.width),
                .height = @intCast(gui.atlas.image.height),
            },
            .format = .r8_unorm,
        });
        errdefer gpu.releaseTexture(atlas_texture);

        const atlas_view = try gpu.createTextureView(atlas_texture, &.{
            .label = "gui_atlas",
            .type = .d2,
            .format = .r8_unorm,
        });
        errdefer gpu.releaseTextureView(atlas_view);

        const sampler = try gpu.createSampler(&.{
            .label = "gui_sampler",
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer gpu.releaseSampler(sampler);

        try gpu.uploadTexture(atlas_texture, gui.atlas.image.pixels);

        return .{
            .vs = vs,
            .fs = fs,
            .pipeline = pipeline,
            .atlas_texture = atlas_texture,
            .atlas_view = atlas_view,
            .sampler = sampler,
        };
    }

    pub fn deinit(self: *const GuiPass, gpu: *Gpu) void {
        gpu.releaseTextureView(self.atlas_view);
        gpu.releaseTexture(self.atlas_texture);
        gpu.releaseSampler(self.sampler);
        gpu.releaseRenderPipeline(self.pipeline);
        gpu.releaseShader(self.vs);
        gpu.releaseShader(self.fs);
    }

    pub fn render(
        self: *const GuiPass,
        gpu: *Gpu,
        cmd: *sgpu.CommandEncoder,
        frame: sgpu.Frame,
        gui: *const Gui,
    ) void {
        var pass = cmd.beginRenderPass("gui", &.{
            .color_attachments = &.{
                .{
                    .view = frame.view,
                    .load_op = .clear,
                    .clear_value = .{ 0, 0, 0, 1 },
                },
            },
        });
        defer cmd.endRenderPass(pass);

        pass.bindPipeline(self.pipeline);

        const frame_size = gpu.frameSize();
        pass.setViewport(.{
            .width = @floatFromInt(frame_size.width),
            .height = @floatFromInt(frame_size.height),
        });

        pass.setScissor(.{
            .x = 0,
            .y = 0,
            .width = frame_size.width,
            .height = frame_size.height,
        });

        const draw_data = gui.getDrawData();
        if (draw_data.indices.len == 0) {
            return;
        }

        const vertex_alloc = gpu.tempAlloc(draw_data.vertices.len * @sizeOf(Vertex), @alignOf(Vertex));
        const vertices = std.mem.bytesAsSlice(Vertex, vertex_alloc.data);

        const index_alloc = gpu.tempAlloc(draw_data.indices.len * @sizeOf(u32), @alignOf(u32));
        const indices = std.mem.bytesAsSlice(u32, index_alloc.data);
        std.mem.copyForwards(u32, indices, draw_data.indices);

        for (draw_data.vertices, 0..) |src, i| {
            const x_ndc = 2.0 * src.position[0] / draw_data.display_size[0] - 1.0;
            const y_ndc = 2.0 * src.position[1] / draw_data.display_size[1] - 1.0;
            vertices[i] = .{
                .position = .{ x_ndc, y_ndc, 0.0, 1.0 },
                .color = src.color.toFloat(),
                .uv = src.uv,
            };
        }

        const shader_input: ShaderInput = .{
            .vbuf = vertex_alloc.device_addr,
            .ibuf = index_alloc.device_addr,
            .texture_index = self.atlas_view.index,
            .sampler_index = self.sampler.index,
        };
        pass.pushConstantsTyped(&shader_input);
        pass.draw(@intCast(draw_data.indices.len), 1, 0, 0);
    }
};

fn loadShader(arena: Allocator, gpu: *Gpu, path: []const u8) !sgpu.Shader {
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
