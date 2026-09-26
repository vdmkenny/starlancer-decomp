//! The orders of a pilot's ejection: Eject (30), the Eject that ends the ship a pilot has left
//! (106), Eject Spin (108), Eject Fighter Attack (113) and Eject Player (118). `object_destroyed`
//! ([`ai.zig`](ai.zig)) gives the player's ship Eject Player and an AI ship Eject Spin, and EJECT
//! (`input.eject`) gives the player's ship Eject. Scoop Up (107), by which a ship picks the
//! player's pod up, is [`tractor.zig`](tractor.zig)'s. **Unknown:** its source file. The code lies
//! after `airipper.cpp`'s and before `jump.cpp`'s, and no string places it; this module is named
//! for its orders. [`ejection.md`](../../../docs/engine/ejection.md) describes the ejection.

const std = @import("std");
const assert = std.debug.assert;

const dte = @import("../../formats/dte.zig");
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const orders = @import("ai/orders.zig");
const Ending = @import("main.zig").Ending;
const Context = aigeneric.Context;
const camera = @import("camera.zig");
const create = @import("create.zig");
const events = @import("mission/events.zig");
const explode = @import("explode.zig");
const gameobj = @import("gameobj.zig");
const guns = @import("guns.zig");
const objects = @import("objects.zig");
const particles = @import("particles.zig");
const sound3d = @import("sound3d.zig");
const srmesh = @import("../surrender/surrenderlib/srmesh.zig");

/// What Eject Player keeps in the object's order state.
pub const PlayerState = extern struct {
    /// The tick after which the ship blows up.
    end: i32,
    /// How often the ship has reached its end: `object_destroyed` pops the order once it has.
    ended: i32,
    _unknown_08: [0x90 - 0x08]u8,

    comptime {
        assert(@offsetOf(PlayerState, "ended") == 0x4);
        assert(@sizeOf(PlayerState) == 0x90);
    }
};

/// What Eject, Eject Spin, the Eject that ends a ship its pilot has left (106) and Eject Fighter
/// Attack keep in the object's order state: when the present stage ends, which stage it is, and the
/// ship's invulnerability as its pilot ejected, which the pod has back once it is clear.
pub const State = extern struct {
    until: i32,
    stage: Stage,
    invulnerable: gameobj.Invulnerability,
    _unknown_09: [0x90 - 0x09]u8,

    comptime {
        assert(@offsetOf(State, "stage") == 0x4);
        assert(@offsetOf(State, "invulnerable") == 0x8);
        assert(@sizeOf(State) == 0x90);
    }
};

/// The stages of the pilot's pod under Eject (`order_eject`).
pub const Stage = enum(i32) {
    /// Shooting clear of the ship.
    clearing = 0,
    /// An AI pilot's pod, adrift for good.
    adrift = 1,
    /// The player's pod, adrift until the pilot calls.
    drifting = 2,
    /// The pilot has called, and waits to be picked up.
    called = 3,
    /// The pickup under way, as the camera watches.
    picked_up = 4,
    _,
};

// --- Eject ---------------------------------------------------------------------------------

/// `order_eject_init` (`0x00415BD0`): the pilot ejects, where the ship has a cockpit to leave in:
/// the first part at its root of that class, which leaves the ship as the pilot's pod
/// (`separate`). The ship's Destroyed event is posted (`events.destroyed`).
///
/// Not ported: a wingman's call on the radio as the pilot ejects, and the rescue's word a thousand
/// ticks later (`radio_wingman_ejected`, `0x00456D80`), which wait for the radio
/// ([#48](https://github.com/vdmkenny/openreliant/issues/48)); and a multiplayer game, in which
/// nobody ejects so.
pub fn init(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const model = if (slot.model) |*live| live else return;
    const cockpit = for (model.parts, 0..) |part, at| {
        if (part.parent == null and part.class == .cockpit) break at;
    } else return;
    separate(ctx, index, cockpit);
    events.destroyed(ctx.world, index, dte.Trigger.whole_object);
}

/// How long the pod takes to shoot clear of its ship (`0x00415BB5`), and to drift before the pilot
/// calls, and how long after the call the pickup comes, in ticks.
const clearing_ticks = 100;
const drifting_ticks = 100;
const calling_ticks = 500;

/// How fast the ship its pilot has left starts to tumble: this pitch, and up to half of
/// `tumble_most` of yaw and roll either way, a step (`0x004158CB`, `0x004DC518`).
const tumble_pitch: f32 = 0.02;
const tumble_most: f32 = 0.01;

/// How fast the pod shoots out along its eject point, a tick, and how much of the ship's velocity
/// the flash carries (`0x00415B9B`, `0x00415B4A`).
const kick: f32 = 50;
const flash_carried: f32 = 0.25;

/// The flash of the pilot's ejection (`eject_flash_template`, `0x0051CF94`, which `eject_init`,
/// `0x00415610`, makes as the renderer starts): puffs of half a second to a second, growing to 100
/// across, from yellow to orange to nothing, sent out in a burst of `flash_count` (`0x00415B60`),
/// flattened across the eject point's axis (`0x00415B22`), at `flash_speed` and up to
/// `flash_speed_range` more a tick (`0x00415B3C`, `0x00415B51`).
const flash: particles.Template = .{
    .life = 50,
    .life_spread = 50,
    .size = .through(0, 50, 100),
    .colour = .{ .through(1, 0.75, 0), .through(1, 0.25, 0), .through(0, 0, 0) },
};
const flash_count = 100;
const flash_spread: Vector = .{ 1, 1, 0.2 };
const flash_speed: f32 = 20;
const flash_speed_range: f32 = 5;

/// `eject_separate` (`0x004156C0`): the cockpit, part `cockpit` of the ship in slot `index`, leaves
/// the ship as the pilot's pod. The ship becomes an object of its own, of its type, with every part
/// but the cockpit: neither targetable nor powered, tumbling a little as it drifts, and destroyed
/// soon after (Eject, 106), `EJECT01` heard from it. The pod keeps the ship's slot and the cockpit
/// alone: its smoke, guns, missiles, shields and armour gone, nothing able to harm it, and no
/// flight of its own until it is clear. Each part at either object's root shows its cap faces
/// (`srmesh.caps_hidden`), so the cockpit closes beneath into a pod, and the ship where it left. A
/// flash goes off at the cockpit's eject point, and the pod shoots out along it.
///
/// The game moves the parts' nodes from the one object to the other. OpenReliant gives the new
/// object the ship's model, as it stands, and the pod a new one of the same type, and takes out of
/// each the parts the other has (`objects.destroyPart`), which each then recentres on
/// (`gameobj.recentreObject`).
///
/// Not ported: the smoke trail from the eject point, a hit's effect of kind 4, which the game never
/// draws either (`shieldfx.componentHit`).
fn separate(ctx: Context, index: u16, cockpit: usize) void {
    const world = ctx.world;
    const all = world.objects;
    const now = ctx.clock.frame_start;
    const pod = &all.slots[index];
    const state = &pod.state.eject;
    state.invulnerable = pod.object.invulnerable;
    const spawn = world.spawn orelse return;
    const left = create.createObject(all, spawn.tables, spawn.types, null, pod.object.type, 0, @splat(0), world.random) catch return;
    const ship = &all.slots[left];
    _ = aigeneric.pushShip(ctx, left, .eject_106, index, aigeneric.Target.whole) catch false;
    pod.smoke = null;
    pod.object.smoke_level = .none;
    ship.object.flags = .{ .ejected = true, ._unknown_24 = true };
    ship.object.side = .neutral;
    ship.object.passes_through[0] = .of(index);
    ship.object.shield_factor = 0;
    ship.motion = .drift;
    // The ship has the model it flew with; the pod a new one of the same.
    std.mem.swap(?objects.Model, &pod.model, &ship.model);
    for ([_]*create.Slot{ pod, ship }) |gunless| gunless.dropGuns(all.gpa);
    if (ship.shield) |bubble| bubble.destroy(all.gpa);
    ship.shield = null;
    ship.drawn = pod.drawn;
    ship.object.root.position = pod.object.root.position;
    ship.object.root.next_position = pod.object.root.next_position;
    ship.object.root.orientation = pod.object.root.orientation;
    ship.object.root.next_orientation = pod.object.root.next_orientation;
    ship.object.velocity = pod.object.velocity;
    ship.object.rotation = pod.object.rotation;
    sound3d.playIn(world, null, null, left, .eject01, 1, if (index == all.player) .guaranteed else .not_reserved);

    const object = &pod.object;
    object.flags.unpowered = true;
    object.flags.ejected = true;
    object.passes_through[0] = .of(left);
    pod.orders[0].target.index = @intCast(left);
    object.rack_count = 0;
    object.shield_factor = 0;
    object.shields = .all(0);
    object.armor = .all(0);
    pod.motion = null;
    object.invulnerable = .full;
    // The roll is drawn first, as the game draws it.
    const roll = world.random.centred() * tumble_most;
    const yaw = world.random.centred() * tumble_most;
    ship.object.rotation = math.product(ship.object.rotation, math.fromAngles(tumble_pitch, yaw, roll));

    if (pod.model) |*model| for (model.parts, 0..) |part, at| {
        if (part.parent == null and at != cockpit) objects.destroyPart(pod, .{ .model = model, .index = at });
    };
    if (ship.model) |*model| objects.destroyPart(ship, .{ .model = model, .index = cockpit });
    // Where the two came apart, each shows its caps: the pod's close the cockpit beneath.
    for ([_]*create.Slot{ pod, ship }) |parted| if (parted.model) |*model| for (model.parts) |*part| {
        if (part.parent == null) part.object.face_mask &= ~srmesh.caps_hidden;
    };
    gameobj.recentreObject(pod);
    gameobj.recentreObject(ship);

    const point = ejectPoint(pod, cockpit) orelse return;
    var emitter: particles.Emitter = .{
        .born = now,
        .place = .{ .position = point.position, .orientation = object.placeAt(.now).orientation },
        .spread = flash_spread,
        .speed = flash_speed,
        .speed_range = flash_speed_range,
        .inherited = gameobj.vector(object.velocity) * @as(Vector, @splat(flash_carried)),
        .template = &flash,
    };
    explode.burstFrom(world, &emitter, flash_count);
    object.velocity = gameobj.vec3(gameobj.vector(object.velocity) + math.forward(point.orientation) * @as(Vector, @splat(kick)));
    state.stage = .clearing;
    state.until = now + clearing_ticks;
}

/// Where the last eject point of the pod's cockpit, part `cockpit`, stands in the world, and which
/// way it faces; null where it has none.
fn ejectPoint(pod: *const create.Slot, cockpit: usize) ?math.Place {
    const loaded = pod.type orelse return null;
    const model = if (pod.model) |*live| live else return null;
    var found: ?math.Place = null;
    for (loaded.model.parts[cockpit].attachments) |*attachment| {
        if (attachment.kind != .eject_point) continue;
        found = objects.attachmentPlace(attachment);
    }
    const local = found orelse return null;
    return local.within(model.partPlace(cockpit, .now).within(pod.object.placeAt(.now)));
}

/// `order_eject` (`0x00415C50`): the pilot's pod. Once clear of its ship it slows to a stop, its
/// own invulnerability back; an AI pilot's then drifts for good. The player's drifts until the
/// pilot calls, then waits to be picked up (`pickUp`).
///
/// Not ported: the pilot's call on the radio (`ejt_015` or `ejt_016`), which waits for the radio
/// ([#48](https://github.com/vdmkenny/openreliant/issues/48)); and a multiplayer game, in which the
/// order ends at once, and in which a player's pod is disabled once clear.
pub fn update(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.eject;
    const now = ctx.clock.frame_start;
    switch (state.stage) {
        .clearing => {
            if (state.until >= now) return;
            slot.motion = .brake;
            slot.object.flags.unpowered = false;
            slot.object.invulnerable = state.invulnerable;
            if (index != all.player) {
                state.stage = .adrift;
                return;
            }
            state.stage = .drifting;
            state.until = now + drifting_ticks;
        },
        .drifting => {
            if (state.until >= now) return;
            state.stage = .called;
            state.until += calling_ticks;
        },
        .called => if (state.until < now) pickUp(ctx, index),
        .adrift, .picked_up, _ => {},
    }
}

/// The mission's odds of how the player fares after ejecting (`rescue_odds_rescued`,
/// `rescue_odds_captured` and `rescue_odds_killed`, `0x0051CF98`, `0x0051CF90` and `0x0051CF9C`),
/// which the mission's `SetRescueProbabilities` sets (`cmd_SetRescueProbabilities`, `0x004598D0`).
/// A mission starts with the pilot always picked up.
pub const RescueOdds = struct {
    rescued: u16 = 100,
    captured: u16 = 0,
    killed: u16 = 0,

    /// How a roll of the runtime's numbers falls (`order_eject`): taken over the three together,
    /// below `rescued` the pilot is picked up by a nanny ship, below that and `captured` more by
    /// the enemy, and past both killed.
    ///
    /// **Fix:** the game divides by the three together whatever they are, and stops on odds of
    /// nothing at all; OpenReliant has the pilot picked up.
    pub fn fate(odds: RescueOdds, roll: u15) Ending {
        const all = @as(u32, odds.rescued) + odds.captured + odds.killed;
        if (all == 0) return .rescued;
        const fell = roll % all;
        if (fell < odds.rescued) return .rescued;
        if (fell < @as(u32, odds.rescued) + odds.captured) return .captured;
        return .destroyed;
    }
};

/// Where the end of the player's ejection plays, out of everything's way (`0x00415CFE`).
const cutaway_place: Vector = .{ 0, -1e7, 0 };

/// Where the ship that picks the pod up starts, short of it along Z (`0x004DC564`), and where the
/// Sabre that shoots it down starts from it, across, above and short (`0x004DC444`, `0x004DC43C`),
/// turned a quarter turn about Y from the pod (`0x00415EFE`); and how much larger a target the pod
/// then makes.
const pickup_short: f32 = 15000;
const killer_across: f32 = 20000;
const killer_above: f32 = 10000;
const killer_turn: f32 = -std.math.pi / 2.0;
const killed_target_scale: f32 = 2;

/// The ship that ends the player's ejection, where it starts, the order it takes against the pod,
/// and the view that watches it.
const PickupScene = struct {
    ship: gameobj.Type,
    at: Vector,
    orientation: math.Matrix,
    order: orders.Order,
    view: camera.View,
};

/// `order_eject` as the pilot's wait ends: the mission's odds settle the pilot's fate
/// (`RescueOdds.fate`), and the mission shows its end alone (`main.Showing.ejection`), played out
/// of the way at `cutaway_place`, the pod turned to the world's axes. A nanny ship, or the
/// enemy's Antanov, made in the cutaway slot `pickup_short` short of the pod, picks it up (Scoop
/// Up, `tractor`), watched round the ship (`camera.View.pickup`); or a Sabre shoots it down (Eject
/// Fighter Attack), watched from behind the pod (`camera.View.pod_shot`), the pod made twice as
/// large a target.
///
/// Not ported: the pilot's word on the radio as it happens (`nanpkup`, `antpkup`, `ejtkll`),
/// which waits for the radio ([#48](https://github.com/vdmkenny/openreliant/issues/48)).
fn pickUp(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const pod = &all.slots[index];
    world.player.showing = .ejection;
    const fate = world.player.rescue_odds.fate(world.random.rand());
    world.player.ending = fate;
    objects.setPosition(&pod.object, &pod.drawn, cutaway_place);
    objects.setOrientation(&pod.object, &pod.drawn, math.identity);
    pod.state.eject.stage = .picked_up;
    const scene: PickupScene = switch (fate) {
        .rescued, .captured => .{
            .ship = if (fate == .rescued) .nanny else .antanov,
            .at = cutaway_place - Vector{ 0, 0, pickup_short },
            .orientation = math.identity,
            .order = .scoop_up,
            .view = .pickup,
        },
        else => .{
            .ship = .sabre,
            .at = cutaway_place + Vector{ killer_across, killer_above, -killer_across },
            .orientation = math.turned(pod.object.root.next_orientation, .y, killer_turn),
            .order = .eject_fighter_attack,
            .view = .pod_shot,
        },
    };
    const spawn = world.spawn orelse return;
    const seen = create.createObject(all, spawn.tables, spawn.types, create.cutaway_slot, scene.ship, 0, @splat(0), world.random) catch return;
    const ship = &all.slots[seen];
    objects.setPosition(&ship.object, &ship.drawn, scene.at);
    objects.setOrientation(&ship.object, &ship.drawn, scene.orientation);
    _ = aigeneric.pushShip(ctx, seen, scene.order, index, aigeneric.Target.whole) catch false;
    if (world.camera) |watching| _ = watching.setCutaway(scene.view, seen, ctx.clock.viewTime(), .of(ship), .of(pod));
    if (scene.order == .eject_fighter_attack) pod.object.radius *= killed_target_scale;
}

/// How many ticks a ship spins under Eject Spin before its pilot gets out, and how long the ship
/// a pilot has left goes on before it is destroyed (Eject, 106).
const spin_ticks = 200;
const abandoned_ticks = 200;

/// How fast Eject Spin sets the ship tumbling about each axis at most, either way, a tick
/// (`0x004DC3F8`).
const spin_most: f32 = 0.2;

/// `order_eject_spin_init` (`0x004160D0`): an AI ship whose pilot is about to eject spins,
/// unpowered, for `spin_ticks`, its pilot marked ejected, and its Destroyed event is posted
/// (`events.destroyed`).
pub fn spinInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    object.flags.unpowered = true;
    object.flags.ejected = true;
    slot.state.eject.until = ctx.clock.frame_start + spin_ticks;
    // The roll is drawn first and the pitch last, as the game draws them.
    object.rotation = math.fromAngleVector(ctx.world.random.centredVector(@splat(spin_most)));
    events.destroyed(ctx.world, index, dte.Trigger.whole_object);
}

/// `order_eject_spin` (`0x00416190`): once the spin is over, the pilot ejects (Eject), the pod
/// harmed by nothing but a player's ship.
pub fn spin(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    if (slot.state.eject.until >= ctx.clock.frame_start) return;
    // Eject is refused an ejected ship: the game lets go of the flag for the push.
    object.flags.ejected = false;
    _ = aigeneric.pop(ctx, index);
    _ = aigeneric.push(ctx, index, .eject, .none) catch false;
    object.invulnerable = .player_can_hit;
    object.flags.ejected = true;
}

/// `order_eject_106_init` (`0x00416080`): the ship its pilot has left goes on for
/// `abandoned_ticks`.
pub fn abandonedInit(ctx: Context, index: u16) void {
    ctx.world.objects.slots[index].state.eject.until = ctx.clock.frame_start + abandoned_ticks;
}

/// `order_eject_106` (`0x004160A0`): then it is destroyed, as any ship is (`ai.objectDestroyed`).
pub fn abandoned(ctx: Context, index: u16) void {
    if (ctx.world.objects.slots[index].state.eject.until < ctx.clock.frame_start) ai.objectDestroyed(ctx, index, false, false);
}

/// How near the pod the Sabre of the pilot's end opens fire, how nearly it must point at it to
/// roll as it does, and how long it holds the trigger, in ticks (`0x004DC444`, `0x004DC414`).
const attack_reach: f32 = 20000;
const attack_aimed: f32 = 0.95;
const attack_trigger_ticks = 100;

/// `order_eject_fighter_attack` (`0x004161F0`): the Sabre that ends a pilot who was not picked up
/// flies at the pod, its target, at full throttle, and within `attack_reach` fires, rolling where
/// it points at the pod; once the pod is exploding it flies on.
pub fn fighterAttack(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const pod = &all.slots[slot.orders[0].target.ship() orelse return];
    if (pod.object.flags.exploding) {
        object.throttle = ai.full_throttle;
        return;
    }
    slot.state.eject.until = ctx.clock.frame_start;
    _ = ai.steer(ctx.world, index, gameobj.vector(pod.object.root.next_position), ai.full_limit, ai.no_ease, .{});
    object.throttle = ai.full_throttle;
    const to = pod.drawn.position - slot.drawn.position;
    if (!(math.length(to) < attack_reach)) return;
    if (ai.noseCosine(slot.drawn.orientation, to) > attack_aimed) object.roll_input = full_roll;
    guns.fire(object, slot.trigger(ctx.clock.frame_start), attack_trigger_ticks);
}

/// The roll at its full.
const full_roll: f32 = 1;

/// How long the player's ship drifts after the pilot ejects: this, and up to as long again as
/// `blow_up_spread`, in ticks.
const blow_up_after = 400;
const blow_up_spread = 200;

/// `order_eject_player_init` (`0x00416310`), as the player's ship's armour runs out: the ship
/// drifts on unpowered for four to six seconds before it blows up, and the pilot has that long to
/// eject (EJECT, `input.eject`). The display's eject marker flashes (`hud.State.ejected`), and the
/// cockpit glows red (`main.cockpit.lightEmergency`).
///
/// Not ported: Moose's call to eject on the radio (`ejt_001` to `ejt_008`), which waits for the
/// radio ([#48](https://github.com/vdmkenny/openreliant/issues/48)).
pub fn playerInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.eject_player;
    state.ended = 0;
    state.end = @as(i32, ctx.world.random.rand() % blow_up_spread) + blow_up_after + ctx.clock.frame_start;
    slot.object.flags.unpowered = true;
    slot.object.flags.ejected = true;
    ctx.world.player.ending = .ejecting;
    if (ctx.world.display) |display| {
        display.ejected = true;
        display.eject_ticks = 0;
    }
    if (ctx.world.cockpit) |cockpit| @import("main.zig").cockpit.lightEmergency(cockpit);
}

/// `order_eject_player` (`0x00416450`): the player's controls run on until the ship's end, when it
/// is destroyed once more, now to explode, and its new order runs at once.
pub fn player(ctx: Context, index: u16) void {
    const state = &ctx.world.objects.slots[index].state.eject_player;
    if (state.end < ctx.clock.frame_start) {
        state.ended += 1;
        ai.objectDestroyed(ctx, index, false, false);
        aigeneric.objectOrders(ctx, index);
        return;
    }
    aigeneric.playerControl(ctx, index);
}

test player {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const index = try mission.add(.predator, @splat(0));
    const slot = &mission.objects.slots[index];

    // The player's ship ejects, and drifts until its end, which comes four to six seconds later.
    try std.testing.expect(try aigeneric.push(ctx, index, .eject_player, .none));
    aigeneric.objectOrders(ctx, index);
    try std.testing.expect(slot.object.flags.ejected and slot.object.flags.unpowered);
    try std.testing.expectEqual(.ejecting, mission.player.ending);
    const end = slot.state.eject_player.end;
    try std.testing.expect(end >= 400 and end < 600);

    // Past it, the ship explodes, and may not spin out.
    mission.clock.frame_start = end + 1;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expect(slot.object.flags.exploding);
    try std.testing.expect(!slot.orders[0].data.destroyed.may_spin);
    try std.testing.expectEqual(.destroyed, mission.player.ending);
}

/// A ship of two parts at its root, its hull and its cockpit, whose eject point stands on the
/// cockpit facing along Z, for the tests of the ejection.
const TestShip = struct {
    parts: guns.turrets.testing.Parts(2),
    point: [1]shp.Attachment,
    type: create.Type,

    const hull = 0;
    const cockpit = 1;

    fn init(ship: *TestShip, with_cockpit: bool) void {
        ship.parts.init();
        ship.point = .{std.mem.zeroes(shp.Attachment)};
        ship.point[0].kind = .eject_point;
        ship.point[0].orientation = math.identity;
        if (with_cockpit) ship.parts.data[cockpit].part.class = .cockpit;
        ship.parts.data[cockpit].attachments = &ship.point;
        ship.type = .{ .model = &ship.parts.source, .loaded = &ship.parts.loaded };
    }

    /// Answers every ship type with the one model.
    fn types(ship: *TestShip) create.Types {
        return .{ .context = ship, .load = load };
    }

    fn load(context: *anyopaque, ship_type: u8) ?*const create.Type {
        _ = ship_type;
        const ship: *TestShip = @ptrCast(@alignCast(context));
        return &ship.type;
    }
};

test "a pilot ejects in the cockpit, which leaves the ship as the pod" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var fixture: TestShip = undefined;
    fixture.init(true);
    var ctx = mission.orders();
    ctx.world.spawn = .{ .tables = &mission.tables, .types = fixture.types() };
    _ = try mission.add(.predator, @splat(0));
    const all = mission.objects;
    const index = try create.createObject(all, &mission.tables, fixture.types(), null, .sabre, 0, .{ 0, 0, 5000 }, &mission.random);
    const pod = mission.slot(index);
    pod.object.invulnerable = .player_can_hit;
    mission.clock.frame_start = 30;

    init(ctx, index);
    // The ship it leaves is an object of its own, with every part but the cockpit, which the pod
    // passes through and which is destroyed soon after.
    try std.testing.expectEqual(index + 2, all.count);
    const left: u16 = index + 1;
    const ship = mission.slot(left);
    try std.testing.expectEqual(gameobj.Slot.of(left), pod.object.passes_through[0]);
    try std.testing.expectEqual(gameobj.Slot.of(index), ship.object.passes_through[0]);
    try std.testing.expectEqual(.eject_106, ship.orders[0].order);
    try std.testing.expect(ship.object.flags.ejected);
    try std.testing.expectEqual(.drift, ship.motion.?);
    try std.testing.expect(ship.model.?.parts[TestShip.cockpit].removed);
    try std.testing.expect(!ship.model.?.parts[TestShip.hull].removed);
    // The pod keeps the slot and the cockpit alone, unpowered and harmed by nothing until it is
    // clear, and shoots out along its eject point.
    try std.testing.expect(pod.model.?.parts[TestShip.hull].removed);
    try std.testing.expect(!pod.model.?.parts[TestShip.cockpit].removed);
    try std.testing.expect(pod.object.flags.unpowered and pod.object.flags.ejected);
    try std.testing.expectEqual(.full, pod.object.invulnerable);
    try std.testing.expectEqual(.player_can_hit, pod.state.eject.invulnerable);
    try std.testing.expectEqual(left, pod.orders[0].target.ship());
    try std.testing.expectEqual(null, pod.motion);
    try std.testing.expectEqual(kick, pod.object.velocity.z);
    try std.testing.expectEqual(.clearing, pod.state.eject.stage);
    try std.testing.expectEqual(30 + clearing_ticks, pod.state.eject.until);
    try std.testing.expectEqual(math.identity, ejectPoint(pod, TestShip.cockpit).?.orientation);
}

test "a ship with no cockpit to leave in keeps its pilot" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var fixture: TestShip = undefined;
    fixture.init(false);
    var ctx = mission.orders();
    ctx.world.spawn = .{ .tables = &mission.tables, .types = fixture.types() };
    _ = try mission.add(.predator, @splat(0));
    const index = try create.createObject(mission.objects, &mission.tables, fixture.types(), null, .sabre, 0, .{ 0, 0, 5000 }, &mission.random);
    const count = mission.objects.count;
    init(ctx, index);
    try std.testing.expectEqual(count, mission.objects.count);
    try std.testing.expect(!mission.slot(index).object.flags.ejected);
}

test "RescueOdds.fate" {
    // Each roll falls to the three in turn, over the three together.
    const even: RescueOdds = .{ .rescued = 1, .captured = 1, .killed = 1 };
    try std.testing.expectEqual(.rescued, even.fate(0));
    try std.testing.expectEqual(.captured, even.fate(1));
    try std.testing.expectEqual(.destroyed, even.fate(2));
    try std.testing.expectEqual(.rescued, even.fate(3));
    // A mission starts with the pilot always picked up, and odds of nothing pick the pilot up too.
    const start: RescueOdds = .{};
    for ([_]u15{ 0, 99, std.math.maxInt(u15) }) |roll| try std.testing.expectEqual(.rescued, start.fate(roll));
    const none: RescueOdds = .{ .rescued = 0 };
    try std.testing.expectEqual(.rescued, none.fate(5));
}

test update {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const index = try mission.add(.predator, @splat(0));
    const slot = mission.slot(index);
    const state = &slot.state.eject;

    // A pod shooting clear stays unpowered until its time is up, then brakes with its
    // invulnerability back.
    state.* = std.mem.zeroes(State);
    state.until = 100;
    state.invulnerable = .player_can_hit;
    slot.object.flags.unpowered = true;
    mission.clock.frame_start = 100;
    update(ctx, index);
    try std.testing.expectEqual(.clearing, state.stage);
    mission.clock.frame_start = 101;
    update(ctx, index);
    try std.testing.expect(!slot.object.flags.unpowered);
    try std.testing.expectEqual(.brake, slot.motion.?);
    try std.testing.expectEqual(.player_can_hit, slot.object.invulnerable);
    // The player's drifts, calls, and is picked up once the call has waited its time.
    try std.testing.expectEqual(.drifting, state.stage);
    try std.testing.expectEqual(101 + drifting_ticks, state.until);
    mission.clock.frame_start = 102 + drifting_ticks;
    update(ctx, index);
    try std.testing.expectEqual(.called, state.stage);
    mission.clock.frame_start = 102 + drifting_ticks + calling_ticks;
    update(ctx, index);
    try std.testing.expectEqual(.picked_up, state.stage);
    // Played out of the way, alone, the pilot rescued by the mission's own odds.
    try std.testing.expectEqual(.ejection, mission.player.showing);
    try std.testing.expectEqual(.rescued, mission.player.ending);
    try std.testing.expectEqual(cutaway_place, slot.drawn.position);
    try std.testing.expectEqual(math.identity, slot.drawn.orientation);

    // An AI pilot's pod drifts for good.
    const other = try mission.addOther(@splat(0));
    const adrift = &mission.slot(other).state.eject;
    adrift.* = std.mem.zeroes(State);
    update(ctx, other);
    try std.testing.expectEqual(.adrift, adrift.stage);
}

test "a pilot's ship spins before the pilot ejects, and is destroyed once left" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = mission.slot(index);

    // Eject Spin: unpowered and marked ejected, turning, until its time is up.
    try std.testing.expect(try aigeneric.push(ctx, index, .eject_spin, .none));
    aigeneric.objectOrders(ctx, index);
    try std.testing.expect(slot.object.flags.unpowered and slot.object.flags.ejected);
    try std.testing.expect(!std.meta.eql(slot.object.rotation, std.mem.zeroes(math.Matrix)));
    try std.testing.expectEqual(spin_ticks, slot.state.eject.until);
    // Then the pilot ejects, the pod harmed by nothing but a player's ship.
    mission.clock.frame_start = spin_ticks + 1;
    spin(ctx, index);
    try std.testing.expectEqual(.eject, slot.orders[0].order);
    try std.testing.expectEqual(.player_can_hit, slot.object.invulnerable);
    try std.testing.expect(slot.object.flags.ejected);

    // The ship a pilot has left goes on for a while, then is destroyed.
    const left = try mission.addOther(.{ 0, 0, 5000 });
    const hull = mission.slot(left);
    mission.clock.frame_start = 1000;
    abandonedInit(ctx, left);
    abandoned(ctx, left);
    try std.testing.expect(hull.orders[0].order != .explode);
    mission.clock.frame_start = 1001 + abandoned_ticks;
    abandoned(ctx, left);
    try std.testing.expectEqual(.explode, hull.orders[0].order);
}

test fighterAttack {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const pod = try mission.add(.predator, @splat(0));
    const sabre = try mission.addOther(.{ 0, 0, -30000 });
    const slot = mission.slot(sabre);
    try std.testing.expect(try aigeneric.pushShip(ctx, sabre, .eject_fighter_attack, pod, aigeneric.Target.whole));

    // Far off, it flies at the pod at full throttle, holding its fire.
    fighterAttack(ctx, sabre);
    try std.testing.expectEqual(ai.full_throttle, slot.object.throttle);
    try std.testing.expectEqual(0, slot.object.roll_input);
    // Within reach and pointing at the pod, it rolls and fires.
    objects.setPosition(&slot.object, &slot.drawn, .{ 0, 0, -10000 });
    fighterAttack(ctx, sabre);
    try std.testing.expectEqual(full_roll, slot.object.roll_input);
    // Once the pod is exploding it flies on.
    mission.slot(pod).object.flags.exploding = true;
    slot.object.throttle = 0;
    fighterAttack(ctx, sabre);
    try std.testing.expectEqual(ai.full_throttle, slot.object.throttle);
}
