const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const vk = @import("vulkan");

const root = @import("root.zig");
const Gpu = @import("Gpu.zig");

const Swapchain = @This();

const FrameSemaphores = struct {
    image_available: vk.Semaphore,
    render_finished: vk.Semaphore,

    pub fn init(ctx: *Gpu) !FrameSemaphores {
        const image_available = try ctx.device.createSemaphore(&.{}, null);
        errdefer ctx.device.destroySemaphore(image_available, null);

        const render_finished = try ctx.device.createSemaphore(&.{}, null);
        errdefer ctx.device.destroySemaphore(render_finished, null);

        return .{
            .image_available = image_available,
            .render_finished = render_finished,
        };
    }
    pub fn deinit(self: FrameSemaphores, ctx: *Gpu) void {
        ctx.device.destroySemaphore(self.image_available, null);
        ctx.device.destroySemaphore(self.render_finished, null);
    }
};

allocator: Allocator,

handle: vk.SwapchainKHR,
images: []root.Texture,
views: []root.TextureView,
semaphores: []FrameSemaphores,
current_frame: usize = 0,
next_image: usize = 0,
need_rebuild: bool = false,
extent: vk.Extent2D,
surface_format: vk.SurfaceFormatKHR,

pub fn init(ctx: *Gpu, extent: vk.Extent2D) !Swapchain {
    const caps = try ctx.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
        ctx.physical_device,
        ctx.surface,
    );

    const surface_formats = try ctx.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
        ctx.physical_device,
        ctx.surface,
        ctx.allocator,
    );
    defer ctx.allocator.free(surface_formats);

    const present_modes = try ctx.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
        ctx.physical_device,
        ctx.surface,
        ctx.allocator,
    );
    defer ctx.allocator.free(present_modes);

    const surface_format = selectSwapSurfaceFormat(surface_formats);
    // TODO: V-sync
    const present_mode = selectSwapPresentMode(present_modes, true);

    const actual_extent: vk.Extent2D = if (caps.current_extent.width != 0xFFFF_FFFF)
        caps.current_extent
    else
        .{
            .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };

    var num_frames = @max(root.frames_in_flight, caps.min_image_count);
    // 0 means no upper limit
    if (caps.max_image_count != 0) {
        num_frames = @min(num_frames, caps.max_image_count);
    }

    const swapchain_info: vk.SwapchainCreateInfoKHR = .{
        .surface = ctx.surface,
        .min_image_count = num_frames,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{
            .color_attachment_bit = true,
        },
        .image_sharing_mode = .exclusive,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
        // TODO: We should probably use use this
        // .old_swapchain = .null_handle,
    };
    const swapchain = try ctx.device.createSwapchainKHR(&swapchain_info, null);

    const swapchain_images = try ctx.device.getSwapchainImagesAllocKHR(swapchain, ctx.allocator);
    defer ctx.allocator.free(swapchain_images);

    assert(swapchain_images.len == num_frames);
    const images = try ctx.allocator.alloc(root.Texture, num_frames);
    errdefer {
        for (images) |im| {
            ctx.pools.textures.release(im);
        }
        ctx.allocator.free(images);
    }

    const views = try ctx.allocator.alloc(root.TextureView, num_frames);
    errdefer {
        for (views) |view| {
            if (ctx.pools.texture_views.getField(view, .view)) |vk_view| {
                ctx.device.destroyImageView(vk_view, null);
            }
            ctx.pools.texture_views.release(view);
        }
        ctx.allocator.free(views);
    }

    if (builtin.mode == .Debug) {
        for (swapchain_images) |image| {
            ctx.debugSetName(image, "swapchain");
        }
    }

    for (0.., swapchain_images) |i, image| {
        const tex_handle = try ctx.pools.textures.allocate();
        ctx.pools.textures.set(tex_handle, .{
            .image = image,
            .allocation = null,
            .info = .{
                .image_type = .@"2d",
                .format = surface_format.format,
                .extent = .{
                    .width = actual_extent.width,
                    .height = actual_extent.height,
                    .depth = 1,
                },
                .mip_levels = 1,
                .array_layers = 1,
                .samples = .{},
                .tiling = .optimal,
                .usage = .{},
                .sharing_mode = .exclusive,
                .initial_layout = .undefined,
            },
        });
        images[i] = tex_handle;

        const view_info: vk.ImageViewCreateInfo = .{
            .image = image,
            .view_type = .@"2d",
            .format = surface_format.format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const view = try ctx.device.createImageView(&view_info, null);

        const view_handle = try ctx.pools.texture_views.allocate();
        ctx.pools.texture_views.set(view_handle, .{
            .view = view,
            .info = .{
                .extent = .{
                    .width = actual_extent.width,
                    .height = actual_extent.height,
                    .depth = 1,
                },
                .storage = false,
                .sampled = false,
            },
        });
        views[i] = view_handle;
    }

    // TODO: Complains about host_transfer not set, but not allowed to set that on the swapchain?
    assert(swapchain_images.len <= 4);
    var transitions_buffer: [4]vk.HostImageLayoutTransitionInfoEXT = undefined;
    var transitions: std.ArrayList(vk.HostImageLayoutTransitionInfoEXT) = .initBuffer(&transitions_buffer);

    for (swapchain_images) |image| {
        transitions.appendBounded(.{
            .image = image,
            .old_layout = .undefined,
            .new_layout = .present_src_khr,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }) catch @panic("oom");
    }

    const semaphores = try ctx.allocator.alloc(FrameSemaphores, num_frames);
    errdefer {
        for (semaphores) |sem| {
            sem.deinit(ctx);
        }
        ctx.allocator.free(semaphores);
    }

    for (0..images.len) |i| {
        semaphores[i] = try .init(ctx);
    }

    return .{
        .allocator = ctx.allocator,
        .handle = swapchain,
        .images = images,
        .views = views,
        .semaphores = semaphores,
        .extent = actual_extent,
        .surface_format = surface_format,
    };
}
pub fn deinit(self: Swapchain, ctx: *Gpu) void {
    for (self.views) |view| {
        if (ctx.pools.texture_views.getField(view, .view)) |vk_view| {
            ctx.device.destroyImageView(vk_view, null);
        }
        ctx.pools.texture_views.release(view);
    }
    for (self.images) |image| {
        ctx.pools.textures.release(image);
    }

    ctx.device.destroySwapchainKHR(self.handle, null);
    self.allocator.free(self.views);
    self.allocator.free(self.images);

    for (self.semaphores) |sem| {
        sem.deinit(ctx);
    }
    self.allocator.free(self.semaphores);
}
pub fn framesInFlight(self: Swapchain) usize {
    return self.images.len;
}
pub fn currentWaitSemaphore(self: Swapchain) vk.Semaphore {
    return self.semaphores[self.current_frame].image_available;
}
pub fn currentSignalSemaphore(self: Swapchain) vk.Semaphore {
    return self.semaphores[self.current_frame].render_finished;
}
pub fn nextImage(self: Swapchain) root.Texture {
    return self.images[self.next_image];
}
pub fn nextImageView(self: Swapchain) root.TextureView {
    return self.views[self.next_image];
}
pub fn acquireNextImage(self: *Swapchain, ctx: *Gpu) !void {
    assert(!self.need_rebuild);

    const sema = self.semaphores[self.current_frame];
    // TODO: Deal with suboptimal?
    const res = ctx.device.acquireNextImageKHR(
        self.handle,
        std.math.maxInt(u64),
        sema.image_available,
        .null_handle,
    ) catch |err| switch (err) {
        error.OutOfDateKHR => {
            self.need_rebuild = true;
            return;
        },
        else => return err,
    };
    self.next_image = res.image_index;
}
pub fn present(self: *Swapchain, ctx: *Gpu) !void {
    const sema = self.semaphores[self.current_frame];

    const image_index: u32 = @intCast(self.next_image);
    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &.{sema.render_finished},
        .swapchain_count = 1,
        .p_swapchains = &.{self.handle},
        .p_image_indices = &.{image_index},
    };

    _ = ctx.device.queuePresentKHR(ctx.queue.handle, &present_info) catch |err| switch (err) {
        error.OutOfDateKHR => {
            self.need_rebuild = true;
        },
        else => return err,
    };
    self.current_frame = (self.current_frame + 1) % self.images.len;
}
pub fn surfaceFormat(self: *Swapchain) root.Format {
    return switch (self.surface_format.format) {
        .b8g8r8a8_unorm => .bgra8_unorm,
        .r8g8b8a8_unorm => .rgba8_unorm,
        else => @panic("Unknown format"),
    };
}

fn selectSwapSurfaceFormat(
    formats: []const vk.SurfaceFormatKHR,
) vk.SurfaceFormatKHR {
    assert(formats.len > 0);
    if (formats.len == 1 and formats[0].format == .undefined) {
        return .{
            .format = .b8g8r8a8_unorm,
            .color_space = .srgb_nonlinear_khr,
        };
    }

    const preferred_formats = [_]vk.SurfaceFormatKHR{
        vk.SurfaceFormatKHR{
            .format = .b8g8r8a8_unorm,
            .color_space = .srgb_nonlinear_khr,
        },
        vk.SurfaceFormatKHR{
            .format = .r8g8b8a8_unorm,
            .color_space = .srgb_nonlinear_khr,
        },
    };

    for (preferred_formats) |preferred_format| {
        for (formats) |format| {
            if (preferred_format.format == format.format and
                preferred_format.color_space == format.color_space)
            {
                return format;
            }
        }
    }
    return formats[0];
}
fn selectSwapPresentMode(modes: []const vk.PresentModeKHR, vsync: bool) vk.PresentModeKHR {
    if (vsync) {
        return .fifo_khr;
    }

    var mailbox = false;
    var immediate = false;

    for (modes) |mode| {
        if (mode == .mailbox_khr) mailbox = true;
        if (mode == .immediate_khr) immediate = true;
    }

    if (mailbox) return .mailbox_khr;
    if (immediate) return .immediate_khr;

    return .fifo_khr;
}
