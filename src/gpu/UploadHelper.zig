const std = @import("std");
const assert = std.debug.assert;

const vk = @import("vulkan");

const root = @import("root.zig");
const Gpu = @import("Gpu.zig");
const GpuTempAllocator = @import("GpuTempAllocator.zig");
const sync = @import("sync.zig");

const UploadHelper = @This();

ctx: *Gpu,

cmd_pool: vk.CommandPool,
cb: vk.CommandBuffer,
fence: vk.Fence,

temp_alloc: GpuTempAllocator,

pub fn init(ctx: *Gpu) !UploadHelper {
    const cmd_pool_info: vk.CommandPoolCreateInfo = .{
        .queue_family_index = ctx.queue.family,
    };

    const pool = try ctx.device.createCommandPool(&cmd_pool_info, null);
    errdefer ctx.device.destroyCommandPool(pool, null);

    const cb_info: vk.CommandBufferAllocateInfo = .{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var cb: [1]vk.CommandBuffer = undefined;
    try ctx.device.allocateCommandBuffers(
        &cb_info,
        &cb,
    );
    errdefer ctx.device.freeCommandBuffers(pool, 1, &.{cb[0]});

    const fence = try ctx.device.createFence(&.{}, null);
    errdefer ctx.device.destroyFence(fence, null);

    const temp_alloc = try GpuTempAllocator.init(ctx);
    errdefer temp_alloc.deinit();

    return .{
        .ctx = ctx,
        .cmd_pool = pool,
        .cb = cb[0],
        .fence = fence,
        .temp_alloc = temp_alloc,
    };
}
pub fn deinit(self: *UploadHelper) void {
    self.temp_alloc.deinit();
    self.ctx.device.destroyFence(self.fence, null);
    self.ctx.device.freeCommandBuffers(self.cmd_pool, 1, &.{self.cb});
    self.ctx.device.destroyCommandPool(self.cmd_pool, null);
}

pub fn uploadBuffer(
    self: *UploadHelper,
    handle: root.Buffer,
    data: []const u8,
) !void {
    const vk_buffer = self.ctx.pools.buffers.getField(handle, .buffer) orelse
        return error.BufferNotFound;
    const info = self.ctx.pools.buffers.getFieldPtr(handle, .info) orelse
        return error.BufferNotFound;

    if (data.len != info.size) {
        return error.InvalidBufferSize;
    }

    const tmp = try self.temp_alloc.allocate(data.len, 1);
    @memcpy(tmp.data, data);

    try self.ctx.device.resetCommandPool(self.cmd_pool, .{});

    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
    };
    try self.ctx.device.beginCommandBuffer(self.cb, &begin_info);

    self.ctx.device.cmdCopyBuffer(
        self.cb,
        // TODO:
        self.ctx.pools.buffers.getField(self.temp_alloc.buffer, .buffer) orelse unreachable,
        vk_buffer,
        1,
        &.{
            .{
                .src_offset = 0,
                .dst_offset = 0,
                .size = data.len,
            },
        },
    );

    try self.ctx.device.endCommandBuffer(self.cb);

    const cb_info = [1]vk.CommandBufferSubmitInfo{
        .{
            .command_buffer = self.cb,
            .device_mask = 0,
        },
    };

    const submit_info: vk.SubmitInfo2 = .{
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = @ptrCast(&cb_info),
    };

    try self.ctx.device.resetFences(1, &.{self.fence});
    try self.ctx.device.queueSubmit2KHR(
        self.ctx.queue.handle,
        1,
        &.{submit_info},
        self.fence,
    );

    _ = try self.ctx.device.waitForFences(1, &.{self.fence}, vk.TRUE, std.math.maxInt(u64));
    self.temp_alloc.reset();
}

pub fn uploadTexture(
    self: *UploadHelper,
    handle: root.Texture,
    data: []const u8,
) !void {
    const vk_image = self.ctx.pools.textures.getField(handle, .image) orelse
        return error.TextureNotFound;
    const info = self.ctx.pools.textures.getFieldPtr(handle, .info) orelse
        return error.TextureNotFound;

    // TODO: >2D
    assert(info.extent.depth == 1);

    // TODO: alignment
    const row_pitch: usize = formatStride(info.format) * info.extent.width;
    const slice_pitch: usize = row_pitch * info.extent.height;

    if (data.len != slice_pitch) {
        return error.InvalidTextureSize;
    }

    const tmp = try self.temp_alloc.allocate(slice_pitch, 1);
    @memcpy(tmp.data, data);

    try self.ctx.device.resetCommandPool(self.cmd_pool, .{});

    const begin_info: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit_bit = true },
    };
    try self.ctx.device.beginCommandBuffer(self.cb, &begin_info);

    const barrier1 = sync.imageBarrier(
        .{
            .texture = handle,
            .before = .undefined,
            .after = .transfer_dst,
            .aspect = .{ .color = true }, // TODO:
        },
        vk_image,
    );

    self.ctx.device.cmdPipelineBarrier2KHR(
        self.cb,
        &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &.{barrier1},
        },
    );

    self.ctx.device.cmdCopyBufferToImage(
        self.cb,
        self.ctx.pools.buffers.getField(self.temp_alloc.buffer, .buffer) orelse unreachable, // TODO:
        vk_image,
        .transfer_dst_optimal,
        1,
        &.{
            .{
                // TODO:
                .buffer_offset = @intFromPtr(tmp.data.ptr) -
                    @intFromPtr(self.temp_alloc.mapped.ptr),
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true }, // TODO:
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = info.extent,
            },
        },
    );

    const barrier2 = sync.imageBarrier(
        .{
            .texture = handle,
            .before = .transfer_dst,
            .after = .shader_read_only,
            .aspect = .{ .color = true }, // TODO:
        },
        vk_image,
    );

    self.ctx.device.cmdPipelineBarrier2KHR(
        self.cb,
        &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &.{barrier2},
        },
    );

    try self.ctx.device.endCommandBuffer(self.cb);

    const cb_info = [1]vk.CommandBufferSubmitInfo{
        .{
            .command_buffer = self.cb,
            .device_mask = 0,
        },
    };

    const submit_info: vk.SubmitInfo2 = .{
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = @ptrCast(&cb_info),
    };

    try self.ctx.device.resetFences(1, &.{self.fence});
    try self.ctx.device.queueSubmit2KHR(
        self.ctx.queue.handle,
        1,
        &.{submit_info},
        self.fence,
    );
    _ = try self.ctx.device.waitForFences(1, &.{self.fence}, vk.TRUE, std.math.maxInt(u64));
    self.temp_alloc.reset();
}

// TODO: Put this somewhere better
fn formatStride(format: vk.Format) usize {
    return switch (format) {
        // zig fmt: off
        .r8_unorm,
        .r8_snorm,
        .r8_uint,
        .r8_sint,
        .s8_uint => 1,
        .r8g8_unorm,
        .r8g8_snorm,
        .r8g8_uint,
        .r8g8_sint,
        .r16_uint,
        .r16_sint,
        .r16_sfloat,
        .d16_unorm => 2,
        .r8g8b8_unorm,
        .r8g8b8_snorm,
        .r8g8b8_uint,
        .r8g8b8_sint,
        .b8g8r8_unorm,
        .b8g8r8_snorm,
        .b8g8r8_uint,
        .b8g8r8_sint,
        .d16_unorm_s8_uint => 3,
        .r8g8b8a8_unorm,
        .r8g8b8a8_snorm,
        .r8g8b8a8_uint,
        .r8g8b8a8_sint,
        .r8g8b8a8_srgb,
        .b8g8r8a8_unorm,
        .b8g8r8a8_snorm,
        .b8g8r8a8_uint,
        .b8g8r8a8_sint,
        .b8g8r8a8_srgb,
        .r16g16_uint,
        .r16g16_sint,
        .r16g16_sfloat,
        .r32_uint,
        .r32_sint,
        .r32_sfloat,
        .d32_sfloat,
        .d24_unorm_s8_uint => 4,
        .d32_sfloat_s8_uint => 5,
        .r16g16b16_uint,
        .r16g16b16_sint,
        .r16g16b16_sfloat => 6,
        .r16g16b16a16_uint,
        .r16g16b16a16_sint,
        .r16g16b16a16_sfloat,
        .r32g32_uint,
        .r32g32_sint,
        .r32g32_sfloat => 8,
        .r32g32b32_uint,
        .r32g32b32_sint,
        .r32g32b32_sfloat => 12,
        .r32g32b32a32_uint,
        .r32g32b32a32_sint,
        .r32g32b32a32_sfloat => 16,
        else => @panic("Unknown format"),
// zig fmt: on
    };
}
