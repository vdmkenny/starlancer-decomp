//! The code that moves live objects, which the binary names no file for: `object_move`
//! (`0x00473FF0`) and the flight model the motion routines run, `object_fly` (`0x004742E0`) with
//! `object_steer` (`0x00474150`). **Unknown:** its source file. The code lies after `explode.cpp`'s
//! and before `gameflow.cpp`'s, and nothing in it asserts. docs/engine/objects.md describes the
//! motion.

const std = @import("std");

const math = @import("../surrender/math.zig");
const ai = @import("ai.zig");
const camera = @import("camera.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const objects = @import("objects.zig");
const GameObject = gameobj.GameObject;

/// The routine `GameObject.motion` points at, which moves it for one update. `create_object` gives
/// every object `motion_forward`. The orders select eight more, of which OpenReliant has those of
/// the pilot's ejection and of the launches; the rest aren't ported yet (#30), and
/// docs/engine/objects.md lists them.
pub const Motion = enum {
    /// `motion_forward` (`0x004744C0`): the flight model thrusting ahead.
    forward,
    /// `motion_backward` (`0x004744D0`): the flight model thrusting astern.
    backward,
    /// `motion_downward` (`0x004744E0`), which the Reliant's launch gives a ship as it drops out
    /// of its bay: the plain flight model (`plain`) along the ship's own Y axis, which points below
    /// it, its last throttle nothing.
    downward,
    /// `motion_plain` (`0x00474570`), which a torpedo's launch gives it as it leaves its tube: the
    /// plain flight model along the ship's nose, save that the Ripper flies it by its own flight
    /// model whatever its class.
    plain,
    /// `motion_brake` (`0x00474610`), which Eject gives the pilot's pod once it is clear of the
    /// ship: it slows to `brake_share` of its velocity each update, its throttle nothing.
    brake,
    /// `motion_drift` (`0x00474B00`), which the ejection gives the ship it leaves, and Jump In: it
    /// slows to `drift_share` of its velocity each update.
    drift,

    /// Moves `object` for one update, by `flight` in `view` where it flies.
    pub fn run(motion: Motion, object: *GameObject, flight: Flight, view: camera.View) void {
        switch (motion) {
            .forward => fly(object, flight.own, view, ahead),
            .backward => fly(object, flight.own, view, astern),
            .downward => {
                plain(object, flight.fighter orelse flight.own, .y);
                object.last_throttle = 0;
            },
            .plain => {
                plain(object, if (object.type == .ripper) flight.own else flight.fighter orelse flight.own, .z);
                object.last_throttle = object.throttle;
            },
            .brake => {
                slow(object, brake_share);
                object.last_throttle = 0;
            },
            .drift => slow(object, drift_share),
        }
    }
};

/// The flight models an object moves by: its type's own (`GameObject.flight`), and for a fighter
/// the first ship type's (`ship_flight_stats`, `0x004F9E70`), the Predator's, which the plain
/// motions fly every fighter by, so that each leaves its carrier alike.
pub const Flight = struct {
    own: *const create.FlightModel,
    /// Null for an object of any other class.
    fighter: ?*const create.FlightModel = null,
};

/// The flight model's thrust flying ahead, and astern.
const ahead: f32 = 1;
const astern: f32 = -1;

/// What a braking and a drifting object keep of their velocity each update (`0x00474618`,
/// `0x00474B07`).
const brake_share: f32 = 0.97;
const drift_share: f32 = 0.99;

/// The object's velocity scaled by `share`.
fn slow(object: *GameObject, share: f32) void {
    object.velocity = gameobj.vec3(gameobj.vector(object.velocity) * @as(math.Vector, @splat(share)));
}

/// The share of the cruise speed the lateral input pushes a ship sideways at (`object_fly`,
/// `0x004DC3D4`).
const lateral_share: f32 = 0.25;

/// What each update of the afterburner or of reverse thrust burns of `afterburner_fuel`
/// (`object_fly`, `0x0047430B` and `0x00474330`).
const burn_fuel: i32 = 4;

/// The throttle the afterburner and reverse thrust hold a ship at (`object_fly`, `0x00474301` and
/// `0x00474326`).
const afterburner_throttle: f32 = 2;
const reverse_throttle: f32 = -1;

/// How many times more slowly a ship with no throttle turns than one at full throttle, where the
/// steering slows it (`object_steer`, `0x004DC3D8`): the divisor falls from this to 1 as the
/// throttle rises.
const idle_turn_slowing: f32 = 3;

/// The rule every quantity of the flight model moves by: it gives up `inertia` of the way it was
/// going and takes the rest from where it is headed, once per update.
fn settle(current: f32, target: f32, inertia: f32) f32 {
    return current * inertia + (1 - inertia) * target;
}

/// `x` squared, keeping its sign, which is the measure the model works in along the nose.
fn signedSquare(x: f32) f32 {
    return @abs(x) * x;
}

/// The inverse of `signedSquare`.
fn signedRoot(x: f32) f32 {
    return if (x >= 0) @sqrt(x) else -@sqrt(-x);
}

/// `object_steer` (`0x00474150`): each input is clamped to between -1 and 1, and each angular rate
/// settles toward the ship's rate for that axis times the input. Where `throttle_turns`, that
/// target is divided by `3 - 2 * |throttle|` (`idle_turn_slowing`) while that exceeds 1, so a ship
/// turns more slowly the less throttle it carries. The three rates then make the rotation.
pub fn steer(object: *GameObject, flight: *const create.FlightModel, throttle_turns: bool) void {
    // The game doubles the throttle by adding it to itself, which the factor of 2 matches exactly.
    const slowed = idle_turn_slowing - (idle_turn_slowing - 1) * @abs(object.throttle);
    const divisor: f32 = if (throttle_turns and slowed >= 1) slowed else 1;
    const axes = [_]struct { rate: *f32, input: *f32, full: f32, inertia: f32 }{
        .{ .rate = &object.pitch_rate, .input = &object.pitch_input, .full = flight.pitch_rate, .inertia = flight.pitch_inertia },
        .{ .rate = &object.yaw_rate, .input = &object.yaw_input, .full = flight.yaw_rate, .inertia = flight.yaw_inertia },
        .{ .rate = &object.roll_rate, .input = &object.roll_input, .full = flight.roll_rate, .inertia = flight.roll_inertia },
    };
    for (axes) |axis| {
        axis.input.* = std.math.clamp(axis.input.*, -1, 1);
        axis.rate.* = settle(axis.rate.*, axis.full * axis.input.* / divisor, axis.inertia);
    }
    object.rotation = math.fromAngles(object.pitch_rate, object.yaw_rate, object.roll_rate);
}

/// `object_fly` (`0x004742E0`): the flight model, run for one update by the motion routine. The
/// throttle settles first, then the steering, then the speed, the last in the ship's own frame.
///
/// Along the nose the model settles in speed times its own size, so that thrust tells evenly at
/// every speed: the speed is squared keeping its sign, settles toward the thrust times the
/// throttle squared the same way times the target speed squared, and is rooted again. Sideways it
/// settles toward a quarter of the target times the lateral input, and along the ship's own down
/// axis it only decays.
pub fn fly(object: *GameObject, flight: *const create.FlightModel, view: camera.View, thrust: f32) void {
    if (object.afterburner) {
        object.throttle = afterburner_throttle;
        object.afterburner_fuel -= burn_fuel;
    } else if (object.reverse_thrust) {
        object.throttle = reverse_throttle;
        object.afterburner_fuel -= burn_fuel;
    } else {
        object.throttle = std.math.clamp(object.throttle, 0, 1);
    }
    object.afterburner_fuel = @max(object.afterburner_fuel, 0);

    steer(object, flight, true);

    // The frame the last update left behind: `object_move` sets it once the motion has run.
    const frame = object.root.next_orientation;
    const inertia = flight.inertia;
    const target = if (object.afterburner or object.reverse_thrust)
        flight.max_speed
    else
        ai.cruiseSpeed(object, flight, view);

    var speed = math.transformTransposed(frame, gameobj.vector(object.velocity));
    const push = thrust * object.throttle;
    speed = .{
        settle(speed[0], object.lateral_input * target * lateral_share, inertia),
        settle(speed[1], 0, inertia),
        signedRoot(settle(signedSquare(speed[2]), signedSquare(push) * target * target, inertia)),
    };
    object.velocity = gameobj.vec3(math.transform(frame, speed));
    object.last_throttle = object.throttle;
}

/// The plain flight model of `motion_downward` and `motion_plain`, which has no rules for the
/// throttle or the burns: the steering, the throttle slowing no turn, then the velocity, which
/// keeps `inertia` of itself and takes the rest from the throttle times the top speed along
/// `axis` of the frame the last update left behind.
fn plain(object: *GameObject, flight: *const create.FlightModel, axis: math.Axis) void {
    steer(object, flight, false);
    const inertia = flight.inertia;
    var along: [3]f32 = @splat(0);
    along[@intFromEnum(axis)] = (1 - inertia) * object.throttle * flight.max_speed;
    const kept = gameobj.vector(object.velocity) * @as(math.Vector, @splat(inertia));
    object.velocity = gameobj.vec3(kept + math.transform(object.root.next_orientation, along));
}

/// `object_move` (`0x00473FF0`): one update of an object. A `frozen` object stays where it is.
/// Otherwise the root's next place is marked as pending, which the next step's `node_tree_update`
/// commits (`objects.updateTree`). If knocks are waiting, they are applied instead of the object's
/// own motion. An `unpowered` object has no motion of its own, and a jumping one only moves when
/// it is knocked or `unpowered`. Then its next orientation becomes its orientation turned by
/// `rotation`, its next position becomes its position plus its velocity, and its speed becomes
/// the length of that velocity. It sets the network flags when the object moves or turns.
///
/// For the player's ship, `player_shake` is the camera's shake (`hit_shake`). When the ship flies
/// faster than its cruise speed, as it does under afterburner, the move raises the shake to at
/// least `0.2 * (speed / cruise speed - 1)`. The game also stores the change in the player's
/// speed at `player_speed_change` (`0x00562CE4`), which nothing reads.
pub fn move(object: *GameObject, flight: Flight, view: camera.View, motion: ?Motion, player_shake: ?*f32) void {
    if (object.flags.frozen) return;
    object.root.flags.next_pending = true;
    const knocked = object.knocks > 0;
    if (object.flags.jumping and !knocked and !object.flags.unpowered) return;
    if (!knocked and !object.flags.unpowered) {
        if (motion) |routine| routine.run(object, flight, view);
    } else {
        gameobj.applyKnocks(object);
    }
    object.root.next_orientation = math.product(object.root.orientation, object.rotation);
    object.root.next_position = gameobj.vec3(gameobj.vector(object.root.position) + gameobj.vector(object.velocity));
    object.speed = math.length(gameobj.vector(object.velocity));
    if (object.speed > 0) object.network.moved = true;
    if (object.pitch_rate != 0 or object.yaw_rate != 0 or object.roll_rate != 0) object.network.turned = true;
    if (player_shake) |shake| {
        shake.* = @max(shake.*, speed_shake * (object.speed / ai.cruiseSpeed(object, flight.own, view)) - speed_shake);
    }
}

/// The camera shake at twice the cruise speed (`0x004DC3F8`).
const speed_shake: f32 = 0.2;

/// The ship type whose flight model the plain motions fly every fighter by: the first,
/// `ship_flight_stats` itself.
const fighters_flight_type = 0;

/// `object_move` for the object in slot `index` of `world`, by its type's flight model, where it
/// has one (`move`), and for a fighter the first ship type's too, where the ship types' stats are
/// at hand (`gameobj.World.spawn`): the player's ship shakes the camera. `objects_update` moves
/// each object so, and `objects_collide` moves a pair again once it has shoved them.
pub fn moveSlot(world: gameobj.World, index: u16) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const own = slot.flight orelse return;
    const fighter = if (slot.combat) |combat| combat.class == .fighter else false;
    const flight: Flight = .{
        .own = own,
        .fighter = if (fighter) if (world.spawn) |spawn| &spawn.tables.flight[fighters_flight_type] else null else null,
    };
    move(&slot.object, flight, world.view, slot.motion, if (index == all.player) world.shake else null);
}

test steer {
    var object = gameobj.testing.object();
    object.throttle = 1;
    // An input past the ends is clamped, and the rate settles toward the ship's own rate.
    object.pitch_input = 5;
    steer(&object, &gameobj.testing.flight, true);
    try std.testing.expectEqual(1, object.pitch_input);
    try std.testing.expectApproxEqAbs(0.4, object.pitch_rate, 1e-6);
    for (0..200) |_| steer(&object, &gameobj.testing.flight, true);
    try std.testing.expectApproxEqAbs(gameobj.testing.flight.pitch_rate, object.pitch_rate, 1e-4);

    // At rest the same input turns it a third as fast, the divisor being 3 - 2 * |throttle|.
    var idle = gameobj.testing.object();
    idle.pitch_input = 1;
    for (0..200) |_| steer(&idle, &gameobj.testing.flight, true);
    try std.testing.expectApproxEqAbs(gameobj.testing.flight.pitch_rate / 3, idle.pitch_rate, 1e-4);
    // A caller that does not ask for it gets no such division.
    var full = gameobj.testing.object();
    full.pitch_input = 1;
    for (0..200) |_| steer(&full, &gameobj.testing.flight, false);
    try std.testing.expectApproxEqAbs(gameobj.testing.flight.pitch_rate, full.pitch_rate, 1e-4);
}

test "the throttle settles between 0 and 1, and the burns take it past both ends" {
    var object = gameobj.testing.object();
    object.throttle = 5;
    fly(&object, &gameobj.testing.flight, .chase, 1);
    try std.testing.expectEqual(1, object.throttle);
    try std.testing.expectEqual(1, object.last_throttle);
    object.throttle = -3;
    fly(&object, &gameobj.testing.flight, .chase, 1);
    try std.testing.expectEqual(0, object.throttle);

    // The afterburner runs it to 2 and burns fuel; reverse thrust to -1, and burns it as well.
    object.afterburner = true;
    object.afterburner_fuel = 10;
    fly(&object, &gameobj.testing.flight, .chase, 1);
    try std.testing.expectEqual(2, object.throttle);
    try std.testing.expectEqual(6, object.afterburner_fuel);
    object.afterburner = false;
    object.reverse_thrust = true;
    fly(&object, &gameobj.testing.flight, .chase, 1);
    try std.testing.expectEqual(-1, object.throttle);
    try std.testing.expectEqual(2, object.afterburner_fuel);
    // The fuel stops at zero however long it burns.
    for (0..4) |_| fly(&object, &gameobj.testing.flight, .chase, 1);
    try std.testing.expectEqual(0, object.afterburner_fuel);
}

test "a ship settles at its cruise speed along its nose" {
    var object = gameobj.testing.object();
    object.throttle = 1;
    for (0..400) |_| move(&object, .{ .own = &gameobj.testing.flight }, .chase, .forward, null);
    // The model frame has Z forward, so all of the speed is along the nose.
    try std.testing.expectApproxEqAbs(320, object.speed, 0.5);
    try std.testing.expectApproxEqAbs(320, object.velocity.z, 0.5);
    try std.testing.expectApproxEqAbs(0, object.velocity.x, 1e-3);
    try std.testing.expectApproxEqAbs(0, object.velocity.y, 1e-3);
    // It never runs past the speed it is settling toward.
    try std.testing.expect(object.speed <= 320);

    // Half its engines gone, it settles at half the speed.
    object.engines_intact = 0.5;
    for (0..400) |_| move(&object, .{ .own = &gameobj.testing.flight }, .chase, .forward, null);
    try std.testing.expectApproxEqAbs(160, object.speed, 0.5);

    // Backward, the same ship ends up going the other way at the same speed.
    var reversed = gameobj.testing.object();
    reversed.throttle = 1;
    for (0..400) |_| move(&reversed, .{ .own = &gameobj.testing.flight }, .chase, .backward, null);
    try std.testing.expectApproxEqAbs(-320, reversed.velocity.z, 0.5);
}

test "the lateral input pushes a ship a quarter as fast sideways" {
    var object = gameobj.testing.object();
    object.lateral_input = 1;
    for (0..400) |_| move(&object, .{ .own = &gameobj.testing.flight }, .chase, .forward, null);
    try std.testing.expectApproxEqAbs(320 * lateral_share, object.velocity.x, 0.5);
}

test move {
    var object = gameobj.testing.object();
    object.root.position = .{ .x = 1, .y = 2, .z = 3 };
    object.velocity = .{ .x = 10, .y = 0, .z = 20 };
    // `create_object` leaves the rotation zeroed, and the steering builds one before the first
    // move uses it; a turn of nothing stands in for that here.
    object.rotation = math.identity;
    // With no motion routine, it carries on at the velocity it has.
    move(&object, .{ .own = &gameobj.testing.flight }, .chase, null, null);
    try std.testing.expectEqual(11, object.root.next_position.x);
    try std.testing.expectEqual(2, object.root.next_position.y);
    try std.testing.expectEqual(23, object.root.next_position.z);
    try std.testing.expectApproxEqAbs(@sqrt(500.0), object.speed, 1e-4);
    // Its next orientation is its orientation turned by the rotation the steering built.
    try std.testing.expectEqual(math.identity, object.root.next_orientation);
    try std.testing.expect(object.root.flags.next_pending);
}

test "a braking object slows faster than a drifting one, and lets go of its throttle" {
    var braking = gameobj.testing.object();
    braking.velocity = .{ .x = 0, .y = 0, .z = 100 };
    braking.last_throttle = 1;
    var drifting = braking;
    Motion.brake.run(&braking, .{ .own = &gameobj.testing.flight }, .chase);
    Motion.drift.run(&drifting, .{ .own = &gameobj.testing.flight }, .chase);
    try std.testing.expectApproxEqAbs(100 * brake_share, braking.velocity.z, 1e-4);
    try std.testing.expectEqual(0, braking.last_throttle);
    try std.testing.expectApproxEqAbs(100 * drift_share, drifting.velocity.z, 1e-4);
    try std.testing.expectEqual(1, drifting.last_throttle);
}

test "the plain motions push along the ship's own axes, a fighter by the first type's flight" {
    var first = gameobj.testing.flight;
    first.max_speed = 100;
    const flight: Flight = .{ .own = &gameobj.testing.flight, .fighter = &first };
    // Turned a quarter about Z, the ship's own Y axis points along the world's -X.
    const turned = math.rotation(.z, std.math.pi / 2.0);
    var dropping = gameobj.testing.object();
    dropping.root.next_orientation = turned;
    dropping.throttle = 1;
    dropping.last_throttle = 1;
    for (0..400) |_| Motion.downward.run(&dropping, flight, .chase);
    try std.testing.expectApproxEqAbs(-100, dropping.velocity.x, 0.5);
    try std.testing.expectApproxEqAbs(0, dropping.velocity.y, 1e-3);
    try std.testing.expectEqual(0, dropping.last_throttle);
    // With no throttle, it turns no more slowly.
    dropping.throttle = 0;
    dropping.pitch_input = 1;
    Motion.downward.run(&dropping, flight, .chase);
    try std.testing.expectApproxEqAbs(0.4, dropping.pitch_rate, 1e-6);

    // Plain, along the nose, keeping its throttle as the last.
    var boosting = gameobj.testing.object();
    boosting.throttle = 2;
    for (0..400) |_| Motion.plain.run(&boosting, flight, .chase);
    try std.testing.expectApproxEqAbs(200, boosting.velocity.z, 0.5);
    try std.testing.expectEqual(2, boosting.last_throttle);
    // The Ripper flies by its own flight model, and so does what is no fighter.
    boosting.type = .ripper;
    for (0..400) |_| Motion.plain.run(&boosting, flight, .chase);
    try std.testing.expectApproxEqAbs(640, boosting.velocity.z, 0.5);
    var other = gameobj.testing.object();
    other.throttle = 1;
    for (0..400) |_| Motion.downward.run(&other, .{ .own = &gameobj.testing.flight }, .chase);
    try std.testing.expectApproxEqAbs(320, other.velocity.y, 0.5);
}

test "a fighter moves by the first ship type's flight where the stats are at hand" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    mission.tables.flight[fighters_flight_type].max_speed = 100;
    const fighter = try mission.add(.sabre, @splat(0));
    const other = try mission.add(.sabre, .{ 0, 0, 5000 });
    mission.tables.combat[@intFromEnum(gameobj.Type.sabre)].class = .fighter;
    var world = mission.world();
    world.spawn = .{ .tables = &mission.tables, .types = create.testing.no_models };
    for ([_]u16{ fighter, other }) |index| {
        const slot = mission.slot(index);
        slot.motion = .downward;
        slot.object.throttle = 1;
    }
    for (0..400) |_| moveSlot(world, fighter);
    try std.testing.expectApproxEqAbs(100, mission.slot(fighter).object.velocity.y, 0.5);
    // Without the stats, even a fighter flies by its own.
    for (0..400) |_| moveSlot(mission.world(), other);
    try std.testing.expectApproxEqAbs(320, mission.slot(other).object.velocity.y, 0.5);
}

test "an object travels from step to step" {
    var object = gameobj.testing.object();
    object.velocity = .{ .x = 0, .y = 0, .z = 10 };
    object.rotation = math.identity;
    // Each step commits the place the previous one worked out, then moves on from it.
    for (0..3) |_| {
        gameobj.updateTree(&object.root, null, null);
        move(&object, .{ .own = &gameobj.testing.flight }, .chase, null, null);
    }
    try std.testing.expectEqual(30, object.root.next_position.z);
    // Between steps the committed position is one step behind.
    try std.testing.expectEqual(20, object.root.position.z);
}

test "frozen, unpowered and jumping objects" {
    // A frozen object isn't moved at all.
    var frozen = gameobj.testing.object();
    frozen.velocity = .{ .x = 0, .y = 0, .z = 10 };
    frozen.rotation = math.identity;
    frozen.flags.frozen = true;
    move(&frozen, .{ .own = &gameobj.testing.flight }, .chase, .forward, null);
    try std.testing.expect(!frozen.root.flags.next_pending);
    try std.testing.expectEqual(0, frozen.root.next_position.z);

    // An unpowered one drifts: its motion routine doesn't run, so the throttle doesn't change its
    // velocity.
    var unpowered = gameobj.testing.object();
    unpowered.velocity = .{ .x = 0, .y = 0, .z = 10 };
    unpowered.rotation = math.identity;
    unpowered.throttle = 1;
    unpowered.flags.unpowered = true;
    move(&unpowered, .{ .own = &gameobj.testing.flight }, .chase, .forward, null);
    try std.testing.expectEqual(10, unpowered.velocity.z);
    try std.testing.expectEqual(10, unpowered.root.next_position.z);

    // A jumping one stays where it is until it's knocked.
    var jumping = gameobj.testing.object();
    jumping.velocity = .{ .x = 0, .y = 0, .z = 10 };
    jumping.rotation = math.identity;
    jumping.mass = 1;
    jumping.flags.jumping = true;
    move(&jumping, .{ .own = &gameobj.testing.flight }, .chase, .forward, null);
    try std.testing.expect(jumping.root.flags.next_pending);
    try std.testing.expectEqual(0, jumping.root.next_position.z);
    gameobj.knock(&jumping, .{ 0, 0, 5 }, .{ 0, 0, 0 });
    move(&jumping, .{ .own = &gameobj.testing.flight }, .chase, .forward, null);
    try std.testing.expectEqual(15, jumping.root.next_position.z);
}

test "moving and turning set the network flags" {
    var object = gameobj.testing.object();
    object.rotation = math.identity;
    move(&object, .{ .own = &gameobj.testing.flight }, .chase, null, null);
    try std.testing.expect(!object.network.moved and !object.network.turned);
    object.velocity.z = 1;
    move(&object, .{ .own = &gameobj.testing.flight }, .chase, null, null);
    try std.testing.expect(object.network.moved and !object.network.turned);
    object.yaw_rate = 0.1;
    move(&object, .{ .own = &gameobj.testing.flight }, .chase, null, null);
    try std.testing.expect(object.network.turned);
}

test moveSlot {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const other = try mission.add(.predator, .{ 0, 0, 1000 });
    for ([_]u16{ player, other }) |index| {
        const slot = mission.slot(index);
        slot.motion = null;
        slot.object.rotation = math.identity;
        slot.object.velocity = .{ .x = 0, .y = 0, .z = 640 };
    }
    // Both move on, and only the player's ship, flying past its cruise speed, shakes the camera.
    moveSlot(mission.world(), other);
    try std.testing.expectEqual(1640, mission.slot(other).object.root.next_position.z);
    try std.testing.expectEqual(0, mission.shake);
    moveSlot(mission.world(), player);
    try std.testing.expectEqual(640, mission.slot(player).object.root.next_position.z);
    try std.testing.expect(mission.shake > 0);
    // An object with no flight model is not moved.
    mission.slot(other).flight = null;
    mission.slot(other).object.velocity.z = 10;
    moveSlot(mission.world(), other);
    try std.testing.expectEqual(1640, mission.slot(other).object.root.next_position.z);
}

test "flying faster than the cruise speed shakes the player's camera" {
    var object = gameobj.testing.object();
    object.rotation = math.identity;
    var shake: f32 = 0;
    // At the cruise speed, it doesn't.
    object.velocity.z = 320;
    move(&object, .{ .own = &gameobj.testing.flight }, .chase, null, &shake);
    try std.testing.expectEqual(0, shake);
    // At twice the cruise speed, by 0.2.
    object.velocity.z = 640;
    move(&object, .{ .own = &gameobj.testing.flight }, .chase, null, &shake);
    try std.testing.expectApproxEqAbs(0.2, shake, 1e-6);
    // It never lowers a stronger shake, such as a hit's.
    shake = 1;
    move(&object, .{ .own = &gameobj.testing.flight }, .chase, null, &shake);
    try std.testing.expectEqual(1, shake);
}
