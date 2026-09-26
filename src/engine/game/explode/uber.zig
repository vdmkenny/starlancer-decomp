//! `C:\lancer\game\explode.cpp`'s Uber Explode: the huge explosion the Huuuuuuuge Explosion order
//! sets off ([`aiexplode.huge`](../aiexplode.zig)), one at a time. Two halves of a sphere of fire
//! open out from where it goes off and fade, as two rings spread from it; then a ball of flame
//! spreads through what is near, knocking each ship it reaches spinning and setting it alight, as
//! burning bits fly at the camera, the view shakes and at last flashes white. At its end each ship
//! it reached is destroyed.
//!
//! The game also makes two squares, `UberWave1` over `bigshock1` and `UberWave2` over `bigshock2`,
//! and a light, `UberExplosion_Light`, and grows the first square as the blast goes on, but never
//! puts any of them in the scene; OpenReliant leaves the squares out, and shows the light only in
//! the fuller style (`Style`).
//!
//! **Improvement:** the game opens the halves and spreads the ball by rounded factors (3.33333 and
//! 1.42857 a share, 0.19635 and 0.349066 radians); OpenReliant divides.
//!
//! Not ported: what a blast in a multiplayer game spares, counts and tells the players, which is
//! multiplayer's ([#55](https://github.com/vdmkenny/openreliant/issues/55)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const Slot = @import("../create.zig").Slot;
const events = @import("../mission/events.zig");
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const matmanager = @import("../matmanager.zig");
const particles = @import("../particles.zig");
const shield = @import("../shield.zig");
const shockwave = @import("../shockwave.zig");
const libcmt = @import("../../libcmt.zig");
const srlight = @import("../../surrender/surrenderlib/srlight.zig");
const sound3d = @import("../sound3d.zig");
const xtrabits = @import("../xtrabits.zig");

/// How a blast is shown.
///
/// **Improvement:** `fuller` draws the halves and the ball on grids `fineness` times as fine as the
/// game's, so neither shows its facets: the halves fade to their rim over as many rings as the
/// game's last band holds, and the ball flickers as the game's does, between its vertices. It
/// flickers and throws its burning bits at the pace of the simulation's steps, 25 times a second,
/// where the game does both each frame, so a faster frame rate neither quickens the flicker nor
/// throws more bits. And the light the game makes but never shows lights what is round the blast,
/// as bright as the halves, while they show. `--original` restores the game's.
pub const Style = enum {
    original,
    fuller,

    /// How many times as fine as the game's its grids are.
    fn fineness(style: Style) u16 {
        return switch (style) {
            .original => 1,
            .fuller => 3,
        };
    }
};

/// The game's grids: the hemisphere both halves show (`uber_hemisphere_create`, `0x00473BF0`),
/// whose first `game_rings` bands the halves show, a ring each round a pole, and a last pole no
/// triangle uses; and the ball's sphere (`sphere_mesh_create`'s grid).
const game_hemisphere: shield.Grid = .{ .around = 18, .down = 16 };
const game_rings = 7;
const game_ball: shield.Grid = .{ .around = 18, .down = 8 };
const game_ball_vertices = game_ball.vertices();

/// A blast's grids in a style: the game's, `fine` times as fine.
const Shape = struct {
    fine: u16,
    hemisphere: shield.Grid,
    rings: usize,
    ball: shield.Grid,

    fn of(style: Style) Shape {
        const fine = style.fineness();
        return .{
            .fine = fine,
            .hemisphere = .{ .around = game_hemisphere.around * fine, .down = game_hemisphere.down * fine },
            .rings = game_rings * fine,
            .ball = .{ .around = game_ball.around * fine, .down = game_ball.down * fine },
        };
    }

    fn hemisphereVertices(shape: Shape) usize {
        return shape.rings * shape.hemisphere.around + 2;
    }

    /// How much of the halves' colour vertex `index` takes: all of it, but for the game's last
    /// band, across which it fades to nothing at the last ring, and the last pole, which takes
    /// none.
    fn fade(shape: Shape, index: usize) f32 {
        if (index == 0) return 1;
        if (index == shape.hemisphereVertices() - 1) return 0;
        const ring = 1 + (index - 1) / shape.hemisphere.around;
        return @min(1, @as(f32, @floatFromInt(shape.rings - ring)) / @as(f32, @floatFromInt(shape.fine)));
    }
};

/// The finest grids a blast is drawn on.
const finest: Shape = .of(.fuller);
const max_hemisphere_vertices = finest.hemisphereVertices();
const max_ball_vertices = finest.ball.vertices();

comptime {
    for (std.enums.values(Style)) |style| std.debug.assert(style.fineness() <= finest.fine);
}

/// How far through a blast, as shares of its duration: the halves flare up until `flared`, open
/// out until `opened`, when the ball starts to spread, and fade out by `faded`, when the bits
/// start to fly; and the view flashes from `flash_from` (`0x004DC474`, `0x004DC4C0`, `0x004DC408`,
/// `0x004DC414`).
const flared: f32 = 0.05;
const opened: f32 = 0.3;
const faded: f32 = 0.5;
const flash_from: f32 = 0.95;

/// How far a blast reaches, by its size: the ships it lists stand within `reach`, as far as the
/// ball spreads to from `least_scale` (`0x004DC56C`); and the halves are drawn at `half_scale`
/// (`0x004DC854`).
const reach: f32 = 5;
const least_scale: f32 = 0.001;
const half_scale: f32 = 1.3;

/// How many ships a blast lists (`0x00562B88`).
pub const max_caught = 80;

/// The rings a blast sets off: so far across by its size, over a share of its duration
/// (`0x004DC848`, `0x004DC3D4`, `0x004DC400`, `0x004DC408`).
const Wave = struct { size: f32, life: f32 };
const waves = [_]Wave{ .{ .size = 16, .life = 0.25 }, .{ .size = 6, .life = 0.5 } };

/// The halves' alpha at full brightness, as they start (`0x004DC4C0`).
const half_alpha: f32 = 0.3;

/// How a half takes its texture from where each vertex lies across, halved and moved in by a half
/// (`0x004DC408`).
const half_mapping: f32 = 0.5;

/// The one point of the shield's texture the ball shows, from `opened` (a texel of the 128 square
/// `shield128`); and its green, a share of its red (`0x004DC4C0`).
const ball_texel: [2]f32 = .{ 45.0 / 128.0, 18.0 / 128.0 };
const ball_green: f32 = 0.3;

/// The ball's glow: red, twice as wide as the ball, sorted as if at its edge.
const glow_colour: [3]f32 = .{ 0.75, 0, 0 };
const glow_scale: f32 = 2;

/// The light the game makes (`UberExplosion_Light`): lilac, at `light_intensity`, reaching that
/// times `light_reach` of the blast's size (`0x004DC72C`).
const light_colour: [3]f32 = .{ 0.7, 0.5, 1 };
const light_intensity: f32 = 2;
const light_reach: f32 = 20;

/// How hard the ball knocks a ship, by its mass (`0x004DC438`); how far from its middle, by its
/// radius (`0x004DC4B4`); and how fast it sets it spinning, a tick about each axis, half of it
/// either way (`0x004DC4C0`).
const knock_strength: f32 = 2000;
const lever_share: f32 = 0.6;
const tumble: f32 = 0.3;

/// The fireballs the ball sets off about a ship: within half its radius, half its radius across,
/// `fireball_gap` ticks apart.
const fireballs = 5;
const fireball_share: f32 = 0.5;
const fireball_gap = 30;

/// How hard the view shakes as the ball spreads out, at its widest.
const most_shake: f32 = 2;

/// How many ticks the view flashes for, a share past `flash_from` (`0x004DC438`), which comes to a
/// full flash (`flash.flash_ticks`) at the end.
const flash_rate: f32 = 2000;

/// The burning bits flying at the camera a frame from `faded`: while the count thrown stays under
/// `bits_least` and a share of `bits_range` more, drawn afresh each time (`0x004DC850`); from
/// `bits_ahead` beyond the camera toward the blast, up to half of `bits_spread` off to each side
/// (`0x004DC84C`).
const bits_least = 12;
const bits_range: f32 = 13;
const bits_ahead: f32 = 10000;
const bits_spread: f32 = 4000;
const bits_throw: explode.Bit.Throw = .{ .size = 0.1, .speed = 1 };

/// The textures a blast shows.
pub const Images = struct {
    ring: *srtexture.Image,
    ball: *srtexture.Image,
    glow: *srtexture.Image,

    pub fn load(textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!Images {
        return .{
            .ring = try matmanager.textureRequire(textures, "ring3"),
            .ball = try matmanager.textureRequire(textures, "shield128"),
            .glow = try matmanager.textureRequire(textures, "gunflare\\partic6"),
        };
    }
};

/// A ship a blast listed, and whether the ball has reached it (the game adds 1000 to its slot).
pub const Caught = struct {
    index: u16,
    reached: bool = false,
};

/// A blast going off.
pub const Blast = struct {
    /// Whose it is (`0x00558718`), where it went off, how far it reaches (`0x00558714`), and from
    /// when for how long (`0x0055870C`, `0x00558710`).
    owner: u16,
    place: math.Place,
    size: f32,
    started: i32,
    duration: i32,
    /// How far through it is at the frame's tick.
    done: f32 = 0,
    caught: [max_caught]Caught = undefined,
    caught_count: usize = 0,
    style: Style,
    /// The tick it last drew its numbers afresh at (`rounds`), and whether its ball has flickered.
    paced_at: i32,
    flickered: bool = false,
    /// The halves (`UberHemi1`, `UberHemi2`), which share their own colours and texture
    /// coordinates, the first as many as the style's hemisphere has vertices.
    halves: [2]srapiext.MeshObject,
    half_colours: [max_hemisphere_vertices][4]f32 = undefined,
    half_uv: [max_hemisphere_vertices][2]f32 = undefined,
    /// The ball, which the game names as it names the second half, and its glow (`Uber BMO`). Its
    /// flicker is a colour for each vertex of the game's ball, which its own vertices take between
    /// them.
    ball: srapiext.MeshObject,
    ball_flicker: [game_ball_vertices][4]f32 = undefined,
    ball_colours: [max_ball_vertices][4]f32 = undefined,
    ball_uv: [max_ball_vertices][2]f32 = @splat(ball_texel),
    glow: srapiext.SpriteSet,
    glow_sprite: [1]srapiext.Sprite = .{.{ .colour = glow_colour }},
    /// Its light, in the fuller style.
    light: srlight.Light,

    fn listed(blast: *Blast) []Caught {
        return blast.caught[0..blast.caught_count];
    }

    fn shape(blast: *const Blast) Shape {
        return .of(blast.style);
    }

    /// How many times the blast draws its numbers afresh this frame, at tick `now`: once a frame,
    /// as the game does; or in the fuller style, once for each simulation step since it last did.
    fn rounds(blast: *Blast, now: i32) u32 {
        switch (blast.style) {
            .original => return 1,
            .fuller => {
                const due: u32 = @intCast(@divFloor(@max(now - blast.paced_at, 0), gameobj.ticks_per_step));
                blast.paced_at += @intCast(due * gameobj.ticks_per_step);
                return due;
            },
        }
    }

    /// The ball's part of the frame, `out` of the way to its widest, drawing its numbers afresh
    /// `drawn` times: it flickers red and orange vertex by vertex, grows, and shakes the view, and
    /// it reaches each ship it listed that stands within it.
    fn spread(blast: *Blast, world: gameobj.World, out: f32, drawn: u32) void {
        if (drawn > 0 or !blast.flickered) blast.flicker(world.random);
        blast.ball.scale = math.lerp(least_scale, blast.size * reach, out);
        world.shake.* = most_shake * out;
        blast.glow_sprite[0].half_size = @splat(blast.ball.scale * glow_scale);
        blast.glow_sprite[0].bias = -blast.ball.scale;
        for (blast.listed()) |*caught| if (!caught.reached) blast.strike(world, caught);
    }

    /// The ball's flicker drawn afresh: each vertex of the game's ball red at a random number to
    /// the fifth, its green `ball_green` of its red; each of its own vertices taking the colours of
    /// those round it (`shield.Grid.sample`).
    fn flicker(blast: *Blast, random: *libcmt.Rand) void {
        // Two numbers the game draws and drops.
        _ = random.rand();
        _ = random.rand();
        for (&blast.ball_flicker) |*colour| {
            const f = random.fraction();
            const red = f * f * f * f * f;
            colour.* = .{ red, red * ball_green, 0, 1 };
        }
        const grid = blast.shape().ball;
        for (blast.ball_colours[0..grid.vertices()], 0..) |*colour, index| colour.* = grid.sample(game_ball, &blast.ball_flicker, index);
        blast.flickered = true;
    }

    /// The ball reaching a ship it listed, unless the ship is exploding already or gone: a knock
    /// away from the blast, off its middle; a spin about each axis; five fireballs about it, one
    /// after another; and its orders dropped for Do Nothing.
    fn strike(blast: *const Blast, world: gameobj.World, caught: *Caught) void {
        const slot = &world.objects.slots[caught.index];
        const object = &slot.object;
        if (object.type == .stand_in) return;
        if (aigeneric.current(world.objects, caught.index)) |entry| if (entry.order == .explode) return;
        if (math.distance(slot.drawn.position, blast.place.position) > blast.ball.scale) return;
        const random = world.random;
        const centre = gameobj.vector(object.root.position);
        const push = math.normalize(centre - blast.place.position) * @as(Vector, @splat(object.mass * knock_strength));
        const lever = math.transform(math.fromAngleVector(random.fractionVector(@splat(std.math.tau))), .{ 0, 0, object.radius * lever_share });
        object.rotation = math.fromAngleVector(random.centredVector(@splat(tumble)));
        gameobj.knock(object, push, lever + centre);
        for (0..fireballs) |n| {
            const at = random.centredVector(@splat(object.radius)) + slot.drawn.position;
            explode.fireballAt(world, at, .{ .size = object.radius * fireball_share, .light = true, .delay = @intCast(n * fireball_gap) });
        }
        const ctx: aigeneric.Context = .{ .world = world, .clock = world.clock };
        aigeneric.popAll(ctx, caught.index);
        _ = aigeneric.push(ctx, caught.index, .do_nothing, .none) catch {};
        caught.reached = true;
    }

    /// The burning bits a frame from `faded`: each from a point `bits_ahead` beyond the camera
    /// toward the blast, flying at the camera.
    fn throwBits(blast: *const Blast, world: gameobj.World) void {
        const seen = world.camera orelse return;
        const eye = seen.place.position;
        const toward = math.lookAt(blast.place.position - eye);
        const random = world.random;
        var thrown: i32 = 0;
        while (thrown < bits_least + @as(i32, @intFromFloat(random.fraction() * bits_range))) : (thrown += 1) {
            const y = random.centred() * bits_spread;
            const x = random.centred() * bits_spread;
            const from = math.transform(toward, .{ x, y, bits_ahead }) + eye;
            explode.throwBit(world, from, math.normalize(eye - blast.place.position), bits_throw);
        }
    }
};

/// What the Uber Explode keeps: for each style the hemisphere the halves share (`0x00562CD0`),
/// which a blast opens out, and the ball's sphere; and the blast going off, where one is.
pub const Uber = struct {
    meshes: std.EnumArray(Style, Meshes),
    glow: *srtexture.Image,
    blast: ?Blast = null,

    /// A style's hemisphere and ball, and a level of detail for each.
    const Meshes = struct {
        hemisphere: srapiext.Mesh,
        ball: srapiext.Mesh,
        levels: [2][1]srapiext.Level = undefined,

        fn deinit(meshes: *Meshes, gpa: Allocator) void {
            meshes.hemisphere.deinit(gpa);
            meshes.ball.deinit(gpa);
        }
    };

    /// As the explosions are set up (`explosions_init`, `0x0046B240`): the hemisphere, fully open,
    /// and the ball's sphere, for each style.
    pub fn create(gpa: Allocator, images: Images) Allocator.Error!*Uber {
        const uber = try gpa.create(Uber);
        errdefer gpa.destroy(uber);
        uber.* = .{ .meshes = undefined, .glow = images.glow };
        var made: usize = 0;
        errdefer for (std.enums.values(Style)[0..made]) |style| uber.meshes.getPtr(style).deinit(gpa);
        for (std.enums.values(Style)) |style| {
            const shape: Shape = .of(style);
            var half = try hemisphereMesh(gpa, shape, images.ring);
            errdefer half.deinit(gpa);
            const meshes = uber.meshes.getPtr(style);
            meshes.* = .{ .hemisphere = half, .ball = try shield.sphereMesh(gpa, shape.ball, images.ball) };
            meshes.levels = .{ .{.{ .mesh = &meshes.hemisphere, .until = std.math.inf(f32) }}, .{.{ .mesh = &meshes.ball, .until = std.math.inf(f32) }} };
            made += 1;
        }
        return uber;
    }

    pub fn destroy(uber: *Uber, gpa: Allocator) void {
        for (&uber.meshes.values) |*meshes| meshes.deinit(gpa);
        gpa.destroy(uber);
    }

    /// `uber_explode_start` (`0x00472AB0`): sets a blast of `size` off at `place` for `owner`, over
    /// `duration` ticks, shown in `style`, in place of any going off. It lists the ships it may
    /// reach: each object but the player's ship that is created and not disabled, of a side but the
    /// neutral one, with combat stats and an order, but for the gates, the Boridin and its
    /// breakaway, and within `reach` of its size. Its halves start at the point, dark and faint,
    /// but for their rims, which never show, each taking its texture from where its vertices lie;
    /// the second is turned half round. The view flashes, the two rings of `waves` spread, and the
    /// owner's ship sounds `uberexp`.
    ///
    /// The game asks for an order stack, which it makes with an object's first order; OpenReliant
    /// asks for an order.
    ///
    /// **Fix:** the game lists every ship in reach, running past the end of its list with more than
    /// `max_caught`; OpenReliant lists the first `max_caught`.
    pub fn start(uber: *Uber, world: gameobj.World, owner: u16, place: math.Place, size: f32, duration: i32, style: Style) void {
        const meshes = uber.meshes.getPtr(style);
        const shape: Shape = .of(style);
        const half: srapiext.MeshObject = .{
            .flags = .{ .not_culled = true, .always_drawn = true, .unbounded = true, .baked_object = true, .own_first = true },
            .position = place.position,
            .orientation = place.orientation,
            .radius = meshes.hemisphere.radius,
            .levels = &meshes.levels[0],
        };
        const now = world.clock.frame_start;
        uber.blast = .{
            .owner = owner,
            .place = place,
            .size = size,
            .started = now,
            .duration = duration,
            .style = style,
            .paced_at = now,
            .halves = .{ half, half },
            .ball = .{ .flags = half.flags, .position = place.position, .orientation = place.orientation, .radius = 1, .levels = &meshes.levels[1] },
            .glow = .{ .position = place.position, .sprites = &.{} },
            .light = .{
                .mask = 0,
                .intensity = 0,
                .colour = light_colour,
                .kind = .{ .point = .{ .position = place.position, .range = size * light_reach } },
            },
        };
        const blast = &uber.blast.?;
        blast.halves[1].orientation = math.product(math.fromAngles(0, std.math.pi, 0), place.orientation);
        const vertices = shape.hemisphereVertices();
        for (blast.half_colours[0..vertices], blast.half_uv[0..vertices], meshes.hemisphere.positions, 0..) |*colour, *uv, at, index| {
            colour.* = .{ 0, 0, 0, half_alpha * shape.fade(index) };
            uv.* = .{ at[0] * half_mapping + half_mapping, at[1] * half_mapping + half_mapping };
        }
        for (&blast.halves) |*shown| {
            shown.baked = blast.half_colours[0..vertices];
            shown.own_uv = .{ blast.half_uv[0..vertices], null };
        }
        const ball_vertices = shape.ball.vertices();
        blast.ball.baked = blast.ball_colours[0..ball_vertices];
        blast.ball.own_uv = .{ blast.ball_uv[0..ball_vertices], null };
        blast.glow.surface = .glow(uber.glow);
        blast.glow.sprites = &blast.glow_sprite;

        const all = world.objects;
        for (all.slots[0..all.count], 0..) |*slot, index| {
            if (blast.caught_count == max_caught) break;
            if (index == all.player or !catches(slot, place.position, size)) continue;
            blast.caught[blast.caught_count] = .{ .index = @intCast(index) };
            blast.caught_count += 1;
        }

        if (world.flash) |flash| flash.start();
        for (waves) |wave| shockwave.setOff(world, place, .{
            .kind = .uber,
            .size = size * wave.size,
            .life = @intFromFloat(@as(f32, @floatFromInt(duration)) * wave.life),
            .owner = owner,
        });
        sound3d.playIn(world, null, null, owner, .uberexp, 1, .guaranteed);
    }

    /// Whether a blast of `size` at `at` lists the object in `slot`.
    fn catches(slot: *const Slot, at: Vector, size: f32) bool {
        const object = &slot.object;
        if (object.flags.disabled or !object.created or object.order_count == 0) return false;
        const combat = slot.combat orelse return false;
        if (combat.side == .neutral) return false;
        switch (object.type) {
            .proto_gate, .advanced_gate, .boridin, .boridin_breakaway => return false,
            else => {},
        }
        return math.distance(slot.drawn.position, at) <= size * reach;
    }

    /// `uber_explode_update` (`0x00473210`), first in `explosions_update`: once its duration is
    /// past the blast ends (`end`). Until `faded` the halves grow to `half_scale` of its size,
    /// open out until `opened`, and brighten and fade by `brightness`, their light with them in the
    /// fuller style; from `opened` the ball spreads (`Blast.spread`); from `flash_from` the view
    /// flashes longer and longer; and from `faded` burning bits fly at the camera
    /// (`Blast.throwBits`), a round of them each time the blast draws its numbers afresh
    /// (`Blast.rounds`).
    ///
    /// **Fix:** the game colours one vertex of the halves' rims with the rest, which shows a sliver
    /// of the rim; OpenReliant keeps the whole rim clear, as the blast starts it.
    pub fn frame(uber: *Uber, world: gameobj.World) void {
        const blast = &(uber.blast orelse return);
        const now = world.clock.frame_start;
        if (blast.started + blast.duration < now) return uber.end(world);
        const done = particles.through(now, blast.started, blast.duration);
        blast.done = done;
        const drawn = blast.rounds(now);
        const shape = blast.shape();
        if (done < faded) {
            for (&blast.halves) |*half| half.scale = blast.size * half_scale;
            if (done < opened) open(uber.meshes.getPtr(blast.style).hemisphere.positions, shape, done / opened);
            const bright = brightness(done);
            for (blast.half_colours[0..shape.hemisphereVertices()], 0..) |*colour, index| {
                const lit = bright * shape.fade(index);
                colour.* = .{ lit, lit, lit, lit * half_alpha };
            }
            blast.light.intensity = light_intensity * bright;
        }
        if (done > opened) blast.spread(world, (done - opened) / (1 - opened), drawn);
        if (done > flash_from) if (world.flash) |flash| {
            flash.left = @intFromFloat((done - flash_from) * flash_rate);
        };
        if (done > faded) for (0..drawn) |_| blast.throwBits(world);
    }

    /// The blast's end: it goes (`uber_explode_free`, `0x004731A0`), its owner's ship sounds
    /// `capexp`, and each ship the ball reached stops turning and, unless it is exploding already,
    /// is destroyed, neither spinning nor ejecting. Last, the owner's ExplosionShip event is posted
    /// (`events.exploded`).
    fn end(uber: *Uber, world: gameobj.World) void {
        const blast = &uber.blast.?;
        defer uber.blast = null;
        sound3d.playIn(world, null, null, blast.owner, .capexp, 1, .player_fx);
        const ctx: aigeneric.Context = .{ .world = world, .clock = world.clock };
        for (blast.listed()) |caught| {
            if (!caught.reached) continue;
            const object = &world.objects.slots[caught.index].object;
            object.rotation = math.identity;
            object.roll_rate = 0;
            object.pitch_rate = 0;
            object.yaw_rate = 0;
            const entry = aigeneric.current(world.objects, caught.index) orelse continue;
            if (entry.order != .explode) ai.objectDestroyed(ctx, caught.index, false, true);
        }
        events.exploded(world, blast.owner);
    }

    /// The blast's objects, in the world's layer: the halves until `faded`, with its light in the
    /// fuller style, and the ball and its glow from `opened`.
    pub fn draw(uber: *Uber, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        const blast = &(uber.blast orelse return);
        if (blast.done < faded) {
            for (&blast.halves) |*half| try xtrabits.sceneAdd(gpa, scene, .{ .mesh = half }, .world);
            if (blast.style == .fuller) try xtrabits.sceneAdd(gpa, scene, .{ .light = &blast.light }, .world);
        }
        if (blast.done > opened) {
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &blast.ball }, .world);
            try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &blast.glow }, .world);
        }
    }
};

/// How bright the halves are `done` of the way through a blast: up from nothing until `flared`,
/// full until `opened`, then down to nothing at `faded`.
fn brightness(done: f32) f32 {
    if (done <= flared) return done / flared;
    if (done <= opened) return 1;
    return 1 - (done - opened) / (faded - opened);
}

/// `uber_hemisphere_open` (`0x00473EA0`): lays the hemisphere of `shape` out `share` of the way
/// open, of a unit radius, its pole at the origin and its bowl toward -Z: each ring `share` of a
/// band of its grid further round from the pole than the last. Shut, it is a point.
fn open(positions: []Vector, shape: Shape, share: f32) void {
    const hemisphere = shape.hemisphere;
    const step = share * std.math.pi / @as(f32, @floatFromInt(hemisphere.down));
    for (0..shape.rings + 2) |ring| {
        const angle = @as(f32, @floatFromInt(ring)) * step;
        const across = @sin(angle);
        const depth = @cos(angle) - 1;
        if (ring == 0 or ring == shape.rings + 1) {
            positions[if (ring == 0) 0 else shape.hemisphereVertices() - 1] = .{ 0, 0, depth };
            continue;
        }
        for (0..hemisphere.around) |slice| {
            const round = @as(f32, @floatFromInt(slice)) * std.math.tau / @as(f32, @floatFromInt(hemisphere.around));
            positions[hemisphere.ring(ring, slice)] = .{ @sin(round) * across, @cos(round) * across, depth };
        }
    }
}

/// `uber_hemisphere_create` (`0x00473BF0`): the hemisphere of `shape`, fully open, over `image`:
/// lit, blended over what is behind it, and coloured and mapped by its objects' own colours and
/// coordinates.
///
/// Not ported: its vertices' normals, which nothing lights.
fn hemisphereMesh(gpa: Allocator, shape: Shape, image: *srtexture.Image) Allocator.Error!srapiext.Mesh {
    const triangles = shape.hemisphere.triangles(shape.rings);
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = triangles, .vertices = shape.hemisphereVertices(), .indices = triangles * 3 });
    errdefer mesh.deinit(gpa);
    open(mesh.positions, shape, 1);
    shape.hemisphere.corners(shape.rings, mesh.indices);
    mesh.numberPolygons(3);
    mesh.surfaces[0] = .{
        .polygons = @intCast(triangles),
        .material = .onePass(.{ .coordinates = .generated, .lit = true, .blend = .premultiplied }),
        .textures = .{ .{ .image = image }, .none },
    };
    srapi.calcPolyNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

pub const testing = struct {
    var ring: srtexture.Image = .{ .levels = &.{} };
    var ball: srtexture.Image = .{ .levels = &.{} };
    var glow: srtexture.Image = .{ .levels = &.{} };

    pub fn images() Images {
        return .{ .ring = &ring, .ball = &ball, .glow = &glow };
    }
};

test hemisphereMesh {
    const gpa = std.testing.allocator;
    const game: Shape = .of(.original);
    var mesh = try hemisphereMesh(gpa, game, testing.images().ring);
    defer mesh.deinit(gpa);
    // A fan round the pole and six bands, 234 triangles over 128 vertices, every corner one of
    // them.
    try std.testing.expectEqual(234, mesh.polygons.len);
    try std.testing.expectEqual(128, mesh.positions.len);
    for (mesh.indices) |corner| try std.testing.expect(corner < game.hemisphereVertices() - 1);
    // Fully open, the pole at the origin and the last ring near the rim, a unit round, a unit down.
    try std.testing.expectEqual(@as(Vector, @splat(0)), mesh.positions[0]);
    const last = mesh.positions[game.hemisphere.ring(game.rings, 0)];
    try std.testing.expectApproxEqAbs(@sin(7 * std.math.pi / 16.0), last[1], 1e-5);
    try std.testing.expectApproxEqAbs(@cos(7 * std.math.pi / 16.0) - 1, last[2], 1e-5);

    // Shut, it is a point; half open, its last ring is half as far round.
    open(mesh.positions, game, 0);
    for (mesh.positions) |at| try std.testing.expectEqual(@as(Vector, @splat(0)), at);
    open(mesh.positions, game, 0.5);
    try std.testing.expectApproxEqAbs(@cos(3.5 * std.math.pi / 16.0) - 1, mesh.positions[game.hemisphere.ring(game.rings, 3)][2], 1e-5);

    // The fuller style's reaches as far round, its last ring where the game's is.
    const fuller: Shape = .of(.fuller);
    var fine = try hemisphereMesh(gpa, fuller, testing.images().ring);
    defer fine.deinit(gpa);
    try std.testing.expectEqual(fuller.hemisphereVertices(), fine.positions.len);
    const fine_last = fine.positions[fuller.hemisphere.ring(fuller.rings, 0)];
    try std.testing.expectApproxEqAbs(last[1], fine_last[1], 1e-5);
    try std.testing.expectApproxEqAbs(last[2], fine_last[2], 1e-5);
}

test "Shape.fade" {
    // The game's halves are coloured whole but for the last ring and the last pole.
    const game: Shape = .of(.original);
    try std.testing.expectEqual(1, game.fade(0));
    try std.testing.expectEqual(1, game.fade(game.hemisphere.ring(game.rings - 1, 5)));
    try std.testing.expectEqual(0, game.fade(game.hemisphere.ring(game.rings, 5)));
    try std.testing.expectEqual(0, game.fade(game.hemisphereVertices() - 1));
    // The fuller style's fade across the game's last band, ring by ring.
    const fuller: Shape = .of(.fuller);
    try std.testing.expectEqual(1, fuller.fade(fuller.hemisphere.ring(fuller.rings - 3, 0)));
    try std.testing.expectApproxEqAbs(2.0 / 3.0, fuller.fade(fuller.hemisphere.ring(fuller.rings - 2, 0)), 1e-6);
    try std.testing.expectApproxEqAbs(1.0 / 3.0, fuller.fade(fuller.hemisphere.ring(fuller.rings - 1, 0)), 1e-6);
    try std.testing.expectEqual(0, fuller.fade(fuller.hemisphere.ring(fuller.rings, 0)));
}

test brightness {
    try std.testing.expectEqual(0, brightness(0));
    try std.testing.expectApproxEqAbs(0.5, brightness(flared / 2), 1e-6);
    try std.testing.expectEqual(1, brightness(0.2));
    try std.testing.expectApproxEqAbs(0.5, brightness(0.4), 1e-5);
    try std.testing.expectApproxEqAbs(0, brightness(faded), 1e-6);
}

test Uber {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const srmesh = @import("../../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    stage.explosions.debris = explode.testing.debris(&mesh);
    var built: shockwave.testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var watching: @import("../camera.zig").Camera = .{};
    watching.place.position = .{ 0, 0, -50000 };
    var world = stage.world();
    world.shockwaves = &built.waves;
    world.camera = &watching;
    const all = world.objects;
    const ctx: aigeneric.Context = .{ .world = world, .clock = world.clock };
    const uber = stage.explosions.uber;

    // The player's ship, which it spares; a ship near; one out of reach; and a gate.
    const player = try stage.mission.add(.predator, @splat(0));
    const near = try stage.mission.add(.sabre, .{ 0, 0, 30000 });
    const far = try stage.mission.add(.sabre, .{ 0, 0, 6000 });
    const gate = try stage.mission.add(.proto_gate, .{ 0, 0, 1000 });
    _ = player;
    for ([_]u16{ near, far, gate }) |index| _ = try aigeneric.push(ctx, index, .do_nothing, .none);
    const size: f32 = 1000;
    all.slots[far].drawn.position = .{ 0, 0, size * reach + 1 };
    all.slots[near].drawn.position = .{ 0, 0, 3000 };
    all.slots[near].object.root.position = gameobj.vec3(.{ 0, 0, 3000 });
    stage.mission.clock.frame_start = 1000;
    uber.start(world, 0, .{ .position = @splat(0) }, size, 1000, .original);
    const blast = &uber.blast.?;
    try std.testing.expectEqual(1, blast.caught_count);
    try std.testing.expectEqual(near, blast.caught[0].index);
    // Its halves start dark and faint, their rims clear; the rings spread.
    const rim = Shape.of(.original).hemisphere.ring(game_rings, 0);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, half_alpha }, blast.half_colours[0]);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, blast.half_colours[rim]);
    try std.testing.expectEqual(.uber, built.waves.waves[0].?.kind);
    try std.testing.expectEqual(size * waves[1].size, built.waves.waves[1].?.size);

    // A fifth of the way through, the halves are grown and bright, the rims still clear, and the
    // ball is yet to show.
    stage.mission.clock.frame_start = 1200;
    uber.frame(world);
    try std.testing.expectEqual(size * half_scale, blast.halves[1].scale);
    try std.testing.expectEqual([4]f32{ 1, 1, 1, half_alpha }, blast.half_colours[rim - 1]);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, blast.half_colours[rim]);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try uber.draw(gpa, &scene);
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(0, scene.lights.items.len);

    // Near the end, the ball has spread past the near ship: knocked, spinning, alight and doing
    // nothing; and burning bits fly at the camera.
    stage.mission.clock.frame_start = 1900;
    uber.frame(world);
    try std.testing.expect(explode.testing.flying(&stage.explosions) >= bits_least);
    try std.testing.expect(blast.caught[0].reached);
    const struck = &all.slots[near].object;
    try std.testing.expectEqual(.do_nothing, aigeneric.current(all, near).?.order);
    try std.testing.expect(struck.knocks > 0);
    try std.testing.expect(stage.explosions.fireballs[0] != null);
    try std.testing.expect(world.shake.* > 0);

    // At its end the ship it reached is destroyed, and the blast is gone.
    stage.mission.clock.frame_start = 2001;
    uber.frame(world);
    try std.testing.expectEqual(null, uber.blast);
    try std.testing.expectEqual(.explode, aigeneric.current(all, near).?.order);
    try std.testing.expectEqual(.do_nothing, aigeneric.current(all, far).?.order);
}

test "the fuller style" {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var watching: @import("../camera.zig").Camera = .{};
    watching.place.position = .{ 0, 0, -50000 };
    var world = stage.world();
    world.camera = &watching;
    const uber = stage.explosions.uber;
    stage.mission.clock.frame_start = 1000;
    uber.start(world, 0, .{ .position = @splat(0) }, 1000, 1000, .fuller);
    const blast = &uber.blast.?;

    // It draws its numbers afresh once for each simulation step: none within a step, two for two.
    try std.testing.expectEqual(0, blast.rounds(1003));
    try std.testing.expectEqual(1, blast.rounds(1004));
    try std.testing.expectEqual(2, blast.rounds(1013));
    try std.testing.expectEqual(0, blast.rounds(1015));

    // Its light shines as bright as the halves while they show.
    stage.mission.clock.frame_start = 1200;
    uber.frame(world);
    try std.testing.expectEqual(light_intensity, blast.light.intensity);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try uber.draw(gpa, &scene);
    try std.testing.expectEqual(1, scene.lights.items.len);

    // The ball flickers the first frame it shows, even between steps.
    stage.mission.clock.frame_start = 1401;
    uber.frame(world);
    try std.testing.expect(blast.flickered);
}
