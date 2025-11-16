const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const vk = @import("vulkan");

const root = @import("root.zig");
const StringTable = @import("core").StringTable;

const conv = @import("conv.zig");
const sync = @import("sync.zig");

const Gpu = @import("Gpu.zig");

pub const CommandEncoder = struct {
    // 2 timestamps per pass
    const max_query_sample_count = 2 * root.max_num_passes;

    ctx: *Gpu,

    // Reset every frame
    temp_arena: std.heap.ArenaAllocator,

    pool: vk.CommandPool,
    cb: vk.CommandBuffer,

    query_pool: vk.QueryPool,

    pass_names: std.ArrayList(?StringTable.Id),

    // 2 timestamps per pass, tick sample + availability
    pass_timestamps: [2 * max_query_sample_count]u64 = @splat(0),

    pub fn init(ctx: *Gpu) CommandEncoder {
        const cmd_pool_info: vk.CommandPoolCreateInfo = .{
            .queue_family_index = ctx.queue.family,
        };

        const pool = ctx.device.createCommandPool(&cmd_pool_info, null) catch
            @panic("CommandEncoder init failed");

        const cb_info: vk.CommandBufferAllocateInfo = .{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        };

        var cb: [1]vk.CommandBuffer = undefined;
        ctx.device.allocateCommandBuffers(
            &cb_info,
            &cb,
        ) catch
            @panic("CommandEncoder init failed");

        const query_pool_info: vk.QueryPoolCreateInfo = .{
            .query_type = .timestamp,
            .query_count = max_query_sample_count,
        };
        const query_pool = ctx.device.createQueryPool(&query_pool_info, null) catch
            @panic("CommandEncoder init failed");

        return .{
            .ctx = ctx,
            .temp_arena = std.heap.ArenaAllocator.init(ctx.allocator),
            .pool = pool,
            .cb = cb[0],
            .query_pool = query_pool,
            .pass_names = .{},
        };
    }
    pub fn deinit(self: CommandEncoder) void {
        self.ctx.device.destroyQueryPool(self.query_pool, null);
        self.ctx.device.freeCommandBuffers(self.pool, 1, &.{self.cb});
        self.ctx.device.destroyCommandPool(self.pool, null);
        self.temp_arena.deinit();
    }
    pub fn reset(self: *CommandEncoder) !void {
        try self.ctx.device.resetCommandPool(self.pool, .{});
        _ = self.temp_arena.reset(.retain_capacity);

        self.pass_names = std.ArrayList(?StringTable.Id).initCapacity(
            self.temp_arena.allocator(),
            root.max_num_passes,
        ) catch @panic("oom");
    }
    pub fn begin(self: *CommandEncoder) !void {
        const begin_info: vk.CommandBufferBeginInfo = .{
            .flags = .{ .one_time_submit_bit = true },
        };
        try self.ctx.device.beginCommandBuffer(self.cb, &begin_info);
        self.ctx.device.cmdResetQueryPool(self.cb, self.query_pool, 0, max_query_sample_count);
    }

    pub fn end(self: *CommandEncoder) void {
        self.ctx.device.endCommandBuffer(self.cb) catch
            @panic("endCommandBuffer");
    }
    pub fn beginRenderPass(
        self: *CommandEncoder,
        comptime label: ?[]const u8,
        desc: *const root.RenderPassDesc,
    ) RenderPassEncoder {
        self.recordBegin(label);
        return .begin(self.ctx, self.cb, desc);
    }
    pub fn endRenderPass(self: *CommandEncoder, pass: RenderPassEncoder) void {
        _ = pass;
        self.ctx.device.cmdEndRenderingKHR(self.cb);
        self.recordEnd();
    }
    pub fn beginComputePass(self: *CommandEncoder, comptime label: ?[]const u8) ComputePassEncoder {
        self.recordBegin(label);
        return .begin(self.ctx, self.cb);
    }
    pub fn endComputePass(self: *CommandEncoder, pass: ComputePassEncoder) void {
        _ = pass;
        self.recordEnd();
    }

    pub fn copyBuffer(self: *CommandEncoder, desc: *const root.CopyBufferDesc) void {
        var regions = std.ArrayList(vk.BufferCopy).initCapacity(
            self.temp_arena.allocator(),
            desc.regions.len,
        ) catch @panic("oom");
        defer regions.deinit(self.temp_arena.allocator());

        for (desc.regions) |region| {
            regions.appendAssumeCapacity(.{
                .src_offset = region.src_offset,
                .dst_offset = region.dst_offset,
                .size = region.size,
            });
        }

        self.ctx.device.cmdCopyBuffer(
            self.cb,
            self.ctx.pools.buffers.getField(desc.src, .buffer) orelse @panic("buffer not found"),
            self.ctx.pools.buffers.getField(desc.dst, .buffer) orelse @panic("buffer not found"),
            @intCast(regions.items.len),
            @ptrCast(regions.items.ptr),
        );
    }

    fn recordBegin(self: *CommandEncoder, comptime name: ?[]const u8) void {
        self.ctx.device.cmdWriteTimestamp(
            self.cb,
            .{ .top_of_pipe_bit = true },
            self.query_pool,
            @intCast(2 * self.pass_names.items.len),
        );

        const id = if (name) |n| self.ctx.string_table.hash(n) else null;
        self.pass_names.appendBounded(id) catch
            @panic("too many render passes");
    }
    fn recordEnd(self: *CommandEncoder) void {
        self.ctx.device.cmdWriteTimestamp(
            self.cb,
            .{ .bottom_of_pipe_bit = true },
            self.query_pool,
            @intCast(2 * (self.pass_names.items.len - 1) + 1),
        );
    }

    pub fn barrier(self: *CommandEncoder, barriers: *const root.BarrierGroup) void {
        const arena = self.temp_arena.allocator();

        var image_barriers: std.ArrayList(vk.ImageMemoryBarrier2) = .empty;
        defer image_barriers.deinit(arena);

        for (barriers.textures) |t| {
            const image_barrier = sync.imageBarrier(
                t,
                self.ctx.pools.textures.getField(t.texture, .image) orelse
                    @panic("texture not found"),
            );
            image_barriers.append(
                arena,
                image_barrier,
            ) catch @panic("oom");
        }

        var buffer_barriers: std.ArrayList(vk.BufferMemoryBarrier2) = .empty;
        defer buffer_barriers.deinit(self.temp_arena.allocator());

        for (barriers.buffers) |b| {
            const buffer_barrier = sync.bufferBarrier(
                b,
                self.ctx.pools.buffers.getField(b.buffer, .buffer) orelse
                    @panic("buffer not found"),
            );
            buffer_barriers.append(arena, buffer_barrier) catch @panic("oom");
        }

        self.ctx.device.cmdPipelineBarrier2KHR(
            self.cb,
            &.{
                .buffer_memory_barrier_count = @intCast(buffer_barriers.items.len),
                .p_buffer_memory_barriers = @ptrCast(buffer_barriers.items.ptr),
                .image_memory_barrier_count = @intCast(image_barriers.items.len),
                .p_image_memory_barriers = @ptrCast(image_barriers.items.ptr),
            },
        );
    }

    /// Collect samples, must be called after frame has completed
    pub fn collectSamples(
        self: *CommandEncoder,
        allocator: Allocator,
        samples: *std.ArrayList(root.PassTime),
    ) !void {
        if (self.pass_names.items.len == 0) {
            return;
        }

        _ = try self.ctx.device.getQueryPoolResults(
            self.query_pool,
            0,
            max_query_sample_count,
            @sizeOf(u64) * max_query_sample_count,
            &self.pass_timestamps,
            @sizeOf(u64),

            // Availability bit not working on MoltenVTK
            // If we use wait_bit, it just blocks forever on linux
            // So now we use wait on macos, otherwise we just pray
            .{ .@"64_bit" = true, .wait_bit = builtin.os.tag == .macos },
        );

        const ms_per_tick = self.ctx.device_limits.timestamp_period / std.time.ns_per_ms;
        for (0.., self.pass_names.items) |i, name| {
            const t0 = self.pass_timestamps[2 * i];
            const t1 = self.pass_timestamps[2 * i + 1];

            const delta: u64 = if (t1 > t0)
                t1 - t0
            else
                0;

            try samples.append(allocator, .{
                .name = name,
                .time = ms_per_tick *
                    @as(f32, @floatFromInt(delta)),
            });
        }
    }
};

pub const RenderPassEncoder = struct {
    ctx: *Gpu,
    cb: vk.CommandBuffer,

    current_pipeline: ?root.RenderPipeline = null,

    pub fn begin(
        ctx: *Gpu,
        cb: vk.CommandBuffer,
        desc: *const root.RenderPassDesc,
    ) RenderPassEncoder {
        var color_attachments_buf: [root.max_color_attachments]vk.RenderingAttachmentInfo = undefined;
        var color_attachments: std.ArrayList(vk.RenderingAttachmentInfo) = .initBuffer(
            &color_attachments_buf,
        );

        var extent: ?vk.Extent2D = null;

        for (desc.color_attachments) |att| {
            const view = ctx.pools.texture_views.get(att.view) orelse
                @panic("texture view not found");

            color_attachments.appendBounded(.{
                .image_view = view.view,
                .image_layout = .attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = conv.vkAttachmentLoadOp(att.load_op),
                .store_op = conv.vkAttachmentStoreOp(att.store_op),
                .clear_value = .{ .color = .{ .float_32 = att.clear_value } },
            }) catch unreachable;

            if (extent) |*e| {
                e.* = .{
                    .width = @max(e.width, view.info.extent.width),
                    .height = @max(e.height, view.info.extent.height),
                };
            } else {
                extent = .{
                    .width = view.info.extent.width,
                    .height = view.info.extent.height,
                };
            }
        }

        var depth_attachment: vk.RenderingAttachmentInfo = undefined;
        if (desc.depth_stencil) |att| {
            const view = ctx.pools.texture_views.get(att.view) orelse
                @panic("depth view not found");

            depth_attachment = .{
                .image_view = view.view,
                .image_layout = .depth_attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = conv.vkAttachmentLoadOp(att.load_op),
                .store_op = conv.vkAttachmentStoreOp(att.store_op),
                .clear_value = .{ .depth_stencil = .{
                    .depth = att.clear_value,
                    .stencil = 0,
                } },
            };

            if (extent) |*e| {
                e.* = .{
                    .width = @max(e.width, view.info.extent.width),
                    .height = @max(e.height, view.info.extent.height),
                };
            } else {
                extent = .{
                    .width = view.info.extent.width,
                    .height = view.info.extent.height,
                };
            }
        }

        // TODO: Will we ever have render passes without color attachments?
        assert(extent != null);

        const rendering_info: vk.RenderingInfoKHR = .{
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = extent.?,
            },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = @intCast(color_attachments.items.len),
            .p_color_attachments = if (color_attachments.items.len > 0)
                @ptrCast(color_attachments.items)
            else
                null,
            .p_depth_attachment = if (desc.depth_stencil != null) &depth_attachment else null,
        };

        ctx.device.cmdBeginRenderingKHR(cb, &rendering_info);

        return .{
            .ctx = ctx,
            .cb = cb,
        };
    }
    pub fn bindPipeline(self: *RenderPassEncoder, pipeline: root.RenderPipeline) void {
        const pipeline_entry = self.ctx.pools.render_pipelines.get(pipeline) orelse
            @panic("pipeline not found");

        self.current_pipeline = pipeline;

        self.ctx.device.cmdBindPipeline(
            self.cb,
            .graphics,
            pipeline_entry.pipeline,
        );

        // TODO: Always same
        var sets_buffer: [root.max_descriptor_sets]vk.DescriptorSet = undefined;
        var sets: std.ArrayList(vk.DescriptorSet) = .initBuffer(&sets_buffer);

        sets.appendBounded(self.ctx.descriptor_heap.set) catch unreachable;

        self.ctx.device.cmdBindDescriptorSets(
            self.cb,
            .graphics,
            pipeline_entry.layout,
            0,
            @intCast(sets.items.len),
            @ptrCast(sets.items),
            0,
            null,
        );
    }
    pub fn setViewport(self: *RenderPassEncoder, viewport: root.Viewport) void {
        self.ctx.device.cmdSetViewport(
            self.cb,
            0,
            1,
            &.{.{
                .x = viewport.x,
                .y = viewport.y,
                .width = viewport.width,
                .height = viewport.height,
                .min_depth = viewport.min_depth,
                .max_depth = viewport.max_depth,
            }},
        );
    }
    pub fn setScissor(self: *RenderPassEncoder, rect: root.ScissorRect) void {
        self.ctx.device.cmdSetScissor(
            self.cb,
            0,
            1,
            &.{.{
                .offset = .{
                    .x = rect.x,
                    .y = rect.y,
                },
                .extent = .{
                    .width = rect.width,
                    .height = rect.height,
                },
            }},
        );
    }
    pub fn pushConstants(self: *RenderPassEncoder, data: []const u8) void {
        if (self.current_pipeline == null) {
            @panic("no pipeline bound");
        }

        const vk_layout = self.ctx.pools.render_pipelines.getField(
            self.current_pipeline.?,
            .layout,
        ) orelse @panic("pipeline not found");

        self.ctx.device.cmdPushConstants(
            self.cb,
            vk_layout,
            .fromInt(0x7fff_ffff),
            0,
            @intCast(data.len),
            data.ptr,
        );
    }
    pub fn pushConstantsTyped(self: *RenderPassEncoder, data: anytype) void {
        if (@typeInfo(@TypeOf(data)) != .pointer) {
            @compileError("Expected pointer");
        }
        self.pushConstants(std.mem.asBytes(data));
    }

    pub fn draw(
        self: *RenderPassEncoder,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        self.ctx.device.cmdDraw(
            self.cb,
            vertex_count,
            instance_count,
            first_vertex,
            first_instance,
        );
    }

    pub fn drawIndirect(
        self: *RenderPassEncoder,
        buffer: root.Buffer,
        offset: u64,
        draw_count: u32,
        stride: u32,
    ) void {
        const buffer_entry = self.ctx.pools.buffers.get(buffer) orelse
            @panic("buffer not found");

        self.ctx.device.cmdDrawIndirect(
            self.cb,
            buffer_entry.buffer,
            offset,
            draw_count,
            stride,
        );
    }
};

pub const ComputePassEncoder = struct {
    ctx: *Gpu,
    cb: vk.CommandBuffer,

    current_pipeline: ?root.ComputePipeline = null,

    pub fn begin(
        ctx: *Gpu,
        cb: vk.CommandBuffer,
    ) ComputePassEncoder {
        return .{
            .ctx = ctx,
            .cb = cb,
        };
    }

    pub fn bindPipeline(self: *ComputePassEncoder, pipeline: root.ComputePipeline) void {
        const pipeline_entry = self.ctx.pools.compute_pipelines.get(pipeline) orelse
            @panic("pipeline not found");

        self.current_pipeline = pipeline;

        self.ctx.device.cmdBindPipeline(
            self.cb,
            .compute,
            pipeline_entry.pipeline,
        );

        // TODO: Always same
        var sets_buffer: [root.max_descriptor_sets]vk.DescriptorSet = undefined;
        var sets: std.ArrayList(vk.DescriptorSet) = .initBuffer(&sets_buffer);

        sets.appendBounded(self.ctx.descriptor_heap.set) catch unreachable;

        self.ctx.device.cmdBindDescriptorSets(
            self.cb,
            .compute,
            pipeline_entry.layout,
            0,
            @intCast(sets.items.len),
            @ptrCast(sets.items),
            0,
            null,
        );
    }

    pub fn pushConstants(self: *ComputePassEncoder, data: []const u8) void {
        if (self.current_pipeline == null) {
            @panic("no pipeline bound");
        }

        const vk_layout = self.ctx.pools.compute_pipelines.getField(
            self.current_pipeline.?,
            .layout,
        ) orelse @panic("pipeline not found");

        self.ctx.device.cmdPushConstants(
            self.cb,
            vk_layout,
            .fromInt(0x7fff_ffff),
            0,
            @intCast(data.len),
            data.ptr,
        );
    }
    pub fn pushConstantsTyped(self: *ComputePassEncoder, data: anytype) void {
        if (@typeInfo(@TypeOf(data)) != .pointer) {
            @compileError("Expected pointer");
        }
        self.pushConstants(std.mem.asBytes(data));
    }

    pub fn dispatch(
        self: *ComputePassEncoder,
        group_count_x: u32,
        group_count_y: u32,
        group_count_z: u32,
    ) void {
        self.ctx.device.cmdDispatch(
            self.cb,
            group_count_x,
            group_count_y,
            group_count_z,
        );
    }
};
