const vk = @import("vulkan");
const root = @import("root.zig");

pub fn vkFormat(format: root.Format) vk.Format {
    return switch (format) {
        .undefined => .undefined,
        .r8_unorm => .r8_unorm,
        .r8_snorm => .r8_snorm,
        .r8_uint => .r8_uint,
        .r8_sint => .r8_sint,
        .rg8_unorm => .r8g8_unorm,
        .rg8_snorm => .r8g8_snorm,
        .rg8_uint => .r8g8_uint,
        .rg8_sint => .r8g8_sint,
        .rgb8_unorm => .r8g8b8_unorm,
        .rgb8_snorm => .r8g8b8_snorm,
        .rgb8_uint => .r8g8b8_uint,
        .rgb8_sint => .r8g8b8_sint,
        .rgba8_unorm => .r8g8b8a8_unorm,
        .rgba8_snorm => .r8g8b8a8_snorm,
        .rgba8_uint => .r8g8b8a8_uint,
        .rgba8_sint => .r8g8b8a8_sint,
        .rgba8_srgb => .r8g8b8a8_srgb,
        .bgra8_unorm => .b8g8r8a8_unorm,
        .bgra8_snorm => .b8g8r8a8_snorm,
        .bgra8_uint => .b8g8r8a8_uint,
        .bgra8_sint => .b8g8r8a8_sint,
        .bgra8_srgb => .b8g8r8a8_srgb,
        .r16_uint => .r16_uint,
        .r16_sint => .r16_sint,
        .r16_float => .r16_sfloat,
        .rg16_uint => .r16g16_uint,
        .rg16_sint => .r16g16_sint,
        .rg16_float => .r16g16_sfloat,
        .rgb16_uint => .r16g16b16_uint,
        .rgb16_sint => .r16g16b16_sint,
        .rgb16_float => .r16g16b16_sfloat,
        .rgba16_uint => .r16g16b16a16_uint,
        .rgba16_sint => .r16g16b16a16_sint,
        .rgba16_float => .r16g16b16a16_sfloat,
        .r32_uint => .r32_uint,
        .r32_sint => .r32_sint,
        .r32_float => .r32_sfloat,
        .rg32_uint => .r32g32_uint,
        .rg32_sint => .r32g32_sint,
        .rg32_float => .r32g32_sfloat,
        .rgb32_uint => .r32g32b32_uint,
        .rgb32_sint => .r32g32b32_sint,
        .rgb32_float => .r32g32b32_sfloat,
        .rgba32_uint => .r32g32b32a32_uint,
        .rgba32_sint => .r32g32b32a32_sint,
        .rgba32_float => .r32g32b32a32_sfloat,
        .d16_unorm => .d16_unorm,
        .d32_float => .d32_sfloat,
        .s8_uint => .s8_uint,
        .d16_unorm_s8_uint => .d16_unorm_s8_uint,
        .d24_unorm_s8_uint => .d24_unorm_s8_uint,
        .d32_float_s8_uint => .d32_sfloat_s8_uint,
    };
}

pub fn fromVkformat(format: vk.Format) root.Format {
    return switch (format) {
        .undefined => .undefined,
        .r8_unorm => .r8_unorm,
        .r8_snorm => .r8_snorm,
        .r8_uint => .r8_uint,
        .r8_sint => .r8_sint,
        .r8g8_unorm => .rg8_unorm,
        .r8g8_snorm => .rg8_snorm,
        .r8g8_uint => .rg8_uint,
        .r8g8_sint => .rg8_sint,
        .r8g8b8_unorm => .rgb8_unorm,
        .r8g8b8_snorm => .rgb8_snorm,
        .r8g8b8_uint => .rgb8_uint,
        .r8g8b8_sint => .rgb8_sint,
        .r8g8b8a8_unorm => .rgba8_unorm,
        .r8g8b8a8_snorm => .rgba8_snorm,
        .r8g8b8a8_uint => .rgba8_uint,
        .r8g8b8a8_sint => .rgba8_sint,
        .r8g8b8a8_srgb => .rgba8_srgb,
        .b8g8r8a8_unorm => .bgra8_unorm,
        .b8g8r8a8_snorm => .bgra8_snorm,
        .b8g8r8a8_uint => .bgra8_uint,
        .b8g8r8a8_sint => .bgra8_sint,
        .b8g8r8a8_srgb => .bgra8_srgb,
        .r16_uint => .r16_uint,
        .r16_sint => .r16_sint,
        .r16_sfloat => .r16_float,
        .r16g16_uint => .rg16_uint,
        .r16g16_sint => .rg16_sint,
        .r16g16_sfloat => .rg16_float,
        .r16g16b16_uint => .rgb16_uint,
        .r16g16b16_sint => .rgb16_sint,
        .r16g16b16_sfloat => .rgb16_float,
        .r16g16b16a16_uint => .rgba16_uint,
        .r16g16b16a16_sint => .rgba16_sint,
        .r16g16b16a16_sfloat => .rgba16_float,
        .r32_uint => .r32_uint,
        .r32_sint => .r32_sint,
        .r32_sfloat => .r32_float,
        .r32g32_uint => .rg32_uint,
        .r32g32_sint => .rg32_sint,
        .r32g32_sfloat => .rg32_float,
        .r32g32b32_uint => .rgb32_uint,
        .r32g32b32_sint => .rgb32_sint,
        .r32g32b32_sfloat => .rgb32_float,
        .r32g32b32a32_uint => .rgba32_uint,
        .r32g32b32a32_sint => .rgba32_sint,
        .r32g32b32a32_sfloat => .rgba32_float,
        .d16_unorm => .d16_unorm,
        .d32_sfloat => .d32_float,
        .s8_uint => .s8_uint,
        .d16_unorm_s8_uint => .d16_unorm_s8_uint,
        .d24_unorm_s8_uint => .d24_unorm_s8_uint,
        .d32_sfloat_s8_uint => .d32_float_s8_uint,
        else => @panic("not implemented"),
    };
}

pub fn hasDepth(format: root.Format) bool {
    return switch (format) {
        .d16_unorm, .d32_float, .d16_unorm_s8_uint, .d24_unorm_s8_uint, .d32_float_s8_uint => true,
        else => false,
    };
}
pub fn hasStencil(format: root.Format) bool {
    return switch (format) {
        .d16_unorm_s8_uint, .d24_unorm_s8_uint, .d32_float_s8_uint => true,
        else => false,
    };
}

pub fn vkImageType(texture_type: root.TextureType) vk.ImageType {
    return switch (texture_type) {
        .d1 => .@"1d",
        .d2 => .@"2d",
        .d3 => .@"3d",
    };
}

pub fn vkImageViewType(view_type: root.TextureViewType) vk.ImageViewType {
    return switch (view_type) {
        .d1 => .@"1d",
        .d2 => .@"2d",
        .d3 => .@"3d",
    };
}

pub fn vkImageAspectFlags(aspect: root.TextureAspectFlags) vk.ImageAspectFlags {
    var flags: vk.ImageAspectFlags = .{};
    if (aspect.color) {
        flags.color_bit = true;
    }
    if (aspect.depth) {
        flags.depth_bit = true;
    }
    if (aspect.stencil) {
        flags.stencil_bit = true;
    }
    return flags;
}

pub fn vkImageLayout(layout: root.TextureLayout) vk.ImageLayout {
    return switch (layout) {
        .undefined => .undefined,
        .color_attachment => .color_attachment_optimal,
        .depth_attachment => .depth_attachment_optimal,
        .present => .present_src_khr,
        .shader_read_only => .shader_read_only_optimal,
        .general => .general,
        .transfer_src => .transfer_src_optimal,
        .transfer_dst => .transfer_dst_optimal,
    };
}

pub fn vkFilter(layout: root.Filter) vk.Filter {
    return switch (layout) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

pub fn vkSamplerMipmapMode(layout: root.Filter) vk.SamplerMipmapMode {
    return switch (layout) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

pub fn vkSamplerAddressMode(layout: root.AddressMode) vk.SamplerAddressMode {
    return switch (layout) {
        .repeat => .repeat,
        .mirrored_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
        .clamp_to_border => .clamp_to_border,
        .mirror_clamp_to_edge => .mirror_clamp_to_edge,
    };
}

pub fn vkAttachmentLoadOp(op: root.LoadOp) vk.AttachmentLoadOp {
    return switch (op) {
        .undefined => .dont_care,
        .load => .load,
        .clear => .clear,
    };
}
pub fn vkAttachmentStoreOp(op: root.StoreOp) vk.AttachmentStoreOp {
    return switch (op) {
        .undefined => .dont_care,
        .store => .store,
    };
}

pub fn vkCullModeFlags(cull_mode: root.CullMode) vk.CullModeFlags {
    return switch (cull_mode) {
        .none => .{},
        .front => .{ .front_bit = true },
        .back => .{ .back_bit = true },
    };
}
pub fn vkFrontFace(front_face: root.FrontFace) vk.FrontFace {
    return switch (front_face) {
        .counter_clockwise => .counter_clockwise,
        .clockwise => .clockwise,
    };
}

pub fn vkColorComponentFlags(mask: root.ColorWriteMask) vk.ColorComponentFlags {
    return .{
        .r_bit = mask.r,
        .g_bit = mask.g,
        .b_bit = mask.b,
        .a_bit = mask.a,
    };
}

pub fn vkBlendFactor(blend_factor: root.BlendFactor) vk.BlendFactor {
    return switch (blend_factor) {
        .zero => .zero,
        .one => .one,
        .src_color => .src_color,
        .one_minus_src_color => .one_minus_src_color,
        .dst_color => .dst_color,
        .one_minus_dst_color => .one_minus_dst_color,
        .src_alpha => .src_alpha,
        .one_minus_src_alpha => .one_minus_src_alpha,
        .dst_alpha => .dst_alpha,
        .one_minus_dst_alpha => .one_minus_dst_alpha,
        .constant_color => .constant_color,
        .one_minus_constant_color => .one_minus_constant_color,
        .constant_alpha => .constant_alpha,
        .one_minus_constant_alpha => .one_minus_constant_alpha,
        .src_alpha_saturate => .src_alpha_saturate,
    };
}

pub fn vkBlendOp(blend_op: root.BlendOp) vk.BlendOp {
    return switch (blend_op) {
        .add => .add,
        .subtract => .subtract,
        .reverse_subtract => .reverse_subtract,
        .min => .min,
        .max => .max,
    };
}

pub fn vkStencilOp(stencil_op: root.StencilOp) vk.StencilOp {
    return switch (stencil_op) {
        .keep => .keep,
        .zero => .zero,
        .replace => .replace,
        .increment_and_clamp => .increment_and_clamp,
        .decrement_and_clamp => .decrement_and_clamp,
        .invert => .invert,
        .increment_and_wrap => .increment_and_wrap,
        .decrement_and_wrap => .decrement_and_wrap,
    };
}

pub fn vkCompareOp(compare_op: root.CompareOp) vk.CompareOp {
    return switch (compare_op) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_or_equal => .less_or_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_or_equal => .greater_or_equal,
        .always => .always,
    };
}

pub fn vkIndexType(index_type: root.IndexType) vk.IndexType {
    return switch (index_type) {
        .uint16 => .uint16,
        .uint32 => .uint32,
    };
}

pub fn vkAccelerationStructureType(t: root.AccelerationStructureType) vk.AccelerationStructureTypeKHR {
    return switch (t) {
        .bottom_level => .bottom_level_khr,
        .top_level => .top_level_khr,
    };
}

pub fn vkRayTracingShaderStage(stage: root.RayTracingShaderStage) vk.ShaderStageFlags {
    return switch (stage) {
        .raygen => .{ .raygen_bit_khr = true },
        .miss => .{ .miss_bit_khr = true },
        .closest_hit => .{ .closest_hit_bit_khr = true },
        .any_hit => .{ .any_hit_bit_khr = true },
        .intersection => .{ .intersection_bit_khr = true },
        .callable => .{ .callable_bit_khr = true },
    };
}

pub fn vkBuildFlags(flags: root.AccelerationStructureBuildFlags) vk.BuildAccelerationStructureFlagsKHR {
    return .{
        .allow_update_bit_khr = flags.allow_update,
        .allow_compaction_bit_khr = flags.allow_compaction,
        .prefer_fast_trace_bit_khr = flags.prefer_fast_trace,
        .prefer_fast_build_bit_khr = flags.prefer_fast_build,
        .low_memory_bit_khr = flags.low_memory,
    };
}
