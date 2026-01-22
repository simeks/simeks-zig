const std = @import("std");

pub const vk = @import("vulkan");

const StringTable = @import("core").StringTable;

pub const frames_in_flight = 2;
pub const max_color_attachments = 4;
pub const max_descriptor_sets = 4;
pub const max_num_passes = 64; // Need to know for query pool

pub const Gpu = @import("Gpu.zig");

const Pools = @import("Pools.zig");
pub const Buffer = Pools.Buffer;
pub const Texture = Pools.Texture;
pub const TextureView = Pools.TextureView;
pub const Sampler = Pools.Sampler;
pub const Shader = Pools.Shader;
pub const RenderPipeline = Pools.RenderPipeline;
pub const ComputePipeline = Pools.ComputePipeline;

const command = @import("command.zig");
pub const CommandEncoder = command.CommandEncoder;
pub const RenderPassEncoder = command.RenderPassEncoder;
pub const ComputePassEncoder = command.ComputePassEncoder;

pub const vma = @import("vma.zig");

pub const DeviceAddress = enum(u64) {
    null_handle = 0,
    _,

    pub fn offset(self: DeviceAddress, nb: u64) DeviceAddress {
        return @enumFromInt(@as(u64, @intFromEnum(self)) + nb);
    }
};

pub fn TempBytesAlign(alignment: comptime_int) type {
    return struct {
        data: []align(alignment) u8,
        device_addr: DeviceAddress,
    };
}
pub fn TempBytesTyped(Type: type) type {
    return struct {
        data: *Type,
        device_addr: DeviceAddress,
    };
}

pub fn FixedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        data: [capacity]T = undefined,
        len: usize = 0,

        pub fn init(items: []const T) Self {
            if (items.len > capacity) @panic("InlineArray overflow");

            var result: Self = .{
                .len = items.len,
            };
            @memcpy(result.data[0..items.len], items);
            return result;
        }

        pub fn slice(self: *const Self) []const T {
            return self.data[0..self.len];
        }

        pub fn sliceMut(self: *Self) []T {
            return self.data[0..self.len];
        }
    };
}

pub const Frame = struct {
    texture: Texture,
    view: TextureView,
};

pub const Extent2D = struct {
    width: u32,
    height: u32,

    pub fn asExtent3D(self: Extent2D) Extent3D {
        return .{
            .width = self.width,
            .height = self.height,
        };
    }
};
pub const Extent3D = struct {
    width: u32,
    height: u32 = 1,
    depth: u32 = 1,
};

pub const BufferUsage = packed struct(u32) {
    vertex_buffer: bool = false, // TODO: Not actually usable
    index_buffer: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    _padding: u27 = 0,
};

pub const MemoryType = enum(u32) {
    gpu_only = 0,
    cpu_write = 1,
    cpu_read = 2,
};

pub const BufferDesc = struct {
    label: ?[:0]const u8 = null,
    size: u64,
    usage: BufferUsage,
    memory: MemoryType,
};

pub const Format = enum(u32) {
    undefined = 0,
    r8_unorm = 1,
    r8_snorm = 2,
    r8_uint = 3,
    r8_sint = 4,
    rg8_unorm = 5,
    rg8_snorm = 6,
    rg8_uint = 7,
    rg8_sint = 8,
    rgb8_unorm = 9,
    rgb8_snorm = 10,
    rgb8_uint = 11,
    rgb8_sint = 12,
    rgba8_unorm = 13,
    rgba8_snorm = 14,
    rgba8_uint = 15,
    rgba8_sint = 16,
    rgba8_srgb = 17,
    bgra8_unorm = 18,
    bgra8_snorm = 19,
    bgra8_uint = 20,
    bgra8_sint = 21,
    bgra8_srgb = 22,

    r16_uint = 23,
    r16_sint = 24,
    r16_float = 25,
    rg16_uint = 26,
    rg16_sint = 27,
    rg16_float = 28,
    rgb16_uint = 29,
    rgb16_sint = 30,
    rgb16_float = 31,
    rgba16_uint = 32,
    rgba16_sint = 33,
    rgba16_float = 34,

    r32_uint = 35,
    r32_sint = 36,
    r32_float = 37,
    rg32_uint = 38,
    rg32_sint = 39,
    rg32_float = 40,
    rgb32_uint = 41,
    rgb32_sint = 42,
    rgb32_float = 43,
    rgba32_uint = 44,
    rgba32_sint = 45,
    rgba32_float = 46,

    d16_unorm = 47,
    d32_float = 48,
    s8_uint = 49,
    d16_unorm_s8_uint = 50,
    d24_unorm_s8_uint = 51,
    d32_float_s8_uint = 52,
};

pub const TextureType = enum(u32) {
    d1 = 0,
    d2 = 1,
    d3 = 2,
};

pub const TextureViewType = enum(u32) {
    d1 = 0,
    d2 = 1,
    d3 = 2,
};

pub const TextureUsage = packed struct(u32) {
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_stencil: bool = false,
    _padding: u28 = 0,
};

pub const TextureDesc = struct {
    label: ?[:0]const u8 = null,
    type: TextureType,
    usage: TextureUsage,
    size: Extent3D,
    format: Format,
};

pub const TextureViewDesc = struct {
    label: ?[:0]const u8 = null,
    type: TextureViewType,
    // .undefined means the same as the texture format
    format: Format = .undefined,
};

pub const Filter = enum(u32) {
    nearest = 0,
    linear = 1,
};

pub const AddressMode = enum(u32) {
    repeat = 0,
    mirrored_repeat = 1,
    clamp_to_edge = 2,
    clamp_to_border = 3,
    mirror_clamp_to_edge = 4,
};

pub const SamplerDesc = struct {
    label: ?[:0]const u8 = null,
    mag_filter: Filter = .nearest,
    min_filter: Filter = .nearest,
    mipmap_mode: Filter = .nearest,
    address_mode_u: AddressMode = .clamp_to_edge,
    address_mode_v: AddressMode = .clamp_to_edge,
    address_mode_w: AddressMode = .clamp_to_edge,
};

pub const ShaderDesc = struct {
    label: ?[:0]const u8 = null,
    data: []const u8,
    entry: [:0]const u8,
};

pub const ColorWriteMask = packed struct(u32) {
    r: bool = false,
    g: bool = false,
    b: bool = false,
    a: bool = false,
    _padding: u28 = 0,

    const all: ColorWriteMask = .{
        .r = true,
        .g = true,
        .b = true,
        .a = true,
    };
};

pub const BlendFactor = enum(u32) {
    zero = 0,
    one = 1,
    src_color = 2,
    one_minus_src_color = 3,
    dst_color = 4,
    one_minus_dst_color = 5,
    src_alpha = 6,
    one_minus_src_alpha = 7,
    dst_alpha = 8,
    one_minus_dst_alpha = 9,
    constant_color = 10,
    one_minus_constant_color = 11,
    constant_alpha = 12,
    one_minus_constant_alpha = 13,
    src_alpha_saturate = 14,
};

pub const BlendOp = enum(u32) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
};

pub const BlendState = struct {
    src_factor: BlendFactor = .one,
    dst_factor: BlendFactor = .zero,
    op: BlendOp = .add,
};

pub const ColorAttachmentDesc = struct {
    format: Format,

    blend_enabled: bool = false,
    blend_color: BlendState = .{},
    blend_alpha: BlendState = .{},

    write_mask: ColorWriteMask = .all,
};

pub const StencilOp = enum(u32) {
    keep = 0,
    zero = 1,
    replace = 2,
    increment_and_clamp = 3,
    decrement_and_clamp = 4,
    invert = 5,
    increment_and_wrap = 6,
    decrement_and_wrap = 7,
};
pub const CompareOp = enum(u32) {
    never = 0,
    less = 1,
    equal = 2,
    less_or_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_or_equal = 6,
    always = 7,
};

pub const StencilOpState = struct {
    fail_op: StencilOp = .keep,
    pass_op: StencilOp = .keep,
    depth_fail_op: StencilOp = .keep,
    compare_op: CompareOp = .never,
    compare_mask: u32 = 0,
    write_mask: u32 = 0,
    reference: u32 = 0,
};

pub const DepthStencilDesc = struct {
    format: Format = .undefined, // Assumes no depth stencil if undefined
    depth_test_enabled: bool = false,
    depth_write_enabled: bool = false,
    depth_compare_op: CompareOp = .always,
};

pub const CullMode = enum(u32) {
    none = 0,
    front = 1,
    back = 2,
};

pub const FrontFace = enum(u32) {
    counter_clockwise = 0,
    clockwise = 1,
};

pub const RenderPipelineDesc = struct {
    label: ?[:0]const u8 = null,

    vertex_shader: Shader,
    fragment_shader: Shader,

    cull_mode: CullMode = .none,
    front_face: FrontFace = .counter_clockwise,

    // FixedArray to make it easier to cache this whole struct
    color_attachments: FixedArray(ColorAttachmentDesc, max_color_attachments),
    depth_stencil: DepthStencilDesc = .{ .format = .undefined },

    push_constant_size: u32 = 0,
};

pub const ComputePipelineDesc = struct {
    label: ?[:0]const u8 = null,

    shader: Shader,

    push_constant_size: u32 = 0,
};

pub const LoadOp = enum(u32) {
    undefined = 0,
    load = 1,
    clear = 2,
};
pub const StoreOp = enum(u32) {
    undefined = 0,
    store = 1,
};

pub const ColorAttachment = struct {
    view: TextureView,
    load_op: LoadOp = .load,
    store_op: StoreOp = .store,
    clear_value: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const DepthStencilAttachment = struct {
    view: TextureView,
    load_op: LoadOp = .load,
    store_op: StoreOp = .store,
    clear_value: f32 = 0.0, // TODO: Only depth for now
};

pub const RenderPassDesc = struct {
    label: ?[:0]const u8 = null,
    color_attachments: []const ColorAttachment,
    depth_stencil: ?DepthStencilAttachment = null,
};

pub const TextureLayout = enum(u32) {
    undefined,
    color_attachment,
    depth_attachment,
    present,
    shader_read_only,
    general,
    transfer_src,
    transfer_dst,
};

pub const TextureAspectFlags = packed struct(u32) {
    color: bool = false,
    depth: bool = false,
    stencil: bool = false,
    _padding: u29 = 0,
};

pub const TextureBarrier = struct {
    texture: Texture,
    before: TextureLayout,
    after: TextureLayout,
    aspect: TextureAspectFlags,
};

pub const BufferLayout = enum(u32) {
    undefined,
    indirect_buffer,
    vertex_buffer,
    index_buffer,
    shader_read_only,
    general,
};

pub const BufferBarrier = struct {
    buffer: Buffer,
    before: BufferLayout,
    after: BufferLayout,
    offset: u64,
    size: enum(u64) {
        whole_size = ~@as(u64, 0),
        _,

        pub fn bytes(b: u64) @This() {
            return @enumFromInt(b);
        }
    },
};

pub const BarrierGroup = struct {
    textures: []const TextureBarrier = &.{},
    buffers: []const BufferBarrier = &.{},
};

pub const CopyBufferRegion = struct {
    src_offset: u64,
    dst_offset: u64,
    size: u64,
};

pub const CopyBufferDesc = struct {
    src: Buffer,
    dst: Buffer,
    regions: []const CopyBufferRegion,
};

pub const Viewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

pub const ScissorRect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const PassTime = struct {
    name: ?StringTable.Id,
    time: f32,
};
