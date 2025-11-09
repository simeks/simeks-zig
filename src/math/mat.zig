//! Matrix math
//! Some references:
//! * https://lxjk.github.io/2017/09/03/Fast-4x4-Matrix-Inverse-with-SSE-SIMD-Explained.html#_appendix_1
//! * https://github.com/zig-gamedev/zig-gamedev/tree/main/libs/zmath
//!
const std = @import("std");
const vec = @import("vec.zig");
const Vec = vec.Vec;
const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;
const Quat = @import("quat.zig").Quat;

pub const Mat4 = extern struct {
    pub const T = f32;

    const nrows = 4;
    const ncols = 4;

    const Column = @Vector(4, f32);

    cols: [ncols]Column,

    pub const identity: Mat4 = .fromCols(
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    );
    pub const zero: Mat4 = .fromCols(
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 0.0 },
    );
    pub fn fromCols(
        c0: Column,
        c1: Column,
        c2: Column,
        c3: Column,
    ) Mat4 {
        return .{ .cols = .{
            c0,
            c1,
            c2,
            c3,
        } };
    }
    pub fn fromQuat(q: Quat) Mat4 {
        const qxx = q[0] * q[0];
        const qyy = q[1] * q[1];
        const qzz = q[2] * q[2];
        const qxz = q[0] * q[2];
        const qxy = q[0] * q[1];
        const qyz = q[1] * q[2];
        const qwx = q[3] * q[0];
        const qwy = q[3] * q[1];
        const qwz = q[3] * q[2];

        return .fromCols(
            .{ 1.0 - 2.0 * (qyy + qzz), 2.0 * (qxy + qwz), 2.0 * (qxz - qwy), 0.0 },
            .{ 2.0 * (qxy - qwz), 1.0 - 2.0 * (qxx + qzz), 2.0 * (qyz + qwx), 0.0 },
            .{ 2.0 * (qxz + qwy), 2.0 * (qyz - qwx), 1.0 - 2.0 * (qxx + qyy), 0.0 },
            .{ 0.0, 0.0, 0.0, 1.0 },
        );
    }
    pub fn transpose(self: Mat4) Mat4 {
        return .fromCols(
            .{ self.cols[0][0], self.cols[1][0], self.cols[2][0], self.cols[3][0] },
            .{ self.cols[0][1], self.cols[1][1], self.cols[2][1], self.cols[3][1] },
            .{ self.cols[0][2], self.cols[1][2], self.cols[2][2], self.cols[3][2] },
            .{ self.cols[0][3], self.cols[1][3], self.cols[2][3], self.cols[3][3] },
        );
    }

    pub fn inverse(self: Mat4) Mat4 {
        return mat4Inverse(self);
    }

    pub fn scale(self: Mat4, b: Vec3) Mat4 {
        return .fromCols(
            self.cols[0] * @as(Vec4, @splat(b[0])),
            self.cols[1] * @as(Vec4, @splat(b[1])),
            self.cols[2] * @as(Vec4, @splat(b[2])),
            self.cols[3],
        );
    }

    fn splat(value: T) Mat4 {
        return .{ .cols = @splat(value) };
    }
};

test "Mat4" {
    const mat_identity = Mat4.identity;
    try mat4ExpectEqual(.{
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    }, mat_identity);

    const mat_zero = Mat4.zero;
    try mat4ExpectEqual(.{
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 0.0 },
    }, mat_zero);

    const mat = Mat4.fromCols(
        .{ 1.0, 2.0, 3.0, 4.0 },
        .{ 4.0, 5.0, 6.0, 7.0 },
        .{ 7.0, 8.0, 9.0, 10.0 },
        .{ 11.0, 12.0, 13.0, 14.0 },
    );
    try mat4ExpectEqual(.{
        .{ 1.0, 2.0, 3.0, 4.0 },
        .{ 4.0, 5.0, 6.0, 7.0 },
        .{ 7.0, 8.0, 9.0, 10.0 },
        .{ 11.0, 12.0, 13.0, 14.0 },
    }, mat);

    const mat_transpose = mat.transpose();
    try mat4ExpectEqual(.{
        .{ 1.0, 4.0, 7.0, 11.0 },
        .{ 2.0, 5.0, 8.0, 12.0 },
        .{ 3.0, 6.0, 9.0, 13.0 },
        .{ 4.0, 7.0, 10.0, 14.0 },
    }, mat_transpose);
}

pub fn mulMat4Mat4(a: Mat4, b: Mat4) Mat4 {
    const VecT = @Vector(4, Mat4.T);
    var cols: [4]VecT = undefined;
    inline for (0..4) |col| {
        cols[col] = a.cols[0] * vec.swizzle(b.cols[col], .{ .x, .x, .x, .x });
        cols[col] += a.cols[1] * vec.swizzle(b.cols[col], .{ .y, .y, .y, .y });
        cols[col] += a.cols[2] * vec.swizzle(b.cols[col], .{ .z, .z, .z, .z });
        cols[col] += a.cols[3] * vec.swizzle(b.cols[col], .{ .w, .w, .w, .w });
    }
    return Mat4.fromCols(cols[0], cols[1], cols[2], cols[3]);
}

test "mulMat4Mat4" {
    const mat1 = Mat4.fromCols(
        .{ 0, 1, 2, 3 },
        .{ 4, 5, 6, 7 },
        .{ 8, 9, 10, 11 },
        .{ 12, 13, 14, 15 },
    );
    const mat2 = Mat4.fromCols(
        .{ 0, 1, 2, 10 },
        .{ 4, 5, 6, 7 },
        .{ 8, 9, 10, 11 },
        .{ 12, 13, 204, 15 },
    );
    const res = mulMat4Mat4(mat1, mat2);
    try mat4ExpectEqual(.{
        .{ 140, 153, 166, 179 },
        .{ 152, 174, 196, 218 },
        .{ 248, 286, 324, 362 },
        .{ 1864, 2108, 2352, 2596 },
    }, res);
}

pub fn mulMat4Vec4(a: Mat4, b: Vec4) Vec4 {
    const vx = vec.swizzle(b, .{ .x, .x, .x, .x });
    const vy = vec.swizzle(b, .{ .y, .y, .y, .y });
    const vz = vec.swizzle(b, .{ .z, .z, .z, .z });
    const vw = vec.swizzle(b, .{ .w, .w, .w, .w });

    return vx * a.cols[0] + vy * a.cols[1] + vz * a.cols[2] + vw * a.cols[3];
}

test "mulMat4Vec4" {
    const expect = std.testing.expect;
    const mat = Mat4.fromCols(
        .{ 1, 0, 1, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    );
    const v = Vec4{ 1, 2, 3, 4 };
    const res = mulMat4Vec4(mat, v);
    try expect(res[0] == 1);
    try expect(res[1] == 2);
    try expect(res[2] == 4);
    try expect(res[3] == 4);
}

fn mat4Inverse(m: Mat4) Mat4 {
    const T = Mat4.T;
    const VecT = @Vector(4, T);

    var v0: [4]VecT = undefined;
    var v1: [4]VecT = undefined;

    v0[0] = @shuffle(T, m.cols[2], undefined, [4]i32{ 0, 0, 1, 1 });
    v1[0] = @shuffle(T, m.cols[3], undefined, [4]i32{ 2, 3, 2, 3 });
    v0[1] = @shuffle(T, m.cols[0], undefined, [4]i32{ 0, 0, 1, 1 });
    v1[1] = @shuffle(T, m.cols[1], undefined, [4]i32{ 2, 3, 2, 3 });
    v0[2] = @shuffle(T, m.cols[2], m.cols[0], [4]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) });
    v1[2] = @shuffle(T, m.cols[3], m.cols[1], [4]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) });

    var d0 = v0[0] * v1[0];
    var d1 = v0[1] * v1[1];
    var d2 = v0[2] * v1[2];

    v0[0] = @shuffle(T, m.cols[2], undefined, [4]i32{ 2, 3, 2, 3 });
    v1[0] = @shuffle(T, m.cols[3], undefined, [4]i32{ 0, 0, 1, 1 });
    v0[1] = @shuffle(T, m.cols[0], undefined, [4]i32{ 2, 3, 2, 3 });
    v1[1] = @shuffle(T, m.cols[1], undefined, [4]i32{ 0, 0, 1, 1 });
    v0[2] = @shuffle(T, m.cols[2], m.cols[0], [4]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) });
    v1[2] = @shuffle(T, m.cols[3], m.cols[1], [4]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) });

    d0 = -v0[0] * v1[0] + d0;
    d1 = -v0[1] * v1[1] + d1;
    d2 = -v0[2] * v1[2] + d2;

    v0[0] = @shuffle(T, m.cols[1], undefined, [4]i32{ 1, 2, 0, 1 });
    v1[0] = @shuffle(T, d0, d2, [4]i32{ ~@as(i32, 1), 1, 3, 0 });
    v0[1] = @shuffle(T, m.cols[0], undefined, [4]i32{ 2, 0, 1, 0 });
    v1[1] = @shuffle(T, d0, d2, [4]i32{ 3, ~@as(i32, 1), 1, 2 });
    v0[2] = @shuffle(T, m.cols[3], undefined, [4]i32{ 1, 2, 0, 1 });
    v1[2] = @shuffle(T, d1, d2, [4]i32{ ~@as(i32, 3), 1, 3, 0 });
    v0[3] = @shuffle(T, m.cols[2], undefined, [4]i32{ 2, 0, 1, 0 });
    v1[3] = @shuffle(T, d1, d2, [4]i32{ 3, ~@as(i32, 3), 1, 2 });

    var c0 = v0[0] * v1[0];
    var c2 = v0[1] * v1[1];
    var c4 = v0[2] * v1[2];
    var c6 = v0[3] * v1[3];

    v0[0] = @shuffle(T, m.cols[1], undefined, [4]i32{ 2, 3, 1, 2 });
    v1[0] = @shuffle(T, d0, d2, [4]i32{ 3, 0, 1, ~@as(i32, 0) });
    v0[1] = @shuffle(T, m.cols[0], undefined, [4]i32{ 3, 2, 3, 1 });
    v1[1] = @shuffle(T, d0, d2, [4]i32{ 2, 1, ~@as(i32, 0), 0 });
    v0[2] = @shuffle(T, m.cols[3], undefined, [4]i32{ 2, 3, 1, 2 });
    v1[2] = @shuffle(T, d1, d2, [4]i32{ 3, 0, 1, ~@as(i32, 2) });
    v0[3] = @shuffle(T, m.cols[2], undefined, [4]i32{ 3, 2, 3, 1 });
    v1[3] = @shuffle(T, d1, d2, [4]i32{ 2, 1, ~@as(i32, 2), 0 });

    c0 = -v0[0] * v1[0] + c0;
    c2 = -v0[1] * v1[1] + c2;
    c4 = -v0[2] * v1[2] + c4;
    c6 = -v0[3] * v1[3] + c6;

    v0[0] = @shuffle(T, m.cols[1], undefined, [4]i32{ 3, 0, 3, 0 });
    v1[0] = @shuffle(T, d0, d2, [4]i32{ 2, ~@as(i32, 1), ~@as(i32, 0), 2 });
    v0[1] = @shuffle(T, m.cols[0], undefined, [4]i32{ 1, 3, 0, 2 });
    v1[1] = @shuffle(T, d0, d2, [4]i32{ ~@as(i32, 1), 0, 3, ~@as(i32, 0) });
    v0[2] = @shuffle(T, m.cols[3], undefined, [4]i32{ 3, 0, 3, 0 });
    v1[2] = @shuffle(T, d1, d2, [4]i32{ 2, ~@as(i32, 3), ~@as(i32, 2), 2 });
    v0[3] = @shuffle(T, m.cols[2], undefined, [4]i32{ 1, 3, 0, 2 });
    v1[3] = @shuffle(T, d1, d2, [4]i32{ ~@as(i32, 3), 0, 3, ~@as(i32, 2) });

    const c1 = -v0[0] * v1[0] + c0;
    const c3 = v0[1] * v1[1] + c2;
    const c5 = -v0[2] * v1[2] + c4;
    const c7 = v0[3] * v1[3] + c6;

    c0 = v0[0] * v1[0] + c0;
    c2 = -v0[1] * v1[1] + c2;
    c4 = v0[2] * v1[2] + c4;
    c6 = -v0[3] * v1[3] + c6;

    var new_cols = .{
        VecT{ c0[0], c2[0], c4[0], c6[0] },
        VecT{ c1[1], c3[1], c5[1], c7[1] },
        VecT{ c0[2], c2[2], c4[2], c6[2] },
        VecT{ c1[3], c3[3], c5[3], c7[3] },
    };

    const dot_0 = VecT{ c0[0], c1[1], c0[2], c1[3] } * m.cols[0];
    var dot_1 = @shuffle(T, dot_0, undefined, [4]i32{ 1, 0, 3, 2 });
    dot_1 = dot_0 + dot_1;
    const det = dot_1[0] + dot_1[2];

    if (std.math.approxEqAbs(T, det, 0.0, std.math.floatEps(T))) {
        return Mat4.zero;
    }

    const scale: VecT = @splat(1.0 / det);
    new_cols[0] *= scale;
    new_cols[1] *= scale;
    new_cols[2] *= scale;
    new_cols[3] *= scale;
    return Mat4.fromCols(
        new_cols[0],
        new_cols[1],
        new_cols[2],
        new_cols[3],
    );
}

test "mat4Inverse" {
    const mat = Mat4.fromCols(
        .{ 1, 0, 1, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    );

    const mat_inverse = mat.inverse();
    const mat_actual = mulMat4Mat4(mat, mat_inverse);

    try mat4ExpectEqual(.{
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    }, mat_actual);
}

fn mat4ExpectEqual(expected: [4][4]f32, actual: Mat4) !void {
    const tol = 0.0001;

    const expectApproxEqAbs = std.testing.expectApproxEqAbs;
    for (0..4) |i| {
        for (0..4) |j| {
            try expectApproxEqAbs(actual.cols[i][j], expected[i][j], tol);
        }
    }
}
