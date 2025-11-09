const builtin = @import("builtin");
const std = @import("std");

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

pub const SwizzleComponent = enum(i32) {
    x = 0,
    y = 1,
    z = 2,
    w = 3,
};

pub fn swizzle(
    a: anytype,
    comptime mask: [numComponents(@TypeOf(a))]SwizzleComponent,
) @TypeOf(a) {
    const VecT = @TypeOf(a);
    const T = ElementType(VecT);
    switch (VecT) {
        inline Vec2 => {
            return @shuffle(T, a, undefined, [2]i32{ @intFromEnum(mask[0]), @intFromEnum(mask[1]) });
        },
        inline Vec3 => {
            return @shuffle(T, a, undefined, [3]i32{ @intFromEnum(mask[0]), @intFromEnum(mask[1]), @intFromEnum(mask[2]) });
        },
        inline Vec4 => {
            return @shuffle(T, a, undefined, [4]i32{ @intFromEnum(mask[0]), @intFromEnum(mask[1]), @intFromEnum(mask[2]), @intFromEnum(mask[3]) });
        },
        else => @compileError("shuffle only works on Vec2, Vec3, and Vec4"),
    }
}

test "vec.swizzle" {
    const expectEqual = std.testing.expectEqual;

    const v2: Vec2 = .{ 1.0, 2.0 };
    const v2_swizzle = swizzle(v2, .{ .y, .x });
    try expectEqual(2.0, v2_swizzle[0]);
    try expectEqual(1.0, v2_swizzle[1]);

    const v3: Vec3 = .{ 1.0, 2.0, 3.0 };
    const v3_swizzle = swizzle(v3, .{ .z, .y, .x });
    try expectEqual(3.0, v3_swizzle[0]);
    try expectEqual(2.0, v3_swizzle[1]);
    try expectEqual(1.0, v3_swizzle[2]);

    const v4: Vec4 = .{ 1.0, 2.0, 3.0, 4.0 };
    const v4_swizzle = swizzle(v4, .{ .w, .z, .y, .x });
    try expectEqual(4.0, v4_swizzle[0]);
    try expectEqual(3.0, v4_swizzle[1]);
    try expectEqual(2.0, v4_swizzle[2]);
    try expectEqual(1.0, v4_swizzle[3]);
}

pub const ShuffleComponent = enum(i32) {
    ax = 0,
    ay = 1,
    az = 2,
    aw = 3,
    bx = ~@as(i32, 0),
    by = ~@as(i32, 1),
    bz = ~@as(i32, 2),
    bw = ~@as(i32, 3),
};

pub fn shuffle(
    a: anytype,
    b: @TypeOf(a),
    comptime mask: [numComponents(@TypeOf(a))]ShuffleComponent,
) @TypeOf(a) {
    const VecT = @TypeOf(a);
    const T = ElementType(VecT);
    switch (VecT) {
        inline Vec2 => {
            return @shuffle(T, a, b, [2]i32{ @intFromEnum(mask[0]), @intFromEnum(mask[1]) });
        },
        inline Vec3 => {
            return @shuffle(T, a, b, [3]i32{ @intFromEnum(mask[0]), @intFromEnum(mask[1]), @intFromEnum(mask[2]) });
        },
        inline Vec4 => {
            return @shuffle(T, a, b, [4]i32{ @intFromEnum(mask[0]), @intFromEnum(mask[1]), @intFromEnum(mask[2]), @intFromEnum(mask[3]) });
        },
        else => @compileError("shuffle only works on Vec2, Vec3, and Vec4"),
    }
}

test "vec.shuffle" {
    const expectEqual = std.testing.expectEqual;

    const v2a: Vec2 = .{ 1.0, 2.0 };
    const v2b: Vec2 = .{ 3.0, 4.0 };
    const v2c = shuffle(v2a, v2b, .{ .ay, .bx });
    try expectEqual(2.0, v2c[0]);
    try expectEqual(3.0, v2c[1]);

    const v3a: Vec3 = .{ 1.0, 2.0, 3.0 };
    const v3b: Vec3 = .{ 4.0, 5.0, 6.0 };
    const v3c = shuffle(v3a, v3b, .{ .az, .by, .bx });
    try expectEqual(3.0, v3c[0]);
    try expectEqual(5.0, v3c[1]);
    try expectEqual(4.0, v3c[2]);

    const v4a: Vec4 = .{ 1.0, 2.0, 3.0, 4.0 };
    const v4b: Vec4 = .{ 5.0, 6.0, 7.0, 8.0 };
    const v4c = shuffle(v4a, v4b, .{ .aw, .bz, .by, .bx });
    try expectEqual(4.0, v4c[0]);
    try expectEqual(7.0, v4c[1]);
    try expectEqual(6.0, v4c[2]);
    try expectEqual(5.0, v4c[3]);
}

pub fn toVec4(v: Vec3, w: ElementType(Vec3)) Vec4 {
    return .{ v[0], v[1], v[2], w };
}

test "vec.toVec4" {
    const expectEqual = std.testing.expectEqual;

    const v3: Vec3 = .{ 1.0, 2.0, 3.0 };
    const v4 = toVec4(v3, 4.0);
    try expectEqual(1.0, v4[0]);
    try expectEqual(2.0, v4[1]);
    try expectEqual(3.0, v4[2]);
    try expectEqual(4.0, v4[3]);
}

pub fn toVec3(v: Vec4) Vec3 {
    return .{ v[0], v[1], v[2] };
}

pub fn length(v: anytype) f32 {
    switch (@TypeOf(v)) {
        Vec2 => return @sqrt(v[0] * v[0] + v[1] * v[1]),
        Vec3 => return @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]),
        Vec4 => return @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3]),
        else => @compileError("type is not a vector"),
    }
}

test "vec.length" {
    const tol = 0.0001;
    const expectApproxEqAbs = std.testing.expectApproxEqAbs;

    const v2: Vec2 = .{ 3.0, 4.0 };
    try expectApproxEqAbs(@sqrt(3.0 * 3.0 + 4.0 * 4.0), length(v2), tol);

    const v3: Vec3 = .{ 1.0, 2.0, 3.0 };
    try expectApproxEqAbs(@sqrt(1.0 * 1.0 + 2.0 * 2.0 + 3.0 * 3.0), length(v3), tol);

    const v4: Vec4 = .{ 1.0, 2.0, 3.0, 4.0 };
    try expectApproxEqAbs(@sqrt(1.0 * 1.0 + 2.0 * 2.0 + 3.0 * 3.0 + 4.0 * 4.0), length(v4), tol);
}

pub fn normalize(v: anytype) @TypeOf(v) {
    switch (@TypeOf(v)) {
        Vec2 => return v / @as(Vec2, @splat(length(v))),
        Vec3 => return v / @as(Vec3, @splat(length(v))),
        Vec4 => return v / @as(Vec4, @splat(length(v))),
        else => @compileError("type is not a vector"),
    }
}

test "vec.normalize" {
    const tol = 0.0001;
    const expectApproxEqAbs = std.testing.expectApproxEqAbs;

    const v2: Vec2 = .{ 3.0, 4.0 };
    const v2_normalized = normalize(v2);
    try expectApproxEqAbs(3.0 / length(v2), v2_normalized[0], tol);
    try expectApproxEqAbs(4.0 / length(v2), v2_normalized[1], tol);

    const v3: Vec3 = .{ 1.0, 2.0, 2.0 };
    const v3_normalized = normalize(v3);
    try expectApproxEqAbs(1.0 / length(v3), v3_normalized[0], tol);
    try expectApproxEqAbs(2.0 / length(v3), v3_normalized[1], tol);
    try expectApproxEqAbs(2.0 / length(v3), v3_normalized[2], tol);

    const v4: Vec4 = .{ 1.0, 2.0, 2.0, 2.0 };
    const v4_normalized = normalize(v4);
    try expectApproxEqAbs(1.0 / length(v4), v4_normalized[0], tol);
    try expectApproxEqAbs(2.0 / length(v4), v4_normalized[1], tol);
    try expectApproxEqAbs(2.0 / length(v4), v4_normalized[2], tol);
    try expectApproxEqAbs(2.0 / length(v4), v4_normalized[3], tol);
}

pub fn cross(a: anytype, b: anytype) @TypeOf(a) {
    switch (@TypeOf(a)) {
        Vec3 => return .{
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        },
        else => @compileError("type is not a vector"),
    }
}

test "vec.cross" {
    const expectEqual = std.testing.expectEqual;

    const a: Vec3 = .{ 1.0, 0.0, 0.0 };
    const b: Vec3 = .{ 0.0, 1.0, 0.0 };
    const c = cross(a, b);
    try expectEqual(0.0, c[0]);
    try expectEqual(0.0, c[1]);
    try expectEqual(1.0, c[2]);
}

pub fn dot(a: anytype, b: anytype) ElementType(@TypeOf(a)) {
    std.debug.assert(@TypeOf(a) == @TypeOf(b));
    switch (@TypeOf(a)) {
        Vec2 => return a[0] * b[0] + a[1] * b[1],
        Vec3 => return a[0] * b[0] + a[1] * b[1] + a[2] * b[2],
        Vec4 => return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3],
        else => @compileError("type is not a vector"),
    }
}

test "vec.dot" {
    const expectEqual = std.testing.expectEqual;

    const a: Vec2 = .{ 1.0, 2.0 };
    const b: Vec2 = .{ 3.0, 4.0 };
    try expectEqual(1.0 * 3.0 + 2.0 * 4.0, dot(a, b));

    const c: Vec3 = .{ 1.0, 2.0, 3.0 };
    const d: Vec3 = .{ 4.0, 5.0, 6.0 };
    try expectEqual(1.0 * 4.0 + 2.0 * 5.0 + 3.0 * 6.0, dot(c, d));

    const e: Vec4 = .{ 1.0, 2.0, 3.0, 4.0 };
    const f: Vec4 = .{ 5.0, 6.0, 7.0, 8.0 };
    try expectEqual(1.0 * 5.0 + 2.0 * 6.0 + 3.0 * 7.0 + 4.0 * 8.0, dot(e, f));
}

pub fn mul(a: anytype, b: ElementType(@TypeOf(a))) @TypeOf(a) {
    switch (@TypeOf(a)) {
        Vec2 => return a * @as(Vec2, @splat(b)),
        Vec3 => return a * @as(Vec3, @splat(b)),
        Vec4 => return a * @as(Vec4, @splat(b)),
        else => @compileError("type is not a vector"),
    }
}

test "vec.mul" {
    const expectEqual = std.testing.expectEqual;

    const v2: Vec2 = .{ 1.0, 2.0 };
    const v2_mul = mul(v2, 3.0);
    try expectEqual(3.0, v2_mul[0]);
    try expectEqual(6.0, v2_mul[1]);

    const v3: Vec3 = .{ 1.0, 2.0, 3.0 };
    const v3_mul = mul(v3, 4.0);
    try expectEqual(4.0, v3_mul[0]);
    try expectEqual(8.0, v3_mul[1]);
    try expectEqual(12.0, v3_mul[2]);

    const v4: Vec4 = .{ 1.0, 2.0, 3.0, 4.0 };
    const v4_mul = mul(v4, 5.0);
    try expectEqual(5.0, v4_mul[0]);
    try expectEqual(10.0, v4_mul[1]);
    try expectEqual(15.0, v4_mul[2]);
    try expectEqual(20.0, v4_mul[3]);
}

pub fn div(a: anytype, b: ElementType(@TypeOf(a))) @TypeOf(a) {
    switch (@TypeOf(a)) {
        Vec2 => return a / @as(Vec2, @splat(b)),
        Vec3 => return a / @as(Vec3, @splat(b)),
        Vec4 => return a / @as(Vec4, @splat(b)),
        else => @compileError("type is not a vector"),
    }
}

test "vec.div" {
    const expectEqual = std.testing.expectEqual;

    const v2: Vec2 = .{ 1.0, 2.0 };
    const v2_div = div(v2, 2.0);
    try expectEqual(0.5, v2_div[0]);
    try expectEqual(1.0, v2_div[1]);

    const v3: Vec3 = .{ 1.0, 2.0, 3.0 };
    const v3_div = div(v3, 2.0);
    try expectEqual(0.5, v3_div[0]);
    try expectEqual(1.0, v3_div[1]);
    try expectEqual(1.5, v3_div[2]);

    const v4: Vec4 = .{ 1.0, 2.0, 3.0, 4.0 };
    const v4_div = div(v4, 2.0);
    try expectEqual(0.5, v4_div[0]);
    try expectEqual(1.0, v4_div[1]);
    try expectEqual(1.5, v4_div[2]);
    try expectEqual(2.0, v4_div[3]);
}

/// Is any of the elements NaN
pub fn isNan(v: anytype) bool {
    const _isNan = std.math.isNan;
    switch (@TypeOf(v)) {
        Vec2 => return _isNan(v[0]) or _isNan(v[1]),
        Vec3 => return _isNan(v[0]) or _isNan(v[1]) or _isNan(v[2]),
        Vec4 => return _isNan(v[0]) or _isNan(v[1]) or _isNan(v[2]) or _isNan(v[3]),
        else => @compileError("type is not a vector"),
    }
}

test "vec.isNan" {
    const expectEqual = std.testing.expectEqual;

    const v2: Vec2 = .{ 1.0, std.math.nan(f32) };
    try expectEqual(true, isNan(v2));

    const v3: Vec3 = .{ 1.0, 2.0, std.math.nan(f32) };
    try expectEqual(true, isNan(v3));

    const v4: Vec4 = .{ 1.0, 2.0, 3.0, std.math.nan(f32) };
    try expectEqual(true, isNan(v4));
}

pub fn numComponents(comptime T: type) comptime_int {
    switch (@typeInfo(T)) {
        .vector => |v| return v.len,
        else => @compileError("type is not a vector"),
    }
}

test "vec.numComponents" {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(2, numComponents(Vec2));
    try expectEqual(3, numComponents(Vec3));
    try expectEqual(4, numComponents(Vec4));
}

pub fn ElementType(comptime T: type) type {
    switch (@typeInfo(T)) {
        .vector => |v| return v.child,
        else => @compileError("type is not a vector"),
    }
}

test "vec.ElementType" {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(f32, ElementType(Vec2));
    try expectEqual(f32, ElementType(Vec3));
    try expectEqual(f32, ElementType(Vec4));
}

test "vec.Vec2" {
    const expectEqual = std.testing.expectEqual;

    // TODO: Investigate
    if (builtin.os.tag == .macos) {
        try expectEqual(8, @sizeOf(Vec2));
    } else {
        try expectEqual(16, @sizeOf(Vec2));
    }

    const v1: Vec2 = .{ 1.0, 2.0 };
    try expectEqual(1.0, v1[0]);
    try expectEqual(2.0, v1[1]);

    const v2: Vec2 = .{ 3.0, 4.0 };
    const v_add = v1 + v2;
    try expectEqual(4.0, v_add[0]);
    try expectEqual(6.0, v_add[1]);

    const v_sub = v1 - v2;
    try expectEqual(-2.0, v_sub[0]);
    try expectEqual(-2.0, v_sub[1]);

    const v_mul = v1 * v2;
    try expectEqual(3.0, v_mul[0]);
    try expectEqual(8.0, v_mul[1]);

    const v_div = v1 / v2;
    try expectEqual(1.0 / 3.0, v_div[0]);
    try expectEqual(2.0 / 4.0, v_div[1]);
}

test "vec.Vec3" {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(16, @sizeOf(Vec3));

    const v1: Vec3 = .{ 1.0, 2.0, 3.0 };
    try expectEqual(1.0, v1[0]);
    try expectEqual(2.0, v1[1]);
    try expectEqual(3.0, v1[2]);

    const v2: Vec3 = .{ 3.0, 4.0, 5.0 };
    const v_add = v1 + v2;
    try expectEqual(4.0, v_add[0]);
    try expectEqual(6.0, v_add[1]);
    try expectEqual(8.0, v_add[2]);

    const v_sub = v1 - v2;
    try expectEqual(-2.0, v_sub[0]);
    try expectEqual(-2.0, v_sub[1]);
    try expectEqual(-2.0, v_sub[2]);

    const v_mul = v1 * v2;
    try expectEqual(3.0, v_mul[0]);
    try expectEqual(8.0, v_mul[1]);
    try expectEqual(15.0, v_mul[2]);

    const v_div = v1 / v2;
    try expectEqual(1.0 / 3.0, v_div[0]);
    try expectEqual(2.0 / 4.0, v_div[1]);
    try expectEqual(3.0 / 5.0, v_div[2]);
}

test "vec.Vec4" {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(16, @sizeOf(Vec4));

    const v1: Vec4 = .{ 1.0, 2.0, 3.0, 4.0 };
    try expectEqual(1.0, v1[0]);
    try expectEqual(2.0, v1[1]);
    try expectEqual(3.0, v1[2]);
    try expectEqual(4.0, v1[3]);

    const v2: Vec4 = .{ 3.0, 4.0, 5.0, 6.0 };
    const v_add = v1 + v2;
    try expectEqual(4.0, v_add[0]);
    try expectEqual(6.0, v_add[1]);
    try expectEqual(8.0, v_add[2]);
    try expectEqual(10.0, v_add[3]);

    const v_sub = v1 - v2;
    try expectEqual(-2.0, v_sub[0]);
    try expectEqual(-2.0, v_sub[1]);
    try expectEqual(-2.0, v_sub[2]);
    try expectEqual(-2.0, v_sub[3]);

    const v_mul = v1 * v2;
    try expectEqual(3.0, v_mul[0]);
    try expectEqual(8.0, v_mul[1]);
    try expectEqual(15.0, v_mul[2]);
    try expectEqual(24.0, v_mul[3]);

    const v_div = v1 / v2;
    try expectEqual(1.0 / 3.0, v_div[0]);
    try expectEqual(2.0 / 4.0, v_div[1]);
    try expectEqual(3.0 / 5.0, v_div[2]);
    try expectEqual(4.0 / 6.0, v_div[3]);
}
