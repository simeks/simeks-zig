//! Offset allocator based on https://github.com/sebbbi/OffsetAllocator/

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const max_allocs = 128 * 1024;
const num_top_bins = 32;
const bins_per_leaf = 8;
const top_bins_index_shift = 3;
const leaf_bins_index_mask = 0x7;
const num_leaf_bins = num_top_bins * bins_per_leaf;

const mantissa_bits = 3;
const mantissa_value = 1 << mantissa_bits;
const mantissa_mask = mantissa_value - 1;

pub const NodeIndex = enum(u32) {
    unused = 0xffff_ffff,
    _,
};
pub const Allocation = struct {
    offset: u32,
    metadata: NodeIndex,
};

pub const StorageReport = struct {
    total_free_space: u32,
    largest_free_region: u32,
};

pub const StorageReportFull = struct {
    const Region = struct {
        size: u32,
        count: u32,
    };

    free_regions: Region[num_leaf_bins],
};

const Node = struct {
    offset: u32 = 0,
    size: u32 = 0,
    bin_prev: NodeIndex = .unused,
    bin_next: NodeIndex = .unused,
    neighbor_prev: NodeIndex = .unused,
    neighbor_next: NodeIndex = .unused,
    used: bool = false,
};

const OffsetAllocator = @This();

size: u32,
free_storage: u32,

used_bins_top: u32,
used_bins: [num_top_bins]u8,
bin_indices: [num_leaf_bins]NodeIndex,

nodes: []Node,
free_nodes: []NodeIndex,
free_offset: u32,

pub fn init(allocator: Allocator, size: usize) !OffsetAllocator {
    const nodes = try allocator.alloc(Node, max_allocs);
    const free_nodes = try allocator.alloc(NodeIndex, max_allocs);

    for (0..max_allocs) |i| {
        nodes[i] = .{};
        free_nodes[i] = @enumFromInt(max_allocs - i - 1);
    }

    var self: OffsetAllocator = .{
        .size = @intCast(size),
        .free_storage = 0,
        .used_bins_top = 0,
        .used_bins = @splat(0),
        .bin_indices = @splat(.unused),
        .nodes = nodes,
        .free_nodes = free_nodes,
        .free_offset = max_allocs - 1,
    };

    // Start state: Whole storage as one big node
    // Algorithm will split remainders and push them back as smaller nodes
    _ = self.insertNodeIntoBin(self.size, 0);
    return self;
}
pub fn deinit(self: *OffsetAllocator, allocator: Allocator) void {
    allocator.free(self.nodes);
    allocator.free(self.free_nodes);
}

pub fn reset(self: *OffsetAllocator) void {
    // Reset all nodes to initial state
    for (0..max_allocs) |i| {
        self.nodes[i] = .{};
        self.free_nodes[i] = @enumFromInt(max_allocs - i - 1);
    }

    // Reset allocator state
    self.free_storage = 0;
    self.used_bins_top = 0;
    @memset(&self.used_bins, 0);
    @memset(&self.bin_indices, .unused);
    self.free_offset = max_allocs - 1;

    // Start state: Whole storage as one big node
    // Algorithm will split remainders and push them back as smaller nodes
    _ = self.insertNodeIntoBin(self.size, 0);
}

pub fn allocate(self: *OffsetAllocator, size: u32) !Allocation {
    if (self.free_offset == 0) {
        return error.OutOfMemory;
    }

    // Round up to bin index to ensure that alloc >= bin
    // Gives us min bin index that fits the size
    const min_bin_index = uintToFloatRoundUp(size);

    const min_top_bin_index: u32 = min_bin_index >> top_bins_index_shift;
    const min_leaf_bin_index: u32 = min_bin_index & leaf_bins_index_mask;

    var top_bin_index: u32 = @intCast(min_top_bin_index);
    var leaf_bin_index: ?u32 = null;

    // If top bin exists, scan its leaf bin. This can fail.
    if ((self.used_bins_top & (@as(u32, 1) << @intCast(top_bin_index))) != 0) {
        leaf_bin_index = findLowestSetBitAfter(self.used_bins[top_bin_index], min_leaf_bin_index);
    }

    if (leaf_bin_index == null) {
        top_bin_index = findLowestSetBitAfter(self.used_bins_top, min_top_bin_index + 1) orelse {
            return error.OutOfMemory;
        };

        // All leaf bins here fit the alloc, since the top bin was rounded up. Start
        //  leaf search from bit 0.
        // NOTE: This search can't fail since at least one leaf bit was set because
        //  the top bit was set.
        leaf_bin_index = @ctz(self.used_bins[top_bin_index]);
    }

    const bin_index: u32 = (top_bin_index << top_bins_index_shift) | leaf_bin_index.?;

    // Pop the top node of the bin. Bin top = node.next
    const node_index: NodeIndex = self.bin_indices[bin_index];
    const node = &self.nodes[@intFromEnum(node_index)];
    const node_total_size: u32 = node.size;
    node.size = size;
    node.used = true;
    self.bin_indices[bin_index] = node.bin_next;
    if (node.bin_next != .unused) {
        self.nodes[@intFromEnum(node.bin_next)].bin_prev = .unused;
    }
    self.free_storage -= node_total_size;

    // Bin empty?
    if (self.bin_indices[bin_index] == .unused) {
        // Remove a leaf bin mask bit
        self.used_bins[top_bin_index] &= ~(@as(u8, 1) << @intCast(leaf_bin_index.?));

        // All leaf bins empty?
        if (self.used_bins[top_bin_index] == 0) {
            // Remove a top bin mask bit
            self.used_bins_top &= ~(@as(u32, 1) << @intCast(top_bin_index));
        }
    }

    // Push back reminder N elements to a lower bin
    const reminder_size: u32 = node_total_size - size;
    if (reminder_size > 0) {
        const new_node_index = self.insertNodeIntoBin(reminder_size, node.offset + size);

        // Link nodes next to eachother so that we can merge them later if both are free.
        // And update the old next neighbor to point to the new node (in middle).
        if (node.neighbor_next != .unused) {
            self.nodes[@intFromEnum(node.neighbor_next)].neighbor_prev = new_node_index;
        }
        self.nodes[@intFromEnum(new_node_index)].neighbor_prev = node_index;
        self.nodes[@intFromEnum(new_node_index)].neighbor_next = node.neighbor_next;
        node.neighbor_next = new_node_index;
    }

    return .{ .offset = node.offset, .metadata = node_index };
}
pub fn free(self: *OffsetAllocator, allocation: Allocation) void {
    const node_index: NodeIndex = allocation.metadata;
    const node = &self.nodes[@intFromEnum(node_index)];

    // Check double delete
    assert(node.used == true);

    // Merge with neighbors
    var offset: u32 = node.offset;
    var size: u32 = node.size;

    if ((node.neighbor_prev != .unused) and
        (self.nodes[@intFromEnum(node.neighbor_prev)].used == false))
    {
        const prev_node = &self.nodes[@intFromEnum(node.neighbor_prev)];
        offset = prev_node.offset;
        size += prev_node.size;

        self.removeNodeFromBin(node.neighbor_prev);

        assert(prev_node.neighbor_next == node_index);
        node.neighbor_prev = prev_node.neighbor_prev;
    }

    if ((node.neighbor_next != .unused) and
        (self.nodes[@intFromEnum(node.neighbor_next)].used == false))
    {
        const next_node = &self.nodes[@intFromEnum(node.neighbor_next)];
        size += next_node.size;

        self.removeNodeFromBin(node.neighbor_next);

        assert(next_node.neighbor_prev == node_index);
        node.neighbor_next = next_node.neighbor_next;
    }

    const neighbor_next = node.neighbor_next;
    const neighbor_prev = node.neighbor_prev;

    self.free_offset += 1;
    self.free_nodes[self.free_offset] = node_index;

    const combined_node_index = self.insertNodeIntoBin(size, offset);

    if (neighbor_next != .unused) {
        self.nodes[@intFromEnum(combined_node_index)].neighbor_next = neighbor_next;
        self.nodes[@intFromEnum(neighbor_next)].neighbor_prev = combined_node_index;
    }
    if (neighbor_prev != .unused) {
        self.nodes[@intFromEnum(combined_node_index)].neighbor_prev = neighbor_prev;
        self.nodes[@intFromEnum(neighbor_prev)].neighbor_next = combined_node_index;
    }
}

fn insertNodeIntoBin(self: *OffsetAllocator, size: u32, offset: u32) NodeIndex {
    // Round down to bin index to ensure that bin >= alloc
    const bin_index: u32 = uintToFloatRoundDown(size);

    const top_bin_index: u32 = bin_index >> top_bins_index_shift;
    const leaf_bin_index: u32 = bin_index & leaf_bins_index_mask;

    // Bin was empty before?
    if (self.bin_indices[bin_index] == .unused) {
        // Set bin mask bits
        self.used_bins[top_bin_index] |= @as(u8, 1) << @intCast(leaf_bin_index);
        self.used_bins_top |= @as(u32, 1) << @intCast(top_bin_index);
    }

    // Take a freelist node and insert on top of the bin linked list (next = old top)
    const top_node_index: NodeIndex = self.bin_indices[bin_index];
    const node_index: NodeIndex = self.free_nodes[self.free_offset];
    self.free_offset -= 1;

    self.nodes[@intFromEnum(node_index)] = .{
        .offset = offset,
        .size = size,
        .bin_next = top_node_index,
    };
    if (top_node_index != .unused) {
        self.nodes[@intFromEnum(top_node_index)].bin_prev = node_index;
    }
    self.bin_indices[bin_index] = node_index;
    self.free_storage += size;

    return node_index;
}
fn removeNodeFromBin(self: *OffsetAllocator, node_index: NodeIndex) void {
    const node = &self.nodes[@intFromEnum(node_index)];
    if (node.bin_prev != .unused) {
        // Easy case: We have previous node, just remove this node from the middle of the list
        self.nodes[@intFromEnum(node.bin_prev)].bin_next = node.bin_next;
        if (node.bin_next != .unused) {
            self.nodes[@intFromEnum(node.bin_next)].bin_prev = node.bin_prev;
        }
    } else {
        // Hard case: We are the first node in a bin. Find the bin.

        // Round down to the bin index to ensure that bin >= alloc
        const bin_index: u32 = uintToFloatRoundDown(node.size);

        const top_bin_index: u32 = bin_index >> top_bins_index_shift;
        const leaf_bin_index: u32 = bin_index & leaf_bins_index_mask;

        self.bin_indices[bin_index] = node.bin_next;
        if (node.bin_next != .unused) {
            self.nodes[@intFromEnum(node.bin_next)].bin_prev = .unused;
        }

        // Bin empty?
        if (self.bin_indices[bin_index] == .unused) {
            // Remove a leaf bin mask bit
            self.used_bins[top_bin_index] &= ~(@as(u8, 1) << @intCast(leaf_bin_index));

            // All leaf bins empty
            if (self.used_bins[top_bin_index] == 0) {
                self.used_bins_top &= ~(@as(u32, 1) << @intCast(top_bin_index));
            }
        }
    }

    self.free_offset += 1;
    self.free_nodes[self.free_offset] = node_index;
    self.free_storage -= node.size;
}

pub fn storageReport(self: *const OffsetAllocator) StorageReport {
    var largest_free_region: u32 = 0;
    var free_storage: u32 = 0;

    // Out of allocations? -> Zero free space
    if (self.free_offset > 0) {
        free_storage = self.free_storage;
        if (self.used_bins_top != 0) {
            const top_bin_index: u32 = @as(u32, 31) - @clz(self.used_bins_top);
            const leaf_bin_index: u32 = @as(u32, 31) -
                @clz(@as(u32, @intCast(self.used_bins[top_bin_index])));
            largest_free_region = floatToUint(
                (top_bin_index << @intCast(top_bins_index_shift)) | leaf_bin_index,
            );
            assert(free_storage >= largest_free_region);
        }
    }

    return .{
        .total_free_space = free_storage,
        .largest_free_region = largest_free_region,
    };
}

pub fn storageReportFull(self: *const OffsetAllocator) StorageReportFull {
    var report: StorageReportFull = undefined;
    for (0..num_leaf_bins) |i| {
        var count: u32 = 0;
        var node_index: NodeIndex = self.bin_indices[i];
        while (node_index != .unused) {
            node_index = self.nodes[@intFromEnum(node_index)].bin_next;
            count += 1;
        }
        report.free_regions[i] = .{ .size = floatToUint(i), .count = count };
    }
    return report;
}

fn uintToFloatRoundUp(size: u32) u32 {
    var exp: u32 = 0;
    var mantissa: u32 = 0;

    if (size < mantissa_value) {
        mantissa = size;
    } else {
        const leading_zeros: u32 = @clz(size);
        const highest_set_bit: u32 = 31 - leading_zeros;

        const mantissa_start_bit = highest_set_bit - mantissa_bits;
        exp = mantissa_start_bit + 1;
        mantissa = (size >> @intCast(mantissa_start_bit)) & mantissa_mask;

        const low_bits_mask: u32 = (@as(u32, 1) << @intCast(mantissa_start_bit)) - 1;

        if ((size & low_bits_mask) != 0) {
            mantissa += 1;
        }
    }
    return (exp << mantissa_bits) + mantissa;
}
fn uintToFloatRoundDown(size: u32) u32 {
    var exp: u32 = 0;
    var mantissa: u32 = 0;

    if (size < mantissa_value) {
        mantissa = size;
    } else {
        const leading_zeros: u32 = @clz(size);
        const highest_set_bit: u32 = 31 - leading_zeros;

        const mantissa_start_bit: u32 = highest_set_bit - mantissa_bits;
        exp = mantissa_start_bit + 1;
        mantissa = (size >> @intCast(mantissa_start_bit)) & mantissa_mask;
    }
    return (exp << mantissa_bits) + mantissa;
}
fn floatToUint(value: u32) u32 {
    const exponent = value >> mantissa_bits;
    const mantissa = value & mantissa_mask;
    if (exponent == 0) return mantissa;
    return (mantissa | mantissa_value) << @intCast(exponent - 1);
}

/// Returns null if no bit found
fn findLowestSetBitAfter(bit_mask: u32, start_bit: u32) ?u32 {
    const mask_before_start: u32 = (@as(u32, 1) << @intCast(start_bit)) - 1;
    const mask_after_start: u32 = ~mask_before_start;
    const bits_after: u32 = bit_mask & mask_after_start;
    if (bits_after == 0) return null;
    return @ctz(bits_after);
}

const testing = std.testing;

test "uintToFloat" {
    // Denorms, exp=1 and exp=2 + mantissa = 0 are all precise.
    // NOTE: Assuming 8 value (3 bit) mantissa.
    // If this test fails, please change this assumption!
    const precise_number_count: u32 = 17;
    for (0..precise_number_count) |i| {
        const round_up = uintToFloatRoundUp(@intCast(i));
        const round_down = uintToFloatRoundDown(@intCast(i));
        try testing.expectEqual(i, round_up);
        try testing.expectEqual(i, round_down);
    }

    // Test some random picked numbers
    const NumberFloatUpDown = struct {
        number: u32,
        up: u32,
        down: u32,
    };

    const test_data = [_]NumberFloatUpDown{
        .{ .number = 17, .up = 17, .down = 16 },
        .{ .number = 118, .up = 39, .down = 38 },
        .{ .number = 1024, .up = 64, .down = 64 },
        .{ .number = 65536, .up = 112, .down = 112 },
        .{ .number = 529445, .up = 137, .down = 136 },
        .{ .number = 1048575, .up = 144, .down = 143 },
    };

    for (test_data) |v| {
        const round_up = uintToFloatRoundUp(v.number);
        const round_down = uintToFloatRoundDown(v.number);
        try testing.expectEqual(v.up, round_up);
        try testing.expectEqual(v.down, round_down);
    }
}

test "floatToUint" {
    // Denorms, exp=1 and exp=2 + mantissa = 0 are all precise.
    // NOTE: Assuming 8 value (3 bit) mantissa.
    // If this test fails, please change this assumption!
    const precise_number_count: u32 = 17;
    for (0..precise_number_count) |i| {
        const v = floatToUint(@intCast(i));
        try testing.expectEqual(i, v);
    }

    // Test that float->uint->float conversion is precise for all numbers
    // NOTE: Test values < 240. 240->4G = overflows 32 bit integer
    for (0..240) |i| {
        const v = floatToUint(@intCast(i));
        const round_up = uintToFloatRoundUp(v);
        const round_down = uintToFloatRoundDown(v);
        try testing.expectEqual(i, round_up);
        try testing.expectEqual(i, round_down);
    }
}

test "basic" {
    var allocator = try OffsetAllocator.init(testing.allocator, 1024 * 1024 * 256);
    defer allocator.deinit(testing.allocator);
    const a = try allocator.allocate(1337);
    defer allocator.free(a);
    try testing.expectEqual(0, a.offset);
}

test "allocate simple" {
    var allocator = try OffsetAllocator.init(testing.allocator, 1024 * 1024 * 256);
    defer allocator.deinit(testing.allocator);

    // Free merges neighbor empty nodes. Next allocation should also have offset = 0
    const a = try allocator.allocate(0);
    try testing.expectEqual(0, a.offset);

    const b = try allocator.allocate(1);
    try testing.expectEqual(0, b.offset);

    const c = try allocator.allocate(123);
    try testing.expectEqual(1, c.offset);

    const d = try allocator.allocate(1234);
    try testing.expectEqual(124, d.offset);

    allocator.free(a);
    allocator.free(b);
    allocator.free(c);
    allocator.free(d);

    // End: Validate that allocator has no fragmentation left. Should be 100% clean.
    const validate_all = try allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(0, validate_all.offset);
    allocator.free(validate_all);
}

test "allocate merge trivial" {
    var allocator = try OffsetAllocator.init(testing.allocator, 1024 * 1024 * 256);
    defer allocator.deinit(testing.allocator);

    // Free merges neighbor empty nodes. Next allocation should also have offset = 0
    const a = try allocator.allocate(1337);
    try testing.expectEqual(0, a.offset);
    allocator.free(a);

    const b = try allocator.allocate(1337);
    try testing.expectEqual(0, b.offset);
    allocator.free(b);

    // End: Validate that allocator has no fragmentation left. Should be 100% clean.
    const validate_all = try allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(0, validate_all.offset);
    allocator.free(validate_all);
}

test "allocate reuse trivial" {
    var allocator = try OffsetAllocator.init(testing.allocator, 1024 * 1024 * 256);
    defer allocator.deinit(testing.allocator);

    // Allocator should reuse node freed by A since the allocation C fits in the same bin (using pow2 size to be sure)
    const a = try allocator.allocate(1024);
    try testing.expectEqual(0, a.offset);

    const b = try allocator.allocate(3456);
    try testing.expectEqual(1024, b.offset);

    allocator.free(a);

    const c = try allocator.allocate(1024);
    try testing.expectEqual(0, c.offset);

    allocator.free(c);
    allocator.free(b);

    // End: Validate that allocator has no fragmentation left. Should be 100% clean.
    const validate_all = try allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(0, validate_all.offset);
    allocator.free(validate_all);
}

test "allocate reuse complex" {
    var allocator = try OffsetAllocator.init(testing.allocator, 1024 * 1024 * 256);
    defer allocator.deinit(testing.allocator);

    // Allocator should not reuse node freed by A since the allocation C doesn't fits in the same bin
    // However node D and E fit there and should reuse node from A
    const a = try allocator.allocate(1024);
    try testing.expectEqual(0, a.offset);

    const b = try allocator.allocate(3456);
    try testing.expectEqual(1024, b.offset);

    allocator.free(a);

    const c = try allocator.allocate(2345);
    try testing.expectEqual(1024 + 3456, c.offset);

    const d = try allocator.allocate(456);
    try testing.expectEqual(0, d.offset);

    const e = try allocator.allocate(512);
    try testing.expectEqual(456, e.offset);

    const report = allocator.storageReport();
    try testing.expectEqual(1024 * 1024 * 256 - 3456 - 2345 - 456 - 512, report.total_free_space);
    try testing.expect(report.largest_free_region != report.total_free_space);

    allocator.free(c);
    allocator.free(d);
    allocator.free(b);
    allocator.free(e);

    // End: Validate that allocator has no fragmentation left. Should be 100% clean.
    const validate_all = try allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(0, validate_all.offset);
    allocator.free(validate_all);
}

test "allocate zero fragmentation" {
    var allocator = try OffsetAllocator.init(testing.allocator, 1024 * 1024 * 256);
    defer allocator.deinit(testing.allocator);

    // Allocate 256x 1MB. Should fit. Then free four random slots and reallocate four slots.
    // Plus free four contiguous slots an allocate 4x larger slot. All must be zero fragmentation!
    var allocations: [256]OffsetAllocator.Allocation = undefined;
    for (0..256) |i| {
        allocations[i] = try allocator.allocate(1024 * 1024);
        try testing.expectEqual(i * 1024 * 1024, allocations[i].offset);
    }

    const report = allocator.storageReport();
    try testing.expectEqual(0, report.total_free_space);
    try testing.expectEqual(0, report.largest_free_region);

    // Free four random slots
    allocator.free(allocations[243]);
    // No room
    try testing.expectError(error.OutOfMemory, allocator.allocate(1024 * 1024 * 4));

    allocator.free(allocations[5]);
    allocator.free(allocations[123]);
    allocator.free(allocations[95]);

    // Free four contiguous slot (allocator must merge)
    allocator.free(allocations[151]);
    allocator.free(allocations[152]);
    allocator.free(allocations[153]);
    allocator.free(allocations[154]);

    allocations[243] = try allocator.allocate(1024 * 1024);
    allocations[5] = try allocator.allocate(1024 * 1024);
    allocations[123] = try allocator.allocate(1024 * 1024);
    allocations[95] = try allocator.allocate(1024 * 1024);
    allocations[151] = try allocator.allocate(1024 * 1024 * 4);

    for (0..256) |i| {
        if (i < 152 or i > 154) {
            allocator.free(allocations[i]);
        }
    }

    const report2 = allocator.storageReport();
    try testing.expectEqual(1024 * 1024 * 256, report2.total_free_space);
    try testing.expectEqual(1024 * 1024 * 256, report2.largest_free_region);

    // End: Validate that allocator has no fragmentation left. Should be 100% clean.
    const validate_all = try allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(0, validate_all.offset);
    allocator.free(validate_all);
}

test "reset" {
    var allocator = try OffsetAllocator.init(testing.allocator, 1024 * 1024 * 256);
    defer allocator.deinit(testing.allocator);

    // Make some allocations
    _ = try allocator.allocate(1024);
    const b = try allocator.allocate(2048);
    _ = try allocator.allocate(4096);

    // Free some but not all
    allocator.free(b);

    // Reset the allocator
    allocator.reset();

    // After reset, we should be able to allocate the full size again
    const validate_all = try allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(0, validate_all.offset);
    allocator.free(validate_all);
}
