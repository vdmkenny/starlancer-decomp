//! OpenReliant's: shadows from the key lights, which Surrender has none of. Each frame the view is
//! split by depth into cascades, each an orthographic box along the sun around its slice of the
//! view (`fit`), and the cockpit, where the scene holds one, gets a box of its own around it. The
//! scene's solid meshes are gathered as casters, whatever the camera sees of them, into the maps
//! they can reach (`gather`), and a cloaking part's see-through hull as strongly as it is solid, so
//! that a ship's shadow fades out as it cloaks. A device that lights each pixel draws the casters
//! into a map for each box and scales a shadowed light's share of each pixel by what it finds there
//! (`device.Device.shadows`): the world's pixels in the cascades, the cockpit's in its own map.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../math.zig");
const Vector = math.Vector;
const srapi = @import("srapi.zig");
const srapiext = @import("srapiext.zig");
const srclip = @import("srclip.zig");
const srcore = @import("srcore.zig");
const srlight = @import("srlight.zig");

pub const cascade_count = 4;

/// The maps: one for each cascade, then the cockpit's.
pub const map_count = cascade_count + 1;
pub const cockpit_map = cascade_count;

/// A set of maps.
pub const Maps = std.bit_set.IntegerBitSet(map_count);

/// How a device draws shadows: its maps' texels across, how far from the camera each cascade
/// reaches in view depth, the first from the near plane, and whether the cockpit gets a map of
/// its own. Past the last cascade, nothing is shadowed.
pub const Settings = struct {
    texels: u32,
    reaches: [cascade_count]f32,
    cockpit: bool = true,
};

/// A caster's corner, in the camera's frame, and how strong a shadow the triangles on it cast,
/// from nothing to whole. A device draws a faint one into its maps a share of texels at a time.
pub const Corner = extern struct {
    position: [3]f32,
    strength: f32 = 1,

    comptime {
        // The GPU's shadow vertex (`platform/gpu/shadows.zig`) reads it as it lies.
        std.debug.assert(@offsetOf(Corner, "position") == 0);
        std.debug.assert(@offsetOf(Corner, "strength") == 12);
        std.debug.assert(@sizeOf(Corner) == 16);
    }
};

/// The frame's shadows as a device takes them, in the camera's frame.
pub const Frame = struct {
    cascades: [cascade_count]Box,
    /// Around the overlay layer's lit meshes, the cockpit's parts, where there are any.
    cockpit: ?Box,
    /// The casters' corners, and their triangles, three indices each.
    corners: []const Corner,
    indices: []const u32,
    /// The triangles in runs, each drawn into the maps it can reach alone.
    runs: []const Run,

    /// Map `map`'s box, or null for the cockpit's without a cockpit.
    pub fn box(frame: Frame, map: usize) ?Box {
        return if (map < cascade_count) frame.cascades[map] else frame.cockpit;
    }
};

/// A run of the frame's indices and the maps it is drawn into.
pub const Run = struct {
    first: u32,
    count: u32,
    maps: Maps,
};

/// A map's box along the sun.
pub const Box = struct {
    /// Where a point of the camera's frame falls in the map, each row dotted with the point and 1:
    /// across and up from -1 to 1, and its depth from 0 on the sun's side to 1.
    rows: [3][4]f32,
    /// For a cascade, the view depth up to which a pixel takes its shadow from it.
    far: f32 = 0,
    /// A texel's width in the world.
    texel: f32,
    /// How far the box reaches across from its centre, in the world.
    half: f32,

    /// Where `point`, in the camera's frame, falls in the map.
    pub fn place(box: Box, point: Vector) Vector {
        var at: Vector = undefined;
        inline for (box.rows, 0..) |row, axis| {
            at[axis] = row[0] * point[0] + row[1] * point[1] + row[2] * point[2] + row[3];
        }
        return at;
    }

    /// Whether a sphere of `radius` at `centre`, in the camera's frame, can throw a shadow into the
    /// box: it overlaps the box across, and does not lie wholly beyond it from the sun.
    pub fn reachedBy(box: Box, centre: Vector, radius: f32) bool {
        const at = box.place(centre);
        const across = radius / box.half;
        return @abs(at[0]) <= 1 + across and @abs(at[1]) <= 1 + across and at[2] <= 1 + across * 0.5;
    }
};

/// The world's axes of the maps for light shining toward the sun along `toward`: across, up and
/// away from the sun, and the same in the camera's frame. They follow the world, not the camera,
/// so that turning the camera does not turn the texels under the shadows.
const Axes = struct {
    world: [3]Vector,
    turned: [3]Vector,

    fn of(context: srapi.Context, toward: Vector) Axes {
        const away = -toward;
        const helper: Vector = if (@abs(toward[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
        const across = math.normalize(math.cross(helper, away));
        const up = math.cross(away, across);
        var axes: Axes = .{ .world = .{ across, up, away }, .turned = undefined };
        for (axes.world, &axes.turned) |axis, *in_view| in_view.* = context.turn(axis);
        return axes;
    }

    /// The box along the sun around `sphere`, in the camera's frame, for a map `texels` across: its
    /// centre moved to a whole texel of the world so that its shadows stay still as the camera
    /// moves.
    fn box(axes: Axes, context: srapi.Context, sphere: Sphere, texels: u32) Box {
        const texel = 2 * sphere.radius / @as(f32, @floatFromInt(texels));
        const centre_world = context.camera.point(sphere.centre);
        var offsets: [3]f32 = undefined;
        for (axes.world, &offsets, 0..) |axis, *offset, index| {
            // In doubles: the world's coordinates are large, and the snapping must not wander.
            const along = dot64(axis, centre_world);
            const origin = if (index < 2) @floor(along / texel) * texel else along - sphere.radius;
            offset.* = @floatCast(dot64(axis, context.camera.position) - origin);
        }
        var made: Box = .{ .rows = undefined, .texel = texel, .half = sphere.radius };
        const scales = [3]f32{ 1 / sphere.radius, 1 / sphere.radius, 1 / (2 * sphere.radius) };
        for (&made.rows, axes.turned, offsets, scales) |*row, axis, offset, scale| {
            row.* = .{ axis[0] * scale, axis[1] * scale, axis[2] * scale, offset * scale };
        }
        return made;
    }
};

/// The cascades `settings` ask for, lit along `toward` in the world: each the box along the sun
/// around the sphere that holds its slice of the view.
pub fn fit(context: srapi.Context, toward: Vector, settings: Settings) [cascade_count]Box {
    const axes: Axes = .of(context, toward);
    var cascades: [cascade_count]Box = undefined;
    var near = context.projection.near;
    for (settings.reaches, &cascades) |far, *cascade| {
        cascade.* = axes.box(context, sliceSphere(context.projection.bounds, near, far), settings.texels);
        cascade.far = far;
        near = far;
    }
    return cascades;
}

/// The cockpit's box, lit along `toward`: around the lit meshes of `overlay`, the cockpit's parts;
/// null where there are none.
pub fn fitCockpit(context: srapi.Context, toward: Vector, overlay: []const srcore.Object, texels: u32) ?Box {
    var low: Vector = @splat(std.math.inf(f32));
    var high: Vector = @splat(-std.math.inf(f32));
    for (overlay) |object| {
        const mesh = switch (object) {
            .mesh => |mesh| mesh,
            .sprites, .stars => continue,
        };
        if (!casts(mesh)) continue;
        const reach: Vector = @splat(mesh.radius * mesh.scale);
        const at = context.view(mesh.position);
        low = @min(low, at - reach);
        high = @max(high, at + reach);
    }
    if (!(low[0] <= high[0])) return null;
    const sphere: Sphere = .{ .centre = (low + high) * @as(Vector, @splat(0.5)), .radius = math.distance(high, low) * 0.5 };
    return Axes.of(context, toward).box(context, sphere, texels);
}

/// The dot product of `a` and `b` in doubles.
fn dot64(a: Vector, b: Vector) f64 {
    const Wide = @Vector(3, f64);
    return @reduce(.Add, @as(Wide, @floatCast(a)) * @as(Wide, @floatCast(b)));
}

const Sphere = struct { centre: Vector, radius: f32 };

/// The sphere around the slice of the view from depth `near` to `far`: centred on its corners'
/// mean, reaching the farthest. It depends on the view's shape alone, so its size holds still.
fn sliceSphere(bounds: [4]f32, near: f32, far: f32) Sphere {
    var corners: [8]Vector = undefined;
    var index: usize = 0;
    for ([2]f32{ near, far }) |depth| {
        for ([2]f32{ bounds[0], bounds[2] }) |x| {
            for ([2]f32{ bounds[1], bounds[3] }) |y| {
                corners[index] = .{ x * depth, y * depth, depth };
                index += 1;
            }
        }
    }
    var sum: Vector = @splat(0);
    for (corners) |corner| sum += corner;
    const centre = sum / @as(Vector, @splat(corners.len));
    var radius: f32 = 0;
    for (corners) |corner| radius = @max(radius, math.distance(corner, centre));
    return .{ .centre = centre, .radius = radius };
}

/// The direction toward the first light of `lights` that casts shadows, a directional one, in the
/// world; null where none does.
pub fn sunward(lights: []const srlight.Light) ?Vector {
    for (lights) |light| {
        if (!light.shadowed) continue;
        switch (light.kind) {
            .directional => |forward| return math.normalize(forward),
            .ambient, .point => {},
        }
    }
    return null;
}

/// Whether a light of `lights` that casts shadows reaches `object`, by the two's light masks.
fn shadowedBy(lights: []const srlight.Light, object: *const srapiext.MeshObject) bool {
    for (lights) |light| {
        if (light.shadowed and light.reaches(object.light_mask)) return true;
    }
    return false;
}

/// Whether `object` casts: a lit mesh, shown and of some size.
pub fn casts(object: *const srapiext.MeshObject) bool {
    return !object.flags.hidden and object.scale != 0 and object.flags.lit and object.levels.len > 0;
}

/// How strong a shadow `object`'s surfaces blended by alpha cast: its colour's alpha, where it
/// asks for one (`alpha_shadow`) and they cast anything at all.
fn alphaShadow(object: *const srapiext.MeshObject) ?f32 {
    if (!object.alpha_shadow) return null;
    const strength = std.math.clamp(object.colour[3], 0, 1);
    return if (strength > 0) strength else null;
}

/// Where the casters of each kind may throw their shadows.
const into = struct {
    /// The world's layer: anywhere, the cockpit included, so a ship between the cockpit and the
    /// sun darkens it.
    const world: Maps = .initFull();
    /// What casts without being drawn, the ship the camera sits in: the cascades alone, as the
    /// cockpit sits inside it and would be dark all over.
    const unseen: Maps = Maps.initFull().differenceWith(cockpit);
    /// The cockpit's parts: its own map alone.
    const cockpit: Maps = blk: {
        var maps: Maps = .initEmpty();
        maps.set(cockpit_map);
        break :blk maps;
    };
};

/// The frame's shadows: the boxes `settings` ask for, along the first light of `lights` that
/// casts shadows, and the triangles of each caster that can reach one of them: the world's layer,
/// `unseen`, which casts without being drawn, and the lit meshes of `overlay`, the cockpit's
/// parts. A mesh that keeps out every light casting shadows by its light mask casts none, as the
/// sun does not light it: the Reliant's hangar, whose walls keep the sun out, leaves a ship
/// within it lit as in the original. Null where no light casts shadows.
pub fn gather(
    arena: Allocator,
    context: srapi.Context,
    lights: []const srlight.Light,
    world: []const srcore.Object,
    overlay: []const srcore.Object,
    unseen: []const *srapiext.MeshObject,
    settings: Settings,
) Allocator.Error!?Frame {
    const toward = sunward(lights) orelse return null;
    var casters: Casters = .{
        .arena = arena,
        .context = context,
        .lights = lights,
        .cascades = fit(context, toward, settings),
        .cockpit = if (settings.cockpit) fitCockpit(context, toward, overlay, settings.texels) else null,
    };
    for (world) |object| try casters.addObject(object, into.world);
    for (unseen) |mesh| try casters.add(mesh, into.unseen);
    for (overlay) |object| try casters.addObject(object, into.cockpit);
    return .{
        .cascades = casters.cascades,
        .cockpit = casters.cockpit,
        .corners = casters.corners.items,
        .indices = casters.indices.items,
        .runs = casters.runs.items,
    };
}

/// The casters as they are gathered.
const Casters = struct {
    arena: Allocator,
    context: srapi.Context,
    /// The frame's lights, of which those that cast shadows decide what casts.
    lights: []const srlight.Light,
    cascades: [cascade_count]Box,
    cockpit: ?Box,
    corners: std.ArrayList(Corner) = .empty,
    indices: std.ArrayList(u32) = .empty,
    runs: std.ArrayList(Run) = .empty,

    fn addObject(casters: *Casters, object: srcore.Object, allowed: Maps) Allocator.Error!void {
        switch (object) {
            .mesh => |mesh| try casters.add(mesh, allowed),
            .sprites, .stars => {},
        }
    }

    /// Adds `object`'s triangles, where it casts and can reach one of the `allowed` maps: its
    /// opaque surfaces at its current level of detail, each polygon a fan of its corners, turned
    /// into the camera's frame as the pipeline turns it, and its surfaces blended by alpha, where
    /// it asks, as strong as its alpha, on corners of their own. Lines cast nothing. The last run
    /// takes them on where it goes into the same maps. An object its portal clips casts only what
    /// the portal keeps of it, as it is drawn.
    fn add(casters: *Casters, object: *const srapiext.MeshObject, allowed: Maps) Allocator.Error!void {
        if (!casts(object) or !shadowedBy(casters.lights, object)) return;
        const context = casters.context;
        const relative = context.view(object.position);
        const reached = casters.reachedBy(relative, object.radius * object.scale).intersectWith(allowed);
        if (reached.count() == 0) return;
        const mesh = object.shown();
        const matrix = context.objectMatrix(object.orientation, object.scale);
        // The corners the solid surfaces cast from, and those the see-through ones do.
        var solid: ?u32 = null;
        var faint: ?u32 = null;
        const first: u32 = @intCast(casters.indices.items.len);
        var polygon: usize = 0;
        for (mesh.surfaces) |surface| {
            const run = mesh.polygons[polygon..][0..surface.polygons];
            polygon += surface.polygons;
            const opaque_surface = surface.material.blend[0] == .off;
            const strength: f32 = if (opaque_surface) 1 else alphaShadow(object) orelse continue;
            const corners_made = if (opaque_surface) &solid else &faint;
            if (corners_made.* == null) corners_made.* = try casters.addCorners(mesh, matrix, relative, strength);
            const base = corners_made.*.?;
            for (run) |shape| {
                if (shape.kind == .lines or shape.count < 3) continue;
                const corners = mesh.indices[shape.first..][0..shape.count];
                for (1..corners.len - 1) |second| {
                    const triangle = [3]u32{ base + corners[0], base + corners[second], base + corners[second + 1] };
                    const portal = if (object.flags.portal_clipped) object.portal else null;
                    if (portal) |cut| {
                        try casters.addClipped(cut.view, triangle);
                    } else {
                        try casters.indices.appendSlice(casters.arena, &triangle);
                    }
                }
            }
        }
        const count = @as(u32, @intCast(casters.indices.items.len)) - first;
        if (count == 0) return;
        if (casters.runs.items.len > 0) {
            const last = &casters.runs.items[casters.runs.items.len - 1];
            if (last.maps.eql(reached) and last.first + last.count == first) {
                last.count += count;
                return;
            }
        }
        try casters.runs.append(casters.arena, .{ .first = first, .count = count, .maps = reached });
    }

    /// Adds `mesh`'s corners, turned by `matrix` and moved by `relative`, casting as `strength`
    /// says: the index of the first.
    fn addCorners(casters: *Casters, mesh: *const srapiext.Mesh, matrix: math.Matrix, relative: Vector, strength: f32) Allocator.Error!u32 {
        const base: u32 = @intCast(casters.corners.items.len);
        try casters.corners.ensureUnusedCapacity(casters.arena, mesh.positions.len);
        for (mesh.positions) |position| {
            casters.corners.appendAssumeCapacity(.{ .position = math.transform(matrix, position) + relative, .strength = strength });
        }
        return base;
    }

    /// Adds what `plane`, a portal's in the camera's frame, keeps of the triangle of the corners
    /// at `triangle`: all of it, none, or the piece on its side, cut as the clipper cuts
    /// (`srclip.cut`), as a fan of new corners as strong as the triangle's.
    fn addClipped(casters: *Casters, plane: srapiext.Portal.View, triangle: [3]u32) Allocator.Error!void {
        var corners: [3]Vector = undefined;
        for (triangle, &corners) |index, *corner| corner.* = casters.corners.items[index].position;
        const strength = casters.corners.items[triangle[0]].strength;
        const side: PortalSide = .{ .plane = plane };
        if (side.inside(corners[0]) >= 0 and side.inside(corners[1]) >= 0 and side.inside(corners[2]) >= 0) {
            return casters.indices.appendSlice(casters.arena, &triangle);
        }
        var kept: [4]Vector = undefined;
        const count = srclip.cut(Vector, &corners, &kept, side);
        if (count < 3) return;
        const base: u32 = @intCast(casters.corners.items.len);
        for (kept[0..count]) |corner| try casters.corners.append(casters.arena, .{ .position = corner, .strength = strength });
        for (1..count - 1) |second| {
            try casters.indices.appendSlice(casters.arena, &.{ base, base + @as(u32, @intCast(second)), base + @as(u32, @intCast(second + 1)) });
        }
    }

    /// The maps a sphere of `radius` at `centre`, in the camera's frame, can throw a shadow into.
    fn reachedBy(casters: Casters, centre: Vector, radius: f32) Maps {
        var reached: Maps = .initEmpty();
        for (casters.cascades, 0..) |cascade, map| reached.setValue(map, cascade.reachedBy(centre, radius));
        if (casters.cockpit) |cockpit| reached.setValue(cockpit_map, cockpit.reachedBy(centre, radius));
        return reached;
    }
};

/// A portal's plane as `srclip.cut` cuts a caster's triangle by it.
const PortalSide = struct {
    plane: srapiext.Portal.View,

    pub fn inside(side: PortalSide, v: Vector) f32 {
        return side.plane.inside(v);
    }

    pub fn between(_: PortalSide, a: Vector, b: Vector, t: f32) Vector {
        return math.lerp(a, b, t);
    }
};

const testing = struct {
    /// A view a right angle wide, from the world's origin along its Z axis.
    fn context() srapi.Context {
        return .{ .projection = .init(640, 480, .{ 0, 0, 1, 1 }, .{ 0.5, 0.5 }) };
    }

    const sun = math.normalize(.{ 1, -2, 0.5 });

    const settings: Settings = .{ .texels = 2048, .reaches = .{ 1500, 6000, 20000, 60000 } };

    fn keyLight(shadowed: bool) srlight.Light {
        return .{ .mask = 1, .intensity = 1, .colour = @splat(1), .kind = .{ .directional = sun }, .shadowed = shadowed };
    }
};

test fit {
    const context = testing.context();
    const cascades = fit(context, testing.sun, testing.settings);
    var near = context.projection.near;
    for (cascades, testing.settings.reaches) |cascade, far| {
        // The middle of its slice of the view lies in its map, and a point toward the sun nearer
        // the sun's side.
        const middle: Vector = .{ 0, 0, (near + far) / 2 };
        const at = cascade.place(middle);
        try std.testing.expect(@abs(at[0]) < 1 and @abs(at[1]) < 1);
        try std.testing.expect(at[2] > 0 and at[2] < 1);
        const toward = middle + context.turn(testing.sun) * @as(Vector, @splat(100));
        try std.testing.expect(cascade.place(toward)[2] < at[2]);
        try std.testing.expectEqual(far, cascade.far);
        near = far;
    }
    // The farther the cascade reaches, the wider its texels.
    for (cascades[0 .. cascade_count - 1], cascades[1..]) |nearer, farther| try std.testing.expect(nearer.texel < farther.texel);
}

test "the maps' texels follow the world, not the camera" {
    var context = testing.context();
    const point: Vector = .{ 300, 200, 900 };
    const before = fit(context, testing.sun, testing.settings)[0].place(context.view(point));
    // However the camera moves, a point of the world moves across the map by whole texels.
    context.camera.position += .{ 7.3, -2.1, 11.9 };
    const after = fit(context, testing.sun, testing.settings)[0].place(context.view(point));
    const half: f32 = @floatFromInt(testing.settings.texels / 2);
    const texels = (after - before) * @as(Vector, @splat(half));
    for ([2]f32{ texels[0], texels[1] }) |moved| try std.testing.expectApproxEqAbs(@round(moved), moved, 1e-2);
}

test sunward {
    const ambient: srlight.Light = .{ .mask = 4, .intensity = 1, .colour = @splat(0.1), .kind = .ambient };
    try std.testing.expectEqual(null, sunward(&.{ ambient, testing.keyLight(false) }));
    const found = sunward(&.{ ambient, testing.keyLight(true) }).?;
    try std.testing.expectApproxEqAbs(1, math.length(found), 1e-6);
}

test gather {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = testing.context();
    var square = try @import("srmesh.zig").testing.square(gpa);
    defer square.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &square, .until = std.math.inf(f32) }};
    var ahead: srapiext.MeshObject = .{ .flags = .{ .lit = true }, .position = .{ 0, 0, 1000 }, .radius = square.radius, .levels = &levels };
    var hidden = ahead;
    hidden.flags.hidden = true;
    var unlit = ahead;
    unlit.flags.lit = false;
    var far_off = ahead;
    far_off.position = .{ 0, 0, 1e7 };
    var unseen = ahead;
    const world = [_]srcore.Object{ .{ .mesh = &ahead }, .{ .mesh = &hidden }, .{ .mesh = &unlit }, .{ .mesh = &far_off } };

    // Without a light that casts shadows, there are none.
    try std.testing.expectEqual(null, try gather(arena, context, &.{testing.keyLight(false)}, &world, &.{}, &.{}, testing.settings));

    // A lit mesh in reach casts its two triangles, in the camera's frame; the hidden, the unlit
    // and the one out of reach cast nothing; one cast without being drawn casts as well. Without
    // a cockpit there is no map for it.
    const lights = [_]srlight.Light{testing.keyLight(true)};
    const frame = (try gather(arena, context, &lights, &world, &.{}, &.{&unseen}, testing.settings)).?;
    try std.testing.expectEqual(null, frame.cockpit);
    try std.testing.expectEqual(8, frame.corners.len);
    try std.testing.expectEqual(12, frame.indices.len);
    try std.testing.expectEqual(Corner{ .position = .{ -100, -100, 1000 } }, frame.corners[0]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 1, 0, 3, 2 }, frame.indices[0..6]);
    try std.testing.expectEqual(4, frame.indices[6]);
    // Both reach the same cascades, one after the other, so they go in one run; a square 1000
    // ahead lies within the first cascade's reach and the second's.
    try std.testing.expectEqual(1, frame.runs.len);
    try std.testing.expectEqual(12, frame.runs[0].count);
    try std.testing.expect(frame.runs[0].maps.isSet(0) and frame.runs[0].maps.isSet(1));

    // A blended surface casts nothing, unless its object asks: then as strong as its alpha, and
    // nothing while it is clear.
    square.surfaces[0].material.blend[0] = .alpha;
    const blended = (try gather(arena, context, &lights, &world, &.{}, &.{}, testing.settings)).?;
    try std.testing.expectEqual(0, blended.indices.len);
    ahead.alpha_shadow = true;
    ahead.colour[3] = 0.25;
    const faint = (try gather(arena, context, &lights, &world, &.{}, &.{}, testing.settings)).?;
    try std.testing.expectEqual(6, faint.indices.len);
    try std.testing.expectEqual(4, faint.corners.len);
    try std.testing.expectEqual(Corner{ .position = .{ -100, -100, 1000 }, .strength = 0.25 }, faint.corners[0]);
    ahead.colour[3] = 0;
    const clear = (try gather(arena, context, &lights, &world, &.{}, &.{}, testing.settings)).?;
    try std.testing.expectEqual(0, clear.indices.len);
    try std.testing.expectEqual(0, clear.corners.len);

    // A mesh whose light mask keeps the shadowed light out casts nothing.
    square.surfaces[0].material.blend[0] = .off;
    ahead.alpha_shadow = false;
    const casting = (try gather(arena, context, &lights, &world, &.{}, &.{}, testing.settings)).?;
    try std.testing.expectEqual(6, casting.indices.len);
    ahead.light_mask = lights[0].mask;
    const kept_out = (try gather(arena, context, &lights, &world, &.{}, &.{}, testing.settings)).?;
    try std.testing.expectEqual(0, kept_out.indices.len);
}

test "a portal cuts a caster's shadow" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = testing.context();
    const square = try @import("srmesh.zig").testing.square(gpa);
    defer square.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &square, .until = std.math.inf(f32) }};
    // A portal down the middle of the square, keeping its left half.
    const portal: srapiext.Portal = .{ .view = .{ .normal = .{ 1, 0, 0 }, .point = .{ 0, 0, 1000 } } };
    var cut: srapiext.MeshObject = .{ .flags = .{ .lit = true, .portal_clipped = true }, .position = .{ 0, 0, 1000 }, .radius = square.radius, .levels = &levels, .portal = &portal };
    const world = [_]srcore.Object{.{ .mesh = &cut }};

    // One triangle keeps a corner and is cut to a triangle, the other keeps two and is cut to two:
    // three triangles, every corner of them in the left half.
    const lights = [_]srlight.Light{testing.keyLight(true)};
    const frame = (try gather(arena, context, &lights, &world, &.{}, &.{}, testing.settings)).?;
    try std.testing.expectEqual(9, frame.indices.len);
    for (frame.indices) |index| try std.testing.expect(frame.corners[index].position[0] <= 1e-3);

    // Not flagged, the portal leaves it whole.
    cut.flags.portal_clipped = false;
    const whole = (try gather(arena, context, &lights, &world, &.{}, &.{}, testing.settings)).?;
    try std.testing.expectEqual(6, whole.indices.len);
}

test "the cockpit's map" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = testing.context();
    var square = try @import("srmesh.zig").testing.square(gpa);
    defer square.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &square, .until = std.math.inf(f32) }};
    // A cockpit's part just ahead of the camera, a tenth the square's size, and a ship around the
    // camera, as the one it sits in is.
    var part: srapiext.MeshObject = .{ .flags = .{ .lit = true }, .position = .{ 0, 0, 20 }, .scale = 0.1, .radius = square.radius, .levels = &levels };
    var seat: srapiext.MeshObject = .{ .flags = .{ .lit = true }, .position = .{ 0, 0, 0 }, .radius = square.radius, .levels = &levels };
    // A ship between the cockpit and the sun, far off toward it.
    var over: srapiext.MeshObject = .{ .flags = .{ .lit = true }, .position = testing.sun * @as(Vector, @splat(5000)), .radius = square.radius, .levels = &levels };
    const lights = [_]srlight.Light{testing.keyLight(true)};
    const overlay = [_]srcore.Object{.{ .mesh = &part }};
    const world = [_]srcore.Object{.{ .mesh = &over }};
    const frame = (try gather(arena, context, &lights, &world, &overlay, &.{&seat}, testing.settings)).?;

    // The cockpit gets a box around its parts, its texels far finer than the nearest cascade's.
    const cockpit = frame.cockpit.?;
    try std.testing.expect(cockpit.texel < frame.cascades[0].texel / 10);
    const at = cockpit.place(.{ 0, 0, 20 });
    try std.testing.expect(@abs(at[0]) < 1 and @abs(at[1]) < 1);

    // The ship between it and the sun casts into it; the cockpit's part into it alone; the ship
    // the camera sits in not at all.
    try std.testing.expectEqual(3, frame.runs.len);
    try std.testing.expect(frame.runs[0].maps.isSet(cockpit_map));
    try std.testing.expect(!frame.runs[1].maps.isSet(cockpit_map) and frame.runs[1].maps.isSet(0));
    try std.testing.expectEqual(1, frame.runs[2].maps.count());
    try std.testing.expect(frame.runs[2].maps.isSet(cockpit_map));
    try std.testing.expectEqual(cockpit, frame.box(cockpit_map).?);

    // Without shadows in the cockpit, it has no map, and its parts cast nothing.
    var plain = testing.settings;
    plain.cockpit = false;
    const outside = (try gather(arena, context, &lights, &world, &overlay, &.{&seat}, plain)).?;
    try std.testing.expectEqual(null, outside.cockpit);
    for (outside.runs) |run| try std.testing.expect(!run.maps.isSet(cockpit_map));
}
