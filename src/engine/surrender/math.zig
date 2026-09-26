//! Surrender's vector and matrix helpers. The binary does not name their file; their code lies
//! before `srAPI.cpp`'s. Matrices are 3x3, row-major, and a vector is turned by multiplying it on
//! the right.

const std = @import("std");

pub const Vector = @Vector(3, f32);
pub const Matrix = [9]f32;

pub const identity: Matrix = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

/// A matrix that stretches along each axis by `by`'s figure for it.
pub fn scaling(by: Vector) Matrix {
    return .{ by[0], 0, 0, 0, by[1], 0, 0, 0, by[2] };
}

test scaling {
    try std.testing.expectEqual(identity, scaling(@splat(1)));
    try std.testing.expectEqual(@as(Vector, .{ 2, 3, 4 }), transform(scaling(.{ 2, 3, 4 }), @splat(1)));
}

/// Where something stands and which way it faces: a position, and an orientation whose columns
/// are its right, down and forward axes.
pub const Place = struct {
    position: Vector = @splat(0),
    orientation: Matrix = identity,

    /// This place, standing in `parent`'s frame, as it stands in the world
    /// (`SR_object_concate_parents`, `0x004C3570`, one level up).
    pub fn within(place: Place, parent: Place) Place {
        return .{
            .position = parent.point(place.position),
            .orientation = product(parent.orientation, place.orientation),
        };
    }

    /// `local`, given in this place's own frame, in the world.
    pub fn point(place: Place, local: Vector) Vector {
        return transform(place.orientation, local) + place.position;
    }

    /// `at`, given in the world, in this place's own frame: the reverse of `point`.
    pub fn inverse(place: Place, at: Vector) Vector {
        return transformTransposed(place.orientation, at - place.position);
    }

    /// This place, standing in the world, as it stands in `parent`'s frame: the reverse of
    /// `within`.
    pub fn relativeTo(place: Place, parent: Place) Place {
        return .{
            .position = parent.inverse(place.position),
            .orientation = product(transpose(parent.orientation), place.orientation),
        };
    }
};

// The helpers add in the order the engine's do, which with the FPU rounding to single precision, as
// it does once Direct3D is running, gives the same results.

/// `vec3_dot` (`0x004C11C0`).
pub fn dot(a: Vector, b: Vector) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn cross(a: Vector, b: Vector) Vector {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// `vec3_length_squared` (`0x004C12A0`).
pub fn lengthSquared(v: Vector) f32 {
    return v[0] * v[0] + v[2] * v[2] + v[1] * v[1];
}

/// `vec3_length` (`0x004C1270`).
pub fn length(v: Vector) f32 {
    return @sqrt(lengthSquared(v));
}

/// How far apart two points are (`vec3_distance`, `0x004C12D0`).
pub fn distance(a: Vector, b: Vector) f32 {
    const d = a - b;
    return @sqrt(d[1] * d[1] + d[2] * d[2] + d[0] * d[0]);
}

/// The value `t` of the way from `a` to `b` (`lerp`, `0x004C1050`), or for vectors the point `t` of
/// the way, each component alike (`vec3_lerp`, `0x004C1070`).
pub fn lerp(a: anytype, b: anytype, t: f32) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    const share: T = if (@typeInfo(T) == .vector) @splat(t) else t;
    return (b - a) * share + a;
}

/// `angle` brought round to within a half turn either way: a turn less past a half turn, a turn
/// more below one the other way, once, as the game's turret code does.
pub fn halfTurn(angle: f32) f32 {
    if (angle > std.math.pi) return angle - std.math.tau;
    if (angle < -std.math.pi) return angle + std.math.tau;
    return angle;
}

/// `v` scaled to a length of 1 (`vec3_normalize`, `0x004C1370`). The zero vector becomes a tiny
/// one pointing forward.
pub fn normalize(v: Vector) Vector {
    const l = length(v);
    if (l == 0) return .{ 0, 0, 7.523164e-37 };
    return v * @as(Vector, @splat(1 / l));
}

/// `m` times `v` (`vec3_turn`, `0x004C22B0`; `mat3_transform`, `0x004C23C0`).
pub fn transform(m: Matrix, v: Vector) Vector {
    return .{
        m[1] * v[1] + m[2] * v[2] + m[0] * v[0],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    };
}

/// The third column of `m`, which for an orientation is the axis its nose points along
/// (`mat3_forward`, `0x004C18A0`).
pub fn forward(m: Matrix) Vector {
    return .{ m[2], m[5], m[8] };
}

/// The first column of `m`, which for an orientation is the axis its X points along: to its right.
pub fn xAxis(m: Matrix) Vector {
    return .{ m[0], m[3], m[6] };
}

/// The second column of `m`, which for an orientation is the axis its Y points along: down, in the
/// game's frame.
pub fn yAxis(m: Matrix) Vector {
    return .{ m[1], m[4], m[7] };
}

/// The transpose of `m` times `v`: for a rotation, `v` turned back (`vec3_turn_back`,
/// `0x004C2310`; `mat3_transform_transposed`, `0x004C2370`).
pub fn transformTransposed(m: Matrix, v: Vector) Vector {
    return .{
        m[3] * v[1] + m[6] * v[2] + m[0] * v[0],
        m[1] * v[0] + m[4] * v[1] + m[7] * v[2],
        m[2] * v[0] + m[5] * v[1] + m[8] * v[2],
    };
}

pub fn product(a: Matrix, b: Matrix) Matrix {
    var m: Matrix = undefined;
    for (0..3) |row| {
        for (0..3) |column| {
            m[row * 3 + column] = a[row * 3] * b[column] + a[row * 3 + 1] * b[3 + column] + a[row * 3 + 2] * b[6 + column];
        }
    }
    return m;
}

/// The determinant of a 3x3 matrix (`mat3_determinant`, `0x004C2070`), by the cofactors of its
/// first row.
///
/// The sums are made in wider arithmetic, as the engine's are on the x87 stack: a capital ship's
/// inertia tensor holds entries around 1e20, whose determinant an `f32` cannot hold.
pub fn determinant(m: Matrix) f64 {
    var wide: [9]f64 = undefined;
    for (&wide, m) |*value, term| value.* = term;
    return wide[0] * (wide[4] * wide[8] - wide[5] * wide[7]) -
        wide[1] * (wide[3] * wide[8] - wide[5] * wide[6]) +
        wide[2] * (wide[3] * wide[7] - wide[4] * wide[6]);
}

/// The inverse of a 3x3 matrix, its adjugate over its determinant, or null for a matrix that has
/// none (`mat3_inverse`, `0x004AD9F0`). The game divides by the determinant whatever it is, and
/// leaves infinities behind where it is zero.
pub fn inverse(m: Matrix) ?Matrix {
    const scale = determinant(m);
    if (scale == 0 or !std.math.isFinite(scale)) return null;
    var wide: [9]f64 = undefined;
    for (&wide, m) |*value, term| value.* = term;
    const over = 1 / scale;
    var out: Matrix = undefined;
    const adjugate = [9]f64{
        wide[4] * wide[8] - wide[5] * wide[7],
        -(wide[1] * wide[8] - wide[2] * wide[7]),
        wide[1] * wide[5] - wide[2] * wide[4],
        -(wide[8] * wide[3] - wide[5] * wide[6]),
        wide[8] * wide[0] - wide[2] * wide[6],
        -(wide[5] * wide[0] - wide[2] * wide[3]),
        wide[7] * wide[3] - wide[4] * wide[6],
        -(wide[0] * wide[7] - wide[1] * wide[6]),
        wide[4] * wide[0] - wide[1] * wide[3],
    };
    for (&out, adjugate) |*value, term| {
        const made = term * over;
        if (!std.math.isFinite(made)) return null;
        value.* = @floatCast(made);
    }
    return out;
}

pub fn transpose(m: Matrix) Matrix {
    return .{ m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8] };
}

/// The matrix whose columns are `x`, `y` and `z`: for an orientation, its right, down and forward
/// axes, as `mat3_from_axes` (`0x004C2610`) lays out the axes it works out.
pub fn fromAxes(x: Vector, y: Vector, z: Vector) Matrix {
    return .{ x[0], y[0], z[0], x[1], y[1], z[1], x[2], y[2], z[2] };
}

/// `mat3_orthonormalize` (`0x004C2690`): `m` with its axes, the columns, made unit length and
/// perpendicular again. The Z axis keeps its direction, the Y axis becomes Z × X normalized, and
/// the X axis Y × Z (`mat3_from_axes`, `0x004C2610`).
pub fn orthonormalize(m: Matrix) Matrix {
    const z = normalize(forward(m));
    const y = normalize(cross(z, xAxis(m)));
    return fromAxes(cross(y, z), y, z);
}

/// A corner of a box given by its two ends, low and high: which end it takes on each axis. Taken as
/// a number from 0 to 7, bit 0 picks the end across, bit 1 down and bit 2 forward.
pub const Corner = packed struct(u3) {
    x: u1,
    y: u1,
    z: u1,

    /// The corner numbered `n`.
    pub fn of(n: usize) Corner {
        return @bitCast(@as(u3, @intCast(n)));
    }

    /// Where the corner of the box from `ends[0]` to `ends[1]` stands.
    pub fn in(corner: Corner, ends: [2]Vector) Vector {
        return .{ ends[corner.x][0], ends[corner.y][1], ends[corner.z][2] };
    }
};

test fromAxes {
    const m = fromAxes(.{ 1, 2, 3 }, .{ 4, 5, 6 }, .{ 7, 8, 9 });
    try std.testing.expectEqual(Vector{ 1, 2, 3 }, xAxis(m));
    try std.testing.expectEqual(Vector{ 4, 5, 6 }, yAxis(m));
    try std.testing.expectEqual(Vector{ 7, 8, 9 }, forward(m));
}

test Corner {
    const ends = [2]Vector{ .{ -1, -2, -3 }, .{ 1, 2, 3 } };
    try std.testing.expectEqual(Vector{ -1, -2, -3 }, Corner.of(0).in(ends));
    try std.testing.expectEqual(Vector{ 1, -2, -3 }, Corner.of(1).in(ends));
    try std.testing.expectEqual(Vector{ -1, 2, -3 }, Corner.of(2).in(ends));
    try std.testing.expectEqual(Vector{ 1, 2, 3 }, Corner.of(7).in(ends));
}

/// `mat3_angles` (`0x004C2740`): the angles about X, Y and Z that make up `m`, in radians. When
/// the Y angle is close to a right angle, the X angle takes all of the turn and Z is 0.
///
/// **Improvement:** the engine looks the angles up in a table of arctangents in steps of 1/4096
/// (`sr_atan2`, `0x004C3200`). OpenReliant computes them, which is more precise by up to half a
/// step.
pub fn angles(m: Matrix) Vector {
    const across = @sqrt(m[1] * m[1] + m[0] * m[0]);
    const y = std.math.atan2(m[2], across);
    if (across > 1.6e-5) return .{ std.math.atan2(-m[5], m[8]), y, std.math.atan2(-m[1], m[0]) };
    return .{ std.math.atan2(m[7], m[4]), y, 0 };
}

/// A small turn by the angles `a` about X, Y and Z, to first order: turning a vector `v` by it
/// adds `cross(a, v)`.
pub fn smallTurn(a: Vector) Matrix {
    return .{ 1, -a[2], a[1], a[2], 1, -a[0], -a[1], a[0], 1 };
}

/// `x` rounded to the nearest whole number, halves to even, as the x87 rounds by default (`FISTP`).
pub fn roundEven(x: f32) f32 {
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5 and @mod(r, 2) != 0) return r - std.math.sign(x);
    return r;
}

/// `sr_round` (`0x004C3330`): `x` as a whole number, rounded as `roundEven` rounds. A value no
/// `i32` holds, or no number at all, gives the least `i32`, which is what the x87 stores for it.
pub fn round(x: f32) i32 {
    const r = roundEven(x);
    if (!(r >= -2147483648.0 and r < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(r);
}

/// `__ftol` (`0x004CF28C`), which the compiler calls to turn a float into an integer: `x` with its
/// fraction dropped, as a 64-bit integer whose low half an `int` keeps. A value no `i64` holds, or
/// no number at all, gives the x87's indefinite integer, whose low half is zero.
pub fn ftol(x: f32) i32 {
    const t = @trunc(x);
    if (!(t >= -0x1p63 and t < 0x1p63)) return 0;
    return @truncate(@as(i64, @intFromFloat(t)));
}

pub const Axis = enum { x, y, z };

/// A right-handed turn by `angle` radians about `axis`.
pub fn rotation(axis: Axis, angle: f32) Matrix {
    const c = @cos(angle);
    const s = @sin(angle);
    return switch (axis) {
        .x => .{ 1, 0, 0, 0, c, -s, 0, s, c },
        .y => .{ c, 0, s, 0, 1, 0, -s, 0, c },
        .z => .{ c, -s, 0, s, c, 0, 0, 0, 1 },
    };
}

/// `m` turned by `angle` about its own `axis`, `m` times the rotation (`mat3_turn_x`, `0x004C2100`;
/// `mat3_turn_y`, `0x004C2190`; `mat3_turn_z`, `0x004C2220`).
pub fn turned(m: Matrix, axis: Axis, angle: f32) Matrix {
    return product(m, rotation(axis, angle));
}

/// The rotation `mat3_from_angles` (`0x004C2410`) builds from a pitch, a yaw and a roll: turns
/// about `X`, then `Y`, then `Z`.
pub fn fromAngles(pitch: f32, yaw: f32, roll: f32) Matrix {
    const sp = @sin(pitch);
    const cp = @cos(pitch);
    const sy = @sin(yaw);
    const cy = @cos(yaw);
    const sr = @sin(roll);
    const cr = @cos(roll);
    return .{
        cr * cy,                -(sr * cy),             sy,
        sr * cp + cr * sy * sp, cr * cp - sr * sy * sp, -(cy * sp),
        sr * sp - cr * sy * cp, cr * sp + sr * sy * cp, cy * cp,
    };
}

/// `fromAngles` with the three angles in a vector, pitch, yaw and roll, as `angles` gives them.
pub fn fromAngleVector(v: Vector) Matrix {
    return fromAngles(v[0], v[1], v[2]);
}

/// An orientation whose forward axis, its third column, points along `direction`: turned about `Y`,
/// then about `X`, with no roll (`mat3_look_at`, `0x004C1940`).
///
/// **Improvement:** the engine takes the angles from `sr_atan2`'s table, as `angles` does.
/// OpenReliant computes them.
pub fn lookAt(direction: Vector) Matrix {
    const yaw = std.math.atan2(direction[0], direction[2]);
    const cy = @cos(yaw);
    const sy = @sin(yaw);
    // The direction's length in the turned frame, where its x is zero.
    const along = direction[0] * sy + direction[2] * cy;
    const pitch = std.math.atan2(direction[1], along);
    const cp = @cos(pitch);
    const sp = @sin(pitch);
    return .{
        cy,  -sy * sp, sy * cp,
        0,   cp,       sp,
        -sy, -cy * sp, cy * cp,
    };
}

fn expectVector(expected: Vector, actual: Vector) !void {
    inline for (0..3) |i| try std.testing.expectApproxEqAbs(expected[i], actual[i], 1e-5);
}

test lookAt {
    for ([_]Vector{ .{ 0, 0, 1 }, .{ 1, -0.5, 0.2 }, .{ -1, 0.5, 0 }, .{ 0.2, 0.9, -0.3 } }) |d| {
        const m = lookAt(normalize(d));
        try expectVector(normalize(d), transform(m, .{ 0, 0, 1 }));
        // No roll: the right axis stays level.
        try std.testing.expectApproxEqAbs(0, m[3], 1e-6);
        try expectVector(.{ 0, 0, 1 }, transformTransposed(m, normalize(d)));
    }
}

test smallTurn {
    const a: Vector = .{ 0.001, -0.002, 0.0015 };
    const v: Vector = .{ 3, -1, 2 };
    try expectVector(v + cross(a, v), transform(smallTurn(a), v));
    // To first order, the same as turning about each axis in turn.
    const turn = fromAngles(a[0], a[1], a[2]);
    for (turn, smallTurn(a)) |e, found| try std.testing.expectApproxEqAbs(e, found, 1e-5);
}

test round {
    try std.testing.expectEqual(2, round(2.5));
    try std.testing.expectEqual(4, round(3.5));
    try std.testing.expectEqual(-3, round(-3.4));
    try std.testing.expectEqual(std.math.minInt(i32), round(1e10));
    try std.testing.expectEqual(std.math.minInt(i32), round(std.math.nan(f32)));
}

test distance {
    try std.testing.expectEqual(5, distance(.{ 1, 5, 2 }, .{ 1, 1, 5 }));
    try std.testing.expectEqual(0, distance(.{ 7, 7, 7 }, .{ 7, 7, 7 }));
}

test ftol {
    try std.testing.expectEqual(3, ftol(3.7));
    try std.testing.expectEqual(-3, ftol(-3.7));
    // Past an `int`, the low half of the 64-bit integer.
    try std.testing.expectEqual(-1294967296, ftol(3e9));
    try std.testing.expectEqual(0, ftol(0x1p32));
    try std.testing.expectEqual(0, ftol(std.math.nan(f32)));
    try std.testing.expectEqual(0, ftol(0x1p70));
}

test lerp {
    const one: f32 = 1;
    try std.testing.expectEqual(1, lerp(one, 0.1, 0));
    try std.testing.expectEqual(3, lerp(@as(f32, 2), 6, 0.25));
    // In single precision the far end can miss `b` by the rounding of `b - a`, as the engine's
    // does.
    try std.testing.expectEqual(0.100000024, lerp(one, 0.1, 1));
    // A vector goes the same share of the way in each component.
    try std.testing.expectEqual(Vector{ 3, 1, -1 }, lerp(Vector{ 2, 0, 0 }, Vector{ 6, 4, -4 }, 0.25));
}

test Place {
    const place: Place = .{ .position = .{ 1, 2, 3 }, .orientation = .{ 0, -1, 0, 1, 0, 0, 0, 0, 1 } };
    const local: Vector = .{ 5, 0, 0 };
    const world = place.point(local);
    try std.testing.expectEqual(Vector{ 1, 7, 3 }, world);
    try std.testing.expectEqual(local, place.inverse(world));
    // A place taken into another's frame and back out stands where it stood.
    const other: Place = .{ .position = .{ -4, 0, 9 }, .orientation = fromAngles(0.3, -1.2, 0.5) };
    const back = other.relativeTo(place).within(place);
    try expectVector(other.position, back.position);
    for (other.orientation, back.orientation) |expected, actual| try std.testing.expectApproxEqAbs(expected, actual, 1e-6);
}

test halfTurn {
    try std.testing.expectEqual(1, halfTurn(1));
    try std.testing.expectApproxEqAbs(4 - std.math.tau, halfTurn(4), 1e-6);
    try std.testing.expectApproxEqAbs(std.math.tau - 4, halfTurn(-4), 1e-6);
    // Once only: two turns past, it comes round by one.
    try std.testing.expectApproxEqAbs(8 - std.math.tau, halfTurn(8), 1e-6);
}

test normalize {
    try std.testing.expectEqual(@as(Vector, .{ 0.6, 0, 0.8 }), normalize(.{ 3, 0, 4 }));
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 7.523164e-37 }), normalize(.{ 0, 0, 0 }));
}

test fromAngles {
    try std.testing.expectEqual(identity, fromAngles(0, 0, 0));
    // A yaw of -90 degrees turns the forward axis to -X.
    try expectVector(.{ -1, 0, 0 }, transform(fromAngles(0, -std.math.pi / 2.0, 0), .{ 0, 0, 1 }));
}

test roundEven {
    try std.testing.expectEqual(2, roundEven(2.5));
    try std.testing.expectEqual(4, roundEven(3.5));
    try std.testing.expectEqual(-2, roundEven(-2.5));
    try std.testing.expectEqual(3, roundEven(2.6));
    try std.testing.expectEqual(128, roundEven(127.5));
}

test turned {
    // A quarter turn about Y takes forward to +X, about X takes down to forward.
    try expectVector(.{ 1, 0, 0 }, transform(rotation(.y, std.math.pi / 2.0), .{ 0, 0, 1 }));
    try expectVector(.{ 0, 0, 1 }, transform(rotation(.x, std.math.pi / 2.0), .{ 0, 1, 0 }));
    try expectVector(.{ 0, 1, 0 }, transform(rotation(.z, std.math.pi / 2.0), .{ 1, 0, 0 }));
    // `fromAngles` is the three turns in order.
    const m = turned(turned(turned(identity, .x, 0.3), .y, -0.7), .z, 0.2);
    for (fromAngles(0.3, -0.7, 0.2), m) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-6);
}

test product {
    const m = fromAngles(0.3, -0.7, 0.2);
    const back = product(transpose(m), m);
    for (identity, back) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-5);
    try std.testing.expectEqual(@as(f32, 3), dot(.{ 1, 1, 1 }, .{ 1, 1, 1 }));
    try expectVector(.{ 0, 0, 1 }, cross(.{ 1, 0, 0 }, .{ 0, 1, 0 }));
}

test orthonormalize {
    // A rotation stays as it is; a skewed, stretched one comes back square, keeping its Z axis.
    const turn = rotation(.y, 0.5);
    for (turn, orthonormalize(turn)) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-6);
    const skewed: Matrix = .{ 2, 0.3, 0, 0, 1, 0, 0.2, 0, 3 };
    const square = orthonormalize(skewed);
    const x: Vector = .{ square[0], square[3], square[6] };
    const y: Vector = .{ square[1], square[4], square[7] };
    const z: Vector = .{ square[2], square[5], square[8] };
    try std.testing.expectApproxEqAbs(1, length(x), 1e-6);
    try std.testing.expectApproxEqAbs(0, dot(x, y), 1e-6);
    try std.testing.expectApproxEqAbs(0, dot(y, z), 1e-6);
    try std.testing.expectApproxEqAbs(0, z[0], 1e-6);
}

test angles {
    // A turn about one axis at a time gives that angle back.
    for ([_]Axis{ .x, .y, .z }, 0..) |axis, index| {
        const found: [3]f32 = angles(rotation(axis, 0.3));
        for (found, 0..) |angle, i| try std.testing.expectApproxEqAbs(if (i == index) @as(f32, 0.3) else 0, angle, 1e-6);
    }
    try std.testing.expectEqual(Vector{ 0, 0, 0 }, angles(identity));
    // At a right angle about Y, the X angle takes all of the turn and Z is 0.
    const found: [3]f32 = angles(fromAngles(0.4, std.math.pi / 2.0, 0.2));
    try std.testing.expectApproxEqAbs(0.6, found[0], 1e-6);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, found[1], 1e-6);
    try std.testing.expectEqual(0, found[2]);
}

test inverse {
    // A matrix times its inverse is the identity.
    const m: Matrix = .{ 2, 0, 0, 0, 4, 0, 1, 0, 8 };
    try std.testing.expectEqual(64, determinant(m));
    const back = inverse(m).?;
    for (product(m, back), identity) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
    // A matrix that flattens space has none.
    try std.testing.expectEqual(null, inverse(.{ 1, 2, 3, 2, 4, 6, 0, 0, 1 }));

    // A capital ship's inertia tensor: its determinant runs past what an f32 holds, and the
    // inverse still comes out.
    const heavy: Matrix = .{ 2e20, 0, 0, 0, 4e20, 0, 0, 0, 8e20 };
    const thin = inverse(heavy).?;
    try std.testing.expectApproxEqRel(5e-21, thin[0], 1e-6);
    try std.testing.expectApproxEqRel(1.25e-21, thin[8], 1e-6);
    // One so heavy that even the inverse's own terms vanish is no matrix to turn by.
    try std.testing.expectEqual(null, inverse(@splat(std.math.inf(f32))));
}
