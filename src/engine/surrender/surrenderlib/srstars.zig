//! `C:\lancer\surrender\surrenderlib\srstars.cpp`: star fields, scene objects of type 7. The driver
//! draws each visible star as a point, or as a line back to where it was last frame when that is
//! more than a pixel away, the tail at half brightness.

const std = @import("std");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

const engine = @import("../../../engine.zig");
const Pointer = engine.Pointer;
const shp = @import("../../../formats/shp.zig");
const math = @import("../math.zig");
const srapi = @import("srapi.zig");
const srapiext = @import("srapiext.zig");
const Vector = math.Vector;

/// A star field (`stars_create`, `0x004C5240`): its stars' positions and colours, and what
/// `stars_project` (`0x004C5380`) makes of them each frame.
pub const Stars = extern struct {
    object: srapiext.Frame,
    /// Its depth key while in a layer's list of blended objects.
    sort_key: u32,
    /// `material`.
    drawn: Pointer(srapiext.Material),
    /// The next in a layer's list of blended objects.
    blended_next: Pointer(Stars),
    /// The object itself.
    self: Pointer(Stars),
    kind: Kind,
    /// Dust: the field's offset from the camera last frame.
    previous_offset: shp.Vec3,
    /// The rotation into the camera's frame last frame.
    previous_rotation: [9]f32,
    /// Untextured, lit and added: each star takes its own colour.
    material: srapiext.Material,
    count: u32,
    /// Stars drawn this frame, listed in `visible_indices`.
    visible: u32,
    /// Four floats a star. Sky: `(x, y, 1)` in the field's frame. Dust: within the cube.
    positions: Pointer(f32),
    /// Four floats a star: red, green and blue at `[1]` to `[3]`.
    colours: Pointer(f32),
    /// One a visible star.
    brightness: Pointer(f32),
    /// Two floats a visible star: its position over its depth, this frame and last.
    screen: Pointer(f32),
    previous_screen: Pointer(f32),
    visible_indices: Pointer(u16),
    /// Dust: the cube's side less one. Positions wrap by masking with it.
    cube_mask: u32,
    /// `2000.0`. **Unknown.**
    _unknown_12c: f32,

    pub const Kind = enum(u32) {
        /// At infinity: only the camera's rotation moves it.
        sky = 0,
        /// A cube of motes around the camera, wrapping as it moves.
        dust = 1,
        _,
    };

    comptime {
        assert(@offsetOf(Stars, "kind") == 0xC4);
        assert(@offsetOf(Stars, "material") == 0xF8);
        assert(@offsetOf(Stars, "count") == 0x108);
        assert(@sizeOf(Stars) == 0x130);
    }
};

/// A sky field is drawn only while its axis is within this cosine of the view axis, or of its
/// opposite. A field behind the camera is drawn mirrored through it, so each field also covers the
/// opposite part of the sky.
pub const field_cosine: f32 = 0.6;

pub const FieldView = enum {
    hidden,
    ahead,
    mirrored,

    /// What turns a star's cosine with the view axis toward the field's side of it.
    fn sign(view: FieldView) f32 {
        return if (view == .mirrored) -1 else 1;
    }
};

/// How a sky field is drawn, for the cosine of its axis with the view axis: mirrored for a negative
/// one, and hidden where, made positive, it falls short of `field_cosine`.
pub fn fieldView(cosine: f32) FieldView {
    const view: FieldView = if (cosine < 0) .mirrored else .ahead;
    if (cosine * view.sign() < field_cosine) return .hidden;
    return view;
}

/// A sky star is drawn only while its direction is within the first cosine of the view axis this
/// frame and last, and within the second in at least one of them.
pub const star_cosines = [2]f64{ 0.6, 0.7 };

/// Whether a sky star is drawn, for the cosines of its direction with the view axis this frame and
/// last.
pub fn starShown(now: f32, last: f32) bool {
    return now >= star_cosines[0] and last >= star_cosines[0] and (now >= star_cosines[1] or last >= star_cosines[1]);
}

/// Longest streak, in view units: a star's screen position over its depth, before scaling to the
/// viewport (`0x004DC420`). A longer one is cut back along its line.
pub const streak_limit: f32 = 0.1;

/// How much a star's motion since last frame dims it: its brightness is divided by the motion,
/// `|dx| + |dy|` in view units, times this, plus 1 (`0x004DC440`).
const motion_dimming: f32 = 100;

fn dimming(motion: f32) f32 {
    return motion * motion_dimming + 1;
}

/// A dust mote's brightness falls off with its distance squared over the cube's side squared,
/// from `dust_near` times that far off to nothing at a quarter of it, half the side away
/// (`0x004DC848`, `0x004DC3D4`).
const dust_near: f32 = 16;
const dust_reach: f32 = 0.25;

/// A sky star's brightness, for `motion`, `|dx| + |dy|` in view units since last frame.
pub fn skyBrightness(motion: f32) f32 {
    return std.math.clamp(1 / dimming(motion), 0, 1);
}

/// A dust mote's brightness at `distance_squared` from the camera: full nearby, gone by half the
/// cube's side.
pub fn dustBrightness(distance_squared: f32, cube_mask: u32, motion: f32) f32 {
    const side: f32 = @floatFromInt(cube_mask);
    return std.math.clamp((dust_reach - distance_squared / (side * side)) * dust_near / dimming(motion), 0, 1);
}

/// A star field as OpenReliant holds it (`stars_create`).
pub const Field = struct {
    kind: Stars.Kind,
    flags: srapiext.ObjectFlags = .{ .fresh = true },
    /// Dust: where the cube's origin is in the world; it wraps round the camera.
    position: Vector = @splat(0),
    /// The field's frame: a sky field is turned to face its axis.
    orientation: math.Matrix = math.identity,
    /// Untextured, lit and added: each star takes its own colour.
    surface: srapiext.Surface = .{ .material = .onePass(.{ .coordinates = .none, .lit = true, .blend = .add }) },
    stars: []const Star,
    /// Dust: the cube's side less one; positions wrap by masking with it.
    cube_mask: u32 = 0,
    /// Last frame's rotation into the camera's frame, and the dust's offset from the camera.
    previous_rotation: math.Matrix = math.identity,
    previous_offset: Vector = @splat(0),
    /// Dust: its streaks cut to a quarter of the usual length (`jump_stretch`), as they are while
    /// the player's ship jumps in (`0x005E82F0`).
    shortened: bool = false,
};

/// How many times shorter the dust's streaks are cut while the player's ship jumps in
/// (`0x004DC424`).
const jump_stretch: f32 = 4;

pub const Star = struct {
    /// Sky: `(x, y, 1)` in the field's frame. Dust: in the cube.
    position: Vector,
    /// Red, green and blue.
    colour: [3]f32,
};

/// A star this frame: its place in view units now and last frame, and its brightness.
pub const Visible = struct {
    index: u32,
    now: [2]f32,
    before: [2]f32,
    brightness: f32,
};

pub const Drawn = struct {
    field: *const Field,
    visible: []const Visible,
};

/// Projects a star field for the frame (`stars_project`), with last frame's places for streaks.
/// Null when the field is out of view.
pub fn project(arena: Allocator, context: *const srapi.Context, field: *Field) Allocator.Error!?*const Drawn {
    defer field.flags.fresh = false;
    const rotation = context.objectMatrix(field.orientation, 1);
    var visible: std.ArrayList(Visible) = .empty;
    switch (field.kind) {
        .sky => {
            const previous = if (field.flags.fresh) rotation else field.previous_rotation;
            field.previous_rotation = rotation;
            const sign = switch (fieldView(rotation[8])) {
                .hidden => return null,
                else => |view| view.sign(),
            };
            for (field.stars, 0..) |star, index| {
                const p = star.position;
                const z = row(rotation, 2, p);
                const z_before = row(previous, 2, p);
                if (!starShown(z * sign, z_before * sign)) continue;
                const now = [2]f32{ row(rotation, 0, p) / z, row(rotation, 1, p) / z };
                var before = [2]f32{ row(previous, 0, p) / z_before, row(previous, 1, p) / z_before };
                const motion = shorten(now, &before, 1);
                var cut_now = now;
                if (!streakClip(context.projection.bounds, &cut_now, &before)) continue;
                try visible.append(arena, .{ .index = @intCast(index), .now = cut_now, .before = before, .brightness = skyBrightness(motion) });
            }
        },
        .dust => {
            const offset = field.position - context.camera.position;
            const previous = if (field.flags.fresh) rotation else field.previous_rotation;
            const previous_offset = if (field.flags.fresh) offset else field.previous_offset;
            field.previous_rotation = rotation;
            field.previous_offset = offset;
            const half: f32 = @floatFromInt(@divTrunc(field.cube_mask, 2));
            const near = context.projection.near;
            for (field.stars, 0..) |star, index| {
                const here = wrapped(offset + star.position, field.cube_mask);
                const z = row(rotation, 2, here);
                if (!(near <= z)) continue;
                const there = wrapped(previous_offset + star.position, field.cube_mask);
                const z_before = row(previous, 2, there);
                if (!(near <= z_before)) continue;
                const jump = @abs(here - there);
                if (!(jump[0] <= half and jump[1] <= half and jump[2] <= half)) continue;
                var now3: Vector = .{ row(rotation, 0, here), row(rotation, 1, here), z };
                var before3: Vector = .{ row(previous, 0, there), row(previous, 1, there), z_before };
                var now: [2]f32 = undefined;
                var before: [2]f32 = undefined;
                if (!dustStreak(context.projection, &now3, &before3, &now, &before)) continue;
                const motion = shorten(now, &before, if (field.shortened) jump_stretch else 1);
                try visible.append(arena, .{
                    .index = @intCast(index),
                    .now = now,
                    .before = before,
                    .brightness = dustBrightness(math.dot(now3, now3), field.cube_mask, motion),
                });
            }
        },
        _ => return null,
    }
    const drawn = try arena.create(Drawn);
    drawn.* = .{ .field = field, .visible = visible.items };
    return drawn;
}

fn row(m: math.Matrix, r: usize, v: Vector) f32 {
    return m[r * 3] * v[0] + m[r * 3 + 1] * v[1] + m[r * 3 + 2] * v[2];
}

/// A point of the dust's cube, wrapped to within half the cube of the camera.
fn wrapped(p: Vector, mask: u32) Vector {
    const half: i64 = @divTrunc(mask, 2);
    var out: Vector = undefined;
    inline for (0..3) |axis| {
        const whole: i64 = std.math.lossyCast(i64, @round(p[axis]));
        out[axis] = @floatFromInt((whole & mask) - half);
    }
    return out;
}

/// A star's motion since last frame in view units, `|dx| + |dy|`, with the streak cut back to
/// `streak_limit` along its line; `stretch` makes the cut shorter still.
fn shorten(now: [2]f32, before: *[2]f32, stretch: f32) f32 {
    const motion = @abs(before[1] - now[1]) + @abs(before[0] - now[0]);
    if (!(motion > streak_limit)) return motion;
    const scale = streak_limit / (motion * stretch);
    before[0] = (before[0] - now[0]) * scale + now[0];
    before[1] = (before[1] - now[1]) * scale + now[1];
    return streak_limit;
}

/// Cuts a streak to the view's bounds (`streak_clip`, `0x004CD6A0`), `now` and `before` in view
/// units. False when it lies wholly outside one.
fn streakClip(bounds: [4]f32, now: *[2]f32, before: *[2]f32) bool {
    for (0..2) |axis| {
        const low = bounds[axis];
        const high = bounds[axis + 2];
        if (now[axis] < low) {
            if (before[axis] < low) return false;
            cutAt(now, before.*, axis, low);
        }
        if (before[axis] < low) cutAt(before, now.*, axis, low);
        if (high < now[axis]) {
            if (high < before[axis]) return false;
            cutAt(now, before.*, axis, high);
        }
        if (high < before[axis]) cutAt(before, now.*, axis, high);
    }
    return true;
}

/// Moves `point` along the line to `other` until its `axis` is `value`.
fn cutAt(point: *[2]f32, other: [2]f32, axis: usize, value: f32) void {
    const t = (value - point[axis]) / (other[axis] - point[axis]);
    const other_axis = 1 - axis;
    point[other_axis] += (other[other_axis] - point[other_axis]) * t;
    point[axis] = value;
}

/// Cuts a mote's streak to the near plane, projects both ends, and cuts it to the view
/// (`dust_streak_project`, `0x004CD340`). False when nothing is left.
fn dustStreak(projection: srapi.Projection, now3: *Vector, before3: *Vector, now: *[2]f32, before: *[2]f32) bool {
    const near = projection.near;
    if (now3[2] < near) {
        if (before3[2] < near) return false;
        now3.* += (before3.* - now3.*) * @as(Vector, @splat((near - now3[2]) / (before3[2] - now3[2])));
    }
    if (before3[2] < near) {
        before3.* += (now3.* - before3.*) * @as(Vector, @splat((near - before3[2]) / (now3[2] - before3[2])));
    }
    now.* = .{ now3[0] / now3[2], now3[1] / now3[2] };
    before.* = .{ before3[0] / before3[2], before3[1] / before3[2] };
    return streakClip(projection.bounds, now, before);
}

test project {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var context: srapi.Context = .{ .projection = .init(1024, 768, srapi.full_screen, .{ 0.6, 0.8 }) };

    // A field straight ahead: its middle star shows, still; the one far off the axis does not.
    const stars = [_]Star{
        .{ .position = .{ 0, 0, 1 }, .colour = .{ 1, 1, 1 } },
        .{ .position = .{ 0.9, 0, 1 }, .colour = .{ 1, 1, 1 } },
    };
    var field: Field = .{ .kind = .sky, .stars = &stars };
    const drawn = (try project(arena, &context, &field)).?;
    try std.testing.expectEqual(1, drawn.visible.len);
    try std.testing.expectEqual([2]f32{ 0, 0 }, drawn.visible[0].now);
    try std.testing.expectEqual(1, drawn.visible[0].brightness);
    try std.testing.expect(!field.flags.fresh);

    // The camera turns a little: the star streaks back to where it was, dimmer.
    context.camera.orientation = math.rotation(.y, 0.01);
    const turned = (try project(arena, &context, &field)).?;
    try std.testing.expect(turned.visible[0].now[0] != turned.visible[0].before[0]);
    try std.testing.expect(turned.visible[0].brightness < 1);

    // A cut to looking back: without the streaks reset nothing shows this frame, as nothing was
    // in view last frame; with them reset, the field is drawn mirrored.
    context.camera.orientation = math.rotation(.y, std.math.pi);
    try std.testing.expectEqual(0, (try project(arena, &context, &field)).?.visible.len);
    field.flags.fresh = true;
    try std.testing.expectEqual(1, (try project(arena, &context, &field)).?.visible.len);
    // Looking across it, not at all.
    context.camera.orientation = math.rotation(.y, std.math.pi / 2.0);
    try std.testing.expectEqual(null, try project(arena, &context, &field));
}

test fieldView {
    try std.testing.expectEqual(FieldView.ahead, fieldView(0.9));
    try std.testing.expectEqual(FieldView.mirrored, fieldView(-0.9));
    try std.testing.expectEqual(FieldView.hidden, fieldView(0.3));
    try std.testing.expectEqual(FieldView.hidden, fieldView(-0.5));
    // No number at all is drawn ahead, as the game's sign test leaves it.
    try std.testing.expectEqual(FieldView.ahead, fieldView(std.math.nan(f32)));
}

test starShown {
    // A still camera: both frames alike, so within the second cosine.
    try std.testing.expect(starShown(0.75, 0.75));
    try std.testing.expect(!starShown(0.65, 0.65));
    // Moving: within the first both times and the second once.
    try std.testing.expect(starShown(0.65, 0.8));
    try std.testing.expect(!starShown(0.5, 0.9));
    // No number at all is not drawn.
    try std.testing.expect(!starShown(std.math.nan(f32), 0.9));
}

test skyBrightness {
    try std.testing.expectEqual(1, skyBrightness(0));
    try std.testing.expectApproxEqAbs(0.5, skyBrightness(0.01), 1e-6);
    try std.testing.expectApproxEqAbs(1.0 / 11.0, skyBrightness(streak_limit), 1e-6);
}

test dustBrightness {
    const cube = 0x1FFF;
    try std.testing.expectEqual(1, dustBrightness(0, cube, 0));
    try std.testing.expectEqual(0, dustBrightness(4096 * 4096, cube, 0));
    // Full out to where 16 * (0.25 - d^2 / side^2) falls to 1.
    try std.testing.expectEqual(1, dustBrightness(3500 * 3500, cube, 0));
    try std.testing.expect(dustBrightness(3800 * 3800, cube, 0) < 1);
}
