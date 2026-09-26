//! `C:\lancer\game\jump.cpp`: the jumps by which ships come and go. Jump Out (orders 20 and 41)
//! takes a ship away: it turns to where it goes, holds still while its jump charges, and is gone.
//! Where its order names another object, Jump In (orders 19 and 40) then brings it in beside that
//! object, flying in from far behind it. [Jumps](../../../docs/engine/jump.md) describes them.
//!
//! The orders are this file's by the assertion `order_jump_in` makes with its path (`0x004165EC`),
//! which the source map misses, as it lies in a case of a switch
//! ([#310](https://github.com/vdmkenny/openreliant/issues/310)).
//!
//! Not ported: what a jump shows, the trails, the lights, the burst and the flare its effect record
//! holds (`State.effect`, [#309](https://github.com/vdmkenny/openreliant/issues/309)); a countdown
//! Jump Out keeps while the player's ship jumps, which nothing reads (`0x0051D0B0`, `0x0051D0B4`,
//! `0x0051CFA0`, `0x0051D0A4`); and a multiplayer game's jumps
//! ([#55](https://github.com/vdmkenny/openreliant/issues/55)).

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../../engine.zig");
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Order = @import("ai/orders.zig").Order;
const camera = @import("camera.zig");
const cloak = @import("cloak.zig");
const create = @import("create.zig");
const events = @import("mission/events.zig");
const gameobj = @import("gameobj.zig");
const GameObject = gameobj.GameObject;
const objects = @import("objects.zig");
const sound3d = @import("sound3d.zig");

/// What a jump keeps in the object's order state.
pub const State = extern struct {
    _unknown_00: u32,
    /// Its step: `OutStep` for Jump Out, `InStep` for Jump In.
    step: u32,
    /// The frame's tick its step began, from which the jump motions count.
    since: i32,
    /// Where it goes: Jump Out's destination, Jump In's arrival (`placeOut`, `placeIn`).
    destination: shp.Vec3,
    /// How it is turned: Jump Out's as it charges, to which it turns back as it ends; Jump In's its
    /// target's.
    orientation: math.Matrix,
    /// Where it stood as Jump Out began charging, and as Jump In was placed.
    position: shp.Vec3,
    _unknown_48: [8]u8,
    /// The frame's tick of its last update, from which `progress` counts.
    updated: i32,
    /// How far through its step it is, from 0 to past 1.
    progress: f32,
    /// **Unknown.** How many lights its effect has (`0x00417670`), which only the effect reads.
    lights: i32,
    /// Where Jump Out's motion takes it from and to (`motion.Motion.jump_out`).
    from: shp.Vec3,
    to: shp.Vec3,
    /// The motion it puts aside while it flies its own: the routine's address, which OpenReliant
    /// keeps as `create.Slot.motion_aside`.
    motion: engine.Pointer(gameobj.Routine),
    /// Its effect record (`0x0051CFA4`): its trails, lights, burst and flare.
    effect: engine.Pointer(anyopaque),
    /// Whether it jumps out with the player's ship, in formation behind it (`placeOut`).
    with_player: u32,
    _unknown_80: [0x90 - 0x80]u8,

    comptime {
        assert(@offsetOf(State, "step") == 0x04);
        assert(@offsetOf(State, "since") == 0x08);
        assert(@offsetOf(State, "destination") == 0x0C);
        assert(@offsetOf(State, "orientation") == 0x18);
        assert(@offsetOf(State, "position") == 0x3C);
        assert(@offsetOf(State, "updated") == 0x50);
        assert(@offsetOf(State, "progress") == 0x54);
        assert(@offsetOf(State, "lights") == 0x58);
        assert(@offsetOf(State, "from") == 0x5C);
        assert(@offsetOf(State, "to") == 0x68);
        assert(@offsetOf(State, "motion") == 0x74);
        assert(@offsetOf(State, "effect") == 0x78);
        assert(@offsetOf(State, "with_player") == 0x7C);
        assert(@sizeOf(State) == 0x90);
    }

    /// The time since its last update, in thousandths of the mission's ticks, as `progress` counts
    /// it, and this update's tick kept for the next.
    fn elapsed(state: *State, now: i32) f32 {
        const ticks = now -% state.updated;
        state.updated = now;
        return @as(f32, @floatFromInt(ticks)) * time_scale;
    }

    /// Moves on to step `next` at `now`, `progress` from nothing.
    fn advance(state: *State, next: u32, now: i32) void {
        state.step = next;
        state.since = now;
        state.progress = 0;
    }
};

/// Jump Out's steps.
pub const OutStep = enum(u32) {
    /// Turning to face where it goes, or holding its place behind the player's ship.
    aligning = 0,
    /// Held still until the next frame, when its effect begins.
    stilling = 1,
    /// Charging (`charge_rate`).
    charging = 2,
    /// Going: its motion takes it off (`motion.Motion.jump_out`) for `going_ticks`.
    going = 3,
    /// Gone: its flare fades (`flare_rate`).
    gone = 4,
    /// Its end: it jumps in at its target, or leaves the mission.
    ending = 5,
    _,
};

/// Jump In's steps.
pub const InStep = enum(u32) {
    /// Placed far behind where it arrives.
    placing = 0,
    /// Flashing in (`flash_rate`).
    flashing = 1,
    /// Flying in (`motion.Motion.jump_in`), until `fly_rate` has run.
    flying = 2,
    /// In: its order ends, or Jump In's second number first holds it `settle_ticks` in formation.
    settling = 3,
    _,
};

/// A jump's `progress` for each of the mission's ticks, by the step's rate (`0x004DC418`).
const time_scale: f32 = 0.001;

/// How still a ship turning to face where it jumps must be before it goes: its rates and its
/// steering inputs no more than these (`0x004DC474`, `0x004DC4AC`).
const aligned_rate: f32 = 0.05;
const aligned_input: f32 = 0.02;

/// How hard it steers to face where it jumps (`0x004DC410`).
const aligning_limit: f32 = 0.8;

/// How long a ship of the player's wing turns to face its jump before it goes anyway, and how long
/// a ship jumping with the player's holds its place, in ticks.
const wing_patience = 1000;
const formation_wait = 100;

/// How fast Jump Out charges, and how fast its effect fades as it goes (`0x004DC400`,
/// `0x004DC424`).
const charge_rate: f32 = 6;
const going_rate: f32 = 4;

/// How long Jump Out's motion takes the ship off, in ticks (`0x004DC448`), which the motion's
/// pace matches (`motion.jump_out_pace`).
pub const going_ticks = 250;

/// How fast Jump Out's flare fades once the ship has gone (`0x004DC520`).
const flare_rate: f32 = 10;

/// How far along its way a ship goes as Jump Out's motion takes it off.
const going_reach: f32 = 500000;

/// How far ahead a ship aims when its Jump Out names nothing, alone, and in the player's
/// formation.
const nowhere_reach: f32 = 1e7;
const formation_reach: f32 = 100000;

/// The player's formation (`placeOut`): rows `formation_spacing` apart behind the player's ship,
/// each a ship wider than the last, at most `formation_rows`, flying `formation_speed` ahead
/// (`0x004DC594`); and how far ahead of it a ship in its way is marked as jumping.
const formation_spacing: f32 = 3000;
const formation_rows = 10;
const formation_speed: f32 = 150;
const clearing_reach: f32 = 500000;

/// The depth a ship that leaves the mission is put at, far below everything.
const gone_depth: f32 = -9.9e6;

/// How far behind where it arrives a ship is placed to fly in from: one that lists components, and
/// any other.
const arrival_distance_components: f32 = 100000;
const arrival_distance: f32 = 25000;

/// How far apart abreast the ships of a group arrive (`0x004DC508`).
const arrival_spacing: f32 = 3000;

/// How fast Jump In flashes, and flies in (`0x004DC48C`, `0x004DC3D8`).
const flash_rate: f32 = 50;
const fly_rate: f32 = 3;

/// How long Jump In's second number holds its formation once in, in ticks.
const settle_ticks = 200;

/// The share of a steering input a ship of Jump In's second number rolls and pitches by for each
/// place along its formation (`0x004DC408`).
const settle_input: f32 = 0.5;

/// `order_jump_out_init` (`0x00416D50`): the ship in slot `index` jumps out. Its throttle goes, it
/// is placed for its jump (`placeOut`), and it is heard (`jumponline`, among the player's own
/// sounds for the player's ship, whose camera watches it from the jump's view, locked). A player's
/// ship uncloaks.
pub fn outInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.jump;
    slot.object.throttle = 0;
    state.step = @intFromEnum(OutStep.aligning);
    state.since = ctx.clock.frame_start;
    state.with_player = 0;
    placeOut(ctx, index);
    sound3d.playIn(world, null, null, index, .jumponline, 1, soundClass(all, index));
    if (index == all.player) if (world.camera) |view| {
        _ = view.setJump(.jump_out, index, ctx.clock.viewTime(), .of(slot), .of(slot));
    };
    if (index < all.players) cloak.set(world, index, false);
}

/// The class a jump's sounds take: the player's own effects for the player's ship.
fn soundClass(all: *const create.Objects, index: u16) sound3d.Class {
    return if (index == all.player) .player_fx else .not_reserved;
}

/// `order_jump_out` (`0x00416E00`): Jump Out's update, a step at a time (`OutStep`). Every update of
/// the player's ship clears the jump the mission has ready (`jump_ready`).
///
/// It turns to face where it goes, until its rates and inputs are still (`aligned`), a ship of the
/// player's wing no longer than `wing_patience`; one jumping with the player's holds its place for
/// `formation_wait` instead. Then it is heard (`jumpout`), and held still until the next frame, when
/// its course is set (`beginCourse`). It charges, and at full charge goes: its motion takes it off,
/// colliding with nothing, drawn at its finest (`showFinest`), for `going_ticks`. Then it flies
/// ahead again, jumping, while its flare fades, and collides again.
///
/// At its end it is turned back as it was, powered and free to move, flies its own motion again,
/// and draws as it did. The player's jump ends every object's jumping. A jump that names another
/// object gives way to Jump In at it, of the matching number and the same place among its group;
/// one that names none leaves the mission: the ship stops jumping, is disabled, but for a player's
/// ship in the multiplayer game's way (`GameObject.Flags._unknown_28`), and is put far below where
/// it went, its order done.
///
/// Not ported: the Boridin's breakaway letting go of its core's sprite as it charges.
pub fn outUpdate(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.jump;
    const now = ctx.clock.frame_start;
    const dt = state.elapsed(now);
    object.nova_charge = 0;
    if (index == all.player) if (world.events) |waiting| {
        waiting.script.variables.ready.jump = .no;
    };
    switch (@as(OutStep, @enumFromInt(state.step))) {
        .aligning => {
            if (state.with_player == 0) {
                _ = ai.steer(world, index, gameobj.vector(state.destination), aligning_limit, ai.no_ease, .{});
                const waited = now >= state.since + wing_patience and object.wing == .player;
                if (!waited and !aligned(object)) return;
            } else if (now < state.since + formation_wait) return;
            state.step = @intFromEnum(OutStep.stilling);
            state.since = now;
            sound3d.playIn(world, null, null, index, .jumpout, 1, soundClass(all, index));
        },
        .stilling => {
            object.yaw_input = 0;
            object.pitch_input = 0;
            object.roll_input = 0;
            object.speed = 0;
            object.yaw_rate = 0;
            object.pitch_rate = 0;
            object.roll_rate = 0;
            object.rotation = math.identity;
            if (now <= state.since) return;
            beginCourse(slot);
            state.progress = 0;
            state.step = @intFromEnum(OutStep.charging);
        },
        .charging => {
            if (state.progress > 1) {
                slot.motion_aside = slot.motion;
                slot.motion = .jump_out;
                object.flags.no_collisions = true;
                state.advance(@intFromEnum(OutStep.going), now);
                if (slot.model) |*model| showFinest(model, true);
                state.from = object.root.position;
                return;
            }
            state.progress += dt * charge_rate;
        },
        .going => {
            if (state.since + going_ticks < now) {
                slot.motion = .forward;
                object.flags.jumping = true;
                state.progress = 0;
                state.step = @intFromEnum(OutStep.gone);
                return;
            }
            state.progress += dt * going_rate;
        },
        .gone => {
            state.progress += dt * flare_rate;
            if (state.progress >= 1) {
                state.progress = 0;
                state.step = @intFromEnum(OutStep.ending);
                object.flags.no_collisions = false;
            }
        },
        .ending => end(ctx, index),
        _ => {},
    }
}

/// Whether a ship turning to face where it jumps has come to rest: each of its rates within
/// `aligned_rate`, and each of its steering inputs within `aligned_input`.
fn aligned(object: *const GameObject) bool {
    for ([_]f32{ object.yaw_rate, object.pitch_rate, object.roll_rate }) |rate| {
        if (@abs(rate) > aligned_rate) return false;
    }
    for ([_]f32{ object.yaw_input, object.pitch_input, object.roll_input }) |input| {
        if (@abs(input) > aligned_input) return false;
    }
    return true;
}

/// Jump Out's end, as `outUpdate` describes it.
fn end(ctx: aigeneric.Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.jump;
    objects.setOrientation(object, &slot.drawn, state.orientation);
    object.flags.unpowered = false;
    object.flags.frozen = false;
    slot.motion = slot.motion_aside;
    const entry = slot.orders[0];
    if (index == all.player) {
        for (all.slots[0..all.count]) |*each| each.object.flags.jumping = false;
    }
    if (slot.model) |*model| showFinest(model, false);
    if (entry.target.slotIn(all)) |target| if (target != index) {
        const next: Order = if (entry.order == .jump_out_41) .jump_in_40 else .jump_in;
        _ = aigeneric.pop(ctx, index);
        const pushed = aigeneric.pushShip(ctx, index, next, target, aigeneric.Target.whole) catch false;
        if (pushed) slot.orders[0].sequence = entry.sequence;
        return;
    };
    object.flags.jumping = false;
    if (index != all.player or !object.flags._unknown_28) object.flags.disabled = true;
    state.destination.y = gone_depth;
    objects.setPosition(object, &slot.drawn, gameobj.vector(state.destination));
    _ = aigeneric.pop(ctx, index);
}

/// The first part of `0x00417670`, Jump Out's effect's start, which sets the ship's course: it
/// keeps how it is turned and where it stands, and aims its motion `going_reach` along the way to
/// its destination (`State.to`).
fn beginCourse(slot: *create.Slot) void {
    const object = &slot.object;
    const state = &slot.state.jump;
    state.orientation = object.root.orientation;
    state.position = object.root.position;
    const here = slot.drawn.position;
    const way = math.normalize(gameobj.vector(state.destination) - here);
    state.to = gameobj.vec3(way * @as(Vector, @splat(going_reach)) + here);
}

/// `0x00417DC0`: each part of `model`, and of each model mounted on it, drawn at its finest, or
/// by its distance again (`srapiext.ObjectFlags.finest`).
fn showFinest(model: *objects.Model, finest: bool) void {
    for (model.parts, 0..) |*part, at| {
        part.object.flags.finest = finest;
        var mounts = model.carriedBy(at);
        while (mounts.next()) |mount| showFinest(&mount.model, finest);
    }
}

/// `0x004184F0`: where the ship in slot `index` jumps out to. Where the player's ship jumps out
/// at the same target, the ship goes with it: it collides with nothing and takes its place in a
/// formation behind the player's ship, facing the target, or `formation_reach` ahead of the
/// player's ship where the order names nothing or the player's ship itself. Row `n` of the
/// formation stands `n` times `formation_spacing` behind, and holds `n` ships abreast, the
/// order's place among its group's (`aigeneric.Entry.sequence`) picking the row and the place in
/// it. The ship flies `formation_speed` ahead there, and each object in the way `clearing_reach`
/// ahead of it, but those jumping with it, is marked jumping (`markJumping`). Otherwise the ship
/// goes to its target, or `nowhere_reach` ahead of it where it names nothing or itself.
///
/// Not ported: in a multiplayer game, the formation of the player whose game it is.
fn placeOut(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.jump;
    const entry = slot.orders[0];
    const player = &all.slots[all.player];
    const leading = player.object.order_count > 0 and player.orders[0].order == .jump_out and entry.target.index == player.orders[0].target.index;
    const named = entry.target.slotIn(all);
    if (!leading) {
        if (named) |target| if (target != index) {
            state.destination = all.slots[target].object.root.next_position;
            return;
        };
        state.destination = gameobj.vec3(ahead(slot.object, nowhere_reach));
        return;
    }
    slot.object.flags.no_collisions = true;
    state.with_player = 1;
    const from = gameobj.vector(player.object.root.next_position);
    // The player's ship jumps at the same target.
    const to = if (named) |target| if (target != all.player)
        gameobj.vector(all.slots[target].object.root.next_position)
    else
        ahead(player.object, formation_reach) else ahead(player.object, formation_reach);
    const facing = math.lookAt(to - from);
    state.destination = gameobj.vec3(to);
    var row: i32 = 1;
    var place: i32 = entry.sequence;
    while (row < formation_rows) : (row += 1) {
        if (place < row) {
            const across = @as(f32, @floatFromInt(place)) - (@as(f32, @floatFromInt(row)) - 1) * 0.5;
            const offset: Vector = .{ across + across, 0, @floatFromInt(-row) };
            const at = math.transform(facing, offset * @as(Vector, @splat(formation_spacing))) + from;
            objects.setOrientation(&slot.object, &slot.drawn, facing);
            objects.setPosition(&slot.object, &slot.drawn, at);
            ai.stop(&slot.object);
            slot.object.velocity = gameobj.vec3(math.transform(slot.object.root.next_orientation, .{ 0, 0, formation_speed }));
            if (slot.flight) |flight| slot.object.throttle = formation_speed / ai.cruiseSpeed(&slot.object, flight, world.view);
            break;
        }
        place -= row;
    }
    const start = gameobj.vector(slot.object.root.next_position);
    const end_at = start + math.forward(slot.object.root.next_orientation) * @as(Vector, @splat(clearing_reach));
    for (all.slots[0..all.count], 0..) |*other, at| {
        if (other.object.flags.outOfFrame()) continue;
        const going_too = other.object.order_count > 0 and other.orders[0].order == .jump_out and other.orders[0].target.index == entry.target.index;
        if (going_too) continue;
        const model = if (other.model) |*live| live else continue;
        if (objects.Box.ofBounds(model, other.drawn).meetsSegment(start, end_at)) markJumping(all, @intCast(at));
    }
}

/// A point `reach` ahead of `object`'s next place, along its next heading.
fn ahead(object: GameObject, reach: f32) Vector {
    return math.forward(object.root.next_orientation) * @as(Vector, @splat(reach)) + gameobj.vector(object.root.next_position);
}

/// `0x00418470`: the object in slot `index`, in the way of a jump, is marked jumping, which holds
/// it where it is and leaves it out of the frame until the player's jump ends; so is each fuel
/// pod, and each ship launching from the object or docking with it, and those in turn.
fn markJumping(all: *create.Objects, index: u16) void {
    all.slots[index].object.flags.jumping = true;
    for (all.slots[0..all.count], 0..) |*other, at| {
        if (other.object.flags.outOfFrame()) continue;
        const follows = other.object.order_count > 0 and other.orders[0].target.slot() == index and switch (other.orders[0].order) {
            .launch, .dock => true,
            else => false,
        };
        if (other.object.type == .fuel_pod or follows) markJumping(all, @intCast(at));
    }
}

/// `order_jump_in_init` (`0x00416540`): the ship in slot `index` jumps in, colliding with nothing
/// and jumping, at its place beside its target (`placeIn`).
pub fn inInit(ctx: aigeneric.Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.object.flags.no_collisions = true;
    slot.object.flags.jumping = true;
    placeIn(ctx.world.objects, index);
    slot.state.jump.step = @intFromEnum(InStep.placing);
}

/// `0x00418850`: where the ship in slot `index` arrives: abreast of its target, turned as the
/// target is, the order's place among its group's putting it `arrival_spacing` apart on either
/// side in turn: the first at the target, the second to its left, the third to its right, and so
/// on.
fn placeIn(all: *create.Objects, index: u16) void {
    const slot = &all.slots[index];
    const target = slot.orders[0].target.slotIn(all) orelse return;
    const beside = &all.slots[target].drawn;
    const n = @as(i32, slot.orders[0].sequence) + 1;
    const side: i32 = if (@rem(n, 2) != 0) 1 else -1;
    const across = @as(f32, @floatFromInt(side * @divTrunc(n, 2))) * arrival_spacing;
    slot.state.jump.destination = gameobj.vec3(math.transform(beside.orientation, .{ across, 0, 0 }) + beside.position);
}

/// `order_jump_in` (`0x00416570`): Jump In's update, a step at a time (`InStep`).
///
/// It is turned as its target is, and placed far behind where it arrives, stopped:
/// `arrival_distance`, or `arrival_distance_components` for a ship that lists components. It is
/// heard (`jumpin`); for the player's ship, the camera watches from one of the arrival's three
/// views at random, the mission's space takes on what its script asked of it
/// (`environfx.Environment.update`), and the stars streak shorter (`srstars`). It flashes in, and
/// then flies in by its motion, no longer jumping, the player's view shaking less and less, until
/// it flies ahead again at full throttle, colliding again, powered and free to move. Then its
/// order ends: for the player's ship the camera goes back to the cockpit, and its JumpedIn event
/// is posted (`events.jumpedIn`). A ship of Jump In's second number first holds `settle_ticks` in
/// its formation, rolling and pitching by its place in it.
///
/// Not ported: in a multiplayer game, the JumpedIn posted for the first player's ship too as the
/// ship of the first player still flying jumps in.
pub fn inUpdate(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.jump;
    const now = ctx.clock.frame_start;
    const dt = state.elapsed(now);
    object.nova_charge = 0;
    switch (@as(InStep, @enumFromInt(state.step))) {
        .placing => {
            const target = slot.orders[0].target.slotIn(all) orelse return;
            state.orientation = all.slots[target].drawn.orientation;
            state.position = object.root.position;
            objects.setOrientation(object, &slot.drawn, state.orientation);
            objects.setPosition(object, &slot.drawn, gameobj.vector(state.destination));
            ai.stop(object);
            const back = if (object.flags.components) arrival_distance_components else arrival_distance;
            const start = math.forward(state.orientation) * @as(Vector, @splat(-back)) + gameobj.vector(object.root.position);
            objects.setPosition(object, &slot.drawn, start);
            state.advance(@intFromEnum(InStep.flashing), now);
            sound3d.playIn(world, null, null, index, .jumpin, 1, soundClass(all, index));
            if (index == all.player) {
                if (world.camera) |view| {
                    const pick = arrivalView(world.random.rand());
                    _ = view.setJump(pick, index, ctx.clock.viewTime(), .of(slot), .of(&all.slots[all.player]));
                }
                if (world.environment) |space| space.update();
                world.player.jumping_in = true;
            }
        },
        .flashing => {
            state.progress += dt * flash_rate;
            if (state.progress > 1) {
                state.progress = 0;
                state.step = @intFromEnum(InStep.flying);
                slot.motion_aside = slot.motion;
                slot.motion = .jump_in;
                object.flags.jumping = false;
            }
        },
        .flying => {
            if (index == all.player) world.shake.* = math.lerp(@as(f32, 1), 0, state.progress);
            state.progress += dt * fly_rate;
            if (!(state.progress > 1)) return;
            slot.motion = slot.motion_aside;
            object.throttle = 1;
            state.progress = 0;
            state.step = @intFromEnum(InStep.settling);
            state.since = now + settle_ticks;
            world.player.jumping_in = false;
            object.flags.no_collisions = false;
            object.flags.unpowered = false;
            object.flags.frozen = false;
        },
        .settling => {
            const entry = slot.orders[0];
            if (entry.order != .jump_in_40 or state.since <= now) {
                if (index == all.player) if (world.camera) |view| {
                    _ = view.setView(.cockpit, index, false, true, ctx.clock.viewTime());
                };
                _ = aigeneric.pop(ctx, index);
                events.jumpedIn(world, index);
                return;
            }
            const n = @as(i32, entry.sequence) + 1;
            const side: i32 = if (@rem(n, 2) != 0) 1 else -1;
            object.roll_input = @as(f32, @floatFromInt(side * @divTrunc(n, 2))) * settle_input;
            object.pitch_input = @as(f32, @floatFromInt(@divTrunc(n, 2))) * settle_input;
        },
        _ => {},
    }
}

/// The view the player's arrival is watched from, by the C runtime's `rand` (`random`): twice its
/// share of the most `rand` gives, rounded (`sr_round`), picks one of three, the middle one half
/// the time.
fn arrivalView(random: u15) camera.View {
    const share = @as(f32, @floatFromInt(random)) * rand_scale;
    return switch (math.round(share + share)) {
        0 => .jump_in_close,
        1 => .jump_in_ahead,
        else => .jump_in_aside,
    };
}

/// A share of the most the C runtime's `rand` gives (`0x004DC4C8`).
const rand_scale: f32 = 1.0 / 32767.0;

/// How long a test's frames are, in ticks.
const test_frame = 10;

/// Moves the test mission's clock on by a frame and runs the orders of the ship in slot `index`.
fn nextFrame(mission: *gameobj.testing.Mission, ctx: aigeneric.Context, index: u16) void {
    mission.clock.frame_start += test_frame;
    mission.clock.mission_ticks = mission.clock.frame_start;
    mission.clock.frame_duration = test_frame;
    aigeneric.objectOrders(ctx, index);
}

/// The step the jump of the ship in `slot` is at.
fn stepOf(comptime Step: type, slot: *const create.Slot) Step {
    return @enumFromInt(slot.state.jump.step);
}

fn expectVector(expected: Vector, actual: Vector) !void {
    inline for (0..3) |i| try std.testing.expectApproxEqAbs(expected[i], actual[i], 1e-2);
}

test "a jump out that names nothing leaves the mission" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.predator, .{ 0, 0, 10000 });
    const slot = mission.slot(ship);
    slot.motion = .forward;
    slot.object.throttle = 1;
    const ctx = mission.orders();
    _ = try aigeneric.push(ctx, ship, .jump_out, .none);
    nextFrame(&mission, ctx, ship);
    // It lets its throttle go and aims far ahead, which it faces already, so it holds still.
    try std.testing.expectEqual(0, slot.object.throttle);
    try expectVector(.{ 0, 0, 10000 + nowhere_reach }, gameobj.vector(slot.state.jump.destination));
    try std.testing.expectEqual(OutStep.stilling, stepOf(OutStep, slot));
    // It charges, then goes by its own motion, colliding with nothing.
    while (slot.motion != .jump_out) nextFrame(&mission, ctx, ship);
    try std.testing.expectEqual(.forward, slot.motion_aside);
    try std.testing.expect(slot.object.flags.no_collisions);
    try expectVector(.{ 0, 0, 10000 + going_reach }, gameobj.vector(slot.state.jump.to));
    // Gone, it flies ahead, jumping, and then leaves the mission, far below.
    while (stepOf(OutStep, slot) == .going) nextFrame(&mission, ctx, ship);
    try std.testing.expectEqual(.forward, slot.motion);
    try std.testing.expect(slot.object.flags.jumping);
    while (slot.object.order_count > 0) nextFrame(&mission, ctx, ship);
    try std.testing.expect(slot.object.flags.disabled);
    try std.testing.expect(!slot.object.flags.jumping);
    try std.testing.expect(!slot.object.flags.no_collisions);
    try std.testing.expectEqual(gone_depth, slot.object.root.position.y);
}

test "a jump out that names a ship gives way to a jump in beside it" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const target = try mission.add(.predator, .{ 0, 0, 80000 });
    const turned = math.rotation(.y, std.math.pi / 2.0);
    objects.setOrientation(&mission.slot(target).object, &mission.slot(target).drawn, turned);
    const ship = try mission.add(.predator, .{ 0, 0, 10000 });
    const slot = mission.slot(ship);
    slot.motion = .forward;
    const ctx = mission.orders();
    _ = try aigeneric.pushShip(ctx, ship, .jump_out_41, target, aigeneric.Target.whole);
    slot.orders[0].sequence = 1;
    while (slot.orders[0].order == .jump_out_41) nextFrame(&mission, ctx, ship);
    // Jump In of the matching number takes over, at the same place in the group.
    try std.testing.expectEqual(Order.jump_in_40, slot.orders[0].order);
    try std.testing.expectEqual(1, slot.orders[0].sequence);
    try std.testing.expectEqual(target, slot.orders[0].target.slot());
    try std.testing.expect(!slot.object.flags.disabled);

    // It arrives to the target's left, turned as the target is, and is placed far behind that to
    // fly in from.
    nextFrame(&mission, ctx, ship);
    const arrival = mission.slot(target).drawn.point(.{ -arrival_spacing, 0, 0 });
    try expectVector(arrival, gameobj.vector(slot.state.jump.destination));
    try expectVector(arrival - math.forward(turned) * @as(Vector, @splat(arrival_distance)), slot.drawn.position);
    try std.testing.expectEqual(turned, slot.drawn.orientation);
    try std.testing.expect(slot.object.flags.jumping);
    try std.testing.expect(slot.object.flags.no_collisions);
    // It flashes in, then flies in by its own motion, no longer jumping.
    while (slot.motion != .jump_in) nextFrame(&mission, ctx, ship);
    try std.testing.expect(!slot.object.flags.jumping);
    // Once in, it flies ahead again at full throttle, colliding again, and holds its place in the
    // formation a while, rolling and pitching by it, before its order ends.
    while (stepOf(InStep, slot) == .flying) nextFrame(&mission, ctx, ship);
    try std.testing.expectEqual(.forward, slot.motion);
    try std.testing.expectEqual(1, slot.object.throttle);
    try std.testing.expect(!slot.object.flags.no_collisions);
    nextFrame(&mission, ctx, ship);
    try std.testing.expectEqual(-settle_input, slot.object.roll_input);
    try std.testing.expectEqual(settle_input, slot.object.pitch_input);
    const settled = mission.clock.frame_start;
    while (slot.object.order_count > 0) nextFrame(&mission, ctx, ship);
    try std.testing.expect(mission.clock.frame_start >= settled + settle_ticks - test_frame);
}

test "the player's arrival is watched from a cutaway, and ends in the cockpit" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const target = try mission.add(.predator, .{ 0, 0, 80000 });
    const slot = mission.slot(player);
    slot.motion = .forward;
    var view: camera.Camera = .{};
    var ctx = mission.orders();
    ctx.world.camera = &view;
    _ = try aigeneric.pushShip(ctx, player, .jump_in, target, aigeneric.Target.whole);
    nextFrame(&mission, ctx, player);
    try std.testing.expect(switch (view.view) {
        .jump_in_close, .jump_in_ahead, .jump_in_aside => true,
        else => false,
    });
    try std.testing.expect(view.locked);
    try std.testing.expect(mission.player.jumping_in);
    // As it flies in, the view shakes less and less.
    while (stepOf(InStep, slot) != .flying) nextFrame(&mission, ctx, player);
    nextFrame(&mission, ctx, player);
    try std.testing.expectEqual(1, mission.shake);
    nextFrame(&mission, ctx, player);
    try std.testing.expect(mission.shake < 1);
    while (slot.object.order_count > 0) nextFrame(&mission, ctx, player);
    try std.testing.expect(!mission.player.jumping_in);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expect(!view.locked);
}

test "the ships that jump out with the player's form up behind it" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const target = try mission.add(.predator, .{ 0, 0, 100000 });
    const wing = [_]u16{ try mission.add(.predator, .{ 5000, 0, 0 }), try mission.add(.predator, .{ -5000, 0, 0 }) };
    const ctx = mission.orders();
    for ([_]u16{ player, wing[0], wing[1] }, 0..) |index, sequence| {
        _ = try aigeneric.pushShip(ctx, index, .jump_out, target, aigeneric.Target.whole);
        mission.slot(index).orders[0].sequence = @intCast(sequence);
    }
    mission.clock.frame_start = test_frame;
    for ([_]u16{ player, wing[0], wing[1] }) |index| aigeneric.objectOrders(ctx, index);
    // The player's ship leads, a row ahead of the next, which holds two abreast.
    try expectVector(.{ 0, 0, -formation_spacing }, mission.slot(player).drawn.position);
    try expectVector(.{ -formation_spacing, 0, -3 * formation_spacing }, mission.slot(wing[0]).drawn.position);
    try expectVector(.{ formation_spacing, 0, -3 * formation_spacing }, mission.slot(wing[1]).drawn.position);
    for (wing) |index| {
        const slot = mission.slot(index);
        try std.testing.expectEqual(1, slot.state.jump.with_player);
        try std.testing.expect(slot.object.flags.no_collisions);
        try std.testing.expectEqual(formation_speed, slot.object.velocity.z);
        try std.testing.expectEqual(formation_speed / gameobj.testing.flight.max_speed, slot.object.throttle);
        try expectVector(.{ 0, 0, 100000 }, gameobj.vector(slot.state.jump.destination));
    }
    // They hold their places a while before they go.
    for (0..formation_wait / test_frame - 1) |_| nextFrame(&mission, ctx, wing[0]);
    try std.testing.expectEqual(OutStep.aligning, stepOf(OutStep, mission.slot(wing[0])));
    nextFrame(&mission, ctx, wing[0]);
    try std.testing.expectEqual(OutStep.stilling, stepOf(OutStep, mission.slot(wing[0])));
}

test markJumping {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const base = try mission.add(.predator, .{ 0, 0, 5000 });
    const launching = try mission.add(.predator, .{ 0, 0, 5000 });
    const pod = try mission.add(.predator, .{ 90000, 0, 0 });
    mission.slot(pod).object.type = .fuel_pod;
    const other = try mission.add(.predator, .{ 0, 0, 9000 });
    _ = try aigeneric.pushShip(mission.orders(), launching, .launch, base, aigeneric.Target.whole);
    // What is in the way holds, with what launches from it, and every fuel pod.
    markJumping(mission.objects, base);
    for ([_]u16{ base, launching, pod }) |index| try std.testing.expect(mission.slot(index).object.flags.jumping);
    try std.testing.expect(!mission.slot(other).object.flags.jumping);
}

test arrivalView {
    // A quarter of the time the close view, half the time the view ahead, and a quarter the view
    // aside.
    try std.testing.expectEqual(camera.View.jump_in_close, arrivalView(0));
    try std.testing.expectEqual(camera.View.jump_in_close, arrivalView(8191));
    try std.testing.expectEqual(camera.View.jump_in_ahead, arrivalView(8192));
    try std.testing.expectEqual(camera.View.jump_in_ahead, arrivalView(24575));
    try std.testing.expectEqual(camera.View.jump_in_aside, arrivalView(24576));
    try std.testing.expectEqual(camera.View.jump_in_aside, arrivalView(32767));
}
