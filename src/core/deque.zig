const std = @import("std");
const Allocator = std.mem.Allocator;

/// Double-ended queue implemnted as a ring buffer.
pub fn Deque(T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        items: []T,
        head: usize,
        tail: usize,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .items = &[_]T{},
                .head = 0,
                .tail = 0,
            };
        }
        pub fn deinit(self: Self) void {
            self.allocator.free(self.items);
        }

        pub fn pushFront(self: *Self, item: T) !void {
            try self.ensureUnusedCapacity(1);

            self.tail = if (self.tail == 0) self.items.len - 1 else self.tail - 1;
            self.items[self.tail] = item;
        }
        pub fn pushBack(self: *Self, item: T) !void {
            try self.ensureUnusedCapacity(1);

            const head = self.head;
            self.head = (self.head + 1) % self.items.len;
            self.items[head] = item;
        }

        pub fn front(self: *Self) ?T {
            if (self.head == self.tail) {
                return null;
            }
            return self.items[self.tail];
        }
        pub fn back(self: *Self) ?T {
            if (self.head == self.tail) {
                return null;
            }
            if (self.head == 0) {
                return self.items[self.items.len - 1];
            }
            return self.items[(self.head - 1) % self.items.len];
        }

        pub fn popFront(self: *Self) ?T {
            if (self.head == self.tail) {
                return null;
            }
            const item = self.items[self.tail];
            self.tail = (self.tail + 1) % self.items.len;
            return item;
        }
        pub fn popBack(self: *Self) ?T {
            if (self.head == self.tail) {
                return null;
            }
            self.head = if (self.head == 0) self.items.len - 1 else self.head - 1;
            return self.items[self.head];
        }

        /// Number of elements in the deque.
        pub fn count(self: Self) usize {
            if (self.tail <= self.head) {
                return self.head - self.tail;
            }
            return self.items.len - self.tail + self.head;
        }

        pub fn capacity(self: Self) usize {
            return self.items.len;
        }

        pub fn ensureTotalCapacity(self: *Self, new_capacity: usize) !void {
            if (self.items.len > new_capacity + 1) return;

            const old_size = self.items.len;
            const new_size = growCapacity(old_size, new_capacity);

            const old = self.items;

            self.items = try self.allocator.alloc(T, new_size);

            // Copy the shortest section possible to new buffer
            if (self.tail <= self.head) {
                // Continous section
                @memcpy(self.items[self.tail..self.head], old[self.tail..self.head]);
            } else if (self.head < old.len - self.tail) {
                // Copy head to end of section
                //    (H)     (T)     |    New   |
                // | h h . . . o o o o           |
                // | . . . . . o o o o h h . . . |
                @memcpy(self.items[old_size .. old_size + self.head], old[0..self.head]);
                @memcpy(self.items[self.tail..old_size], old[self.tail..old_size]);
                self.head += old.len;
            } else {
                // Copy tail to end of section
                //        (H)     (T) |  New   |
                // | o o o o . . . t t         |
                // | o o o o . . . . . . . t t |
                @memcpy(self.items[0..self.head], old[0..self.head]);
                @memcpy(self.items[self.tail + (new_size - old_size) .. new_size], old[self.tail..old_size]);
                self.tail += new_size - old_size;
            }
            self.allocator.free(old);
        }
        pub fn ensureUnusedCapacity(self: *Self, unused: usize) !void {
            try self.ensureTotalCapacity(self.count() + unused);
        }
        pub fn clearRetainingCapacity(self: *Self) void {
            self.head = 0;
            self.tail = 0;
        }
        pub fn cloneWithAllocator(self: *Self, gpa: Allocator) !Self {
            const other: Self = .{
                .allocator = gpa,
                .items = try gpa.alloc(T, self.capacity()),
                .head = self.head,
                .tail = self.tail,
            };
            @memcpy(other.items, self.items);
            return other;
        }
    };
}

fn growCapacity(current: usize, minimum: usize) usize {
    var new = current;
    while (true) {
        new +|= new / 2 + 8;
        if (new >= minimum)
            return new;
    }
}

const test_alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "deque" {
    var deque = Deque(usize).init(test_alloc);
    defer deque.deinit();

    try expectEqual(0, deque.count());

    try deque.pushBack(0);
    try expectEqual(1, deque.count());
    try expectEqual(8, deque.capacity());
    try expectEqual(0, deque.front());
    try expectEqual(0, deque.back());

    try deque.pushBack(1);
    try expectEqual(2, deque.count());
    try expectEqual(8, deque.capacity());
    try expectEqual(0, deque.front());
    try expectEqual(1, deque.back());

    try deque.pushFront(2);
    try expectEqual(3, deque.count());
    try expectEqual(8, deque.capacity());
    try expectEqual(2, deque.front());
    try expectEqual(1, deque.back());

    deque.clearRetainingCapacity();
    try expectEqual(0, deque.count());
    try expectEqual(null, deque.front());
    try expectEqual(null, deque.back());

    for (0..10) |i| {
        if (i % 2 == 0) {
            try deque.pushBack(i);
        } else {
            try deque.pushFront(i);
        }
    }

    try expectEqual(10, deque.count());
    try expectEqual(9, deque.popFront());
    try expectEqual(7, deque.popFront());
    try expectEqual(5, deque.popFront());
    try expectEqual(3, deque.popFront());
    try expectEqual(1, deque.popFront());
    try expectEqual(8, deque.popBack());
    try expectEqual(6, deque.popBack());
    try expectEqual(4, deque.popBack());
    try expectEqual(2, deque.popBack());
    try expectEqual(0, deque.popBack());
    try expectEqual(0, deque.count());
}

test "popFront" {
    var deque = Deque(usize).init(test_alloc);
    defer deque.deinit();

    try deque.pushBack(0);
    try deque.pushBack(1);
    try deque.pushBack(2);
    try deque.pushBack(3);
    try deque.pushBack(4);
    try deque.pushBack(5);
    try deque.pushBack(6);

    var n: usize = 0;
    while (deque.popFront()) |_| {
        n += 1;
    }
    try expectEqual(7, n);
}
