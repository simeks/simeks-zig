//! Linear temp allocator for GPU
const std = @import("std");

const root = @import("root.zig");
const Gpu = @import("Gpu.zig");

// TODO: Make dynamic
const buffer_size = 64 * 1024 * 1024;

const GpuTempAllocator = @This();

ctx: *Gpu,
buffer: root.Buffer,
mapped: []u8,
device_address: root.DeviceAddress,
offset: usize,

pub fn init(ctx: *Gpu) !GpuTempAllocator {
    const buffer = try ctx.createBuffer(&.{
        .label = "temp",
        .size = buffer_size,
        .usage = .{},
        .memory = .cpu_write,
    });
    return .{
        .ctx = ctx,
        .buffer = buffer,
        .mapped = ctx.mappedData(buffer),
        .device_address = ctx.deviceAddress(buffer),
        .offset = 0,
    };
}
pub fn deinit(self: *GpuTempAllocator) void {
    self.ctx.releaseBuffer(self.buffer);
}
pub fn reset(self: *GpuTempAllocator) void {
    self.offset = 0;
}
pub fn allocate(
    self: *GpuTempAllocator,
    size: usize,
    comptime alignment: comptime_int,
) !root.TempBytesAlign(alignment) {
    const offset = std.mem.alignForward(usize, self.offset, alignment);
    if (offset + size > buffer_size) {
        return error.OutOfMemory;
    }
    self.offset = offset + size;
    return .{
        .data = @alignCast(self.mapped[offset..self.offset]),
        .device_addr = self.device_address.offset(@intCast(offset)),
    };
}
