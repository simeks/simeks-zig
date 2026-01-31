const vk = @import("vulkan");
const root = @import("root.zig");
const conv = @import("conv.zig");
const Gpu = @import("Gpu.zig");

pub fn imageBarrier(
    desc: root.TextureBarrier,
    image: vk.Image,
) vk.ImageMemoryBarrier2 {
    const src_stage, const src_access = imageStageAccess(
        conv.vkImageLayout(desc.before),
    );
    const dst_stage, const dst_access = imageStageAccess(
        conv.vkImageLayout(desc.after),
    );

    return .{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
        .old_layout = conv.vkImageLayout(desc.before),
        .new_layout = conv.vkImageLayout(desc.after),
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = conv.vkImageAspectFlags(desc.aspect),
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
}

pub fn bufferBarrier(
    desc: root.BufferBarrier,
    buffer: vk.Buffer,
) vk.BufferMemoryBarrier2 {
    const src_stage, const src_access = bufferStageAccess(
        desc.before,
    );
    const dst_stage, const dst_access = bufferStageAccess(
        desc.after,
    );

    return .{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .buffer = buffer,
        .offset = desc.offset,
        .size = @intFromEnum(desc.size),
    };
}

pub fn accelerationBarrier(desc: root.AccelerationStructureBarrier) vk.MemoryBarrier2 {
    const src_stage, const src_access = accelerationStageAccess(desc.before);
    const dst_stage, const dst_access = accelerationStageAccess(desc.after);

    return .{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
    };
}

pub fn vkRange(range: root.AccelerationStructureBuildRange) vk.AccelerationStructureBuildRangeInfoKHR {
    return .{
        .primitive_count = range.primitive_count,
        .primitive_offset = range.primitive_offset,
        .first_vertex = range.first_vertex,
        .transform_offset = range.transform_offset,
    };
}

fn bufferStageAccess(
    layout: root.BufferLayout,
) struct { vk.PipelineStageFlags2, vk.AccessFlags2 } {
    return switch (layout) {
        .undefined => .{
            .{ .top_of_pipe_bit = true },
            .{},
        },
        .indirect_buffer => .{
            .{ .draw_indirect_bit = true },
            .{ .indirect_command_read_bit = true },
        },
        .vertex_buffer => .{
            .{ .vertex_input_bit = true },
            .{ .vertex_attribute_read_bit = true },
        },
        .index_buffer => .{
            .{ .vertex_input_bit = true },
            .{ .index_read_bit = true },
        },
        .shader_read_only => .{
            .{
                .fragment_shader_bit = true,
                .compute_shader_bit = true,
                .pre_rasterization_shaders_bit = true,
            },
            .{ .shader_read_bit = true },
        },
        .general => .{
            .{ .compute_shader_bit = true, .all_transfer_bit = true, .acceleration_structure_build_bit_khr = true },
            .{ .memory_read_bit = true, .memory_write_bit = true, .transfer_write_bit = true },
        },
    };
}

fn accelerationStageAccess(
    access: root.AccelerationStructureAccess,
) struct { vk.PipelineStageFlags2, vk.AccessFlags2 } {
    return switch (access) {
        .build => .{
            .{ .acceleration_structure_build_bit_khr = true },
            .{ .acceleration_structure_write_bit_khr = true },
        },
        .read => .{
            .{ .ray_tracing_shader_bit_khr = true },
            .{ .acceleration_structure_read_bit_khr = true },
        },
    };
}

fn imageStageAccess(
    state: vk.ImageLayout,
) struct { vk.PipelineStageFlags2, vk.AccessFlags2 } {
    return switch (state) {
        .undefined => .{
            .{ .top_of_pipe_bit = true },
            .{},
        },
        .color_attachment_optimal => .{
            .{ .color_attachment_output_bit = true },
            .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
        },
        .depth_attachment_optimal => .{
            .{ .early_fragment_tests_bit = true },
            .{ .depth_stencil_attachment_read_bit = true, .depth_stencil_attachment_write_bit = true },
        },
        .shader_read_only_optimal => .{
            .{
                .fragment_shader_bit = true,
                .compute_shader_bit = true,
                .pre_rasterization_shaders_bit = true,
            },
            .{ .shader_read_bit = true },
        },
        .transfer_dst_optimal => .{
            .{ .all_transfer_bit = true },
            .{ .transfer_write_bit = true },
        },
        .general => .{
            .{ .compute_shader_bit = true, .all_transfer_bit = true },
            .{ .memory_read_bit = true, .memory_write_bit = true, .transfer_write_bit = true },
        },
        .present_src_khr => .{
            .{ .color_attachment_output_bit = true },
            .{},
        },
        else => @panic("Unsupported layout transition"),
    };
}
