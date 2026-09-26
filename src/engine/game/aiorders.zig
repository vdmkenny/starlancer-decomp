//! The orders a ship flies by: Mill, Do Nothing, Escort, Fly, Run Away, Find New Target, Slow
//! Rotate, the Random Spins, Match Speed and Disrupted; and the two that launch a missile. [`aigeneric.zig`](aigeneric.zig) runs them, [`ai.zig`](ai.zig) steers for them, and
//! `docs/engine/orders.md` describes what each does.
//!
//! **Unknown:** its source file. The code lies after `aifight.cpp`'s and before `aifuncs.cpp`'s,
//! and no string places it. The orders of the two files around it are their own.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.orders);

const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const erayfx = @import("erayfx.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const Order = @import("ai/orders.zig").Order;
const missiles = @import("missiles.zig");
const objects = @import("objects.zig");
const xtrabits = @import("xtrabits.zig");

/// What Fly keeps in `order_state`: the heading it started with, which it flies along while it has
/// no target to fly to.
pub const FlyState = extern struct {
    _unknown_00: [2]f32,
    heading: shp.Vec3,
    _unknown_14: [0x7C]u8,

    comptime {
        assert(@offsetOf(FlyState, "heading") == 0x8);
        assert(@sizeOf(FlyState) == 0x90);
    }
};

/// How near its target Fly comes before it pops (`0x004DC490` holds its square).
const fly_reach: f32 = 2000;

/// How far along its heading Fly steers at while it has no target.
const fly_ahead: f32 = 20000;

/// How far past the target Run Away puts the point it steers away by.
const run_away_ahead: f32 = 100000;

/// The throttle Run Away flies at, and the ease it steers with (`order_run_away`).
const run_away_throttle: f32 = 0.5;
const run_away_ease: f32 = 0.1;

/// What Fly and Run Away leave of the throttle while the ship is going round something
/// (`0x004DC408`).
const avoided_throttle: f32 = 0.5;

/// How far a Fly order moves an object that has no flight stats, for each unit of speed and each
/// tick of the frame (`0x004DC3D4`).
const drift_per_tick: f32 = 0.25;

/// The turn Slow Rotate yaws at, and what every Random Spin turns at before its own share
/// (`0x004DC420`).
pub const spin_input: f32 = 0.1;

/// The throttle Fly Ship Backwards flies at, which is reverse thrust.
pub const backwards_throttle: f32 = -0.5;

// --- Mill -----------------------------------------------------------------------------------

/// What Mill keeps in `order_state`: the frame's tick it began, and the circle it flies round its
/// target, as an orientation whose X and forward axes the circle turns through.
pub const MillState = extern struct {
    started: i32,
    circle: math.Matrix,
    _unknown_28: [0x90 - 0x28]u8,

    comptime {
        assert(@offsetOf(MillState, "circle") == 0x04);
        assert(@sizeOf(MillState) == 0x90);
    }
};

/// How long Mill flies round its target, in ticks; how far from the target its circle runs
/// (`0x004DC494`); and how far round it the point it steers for comes for each tick at the ship's
/// cruise speed (`0x004DC4F4`).
const mill_ticks = 500;
const mill_radius: f32 = 50000;
const mill_pace: f32 = 5e-6;

/// `order_mill_init` (`0x0040A6F0`): the init of Mill (120). Where the ship can aim at its target,
/// cloaked or not (`ai.targetValid`), the mill begins, round a circle facing from the target's node
/// (`ai.aimedAt`) to where the ship will be next.
pub fn millInit(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = slot.orders[0].target;
    if (!ai.targetValid(all, target, .{ .cloaked = true })) return;
    const state = &slot.state.mill;
    state.started = ctx.clock.frame_start;
    state.circle = math.lookAt(slot.object.nextPosition() - ai.aimedAt(all, target).position);
}

/// `order_mill` (`0x0040A750`): the update of Mill (120). It pops once the ship can no longer aim
/// at its target or `mill_ticks` have passed. Otherwise the ship flies at full throttle, going round
/// what is in its way, for a point on its circle round the target's node, `mill_radius` from it,
/// which comes round from the ship's side by `mill_pace` of the cruise speed a tick.
pub fn mill(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = slot.orders[0].target;
    const state = &slot.state.mill;
    const now = ctx.clock.frame_start;
    if (!ai.targetValid(all, target, .{ .cloaked = true }) or state.started + mill_ticks < now) {
        _ = aigeneric.pop(ctx, index);
        return;
    }
    const flight = slot.flight orelse return;
    const round: f32 = ai.cruiseSpeed(&slot.object, flight, ctx.world.view) * @as(f32, @floatFromInt(now - state.started)) * mill_pace;
    const across = math.xAxis(state.circle) * @as(Vector, @splat(@sin(round) * mill_radius));
    const along = math.forward(state.circle) * @as(Vector, @splat(@cos(round) * mill_radius));
    _ = ai.steer(ctx.world, index, across + along + ai.aimedAt(all, target).position, ai.full_limit, ai.no_ease, .{ .avoid_near = true, .avoid_ahead = true });
    slot.object.throttle = ai.full_throttle;
}

/// `order_do_nothing` (`0x0040A880`): the update of Do Nothing (0), which lets the ship coast.
pub fn doNothing(ctx: Context, index: u16) void {
    ctx.world.objects.slots[index].object.letGo();
}

// --- Escort ---------------------------------------------------------------------------------

/// What Escort keeps in `order_state`: how many ships of its target's group its start has still to
/// pass before the one it escorts, and that ship's slot, -1 for none.
pub const EscortState = extern struct {
    place: i32,
    escorted: i32,
    _unknown_08: [0x90 - 0x08]u8,

    comptime {
        assert(@offsetOf(EscortState, "escorted") == 0x04);
        assert(@sizeOf(EscortState) == 0x90);
    }
};

/// How far ahead of the escorted ship the escort steers for (`order_escort`); within how far of it
/// the escort steers gently, and by how much of its turn (`0x004DC504`, as its square); and how much
/// faster than the escorted ship it flies for each unit it lies ahead of the escort along the
/// escort's heading (`0x004DC4B0`).
const escort_lead: f32 = 10000;
const escort_near: f32 = 5000;
const escort_near_limit: f32 = 0.5;
const escort_catch_up: f32 = 0.0001;

/// `order_escort_init` (`0x0040AA80`): the init of Escort (9). The ship escorts the ship its order
/// names; or for a flight group or a squad, the ship at the order's place among the group's ships
/// (`aigeneric.Entry.sequence`), counting round them again past the last (`ai.eachShip`, the walk's
/// visitor at `0x0040AA50`).
///
/// **Fix:** where the group has no ships, the game walks it again for ever; OpenReliant escorts
/// none, which ends the order at its first update.
pub fn escortInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.escort;
    const entry = slot.orders[0];
    if (entry.target.kind == .ship) {
        state.escorted = entry.target.index;
        return;
    }
    state.escorted = -1;
    state.place = entry.sequence;
    while (state.place >= 0) {
        var counting: EscortCount = .{ .state = state };
        _ = ai.eachShip(ctx.world, entry.target, &counting);
        if (!counting.visited) return;
    }
}

/// The visitor of Escort's walk: each ship takes one off the place to go, and the one that takes it
/// below nothing is the one to escort.
const EscortCount = struct {
    state: *EscortState,
    visited: bool = false,

    pub fn visit(count: *EscortCount, ship: aigeneric.Target) bool {
        count.visited = true;
        count.state.place -= 1;
        if (count.state.place >= 0) return false;
        count.state.escorted = ship.index;
        return true;
    }
};

/// `order_escort` (`0x0040AAD0`): the update of Escort (9). Once the escorted ship has gone, a
/// stand-in in its slot, the order pops. Otherwise the ship steers for a point `escort_lead` ahead
/// of it: within `escort_near` of it by `escort_near_limit` of its turn, rolling upright, and farther
/// off at its full turn, going round what is in its way. It flies at the escorted ship's speed, and
/// the faster the farther the escorted ship lies ahead along its own heading (`escort_catch_up`).
pub fn escort(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const escorted = std.math.cast(u16, slot.state.escort.escorted) orelse return escortLost(ctx, index);
    if (escorted >= all.slots.len or all.slots[escorted].object.type == .stand_in) return escortLost(ctx, index);
    const other = &all.slots[escorted];
    const lead = other.drawn.position + math.forward(other.drawn.orientation) * @as(Vector, @splat(escort_lead));
    const to = other.drawn.position - slot.drawn.position;
    const near = math.lengthSquared(to) <= escort_near * escort_near;
    const limit = if (near) escort_near_limit else ai.full_limit;
    const flags: ai.Steering = if (near) .{ .roll_upright = true } else .{ .avoid_near = true, .avoid_ahead = true };
    _ = ai.steer(ctx.world, index, lead, limit, ai.no_ease, flags);
    const flight = slot.flight orelse return;
    const cruise = ai.cruiseSpeed(&slot.object, flight, ctx.world.view);
    slot.object.throttle = math.dot(math.forward(slot.drawn.orientation), to) * escort_catch_up + other.object.speed / cruise;
}

fn escortLost(ctx: Context, index: u16) void {
    _ = aigeneric.pop(ctx, index);
}

/// `order_fly_init` (`0x0040AC00`): the init of Fly (6), which keeps the heading the ship starts
/// on.
pub fn flyInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.state.fly.heading = gameobj.vec3(slot.object.nextHeading());
}

/// `order_fly` (`0x0040AC20`): the update of Fly (6). It flies at the speed in the order's data, or
/// at full throttle for none. With a target it flies to it and pops once it is within `fly_reach`;
/// without one it holds the heading it started on, steering at a point `fly_ahead` along it. An
/// object with no flight stats is moved along that heading instead of flown, so that a body which
/// has no flight of its own still travels.
pub fn fly(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const heading = gameobj.vector(slot.state.fly.heading);
    const speed: f32 = @floatFromInt(slot.orders[0].data.fly);
    if (speed == 0) {
        object.throttle = ai.full_throttle;
    } else if (ai.slotCruise(slot, ctx.world.view)) |cruise| {
        object.throttle = speed / cruise;
    } else {
        const ticks: f32 = @floatFromInt(ctx.clock.frame_duration);
        const per_tick = heading * @as(Vector, @splat(speed * drift_per_tick));
        objects.setPosition(object, &slot.drawn, object.nextPosition() + per_tick * @as(Vector, @splat(ticks)));
        // Drawn on between the ticks (`create.Slot.glide`).
        slot.glide = per_tick;
        return;
    }

    // The game reads the target's index as a ship's slot, whatever its kind.
    const flags: ai.Steering = .{ .avoid_near = true, .avoid_ahead = true, .roll_upright = true };
    const avoided = if (slot.orders[0].target.slot()) |target| steer: {
        const to = all.slots[target].object.nextPosition();
        if (math.lengthSquared(to - object.nextPosition()) < fly_reach * fly_reach) {
            object.letGo();
            _ = aigeneric.pop(ctx, index);
            return;
        }
        if (slot.flight == null) return;
        break :steer ai.steer(ctx.world, index, to, ai.full_limit, ai.no_ease, flags);
    } else steer: {
        const at = object.nextPosition() + heading * @as(Vector, @splat(fly_ahead));
        break :steer ai.steer(ctx.world, index, at, ai.full_limit, ai.no_ease, flags);
    };
    if (avoided) object.throttle *= avoided_throttle;
}

/// `order_run_away` (`0x0040ADE0`): the update of Run Away (7), which flies away from its target at
/// half throttle, steering at a point far beyond itself. It pops once the target's slot holds a
/// stand-in.
pub fn runAway(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    // The game reads the target's index as a ship's slot, whatever its kind.
    const other = find: {
        const target = slot.orders[0].target.slot() orelse break :find null;
        const object = &all.slots[target].object;
        break :find if (object.type == .stand_in) null else object;
    } orelse {
        _ = aigeneric.pop(ctx, index);
        return;
    };
    const from = slot.object.nextPosition();
    const away = from - other.nextPosition();
    const at = from + away * @as(Vector, @splat(run_away_ahead));
    _ = ai.steer(ctx.world, index, at, ai.full_limit, run_away_ease, .{ .avoid_near = true, .avoid_ahead = true });
    slot.object.throttle = run_away_throttle;
}

// --- Find New Target ------------------------------------------------------------------------

/// What Find New Target keeps in `order_state` as it walks its target's ships: the one it would
/// fight, the component, and how heavily it weighs, and the one it would mill round likewise; -1
/// for none, and the most a float holds for no weight yet.
pub const FindTargetState = extern struct {
    _unknown_00: u32,
    fight: i32,
    fight_component: i32,
    fight_weight: f32,
    mill: i32,
    mill_component: i32,
    mill_weight: f32,
    _unknown_1c: [0x90 - 0x1C]u8,

    comptime {
        assert(@offsetOf(FindTargetState, "fight") == 0x04);
        assert(@offsetOf(FindTargetState, "mill") == 0x10);
        assert(@offsetOf(FindTargetState, "mill_weight") == 0x18);
        assert(@sizeOf(FindTargetState) == 0x90);
    }
};

/// How many other fighters may fight a target before a fighter looks past it, as the count that
/// starts at 1 for itself (`0x0040AFAB`).
const most_fought = 3;

/// `order_find_new_target` (`0x0040B040`): the update of Find New Target (10). It weighs each ship
/// its target names (`ai.eachShip`, `weighTarget`) for the one to fight and the one to mill round.
/// It fights the lightest of the first, pushing Fight (105), or Torpedo (103) for a ship of the
/// torpedo class; with none, it mills round the lightest of the second (Mill, 120); each pushed
/// above it. With neither it pops.
///
/// Not ported: the Torpedo order it pushes, which does nothing yet
/// ([#30](https://github.com/vdmkenny/openreliant/issues/30)); and in a multiplayer game, a ship
/// another machine flies, which pushes no Fight ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
pub fn findNewTarget(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.find_target;
    state.fight = -1;
    state.fight_component = -1;
    state.fight_weight = std.math.floatMax(f32);
    state.mill = -1;
    state.mill_component = -1;
    state.mill_weight = std.math.floatMax(f32);
    var weighing: Weighing = .{ .ctx = ctx, .index = index };
    _ = ai.eachShip(ctx.world, slot.orders[0].target, &weighing);
    if (state.mill < 0) {
        if (state.fight == -1) {
            _ = aigeneric.pop(ctx, index);
        } else {
            slot.object.letGo();
        }
        return;
    }
    const pushed: Order, const ship: i32, const component: i32 = if (state.fight < 0)
        .{ .mill, state.mill, state.mill_component }
    else if (slot.combat != null and slot.combat.?.class == .torpedo)
        .{ .torpedo, state.fight, state.fight_component }
    else
        .{ .fight, state.fight, state.fight_component };
    _ = aigeneric.pushShip(ctx, index, pushed, @intCast(ship), @intCast(component)) catch |err| {
        log.warn("ship {d} takes no order {d}: {s}", .{ index, @intFromEnum(pushed), @errorName(err) });
    };
}

/// The visitor of Find New Target's walk (`weighTarget`).
const Weighing = struct {
    ctx: Context,
    index: u16,

    pub fn visit(weighing: *Weighing, target: aigeneric.Target) bool {
        weighTarget(weighing.ctx, weighing.index, target);
        return false;
    }
};

/// `0x0040AE90`, Find New Target's visitor: a ship it can aim at, cloaked or not
/// (`ai.targetValid`), weighs the square of its node's distance from where the searcher will be
/// next. As one to fight, times one more than the ships whose current order is Fight at it, this
/// one component and all; as one to mill round, times that and one more than the ships whose
/// current order is Mill round it. The lightest of each is kept, but to fight only one that is
/// not cloaked, not the target the radio's menu has set aside for the searcher
/// (`GameObject.set_aside`), and for a fighter one fewer than two others fight. Once the set-aside
/// time is up, the target is set aside no more, though not until this walk is over.
///
/// **Quirk:** the game weighs the one to fight by 0.7 more (`0x004DC484`) where the count of
/// objects it has just walked equals the player's slot, which never happens; it looks meant to
/// favour the player's ship ([#314](https://github.com/vdmkenny/openreliant/issues/314)).
/// OpenReliant keeps the game's weights.
fn weighTarget(ctx: Context, index: u16, target: aigeneric.Target) void {
    const all = ctx.world.objects;
    if (!ai.targetValid(all, target, .{ .cloaked = true })) return;
    const slot = &all.slots[index];
    const state = &slot.state.find_target;
    const distance = math.lengthSquared(ai.aimedAt(all, target).position - slot.object.nextPosition());
    var fights: f32 = 1;
    var mills: f32 = 1;
    for (all.slots[0..all.count]) |*other| {
        if (!other.object.type.hasStats() or other.object.order_count <= 0) continue;
        const entry = other.orders[0];
        if (entry.target.index != target.index or entry.target.component != target.component) continue;
        if (entry.order == .fight) fights += 1;
        if (entry.order == .mill) mills += 1;
    }
    const aimed = @as(u16, @intCast(target.index));
    if (slot.object.set_aside.index() == aimed) {
        if (slot.object.set_aside_until < ctx.clock.game_ticks) {
            slot.object.set_aside = .none;
            slot.object.set_aside_until = 0;
        }
    } else {
        const weight = fights * distance;
        const fighter = if (slot.combat) |combat| combat.class == .fighter else false;
        if (weight < state.fight_weight and !all.slots[aimed].object.flags.cloaked and !(fighter and fights >= most_fought)) {
            state.fight = target.index;
            state.fight_weight = weight;
            state.fight_component = target.component;
        }
    }
    const crowd = (fights + mills) * distance;
    if (crowd < state.mill_weight) {
        state.mill = target.index;
        state.mill_weight = crowd;
        state.mill_component = target.component;
    }
}

/// `order_slow_rotate` (`0x0040B660`): the update of Slow Rotate (18), which turns the ship on the
/// spot.
pub fn slowRotate(ctx: Context, index: u16) void {
    const object = &ctx.world.objects.slots[index].object;
    object.letGo();
    object.yaw_input = spin_input;
}

/// How fast a Random Spin tumbles: the share of the turn each input takes at random, on top of
/// `spin_input` (`0x004DC4C0` and the words after it).
pub const Spin = enum(u8) {
    slow = 0,
    medium = 1,
    fast = 2,

    pub fn spread(spin: Spin) f32 {
        return switch (spin) {
            .slow => 0.3,
            .medium => 0.5,
            .fast => 0.9,
        };
    }
};

/// `order_random_spin_slow_init` (`0x0040B6A0`) and its two neighbours: the init of the Random
/// Spins (22 to 24), which set the ship tumbling, each input at random. Their update does nothing,
/// so the ship keeps the tumble.
pub fn randomSpinInit(ctx: Context, index: u16, spin: Spin) void {
    const object = &ctx.world.objects.slots[index].object;
    const spread = spin.spread();
    object.throttle = 0;
    object.pitch_input = xtrabits.objectRandom(object) * spread + spin_input;
    object.roll_input = xtrabits.objectRandom(object) * spread + spin_input;
    object.yaw_input = xtrabits.objectRandom(object) * spread + spin_input;
}

/// `order_match_speed` (`0x0040B9E0`): the update of Match Speed (32), which holds the ship at its
/// target's speed. It pops once the target can no longer be aimed at.
pub fn matchSpeed(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = slot.orders[0].target;
    if (!ai.targetValid(all, target, .{})) {
        _ = aigeneric.pop(ctx, index);
        return;
    }
    const cruise = ai.slotCruise(slot, ctx.world.view) orelse return;
    slot.object.throttle = all.slots[@intCast(target.index)].object.speed / cruise;
}

/// `order_launch_missile` (`0x0040B940`): the update of Launch Missile (2), which runs once over
/// the ship's order: a missile from the first of its racks with any left, but Jack Hammers, at the
/// order's target.
pub fn launchMissile(ctx: Context, index: u16) void {
    launchFrom(ctx, index, false);
}

/// `0x0040B990`: the update of order 3, which the game names nothing, likewise for a Jack Hammer,
/// which the Fight order never launches.
pub fn launchJackHammer(ctx: Context, index: u16) void {
    launchFrom(ctx, index, true);
}

fn launchFrom(ctx: Context, index: u16, jack_hammer: bool) void {
    const slot = &ctx.world.objects.slots[index];
    const ship = &slot.object;
    for (ship.fittedRacks(), 0..) |rack, at| {
        if (rack.count < 1 or (rack.type == .jack_hammer) != jack_hammer) continue;
        missiles.launch(ctx.world, index, at, slot.orders[0].target);
        return;
    }
}

/// What a Havoc's shockwave leaves in Disrupted's data (`shockwave.Shockwave.strike`): how many
/// ticks the ship is disrupted for, and the push it takes.
pub const DisruptedData = extern struct {
    ticks: i32 align(2),
    push: [3]f32 align(2),

    comptime {
        assert(@sizeOf(DisruptedData) == @sizeOf(aigeneric.Entry.Data));
    }
};

/// What Disrupted keeps in `order_state`: the tick it ends at, where Explode keeps its own.
pub const DisruptedState = extern struct {
    _unknown_00: u32,
    end: i32,
    _unknown_08: [0x88]u8,

    comptime {
        assert(@offsetOf(DisruptedState, "end") == 0x4);
        assert(@sizeOf(DisruptedState) == 0x90);
    }
};

/// How far either way each of a disrupted ship's rates is knocked, in radians a step.
const disrupted_spin: f32 = 0.1;

/// The electric rays over a disrupted ship: fifteen, each from its centre out to its radius at
/// random, 90 either way, straying by up to 0.6 of its length, flickering and dimming as they go
/// dark, and lasting as long as the order; white and blue in turn.
const disrupted_rays = 15;
const disrupted_ray: erayfx.Spec = .{ .life = 0, .jitter = 0.6, .width = 90, .flags = .{ .flickers = true, .fades = true, .timed = true } };
const disrupted_colours = [2][3]f32{ .{ 0.8, 0.8, 1 }, .{ 0.3, 0.5, 1 } };

/// `order_disrupted_init` (`0x0040C140`): the init of Disrupted (114). The ship is left unpowered
/// until the tick its data counts to, takes the push in its data, and has each rate knocked by up
/// to 0.05 either way, at random, which it tumbles by.
///
/// **Quirk:** the push is given in the world's frame and taken in the ship's own
/// (`gameobj.knockLocal`), so the ship is thrown off at a turn from straight away from the blast.
///
/// Fifteen electric rays play over it meanwhile (`disrupted_rays`).
pub fn disruptedInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    const data = slot.orders[0].data.disrupted;
    object.flags.unpowered = true;
    slot.state.disrupted.end = data.ticks + ctx.clock.frame_start;
    gameobj.knockLocal(object, data.push, @splat(0));
    const random = ctx.world.random;
    object.yaw_rate += random.centred() * disrupted_spin;
    object.pitch_rate += random.centred() * disrupted_spin;
    object.roll_rate += random.centred() * disrupted_spin;
    object.rotation = math.fromAngles(object.pitch_rate, object.yaw_rate, object.roll_rate);
    const rays = ctx.world.rays orelse return;
    var spec = disrupted_ray;
    spec.life = data.ticks;
    for (0..disrupted_rays) |n| {
        const ray = rays.add(spec, random) catch return;
        ray.colour(0, disrupted_colours[n % 2]);
        const turn = math.fromAngleVector(random.fractionVector(@splat(std.math.tau)));
        ray.to = math.transform(turn, .{ 0, 0, object.radius });
        ray.hang(.{ .object = index });
        ray.owner = index;
    }
}

/// `order_disrupted` (`0x0040C370`): the update of Disrupted, which pops past its end.
pub fn disrupted(ctx: Context, index: u16) void {
    if (ctx.world.objects.slots[index].state.disrupted.end < ctx.clock.frame_start) _ = aigeneric.pop(ctx, index);
}

/// `order_disrupted_exit` (`0x0040C390`): the exit of Disrupted, which powers the ship again.
pub fn disruptedExit(ctx: Context, index: u16) void {
    ctx.world.objects.slots[index].object.flags.unpowered = false;
}

test disruptedInit {
    const gpa = std.testing.allocator;
    var rays: erayfx.testing.Built = try .init(gpa);
    defer rays.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var ctx = mission.orders();
    ctx.world.rays = &rays.rays;
    const index = try mission.add(.predator, @splat(0));
    const slot = mission.slot(index);
    slot.object.radius = 50;
    slot.orders[0].data = .{ .disrupted = .{ .ticks = 300, .push = @splat(0) } };

    // Unpowered until its data runs out, with fifteen rays out from its centre to its radius,
    // white and blue in turn, lasting as long.
    disruptedInit(ctx, index);
    try std.testing.expect(slot.object.flags.unpowered);
    for (rays.rays.slots[0..disrupted_rays], 0..) |made, n| {
        const ray = made.?;
        try std.testing.expectEqual(index, ray.owner);
        try std.testing.expectEqual(300, ray.life);
        try std.testing.expect(ray.flags.flickers and ray.flags.fades and ray.flags.timed);
        try std.testing.expectApproxEqAbs(50, math.length(ray.to), 1e-3);
        try std.testing.expectEqual(disrupted_colours[n % 2], ray.light.colour);
    }
    try std.testing.expectEqual(null, rays.rays.slots[disrupted_rays]);
}

test doNothing {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const index = try mission.add(.predator, @splat(0));
    const ctx = mission.orders();

    all.slots[index].object.throttle = 1;
    all.slots[index].object.yaw_input = 1;
    doNothing(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.throttle);
    try std.testing.expectEqual(0, all.slots[index].object.yaw_input);
}

test fly {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const other = try mission.addOther(.{ 0, 0, 30000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .fly, other, aigeneric.Target.whole));

    // Starting it keeps the heading, and with no speed of its own it flies at full throttle.
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(1, all.slots[index].state.fly.heading.z);
    try std.testing.expectEqual(1, all.slots[index].object.throttle);
    // It steers at its target, which lies dead ahead, so it holds its course.
    try std.testing.expectApproxEqAbs(0, all.slots[index].object.yaw_input, 1e-6);

    // A speed in its data is a share of the cruise speed, which is 320 for the test's stats.
    all.slots[index].orders[0].data.fly = 160;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectApproxEqAbs(0.5, all.slots[index].object.throttle, 1e-6);

    // Within reach of the target it stops and pops.
    objects.setPosition(&all.slots[other].object, &all.slots[other].drawn, .{ 0, 0, 1500 });
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.throttle);
    try std.testing.expectEqual(0, all.slots[index].object.order_count);
}

test "Fly without a target holds the heading it started on" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    objects.setOrientation(&slot.object, &slot.drawn, math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expect(try aigeneric.push(ctx, index, .fly, .none));
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectApproxEqAbs(1, slot.state.fly.heading.x, 1e-6);
    // The heading is where it points, so it steers straight on.
    try std.testing.expectApproxEqAbs(0, slot.object.yaw_input, 1e-6);
    try std.testing.expectEqual(1, slot.object.order_count);
}

test "Fly moves an object with no flight stats, and glides it between the ticks" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    slot.flight = null;
    try std.testing.expect(try aigeneric.push(ctx, index, .fly, .none));
    slot.orders[0].data.fly = 100;
    // Placed on by its speed for the ticks the frame spans, and gliding that much a tick.
    mission.clock.frame_duration = 2;
    aigeneric.objectOrders(ctx, index);
    const per_tick = 100 * drift_per_tick;
    try std.testing.expectApproxEqAbs(2 * per_tick, slot.object.root.position.z, 1e-4);
    try std.testing.expectApproxEqAbs(per_tick, slot.glide[2], 1e-6);
}

test "a ship under a Fly order closes on its target and stops there" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const target = try mission.addOther(.{ 8000, 0, 30000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .fly, target, aigeneric.Target.whole));
    const slot = &all.slots[index];
    const to = all.slots[target].object.nextPosition();
    const start = math.distance(gameobj.vector(slot.object.root.position), to);

    // A frame of orders, then the step that moves what they steer, as the loop paces them.
    for (0..2000) |_| {
        mission.clock.frame_duration = 4;
        aigeneric.ordersUpdate(ctx);
        create.objectsUpdate(ctx.world);
        for (all.slots[0..all.count]) |*live| {
            gameobj.updateTree(&live.object.root, null, null);
            live.drawn = .{ .position = gameobj.vector(live.object.root.position), .orientation = live.object.root.orientation };
        }
        if (slot.object.order_count == 0) break;
    }

    // It flew there, and stopped once it arrived: the order popped and the throttle is off.
    const reached = math.distance(gameobj.vector(slot.object.root.position), to);
    try std.testing.expect(reached < start / 10);
    try std.testing.expect(reached < fly_reach);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(0, slot.object.throttle);
}

test matchSpeed {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const other = try mission.addOther(.{ 0, 0, 5000 });
    all.slots[other].object.flags.targetable = true;
    all.slots[other].object.speed = 160;
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .match_speed, other, aigeneric.Target.whole));

    aigeneric.objectOrders(ctx, index);
    try std.testing.expectApproxEqAbs(0.5, all.slots[index].object.throttle, 1e-6);

    // Once the target can no longer be aimed at, it pops.
    all.slots[other].object.flags.exploding = true;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.order_count);
}

test randomSpinInit {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const object = &all.slots[index].object;
    object.throttle = 1;
    randomSpinInit(ctx, index, .fast);
    try std.testing.expectEqual(0, object.throttle);
    for ([_]f32{ object.pitch_input, object.roll_input, object.yaw_input }) |turn| {
        try std.testing.expect(turn >= spin_input and turn <= spin_input + Spin.fast.spread());
    }
    // A slower spin never turns as fast as the fastest can.
    randomSpinInit(ctx, index, .slow);
    try std.testing.expect(object.yaw_input <= spin_input + Spin.slow.spread());
}

test runAway {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const other = try mission.addOther(.{ 0, 0, 5000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .run_away, other, aigeneric.Target.whole));

    // The target lies ahead, so it turns away from it and flies at half throttle.
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(run_away_throttle, all.slots[index].object.throttle);
    try std.testing.expect(@abs(all.slots[index].object.yaw_input) > 0 or @abs(all.slots[index].object.roll_input) > 0);

    // A slot that has gone back to standing in is nothing to run from.
    all.resetSlot(other, &mission.random);
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.order_count);
}

test launchMissile {
    var armed: missiles.testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    const ship = try armed.add(.hostile, @splat(0));
    const target = try armed.add(.friendly, .{ 0, 0, 20000 });
    armed.mission.slot(ship).orders[0] = .{ .order = .launch_missile, .target = .at(target, null), .sequence = 0, .data = .{ .words = @splat(0) } };
    const ctx = armed.mission.orders();
    // The first rack with missiles, the Raptor pod, at the order's target.
    launchMissile(ctx, ship);
    try std.testing.expectEqual(missiles.Type.raptor, armed.missile(0).type);
    try std.testing.expectEqual(@as(i16, @intCast(target)), armed.missile(0).target.index);
    // The fixture carries no Jack Hammer.
    launchJackHammer(ctx, ship);
    try std.testing.expectEqual(1, armed.live());
}

/// A mission for the tests of the orders that walk a flight group: `count` ships, the first two
/// outside any group, and the rest in flight group 0, which the world's mission binds.
const GroupMission = struct {
    fixture: @import("../vm.zig").machine.testing.Fixture,
    game: gameobj.testing.Mission,

    fn init(mission: *GroupMission, comptime count: usize, in_group: usize) !void {
        const gpa = std.testing.allocator;
        const dte = @import("../../formats/dte.zig");
        var ships: [count]dte.Ship = @splat(std.mem.zeroes(dte.Ship));
        for (&ships, 0..) |*ship, n| {
            ship.object_id = @intCast(n);
            ship.flight_group = if (n >= count - in_group) 0 else dte.Ship.no_flight_group;
        }
        var flight_group = std.mem.zeroes(dte.FlightGroup);
        flight_group.object_id = count;
        var kinds: [count + 1]dte.Object = @splat(.{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 });
        kinds[count].kind = .flight_group;
        try mission.fixture.init(gpa, &.{}, .{ .ships = &ships, .flight_groups = &.{flight_group}, .objects = &kinds });
        errdefer mission.fixture.deinit();
        try mission.game.init(gpa);
    }

    fn deinit(mission: *GroupMission) void {
        mission.game.deinit();
        mission.fixture.deinit();
    }

    fn orders(mission: *GroupMission) Context {
        var ctx = mission.game.orders();
        ctx.world.mission = &mission.fixture.mission;
        return ctx;
    }

    const group: aigeneric.Target = .{ .kind = .flight_group, .index = 0, .component = aigeneric.Target.whole };
};

test "Find New Target fights what it may, mills round the rest, and pops with none" {
    var mission: GroupMission = undefined;
    try mission.init(6, 3);
    defer mission.deinit();
    const game = &mission.game;
    const ctx = mission.orders();
    // A fighter at the origin, a Predator that fights, and the flight group of three ahead, the
    // nearest fought by two others already and the next cloaked.
    const searcher = try game.addOther(@splat(0));
    const other = try game.add(.predator, .{ 0, 0, -5000 });
    const near = try game.add(.predator, .{ 0, 0, 10000 });
    const cloaked = try game.add(.predator, .{ 0, 0, 20000 });
    const far = try game.add(.predator, .{ 0, 0, 30000 });
    for ([_]u16{ near, cloaked, far }) |index| game.slot(index).object.flags.targetable = true;
    game.slot(cloaked).object.flags.cloaked = true;
    try std.testing.expectEqual(.fighter, game.slot(searcher).combat.?.class);
    for ([_]u16{ 0, other }) |index| {
        _ = try aigeneric.pushShip(ctx, index, .fight, near, aigeneric.Target.whole);
    }

    // It fights the farthest, the one it may.
    _ = try aigeneric.push(ctx, searcher, .find_new_target, GroupMission.group);
    findNewTarget(ctx, searcher);
    const fought = game.slot(searcher).orders[0];
    try std.testing.expectEqual(Order.fight, fought.order);
    try std.testing.expectEqual(far, fought.target.slot());

    // With that one set aside, it mills round the least crowded for its distance: the nearest.
    _ = aigeneric.pop(ctx, searcher);
    game.slot(searcher).object.set_aside = .of(far);
    game.slot(searcher).object.set_aside_until = 1000;
    findNewTarget(ctx, searcher);
    const milled = game.slot(searcher).orders[0];
    try std.testing.expectEqual(Order.mill, milled.order);
    try std.testing.expectEqual(near, milled.target.slot());

    // Once none can be aimed at, it pops.
    _ = aigeneric.pop(ctx, searcher);
    for ([_]u16{ near, cloaked, far }) |index| game.slot(index).object.flags.targetable = false;
    findNewTarget(ctx, searcher);
    try std.testing.expectEqual(0, game.slot(searcher).object.order_count);
}

test "Escort takes its place in the group, follows, and ends with its ship" {
    var mission: GroupMission = undefined;
    try mission.init(4, 2);
    defer mission.deinit();
    const game = &mission.game;
    const ctx = mission.orders();
    const escort_ship = try game.addOther(@splat(0));
    const first = try game.add(.predator, .{ 0, 0, 20000 });
    _ = try game.add(.predator, .{ 0, 0, 20000 });

    // Third among the group's two, it counts round to the first.
    _ = try aigeneric.push(ctx, escort_ship, .escort, GroupMission.group);
    game.slot(escort_ship).orders[0].sequence = 2;
    aigeneric.objectOrders(ctx, escort_ship);
    try std.testing.expectEqual(first, game.slot(escort_ship).state.escort.escorted);

    // Far behind a ship flying at 320, it flies faster than that to catch up.
    const lead = game.slot(first);
    lead.object.speed = 320;
    aigeneric.objectOrders(ctx, escort_ship);
    const cruise = gameobj.testing.flight.max_speed;
    try std.testing.expectApproxEqAbs(20000 * escort_catch_up + 320 / cruise, game.slot(escort_ship).object.throttle, 1e-4);

    // Once its ship has gone, it ends.
    lead.object.type = .stand_in;
    aigeneric.objectOrders(ctx, escort_ship);
    try std.testing.expectEqual(0, game.slot(escort_ship).object.order_count);
}

test "Escort of a group with no ships escorts none" {
    var mission: GroupMission = undefined;
    try mission.init(2, 0);
    defer mission.deinit();
    const ctx = mission.orders();
    const escort_ship = try mission.game.addOther(@splat(0));
    _ = try aigeneric.push(ctx, escort_ship, .escort, GroupMission.group);
    aigeneric.objectOrders(ctx, escort_ship);
    try std.testing.expectEqual(0, mission.game.slot(escort_ship).object.order_count);
}

test "Mill circles its target for a while" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const ship = try mission.addOther(@splat(0));
    const target = try mission.add(.predator, .{ 0, 0, 60000 });
    mission.slot(target).object.flags.targetable = true;
    _ = try aigeneric.pushShip(ctx, ship, .mill, target, aigeneric.Target.whole);
    aigeneric.objectOrders(ctx, ship);
    // Its circle faces from the target back to the ship, and it flies at full throttle.
    const state = &mission.slot(ship).state.mill;
    try std.testing.expectApproxEqAbs(-1, math.forward(state.circle)[2], 1e-5);
    try std.testing.expectEqual(ai.full_throttle, mission.slot(ship).object.throttle);
    // After its time is up, it ends.
    mission.clock.frame_start = mill_ticks + 1;
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(0, mission.slot(ship).object.order_count);
}
