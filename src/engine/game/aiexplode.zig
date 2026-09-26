//! Order 11, Explode: what a destroyed object does until it is gone. `object_destroyed`
//! ([`ai.zig`](ai.zig)) gives it, and the object runs nothing else from then on. **Unknown:** its
//! source file, which no assertion names: the code lies between `aidock.cpp`'s and
//! `aifight.cpp`'s, so this module is named for the order, as theirs are for theirs.
//!
//! `order_explode_init` (`0x00408610`) picks a mode by what the object is, and each mode has an
//! `init` and an `update` in the table at `0x004E1798`. A ship's (`0x004086F0`, `0x00408A60`)
//! picks one of three styles of going, each with its own `init` and `update`
//! (`0x004E1740`, `0x004E174C`), and ends in a blast ([`explode.zig`](explode.zig)), after which
//! the ship is retired (`create.retire`).
//!
//! The styles leave fireballs, burning bits and a torpedo's shockwave behind
//! ([`explode.zig`](explode.zig), [`shockwave.zig`](shockwave.zig)).
//!
//! A ship that lists components loses its hull, or the one component the order is aimed at, to
//! the component losses (`objects.loseComponents`). An asteroid goes up in a fireball, a large one
//! leaving three smaller in its place, and the limpet car leaves its pod.
//!
//! A ship's end credits the player with the kill where the player's ship struck it last
//! (`killCredit`), and posts its Destroyed event (`events.destroyed`).
//!
//! Order 43, Huuuuuuuge Explosion, lies with Explode (`huge`): it sets the Uber Explode off where
//! the object stands ([`explode/uber.zig`](explode/uber.zig)).
//!
//! **Not ported:** the pilots' records a ship's end keeps, its pilot taken off the wing's list
//! (`0x0058A958`) and marked lost (`0x005047D0`), which are the campaign's
//! ([#301](https://github.com/vdmkenny/openreliant/issues/301)).

const std = @import("std");
const assert = std.debug.assert;

const dte = @import("../../formats/dte.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const Vec3 = @import("../../formats/shp.zig").Vec3;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const camera = @import("camera.zig");
const create = @import("create.zig");
const deathmatch = @import("deathmatch.zig");
const events = @import("mission/events.zig");
const explode = @import("explode.zig");
const gameobj = @import("gameobj.zig");
const objects = @import("objects.zig");
const shockwave = @import("shockwave.zig");
const GameObject = gameobj.GameObject;
const libcmt = @import("../libcmt.zig");
const main = @import("main.zig");
const xtrabits = @import("xtrabits.zig");

/// What the order does, by what the object is.
pub const Mode = enum(i16) {
    /// A ship that lists no components, and the troop car.
    ship = 0,
    /// A ship that lists components, going as a whole.
    hull = 1,
    /// One of a ship's components, which the order is aimed at.
    component = 2,
    asteroid = 3,
    limpet_car = 4,

    /// `order_explode_init`'s choice.
    pub fn of(object: *const GameObject, target: aigeneric.Target) Mode {
        return switch (object.type) {
            .troop_car => .ship,
            .limpet_car => .limpet_car,
            else => if (object.type.isAsteroid())
                .asteroid
            else if (!object.flags.components)
                .ship
            else if (target.component != aigeneric.Target.whole)
                .component
            else
                .hull,
        };
    }
};

/// How a ship goes.
pub const Style = enum(i16) {
    /// It drifts on unpowered, spinning ever slower, for two to four seconds, then blows up.
    spin_out = 0,
    /// It drifts on unpowered, no longer turning, and bursts at once.
    burst = 1,
    /// It stops dead and blows up at once.
    halt = 2,
};

/// What the order keeps in the object's order state. `init` writes the mode and the style before
/// anything reads them.
pub const State = extern struct {
    mode: Mode,
    _unknown_02: u16,
    /// The tick past which it blows up.
    end: i32,
    /// A ship's.
    style: Style,
    _unknown_0a: u16,
    /// A spinning ship's turn a step, as angles, at the full length of its spin.
    spin: Vec3,
    /// The bits a spinning ship has left to trail behind it.
    trail: i16,
    _unknown_1a: [0x90 - 0x1A]u8,

    comptime {
        assert(@offsetOf(State, "end") == 0x4);
        assert(@offsetOf(State, "style") == 0x8);
        assert(@offsetOf(State, "spin") == 0xC);
        assert(@offsetOf(State, "trail") == 0x18);
        assert(@sizeOf(State) == 0x90);
    }
};

/// What `object_destroyed` leaves in the order's data.
pub const Data = extern struct {
    /// Whether a ship may spin out: set by a blow to its armour, clear once its pilot has
    /// ejected.
    may_spin: bool,

    comptime {
        assert(@offsetOf(Data, "may_spin") == 0x0);
        assert(@sizeOf(Data) == 1);
    }
};

/// `order_explode_init` (`0x00408610`).
pub fn init(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.explode;
    state.mode = .of(&slot.object, slot.orders[0].target);
    switch (state.mode) {
        .ship => shipInit(ctx, index),
        .hull => hullInit(ctx, index),
        .component => componentInit(ctx, index),
        .asteroid => asteroidInit(ctx, index),
        .limpet_car => limpetCarInit(ctx, index),
    }
}

/// `order_explode` (`0x004086A0`).
pub fn update(ctx: Context, index: u16) void {
    switch (ctx.world.objects.slots[index].state.explode.mode) {
        .ship => shipUpdate(ctx, index),
        .hull => hullUpdate(ctx, index),
        // `explode_component` (`0x00409260`): the component is lost, and the order is done.
        .component => _ = aigeneric.pop(ctx, index),
        .asteroid => asteroidUpdate(ctx, index),
        .limpet_car => limpetCarUpdate(ctx, index),
    }
}

/// How far the Huuuuuuuge Explosion reaches, and for how long, in ticks (`0x004086C8`,
/// `0x004086C3`).
const huge_size: f32 = 50000;
const huge_duration = 1500;

/// `order_huuuuuuuge_explosion` (`0x004086C0`), the update of order 43, whose init does nothing:
/// sets the Uber Explode off where the object stands, the object its owner (`explode.uberExplode`),
/// and pops.
pub fn huge(ctx: Context, index: u16) void {
    explode.uberExplode(ctx.world, index, ctx.world.objects.slots[index].drawn, huge_size, huge_duration);
    _ = aigeneric.pop(ctx, index);
}

// --- A ship that lists components --------------------------------------------------------------

/// `explode_hull_init` (`0x00409170`): each part of the hull hanging from the model's root, but a
/// part of a damaged model, runs out of armour, for the component losses to take its assembly
/// away (`objects.loseComponents`).
fn hullInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const model = if (slot.model) |*live| live else return;
    for (model.parts) |*part| {
        if (part.parent != null or part.flags.damaged or part.class != .hull) continue;
        part.armor = spent_armor;
        model.destroyed = true;
    }
}

/// `explode_hull` (`0x004091E0`): a disabled ship ends as its hull holding it together does
/// (`ai.hullLost`); any other's order is done, the hull left to the component losses.
fn hullUpdate(ctx: Context, index: u16) void {
    if (ctx.world.objects.slots[index].object.flags.disabled) return ai.hullLost(ctx, index);
    _ = aigeneric.pop(ctx, index);
}

/// `explode_component_init` (`0x00409200`): the component the order is aimed at, where it is
/// shown, runs out of armour, and the model holding it takes it away (`objects.loseComponents`).
fn componentInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const model = if (slot.model) |*live| live else return;
    const part = slot.component(slot.orders[0].target.part() orelse return) orelse return;
    if (part.hidden) return;
    part.armor = spent_armor;
    if (model.holding(part)) |holder| holder.destroyed = true;
}

/// The armour a part is left with to be lost.
const spent_armor: f32 = -1;

// --- An asteroid -------------------------------------------------------------------------------

/// `explode_asteroid_init` (`0x00409270`): it goes up the frame after, and moves no more.
fn asteroidInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.state.explode.end = ctx.clock.frame_start;
    slot.object.flags.unpowered = true;
    slot.object.flags.frozen = true;
}

/// A rock's fireball, times its radius, and how large a rock must be, as its `visibility`, for
/// three smaller to take its place (`0x004DC4E0`, `0x004DC4D8`), each so much the size of the
/// last (`0x004DC4DC`), standing its radius times `fragment_reach` from where it was, a turn of
/// `fragment_turn` apart about the X axis (`0x004DC3D8`, `0x004DC4D4`).
///
/// **Improvement:** the game turns them by 1.88496, three fifths of a half turn rounded;
/// OpenReliant computes it.
const rock_fireball: f32 = 1.5;
const least_breaking: f32 = 0.16;
const fragment_share: f32 = 0.4;
const fragments = 3;
const fragment_reach: f32 = 3;
const fragment_turn: f32 = 0.6 * std.math.pi;
/// The fragments are asteroids from the third of the seven, one of the four from it.
const fragment_first = 2;
const fragment_kinds = 4;

/// `explode_asteroid` (`0x004092A0`): once its moment has passed, a fireball as wide as
/// `rock_fireball` of its radius, lighting what is round it, and it is retired. Where it is large
/// enough, `fragments` smaller asteroids, `fragment_share` of its size, take its place, each turned
/// a further `fragment_turn` about the X axis and standing `fragment_reach` of its own radius along
/// its nose from where the rock was, still and colliding with nothing.
///
/// Not ported: the count of asteroids made, which the game keeps for its log alone.
fn asteroidUpdate(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    if (!(slot.state.explode.end < ctx.clock.frame_start)) return;
    const at = slot.drawn.position;
    const size = slot.object.visibility * fragment_share;
    explode.fireballAt(world, at, .{ .size = slot.object.radius * rock_fireball, .light = true });
    create.retire(ctx, index);
    if (size < least_breaking) return;
    const spawn = world.spawn orelse return;
    var turn_count: usize = fragments;
    while (turn_count > 0) : (turn_count -= 1) {
        const kind = gameobj.Type.asteroid(fragment_first + @as(usize, world.random.rand() % fragment_kinds));
        const fragment = create.createObject(all, spawn.tables, spawn.types, null, kind, 0, @splat(0), world.random) catch return;
        const piece = &all.slots[fragment];
        const turn = math.fromAngles(@as(f32, @floatFromInt(turn_count)) * fragment_turn, 0, 0);
        objects.setPosition(&piece.object, &piece.drawn, at + math.transform(turn, .{ 0, 0, piece.object.radius * fragment_reach }));
        objects.setOrientation(&piece.object, &piece.drawn, turn);
        piece.object.throttle = 0;
        piece.object.flags.no_collisions = true;
        piece.shrink(size);
    }
}

// --- The limpet car ----------------------------------------------------------------------------

/// The model of the object in `slot`, where its first part still shows.
fn shownModel(slot: *create.Slot) ?*objects.Model {
    const model = if (slot.model) |*live| live else return null;
    if (model.parts.len == 0 or model.parts[0].hidden) return null;
    return model;
}

/// The bits the limpet car's trail has left.
const limpet_trail = 50;

/// `explode_limpet_car_init` (`0x004094D0`): the car's Destroyed event is posted
/// (`events.destroyed`); the car stops dead, unpowered, with a random turn (`randomSpin`) and a
/// trail to leave, which its update never reaches, and goes up in a fireball as wide as its
/// radius.
fn limpetCarInit(ctx: Context, index: u16) void {
    const world = ctx.world;
    events.destroyed(world, index, dte.Trigger.whole_object);
    const slot = &world.objects.slots[index];
    const object = &slot.object;
    const state = &slot.state.explode;
    state.trail = limpet_trail;
    state.end = 0;
    stop(object);
    object.flags.unpowered = true;
    state.spin = randomSpin(world.random);
    explode.fireballAt(world, slot.drawn.position, .{ .size = object.radius });
}

/// `explode_limpet_car` (`0x004095F0`): where the car's first part still shows, it is hidden, the
/// car blows up (`explode.blast`), and a limpet pod takes its slot, where that part was going;
/// otherwise the car blows up and is retired.
///
/// Not ported: the sounds `0x004B9C70` ends and plays.
fn limpetCarUpdate(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const model = shownModel(slot) orelse {
        explode.blast(world, index);
        return create.retire(ctx, index);
    };
    model.parts[0].hidden = true;
    const place = model.partPlace(0, .next).within(slot.object.placeAt(.next));
    explode.blast(world, index);
    all.resetSlot(index, world.random);
    const spawn = world.spawn orelse return;
    const pod = create.createObject(all, spawn.tables, spawn.types, index, .limpet_pod, 0, @splat(0), world.random) catch return;
    const replaced = &all.slots[pod];
    objects.setPosition(&replaced.object, &replaced.drawn, place.position);
    objects.setOrientation(&replaced.object, &replaced.drawn, place.orientation);
}

/// A ship moving slower than this as it is destroyed is watched from behind, pulling away; one
/// faster from where the camera was (`0x004DC440`).
const slow: f32 = 100;

/// `0x004086F0`: a ship's end begins. Close to the camera it is heard at once. It takes a style of
/// going, the torpedoes always stopping dead; the player's credit for the kill is settled
/// (`killCredit`), and the ship's Destroyed event posted (`events.destroyed`). The player's has the
/// camera watch it, from a view by the style and how fast it was flying, and the mission end with
/// it. At the end of the player's ejection (`main.Showing.ejection`) the player's pod stops dead
/// instead, as the Sabre's view watches it, and its end ends nothing.
fn shipInit(ctx: Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const object = &slot.object;
    const at = slot.drawn.position;
    if (explode.soundClass(world, at) == .guaranteed) explode.sound(world, at, .guaranteed);

    const state = &slot.state.explode;
    const players = index == world.objects.player;
    const cutaway = world.player.showing != .everything;
    state.style = switch (object.type) {
        .torpedo, .russian_torpedo => .halt,
        else => if (players and cutaway) .halt else @enumFromInt(xtrabits.objectRandom15(object) % std.enums.values(Style).len),
    };
    killCredit(world, index);
    events.destroyed(world, index, dte.Trigger.whole_object);

    if (players and !cutaway) {
        const view: camera.View = switch (state.style) {
            .spin_out => if (movingSlowly(object, slot.flight, world.view)) .pull_back else .watch,
            .burst => .watch_marker,
            .halt => .pull_back,
        };
        if (world.camera) |watching| _ = watching.setView(view, index, true, true, ctx.clock.viewTime());
        world.player.ending = .destroyed;
    }

    switch (state.style) {
        .spin_out => spinOutInit(ctx, index),
        .burst => burstInit(object, state),
        .halt => haltInit(ctx, index),
    }
}

/// `explode_kill_credit` (`0x00408500`), as a ship's end begins: a kill for the player
/// (`deathmatch.addKills`) where the player's ship struck it last and it is hostile, and a fighter
/// by its type's class, a Kamov, a Kurgan or a Gurevich.
///
/// Not ported: a wingman's remark on the kill (`radio_kill_remark`) and the line the loss of a
/// ship in the player's wing draws (`radio_ship_lost`), which wait for the radio
/// ([#48](https://github.com/vdmkenny/openreliant/issues/48)); the other players' kills in a
/// multiplayer game; and `0x00529C6C`, which a mission's start sets and two of the radio's states
/// set and clear, and without which it does nothing.
pub fn killCredit(world: gameobj.World, index: u16) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (object.last_attacker.index() != all.player or object.side != .hostile) return;
    const fighter = if (slot.combat) |combat| combat.class == .fighter else false;
    const credited = fighter or switch (object.type) {
        .kamov, .kurgan, .gurevich => true,
        else => false,
    };
    if (credited) deathmatch.addKills(world.player, all, all.player, 1);
}

fn movingSlowly(object: *const GameObject, flight: ?*const create.FlightModel, view: camera.View) bool {
    const model = flight orelse return true;
    return ai.cruiseSpeed(object, model, view) * object.throttle < slow;
}

/// `0x00408A60`: until its end the ship goes on in its style; then it blows up, a burst in its own
/// way and a torpedo not at all, having gone up as it stopped, and is retired.
fn shipUpdate(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.explode;
    if (ctx.clock.frame_start <= state.end) {
        switch (state.style) {
            .spin_out, .halt => spin(ctx.world, slot),
            .burst => {},
        }
        return;
    }
    switch (state.style) {
        .burst => explode.burst(ctx.world, index),
        else => switch (slot.object.type) {
            .torpedo, .russian_torpedo => {},
            else => explode.blast(ctx.world, index),
        },
    }
    create.retire(ctx, index);
}

/// The trail a spinning ship leaves: a small bit of debris a frame while it has less than
/// `trail_ticks` a bit left, from within half of `trail_spread` of it on each axis, thrown out
/// backwards (`0x004DC4A8`).
const trail_bits = 50;
const trail_ticks = 10;
const trail_spread: f32 = 500;
const trail_throw: explode.Bit.Throw = .{ .size = 0.1, .speed = 1 };

/// How long a spin-out lasts: this, and up to as long again (`0x004DC4C4`).
const spin_ticks = 200;

/// How fast a spin's turn shrinks to nothing as the end comes, a tick (`0x004DC4D0`).
const spin_fade: f32 = 0.005;

/// How far a spinning ship's turn a step ranges about its first two axes and about its third, half
/// of it either way (`0x004DC474`, `0x004DC4C0`); the limpet car's too.
const spin_range: Vector = .{ 0.05, 0.05, 0.3 };

/// `0x00408BC0`: a spinning ship drifts on unpowered for two to four seconds; a torpedo, or a ship
/// told not to spin, stops dead and blows up at once.
fn spinOutInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    const state = &slot.state.explode;
    state.trail = trail_bits;
    const torpedo = if (slot.combat) |combat| combat.class == .torpedo else false;
    if (torpedo or !slot.orders[0].data.destroyed.may_spin) {
        stop(object);
        state.end = 0;
    } else {
        state.end = ctx.clock.frame_start + @as(i32, @intFromFloat(ctx.world.random.fraction() * spin_ticks)) + spin_ticks;
    }
    object.flags.unpowered = true;
    state.spin = randomSpin(ctx.world.random);
    goesUp(ctx.world, slot);
}

/// A bang of the ship's size where it is, which a spinning or halting ship sets off as it goes.
fn goesUp(world: gameobj.World, slot: *const create.Slot) void {
    explode.fireballAt(world, slot.drawn.position, .{ .size = slot.object.radius });
}

/// `0x004090F0`: a bursting ship drifts on unpowered, no longer turning.
fn burstInit(object: *GameObject, state: *State) void {
    state.trail = trail_bits;
    state.end = 0;
    object.flags.unpowered = true;
    object.pitch_rate = 0;
    object.pitch_input = 0;
    object.roll_rate = 0;
    object.roll_input = 0;
    object.yaw_rate = 0;
    object.yaw_input = 0;
}

/// `0x00408D20`: a halting ship stops dead and blows up at once; a torpedo sets off its chain of
/// fireballs and a shockwave that harms the player it passes.
fn haltInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.explode;
    state.trail = trail_bits;
    stop(&slot.object);
    state.end = 0;
    slot.object.flags.unpowered = true;
    state.spin = randomSpin(ctx.world.random);
    goesUp(ctx.world, slot);
    switch (slot.object.type) {
        .torpedo, .russian_torpedo => {
            chain(ctx.world, slot.drawn.position);
            shockwave.setOff(ctx.world, slot.drawn, .{
                .kind = .torpedo,
                .size = torpedo_shockwave_size,
                .life = torpedo_shockwave_life,
                .velocity = gameobj.vector(slot.object.velocity),
                .owner = index,
            });
        },
        else => {},
    }
}

/// A halting torpedo's shockwave, which harms the player it passes: how far it spreads, over how
/// many ticks.
const torpedo_shockwave_size: f32 = 6000;
const torpedo_shockwave_life = 100;

/// A torpedo's chain of lit fireballs, `chain_length` of them `chain_step` ticks apart, each less a
/// share of `chain_lag`, so up to 19 ticks later; within half of `chain_spread` of it on each axis,
/// and `chain_size` and up to `chain_size_range` more across (`0x004DC4B8`, `0x004DC4CC`,
/// `0x004DC44C`, `0x004DC4A8`).
fn chain(world: gameobj.World, at: Vector) void {
    const random = world.random;
    for (0..chain_length) |n| {
        const offset = random.centredVector(@splat(chain_spread));
        const lag: i32 = @intFromFloat(random.fraction() * chain_lag);
        const size = random.fraction() * chain_size_range + chain_size;
        explode.fireballAt(world, offset + at, .{ .size = size, .light = true, .delay = @as(i32, @intCast(n)) * chain_step - lag });
    }
}

const chain_length = 5;
const chain_step = 30;
const chain_lag: f32 = -20;
const chain_spread: f32 = 1500;
const chain_size: f32 = 1000;
const chain_size_range: f32 = 500;

/// Stops the ship dead, as the styles do: no velocity, speed or throttle.
fn stop(object: *GameObject) void {
    object.velocity = .{ .x = 0, .y = 0, .z = 0 };
    object.speed = 0;
    object.throttle = 0;
}

/// A turn a step either way about each axis, within `spin_range`.
fn randomSpin(random: *libcmt.Rand) Vec3 {
    return gameobj.vec3(random.centredVector(spin_range));
}

/// `0x00408F70`, a spinning or halting ship's update: it leaves its trail, a ship with flag 24
/// set only every other bit, and turns by its spin, less and less as its end comes.
fn spin(world: gameobj.World, slot: *create.Slot) void {
    const state = &slot.state.explode;
    const left = state.end - world.clock.frame_start;
    if (left < @as(i32, state.trail) * trail_ticks) {
        const at = world.random.centredVector(@splat(trail_spread)) + slot.drawn.position;
        const behind = -math.forward(slot.drawn.orientation);
        if (!slot.object.flags._unknown_24 or @rem(state.trail, 2) == 0) explode.throwBit(world, at, behind, trail_throw);
        state.trail -= 1;
    }
    const share = @as(f32, @floatFromInt(left)) * spin_fade;
    slot.object.rotation = math.fromAngles(state.spin.x * share, state.spin.y * share, state.spin.z * share);
}

test Mode {
    var object = gameobj.testing.object();
    const whole = aigeneric.Target.none;
    try std.testing.expectEqual(Mode.ship, Mode.of(&object, whole));
    object.flags.components = true;
    try std.testing.expectEqual(Mode.hull, Mode.of(&object, whole));
    try std.testing.expectEqual(Mode.component, Mode.of(&object, .at(3, 2)));
    object.type = .troop_car;
    try std.testing.expectEqual(Mode.ship, Mode.of(&object, whole));
    object.type = @enumFromInt(0x7B);
    try std.testing.expectEqual(Mode.asteroid, Mode.of(&object, whole));
    object.type = .limpet_car;
    try std.testing.expectEqual(Mode.limpet_car, Mode.of(&object, whole));
}

test "a ship's end" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var watching: camera.Camera = .{};
    var ctx = mission.orders();
    ctx.world.camera = &watching;
    const player = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.sabre, .{ 0, 0, 1000 });
    const slots = &mission.objects.slots;

    // A ship takes a style, and is gone once its end has passed.
    ai.objectDestroyed(ctx, ship, true, false);
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(Mode.ship, slots[ship].state.explode.mode);
    try std.testing.expect(slots[ship].object.flags.unpowered);
    mission.clock.frame_start = 2 * spin_ticks;
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(gameobj.Type.stand_in, slots[ship].object.type);

    // The player's has the camera watch it, and ends the mission.
    ai.objectDestroyed(ctx, player, true, true);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expect(watching.view == .pull_back or watching.view == .watch or watching.view == .watch_marker);
    try std.testing.expectEqual(.destroyed, mission.player.ending);
}

test "the pod shot down in the ejection's cutaway bursts at once" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var watching: camera.Camera = .{};
    var ctx = mission.orders();
    ctx.world.camera = &watching;
    const pod = try mission.add(.predator, @splat(0));
    _ = watching.setView(.pod_shot, pod, true, true, 0);
    mission.player.showing = .ejection;
    mission.player.ending = .destroyed;
    mission.slot(pod).object.flags.ejected = true;

    // It halts, and the camera and the mission's ending stay as the cutaway set them.
    ai.objectDestroyed(ctx, pod, true, true);
    aigeneric.objectOrders(ctx, pod);
    try std.testing.expectEqual(Style.halt, mission.slot(pod).state.explode.style);
    try std.testing.expectEqual(.pod_shot, watching.view);
    try std.testing.expectEqual(.destroyed, mission.player.ending);
}

test "an asteroid goes up, a large one leaving smaller ones" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var ctx = mission.orders();
    ctx.world.spawn = .{ .tables = &mission.tables, .types = create.testing.no_models };
    const all = mission.objects;
    _ = try mission.add(.predator, @splat(0));
    const rock = try mission.add(.asteroid(0), .{ 0, 0, 5000 });
    mission.clock.frame_start = 10;

    // It stops, and goes the frame after.
    ai.objectDestroyed(ctx, rock, true, false);
    aigeneric.objectOrders(ctx, rock);
    try std.testing.expectEqual(Mode.asteroid, all.slots[rock].state.explode.mode);
    try std.testing.expect(all.slots[rock].object.flags.frozen);
    mission.clock.frame_start += 1;
    aigeneric.objectOrders(ctx, rock);
    try std.testing.expectEqual(gameobj.Type.stand_in, all.slots[rock].object.type);

    // Three fragments of the next asteroids take its place, smaller, colliding with nothing.
    try std.testing.expectEqual(rock + 1 + fragments, all.count);
    const fragment = &all.slots[rock + 1];
    try std.testing.expect(fragment.object.type.isAsteroid());
    try std.testing.expectEqual(fragment_share, fragment.object.visibility);
    try std.testing.expect(fragment.object.flags.no_collisions);

    // A fragment breaks once more; the smallest leave nothing.
    const smaller = rock + 1;
    ai.objectDestroyed(ctx, smaller, true, false);
    aigeneric.objectOrders(ctx, smaller);
    mission.clock.frame_start += 1;
    aigeneric.objectOrders(ctx, smaller);
    const smallest: u16 = @intCast(all.count - 1);
    try std.testing.expectApproxEqAbs(fragment_share * fragment_share, all.slots[smallest].object.visibility, 1e-6);
    const count = all.count;
    ai.objectDestroyed(ctx, smallest, true, false);
    aigeneric.objectOrders(ctx, smallest);
    mission.clock.frame_start += 1;
    aigeneric.objectOrders(ctx, smallest);
    try std.testing.expectEqual(count, all.count);
}

test "a ship listing components loses its hull, or a component" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const ctx = mission.orders();
    var hull: create.testing.Model = undefined;
    try hull.init(gpa);
    defer hull.deinit(gpa);
    hull.source.header.flags.components = true;
    hull.data[0].part.flags.component = true;
    hull.data[0].part.class = .hull;
    const all = mission.objects;
    _ = try mission.add(.predator, @splat(0));
    const ship = try create.createObject(all, &mission.tables, hull.types(), null, .reaper, 0, .{ 0, 0, 1000 }, &mission.random);
    try std.testing.expect(all.slots[ship].object.flags.components);
    const model = &all.slots[ship].model.?;

    // As a whole, its hull runs out of armour for the losses to take, and the order is done.
    _ = try aigeneric.push(ctx, ship, .explode, .none);
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(spent_armor, model.parts[0].armor);
    try std.testing.expect(model.destroyed);
    try std.testing.expectEqual(0, all.slots[ship].object.order_count);

    // Aimed at a component, that one does, and again the order is done.
    model.destroyed = false;
    model.parts[0].armor = 100;
    _ = try aigeneric.push(ctx, ship, .explode, .at(ship, 0));
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(spent_armor, model.parts[0].armor);
    try std.testing.expect(model.destroyed);
    try std.testing.expectEqual(0, all.slots[ship].object.order_count);

    // A disabled ship ends as its hull holding it together does.
    all.slots[ship].object.flags.disabled = true;
    _ = try aigeneric.push(ctx, ship, .explode, .none);
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expect(all.slots[ship].object.flags.exploding);
}

test "the limpet car leaves its pod" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var ctx = mission.orders();
    var car: create.testing.Model = undefined;
    try car.init(gpa);
    defer car.deinit(gpa);
    ctx.world.spawn = .{ .tables = &mission.tables, .types = car.types() };
    const all = mission.objects;
    _ = try mission.add(.predator, @splat(0));
    const index = try create.createObject(all, &mission.tables, car.types(), null, .limpet_car, 0, .{ 0, 0, 2000 }, &mission.random);

    // It stops dead and, the same step as its order starts, blows up, and a limpet pod takes its
    // slot where it was.
    ai.objectDestroyed(ctx, index, true, false);
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(gameobj.Type.limpet_pod, all.slots[index].object.type);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 2000 }), all.slots[index].drawn.position);
}

test huge {
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const ctx: Context = .{ .world = stage.world(), .clock = &stage.mission.clock };
    _ = try stage.mission.add(.predator, @splat(0));
    const ship = try stage.mission.add(.sabre, .{ 0, 0, 1000 });
    _ = try aigeneric.push(ctx, ship, .do_nothing, .none);
    _ = try aigeneric.push(ctx, ship, .huuuuuuuge_explosion, .none);

    // It sets the Uber Explode off where the ship stands, the ship its owner, and gives way to the
    // order below.
    aigeneric.objectOrders(ctx, ship);
    const blast = &stage.explosions.uber.blast.?;
    try std.testing.expectEqual(ship, blast.owner);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 1000 }), blast.place.position);
    try std.testing.expectEqual(huge_size, blast.size);
    try std.testing.expectEqual(.do_nothing, aigeneric.current(stage.mission.objects, ship).?.order);
}

test spin {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ship = try mission.add(.sabre, @splat(0));
    const slot = &mission.objects.slots[ship];
    const state = &slot.state.explode;
    const world = mission.orders().world;
    state.spin = .{ .x = 0, .y = 0, .z = 0.1 };
    state.end = 200;
    state.trail = 2;

    // A spin turns the ship less and less as its end comes, and leaves its trail once it has
    // less than the trail's time left.
    spin(world, slot);
    const early = math.angles(slot.object.rotation);
    try std.testing.expectEqual(2, state.trail);
    mission.clock.frame_start = 185;
    spin(world, slot);
    spin(world, slot);
    const late = math.angles(slot.object.rotation);
    try std.testing.expect(@abs(late[2]) < @abs(early[2]));
    try std.testing.expectEqual(1, state.trail);
}

test "a halting torpedo's shockwave" {
    const gpa = std.testing.allocator;
    var built: shockwave.testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var ctx = mission.orders();
    ctx.world.shockwaves = &built.waves;
    _ = try mission.add(.predator, @splat(0));
    const torpedo = try mission.add(.torpedo, .{ 0, 0, 1000 });

    // It halts, and sets off a shockwave that harms the player it passes.
    haltInit(ctx, torpedo);
    const wave = built.waves.waves[0].?;
    try std.testing.expectEqual(shockwave.Kind.torpedo, wave.kind);
    try std.testing.expectEqual(torpedo_shockwave_size, wave.size);
    try std.testing.expectEqual(torpedo, wave.owner);
}

test randomSpin {
    var random: libcmt.Rand = .{};
    for (0..100) |_| {
        const turn = randomSpin(&random);
        const most = spin_range / @as(Vector, @splat(2));
        try std.testing.expect(@abs(turn.x) <= most[0] and @abs(turn.y) <= most[1] and @abs(turn.z) <= most[2]);
    }
}

test killCredit {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const world = mission.world();
    const credit = struct {
        fn of(m: *gameobj.testing.Mission, w: gameobj.World, ship_type: gameobj.Type, by: u16) !i32 {
            const index = try m.add(ship_type, .{ 0, 0, 1000 });
            m.slot(index).object.last_attacker = .of(by);
            const before = m.player.kills.count;
            killCredit(w, index);
            return m.player.kills.count - before;
        }
    }.of;
    // A hostile fighter the player's ship struck last is the player's kill.
    try std.testing.expectEqual(1, try credit(&mission, world, .sabre, player));
    // So are a Kamov and a Kurgan, which are not fighters by their class.
    try std.testing.expectEqual(1, try credit(&mission, world, .kamov, player));
    try std.testing.expectEqual(1, try credit(&mission, world, .kurgan, player));
    // A Kronstadt, of the support class like the Kurgan, is not; nor is a friend, nor another's
    // kill.
    try std.testing.expectEqual(0, try credit(&mission, world, .kronstadt, player));
    try std.testing.expectEqual(0, try credit(&mission, world, .predator, player));
    const other = try mission.add(.predator, .{ 0, 0, 2000 });
    try std.testing.expectEqual(0, try credit(&mission, world, .sabre, other));
    try std.testing.expectEqual(3, mission.player.kills.count);
}
