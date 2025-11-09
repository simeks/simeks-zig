const std = @import("std");

/// Extern struct type for array[capacity] + len
/// Maps to this in C:
/// struct {
///     T extern_array[capacity];
///     size_t num_extern_array;
/// }
pub fn Array(T: type, comptime capacity: usize) type {
    const alignment = @alignOf(T);
    return extern struct {
        pub const Element = T;
        pub const Capacity = capacity;

        const Self = @This();

        data: [capacity]T align(alignment) = undefined,
        len: usize = 0,

        pub fn init(m: []const T) Self {
            if (m.len > capacity) @panic("extern.Array overflow");
            var self: Self = .{
                .len = m.len,
            };
            @memcpy(self.data[0..m.len], m);
            return self;
        }
        pub fn slice(self: *const Self) []align(alignment) const T {
            return self.data[0..self.len];
        }
    };
}

/// Extern fat pointer for passing ptr + len through C ABI
/// Maps to this in C:
/// struct {
///     T* extern_array;
///     size_t num_extern_array;
/// }
pub fn Pointer(T: type) type {
    const alignment = @alignOf(T);
    return extern struct {
        pub const Element = T;

        const Self = @This();

        ptr: ?[*]const T = null,
        len: usize = 0,

        pub fn init(s: []const T) Self {
            return .{
                .ptr = s.ptr,
                .len = s.len,
            };
        }
        pub fn slice(self: *const Self) []align(alignment) const T {
            if (self.ptr) |p| {
                return p[0..self.len];
            } else {
                return &.{};
            }
        }
    };
}
