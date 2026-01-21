const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const Allocator = std.mem.Allocator;

const root = @import("root.zig");
const Buffer = root.Buffer;
const Texture = root.Texture;
const TextureView = root.TextureView;
const Sampler = root.Sampler;
const Shader = root.Shader;
const RenderPipeline = root.RenderPipeline;
const ComputePipeline = root.ComputePipeline;

const CommandEncoder = root.CommandEncoder;
const RenderPassEncoder = root.RenderPassEncoder;

const Swapchain = @import("Swapchain.zig");
const Pools = @import("Pools.zig");
const DestoyQueue = @import("DestroyQueue.zig");
const GpuTempAllocator = @import("GpuTempAllocator.zig");
const UploadHelper = @import("UploadHelper.zig");
const DescriptorHeap = @import("DescriptorHeap.zig");
const conv = @import("conv.zig");
const sync = @import("sync.zig");
const vma = @import("vma.zig");

const StringTable = @import("core").StringTable;

pub const WindowInterface = union(enum) {
    wayland: struct {
        display: *anyopaque,
        surface: *anyopaque,
    },
    glfw: struct {
        window: *anyopaque,

        create_surface_fn: *const fn (
            vk.Instance,
            *anyopaque,
            ?*const vk.AllocationCallbacks,
            *vk.SurfaceKHR,
        ) callconv(.c) vk.Result,
    },
};

const vkGetInstanceProcAddr = @extern(vk.PfnGetInstanceProcAddr, .{
    .name = "vkGetInstanceProcAddr",
    .library_name = "vulkan",
});

const use_validation_layer: bool = builtin.mode == .Debug;
const is_debug: bool = builtin.mode == .Debug;

const Queue = struct {
    handle: vk.Queue,
    family: u32,
};
const FrameData = struct {
    frame_number: u64,

    enc: CommandEncoder,
    allocator: GpuTempAllocator,
};

const Gpu = @This();

allocator: Allocator,

base: vk.BaseWrapper,
instance: Instance,
surface: vk.SurfaceKHR,
physical_device: vk.PhysicalDevice,
device: Device,

queue: Queue,

gpu_allocator: vma.Allocator,
upload_helper: UploadHelper,

pools: Pools,
descriptor_heap: DescriptorHeap,

destroy_queue: DestoyQueue,

debug_messenger: ?vk.DebugUtilsMessengerEXT,

frame_data: [root.frames_in_flight]FrameData,
frame_timeline_sem: vk.Semaphore,
current_frame: usize,

swapchain: Swapchain,
desired_extent: vk.Extent2D,

device_limits: vk.PhysicalDeviceLimits,

pass_time_samples: std.ArrayList(root.PassTime),

string_table: StringTable,

pub fn create(allocator: Allocator, window: WindowInterface, fb_size: [2]u32) !*Gpu {
    const self = try allocator.create(Gpu);
    self.* = undefined;
    self.allocator = allocator;

    self.base = .load(vkGetInstanceProcAddr);
    errdefer allocator.destroy(self);

    self.instance = try createInstance(allocator, self.base);
    errdefer destroyInstance(allocator, self.instance);

    const candidate = try selectPhysicalDevice(self.instance, allocator);
    self.physical_device = candidate.physical_device;
    self.device = try createDevice(self.instance, candidate, allocator);

    const device_props = self.instance.getPhysicalDeviceProperties(candidate.physical_device);
    log.info("GPU: {s}", .{device_props.device_name});

    self.device_limits = device_props.limits;

    if (is_debug) {
        const dbg_msg_info: vk.DebugUtilsMessengerCreateInfoEXT = .{
            .message_severity = .{
                .warning_bit_ext = true,
                .error_bit_ext = true,
            },
            .message_type = .{
                .validation_bit_ext = true,
            },
            .pfn_user_callback = debugCallback,
        };
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(
            &dbg_msg_info,
            null,
        );
    } else {
        self.debug_messenger = null;
    }

    self.queue = .{
        .handle = self.device.getDeviceQueue(candidate.queue_family, 0),
        .family = candidate.queue_family,
    };

    switch (window) {
        .wayland => |w| {
            self.surface = try self.instance.createWaylandSurfaceKHR(&.{
                .display = @ptrCast(w.display),
                .surface = @ptrCast(w.surface),
            }, null);
        },
        .glfw => |w| {
            if (w.create_surface_fn(self.instance.handle, w.window, null, &self.surface) != .success) {
                return error.SurfaceInitFailed;
            }
        },
    }

    errdefer self.instance.destroySurfaceKHR(self.surface, null);

    self.gpu_allocator = try .init(self);
    errdefer self.gpu_allocator.deinit();

    self.pools = try .init(allocator);
    errdefer self.pools.deinit();
    self.upload_helper = try .init(self);
    errdefer self.upload_helper.deinit();
    self.descriptor_heap = try .init(self, .{});
    errdefer self.descriptor_heap.deinit();
    self.destroy_queue = .init(self);
    errdefer self.destroy_queue.deinit();

    const num_frames = root.frames_in_flight;
    const initial_value: u64 = num_frames - 1;
    const timeline_info: vk.SemaphoreTypeCreateInfo = .{
        .semaphore_type = .timeline,
        .initial_value = initial_value,
    };
    const timeline_sem_info: vk.SemaphoreCreateInfo = .{
        .p_next = &timeline_info,
    };
    self.frame_timeline_sem = try self.device.createSemaphore(&timeline_sem_info, null);
    errdefer self.device.destroySemaphore(self.frame_timeline_sem, null);
    self.debugSetName(self.frame_timeline_sem, "frame_timeline");

    self.current_frame = 0;
    self.frame_data = undefined;
    for (0..num_frames) |i| {
        self.frame_data[i] = .{
            .frame_number = i,
            .enc = .init(self),
            .allocator = try .init(self),
        };
    }
    errdefer for (&self.frame_data) |*frame| {
        frame.allocator.deinit();
        frame.enc.deinit();
    };

    self.desired_extent = .{
        .width = fb_size[0],
        .height = fb_size[1],
    };
    self.swapchain = try .init(self, self.desired_extent);
    errdefer self.swapchain.deinit(self);

    log.info("Swapchain created: {d}x{d}, {s}", .{
        self.swapchain.extent.width,
        self.swapchain.extent.height,
        @tagName(self.swapchain.surfaceFormat()),
    });

    self.pass_time_samples = .empty;
    errdefer self.pass_time_samples.deinit(allocator);

    self.string_table = .init(allocator);

    return self;
}
pub fn destroy(self: *Gpu) void {
    self.waitForIdle() catch {};

    self.swapchain.deinit(self);

    for (&self.frame_data) |*frame| {
        frame.allocator.deinit();
        frame.enc.deinit();
    }

    self.device.destroySemaphore(self.frame_timeline_sem, null);

    self.upload_helper.deinit();

    self.descriptor_heap.deinit();
    self.pools.deinit();
    self.destroy_queue.deinit();
    self.instance.destroySurfaceKHR(self.surface, null);

    self.gpu_allocator.deinit();

    destroyDevice(self.allocator, self.device);
    if (self.debug_messenger) |msg| {
        self.instance.destroyDebugUtilsMessengerEXT(
            msg,
            null,
        );
    }
    destroyInstance(self.allocator, self.instance);

    self.pass_time_samples.deinit(self.allocator);
    self.string_table.deinit();
    self.allocator.destroy(self);
}

pub fn createBuffer(self: *Gpu, desc: *const root.BufferDesc) !Buffer {
    const handle = try self.pools.buffers.allocate();
    errdefer self.pools.buffers.release(handle);

    var vk_usage: vk.BufferUsageFlags = .{};
    if (desc.usage.vertex_buffer) {
        vk_usage.vertex_buffer_bit = true;
    }
    if (desc.usage.index_buffer) {
        vk_usage.index_buffer_bit = true;
    }
    if (desc.usage.uniform) {
        vk_usage.uniform_buffer_bit = true;
    }
    if (desc.usage.storage) {
        vk_usage.storage_buffer_bit = true;
    }
    if (desc.usage.indirect) {
        vk_usage.indirect_buffer_bit = true;
    }
    vk_usage.transfer_src_bit = true;
    vk_usage.transfer_dst_bit = true;
    vk_usage.shader_device_address_bit = true;

    const buffer_info: vk.BufferCreateInfo = .{
        .size = desc.size,
        .usage = vk_usage,
        .sharing_mode = .exclusive, // singlue queue for now
    };

    const vk_buffer, const allocation = try self.gpu_allocator.createBuffer(
        &buffer_info,
        desc.memory,
    );
    errdefer self.gpu_allocator.destroyBuffer(vk_buffer, allocation);

    if (desc.label) |label| {
        self.debugSetName(vk_buffer, label);
    }

    const allocation_info = self.gpu_allocator.allocationInfo(allocation);
    const mapped_data: ?[]u8 = if (allocation_info.mapped_data) |ptr|
        @as([*]u8, @ptrCast(ptr))[0..desc.size]
    else
        null;

    const address_info: vk.BufferDeviceAddressInfo = .{
        .buffer = vk_buffer,
    };

    const device_addr = self.device.getBufferDeviceAddress(&address_info);

    self.pools.buffers.set(handle, .{
        .buffer = vk_buffer,
        .allocation = allocation,
        .mapped_data = mapped_data,
        .device_addr = @enumFromInt(device_addr),
        .info = desc.*,
    });

    if (desc.usage.uniform) {
        self.descriptor_heap.putUniformBuffer(handle.index, vk_buffer, desc.size);
    }

    return handle;
}
pub fn releaseBuffer(self: *Gpu, handle: Buffer) void {
    if (self.pools.buffers.get(handle)) |buffer| {
        self.destroy_queue.push(.{ buffer.buffer, buffer.allocation });
        self.pools.buffers.release(handle);
    }
}
pub fn mappedData(self: *Gpu, handle: Buffer) []u8 {
    const mapped_data = self.pools.buffers.getField(handle, .mapped_data) orelse
        @panic("buffer not found");

    if (mapped_data == null) {
        @panic("buffer not mapped");
    }

    return mapped_data.?;
}
pub fn deviceAddress(self: *Gpu, handle: Buffer) root.DeviceAddress {
    return self.pools.buffers.getField(handle, .device_addr) orelse
        @panic("buffer not found");
}
pub fn tempAlloc(
    self: *Gpu,
    size: usize,
    comptime alignment: comptime_int,
) root.TempBytesAlign(alignment) {
    return self.frame_data[self.current_frame].allocator.allocate(size, alignment) catch {
        @panic("GPU temp buffer OOM");
    };
}
pub fn tempAllocTyped(self: *Gpu, Type: type) root.TempBytesTyped(Type) {
    const alloc = self.tempAlloc(@sizeOf(Type), @alignOf(Type));
    return .{
        .data = std.mem.bytesAsValue(Type, alloc.data),
        .device_addr = alloc.device_addr,
    };
}
pub fn createTexture(self: *Gpu, desc: *const root.TextureDesc) !Texture {
    const handle = try self.pools.textures.allocate();
    errdefer self.pools.textures.release(handle);

    var vk_usage: vk.ImageUsageFlags = .{
        .transfer_src_bit = true,
        .transfer_dst_bit = true,
    };
    if (desc.usage.sampled) {
        vk_usage.sampled_bit = true;
    }
    if (desc.usage.storage) {
        vk_usage.storage_bit = true;
    }
    if (desc.usage.color_attachment) {
        vk_usage.color_attachment_bit = true;
    }
    if (desc.usage.depth_stencil) {
        vk_usage.depth_stencil_attachment_bit = true;
    }

    const image_info: vk.ImageCreateInfo = .{
        .image_type = conv.vkImageType(desc.type),
        .format = conv.vkFormat(desc.format),
        .extent = .{
            .width = desc.size.width,
            .height = desc.size.height,
            .depth = desc.size.depth,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = vk_usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };

    const vk_image, const allocation = try self.gpu_allocator.createImage(
        &image_info,
    );
    errdefer self.gpu_allocator.destroyImage(vk_image, allocation);

    if (desc.label) |label| {
        self.debugSetName(vk_image, label);
    }

    self.pools.textures.set(handle, .{
        .image = vk_image,
        .allocation = allocation,
        .info = image_info,
    });

    return handle;
}
pub fn releaseTexture(self: *Gpu, handle: Texture) void {
    if (self.pools.textures.get(handle)) |texture| {
        self.destroy_queue.push(.{ texture.image, texture.allocation });
        self.pools.textures.release(handle);
    }
}

pub fn createTextureView(self: *Gpu, texture: Texture, desc: *const root.TextureViewDesc) !TextureView {
    const handle = try self.pools.texture_views.allocate();
    errdefer self.pools.texture_views.release(handle);

    const texture_entry = self.pools.textures.get(texture) orelse return error.InvalidTexture;

    const vk_format: vk.Format = if (desc.format == .undefined)
        texture_entry.info.format
    else
        conv.vkFormat(desc.format);

    const format = conv.fromVkformat(vk_format);

    var aspect_flags: vk.ImageAspectFlags = .{};
    if (conv.hasDepth(format)) {
        aspect_flags.depth_bit = true;
    }
    if (conv.hasStencil(format)) {
        aspect_flags.stencil_bit = true;
    }
    if (aspect_flags.toInt() == 0) {
        aspect_flags.color_bit = true;
    }

    const view_info: vk.ImageViewCreateInfo = .{
        .image = texture_entry.image,
        .view_type = conv.vkImageViewType(desc.type),
        .format = vk_format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = aspect_flags,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    const vk_view = try self.device.createImageView(&view_info, null);
    errdefer self.device.destroyImageView(vk_view, null);

    if (desc.label) |label| {
        self.debugSetName(vk_view, label);
    }

    self.pools.texture_views.set(handle, .{
        .view = vk_view,
        .info = .{
            .extent = texture_entry.info.extent,
            .storage = texture_entry.info.usage.storage_bit,
            .sampled = texture_entry.info.usage.sampled_bit,
        },
    });

    if (texture_entry.info.usage.storage_bit) {
        self.descriptor_heap.putStorageImageView(handle.index, vk_view);
    }
    if (texture_entry.info.usage.sampled_bit) {
        self.descriptor_heap.putSampledImageView(handle.index, vk_view);
    }

    return handle;
}
pub fn releaseTextureView(self: *Gpu, handle: TextureView) void {
    if (self.pools.texture_views.getField(handle, .view)) |view| {
        self.destroy_queue.push(view);
        self.pools.texture_views.release(handle);
    }
}

pub fn createSampler(self: *Gpu, desc: *const root.SamplerDesc) !Sampler {
    const handle = try self.pools.samplers.allocate();
    errdefer self.pools.samplers.release(handle);

    const sampler_info: vk.SamplerCreateInfo = .{
        .mag_filter = conv.vkFilter(desc.mag_filter),
        .min_filter = conv.vkFilter(desc.min_filter),
        .mipmap_mode = conv.vkSamplerMipmapMode(desc.mipmap_mode),
        .address_mode_u = conv.vkSamplerAddressMode(desc.address_mode_u),
        .address_mode_v = conv.vkSamplerAddressMode(desc.address_mode_v),
        .address_mode_w = conv.vkSamplerAddressMode(desc.address_mode_w),
        .mip_lod_bias = 0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 0,
        .compare_enable = vk.FALSE,
        .compare_op = .never,
        .min_lod = 0,
        .max_lod = std.math.floatMax(f32),
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = vk.FALSE,
    };

    const vk_sampler = try self.device.createSampler(&sampler_info, null);
    errdefer self.device.destroySampler(vk_sampler, null);

    if (desc.label) |label| {
        self.debugSetName(vk_sampler, label);
    }

    self.pools.samplers.set(handle, .{
        .sampler = vk_sampler,
    });

    self.descriptor_heap.putSampler(handle.index, vk_sampler);

    return handle;
}
pub fn releaseSampler(self: *Gpu, handle: Sampler) void {
    if (self.pools.samplers.getField(handle, .sampler)) |sampler| {
        self.destroy_queue.push(sampler);
        self.pools.samplers.release(handle);
    }
}

pub fn createShader(self: *Gpu, desc: *const root.ShaderDesc) !Shader {
    const handle = try self.pools.shaders.allocate();
    errdefer self.pools.shaders.release(handle);

    const vk_shader = try self.device.createShaderModule(
        &.{
            .code_size = desc.data.len,
            .p_code = @ptrCast(@alignCast(desc.data.ptr)),
        },
        null,
    );
    if (desc.label) |label| {
        self.debugSetName(vk_shader, label);
    }

    self.pools.shaders.set(handle, .{
        .module = vk_shader,
        .entry = desc.entry,
    });

    return handle;
}
pub fn releaseShader(self: *Gpu, handle: Shader) void {
    if (self.pools.shaders.getField(handle, .module)) |module| {
        self.destroy_queue.push(module);
        self.pools.shaders.release(handle);
    }
}

/// Replaces the given texture with the new texture
pub fn swapHandles(self: *Gpu, handle1: anytype, handle2: @TypeOf(handle1)) void {
    switch (@TypeOf(handle1)) {
        Texture => {
            self.pools.textures.swap(handle1, handle2);
        },
        TextureView => {
            self.pools.texture_views.swap(handle1, handle2);

            const view1 = self.pools.texture_views.get(handle1) orelse @panic("not found");
            const view2 = self.pools.texture_views.get(handle2) orelse @panic("not found");

            if (view1.info.storage) {
                self.descriptor_heap.putStorageImageView(handle1.index, view1.view);
            }
            if (view1.info.sampled) {
                self.descriptor_heap.putSampledImageView(handle1.index, view1.view);
            }

            if (view2.info.storage) {
                self.descriptor_heap.putStorageImageView(handle2.index, view2.view);
            }
            if (view2.info.sampled) {
                self.descriptor_heap.putSampledImageView(handle2.index, view2.view);
            }
        },
        else => @compileError("not implemented"),
    }
}

/// Reloads a shader, requires call to reloadPipelines for changes to actually
/// reach pipelines
pub fn reloadShader(self: *Gpu, handle: Shader, desc: *const root.ShaderDesc) !void {
    if (self.pools.shaders.getFieldPtr(handle, .module)) |module| {
        const vk_shader = try self.device.createShaderModule(
            &.{
                .code_size = desc.data.len,
                .p_code = @ptrCast(@alignCast(desc.data.ptr)),
            },
            null,
        );

        if (desc.label) |label| {
            self.debugSetName(vk_shader, label);
        }

        self.destroy_queue.push(module.*);
        module.* = vk_shader;
    } else {
        return error.ShaderNotFound;
    }
}

/// Reloads pipelines
/// TODO: Put this directly in reloadShader?
pub fn reloadPipelines(self: *Gpu) !void {
    log.debug("Reloading GPU pipelines", .{});

    var render_it = self.pools.render_pipelines.iterator();
    while (render_it.next()) |handle| {
        if (self.pools.render_pipelines.get(handle)) |info| {
            const new_pipeline = try self.createVkRenderPipeline(
                info.layout,
                &info.desc,
            );

            self.destroy_queue.push(info.pipeline);
            self.pools.render_pipelines.getFieldPtr(handle, .pipeline).?.* = new_pipeline;
        }
    }

    var compute_it = self.pools.compute_pipelines.iterator();
    while (compute_it.next()) |handle| {
        if (self.pools.compute_pipelines.get(handle)) |info| {
            const new_pipeline = try self.createVkComputePipeline(
                info.layout,
                &info.desc,
            );

            self.destroy_queue.push(info.pipeline);
            self.pools.compute_pipelines.getFieldPtr(handle, .pipeline).?.* = new_pipeline;
        }
    }
}

pub fn createRenderPipeline(
    self: *Gpu,
    desc: *const root.RenderPipelineDesc,
) !RenderPipeline {
    const handle = try self.pools.render_pipelines.allocate();
    errdefer self.pools.render_pipelines.release(handle);

    const push_constant_range: vk.PushConstantRange = .{
        .stage_flags = .fromInt(0x7fff_ffff),
        .offset = 0,
        .size = desc.push_constant_size,
    };

    var set_layouts_buffer: [root.max_descriptor_sets]vk.DescriptorSetLayout = undefined;
    var set_layouts: std.ArrayList(vk.DescriptorSetLayout) = .initBuffer(&set_layouts_buffer);

    try set_layouts.appendBounded(self.descriptor_heap.layout);

    const vk_layout = try self.device.createPipelineLayout(&.{
        .set_layout_count = @intCast(set_layouts.items.len),
        .p_set_layouts = @ptrCast(set_layouts.items),
        .push_constant_range_count = if (desc.push_constant_size > 0) 1 else 0,
        .p_push_constant_ranges = if (desc.push_constant_size > 0)
            @ptrCast(&push_constant_range)
        else
            null,
    }, null);

    if (desc.label) |label| {
        self.debugSetName(vk_layout, label);
    }

    const vk_pipeline: vk.Pipeline = try self.createVkRenderPipeline(
        vk_layout,
        desc,
    );
    errdefer self.device.destroyPipeline(vk_pipeline, null);

    if (desc.label) |label| {
        self.debugSetName(vk_pipeline, label);
    }

    self.pools.render_pipelines.set(handle, .{
        .pipeline = vk_pipeline,
        .layout = vk_layout,
        .desc = desc.*,
    });

    return handle;
}
pub fn releaseRenderPipeline(self: *Gpu, handle: RenderPipeline) void {
    if (self.pools.render_pipelines.get(handle)) |pipeline| {
        self.destroy_queue.push(pipeline.pipeline);
        self.destroy_queue.push(pipeline.layout);
        self.pools.render_pipelines.release(handle);
    }
}

pub fn createComputePipeline(self: *Gpu, desc: *const root.ComputePipelineDesc) !ComputePipeline {
    const handle = try self.pools.compute_pipelines.allocate();
    errdefer self.pools.compute_pipelines.release(handle);

    const push_constant_range: vk.PushConstantRange = .{
        .stage_flags = .fromInt(0x7fff_ffff),
        .offset = 0,
        .size = desc.push_constant_size,
    };

    var set_layouts_buffer: [root.max_descriptor_sets]vk.DescriptorSetLayout = undefined;
    var set_layouts: std.ArrayList(vk.DescriptorSetLayout) = .initBuffer(&set_layouts_buffer);

    try set_layouts.appendBounded(self.descriptor_heap.layout);

    const vk_layout = try self.device.createPipelineLayout(&.{
        .set_layout_count = @intCast(set_layouts.items.len),
        .p_set_layouts = @ptrCast(set_layouts.items),
        .push_constant_range_count = if (desc.push_constant_size > 0) 1 else 0,
        .p_push_constant_ranges = if (desc.push_constant_size > 0)
            @ptrCast(&push_constant_range)
        else
            null,
    }, null);

    if (desc.label) |label| {
        self.debugSetName(vk_layout, label);
    }

    const vk_pipeline = try self.createVkComputePipeline(vk_layout, desc);
    errdefer self.device.destroyPipeline(vk_pipeline, null);

    if (desc.label) |label| {
        self.debugSetName(vk_pipeline, label);
    }

    self.pools.compute_pipelines.set(handle, .{
        .pipeline = vk_pipeline,
        .layout = vk_layout,
        .desc = desc.*,
    });

    return handle;
}
pub fn releaseComputePipeline(self: *Gpu, handle: ComputePipeline) void {
    if (self.pools.compute_pipelines.get(handle)) |pipeline| {
        self.destroy_queue.push(pipeline.pipeline);
        self.destroy_queue.push(pipeline.layout);
        self.pools.compute_pipelines.release(handle);
    }
}

pub fn uploadBuffer(self: *Gpu, handle: Buffer, data: []const u8) !void {
    try self.upload_helper.uploadBuffer(handle, data);
}

pub fn uploadTexture(self: *Gpu, handle: Texture, data: []const u8) !void {
    try self.upload_helper.uploadTexture(handle, data);
}

pub fn beginCommandEncoder(self: *Gpu) !*CommandEncoder {
    const enc = &self.frame_data[self.current_frame].enc;
    try enc.begin();
    return enc;
}

/// fb_size: Requested framebuffer size
pub fn beginFrame(self: *Gpu, fb_size: [2]u32) !root.Frame {
    const requested_extent: vk.Extent2D = .{
        .width = fb_size[0],
        .height = fb_size[1],
    };

    if (requested_extent.width != 0 and requested_extent.height != 0) {
        if (requested_extent.width != self.desired_extent.width or
            requested_extent.height != self.desired_extent.height)
        {
            self.desired_extent = requested_extent;
            self.swapchain.need_rebuild = true;
        }
    }

    if (self.swapchain.need_rebuild) {
        // Flush
        try self.device.deviceWaitIdle();

        self.swapchain.deinit(self);
        self.swapchain = try .init(self, self.desired_extent);
    }

    // Perform pending cleanup
    self.destroy_queue.update();

    var frame = &self.frame_data[self.current_frame];
    const wait_value = frame.frame_number;
    const wait_info: vk.SemaphoreWaitInfo = .{
        .semaphore_count = 1,
        .p_semaphores = &.{self.frame_timeline_sem},
        .p_values = &.{wait_value},
    };
    _ = try self.device.waitSemaphores(&wait_info, std.math.maxInt(u64));

    try self.swapchain.acquireNextImage(self);

    self.pass_time_samples.clearRetainingCapacity();
    try frame.enc.collectSamples(self.allocator, &self.pass_time_samples);

    // Free to free up resources released previously for this frame
    try frame.enc.reset();
    frame.allocator.reset();

    return .{
        .texture = self.swapchain.nextImage(),
        .view = self.swapchain.nextImageView(),
    };
}
pub fn submit(self: *Gpu, enc: *CommandEncoder) !void {
    // TODO: Now we assume only one submit per frame

    const frame = &self.frame_data[self.current_frame];

    const signal_frame_value = frame.frame_number + self.swapchain.framesInFlight();
    frame.frame_number = signal_frame_value;

    const wait_semaphores = [_]vk.SemaphoreSubmitInfo{
        .{
            .semaphore = self.swapchain.currentWaitSemaphore(),
            .value = 0,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .device_index = 0,
        },
    };
    const signal_semaphores = [_]vk.SemaphoreSubmitInfo{
        .{
            .semaphore = self.swapchain.currentSignalSemaphore(),
            .value = 0,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .device_index = 0,
        },
        .{
            .semaphore = self.frame_timeline_sem,
            .value = signal_frame_value,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .device_index = 0,
        },
    };
    const cb_info = [_]vk.CommandBufferSubmitInfo{
        .{
            .command_buffer = enc.cb,
            .device_mask = 0,
        },
    };

    const submit_info: vk.SubmitInfo2 = .{
        .wait_semaphore_info_count = wait_semaphores.len,
        .p_wait_semaphore_infos = @ptrCast(&wait_semaphores),
        .command_buffer_info_count = cb_info.len,
        .p_command_buffer_infos = @ptrCast(&cb_info),
        .signal_semaphore_info_count = signal_semaphores.len,
        .p_signal_semaphore_infos = @ptrCast(&signal_semaphores),
    };
    try self.device.queueSubmit2KHR(self.queue.handle, 1, &.{submit_info}, .null_handle);
}
pub fn present(self: *Gpu) !void {
    // TODO: Now we assume only one submit per frame
    try self.swapchain.present(self);

    // TODO: Where to put this?
    self.current_frame = (self.current_frame + 1) % self.swapchain.framesInFlight();
}

pub fn frameSize(self: *Gpu) root.Extent2D {
    return .{
        .width = self.swapchain.extent.width,
        .height = self.swapchain.extent.height,
    };
}
pub fn surfaceFormat(self: *Gpu) root.Format {
    return self.swapchain.surfaceFormat();
}

pub fn waitForIdle(self: *Gpu) !void {
    try self.device.deviceWaitIdle();
}

pub fn debugSetName(self: *Gpu, obj: anytype, name: [:0]const u8) void {
    if (!is_debug) return;

    // TODO: Disable in release?
    const object_type: vk.ObjectType = switch (@TypeOf(obj)) {
        vk.Instance => .instance,
        vk.PhysicalDevice => .physical_device,
        vk.Device => .device,
        vk.Queue => .queue,
        vk.Semaphore => .semaphore,
        vk.CommandBuffer => .command_buffer,
        vk.Fence => .fence,
        vk.DeviceMemory => .device_memory,
        vk.Buffer => .buffer,
        vk.Image => .image,
        vk.Event => .event,
        vk.QueryPool => .query_pool,
        vk.BufferView => .buffer_view,
        vk.ImageView => .image_view,
        vk.ShaderModule => .shader_module,
        vk.PipelineCache => .pipeline_cache,
        vk.PipelineLayout => .pipeline_layout,
        vk.RenderPass => .render_pass,
        vk.Pipeline => .pipeline,
        vk.DescriptorSetLayout => .descriptor_set_layout,
        vk.Sampler => .sampler,
        vk.DescriptorPool => .descriptor_pool,
        vk.DescriptorSet => .descriptor_set,
        vk.Framebuffer => .framebuffer,
        vk.CommandPool => .command_pool,
        else => @compileError("Unsupported type for debugSetName"),
    };

    const info: vk.DebugUtilsObjectNameInfoEXT = .{
        .object_type = object_type,
        .object_handle = @intFromEnum(obj),
        .p_object_name = name.ptr,
    };
    self.device.setDebugUtilsObjectNameEXT(&info) catch
        @panic("OOM");
}

const vk = @import("vulkan");

pub const Instance = vk.InstanceProxy;
pub const Device = vk.DeviceProxy;

fn hasExtension(available: []const vk.ExtensionProperties, ext: [*:0]const u8) bool {
    for (available) |a| {
        if (std.mem.eql(u8, std.mem.sliceTo(&a.extension_name, 0), std.mem.span(ext))) {
            return true;
        }
    }
    return false;
}

fn hasLayer(available: []const vk.LayerProperties, name: [*:0]const u8) bool {
    for (available) |layer| {
        if (std.mem.eql(u8, std.mem.sliceTo(&layer.layer_name, 0), std.mem.span(name))) {
            return true;
        }
    }
    return false;
}

fn createInstance(alloc: Allocator, base: vk.BaseWrapper) !Instance {
    const app_info = vk.ApplicationInfo{
        .p_application_name = "simeks-root",
        .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
        .p_engine_name = "simeks-root",
        .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
        .api_version = @bitCast(vk.API_VERSION_1_2),
    };

    const available = try base.enumerateInstanceExtensionPropertiesAlloc(null, alloc);
    defer alloc.free(available);

    var exts: std.ArrayList([*:0]const u8) = .empty;
    defer exts.deinit(alloc);

    assert(hasExtension(available, vk.extensions.khr_get_surface_capabilities_2.name));
    try exts.append(alloc, vk.extensions.khr_get_surface_capabilities_2.name);

    assert(hasExtension(available, vk.extensions.khr_surface.name));
    try exts.append(alloc, vk.extensions.khr_surface.name);

    switch (builtin.os.tag) {
        .linux => {
            const platform_exts = [_][*:0]const u8{
                vk.extensions.khr_wayland_surface.name,
                vk.extensions.khr_xlib_surface.name,
            };
            var platform_ext_added = false;
            for (platform_exts) |ext| {
                if (hasExtension(available, ext)) {
                    try exts.append(alloc, ext);
                    platform_ext_added = true;
                }
            }
            if (!platform_ext_added) {
                return error.SurfaceExtensionUnavailable;
            }
        },
        .windows => {
            assert(hasExtension(available, vk.extensions.khr_win_32_surface.name));
            try exts.append(alloc, vk.extensions.khr_win_32_surface.name);
        },
        .macos => {
            assert(hasExtension(available, vk.extensions.ext_metal_surface.name));
            try exts.append(alloc, vk.extensions.ext_metal_surface.name);
        },
        else => @compileError("not implemented"),
    }

    // MoltenVK
    var enumerate_portability_bit_khr: bool = false;
    if (builtin.os.tag == .macos) {
        try exts.append(alloc, vk.extensions.khr_portability_enumeration.name);
        enumerate_portability_bit_khr = true;
    }

    var layers: std.ArrayList([*:0]const u8) = .empty;
    defer layers.deinit(alloc);
    const available_layers = try base.enumerateInstanceLayerPropertiesAlloc(alloc);
    defer alloc.free(available_layers);

    if (use_validation_layer) {
        if (hasLayer(available_layers, "VK_LAYER_KHRONOS_validation")) {
            log.info("Vulkan: Validation layer enabled", .{});
            try layers.append(alloc, "VK_LAYER_KHRONOS_validation");
        } else {
            log.warn("Vulkan: Validation layer requested but not available", .{});
        }
    }

    if (is_debug) {
        if (hasExtension(available, vk.extensions.ext_debug_utils.name)) {
            try exts.append(alloc, vk.extensions.ext_debug_utils.name);
        }
    }

    const vk_instance = try base.createInstance(&.{
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(layers.items.len),
        .pp_enabled_layer_names = @ptrCast(layers.items),
        .enabled_extension_count = @intCast(exts.items.len),
        .pp_enabled_extension_names = @ptrCast(exts.items),
        .flags = .{
            .enumerate_portability_bit_khr = enumerate_portability_bit_khr,
        },
    }, null);

    const dispatch = try alloc.create(vk.InstanceWrapper);
    errdefer alloc.destroy(dispatch);

    dispatch.* = .load(
        vk_instance,
        base.dispatch.vkGetInstanceProcAddr.?,
    );

    const instance = Instance.init(vk_instance, dispatch);
    errdefer instance.destroyInstance(null);

    return instance;
}
fn destroyInstance(allocator: Allocator, instance: Instance) void {
    instance.destroyInstance(null);
    allocator.destroy(instance.wrapper);
}

const DeviceCandidate = struct {
    physical_device: vk.PhysicalDevice,
    queue_family: u32,
};

fn selectPhysicalDevice(
    instance: Instance,
    allocator: Allocator,
) !DeviceCandidate {
    const physical_devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(physical_devices);

    assert(physical_devices.len != 0);
    if (physical_devices.len == 0) {
        return error.NoSuitableDevice;
    }

    // TODO: Fix this, just picks first available device
    const physical_device = physical_devices[0];
    const queue_families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(
        physical_device,
        allocator,
    );
    defer allocator.free(queue_families);

    // Use graphics queue only
    var family_index: u32 = 0;
    for (0.., queue_families) |i, family| {
        if (family.queue_flags.graphics_bit) {
            family_index = @intCast(i);
            break;
        }
    }

    return .{
        .physical_device = physical_device,
        .queue_family = family_index,
    };
}

fn createDevice(instance: Instance, candidate: DeviceCandidate, allocator: Allocator) !Device {
    // TODO: Check features
    const shader_draw_parameters: vk.PhysicalDeviceShaderDrawParametersFeatures = .{
        .shader_draw_parameters = vk.TRUE,
    };
    const dynamic_rendering_feature: vk.PhysicalDeviceDynamicRenderingFeaturesKHR = .{
        .p_next = @constCast(&shader_draw_parameters),
        .dynamic_rendering = vk.TRUE,
    };
    const timeline_semaphore_feature: vk.PhysicalDeviceTimelineSemaphoreFeaturesKHR = .{
        .p_next = @constCast(&dynamic_rendering_feature),
        .timeline_semaphore = vk.TRUE,
    };
    const synchronization_2_feature: vk.PhysicalDeviceSynchronization2FeaturesKHR = .{
        .p_next = @constCast(&timeline_semaphore_feature),
        .synchronization_2 = vk.TRUE,
    };
    const descriptor_indexing_feature: vk.PhysicalDeviceDescriptorIndexingFeatures = .{
        .p_next = @constCast(&synchronization_2_feature),
        .descriptor_binding_storage_buffer_update_after_bind = vk.TRUE,
        .descriptor_binding_uniform_buffer_update_after_bind = vk.TRUE,
        .descriptor_binding_sampled_image_update_after_bind = vk.TRUE,
        .descriptor_binding_storage_image_update_after_bind = vk.TRUE,
        .descriptor_binding_partially_bound = vk.TRUE,
        .runtime_descriptor_array = vk.TRUE,
    };
    const buffer_device_address_features: vk.PhysicalDeviceBufferDeviceAddressFeatures = .{
        .p_next = @constCast(&descriptor_indexing_feature),
        .buffer_device_address = vk.TRUE,
    };

    const queue_priority: [1]f32 = .{1};
    const queue_info: vk.DeviceQueueCreateInfo = .{
        .queue_family_index = candidate.queue_family,
        .queue_count = 1,
        .p_queue_priorities = &queue_priority,
    };

    // TODO: Check extension availability
    var exts: std.ArrayList([*:0]const u8) = .empty;
    defer exts.deinit(allocator);

    const available = try instance.enumerateDeviceExtensionPropertiesAlloc(
        candidate.physical_device,
        null,
        allocator,
    );
    defer allocator.free(available);

    assert(hasExtension(available, vk.extensions.khr_swapchain.name));
    try exts.append(allocator, vk.extensions.khr_swapchain.name);
    assert(hasExtension(available, vk.extensions.khr_dynamic_rendering.name));
    try exts.append(allocator, vk.extensions.khr_dynamic_rendering.name);
    assert(hasExtension(available, vk.extensions.khr_format_feature_flags_2.name));
    try exts.append(allocator, vk.extensions.khr_format_feature_flags_2.name);

    // assert(hasExtension(available, vk.extensions.ext_swapchain_maintenance_1.name));
    // try exts.append(vk.extensions.ext_swapchain_maintenance_1.name);
    assert(hasExtension(available, vk.extensions.khr_synchronization_2.name));
    try exts.append(allocator, vk.extensions.khr_synchronization_2.name);

    assert(hasExtension(available, vk.extensions.khr_copy_commands_2.name));
    try exts.append(allocator, vk.extensions.khr_copy_commands_2.name);

    // Not available on MoltenVK :(
    // assert(hasExtension(available, vk.extensions.khr_maintenance_6.name));
    // try exts.append(vk.extensions.khr_maintenance_6.name);

    if (builtin.os.tag == .macos) {
        assert(hasExtension(available, vk.extensions.khr_portability_subset.name));
        try exts.append(allocator, vk.extensions.khr_portability_subset.name);
    }

    const features: vk.PhysicalDeviceFeatures = .{
        .shader_int_64 = vk.TRUE,
    };

    const device_info: vk.DeviceCreateInfo = .{
        .queue_create_info_count = 1,
        .p_queue_create_infos = @ptrCast(&queue_info),
        .enabled_extension_count = @intCast(exts.items.len),
        .pp_enabled_extension_names = @ptrCast(exts.items),
        .p_enabled_features = &features,
        .p_next = &buffer_device_address_features,
    };

    const vk_device = try instance.createDevice(candidate.physical_device, &device_info, null);

    const dispatch = try allocator.create(vk.DeviceWrapper);
    errdefer allocator.destroy(dispatch);
    dispatch.* = .load(vk_device, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);

    const device = Device.init(vk_device, dispatch);
    errdefer device.destroyDevice(null);

    return device;
}
fn destroyDevice(allocator: Allocator, device: Device) void {
    device.destroyDevice(null);
    allocator.destroy(device.wrapper);
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    if (data == null or data.?.p_message == null) return vk.FALSE;

    if (severity.error_bit_ext) {
        log.err("Vulkan: {s}", .{data.?.p_message.?});
    } else if (severity.warning_bit_ext) {
        log.warn("Vulkan: {s}", .{data.?.p_message.?});
    } else {
        log.info("Vulkan: {s}", .{data.?.p_message.?});
    }
    return vk.FALSE;
}

fn createVkRenderPipeline(
    self: *Gpu,
    vk_layout: vk.PipelineLayout,
    desc: *const root.RenderPipelineDesc,
) !vk.Pipeline {
    const vs = self.pools.shaders.get(desc.vertex_shader) orelse
        return error.InvalidVS;
    const fs = self.pools.shaders.get(desc.fragment_shader) orelse
        return error.InvalidFS;

    const stages: [2]vk.PipelineShaderStageCreateInfo = .{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vs.module,
            .p_name = vs.entry.ptr,
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = fs.module,
            .p_name = fs.entry.ptr,
        },
    };

    const vertex_input_state: vk.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = null,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = null,
    };
    const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };
    const viewport_state: vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .p_viewports = undefined,
        .scissor_count = 1,
        .p_scissors = undefined,
    };

    const raster_state: vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = conv.vkCullModeFlags(desc.cull_mode),
        .front_face = conv.vkFrontFace(desc.front_face),
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const ms_state = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 0,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    var attachments_buffer: [root.max_color_attachments]vk.PipelineColorBlendAttachmentState =
        undefined;
    var attachments: std.ArrayList(vk.PipelineColorBlendAttachmentState) =
        .initBuffer(&attachments_buffer);

    for (desc.color_attachments.slice()) |att| {
        attachments.appendBounded(.{
            .blend_enable = if (att.blend_enabled) vk.TRUE else vk.FALSE,
            .src_color_blend_factor = conv.vkBlendFactor(att.blend_color.src_factor),
            .dst_color_blend_factor = conv.vkBlendFactor(att.blend_color.dst_factor),
            .color_blend_op = conv.vkBlendOp(att.blend_color.op),
            .src_alpha_blend_factor = conv.vkBlendFactor(att.blend_alpha.src_factor),
            .dst_alpha_blend_factor = conv.vkBlendFactor(att.blend_alpha.dst_factor),
            .alpha_blend_op = conv.vkBlendOp(att.blend_alpha.op),
            .color_write_mask = conv.vkColorComponentFlags(att.write_mask),
        }) catch unreachable;
    }

    const color_blend_state: vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = vk.FALSE,
        .logic_op = .clear,
        .attachment_count = @intCast(attachments.items.len),
        .p_attachments = @ptrCast(attachments.items),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dyn = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state: vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dyn.len,
        .p_dynamic_states = @ptrCast(&dyn),
    };

    var attachment_formats_buffer: [root.max_color_attachments]vk.Format = undefined;
    var attachment_formats: std.ArrayList(vk.Format) =
        .initBuffer(&attachment_formats_buffer);

    for (desc.color_attachments.slice()) |att| {
        try attachment_formats.appendBounded(conv.vkFormat(att.format));
    }

    const use_depth_stencil = desc.depth_stencil.format != .undefined;
    var ds_state: vk.PipelineDepthStencilStateCreateInfo = .{
        .depth_test_enable = if (desc.depth_stencil.depth_test_enabled) vk.TRUE else vk.FALSE,
        .depth_write_enable = if (desc.depth_stencil.depth_write_enabled) vk.TRUE else vk.FALSE,
        .depth_compare_op = conv.vkCompareOp(desc.depth_stencil.depth_compare_op),
        // TODO:
        .depth_bounds_test_enable = vk.FALSE,
        .stencil_test_enable = vk.FALSE,
        .front = .{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .never,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .back = .{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .never,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .min_depth_bounds = 0,
        .max_depth_bounds = 0,
    };

    const dynamic_rendering_info: vk.PipelineRenderingCreateInfo = .{
        .view_mask = 0,
        .color_attachment_count = @intCast(attachment_formats.items.len),
        .p_color_attachment_formats = if (attachment_formats.items.len > 0)
            @ptrCast(attachment_formats.items)
        else
            null,
        .depth_attachment_format = conv.vkFormat(desc.depth_stencil.format),
        .stencil_attachment_format = .undefined, // TODO:
    };

    const pipeline_info: vk.GraphicsPipelineCreateInfo = .{
        .p_next = &dynamic_rendering_info,
        .stage_count = 2,
        .p_stages = @ptrCast(&stages),
        .p_vertex_input_state = &vertex_input_state,
        .p_input_assembly_state = &input_assembly,
        .p_tessellation_state = null,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &raster_state,
        .p_multisample_state = &ms_state,
        .p_depth_stencil_state = if (use_depth_stencil) &ds_state else null,
        .p_color_blend_state = &color_blend_state,
        .p_dynamic_state = &dynamic_state,
        .layout = vk_layout,
        .render_pass = .null_handle, // dynamic rendering extension
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try self.device.createGraphicsPipelines(
        .null_handle,
        1,
        @ptrCast(&pipeline_info),
        null,
        @ptrCast(&pipeline),
    );
    return pipeline;
}
fn createVkComputePipeline(
    self: *Gpu,
    vk_layout: vk.PipelineLayout,
    desc: *const root.ComputePipelineDesc,
) !vk.Pipeline {
    const cs = self.pools.shaders.get(desc.shader) orelse
        return error.InvalidVS;

    const pipeline_info: vk.ComputePipelineCreateInfo = .{
        .stage = .{
            .stage = .{ .compute_bit = true },
            .module = cs.module,
            .p_name = cs.entry.ptr,
        },
        .layout = vk_layout,
        .base_pipeline_index = 0,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try self.device.createComputePipelines(
        .null_handle,
        1,
        @ptrCast(&pipeline_info),
        null,
        @ptrCast(&pipeline),
    );

    return pipeline;
}
