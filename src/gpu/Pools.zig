const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const vk = @import("vulkan");

const root = @import("root.zig");
const vma = @import("vma.zig");

const VkBuffer = struct {
    buffer: vk.Buffer,
    allocation: vma.Allocation,
    mapped_data: ?[]u8,
    device_addr: root.DeviceAddress,
    info: root.BufferDesc,
};

const VkTexture = struct {
    image: vk.Image,
    allocation: vma.Allocation,

    info: vk.ImageCreateInfo,
};

const VkTextureView = struct {
    view: vk.ImageView,
    info: struct {
        extent: vk.Extent3D,
        storage: bool,
        sampled: bool,
    },
};

const VkSampler = struct {
    sampler: vk.Sampler,
};

const VkBindGroupLayout = struct {
    layout: vk.DescriptorSetLayout,
    pool_sizes: std.BoundedArray(vk.DescriptorPoolSize, 16),
};

const VkBindGroup = struct {
    set: vk.DescriptorSet,
    pool: vk.DescriptorPool,
};

const VkShader = struct {
    module: vk.ShaderModule,
    entry: [:0]const u8,
};

const VkRenderPipeline = struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    desc: root.RenderPipelineDesc,
};
const VkComputePipeline = struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    desc: root.ComputePipelineDesc,
};

const BufferPool = Pool(VkBuffer, 16, 16, 128);
const TexturePool = Pool(VkTexture, 16, 16, 128);
const TextureViewPool = Pool(VkTextureView, 16, 16, 128);
const SamplerPool = Pool(VkSampler, 16, 16, 128);
const ShaderPool = Pool(VkShader, 16, 16, 128);
const RenderPipelinePool = Pool(VkRenderPipeline, 16, 16, 128);
const ComputePipelinePool = Pool(VkComputePipeline, 16, 16, 128);

pub const Buffer = BufferPool.Handle;
pub const Texture = TexturePool.Handle;
pub const TextureView = TextureViewPool.Handle;
pub const Sampler = SamplerPool.Handle;
pub const Shader = ShaderPool.Handle;
pub const RenderPipeline = RenderPipelinePool.Handle;
pub const ComputePipeline = ComputePipelinePool.Handle;

const Pools = @This();

buffers: BufferPool,
textures: TexturePool,
texture_views: TextureViewPool,
samplers: SamplerPool,
shaders: ShaderPool,
render_pipelines: RenderPipelinePool,
compute_pipelines: ComputePipelinePool,

pub fn init(allocator: Allocator) !Pools {
    return .{
        .buffers = try .init(allocator),
        .textures = try .init(allocator),
        .texture_views = try .init(allocator),
        .samplers = try .init(allocator),
        .shaders = try .init(allocator),
        .render_pipelines = try .init(allocator),
        .compute_pipelines = try .init(allocator),
    };
}
pub fn deinit(self: *Pools) void {
    self.buffers.deinit();
    self.textures.deinit();
    self.texture_views.deinit();
    self.samplers.deinit();
    self.shaders.deinit();
    self.render_pipelines.deinit();
    self.compute_pipelines.deinit();
}

/// Resource pool
/// Backed by MultiArrayList, meaning each field of the resource struct is
/// stored in a separate array
/// capacity: Initial capacity
pub fn Pool(
    TResource: type,
    comptime index_bits: u16,
    comptime generation_bits: u16,
    comptime capacity: usize,
) type {
    const THandle = _Handle(TResource, index_bits, generation_bits);

    const max_resources_count = 1 << index_bits;

    return struct {
        const Self = @This();

        pub const Handle = THandle;
        const Resource = TResource;
        const Storage = std.MultiArrayList(Resource);

        const Field = std.meta.FieldEnum(Resource);

        const Generations = std.ArrayListUnmanaged(Handle.GenerationType);
        const FreeSet = std.DynamicBitSetUnmanaged;

        allocator: std.mem.Allocator,
        storage: Storage,
        generations: Generations,
        free_set: FreeSet,

        pub fn init(allocator: std.mem.Allocator) !Self {
            var storage = Storage{};
            try storage.setCapacity(allocator, capacity);

            return Self{
                .allocator = allocator,
                .storage = storage,
                .generations = try Generations.initCapacity(allocator, capacity),
                .free_set = try FreeSet.initFull(allocator, 0),
            };
        }
        pub fn deinit(self: *Self) void {
            if (builtin.mode == .Debug) {
                if (self.free_set.bit_length < self.storage.len) {
                    std.log.err("Pool ({s}): Unfreed resources", .{@typeName(TResource)});
                }
            }
            self.storage.deinit(self.allocator);
            self.generations.deinit(self.allocator);
            self.free_set.deinit(self.allocator);

            self.* = undefined;
        }

        /// Allocate new handle
        pub fn allocate(self: *Self) !Handle {
            if (self.free_set.findFirstSet()) |index| {
                self.free_set.unset(index);
                return .{
                    .index = @intCast(index),
                    .generation = self.generations.items[index],
                };
            }

            if (self.storage.len >= max_resources_count) return error.PoolFull;

            const index = try self.storage.addOne(self.allocator);
            if (self.free_set.bit_length < self.storage.len) {
                try self.free_set.resize(self.allocator, self.storage.len, true);
            }
            self.free_set.unset(index);
            try self.generations.append(self.allocator, 1);
            return .{ .index = @intCast(index), .generation = 1 };
        }

        /// Remove resource by handle
        pub fn release(self: *Self, handle: Handle) void {
            assert(self.has(handle));
            const entry = &self.generations.items[handle.index];
            if (entry.* == std.math.maxInt(Handle.GenerationType)) {
                entry.* = 1;
            } else {
                entry.* += 1;
            }
            self.free_set.set(handle.index);
        }

        /// Set resource by handle
        /// Assumes handle is valid
        pub fn set(self: *Self, handle: Handle, resource: Resource) void {
            assert(self.has(handle));
            self.storage.set(handle.index, resource);
        }

        /// Return resource by handle, null if handle is invalid
        pub fn get(self: *const Self, handle: Handle) ?Resource {
            if (!self.has(handle)) {
                return null;
            }
            return self.storage.get(handle.index);
        }

        /// Swap to handles
        pub fn swap(self: *Self, handle1: Handle, handle2: Handle) void {
            assert(self.has(handle1));
            assert(self.has(handle2));

            const res1 = self.storage.get(handle1.index);
            const res2 = self.storage.get(handle2.index);

            self.storage.set(handle2.index, res1);
            self.storage.set(handle1.index, res2);
        }

        /// Is handle valid in pool
        pub fn has(self: *const Self, handle: Handle) bool {
            return handle.index < self.generations.items.len and
                handle.generation == self.generations.items[handle.index];
        }

        /// Returns pointer to the specified resource and field
        /// Error if handle is invalid
        pub fn getField(
            self: *const Self,
            handle: Handle,
            comptime field: Field,
        ) ?FieldType(field) {
            if (!self.has(handle)) {
                return null;
            }
            return self.storage.items(field)[handle.index];
        }

        /// Returns pointer to the specified resource and field
        /// Error if handle is invalid
        pub fn getFieldPtr(
            self: *Self,
            handle: Handle,
            comptime field: Field,
        ) ?*FieldType(field) {
            if (!self.has(handle)) {
                return null;
            }
            return &self.storage.items(field)[handle.index];
        }

        fn FieldType(comptime field: Field) type {
            return std.meta.fieldInfo(Resource, field).type;
        }

        pub const Iterator = struct {
            pool: *const Self,
            next_index: usize = 0,

            pub fn next(self: *Iterator) ?Handle {
                while (self.next_index < self.pool.storage.len and
                    self.pool.free_set.isSet(self.next_index))
                {
                    self.next_index += 1;
                }

                if (self.next_index < self.pool.storage.len) {
                    const index = self.next_index;
                    self.next_index += 1;
                    return Handle{
                        .index = @intCast(index),
                        .generation = self.pool.generations.items[index],
                    };
                }
                return null;
            }
        };

        /// Iterate over all alive handles in pool
        pub fn iterator(self: *const Self) Iterator {
            return Iterator{ .pool = self };
        }
    };
}

/// Resource handle
/// Generation 0 is reserved for invalid handles
/// index_bits: number of bits used for index
/// generation_bits: number of bits used for generation
fn _Handle(
    Type: type,
    comptime index_bits: u16,
    comptime generation_bits: u16,
) type {
    return extern struct {
        const Self = @This();

        // To ensure returned type is unique for this type
        pub const T: type = Type;
        pub const IndexType = std.meta.Int(.unsigned, index_bits);
        pub const GenerationType = std.meta.Int(.unsigned, generation_bits);
        pub const invalid = Self{ .index = 0, .generation = 0 };

        index: IndexType = 0,
        generation: GenerationType = 0,

        pub fn eql(a: Self, b: Self) bool {
            return a.index == b.index and a.generation == b.generation;
        }

        pub fn isValid(self: Self) bool {
            return self.generation != 0;
        }
    };
}

test "Pool" {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;

    const Resource = struct {
        x: u32,
        y: u32,
    };

    const PoolType = Pool(Resource, 16, 16, 32);

    var pool = try PoolType.init(std.testing.allocator);
    defer pool.deinit();

    const handle1 = try pool.allocate();
    pool.set(handle1, Resource{ .x = 1, .y = 2 });
    try expect(pool.has(handle1));
    try expect(handle1.isValid());
    try expectEqual(0, handle1.index);
    try expectEqual(1, handle1.generation);

    try expectEqual(Resource{ .x = 1, .y = 2 }, pool.get(handle1).?);

    const x1 = pool.getFieldPtr(handle1, .x).?;
    const y1 = pool.getFieldPtr(handle1, .y).?;
    try expectEqual(1, x1.*);
    try expectEqual(2, y1.*);

    x1.* = 4;
    y1.* = 5;

    try expectEqual(4, pool.getField(handle1, .x).?);
    try expectEqual(5, pool.getField(handle1, .y).?);

    pool.release(handle1);
    try expect(!pool.has(handle1));

    const handle2 = try pool.allocate();
    pool.set(handle2, Resource{ .x = 1, .y = 2 });
    try expectEqual(0, handle2.index);
    try expectEqual(2, handle2.generation);
}
test "Pool fail" {
    const expectError = std.testing.expectError;
    const expectEqual = std.testing.expectEqual;

    const Resource = struct {
        x: u32,
        y: u32,
    };

    // max resource count is 255
    const PoolType = Pool(Resource, 8, 8, 256);

    var pool = try PoolType.init(std.testing.allocator);
    defer pool.deinit();

    const handle1 = try pool.allocate();
    pool.set(handle1, Resource{ .x = 1, .y = 2 });
    pool.release(handle1);

    try expectEqual(null, pool.getField(handle1, .x));
    try expectEqual(null, pool.getFieldPtr(handle1, .x));

    for (0..256) |i| {
        const handle = try pool.allocate();
        pool.set(handle, Resource{ .x = @intCast(i), .y = 2 });
        try expectEqual(i, pool.getField(handle, .x).?);
    }
    try expectError(error.PoolFull, pool.allocate());
}
test "Pool.iterator" {
    const expectEqual = std.testing.expectEqual;

    const Resource = struct {
        x: u32,
    };

    const PoolType = Pool(Resource, 16, 16, 32);

    var pool = try PoolType.init(std.testing.allocator);
    defer pool.deinit();

    const handle1 = try pool.allocate();
    const handle2 = try pool.allocate();
    const handle3 = try pool.allocate();

    pool.release(handle2);

    var iter = pool.iterator();
    try expectEqual(handle1, iter.next().?);
    try expectEqual(handle3, iter.next().?);
    try expectEqual(null, iter.next());
}
