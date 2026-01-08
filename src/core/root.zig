const builtin = @import("builtin");
const std = @import("std");

pub fn Set(Key: type) type {
    return std.AutoArrayHashMap(Key, void);
}

pub const Deque = @import("deque.zig").Deque;
pub const SpscQueue = @import("spsc_queue.zig").SpscQueue;
pub const EventStream = @import("event.zig").Stream;
pub const ext = @import("ext.zig");
pub const tga = @import("tga.zig");

pub const OffsetAllocator = @import("OffsetAllocator.zig");

pub const StringTable = @import("str.zig").StringTable(builtin.mode == .Debug);

pub const DebugTimer = struct {
    name: []const u8,
    t: std.time.Timer,

    pub fn start(name: []const u8) DebugTimer {
        return .{
            .name = name,
            .t = std.time.Timer.start() catch @panic("failed to start timer"),
        };
    }
    pub fn stop(self: *DebugTimer) void {
        std.debug.print("{s}: {d} ms\n", .{
            self.name,
            @as(f64, @floatFromInt(self.t.read())) / std.time.ns_per_ms,
        });
    }
    pub fn lap(self: *DebugTimer) void {
        std.debug.print("{s}: {d} ms\n", .{
            self.name,
            @as(f64, @floatFromInt(self.t.lap())) / std.time.ns_per_ms,
        });
    }
};

test {
    _ = @import("OffsetAllocator.zig");
    _ = @import("deque.zig");
    _ = @import("event.zig");
    _ = @import("ext.zig");
    _ = @import("spsc_queue.zig");
    _ = @import("str.zig");
    _ = @import("tga.zig");
}
