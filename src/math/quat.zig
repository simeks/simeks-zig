const std = @import("std");
const vec = @import("vec.zig");
const Vec3 = vec.Vec3;

/// x, y, z, w
pub const Quat = @Vector(4, f32);
pub const identity: Quat = .{ 0.0, 0.0, 0.0, 1.0 };

pub fn fromEulerAngle(a: Vec3) Quat {
    const c = @cos(vec.mul(a, 0.5));
    const s = @sin(vec.mul(a, 0.5));

    return .{
        s[0] * c[1] * c[2] - c[0] * s[1] * s[2],
        c[0] * s[1] * c[2] + s[0] * c[1] * s[2],
        c[0] * c[1] * s[2] - s[0] * s[1] * c[2],
        c[0] * c[1] * c[2] + s[0] * s[1] * s[2],
    };
}
pub fn mulQuat(a: Quat, b: Quat) Quat {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}
pub fn mulQuatVec3(q: Quat, v: Vec3) Vec3 {
    const uv = vec.cross(Vec3{ q[0], q[1], q[2] }, v);
    const uuv = vec.cross(Vec3{ q[0], q[1], q[2] }, uv);
    return v + vec.mul(vec.mul(uv, q[3]) + uuv, 2.0);
}
pub fn pitch(q: Quat) f32 {
    const y = 2.0 * (q[1] * q[2] + q[3] * q[0]);
    const x = q[3] * q[3] - q[0] * q[0] - q[1] * q[1] + q[2] * q[2];
    return std.math.atan2(y, x);
}
pub fn yaw(q: Quat) f32 {
    return std.math.asin(
        std.math.clamp(-2.0 * (q[0] * q[2] - q[3] * q[1]), -1.0, 1.0),
    );
}
pub fn roll(q: Quat) f32 {
    const y = 2 * (q[0] * q[1] + q[3] * q[2]);
    const x = q[3] * q[3] + q[0] * q[0] - q[1] * q[1] - q[2] * q[2];
    return std.math.atan2(y, x);
}
pub fn conjugate(q: Quat) Quat {
    return .{ -q[0], -q[1], -q[2], q[3] };
}

pub fn fromAxisAngle(axis: Vec3, angle: f32) Quat {
    const half_angle = angle * 0.5;
    const s = @sin(half_angle);
    const c = @cos(half_angle);
    return .{ axis[0] * s, axis[1] * s, axis[2] * s, c };
}

test "pitch yaw roll" {
    const expectApproxEqAbs = std.testing.expectApproxEqAbs;

    const x = 1.0;
    const y = 0.1;
    const z = 2.2;

    const q = fromEulerAngle(.{ x, y, z });
    try expectApproxEqAbs(x, pitch(q), 0.000001);
    try expectApproxEqAbs(y, yaw(q), 0.000001);
    try expectApproxEqAbs(z, roll(q), 0.000001);
}
