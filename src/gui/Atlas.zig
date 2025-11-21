const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("math");

pub const font_glyph_height = 7;
pub const font_glyph_width = 5;
pub const font_glyph_advance = font_glyph_width + 1;
pub const font_line_spacing = 4;

const padding = 1;
const cell_width = font_glyph_width + padding * 2;
const cell_height = font_glyph_height + padding * 2;

const glyph_count = glyph_bitmaps.len + 1; // +1 for fallback
const columns = 16;
const rows = (glyph_count + columns - 1) / columns;

const atlas_width = cell_width * columns;
const atlas_height = cell_height * rows;
const inv_atlas_width = 1.0 / @as(f32, @floatFromInt(atlas_width));
const inv_atlas_height = 1.0 / @as(f32, @floatFromInt(atlas_height));
const ascii_count = 256;

pub const Glyph = struct {
    uv_min: math.Vec2,
    uv_max: math.Vec2,
    size: math.Vec2,
    advance: f32,
};

const Atlas = @This();

width: u32,
height: u32,
pixels: []u8,

glyphs: []Glyph,
glyph_lookup: []usize, // ascii to glyph index

pub fn create(gpa: Allocator) !*Atlas {
    var pixels = try gpa.alloc(u8, atlas_width * atlas_height);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);

    // (0, 0) is used for solids
    pixels[0] = 255;

    var glyphs = try gpa.alloc(Glyph, glyph_count);
    errdefer gpa.free(glyphs);

    var glyph_idx: usize = 0;

    const glyph_lookup = try gpa.alloc(usize, ascii_count);
    @memset(glyph_lookup, 0);

    // Fallback
    glyphs[glyph_idx] = allocGlyph(pixels, 0, fallback_bitmap);
    glyph_idx += 1;

    for (glyph_bitmaps) |entry| {
        const cp, const bitmap = entry;

        glyphs[glyph_idx] = allocGlyph(pixels, glyph_idx, bitmap);
        glyph_lookup[cp] = glyph_idx;
        glyph_idx += 1;
    }

    const self = try gpa.create(Atlas);
    self.* = .{
        .width = atlas_width,
        .height = atlas_height,
        .pixels = pixels,
        .glyphs = glyphs,
        .glyph_lookup = glyph_lookup,
    };
    return self;
}

pub fn destroy(self: *Atlas, gpa: Allocator) void {
    gpa.free(self.glyphs);
    gpa.free(self.glyph_lookup);
    gpa.free(self.pixels);
    gpa.destroy(self);
}

pub fn lookup(self: *const Atlas, cp: u8) Glyph {
    return self.glyphs[self.glyph_lookup[std.ascii.toUpper(cp)]];
}

fn allocGlyph(pixels: []u8, idx: usize, bitmap: []const u8) Glyph {
    const col = idx % columns;
    const row = idx / columns;

    const base_x = col * cell_width + padding;
    const base_y = row * cell_height + padding;

    for (0.., bitmap) |y, mask| {
        for (0..font_glyph_width) |x| {
            const bit = (mask >> @intCast(font_glyph_width - 1 - x)) & 0x1;
            const px = base_x + x;
            const py = base_y + y;

            pixels[py * atlas_width + px] = if (bit == 1) 255 else 0;
        }
    }

    const uv_min: math.Vec2 = .{
        @as(f32, @floatFromInt(base_x)) * inv_atlas_width,
        @as(f32, @floatFromInt(base_y)) * inv_atlas_height,
    };
    const uv_max: math.Vec2 = .{
        @as(f32, @floatFromInt(base_x + font_glyph_width)) * inv_atlas_width,
        @as(f32, @floatFromInt(base_y + font_glyph_height)) * inv_atlas_height,
    };

    return .{
        .uv_min = uv_min,
        .uv_max = uv_max,
        .size = .{
            font_glyph_width,
            font_glyph_height,
        },
        .advance = font_glyph_advance,
    };
}

const GlyphBitmap = struct {
    u8,
    []const u8,
};

const glyph_bitmaps = [_]GlyphBitmap{
    .{ 'A', &.{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 } },
    .{ 'B', &.{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 } },
    .{ 'C', &.{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 } },
    .{ 'D', &.{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 } },
    .{ 'E', &.{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 } },
    .{ 'F', &.{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 } },
    .{ 'G', &.{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 } },
    .{ 'H', &.{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 } },
    .{ 'I', &.{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 } },
    .{ 'J', &.{ 0b11111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100 } },
    .{ 'K', &.{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 } },
    .{ 'L', &.{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 } },
    .{ 'M', &.{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 } },
    .{ 'N', &.{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 } },
    .{ 'O', &.{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 } },
    .{ 'P', &.{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 } },
    .{ 'Q', &.{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 } },
    .{ 'R', &.{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 } },
    .{ 'S', &.{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 } },
    .{ 'T', &.{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 } },
    .{ 'U', &.{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 } },
    .{ 'V', &.{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 } },
    .{ 'W', &.{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 } },
    .{ 'X', &.{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 } },
    .{ 'Y', &.{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 } },
    .{ 'Z', &.{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 } },
    .{ '0', &.{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 } },
    .{ '1', &.{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 } },
    .{ '2', &.{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 } },
    .{ '3', &.{ 0b11110, 0b00001, 0b00001, 0b00110, 0b00001, 0b00001, 0b11110 } },
    .{ '4', &.{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 } },
    .{ '5', &.{ 0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110 } },
    .{ '6', &.{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 } },
    .{ '7', &.{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 } },
    .{ '8', &.{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 } },
    .{ '9', &.{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 } },
    .{ ' ', &.{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ '!', &.{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 } },
    .{ '?', &.{ 0b01110, 0b10001, 0b00001, 0b00110, 0b00100, 0b00000, 0b00100 } },
    .{ '%', &.{ 0b11001, 0b11010, 0b00100, 0b01000, 0b10011, 0b00011, 0b00000 } },
    .{ '#', &.{ 0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010 } },
    .{ '.', &.{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100 } },
    .{ ',', &.{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b00100, 0b01000 } },
    .{ '-', &.{ 0b00000, 0b00000, 0b00000, 0b01110, 0b00000, 0b00000, 0b00000 } },
    .{ '_', &.{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 } },
    .{ ':', &.{ 0b00000, 0b00100, 0b00000, 0b00000, 0b00000, 0b00100, 0b00000 } },
    .{ '\'', &.{ 0b00100, 0b00100, 0b01000, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ '"', &.{ 0b01010, 0b01010, 0b10100, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ '(', &.{ 0b00100, 0b01000, 0b10000, 0b10000, 0b10000, 0b01000, 0b00100 } },
    .{ ')', &.{ 0b00100, 0b00010, 0b00001, 0b00001, 0b00001, 0b00010, 0b00100 } },
    .{ '{', &.{ 0b01100, 0b01000, 0b01000, 0b11000, 0b01000, 0b01000, 0b01100 } },
    .{ '}', &.{ 0b00110, 0b00010, 0b00010, 0b00011, 0b00010, 0b00010, 0b00110 } },
    .{ '[', &.{ 0b11100, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11100 } },
    .{ ']', &.{ 0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110 } },
    .{ '<', &.{ 0b00010, 0b00100, 0b01000, 0b00100, 0b00010, 0b00000, 0b00000 } },
    .{ '>', &.{ 0b01000, 0b00100, 0b00010, 0b00100, 0b01000, 0b00000, 0b00000 } },
    .{ '/', &.{ 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b00000, 0b00000 } },
    .{ '\\', &.{ 0b10000, 0b01000, 0b00100, 0b00010, 0b00001, 0b00000, 0b00000 } },
    .{ '+', &.{ 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000, 0b00000 } },
    .{ '*', &.{ 0b10101, 0b01110, 0b00100, 0b01110, 0b10101, 0b00000, 0b00000 } },
    .{ '|', &.{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 } },
    .{ '^', &.{ 0b00100, 0b01010, 0b10001, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ ';', &.{ 0b00000, 0b00100, 0b00000, 0b00000, 0b00100, 0b00100, 0b01000 } },
};

const fallback_bitmap: []const u8 = &.{ 0b11111, 0b11111, 0b11111, 0b11111, 0b11111, 0b11111, 0b11111 };
