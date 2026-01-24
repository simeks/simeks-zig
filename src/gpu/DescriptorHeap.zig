const std = @import("std");

const vk = @import("vulkan");

const Gpu = @import("Gpu.zig");

const DescriptorHeap = @This();

const Bindings = enum(u32) {
    sampled_image = 0,
    storage_image = 1,
    sampler = 2,
    storage_buffer = 3,
    uniform_buffer = 4,
};

const Sizes = struct {
    sampled_images: u32 = 64,
    storage_images: u32 = 64,
    samplers: u32 = 64,
    storage_buffers: u32 = 64,
    uniform_buffers: u32 = 64,
};

ctx: *Gpu,

pool: vk.DescriptorPool,
layout: vk.DescriptorSetLayout,
set: vk.DescriptorSet,

sizes: Sizes,

pub fn init(ctx: *Gpu, sizes: Sizes) !DescriptorHeap {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .sampled_image, .descriptor_count = sizes.sampled_images },
        .{ .type = .storage_image, .descriptor_count = sizes.storage_images },
        .{ .type = .sampler, .descriptor_count = sizes.samplers },
        .{ .type = .storage_buffer, .descriptor_count = sizes.storage_buffers },
        .{ .type = .uniform_buffer, .descriptor_count = sizes.uniform_buffers },
    };

    const pool_info: vk.DescriptorPoolCreateInfo = .{
        .flags = .{ .free_descriptor_set_bit = true, .update_after_bind_bit = true },
        .max_sets = 1,
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = @ptrCast(&pool_sizes),
    };

    const pool = try ctx.device.createDescriptorPool(&pool_info, null);
    errdefer ctx.device.destroyDescriptorPool(pool, null);
    ctx.debugSetName(pool, "DescriptorHeap.pool");

    const layout_bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = @intFromEnum(Bindings.sampled_image),
            .descriptor_type = .sampled_image,
            .descriptor_count = sizes.sampled_images,
            .stage_flags = .fromInt(0x7fff_ffff),
            .p_immutable_samplers = null,
        },
        .{
            .binding = @intFromEnum(Bindings.storage_image),
            .descriptor_type = .storage_image,
            .descriptor_count = sizes.storage_images,
            .stage_flags = .fromInt(0x7fff_ffff),
            .p_immutable_samplers = null,
        },
        .{
            .binding = @intFromEnum(Bindings.sampler),
            .descriptor_type = .sampler,
            .descriptor_count = sizes.samplers,
            .stage_flags = .fromInt(0x7fff_ffff),
            .p_immutable_samplers = null,
        },
        .{
            .binding = @intFromEnum(Bindings.storage_buffer),
            .descriptor_type = .storage_buffer,
            .descriptor_count = sizes.storage_buffers,
            .stage_flags = .fromInt(0x7fff_ffff),
            .p_immutable_samplers = null,
        },
        .{
            .binding = @intFromEnum(Bindings.uniform_buffer),
            .descriptor_type = .uniform_buffer,
            .descriptor_count = sizes.uniform_buffers,
            .stage_flags = .fromInt(0x7fff_ffff),
            .p_immutable_samplers = null,
        },
    };
    const binding_flags = [_]vk.DescriptorBindingFlags{
        .{ .partially_bound_bit = true, .update_after_bind_bit = true },
        .{ .partially_bound_bit = true, .update_after_bind_bit = true },
        .{ .partially_bound_bit = true, .update_after_bind_bit = true },
        .{ .partially_bound_bit = true, .update_after_bind_bit = true },
        .{ .partially_bound_bit = true, .update_after_bind_bit = true },
    };

    const layout_flags_info: vk.DescriptorSetLayoutBindingFlagsCreateInfo = .{
        .binding_count = binding_flags.len,
        .p_binding_flags = @ptrCast(&binding_flags),
    };

    const layout_info: vk.DescriptorSetLayoutCreateInfo = .{
        .p_next = &layout_flags_info,
        .flags = .{ .update_after_bind_pool_bit = true },
        .binding_count = layout_bindings.len,
        .p_bindings = @ptrCast(&layout_bindings),
    };

    const layout = try ctx.device.createDescriptorSetLayout(&layout_info, null);
    errdefer ctx.device.destroyDescriptorSetLayout(layout, null);
    ctx.debugSetName(layout, "DescriptorHeap.layout");

    const alloc_info: vk.DescriptorSetAllocateInfo = .{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&layout),
    };

    var set: [1]vk.DescriptorSet = undefined;
    try ctx.device.allocateDescriptorSets(&alloc_info, &set);
    errdefer ctx.device.freeDescriptorSets(pool, 1, &set);
    ctx.debugSetName(set[0], "DescriptorHeap.set");

    return .{
        .ctx = ctx,
        .pool = pool,
        .layout = layout,
        .set = set[0],
        .sizes = sizes,
    };
}
pub fn deinit(self: *DescriptorHeap) void {
    self.ctx.device.freeDescriptorSets(self.pool, 1, &.{self.set}) catch {};
    self.ctx.device.destroyDescriptorSetLayout(self.layout, null);
    self.ctx.device.destroyDescriptorPool(self.pool, null);
}
pub fn putSampledImageView(
    self: *DescriptorHeap,
    index: u32,
    image_view: vk.ImageView,
) void {
    if (index >= self.sizes.sampled_images) {
        @panic("Sampled image view descriptor heap full");
    }

    const image_info: vk.DescriptorImageInfo = .{
        .sampler = .null_handle,
        .image_view = image_view,
        .image_layout = .shader_read_only_optimal,
    };

    const write: vk.WriteDescriptorSet = .{
        .dst_set = self.set,
        .dst_binding = @intFromEnum(Bindings.sampled_image),
        .dst_array_element = index,
        .descriptor_count = 1,
        .descriptor_type = .sampled_image,
        .p_image_info = @ptrCast(&image_info),
        .p_buffer_info = &.{undefined},
        .p_texel_buffer_view = &.{undefined},
    };

    self.ctx.device.updateDescriptorSets(1, @ptrCast(&write), 0, null);
}
pub fn putStorageImageView(
    self: *DescriptorHeap,
    index: u32,
    image_view: vk.ImageView,
) void {
    if (index >= self.sizes.storage_images) {
        @panic("Storage image view descriptor heap full");
    }

    const image_info: vk.DescriptorImageInfo = .{
        .sampler = .null_handle,
        .image_view = image_view,
        .image_layout = .general,
    };

    const write: vk.WriteDescriptorSet = .{
        .dst_set = self.set,
        .dst_binding = @intFromEnum(Bindings.storage_image),
        .dst_array_element = index,
        .descriptor_count = 1,
        .descriptor_type = .storage_image,
        .p_image_info = @ptrCast(&image_info),
        .p_buffer_info = &.{undefined},
        .p_texel_buffer_view = &.{undefined},
    };

    self.ctx.device.updateDescriptorSets(1, @ptrCast(&write), 0, null);
}
pub fn putSampler(
    self: *DescriptorHeap,
    index: u32,
    sampler: vk.Sampler,
) void {
    if (index >= self.sizes.samplers) {
        @panic("Sampler view descriptor heap full");
    }

    const sampler_info: vk.DescriptorImageInfo = .{
        .sampler = sampler,
        .image_view = .null_handle,
        .image_layout = .undefined,
    };

    const write: vk.WriteDescriptorSet = .{
        .dst_set = self.set,
        .dst_binding = @intFromEnum(Bindings.sampler),
        .dst_array_element = index,
        .descriptor_count = 1,
        .descriptor_type = .sampler,
        .p_image_info = @ptrCast(&sampler_info),
        .p_buffer_info = &.{undefined},
        .p_texel_buffer_view = &.{undefined},
    };

    self.ctx.device.updateDescriptorSets(1, @ptrCast(&write), 0, null);
}

pub fn putStorageBuffer(
    self: *DescriptorHeap,
    index: u32,
    buffer: vk.Buffer,
    size: vk.DeviceSize,
) void {
    if (index >= self.sizes.storage_buffers) {
        @panic("Storage buffer descriptor heap full");
    }

    const buffer_info: vk.DescriptorBufferInfo = .{
        .buffer = buffer,
        .offset = 0,
        .range = size,
    };

    const write: vk.WriteDescriptorSet = .{
        .dst_set = self.set,
        .dst_binding = @intFromEnum(Bindings.storage_buffer),
        .dst_array_element = index,
        .descriptor_count = 1,
        .descriptor_type = .storage_buffer,
        .p_image_info = &.{undefined},
        .p_buffer_info = @ptrCast(&buffer_info),
        .p_texel_buffer_view = &.{undefined},
    };

    self.ctx.device.updateDescriptorSets(1, @ptrCast(&write), 0, null);
}

pub fn putUniformBuffer(
    self: *DescriptorHeap,
    index: u32,
    buffer: vk.Buffer,
    size: vk.DeviceSize,
) void {
    if (index >= self.sizes.uniform_buffers) {
        @panic("Uniform buffer descriptor heap full");
    }

    const buffer_info: vk.DescriptorBufferInfo = .{
        .buffer = buffer,
        .offset = 0,
        .range = size,
    };

    const write: vk.WriteDescriptorSet = .{
        .dst_set = self.set,
        .dst_binding = @intFromEnum(Bindings.uniform_buffer),
        .dst_array_element = index,
        .descriptor_count = 1,
        .descriptor_type = .uniform_buffer,
        .p_image_info = &.{undefined},
        .p_buffer_info = @ptrCast(&buffer_info),
        .p_texel_buffer_view = &.{undefined},
    };

    self.ctx.device.updateDescriptorSets(1, @ptrCast(&write), 0, null);
}
