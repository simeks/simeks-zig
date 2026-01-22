const std = @import("std");

pub const vec = @import("vec.zig");
pub const Vec2 = vec.Vec2;
pub const Vec3 = vec.Vec3;
pub const Vec4 = vec.Vec4;
pub const shuffle = vec.shuffle;
pub const swizzle = vec.swizzle;
pub const normalize = vec.normalize;
pub const length = vec.length;
pub const toVec4 = vec.toVec4;
pub const toVec3 = vec.toVec3;

pub const mat = @import("mat.zig");
pub const Mat3 = mat.Mat3;
pub const Mat4 = mat.Mat4;

pub const quat = @import("quat.zig");
pub const Quat = quat.Quat;
pub const fromEulerAngle = quat.fromEulerAngle;

const primitives = @import("primitives.zig");
pub const Aabb = primitives.Aabb;

pub fn identity(Type: type) Type {
    switch (Type) {
        Mat4 => return Mat4.identity,
        Quat => return quat.identity,
        else => @compileError("Unsupported type"),
    }
}

pub fn mul(a: anytype, b: anytype) @TypeOf(b) {
    const Ta = @TypeOf(a);
    const Tb = @TypeOf(b);
    if (Ta == Mat4 and Tb == Mat4) {
        return mat.mulMat4Mat4(a, b);
    } else if (Ta == Mat4 and Tb == Vec4) {
        return mat.mulMat4Vec4(a, b);
    } else if (Ta == Quat and Tb == Quat) {
        return quat.mulQuat(a, b);
    } else if (Ta == Quat and Tb == Vec3) {
        return quat.mulQuatVec3(a, b);
    } else if (Ta == Vec3 and Tb == Vec3) {
        return a * b;
    } else {
        @compileError("Unsupported multiplication");
    }
}

pub fn isNan(a: anytype) bool {
    switch (@TypeOf(a)) {
        Vec2 => return vec.isNan(a),
        Vec3 => return vec.isNan(a),
        Vec4 => return vec.isNan(a),
        else => @compileError("Not implemented"),
    }
}

test {
    _ = @import("mat.zig");
    _ = @import("primitives.zig");
    _ = @import("quat.zig");
    _ = @import("vec.zig");
}
