const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("math");

const root = @import("root.zig");
const Color = root.Color;
const DrawVertex = root.DrawVertex;
const Rect = root.Rect;

const Atlas = @import("Atlas.zig");

const DrawList = @This();

gpa: Allocator,

atlas: *const Atlas,

vertices: std.ArrayList(DrawVertex),
indices: std.ArrayList(u32),

pub fn init(gpa: Allocator, atlas: *const Atlas) DrawList {
    return .{
        .gpa = gpa,
        .atlas = atlas,
        .vertices = .empty,
        .indices = .empty,
    };
}
pub fn deinit(self: *DrawList) void {
    self.vertices.deinit(self.gpa);
    self.indices.deinit(self.gpa);
}
pub fn reset(self: *DrawList) void {
    self.vertices.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();
}

pub fn drawRect(
    self: *DrawList,
    rect: Rect,
    color: Color,
    uv_min: math.Vec2,
    uv_max: math.Vec2,
) void {
    const base_index: u32 = @intCast(self.vertices.items.len);
    self.vertices.appendSlice(self.gpa, &.{
        .{
            .position = .{ rect.x, rect.y },
            .uv = .{ uv_min[0], uv_min[1] },
            .color = color,
        },
        .{
            .position = .{ rect.x + rect.width, rect.y },
            .uv = .{ uv_max[0], uv_min[1] },
            .color = color,
        },
        .{
            .position = .{ rect.x + rect.width, rect.y + rect.height },
            .uv = .{ uv_max[0], uv_max[1] },
            .color = color,
        },
        .{
            .position = .{ rect.x, rect.y + rect.height },
            .uv = .{ uv_min[0], uv_max[1] },
            .color = color,
        },
    }) catch @panic("oom");

    self.indices.appendSlice(self.gpa, &.{
        base_index + 0,
        base_index + 1,
        base_index + 2,
        base_index + 0,
        base_index + 2,
        base_index + 3,
    }) catch @panic("oom");
}

pub fn drawText(
    self: *DrawList,
    origin: math.Vec2,
    text: []const u8,
    color: Color,
    size: f32,
) void {
    const pixel_scale = size / Atlas.font_glyph_height;
    const line_advance = size + Atlas.font_line_spacing;

    var cursor_x = origin[0];
    var cursor_y = origin[1];

    for (text) |cp| {
        if (cp == '\n') {
            cursor_x = origin[0];
            cursor_y += line_advance;
            continue;
        }

        const glyph = self.atlas.lookup(cp);
        self.drawRect(
            .{
                .x = cursor_x,
                .y = cursor_y,
                .width = glyph.size[0] * pixel_scale,
                .height = glyph.size[1] * pixel_scale,
            },
            color,
            glyph.uv_min,
            glyph.uv_max,
        );
        cursor_x += glyph.advance * pixel_scale;
    }
}

pub fn drawCircleFilled(self: *DrawList, center: math.Vec2, radius: f32, color: Color) void {
    if (radius <= 0.0) return;

    const segments = std.math.clamp(
        @as(usize, @intFromFloat(@ceil(radius * 0.75))),
        8,
        32,
    );

    const base_index = self.vertices.items.len;
    self.vertices.append(self.gpa, .{
        .position = center,
        .uv = .{ 0, 0 },
        .color = color,
    }) catch @panic("oom");

    const step = std.math.tau / @as(f32, @floatFromInt(segments));
    for (0..segments) |i| {
        const angle = step * @as(f32, @floatFromInt(i));
        self.vertices.append(self.gpa, .{
            .position = .{
                center[0] + std.math.cos(angle) * radius,
                center[1] + std.math.sin(angle) * radius,
            },
            .uv = .{ 0, 0 },
            .color = color,
        }) catch @panic("oom");
    }

    for (0..segments) |i| {
        const next = (i + 1) % segments;
        self.indices.appendSlice(self.gpa, &.{
            @intCast(base_index),
            @intCast(base_index + 1 + i),
            @intCast(base_index + 1 + next),
        }) catch @panic("oom");
    }
}
