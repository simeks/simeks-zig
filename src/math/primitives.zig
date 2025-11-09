const math = @import("root.zig");
const vec = math.vec;
const Vec3 = math.Vec3;

pub const Aabb = extern struct {
    min: Vec3,
    max: Vec3,

    pub fn center(self: Aabb) Vec3 {
        return (self.min + self.max) * @as(Vec3, @splat(0.5));
    }
    pub fn size(self: Aabb) Vec3 {
        return self.max - self.min;
    }
    pub fn concat(self: Aabb, other: Aabb) Aabb {
        return .{
            .min = @min(self.min, other.min),
            .max = @max(self.max, other.max),
        };
    }
    pub fn overlaps(self: Aabb, other: Aabb) bool {
        return !(self.max[0] < other.min[0] or
            self.min[0] > other.max[0] or
            self.max[1] < other.min[1] or
            self.min[1] > other.max[1] or
            self.max[2] < other.min[2] or
            self.min[2] > other.max[2]);
    }
};
