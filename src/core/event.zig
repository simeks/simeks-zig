const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Stream(Event: type) type {
    return struct {
        const EventTag = std.meta.FieldEnum(Event);

        gpa: Allocator,
        events: std.ArrayList(Event),

        pub fn init(gpa: Allocator) @This() {
            return .{
                .gpa = gpa,
                .events = .empty,
            };
        }
        pub fn deinit(self: *@This()) void {
            self.events.deinit(self.gpa);
            self.* = undefined;
        }
        pub fn reset(self: *@This()) void {
            self.events.clearRetainingCapacity();
        }

        pub fn push(
            self: *@This(),
            comptime tag: EventTag,
            event: EventType(tag),
        ) void {
            self.events.append(
                self.gpa,
                @unionInit(Event, @tagName(tag), event),
            ) catch @panic("oom");
        }

        pub fn slice(self: *@This()) []Event {
            return self.events.items;
        }

        fn EventType(comptime field: EventTag) type {
            return std.meta.fieldInfo(Event, field).type;
        }
    };
}
