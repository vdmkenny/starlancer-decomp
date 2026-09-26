//! `C:\lancer\game\environfx.cpp`: the effects a mission's space is drawn with. OpenReliant has the
//! engine glows, the flares a ship's thrusters burn, which `engine_glows_build` (`0x00469620`)
//! makes once at start-up and every ship's attachments of kind `engine_glow` then draw, and the
//! capital ships' exhaust, which burns the player's ship flying into it (`Exhaust`). The file also
//! holds the environment effects a script turns on (`environment_effect_set`, `0x00469C60`), which
//! [`backdrop.zig`](backdrop.zig) draws. Only that one asserts, so only its code names the file;
//! the glows and the exhaust lie in the stretch the linker gave it, between `Create.cpp`'s code
//! and `erayfx.cpp`'s ([`sources.zig`](../sources.zig)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const aigeneric = @import("aigeneric.zig");
const collision = @import("collision.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const matmanager = @import("matmanager.zig");
const objects = @import("objects.zig");
const Vector = math.Vector;
const backdrop = @import("backdrop.zig");
const nebula = @import("nebula.zig");
const log = std.log.scoped(.environfx);

/// What a mission's script asks of the space it is flown in, which `environment_update`
/// (`0x00469D30`) applies: the nebula it asks for, shown on the sky, whose fill lights take the
/// nebula's colour (`nebula.Sky.select`).
///
/// Not ported: the rest of `environment_update`, the objects' flag `0x400` it sets and clears as
/// asked, and the environment effects it turns on and off, which commands of other missions ask
/// for (`DisableObjectAtNextJump`, `SetEnvironmentFX`,
/// [#281](https://github.com/vdmkenny/openreliant/issues/281)).
pub const Environment = struct {
    sky: *nebula.Sky,
    textures: *srtexture.Table,
    lights: *backdrop.Lights,
    /// `nebula_requested` (`0x0058A6B8`): the nebula `SetEnvironmentFXNebula` asks for, the
    /// first until one does. A mission's start leaves it as the one before asked.
    requested: u32 = nebula.default_nebula,

    /// `environment_update` (`0x00469D30`), as a fixed gate's jump ends or the script asks
    /// (`UpdateEnvironmentFXState`): the nebula asked for shows where the sky shows another
    /// (`nebula_select`, `0x00498D00`).
    ///
    /// **Fix:** the game stops with the assertion "Error in script: Invalid nebula" for a nebula
    /// past the seventh; OpenReliant logs it, and keeps the nebula it shows.
    pub fn update(environment: *Environment) void {
        if (environment.sky.nebula == environment.requested) return;
        environment.sky.select(environment.textures, environment.requested, environment.lights) catch |err| {
            log.warn("nebula {d} is left out: {s}", .{ environment.requested, @errorName(err) });
        };
    }
};

/// How many engine glows the game builds. An attachment's id picks one, clamped to these
/// (`engine_glow_create`, `0x004697D0`).
pub const glow_kinds = 7;

/// The glows' meshes (`engine_glow_meshes`, `0x0054EA18`), built once and shared by every glow
/// drawn. Whatever holds these must outlive the models pointing at them.
pub const Glows = struct {
    meshes: [glow_kinds]srapiext.Mesh,

    /// Builds all seven (`engine_glows_build`), each with its own pair of flare materials.
    pub fn create(gpa: Allocator, textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!Glows {
        var glows: Glows = .{ .meshes = undefined };
        var made: usize = 0;
        errdefer for (glows.meshes[0..made]) |built| built.deinit(gpa);
        for (&glows.meshes, 0..) |*built, kind| {
            built.* = try glowMesh(gpa, textures, kind);
            made += 1;
        }
        return glows;
    }

    /// Frees what `gpa` allocated for them (`engine_glows_free`, `0x00469770`).
    pub fn deinit(glows: *const Glows, gpa: Allocator) void {
        for (glows.meshes) |built| built.deinit(gpa);
    }

    /// The mesh an attachment of `id` draws. The game clamps the id to the glows it has, so an
    /// attachment naming none of them draws the first (`engine_glow_create`).
    pub fn mesh(glows: *const Glows, id: u32) *const srapiext.Mesh {
        return &glows.meshes[std.math.clamp(id, 1, glow_kinds) - 1];
    }
};

/// The quads a plume's mesh is made of: one across its foot, then the blades down it.
const nozzle_quads = 1;
const blade_quads = 3;
const quads = nozzle_quads + blade_quads;
const corners = 4;

/// How far apart the blades stand about the axis the plume runs along (`0x004DC458`). Each blade is
/// a single quad crossing the axis, so it stands for two, and a sixth of a turn apart spreads the
/// three of them evenly around it.
///
/// **Improvement:** a sixth of a turn exactly, where the game rounds it to 1.0472.
const blade_step: f32 = std.math.pi / 3.0;

/// How far into a flare's texture a corner reaches: a little inside its edges, so that a flare
/// fades out rather than ending on the texture's border.
const uv_near: f32 = 0.04;
const uv_far: f32 = 0.99;

/// What a glow's quads are sorted by, ten in front of where they lie, so that a plume is drawn over
/// the hull it burns from rather than fighting with it. `srofiles.build` puts a third of a face's
/// own bias in the same place.
const sort_bias: f32 = -10;

/// A flare's material: added to what stands behind it, unlit, with the mesh's own coordinates.
const flare_material: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = false, .blend = .add });

/// The material a glow's nozzle draws with, and the one its blades draw with
/// (`engine_glows_build`).
const nozzle_materials = materialNames("matflarea");
const blade_materials = materialNames("matflareb");

/// `matflarea1` to `matflarea7`, or `matflareb1` to `matflareb7`: the game numbers them from one.
fn materialNames(comptime prefix: []const u8) [glow_kinds][]const u8 {
    var names: [glow_kinds][]const u8 = undefined;
    for (&names, 1..) |*name, kind| name.* = std.fmt.comptimePrint("{s}{d}", .{ prefix, kind });
    return names;
}

/// One glow's mesh (`engine_glow_mesh_build`, `0x00469400`): a plume a unit across and a unit
/// long, for `node_draw` to scale by the attachment's size and to stretch along the plume by the
/// throttle, over the mesh's own texture coordinates, a little inside each flare.
fn glowMesh(gpa: Allocator, textures: *srtexture.Table, kind: usize) (Allocator.Error || matmanager.Error)!srapiext.Mesh {
    const nozzle = try matmanager.textureRequire(textures, nozzle_materials[kind]);
    const blades = try matmanager.textureRequire(textures, blade_materials[kind]);
    var mesh = try plumeMesh(gpa, @splat(1), flare_material, nozzle, blades);
    errdefer mesh.deinit(gpa);
    const uv = try mesh.addCoordinates(gpa);
    // Nothing gives the quads their planes, so every one of them faces the camera: the mesh is
    // never culled by them.
    @memset(mesh.biases, sort_bias);
    for (0..quads) |quad| {
        uv[quad * corners ..][0..corners].* = .{
            .{ uv_far, uv_far }, .{ uv_far, uv_near }, .{ uv_near, uv_near }, .{ uv_near, uv_far },
        };
    }
    return mesh;
}

/// A plume's mesh, which the engine glows and the muzzle flashes (`guns.flash`) share: four quads
/// of sixteen vertices, `size` across, up and long. The first stands square across the plume's
/// foot, and the other three run down the plume from it, `blade_step` apart about it. The first
/// quad is drawn with `material` over `nozzle`, the rest with it over `blades`.
pub fn plumeMesh(gpa: Allocator, size: Vector, material: srapiext.Material, nozzle: *srtexture.Image, blades: *srtexture.Image) Allocator.Error!srapiext.Mesh {
    const vertex_count = quads * corners;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = quads, .vertices = vertex_count, .indices = vertex_count, .surfaces = 2 });
    errdefer mesh.deinit(gpa);
    mesh.surfaces[0] = .{ .polygons = nozzle_quads, .material = material, .textures = .{ .{ .image = nozzle }, .none } };
    mesh.surfaces[1] = .{ .polygons = blade_quads, .material = material, .textures = .{ .{ .image = blades }, .none } };

    // The nozzle sits square across the plume's foot, where it leaves the hull.
    mesh.positions[0..corners].* = .{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };
    for (0..blade_quads) |blade| {
        const angle = @as(f32, @floatFromInt(blade)) * blade_step;
        const across: Vector = .{ @sin(angle), @cos(angle), 0 };
        const along: Vector = .{ 0, 0, 1 };
        mesh.positions[(nozzle_quads + blade) * corners ..][0..corners].* = .{ -across, along - across, along + across, across };
    }
    for (mesh.positions) |*position| position.* *= size;
    mesh.numberPolygons(corners);
    for (mesh.indices, 0..) |*index, at| index.* = @intCast(at);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

// --- The exhaust ---------------------------------------------------------------------------------

/// The ships whose engine exhaust burns the player's ship (`exhaust_ships`, `0x0054EA80`, and
/// `exhaust_ship_count`, `0x0054F0C0`): those that list components and carry an engine glow, by
/// their slots, listed the first time they are looked at (`exhaust_ships_listed`, `0x0054F0C4`),
/// with each one `create_object` makes after (`offer`). And whether the player's ship stands in
/// one's exhaust this frame (`exhaust_burning`, `0x0054EA7C`), which keeps the display's red away
/// (`main.drawFrame`).
///
/// A slot stays listed whatever it comes to hold, and an object made in a listed slot is listed
/// again, as the game lists them.
pub const Exhaust = struct {
    ships: [capacity]u16 = undefined,
    count: usize = 0,
    listed: bool = false,
    burning: bool = false,

    /// The slots the list has room for.
    pub const capacity = gameobj.max_objects;

    /// `exhaust_ships_reset` (`0x00469840`), as a mission ends (`0x004AD260`): the ships to be
    /// listed afresh.
    pub fn reset(exhaust: *Exhaust) void {
        exhaust.listed = false;
    }

    /// `create_object`'s offer (`0x004684E4`): once the ships are listed, the object it made in
    /// slot `index` joins them where it would have been listed.
    pub fn offer(exhaust: *Exhaust, all: *const create.Objects, index: u16) void {
        if (exhaust.listed) exhaust.add(all, index);
    }

    /// `exhaust_ship_add` (`0x004699E0`): the object in slot `index` listed, where it lists
    /// components and carries an engine glow (`0x00469BC0`).
    ///
    /// **Fix:** the game lists past its room, for a list that a slot made again has grown;
    /// OpenReliant lists no more.
    fn add(exhaust: *Exhaust, all: *const create.Objects, index: u16) void {
        const slot = &all.slots[index];
        if (!slot.object.flags.components) return;
        const model = if (slot.model) |*held| held else return;
        if (!carriesGlow(model)) return;
        if (exhaust.count == capacity) return;
        exhaust.ships[exhaust.count] = index;
        exhaust.count += 1;
    }

    /// `exhaust_ships_list` (`0x00469810`): the slots handed out, each in turn.
    fn list(exhaust: *Exhaust, all: *const create.Objects) void {
        exhaust.count = 0;
        for (0..all.count) |index| exhaust.add(all, @intCast(index));
        exhaust.listed = true;
    }

    /// `exhaust_burn` (`0x00469850`), once a frame as `mission_frame` runs: while the player's ship
    /// flies under Player Control, each listed ship whose throttle is not at nothing, and whose
    /// reach of `reach_radii` of its radius meets the player's ship, measures how deep the player's
    /// ship stands in its exhaust (`depth`), by its throttle and its engines. Anywhere in it, the
    /// display's red keeps away (`burning`). The screen's flash lasts `flash_per_depth` ticks for
    /// each of the depth, which also cuts short a flash where the depth is nothing, and on a tick
    /// that `burn_ticks` divides, a depth above nothing burns the ship on its fore quadrant as a
    /// collision, by `burn_damage` for each of the depth, no more than one.
    ///
    /// The ships meet where the distance between them, squared, is no more than the reach squared
    /// and the player's ship's radius squared together, as the game has it.
    ///
    /// The game lets go of `burning` each time round its loop (`mission_run`); OpenReliant as this
    /// starts.
    pub fn burn(exhaust: *Exhaust, world: gameobj.World) void {
        const all = world.objects;
        if (!exhaust.listed) exhaust.list(all);
        exhaust.burning = false;
        const flying = aigeneric.current(all, all.player) orelse return;
        if (flying.order != .player_control) return;
        const player = &all.slots[all.player];
        const at = player.drawn.position;
        for (exhaust.ships[0..exhaust.count]) |index| {
            const ship = &all.slots[index];
            const object = &ship.object;
            if (object.last_throttle == 0) continue;
            const reach = object.radius * reach_radii;
            const radius = player.object.radius;
            if (math.lengthSquared(ship.drawn.position - at) > reach * reach + radius * radius) continue;
            const model = if (ship.model) |*held| held else continue;
            const strength = @abs(object.last_throttle * object.engines_intact) * reach_share;
            const deep = depth(model, object.placeAt(.next), at, strength);
            if (deep > 0) exhaust.burning = true;
            if (world.flash) |flash| flash.left = @intFromFloat(deep * flash_per_depth);
            if (@rem(world.clock.frame_start, burn_ticks) == 0 and deep > 0) {
                collision.damage(world, all.player, .fore, @min(deep, 1) * burn_damage, burn_through, all.player, .collision);
            }
        }
    }
};

/// How far a ship's exhaust reaches, in its radii (`0x004DC7EC`); how far a glow's exhaust reaches
/// beyond its size, at full throttle (`0x004DC780`); how long the screen's flash lasts for each of
/// the depth, in ticks (`0x004DC440`); and how often the exhaust burns, in ticks, how much it burns
/// at a depth of one, and how much of what passes the shields wears the armour (`0x00469968`,
/// `0x004DC7E8`, `0x004699A5`).
const reach_radii: f32 = 1.2;
const reach_share: f32 = 1.7;
const flash_per_depth: f32 = 100;
const burn_ticks = 7;
const burn_damage: f32 = 23;
const burn_through: f32 = 0.5;

/// Whether `model`, or a model it carries, carries an engine glow on a part not taken out of it
/// (`0x00469BC0`).
fn carriesGlow(model: *const objects.Model) bool {
    for (model.glows) |glow| {
        if (!model.parts[glow.part].removed) return true;
    }
    var each = model.carried();
    while (each.next()) |mount| {
        if (!model.parts[mount.part].removed and carriesGlow(&mount.model)) return true;
    }
    return false;
}

/// `exhaust_depth` (`0x00469A10`): how deep `point`, in the world, stands in the exhaust of
/// `model`'s engine glows and of the models it carries, with its root at `root`, summed over them
/// (`glowDepth`), each glow where it next stands and its exhaust `strength` times its size.
fn depth(model: *const objects.Model, root: math.Place, point: Vector, strength: f32) f32 {
    var sum: f32 = 0;
    for (model.glows) |glow| {
        if (model.parts[glow.part].removed) continue;
        const part = model.partPlace(glow.part, .next).within(root);
        const place = (math.Place{ .position = glow.origin, .orientation = glow.orientation }).within(part);
        sum += glowDepth(glow.level[0].mesh.bounds, glow.size * @as(Vector, @splat(strength)), place.inverse(point));
    }
    var each = model.carried();
    while (each.next()) |mount| {
        if (model.parts[mount.part].removed) continue;
        sum += depth(&mount.model, model.mountRoot(mount, root, .next), point, strength);
    }
    return sum;
}

/// How deep a point at `local` in a glow's own frame stands in its exhaust: its mesh's `bounds`
/// times `scale`, their ends along the plume changing places where the scale turns it back. Inside,
/// 1 at the glow's origin down to nothing at the bounds' far corner; outside, nothing.
///
/// **Fix:** an exhaust of no size, as a ship whose engines are out burns, leaves a point at its
/// origin nothing deep, where the game divides nothing by nothing.
fn glowDepth(bounds: [2]Vector, scale: Vector, local: Vector) f32 {
    var low = bounds[0] * scale;
    var high = bounds[1] * scale;
    if (high[2] < low[2]) {
        const near = high[2];
        high[2] = low[2];
        low[2] = near;
    }
    if (@reduce(.Or, local > high) or @reduce(.Or, local < low)) return 0;
    const far = math.length(high);
    if (!(far > 0)) return 0;
    return 1 - math.length(local) / far;
}

pub const testing = struct {
    /// The glows built over a table holding nothing but their flares, for tests that draw them.
    pub const Built = struct {
        textures: *@import("../surrender/surrenderlib/srtexture.zig").testing.Textures,
        glows: Glows,

        pub fn init(gpa: Allocator) !Built {
            var names: [glow_kinds * 2][]const u8 = undefined;
            for (nozzle_materials, blade_materials, 0..) |nozzle, blade, kind| {
                names[kind * 2] = nozzle;
                names[kind * 2 + 1] = blade;
            }
            const textures = try @import("../surrender/surrenderlib/srtexture.zig").testing.Textures.init(gpa, &names);
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .glows = try .create(gpa, &textures.table) };
        }

        pub fn deinit(built: Built, gpa: Allocator) void {
            built.glows.deinit(gpa);
            built.textures.deinit(gpa);
        }
    };
};

test glowMesh {
    const gpa = std.testing.allocator;
    const textures = try @import("../surrender/surrenderlib/srtexture.zig").testing.Textures.init(gpa, &.{ "matflarea1", "matflareb1" });
    defer textures.deinit(gpa);
    const mesh = try glowMesh(gpa, &textures.table, 0);
    defer mesh.deinit(gpa);

    // The nozzle quad, then a blade for each third of a half turn.
    try std.testing.expectEqual(16, mesh.positions.len);
    try std.testing.expectEqual(@as(Vector, .{ -1, -1, 0 }), mesh.positions[0]);
    try std.testing.expectEqual(@as(Vector, .{ 0, -1, 0 }), mesh.positions[4]);
    try std.testing.expectEqual(@as(Vector, .{ 0, 1, 1 }), mesh.positions[6]);
    try std.testing.expectApproxEqAbs(-0.866025, mesh.positions[8][0], 1e-5);
    try std.testing.expectApproxEqAbs(-0.5, mesh.positions[8][1], 1e-5);

    // Each quad is four consecutive indices, drawn as a fan over the whole flare.
    try std.testing.expectEqual(srapiext.Polygon{ .kind = .triangle, .continues = 0, .first = 12, .count = 4 }, mesh.polygons[3]);
    try std.testing.expectEqualSlices(u16, &.{ 12, 13, 14, 15 }, mesh.indices[12..16]);
    try std.testing.expectEqual([2]f32{ uv_far, uv_near }, mesh.uv[0].?[13]);
    try std.testing.expectEqual(sort_bias, mesh.biases[3]);

    // The nozzle takes the `a` flare and the blades the `b` one, both added and unlit.
    try std.testing.expectEqual(1, mesh.surfaces[0].polygons);
    try std.testing.expectEqual(3, mesh.surfaces[1].polygons);
    try std.testing.expect(mesh.surfaces[0].textures[0].image != mesh.surfaces[1].textures[0].image);
    try std.testing.expectEqual(srapiext.Material.Blend.add, mesh.surfaces[1].material.blend[0]);
    try std.testing.expect(!mesh.surfaces[1].material.lit[0]);

    // A unit across and a unit long, reaching furthest at the nozzle's corners.
    try std.testing.expectEqual(@as(Vector, .{ -1, -1, 0 }), mesh.bounds[0]);
    try std.testing.expectEqual(@as(Vector, .{ 1, 1, 1 }), mesh.bounds[1]);
    try std.testing.expectApproxEqAbs(std.math.sqrt2, mesh.radius, 1e-5);
}

test plumeMesh {
    const gpa = std.testing.allocator;
    const textures = try @import("../surrender/surrenderlib/srtexture.zig").testing.Textures.init(gpa, &.{ "matflarea3", "matflareb3" });
    defer textures.deinit(gpa);
    const nozzle = try matmanager.textureRequire(&textures.table, "matflarea3");
    const mesh = try plumeMesh(gpa, .{ 60, 60, 600 }, flare_material, nozzle, nozzle);
    defer mesh.deinit(gpa);

    // Stretched to its size: the nozzle's corners, and each blade's far end.
    try std.testing.expectEqual(@as(Vector, .{ 60, -60, 0 }), mesh.positions[1]);
    try std.testing.expectEqual(@as(Vector, .{ 0, 60, 600 }), mesh.positions[6]);
    try std.testing.expectApproxEqAbs(-0.866025 * 60.0, mesh.positions[8][0], 1e-3);
    try std.testing.expectEqual(@as(Vector, .{ 60, 60, 600 }), mesh.bounds[1]);
    // No coordinates of its own, and no bias.
    try std.testing.expectEqual(null, mesh.uv[0]);
    try std.testing.expectEqual(0, mesh.biases[0]);
}

test "materials are numbered from one" {
    try std.testing.expectEqualStrings("matflarea1", nozzle_materials[0]);
    try std.testing.expectEqualStrings("matflareb7", blade_materials[glow_kinds - 1]);
}

test Glows {
    const gpa = std.testing.allocator;
    const built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const glows = built.glows;

    // An id names a glow from one; one past either end takes the nearest.
    try std.testing.expectEqual(&glows.meshes[0], glows.mesh(1));
    try std.testing.expectEqual(&glows.meshes[glow_kinds - 1], glows.mesh(glow_kinds));
    try std.testing.expectEqual(&glows.meshes[0], glows.mesh(0));
    try std.testing.expectEqual(&glows.meshes[glow_kinds - 1], glows.mesh(99));
}

test {
    std.testing.refAllDecls(@This());
}

test glowDepth {
    const bounds: [2]Vector = .{ .{ -1, -1, 0 }, .{ 1, 1, 1 } };
    const size: Vector = .{ 2, 2, 10 };
    // The whole depth at the glow's origin, nothing at the far corner, and nothing outside.
    try std.testing.expectEqual(1, glowDepth(bounds, size, @splat(0)));
    try std.testing.expectApproxEqAbs(0, glowDepth(bounds, size, size), 1e-6);
    try std.testing.expectEqual(0, glowDepth(bounds, size, .{ 0, 0, -1 }));
    try std.testing.expectEqual(0, glowDepth(bounds, size, .{ 3, 0, 5 }));
    try std.testing.expectApproxEqAbs(1 - 5 / math.length(size), glowDepth(bounds, size, .{ 0, 0, 5 }), 1e-5);
    // A plume turned back along its length reaches the other way.
    const back: Vector = .{ 2, 2, -10 };
    try std.testing.expect(glowDepth(bounds, back, .{ 0, 0, -1 }) > 0);
    try std.testing.expectEqual(0, glowDepth(bounds, back, .{ 0, 0, 1 }));
    // An exhaust of no size, as of a ship whose engines are out, is nothing deep.
    try std.testing.expectEqual(0, glowDepth(bounds, @splat(0), @splat(0)));
}

test Exhaust {
    const gpa = std.testing.allocator;
    const built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.predator, @splat(0));
    // A capital ship behind the player, its one engine's plume burning forward along +Z through
    // where the player's ship stands.
    const capital = try mission.addOther(.{ 0, 0, -200 });
    var parts = [_]objects.Model.Part{.{
        .hidden = false,
        .parent = null,
        .origin = @splat(0),
        .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} },
    }};
    var glows = [_]objects.Model.Glow{.{
        .part = 0,
        .origin = .{ 0, 0, -50 },
        .orientation = math.identity,
        .size = .{ 100, 100, 200 },
        .retro = false,
        .steady = false,
        .level = .{.{ .mesh = built.glows.mesh(1), .until = std.math.inf(f32) }},
        .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} },
    }};
    const ship = mission.slot(capital);
    ship.model = .{ .parts = &parts, .order = &.{0}, .lights = &.{}, .glows = &glows, .mounts = &.{} };
    defer ship.model = null;
    ship.object.flags.components = true;
    ship.object.radius = 400;
    ship.object.last_throttle = 1;
    var flash: @import("main/flash.zig").Flash = .{};
    var world = mission.world();
    world.flash = &flash;
    const exhaust = &all.exhaust;

    // Listed once looked at, it burns nothing while the player's ship is not under its controls.
    exhaust.burn(world);
    try std.testing.expect(exhaust.listed);
    try std.testing.expectEqualSlices(u16, &.{capital}, exhaust.ships[0..exhaust.count]);
    try std.testing.expect(!exhaust.burning);

    // Under them, in the plume: the red keeps away, the view whites out by the depth, and on a
    // seventh tick the ship's fore quadrant burns.
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .player_control, .none));
    const deep = depth(&ship.model.?, ship.object.placeAt(.next), @splat(0), reach_share);
    try std.testing.expect(deep > 0 and deep < 1);
    const shields = all.slots[player].object.shields;
    mission.clock.frame_start = 6;
    exhaust.burn(world);
    try std.testing.expect(exhaust.burning);
    try std.testing.expectEqual(@as(i32, @intFromFloat(deep * flash_per_depth)), flash.left);
    try std.testing.expectEqual(shields, all.slots[player].object.shields);
    mission.clock.frame_start = 7;
    exhaust.burn(world);
    try std.testing.expect(all.slots[player].object.shields.fore < shields.fore);
    try std.testing.expectEqual(shields.aft, all.slots[player].object.shields.aft);

    // With its engines idle, it burns nothing.
    ship.object.last_throttle = 0;
    exhaust.burn(world);
    try std.testing.expect(!exhaust.burning);

    // Once listed, a ship made after joins; one that lists no components doesn't.
    ship.object.last_throttle = 1;
    const later = try mission.addOther(.{ 0, 0, 5000 });
    exhaust.offer(all, later);
    try std.testing.expectEqual(1, exhaust.count);
    exhaust.offer(all, capital);
    try std.testing.expectEqual(2, exhaust.count);
    // A mission's start lists them afresh.
    exhaust.reset();
    try std.testing.expect(!exhaust.listed);
}
