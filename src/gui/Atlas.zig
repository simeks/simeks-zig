const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const core = @import("core");
const math = @import("math");

const tga = core.tga;

const atlas_def = @import("atlas.zon");
const atlas_data = @embedFile("atlas.tga");

const TextOptions = @import("root.zig").TextOptions;

const GlyphLookup = std.AutoHashMap(i32, usize);

pub const font_glyph_height = atlas_def.font_size;
pub const font_line_height = atlas_def.ascent + atlas_def.descent;
pub const font_line_spacing = 1.0;
pub const font_ascent = atlas_def.ascent;
pub const font_descent = atlas_def.descent;

pub const Glyph = struct {
    uv_min: math.Vec2,
    uv_max: math.Vec2,
    size: math.Vec2,
    offset: math.Vec2,
    advance: f32,
};

const Atlas = @This();

image: tga.Image,

glyphs: []Glyph,
glyph_lookup: GlyphLookup,
fallback_index: usize,

pub fn create(gpa: Allocator) !*Atlas {
    const image = try core.tga.readFromMemory(gpa, atlas_data);
    errdefer image.deinit(gpa);

    assert(image.width == atlas_def.atlas_size[0]);
    assert(image.height == atlas_def.atlas_size[1]);

    var glyphs = try gpa.alloc(Glyph, atlas_def.glyphs.len);
    errdefer gpa.free(glyphs);

    var glyph_lookup: GlyphLookup = .init(gpa);
    errdefer glyph_lookup.deinit();

    var fallback_index: ?usize = null;

    inline for (0.., atlas_def.glyphs) |i, glyph_def| {
        glyphs[i] = .{
            .uv_min = glyph_def.uv_min,
            .uv_max = glyph_def.uv_max,
            .size = glyph_def.size,
            .offset = glyph_def.offset,
            .advance = glyph_def.advance,
        };

        try glyph_lookup.putNoClobber(glyph_def.codepoint, i);

        if (glyph_def.codepoint == atlas_def.default_codepoint) {
            fallback_index = i;
        }
    }

    if (fallback_index == null) {
        return error.MissingFallbackGlyph;
    }

    const self = try gpa.create(Atlas);
    self.* = .{
        .image = image,
        .glyphs = glyphs,
        .glyph_lookup = glyph_lookup,
        .fallback_index = fallback_index.?,
    };
    return self;
}

pub fn destroy(self: *Atlas, gpa: Allocator) void {
    self.glyph_lookup.deinit();
    self.image.deinit(gpa);
    gpa.free(self.glyphs);
    gpa.destroy(self);
}

pub fn lookup(self: *const Atlas, cp: u21) Glyph {
    return self.glyphs[self.glyph_lookup.get(@intCast(cp)) orelse self.fallback_index];
}

pub fn measureText(self: *const Atlas, text: []const u8, options: TextOptions) math.Vec2 {
    const pixel_scale = options.size / font_glyph_height;
    const line_height = font_line_height * pixel_scale;
    const line_spacing = font_line_spacing * pixel_scale;

    var line_width: f32 = 0.0;
    var max_width: f32 = 0.0;
    var line_count: usize = 1;

    const view = std.unicode.Utf8View.init(text) catch @panic("invalid utf-8 string");

    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n') {
            max_width = @max(max_width, line_width);
            line_width = 0.0;
            line_count += 1;
            continue;
        }

        const glyph = self.lookup(cp);
        line_width += glyph.advance * pixel_scale;
    }

    max_width = @max(max_width, line_width);

    const height = line_height * @as(f32, @floatFromInt(line_count)) +
        line_spacing * @as(f32, @floatFromInt(line_count - 1));

    return .{
        max_width,
        height,
    };
}
