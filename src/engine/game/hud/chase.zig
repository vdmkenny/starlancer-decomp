//! The chase view's objects in the scene, which `hud_init` (`0x00483150`) builds: a sight of two
//! squares ahead of the player's ship (`chase_sight_near`, `chase_sight_far`), which `camera_chase`
//! places; blind fire's mark where the guns aim (`chase_blind_mark`); a pointer to the target where
//! it stands out of sight (`chase_target_pointer`), and one to the player's nav point
//! (`chase_nav_pointer`, `0x005667AC`), which `hud_target` turns. `hud_missile_lock` (`0x00491520`)
//! picks their textures and adds them to the overlay, in the view ahead from the chase mode.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const matmanager = @import("../matmanager.zig");
const xtrabits = @import("../xtrabits.zig");

/// How far across the sight's squares and blind fire's mark are, and the pointers, whose squares
/// stand `pointer_drop` above the point they turn about (`0x004DC5A8`).
const sight_size: f32 = 600;
const pointer_size: f32 = 200;
const pointer_drop: f32 = 400;

/// How far ahead of the ship the sight's near square, the mark and the pointer stand, and the
/// sight's far square.
const near_reach: f32 = 6000;
const far_reach: f32 = 12000;

/// The colours the objects that are coloured by their own are made with: half grey, and white.
const half_grey: [4]f32 = .{ 0.5, 0.5, 0.5, 1 };
const white: [4]f32 = .{ 1, 1, 1, 1 };

/// The pointer to the target, as `hud_target` turns it this frame: rolled about the ship's nose
/// by `roll`, and for a hostile target or another.
pub const Pointer = struct {
    roll: f32,
    hostile: bool,

    /// The pointer for a target the way `way` from the ship, across and down in its frame
    /// (`hud.pointerDirection`), turned so that it points that way (`rollToward`).
    pub fn toward(way: [2]f32, hostile: bool) Pointer {
        return .{ .roll = rollToward(way), .hostile = hostile };
    }

    /// The roll that turns a pointer the way `way`, as the pointers to the target and to the nav
    /// point are turned alike: the way's angle from straight up, going round to the right.
    /// `hud_target` works the angle out from the way `hud_pointer_direction` gives, the way turned
    /// half round, and turns it half a turn more, which comes to the same.
    ///
    /// **Improvement:** the game takes the angle from `sr_atan`'s table, a quadrant at a time;
    /// OpenReliant computes it.
    pub fn rollToward(way: [2]f32) f32 {
        return std.math.atan2(way[0], -way[1]);
    }
};

/// What the objects are drawn with: the sight's texture, the sight's while a target stands under
/// the reticle, and the pointer's for a hostile target and for another.
const images = struct {
    const sight = "chasetarget";
    const sight_bright = "chasetarget2";
    const hostile_pointer = "chasepointat2";
    const other_pointer = "chasepointat3";
    const nav_pointer = "chasepointat";
};

/// One of the objects: a mesh of its own, as `mesh_build_square` (`0x0044F000`) makes one, and its
/// object, never culled, always drawn and clipped.
const Square = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    colours: [corners][4]f32,

    const corners = 4;

    /// The mesh `size` across, standing `drop` above the point it turns about, facing along Z as
    /// two triangles over the whole of `image`, added to what is drawn and coloured by `own`
    /// colours, or at full strength without them.
    fn init(square: *Square, gpa: Allocator, size: f32, drop: f32, image: *srtexture.Image, own: ?[4]f32) Allocator.Error!void {
        var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = 2, .vertices = corners, .indices = 6 });
        errdefer mesh.deinit(gpa);
        const half = size / 2;
        mesh.positions[0..corners].* = .{ .{ -half, -half - drop, 0 }, .{ half, -half - drop, 0 }, .{ half, half - drop, 0 }, .{ -half, half - drop, 0 } };
        mesh.numberPolygons(3);
        mesh.indices[0..6].* = .{ 3, 2, 0, 2, 1, 0 };
        const uv = try mesh.addCoordinates(gpa);
        uv[0..6].* = .{ .{ 0, 1 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
        mesh.surfaces[0] = .{
            .polygons = 2,
            .material = .onePass(.{ .coordinates = .mesh, .lit = own != null, .blend = .add }),
            .textures = .{ .{ .image = image }, .none },
        };
        srapi.findBoundingBox(&mesh);
        square.mesh = mesh;
        square.level = .{.{ .mesh = &square.mesh, .until = std.math.inf(f32) }};
        square.colours = @splat(own orelse white);
        square.object = .{
            .flags = .{ .not_culled = true, .always_drawn = true, .unbounded = true, .baked_object = own != null },
            .position = @splat(0),
            .radius = mesh.radius,
            .levels = &square.level,
            .baked = if (own != null) &square.colours else null,
        };
    }

    /// Stands it `reach` along `direction` from `from`, turned as `turn`, drawn with `image`, in
    /// the overlay.
    fn add(square: *Square, gpa: Allocator, scene: *srcore.Scene, from: Vector, direction: Vector, reach: f32, turn: math.Matrix, image: *srtexture.Image) Allocator.Error!void {
        square.object.position = from + direction * @as(Vector, @splat(reach));
        square.object.orientation = turn;
        square.mesh.surfaces[0].textures[0] = .{ .image = image };
        try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &square.object }, .overlay);
    }
};

pub const Chase = struct {
    near: Square,
    far: Square,
    mark: Square,
    pointer: Square,
    nav_pointer: Square,
    sight: *srtexture.Image,
    sight_bright: *srtexture.Image,
    hostile_pointer: *srtexture.Image,
    other_pointer: *srtexture.Image,
    nav_image: *srtexture.Image,

    /// `hud_init`'s objects for the chase view: the sight's near square at full strength, its far
    /// one half grey, blind fire's mark white, and the two pointers.
    pub fn create(gpa: Allocator, textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!*Chase {
        const chase = try gpa.create(Chase);
        errdefer gpa.destroy(chase);
        chase.sight = try matmanager.textureRequire(textures, images.sight);
        chase.sight_bright = try matmanager.textureRequire(textures, images.sight_bright);
        chase.hostile_pointer = try matmanager.textureRequire(textures, images.hostile_pointer);
        chase.other_pointer = try matmanager.textureRequire(textures, images.other_pointer);
        chase.nav_image = try matmanager.textureRequire(textures, images.nav_pointer);
        try chase.near.init(gpa, sight_size, 0, chase.sight, null);
        errdefer chase.near.mesh.deinit(gpa);
        try chase.far.init(gpa, sight_size, 0, chase.sight, half_grey);
        errdefer chase.far.mesh.deinit(gpa);
        try chase.mark.init(gpa, sight_size, 0, chase.sight, white);
        errdefer chase.mark.mesh.deinit(gpa);
        try chase.pointer.init(gpa, pointer_size, pointer_drop, chase.hostile_pointer, null);
        errdefer chase.pointer.mesh.deinit(gpa);
        try chase.nav_pointer.init(gpa, pointer_size, pointer_drop, chase.nav_image, null);
        return chase;
    }

    pub fn destroy(chase: *Chase, gpa: Allocator) void {
        for ([_]*Square{ &chase.near, &chase.far, &chase.mark, &chase.pointer, &chase.nav_pointer }) |square| square.mesh.deinit(gpa);
        gpa.destroy(chase);
    }

    /// `hud_missile_lock`'s part in the view ahead from the chase mode, with `camera_chase`'s
    /// placing of the sight, for the player's ship at `ship`: the sight's squares `near_reach` and
    /// `far_reach` ahead, turned as the ship is, bright while a target stands under the reticle
    /// (`bright`) unless blind fire aims; while blind fire aims at `aim`, its mark `near_reach` that
    /// way, bright where a target stands under the reticle; and the pointers `near_reach` ahead,
    /// where `hud_target` has turned them this frame: the nav point's rolled by `nav_roll`, where
    /// the target's stands.
    pub fn draw(chase: *Chase, gpa: Allocator, scene: *srcore.Scene, ship: math.Place, bright: bool, aim: ?Vector, pointer: ?Pointer, nav_roll: ?f32) Allocator.Error!void {
        const ahead = math.forward(ship.orientation);
        const sight_image = if (bright and aim == null) chase.sight_bright else chase.sight;
        try chase.near.add(gpa, scene, ship.position, ahead, near_reach, ship.orientation, sight_image);
        try chase.far.add(gpa, scene, ship.position, ahead, far_reach, ship.orientation, sight_image);
        if (aim) |point| {
            const mark_image = if (bright) chase.sight_bright else chase.sight;
            try chase.mark.add(gpa, scene, ship.position, math.normalize(point - ship.position), near_reach, ship.orientation, mark_image);
        }
        if (pointer) |shown| {
            const turn = math.product(ship.orientation, math.fromAngles(0, 0, shown.roll));
            try chase.pointer.add(gpa, scene, ship.position, ahead, near_reach, turn, if (shown.hostile) chase.hostile_pointer else chase.other_pointer);
        }
        const roll = nav_roll orelse return;
        const turn = math.product(ship.orientation, math.fromAngles(0, 0, roll));
        try chase.nav_pointer.add(gpa, scene, ship.position, ahead, near_reach, turn, chase.nav_image);
    }
};

test "the pointer points the way to the target" {
    // Straight up the view the pointer, whose square stands above the point it turns about, is
    // not turned; to the right it turns a quarter round, down half round, and to the left a
    // quarter round back.
    try std.testing.expectApproxEqAbs(0, Pointer.toward(.{ 0, -1 }, true).roll, 1e-6);
    try std.testing.expectApproxEqAbs(0.5 * std.math.pi, Pointer.toward(.{ 1, 0 }, true).roll, 1e-6);
    try std.testing.expectApproxEqAbs(std.math.pi, Pointer.toward(.{ 0, 1 }, false).roll, 1e-6);
    try std.testing.expectApproxEqAbs(-0.5 * std.math.pi, Pointer.rollToward(.{ -1, 0 }), 1e-6);
}

test Square {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = .{ .levels = &.{} };
    var square: Square = undefined;
    try square.init(gpa, pointer_size, pointer_drop, &image, half_grey);
    defer square.mesh.deinit(gpa);
    // The pointer's square stands above the point it turns about, and colours itself half grey.
    try std.testing.expectEqual(@as(Vector, .{ -100, -500, 0 }), square.mesh.positions[0]);
    try std.testing.expectEqual(@as(Vector, .{ 100, -300, 0 }), square.mesh.positions[2]);
    try std.testing.expect(square.object.flags.baked_object);
    try std.testing.expectEqual(half_grey, square.colours[0]);

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try square.add(gpa, &scene, @splat(0), .{ 0, 0, 1 }, near_reach, math.identity, &image);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, near_reach }), square.object.position);
    try std.testing.expectEqual(1, scene.layers.get(.overlay).items.len);
}
