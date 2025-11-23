const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Image = struct {
    pixels: []u8,
    width: usize,
    height: usize,

    pub fn deinit(self: Image, gpa: Allocator) void {
        gpa.free(self.pixels);
    }
};

const DataType = enum(u8) {
    no_image_data = 0,
    uncompressed_color_mapped = 1,
    uncompressed_rgb = 2,
    uncompressed_black_and_white = 3,
    rle_color_mapped = 9,
    rle_rgb = 10,
    _,
};

const Header = packed struct {
    id_len: u8,
    color_map_type: u8,
    data_type: DataType,
    color_map_origin: u16,
    color_map_len: u16,
    color_map_entry_size: u8,
    x_origin: u16,
    y_origin: u16,
    width: u16,
    height: u16,
    bits_per_pixel: u8,
    image_descriptor: u8,
};

/// Read an uncompressed 8-bit grayscale TGA image.
pub fn readImpl(gpa: Allocator, reader: *std.Io.Reader) !Image {
    const header = try reader.takeStruct(Header, .little);
    if (header.data_type != .uncompressed_black_and_white) {
        return error.NotSupported;
    }
    if (header.color_map_type != 0) {
        return error.NotSupported;
    }

    if (header.width <= 0 or header.height <= 0) {
        return error.ZeroSize;
    }

    if (header.bits_per_pixel != 8) {
        return error.NotSupported;
    }

    _ = try reader.discard(.limited(header.id_len));

    // No alpha bits
    assert((header.image_descriptor & 0b1111) == 0);
    // No X reverse
    assert((header.image_descriptor & 0b10000) == 0);

    const top_to_bottom = (header.image_descriptor & 0b0010_0000) != 0;

    const width: usize = header.width;
    const height: usize = header.height;
    const num_pixels = width * height;

    const pixels = try gpa.alloc(u8, num_pixels);
    errdefer gpa.free(pixels);

    if (top_to_bottom) {
        try reader.readSliceAll(pixels);
    } else {
        const stride: usize = @intCast(header.width);
        for (0..header.height) |y| {
            const dst_y = (header.height - y - 1);
            const dst = pixels[dst_y * stride .. (dst_y + 1) * stride];
            try reader.readSliceAll(dst);
        }
    }

    return .{
        .pixels = pixels,
        .width = header.width,
        .height = header.height,
    };
}

pub fn readFromMemory(gpa: Allocator, data: []const u8) !Image {
    var reader: std.Io.Reader = .fixed(data);
    return readImpl(gpa, &reader);
}

pub fn read(gpa: Allocator, path: []const u8) !Image {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    var buf: [1024]u8 = undefined;
    var reader = f.reader(&buf);

    return readImpl(gpa, &reader.interface);
}

test "tga" {
    const expectEqual = std.testing.expectEqual;

    const img = try read(std.testing.allocator, "tests/test.tga");
    defer img.deinit(std.testing.allocator);

    try expectEqual(4, img.width);
    try expectEqual(4, img.height);

    try expectEqual(0, img.pixels[0]);
    try expectEqual(255, img.pixels[1]);
    try expectEqual(255, img.pixels[2]);
    try expectEqual(255, img.pixels[3]);

    try expectEqual(255, img.pixels[4]);
    try expectEqual(0, img.pixels[5]);
    try expectEqual(255, img.pixels[6]);
    try expectEqual(255, img.pixels[7]);

    try expectEqual(255, img.pixels[8]);
    try expectEqual(255, img.pixels[9]);
    try expectEqual(0, img.pixels[10]);
    try expectEqual(255, img.pixels[11]);

    try expectEqual(255, img.pixels[12]);
    try expectEqual(255, img.pixels[13]);
    try expectEqual(127, img.pixels[14]);
    try expectEqual(255, img.pixels[15]);
}
