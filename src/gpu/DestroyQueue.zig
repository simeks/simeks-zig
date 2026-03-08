/// Tracking resource pending to be destroyed
const std = @import("std");
const log = std.log;

const vk = @import("vulkan");

const root = @import("root.zig");
const Deque = @import("core").Deque;

const Gpu = @import("Gpu.zig");
const vma = @import("vma.zig");

const DestroyQueue = @This();

const Resource = union(enum) {
    buffer: struct { vk.Buffer, vma.Allocation },
    image: struct { vk.Image, vma.Allocation },
    acceleration_structure: struct { vk.AccelerationStructureKHR, vk.Buffer, vma.Allocation },
    image_view: vk.ImageView,
    sampler: vk.Sampler,
    shader: vk.ShaderModule,
    pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    descriptor_set_layout: vk.DescriptorSetLayout,
};

ctx: *Gpu,
queue: Deque(struct { u64, Resource }),
frame_num: u64 = 0,

pub fn init(ctx: *Gpu) DestroyQueue {
    return .{
        .ctx = ctx,
        .queue = .init(ctx.allocator),
    };
}
pub fn deinit(self: *DestroyQueue) void {
    self.destroyAll();
    self.queue.deinit();
}
/// Queue resource for deletion
pub fn push(self: *DestroyQueue, resource: anytype) void {
    const res: Resource = switch (@TypeOf(resource)) {
        struct { vk.Buffer, vma.Allocation } => .{ .buffer = resource },
        struct { vk.Image, vma.Allocation } => .{ .image = resource },
        struct { vk.AccelerationStructureKHR, vk.Buffer, vma.Allocation } => .{ .acceleration_structure = resource },
        vk.ImageView => .{ .image_view = resource },
        vk.Sampler => .{ .sampler = resource },
        vk.ShaderModule => .{ .shader = resource },
        vk.Pipeline => .{ .pipeline = resource },
        vk.PipelineLayout => .{ .pipeline_layout = resource },
        else => @compileError("Invalid resource type " ++ @typeName(@TypeOf(resource))),
    };
    self.queue.pushBack(.{ self.frame_num, res }) catch @panic("Out of memory");
}
/// Advances frame counter and destroys resources ready to be destroyed
pub fn update(self: *DestroyQueue) void {
    while (self.queue.front()) |item| {
        const frame, const resource = item;
        if (frame + root.frames_in_flight < self.frame_num) {
            _ = self.queue.popFront();
            self.destroy(resource);
        } else {
            break;
        }
    }
    self.frame_num += 1;
}
fn destroy(self: *DestroyQueue, resource: Resource) void {
    switch (resource) {
        .buffer => |res| self.ctx.gpu_allocator.destroyBuffer(res.@"0", res.@"1"),
        .image => |res| self.ctx.gpu_allocator.destroyImage(res.@"0", res.@"1"),
        .acceleration_structure => |res| {
            self.ctx.device.destroyAccelerationStructureKHR(res.@"0", null);
            self.ctx.gpu_allocator.destroyBuffer(res.@"1", res.@"2");
        },
        .image_view => |res| self.ctx.device.destroyImageView(res, null),
        .sampler => |res| self.ctx.device.destroySampler(res, null),
        .shader => |res| self.ctx.device.destroyShaderModule(res, null),
        .pipeline => |res| self.ctx.device.destroyPipeline(res, null),
        .pipeline_layout => |res| self.ctx.device.destroyPipelineLayout(res, null),
        .descriptor_set_layout => |res| self.ctx.device.destroyDescriptorSetLayout(res, null),
    }
}
/// Destroys all queued resources immediately
fn destroyAll(self: *DestroyQueue) void {
    while (self.queue.popFront()) |item| {
        self.destroy(item.@"1");
    }
}
