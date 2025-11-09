const math = @import("math");

pub const Style = struct {
    background_color: Color = .rgba(29, 32, 33, 255),
    accent_color: Color = .rgba(215, 153, 33, 255),

    button_background: Color = .rgba(60, 56, 54, 255),
    button_hover_background: Color = .rgba(80, 73, 69, 255),
    button_hold_background: Color = .rgba(102, 92, 84, 255),
    button_text_color: Color = .rgba(235, 219, 178, 255),
    button_padding: math.Vec2 = .{ 12.0, 10.0 },

    panel_background_color: Color = .rgba(40, 40, 40, 255),
    panel_padding: math.Vec2 = .{ 8.0, 8.0 },
    panel_item_spacing: f32 = 8.0,

    slider_track_color: Color = .rgba(80, 73, 69, 255),
    slider_track_active_color: Color = .rgba(214, 93, 14, 255),
    slider_track_hover_color: Color = .rgba(102, 92, 84, 255),

    slider_handle_color: Color = .rgba(235, 219, 178, 255),
    slider_handle_active_color: Color = .rgba(250, 189, 47, 255),
    slider_handle_hover_color: Color = .rgba(248, 189, 40, 255),

    slider_height: f32 = 24.0,
    slider_handle_width: f32 = 14.0,
    slider_track_height: f32 = 6.0,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn containsPoint(self: Rect, pt: math.Vec2) bool {
        return pt[0] >= self.x and
            pt[0] <= self.x + self.width and
            pt[1] >= self.y and
            pt[1] <= self.y + self.height;
    }
};

pub const Color = packed struct(u32) {
    pub const white: Color = .rgb(255, 255, 255);
    pub const red: Color = .rgb(255, 0, 0);
    pub const green: Color = .rgb(0, 255, 0);
    pub const blue: Color = .rgb(0, 0, 255);

    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn toFloat(self: Color) math.Vec4 {
        return .{
            @as(f32, @floatFromInt(self.r)) / 255.0,
            @as(f32, @floatFromInt(self.g)) / 255.0,
            @as(f32, @floatFromInt(self.b)) / 255.0,
            @as(f32, @floatFromInt(self.a)) / 255.0,
        };
    }
};

pub const TextOptions = struct {
    color: ?Color = null,
    size: f32 = 18.0,
};

pub const DrawVertex = struct {
    position: math.Vec2,
    uv: math.Vec2,
    color: Color,
};

pub const DrawData = struct {
    display_size: math.Vec2,
    vertices: []const DrawVertex,
    indices: []const u32,
};

pub const Gui = @import("Gui.zig");

test {
    _ = @import("Gui.zig");
}
