const std = @import("std");

pub fn StringTable(comptime enable_lookup: bool) type {
    return struct {
        pub const Id = u64;

        const Self = @This();

        arena: if (enable_lookup) std.heap.ArenaAllocator else void,
        gpa: if (enable_lookup) std.mem.Allocator else void,
        map: if (enable_lookup) std.array_hash_map.Auto(u64, []const u8) else void,

        pub fn init(gpa: std.mem.Allocator) Self {
            if (enable_lookup) return .{
                .arena = .init(gpa),
                .gpa = gpa,
                .map = .empty,
            } else return .{ .arena = {}, .gpa = {}, .map = {} };
        }
        pub fn deinit(self: *Self) void {
            if (enable_lookup) {
                self.map.deinit(self.gpa);
                self.arena.deinit();
            }
        }

        pub fn hash(self: *Self, comptime str: []const u8) Id {
            const id = hashStr(str);
            if (enable_lookup) {
                const e = self.map.getOrPut(self.gpa, id) catch @panic("oom");
                if (!e.found_existing) {
                    e.value_ptr.* = self.arena.allocator().dupe(u8, str) catch @panic("oom");
                } else {
                    std.debug.assert(std.mem.eql(u8, str, e.value_ptr.*));
                }
            }
            return id;
        }
        pub fn lookup(self: *const Self, id: Id) []const u8 {
            if (enable_lookup) {
                if (self.map.get(id)) |entry| {
                    return entry;
                }
            }
            return "unknown";
        }

        fn hashStr(comptime str: []const u8) comptime_int {
            return std.hash.Fnv1a_64.hash(str);
        }
    };
}

const testing = std.testing;

test "StringTable" {
    var table: StringTable(false) = .init(testing.allocator);
    defer table.deinit();

    const id1 = table.hash("test1");
    const id2 = table.hash("test2");

    try testing.expect(id1 == table.hash("test1"));
    try testing.expect(id1 != id2);

    try testing.expectEqualStrings("unknown", table.lookup(id1));
    try testing.expectEqual(0, @sizeOf(@TypeOf(table)));
}

test "StringTable lookup" {
    var table: StringTable(true) = .init(testing.allocator);
    defer table.deinit();

    const id1 = table.hash("test1");
    const id2 = table.hash("test2");

    try testing.expect(id1 == table.hash("test1"));
    try testing.expect(id1 != id2);

    try testing.expectEqualStrings("test1", table.lookup(id1));
    try testing.expectEqualStrings("test2", table.lookup(id2));
    try testing.expectEqualStrings("unknown", table.lookup(1234));
}
