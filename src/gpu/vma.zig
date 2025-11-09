const std = @import("std");
const assert = std.debug.assert;

const vma = @import("vma");
const vk = @import("vulkan");

const root = @import("root.zig");
const Gpu = @import("Gpu.zig");

pub const max_memory_heaps = vma.VK_MAX_MEMORY_HEAPS;

pub const Allocation = vma.VmaAllocation;

pub const AllocationInfo = extern struct {
    memory_type: u32,
    device_memory: vk.DeviceMemory,
    offset: vk.DeviceSize,
    size: vk.DeviceSize,
    mapped_data: ?*anyopaque,
    user_data: ?*anyopaque,
    name: [*c]const u8,
};

pub const HeapStats = extern struct {
    usage: vma.VkDeviceSize,
    budget: vma.VkDeviceSize,
};

pub const Allocator = struct {
    allocator: vma.VmaAllocator,

    pub fn init(ctx: *Gpu) !Allocator {
        const vma_funcs: vma.VmaVulkanFunctions = .{
            .vkGetInstanceProcAddr = @ptrCast(ctx.base.dispatch.vkGetInstanceProcAddr),
            .vkGetDeviceProcAddr = @ptrCast(ctx.instance.wrapper.dispatch.vkGetDeviceProcAddr),
        };

        const vma_allocator_info: vma.VmaAllocatorCreateInfo = .{
            .physicalDevice = @ptrFromInt(@intFromEnum(ctx.physical_device)),
            .device = @ptrFromInt(@intFromEnum(ctx.device.handle)),
            .instance = @ptrFromInt(@intFromEnum(ctx.instance.handle)),
            .pVulkanFunctions = &vma_funcs,
            .flags = vma.VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT,
        };

        var allocator: vma.VmaAllocator = undefined;
        const res = vma.vmaCreateAllocator(&vma_allocator_info, &allocator);
        if (res != vma.VK_SUCCESS) {
            return error.VmaInitFailed;
        }
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: Allocator) void {
        vma.vmaDestroyAllocator(self.allocator);
    }
    pub fn createBuffer(
        self: Allocator,
        buffer_info: *const vk.BufferCreateInfo,
        memory_type: root.MemoryType,
    ) !struct { vk.Buffer, Allocation } {
        // https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/usage_patterns.html

        const flags: vma.VmaAllocationCreateFlags = switch (memory_type) {
            .gpu_only => vma.VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT,
            .cpu_write => vma.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT |
                vma.VMA_ALLOCATION_CREATE_MAPPED_BIT,
            .cpu_read => vma.VMA_ALLOCATION_CREATE_MAPPED_BIT |
                vma.VMA_ALLOCATION_CREATE_MAPPED_BIT,
        };

        const allocation_create_info: vma.VmaAllocationCreateInfo = .{
            .usage = vma.VMA_MEMORY_USAGE_AUTO,
            .flags = flags,
        };

        var buffer: vk.Buffer = undefined;
        var allocation: vma.VmaAllocation = undefined;
        const res = vma.vmaCreateBuffer(
            self.allocator,
            @ptrCast(buffer_info),
            &allocation_create_info,
            @ptrCast(&buffer),
            &allocation,
            null,
        );
        if (res != vma.VK_SUCCESS) {
            return error.VmaCreateBufferFailed;
        }
        return .{ buffer, allocation };
    }
    pub fn destroyBuffer(
        self: Allocator,
        buffer: vk.Buffer,
        allocation: Allocation,
    ) void {
        vma.vmaDestroyBuffer(
            self.allocator,
            @ptrFromInt(@intFromEnum(buffer)),
            allocation,
        );
    }
    pub fn createImage(
        self: Allocator,
        image_info: *const vk.ImageCreateInfo,
    ) !struct { vk.Image, Allocation } {
        const flags = vma.VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT;
        const allocation_create_info: vma.VmaAllocationCreateInfo = .{
            .usage = vma.VMA_MEMORY_USAGE_AUTO,
            .flags = flags,
        };

        var image: vk.Image = undefined;
        var allocation: vma.VmaAllocation = undefined;

        const res = vma.vmaCreateImage(
            self.allocator,
            @ptrCast(image_info),
            @ptrCast(&allocation_create_info),
            @ptrCast(&image),
            &allocation,
            null,
        );

        if (res != vma.VK_SUCCESS) {
            return error.VmaCreateImageFailed;
        }
        return .{ image, allocation };
    }
    pub fn destroyImage(
        self: Allocator,
        image: vk.Image,
        allocation: Allocation,
    ) void {
        vma.vmaDestroyImage(
            self.allocator,
            @ptrFromInt(@intFromEnum(image)),
            allocation,
        );
    }

    pub fn allocationInfo(self: Allocator, allocation: Allocation) AllocationInfo {
        var allocation_info: AllocationInfo = undefined;
        vma.vmaGetAllocationInfo(self.allocator, allocation, @ptrCast(&allocation_info));
        return allocation_info;
    }

    pub fn getHeapBudgetStats(self: Allocator, budgets: []?HeapStats) void {
        var vma_budgets: [vma.VK_MAX_MEMORY_HEAPS]vma.VmaBudget = std.mem.zeroes(
            [vma.VK_MAX_MEMORY_HEAPS]vma.VmaBudget,
        );
        vma.vmaGetHeapBudgets(self.allocator, &vma_budgets);

        assert(budgets.len == vma.VK_MAX_MEMORY_HEAPS);

        for (0.., budgets) |i, *b| {
            if (vma_budgets[i].budget > 0) {
                b.* = .{
                    .usage = vma_budgets[i].usage,
                    .budget = vma_budgets[i].budget,
                };
            } else {
                b.* = null;
            }
        }
    }
};
