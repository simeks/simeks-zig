const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

// Based on https://github.com/CharlesFrasch/cppcon2023/tree/main
// https://www.youtube.com/watch?v=K3P_Lmq6pw0
pub fn SpscQueue(T: type, capacity: comptime_int) type {
    const cache_line = std.atomic.cache_line;

    if ((capacity & (capacity - 1)) != 0) {
        @compileError("Capacity must be pow2");
    }

    // Mask used to wrap index, which is significantly faster than %
    const mask = capacity - 1;

    return struct {
        const Self = @This();

        buffer: []T,

        // Dodge false sharing by aligning to cache line
        push_cursor: std.atomic.Value(usize) align(cache_line),
        pop_cursor: std.atomic.Value(usize) align(cache_line),

        pub fn init(gpa: Allocator) !Self {
            return .{
                .buffer = try gpa.alloc(T, capacity),
                .push_cursor = .init(0),
                .pop_cursor = .init(0),
            };
        }
        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.buffer);
        }

        /// Number of elements in the queue
        pub fn count(self: *const Self) usize {
            const push_cursor = self.push_cursor.load(.monotonic);
            const pop_cursor = self.pop_cursor.load(.monotonic);
            assert(pop_cursor <= push_cursor);
            return push_cursor - pop_cursor;
        }

        /// Push to queue, returns error.QueueFull if full
        pub fn push(self: *Self, item: T) !void {
            const push_cursor = self.push_cursor.load(.monotonic);
            const pop_cursor = self.pop_cursor.load(.acquire);

            if (push_cursor - pop_cursor == capacity) {
                return error.QueueFull;
            }

            self.buffer[push_cursor & mask] = item;
            self.push_cursor.store(push_cursor + 1, .release);
        }
        /// Pop from queue, returns null if queue was empty
        pub fn pop(self: *Self) ?T {
            const push_cursor = self.push_cursor.load(.acquire);
            const pop_cursor = self.pop_cursor.load(.monotonic);
            if (push_cursor == pop_cursor) {
                return null;
            }

            const elem = self.buffer[pop_cursor & mask];
            self.pop_cursor.store(pop_cursor + 1, .release);
            return elem;
        }
    };
}

test "SpscQueue" {
    var q: SpscQueue(usize, 1024) = try .init(std.testing.allocator);
    defer q.deinit(std.testing.allocator);

    for (0..1024) |i| {
        try q.push(i);
    }

    try std.testing.expectError(error.QueueFull, q.push(1024));

    for (0..1024) |i| {
        const j = q.pop();
        try std.testing.expectEqual(i, j);
    }

    try std.testing.expectEqual(null, q.pop());
}

test "SpscQueue threaded" {
    const Queue = SpscQueue(usize, 1024 * 1024);

    var q: Queue = try .init(std.testing.allocator);
    defer q.deinit(std.testing.allocator);

    var thread = try std.Thread.spawn(
        .{},
        struct {
            pub fn run(qq: *Queue) void {
                for (0..1024 * 1024) |i| {
                    qq.push(i) catch @panic("");
                }
            }
        }.run,
        .{&q},
    );

    var i: usize = 0;
    while (i < 1024 * 1024) {
        if (q.pop()) |j| {
            try std.testing.expectEqual(i, j);
            i += 1;
        }
    }
    thread.join();
}
