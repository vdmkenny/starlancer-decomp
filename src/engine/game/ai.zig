//! `C:\lancer\game\Ai.cpp`: the order table, every order objects follow.
//! [`ai/orders.zig`](ai/orders.zig) transcribes it. **Unverified:** the table lies in the data
//! before this file's path, which holds this file's data or an earlier file's.

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;
const dte = @import("../../formats/dte.zig");
const bind = @import("mission/bind.zig");
const events = @import("mission/events.zig");
const gameobj = @import("gameobj.zig");
const Routine = gameobj.Routine;
const camera = @import("camera.zig");
const create = @import("create.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const motion = @import("motion.zig");
const aigeneric = @import("aigeneric.zig");
const guns = @import("guns.zig");
const objects = @import("objects.zig");
const GameObject = gameobj.GameObject;

pub const orders = @import("ai/orders.zig");
/// Ship Follow Curve and its backwards twin.
pub const follow = @import("ai/follow.zig");

/// A record of the order table. `order_groups` points at the records of each hundred order
/// numbers: order `n` is record `n % 100` of group `n / 100`.
pub const Record = extern struct {
    /// Runs before the order's first update. Null for none.
    init: Pointer(Routine),
    /// Runs each time `object_orders` runs the order.
    update: Pointer(Routine),
    /// Runs when the order is popped or replaced after it has started. Null for none.
    exit: Pointer(Routine),
    flags: Flags,
    /// The developers' name for the order, which fatal errors show.
    name: Pointer(u8),
    /// Zero for an order that any other replaces. Otherwise, once it has started, only `explode`, a
    /// one-shot order or an order of higher priority may be pushed on it, and pushing another is a
    /// fatal error.
    priority: i32,

    pub const Flags = packed struct(u32) {
        /// It may be given to a player's ship. A player's ship refuses the other orders numbered
        /// below 100.
        players: bool,
        /// **Unknown.** Bits set on some orders that nothing in the payload tests.
        _unknown_1: u4,
        /// It runs its update once, then pops itself, and the order below carries on without
        /// starting again. Its `init` never runs.
        one_shot: bool,
        /// While it runs, a ship that takes enough damage turns to fight its attacker
        /// (`order_retaliate`).
        retaliate: bool,
        /// While it runs, `avoidance_scan` lists the objects the ship could hit, up to ten of each
        /// of two kinds (`GameObject.avoid_near`, `avoid_ahead`), unless the object has
        /// `no_avoidance`; `docs/engine/orders.md` says which.
        avoidance: bool,
        _unknown_8: u2,
        /// While it runs, a multiplayer game sends the ship's steering inputs, throttle, rates and
        /// velocity.
        send_flight: bool,
        _unknown_11: u21,
    };

    comptime {
        assert(@offsetOf(Record, "flags") == 0xC);
        assert(@sizeOf(Record) == 0x18);
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// Where the AI aims at a target, and how far across that is: the part a component names, the
/// part a few types are aimed at by (`gameobj.Type.aimedChild`), or the object itself
/// (`0x004018F0`, which gives the part's node). **Unverified:** these helpers lie before this
/// file's path, beside `ai_steer`.
pub const Aimed = struct {
    position: Vector,
    radius: f32,
    /// How the part hanging from the root that it is, or hangs from, is turned; the object's own
    /// turn for the object itself (`maneuver_new_attack_run_run`, which walks up to it).
    orientation: math.Matrix,

    fn ofPart(model: *const objects.Model, part: *const objects.Model.Part) Aimed {
        return .{ .position = part.object.position, .radius = part.object.radius, .orientation = model.topOf(part).object.orientation };
    }
};

pub fn aimedAt(all: *const create.Objects, target: aigeneric.Target) Aimed {
    const slot = &all.slots[@intCast(target.index)];
    if (slot.model) |*model| if (targetPart(all, target)) |part| return .ofPart(model, part);
    return .{ .position = slot.drawn.position, .radius = slot.object.radius, .orientation = slot.drawn.orientation };
}

/// `ai_target_node` (`0x004018F0`): the part whose node a target names, the component or the part
/// a few types are aimed at by, or null for the object's root.
pub fn targetPart(all: *const create.Objects, target: aigeneric.Target) ?*const objects.Model.Part {
    const slot = &all.slots[@intCast(target.index)];
    const model = if (slot.model) |*model| model else return null;
    if (target.part()) |component| if (slot.component(component)) |part| return part;
    const child = slot.object.type.aimedChild() orelse return null;
    return model.rootChild(child);
}

/// `0x00402860`: the entry of the player's orders that is Player Control, which holds the
/// player's target, or null for none.
pub fn playerControlEntry(all: *create.Objects) ?*aigeneric.Entry {
    const slot = &all.slots[all.player];
    for (slot.orders[0..@intCast(slot.object.order_count)]) |*entry| {
        if (entry.order == .player_control) return entry;
    }
    return null;
}

/// How much further a Turret Flak's shot is led for, over its lifetime (`0x004DC3D8`), and the
/// share of a gun's life within which a shot is led at all (`0x004DC3D4`).
const flak_lead: f32 = 3;
const lead_range: f32 = 0.25;

/// `ai_lead_aim` (`0x00401280`): where to aim at `target` for the fastest of the guns the ship
/// fires together to hit it, from its root (`leadAimWithGun`).
///
/// **Fix:** the game reads each gun's turret kind as its type, which leads every ship's shots as
/// a Laser Cannon's; OpenReliant leads by the fastest gun's own type.
pub fn leadAim(all: *const create.Objects, index: u16, target: aigeneric.Target, lead: f32) ?Vector {
    const slot = &all.slots[index];
    var fastest: guns.GunType = .laser_cannon;
    var best: f32 = -1;
    var chosen: guns.Chosen = .of(&slot.object, slot.guns, slot.gun_groups);
    while (chosen.next()) |gun| {
        const barrel = gun.barrel() orelse continue;
        const speed = barrel.type.stats(&all.gun_stats).speed;
        if (speed > best) {
            best = speed;
            fastest = barrel.type;
        }
    }
    return leadAimWithGun(all, slot.drawn.position, target, fastest, lead);
}

/// `ai_lead_aim_with_gun` (`0x00401180`): where to aim from `from` at `target` for a shot of `gun`
/// to hit it: ahead of it along its heading by how far it flies, times `lead`, while the shot
/// flies to it. Null where that takes longer than a quarter of the gun's life, when the caller
/// aims at it unled or not at all.
///
/// A Turret Flak's shot is led within three times its gun's lifetime.
///
/// **Fix:** the game takes the Laser Cannon's lifetime there, the table's first gun's, which leads
/// flak past the life of its own shells; OpenReliant the flak's own.
pub fn leadAimWithGun(all: *const create.Objects, from: Vector, target: aigeneric.Target, gun: guns.GunType, lead: f32) ?Vector {
    const record = gun.stats(&all.gun_stats);
    const lifetime = @as(f32, @floatFromInt(record.lifetime)) * @as(f32, if (gun == .turret_flak) flak_lead else 1);
    const aimed = aimedAt(all, target);
    const flight = math.distance(from, aimed.position) / record.speed;
    if (!(flight <= lifetime * lead_range)) return null;
    const struck = &all.slots[@intCast(target.index)];
    return aimed.position + math.forward(struck.drawn.orientation) * @as(Vector, @splat(flight * struck.object.speed * lead));
}

/// `0x004010F0`: whether `point` lies ahead of `place` and within `radius` of the line along its
/// nose.
pub fn alongNose(place: math.Place, point: Vector, radius: f32) bool {
    const offset = point - place.position;
    const along = math.dot(math.forward(place.orientation), offset);
    if (!(along > 0)) return false;
    return math.lengthSquared(offset) - along * along < radius * radius;
}

/// The cosine of the angle between `toward` and `nose`, a unit direction: their dot product over
/// the length of `toward`, as the Fight order and its maneuvers work it out
/// (`fight_choose_by_position`, `maneuver_steer_to_point`).
///
/// `noseCosine` normalizes first, which rounds differently, and some callers compare the dot
/// product with the length times a cosine instead; each keeps the original's way.
pub fn cosineOff(toward: Vector, nose: Vector) f32 {
    return math.dot(toward, nose) / math.length(toward);
}

/// The cosine of the angle between `toward` and the nose of something turned as `orientation`:
/// `toward` normalized, dotted with the nose, as the ejection's Sabre and Scoop Up work it out
/// (`order_eject_fighter_attack`, `order_scoop_up`).
pub fn noseCosine(orientation: math.Matrix, toward: Vector) f32 {
    return math.dot(math.normalize(toward), math.forward(orientation));
}

/// How near a box of a hull has to be for `escapeDirection` to push away from it (`0x004DC444`).
const escape_reach: f32 = 20000;

/// `0x00402500`: which way lies clear of a ship's hull from `from`. Each box of the collision trees
/// of its parts, the root's child list, whose edge, taking it as a sphere as wide as its half-size,
/// is within `escape_reach` of `from` pushes away from it, the harder the nearer it is; the sum,
/// normalized.
pub fn escapeDirection(slot: *const create.Slot, from: Vector) Vector {
    var away: Vector = @splat(0);
    const model = if (slot.model) |*model| model else return math.normalize(away);
    const source = (slot.type orelse return math.normalize(away)).model;
    const count = @min(model.parts.len, source.parts.len);
    for (model.parts[0..count], source.parts[0..count]) |part, data| {
        if (part.removed) continue;
        for (data.nodes) |node| {
            const toward = part.drawn().point(gameobj.vector(node.centre)) - from;
            const gap = math.length(toward) - math.length(gameobj.vector(node.half_size));
            if (gap < escape_reach and gap > 0) away += math.normalize(toward) * @as(Vector, @splat(gap - escape_reach));
        }
    }
    return math.normalize(away);
}

/// How much of the target's velocity the course is closed against (`0x00401980`), and the least
/// closing that counts (`0x004DC418`).
const crash_target_share: f32 = -2;
const least_closing: f32 = 0.001;

/// `0x00401980`: whether the ship at `index` is on course to hit `target`, one without listed
/// components, within `steps` simulation steps and with `margin` to spare: they are within reach
/// of each other at their cruise speeds, the target is ahead of the ship, and the ship is closing
/// on it by its velocity less twice the target's, to within both radii and the margin.
///
/// Not ported: against a target with listed components, the parts of it the ship could hit
/// ([#239](https://github.com/vdmkenny/openreliant/issues/239)); that is taken as no.
pub fn collisionCourse(world: gameobj.World, index: u16, target: u16, steps: f32, margin: f32) bool {
    const all = world.objects;
    const ship = &all.slots[index];
    const struck = &all.slots[target];
    if (struck.object.flags.components) return false;
    const ship_flight = ship.flight orelse return false;
    const struck_flight = struck.flight orelse return false;
    var apart = ship.object.nextPosition() - struck.object.nextPosition();
    const speeds = cruiseSpeed(&struck.object, struck_flight, world.view) + cruiseSpeed(&ship.object, ship_flight, world.view);
    const reach = speeds * steps + struck.object.radius + ship.object.radius + margin;
    if (math.lengthSquared(apart) > reach * reach) return false;
    const closing = gameobj.vector(struck.object.velocity) * @as(Vector, @splat(crash_target_share)) + gameobj.vector(ship.object.velocity);
    if (math.dot(ship.object.nextHeading(), apart) > 0) return false;
    const along = math.dot(apart, closing);
    if (-along < 0) return false;
    const rate = math.dot(closing, closing);
    if (rate < least_closing) return false;
    apart += closing * @as(Vector, @splat(@min(-along / rate, steps)));
    const touching = struck.object.radius + ship.object.radius + margin;
    return math.lengthSquared(apart) < touching * touching;
}

/// A pilot ejects rather than go down with the ship where its `eject_roll` is below this
/// (`0x28`).
pub const eject_below = 40;

/// `object_hull_lost` (`0x00401F00`): the end of a ship that lists components, as the part of its
/// hull holding it together is destroyed. Its current order gives way as to Explode, its stack is
/// emptied, and it is marked exploding, so it takes no order again; no Explode order runs it down.
/// Its Destroyed event is posted (`events.destroyed`).
pub fn hullLost(ctx: aigeneric.Context, index: u16) void {
    const object = &ctx.world.objects.slots[index].object;
    _ = aigeneric.giveWay(ctx, index, .explode) catch false;
    object.order_count = 0;
    object.flags.exploding = true;
    events.destroyed(ctx.world, index, dte.Trigger.whole_object);
}

/// `object_destroyed` (`0x00401F30`): a ship's end. An AI ship's pilot ejects where the ship is in
/// the player's wing and its roll says so, or where the ship is told to eject before exploding, and
/// the ship spins on under Eject Spin. The player's ejects, unless it already has or the blow was
/// too heavy, or it is flying the Kamov, and its ship blows up later (`aieject.playerInit`).
/// Otherwise the ship explodes (`aiexplode`), in place of whatever it was doing: the stack is
/// overwritten whether or not its order gives way, and the order's state is left for Explode's
/// `init` to fill in. `may_spin` goes into the order's data.
///
/// Not ported: multiplayer, where the player's ship explodes at once.
pub fn objectDestroyed(ctx: aigeneric.Context, index: u16, may_spin: bool, no_eject: bool) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const ai_pilot_ejects = index >= all.players and object.wing == .player and object.eject_roll < eject_below;
    if (!object.flags.ejected and (ai_pilot_ejects or object.invulnerable == .eject_before_exploding)) {
        replaceOrders(ctx, index, .eject, .eject_spin, may_spin);
        return;
    }
    if (slot.orders[0].order == .explode) return;
    if (index == all.player and !object.flags.ejected and !no_eject and object.type != .kamov) {
        if (slot.orders[0].order != .eject_player) {
            const aimed = slot.orders[0].target;
            _ = aigeneric.push(ctx, index, .eject_player, .{ .kind = .ship, .index = aimed.index, .component = aimed.component }) catch false;
            object.flags.ejected = true;
            return;
        }
        if (slot.state.eject_player.ended == 0) return;
        _ = aigeneric.pop(ctx, index);
    }
    replaceOrders(ctx, index, .explode, .explode, may_spin);
    object.flags.exploding = true;
}

/// Clears the way as for `making_way`, whatever the current order says, and leaves `order`,
/// aimed at nothing, as the only one, starting.
fn replaceOrders(ctx: aigeneric.Context, index: u16, making_way: orders.Order, order: orders.Order, may_spin: bool) void {
    const slot = &ctx.world.objects.slots[index];
    _ = aigeneric.giveWay(ctx, index, making_way) catch false;
    slot.object.order_count = 1;
    slot.orders[0].order = order;
    slot.orders[0].target = .none;
    slot.orders[0].data.destroyed = .{ .may_spin = may_spin };
    slot.object.order_starting = true;
}

/// `object_set_targetable` (`0x00401830`): sets or clears the object's `targetable` flag, which
/// stays clear for an object with no stats or of a type that can't be targeted
/// (`ShipCombat.Targeting`). **Unverified:** it lies before this file's known code.
pub fn setTargetable(object: *gameobj.GameObject, combat: ?*const create.ShipCombat, targetable: bool) void {
    const allowed = if (combat) |stats| stats.targeting.targetable else false;
    object.flags.targetable = targetable and allowed;
}

/// `order_target_walk` (`0x00401CB0`): `visitor.visit` for each ship an order's `target` names,
/// until a visit returns true: the ship itself, as the target names it; each ship of a flight group,
/// whole; and each ship of a squad (`squadWalk`). Whether a visit ended the walk. A flight group or
/// a squad names no ship where no mission is bound (`gameobj.World.mission`). Dock, Escort, the
/// search for a new target, the search for a pod to scoop up, the Dark Reign's guns and Launch walk
/// their targets so. **Unverified:** it lies before this file's known code.
pub fn eachShip(world: gameobj.World, target: aigeneric.Target, visitor: anytype) bool {
    switch (target.kind) {
        .ship => return visitor.visit(target),
        .flight_group => {
            const mission = world.mission orelse return false;
            const groups = mission.flightGroups() catch return false;
            const group = std.math.cast(usize, target.index) orelse return false;
            if (group >= groups.len) return false;
            return groupWalk(mission, groups[group], visitor);
        },
        .squad => {
            const mission = world.mission orelse return false;
            return squadWalk(mission, std.math.cast(u16, target.index) orelse return false, visitor, 0);
        },
        _ => return false,
    }
}

/// Each ship of flight group `group`, whole, for `eachShip`.
fn groupWalk(mission: *const bind.Mission, group: dte.FlightGroup, visitor: anytype) bool {
    for (mission.groupShips(group)) |ship| {
        if (visitor.visit(aigeneric.Target.at(ship, null))) return true;
    }
    return false;
}

/// `squad_walk` (`0x00401D80`): `eachShip`'s walk of squad `squad`, `depth` squads down: its
/// members in turn from its first, while they are its own: a ship, as the member names its
/// component; a flight group's ships, whole; and a squad's own walk.
///
/// **Fix:** the game walks a squad that holds itself round for ever, takes a member no record
/// stands for as the ship at address zero, and stops with a fatal error at a member of a kind it
/// does not know; OpenReliant stops once the walk has gone down more squads than the mission has,
/// and passes over the member.
fn squadWalk(mission: *const bind.Mission, squad: u16, visitor: anytype, depth: usize) bool {
    const file = mission.file;
    const squads = file.squads() catch return false;
    if (squad >= squads.len or depth > squads.len) return false;
    const members = file.records(dte.SquadMember, .squad_members) catch return false;
    const kinds = file.objects() catch return false;
    const groups = mission.flightGroups() catch return false;
    const first: usize = squads[squad].first_member;
    if (first >= members.len) return false;
    for (members[first..]) |member| {
        if (member.squad != squad) return false;
        const id = member.object_id;
        if (id >= kinds.len or id >= mission.records.len) continue;
        const record = mission.records[id] orelse continue;
        switch (kinds[id].kind) {
            .ship => {
                const ship = switch (record) {
                    .ship => |at| at,
                    else => continue,
                };
                const component: ?u16 = if (member.component == dte.Trigger.whole_object) null else member.component;
                if (visitor.visit(aigeneric.Target.at(ship, component))) return true;
            },
            .flight_group => {
                const group = switch (record) {
                    .flight_group => |at| at,
                    else => continue,
                };
                if (group < groups.len and groupWalk(mission, groups[group], visitor)) return true;
            },
            .squad => {
                const inner = switch (record) {
                    .squad => |at| at,
                    else => continue,
                };
                if (squadWalk(mission, inner, visitor, depth + 1)) return true;
            },
            _ => continue,
        }
    }
    return false;
}

test hullLost {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    _ = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.sabre, .{ 0, 0, 1000 });
    const object = &mission.objects.slots[ship].object;

    // Its orders are cleared, and it takes none again.
    try std.testing.expect(try aigeneric.push(ctx, ship, .do_nothing, .none));
    hullLost(ctx, ship);
    try std.testing.expectEqual(0, object.order_count);
    try std.testing.expect(object.flags.exploding);
    try std.testing.expect(!try aigeneric.push(ctx, ship, .do_nothing, .none));
}

test objectDestroyed {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const player = try mission.add(.predator, @splat(0));
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });
    const slots = &mission.objects.slots;

    // An AI ship explodes, taking no order after.
    try std.testing.expect(try aigeneric.push(ctx, other, .do_nothing, .none));
    objectDestroyed(ctx, other, true, false);
    try std.testing.expectEqual(.explode, slots[other].orders[0].order);
    try std.testing.expectEqual(1, slots[other].object.order_count);
    try std.testing.expect(slots[other].object.flags.exploding and slots[other].object.order_starting);
    try std.testing.expect(!try aigeneric.push(ctx, other, .do_nothing, .none));

    // In the player's wing, where its pilot may eject, a low roll ejects, and the ship spins on.
    const ejecting = try mission.add(.sabre, .{ 0, 0, 2000 });
    slots[ejecting].object.wing = .player;
    slots[ejecting].object.eject_roll = eject_below - 1;
    objectDestroyed(ctx, ejecting, true, false);
    try std.testing.expectEqual(.eject_spin, slots[ejecting].orders[0].order);
    try std.testing.expect(!slots[ejecting].object.flags.exploding);

    // The player's pilot ejects, unless the blow was too heavy.
    objectDestroyed(ctx, player, true, false);
    try std.testing.expectEqual(.eject_player, slots[player].orders[0].order);
    try std.testing.expect(slots[player].object.flags.ejected);
    const heavy = try mission.add(.predator, .{ 0, 0, 3000 });
    mission.objects.player = heavy;
    objectDestroyed(ctx, heavy, true, true);
    try std.testing.expectEqual(.explode, slots[heavy].orders[0].order);
}

test setTargetable {
    var object = gameobj.testing.object();
    var combat = std.mem.zeroes(create.ShipCombat);
    setTargetable(&object, &combat, true);
    try std.testing.expect(!object.flags.targetable);
    combat.targeting.targetable = true;
    setTargetable(&object, &combat, true);
    try std.testing.expect(object.flags.targetable);
    setTargetable(&object, &combat, false);
    try std.testing.expect(!object.flags.targetable);
    object.flags.targetable = true;
    setTargetable(&object, null, true);
    try std.testing.expect(!object.flags.targetable);
}

test eachShip {
    const gpa = std.testing.allocator;
    // Ships 0 to 3, the first two in flight group 0. Squad 0 holds ship 2's component 5, the flight
    // group, and squad 1, which holds ship 3.
    var ships: [4]dte.Ship = @splat(std.mem.zeroes(dte.Ship));
    for (&ships, 0..) |*ship, n| {
        ship.object_id = @intCast(n);
        ship.flight_group = if (n < 2) 0 else dte.Ship.no_flight_group;
    }
    var group = std.mem.zeroes(dte.FlightGroup);
    group.object_id = 4;
    var squads: [2]dte.Squad = @splat(std.mem.zeroes(dte.Squad));
    squads[0].object_id = 5;
    squads[0].first_member = 0;
    squads[1].object_id = 6;
    squads[1].first_member = 3;
    const Member = struct {
        fn of(object_id: u16, squad: u16, component: u8) dte.SquadMember {
            return .{ .object_id = object_id, ._unknown_02 = 0, .squad = squad, ._unknown_06 = 0, .component = component, ._unknown_09 = @splat(0) };
        }
    };
    const whole = dte.Trigger.whole_object;
    const members = [_]dte.SquadMember{ Member.of(2, 0, 5), Member.of(4, 0, whole), Member.of(6, 0, whole), Member.of(3, 1, whole) };
    var kinds: [7]dte.Object = @splat(.{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 });
    kinds[4].kind = .flight_group;
    kinds[5].kind = .squad;
    kinds[6].kind = .squad;
    var fixture: @import("../vm.zig").machine.testing.Fixture = undefined;
    try fixture.init(gpa, &.{}, .{ .ships = &ships, .flight_groups = &.{group}, .objects = &kinds, .squads = &squads, .squad_members = &members });
    defer fixture.deinit();
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var world = mission.world();
    world.mission = &fixture.mission;

    const Seen = struct {
        targets: [8]aigeneric.Target = undefined,
        count: usize = 0,
        stop_at: usize = 0,

        pub fn visit(seen: *@This(), target: aigeneric.Target) bool {
            seen.targets[seen.count] = target;
            seen.count += 1;
            return seen.count == seen.stop_at;
        }
    };
    // A ship is visited as the target names it.
    var one: Seen = .{};
    try std.testing.expect(!eachShip(world, .at(3, 7), &one));
    try std.testing.expectEqualSlices(aigeneric.Target, &.{.at(3, 7)}, one.targets[0..one.count]);
    // A flight group's ships, whole.
    var flight: Seen = .{};
    _ = eachShip(world, .{ .kind = .flight_group, .index = 0, .component = aigeneric.Target.whole }, &flight);
    try std.testing.expectEqualSlices(aigeneric.Target, &.{ .at(0, null), .at(1, null) }, flight.targets[0..flight.count]);
    // A squad's members in turn, down into the flight group and the squad it holds.
    const squad: aigeneric.Target = .{ .kind = .squad, .index = 0, .component = aigeneric.Target.whole };
    var all: Seen = .{};
    _ = eachShip(world, squad, &all);
    try std.testing.expectEqualSlices(aigeneric.Target, &.{ .at(2, 5), .at(0, null), .at(1, null), .at(3, null) }, all.targets[0..all.count]);
    // A visit that returns true ends the walk.
    var two: Seen = .{ .stop_at = 2 };
    try std.testing.expect(eachShip(world, squad, &two));
    try std.testing.expectEqual(2, two.count);
    // With no mission bound, a flight group names no ship.
    var none: Seen = .{};
    try std.testing.expect(!eachShip(mission.world(), .{ .kind = .flight_group, .index = 0, .component = aigeneric.Target.whole }, &none));
    try std.testing.expectEqual(0, none.count);
}

/// `object_cruise_speed` (`0x00403060`), which lies after this file's known code, before
/// `aidefend.cpp`'s: `max_speed` scaled by `speed_factor`, by the share of its
/// engines left, and, unless the camera is in view 13 or the object is invulnerable, by
/// `armor_speed_factor` as well. So losing engines or armor slows a ship.
///
/// OpenReliant takes the flight stats and the view rather than reaching them through the object and
/// a global, since `GameObject` holds the binary's own 32-bit pointers.
pub fn cruiseSpeed(object: *const gameobj.GameObject, flight: *const create.FlightModel, view: camera.View) f32 {
    var speed = flight.max_speed * object.speed_factor * object.engines_intact;
    if (view != .director and object.invulnerable == .none) speed *= object.armor_speed_factor;
    return speed;
}

/// `cruiseSpeed` of the object in `slot`, where it has flight stats. The game reads them through
/// the object, and every ship its orders fly has them; each caller says what a slot without them
/// does.
pub fn slotCruise(slot: *const create.Slot, view: camera.View) ?f32 {
    const flight = slot.flight orelse return null;
    return cruiseSpeed(&slot.object, flight, view);
}

test cruiseSpeed {
    var object = gameobj.testing.object();
    try std.testing.expectEqual(320, cruiseSpeed(&object, &gameobj.testing.flight, .chase));
    // Losing half its engines and a fifth of its armor slows it.
    object.engines_intact = 0.5;
    object.armor_speed_factor = 0.8;
    try std.testing.expectEqual(128, cruiseSpeed(&object, &gameobj.testing.flight, .chase));
    // The armor tells in every view but 13, and not at all while it is invulnerable.
    try std.testing.expectEqual(160, cruiseSpeed(&object, &gameobj.testing.flight, .director));
    object.invulnerable = .player_can_hit;
    try std.testing.expectEqual(160, cruiseSpeed(&object, &gameobj.testing.flight, .chase));
}

test slotCruise {
    var slot: create.Slot = .{ .object = gameobj.testing.object(), .flight = &gameobj.testing.flight };
    try std.testing.expectEqual(320, slotCruise(&slot, .chase));
    slot.flight = null;
    try std.testing.expectEqual(null, slotCruise(&slot, .chase));
}

/// What `ai_steer` does besides turning toward its point, as the orders and the maneuvers ask for
/// it.
pub const Steering = packed struct(u32) {
    /// Move the point around the objects with listed components the ship could hit (`avoidNear`).
    avoid_near: bool = false,
    /// Move the point around the objects the ship is on course to hit (`avoidAhead`).
    avoid_ahead: bool = false,
    /// Unless avoidance took the point over, roll toward the world's Y axis as well
    /// (`rollUpright`).
    roll_upright: bool = false,
    /// Hold the pitch at `pitch_floor` or more, so the ship keeps its nose up.
    pitch_up: bool = false,
    _unknown_4: u28 = 0,
};

/// The steering's turn limit at its full, and no ease on the turn, which `steer` takes where it
/// goes round something and most orders give it; and the throttle at its full.
pub const full_limit: f32 = 1;
pub const no_ease: f32 = 0;
pub const full_throttle: f32 = 1;

/// The turn that fills a steering input: an input reaches 1 at five degrees off, the angle in
/// degrees over five (`0x004DC3FC`).
///
/// **Improvement:** the game holds this rounded to 11.459155, one place in the last digit below
/// the figure OpenReliant computes.
pub const input_per_radian: f32 = std.math.deg_per_rad / 5.0;

/// How much of the turn rate the steering takes off its input at no ease, which damps the turn as
/// the ship comes round (`0x004DC400`).
pub const rate_damping: f32 = 6;

/// While a frame takes more than this many ticks, `steer` halves the turns under `half_turn`, so a
/// slow frame doesn't overshoot (`frame_duration`).
const slow_frame: i32 = 10;

/// The turn `steer` halves while frames are slow (`0x004DC40C`), which is an eighth of a turn.
const half_turn: f32 = std.math.pi / 8.0;

/// Where `Steering.pitch_up` holds the pitch input (`0x004DC3F8`).
const pitch_floor: f32 = 0.2;

/// How near its nose a direction counts as ahead: the cosine of the angle (`0x004DC414`).
const ahead_cosine: f32 = 0.95;

/// How far the roll may be off, in radians, before the ship pitches as well (`0x004DC410`).
const roll_before_pitch: f32 = 0.8;

/// `ai_steer` (`0x00401380`): the AI's steering, which the orders and the maneuvers turn a ship
/// with. It aims the ship at `at`, a point in the world, by setting its three turning inputs
/// (`turn`). Where the flags ask for avoidance, the point first moves around what the ship could
/// hit (`avoidNear`, `avoidAhead`), and the turn is then made at full limit with no ease and no
/// pitch held up. Whether avoidance moved the point.
pub fn steer(world: gameobj.World, index: u16, at: Vector, limit: f32, ease: f32, flags: Steering) bool {
    var point = at;
    var avoided = false;
    if (flags.avoid_near) avoided = avoidNear(world, index, &point);
    if (flags.avoid_ahead) avoided = avoidAhead(world, index, &point) or avoided;
    turn(&world.objects.slots[index], point, limit, ease, flags, world.clock.frame_duration, avoided);
    return avoided;
}

/// The rest of `ai_steer`: the turning inputs that aim the ship at `at`, the angles off its nose,
/// less `(1 - ease) * 6` times each turn rate, as shares of five degrees, each held within
/// `limit` and 1. `ease` slackens the damping, so an eased turn swings further. Where `avoided`,
/// at full limit, with no ease and no pitch held up, and no roll upright.
///
/// It steers by the place the ship is drawn at, which is where the frames have moved it to since
/// the last step, since the orders run once a frame.
///
/// **Improvement:** the angles come from `std.math.atan2` rather than the engine's table
/// (`sr_atan2`), as they do elsewhere in OpenReliant.
pub fn turn(slot: *create.Slot, at: Vector, limit_given: f32, ease_given: f32, flags_given: Steering, frame_duration: i32, avoided: bool) void {
    const object = &slot.object;
    // A ship with no flight stats would follow a null pointer here, so it steers nowhere instead.
    const flight = slot.flight orelse return;
    var flags = flags_given;
    var ease = ease_given;
    var limit = limit_given;
    if (avoided) {
        limit = full_limit;
        ease = no_ease;
        flags.pitch_up = false;
    }
    const held = limit;

    object.holdTurns();
    const direction = slot.drawn.inverse(at);
    if (@as(u16, @truncate(flight._unknown_24)) == 0) {
        steerAngles(object, direction, slot.motion == .backward, flags);
    } else {
        steerAxes(object, direction);
    }

    // A slow frame turns the ship further than a quick one, so the small turns are halved.
    if (frame_duration > slow_frame) {
        var halved = false;
        inline for (.{ &object.pitch_input, &object.yaw_input, &object.roll_input }) |input| {
            if (@abs(input.*) < half_turn) {
                input.* *= 0.5;
                halved = true;
            }
        }
        if (halved) limit = held * 0.5;
    }

    const damping = (1 - ease) * rate_damping;
    object.pitch_input = (object.pitch_input - damping * object.pitch_rate) * input_per_radian;
    object.yaw_input = (object.yaw_input - damping * object.yaw_rate) * input_per_radian;
    object.roll_input = (object.roll_input - damping * object.roll_rate) * input_per_radian;

    limit = @min(limit, 1);
    object.pitch_input = @min(object.pitch_input, limit);
    object.pitch_input = if (flags.pitch_up) @max(object.pitch_input, pitch_floor) else @max(object.pitch_input, -limit);
    object.yaw_input = std.math.clamp(object.yaw_input, -limit, limit);
    object.roll_input = std.math.clamp(object.roll_input, -limit, limit);

    if (!avoided and flags.roll_upright) rollUpright(object, at);
}

/// `ai_arrive` (`0x00402140`, `0x00402160`): steers the ship in slot `index` to arrive at `at`,
/// turned as `orientation`, its throttle `least` or more; whether it has arrived, within
/// `arrive_reach` of it, its throttle then `least` and its turning inputs nothing. It goes by where
/// the ship stands next (`Node.next_position`).
///
/// Where the ship stands behind `at` along the way `orientation` faces, near that line, and faces
/// that way itself, it flies at `at` (`steer`, keeping clear of what it could hit), rolling to
/// stand as `orientation` stands. Otherwise it flies round the circle that runs through it and
/// meets that line at `at`, its radius `2 * speed_per_pitch_rate` at least, aiming half a radian round
/// ahead of itself, or at `at` in the circle's last half radian; standing ahead of `at`, it goes
/// round the far side of the smallest circle. Either way it slows as it nears `at`: its throttle is
/// the way left over `arrive_steps` times its cruise speed through its inertia, less
/// `arrive_throttle_less`.
///
/// **Improvement:** the angles, sines and cosines come from `std.math` rather than the engine's
/// tables (`sr_atan2`, `sr_sin`, `sr_cos`).
pub fn arrive(world: gameobj.World, index: u16, at: Vector, orientation: math.Matrix, least: f32) bool {
    const slot = &world.objects.slots[index];
    const object = &slot.object;
    const flight = slot.flight orelse return false;
    const off = gameobj.vector(object.root.next_position) - at;
    const reach = math.length(off);
    if (reach < arrive_reach) {
        object.throttle = least;
        object.pitch_input = 0;
        object.roll_input = 0;
        object.yaw_input = 0;
        return true;
    }
    const clear: Steering = .{ .avoid_near = true, .avoid_ahead = true };
    const local = math.transformTransposed(orientation, off);
    const slowing = arrive_steps * cruiseSpeed(object, flight, world.view) / (1 - flight.inertia);
    if (-local[2] > reach * ahead_cosine and
        math.transformTransposed(orientation, math.forward(object.root.next_orientation))[2] > facing_cosine)
    {
        _ = steer(world, index, at, full_limit, no_ease, clear);
        const up = math.transformTransposed(orientation, math.yAxis(slot.drawn.orientation));
        const roll = math.halfTurn(std.math.atan2(up[0], up[1]));
        object.roll_input = (roll - arrive_roll_damping * object.roll_rate) * arrive_roll_input;
        object.throttle = @max(reach / slowing - arrive_throttle_less, least);
        return false;
    }
    const smallest = 2 * flight.speed_per_pitch_rate;
    const side = math.normalize(.{ local[0], local[1], 0 });
    const across = math.dot(local, side);
    var radius = @abs((across * across + local[2] * local[2]) / (2 * across));
    const round = std.math.atan2(local[2], radius - across);
    var aim = if (round > -circle_lead and round < 0) 0 else round + circle_lead;
    if (local[2] > 0) {
        radius = smallest;
        aim = std.math.pi;
    } else if (radius < smallest) {
        radius = smallest;
    }
    const toward = side * @as(Vector, @splat(radius - radius * @cos(aim))) + Vector{ 0, 0, radius * @sin(aim) };
    _ = steer(world, index, math.transform(orientation, toward) + at, full_limit, no_ease, clear);
    const gone = if (round < 0) round + std.math.tau else round;
    object.throttle = @max((std.math.tau - gone) * radius / slowing - arrive_throttle_less, least);
    return false;
}

/// How near `arrive` counts as there (`0x004DC438`).
pub const arrive_reach: f32 = 2000;

/// How near the way the point faces the ship must face for `arrive` to fly straight at the point,
/// standing near its line (`ahead_cosine`): the cosine of the angle (`0x004DC434`).
const facing_cosine: f32 = 0.98;

/// How far round its circle ahead of itself `arrive` aims, in radians, and within how much of the
/// circle's end it aims at the point itself (`0x004DC408`, `0x004DC41C`).
const circle_lead: f32 = 0.5;

/// How `arrive` rolls to stand as the point's orientation stands: the roll's damping, and the turn
/// that fills the input, the angle in degrees over forty (`0x004DC42C`, `0x004DC428`).
///
/// **Improvement:** the game holds the second rounded to 1.4323944.
const arrive_roll_damping: f32 = 12;
const arrive_roll_input: f32 = std.math.deg_per_rad / 40.0;

/// How `arrive` slows the ship as it nears the point: over this many steps of its cruise speed,
/// through its inertia, and by this much less throttle (`0x004DC424`, `0x004DC420`).
const arrive_steps: f32 = 4;
const arrive_throttle_less: f32 = 0.1;

/// How long ahead, in steps, `avoidNear` looks for a meeting (`0x004DC448`).
const near_steps: f32 = 250;

/// `avoid_near` (`0x004028F0`): for each object of the ship's first avoidance list not standing in,
/// exploding or disabled, not far behind along the line to the point and closing along it, that it
/// would meet within 250 steps: where the line from where the ship goes next to the point crosses
/// that object's box where it will then be, widened by the ship's radius, the point moves onto the
/// box, widened again: to the face the line enters nearest, at the corner of it that is nearest the
/// point, one way or the other along each of its two other axes. Whether it moved the point.
///
/// **Quirk:** it scales the point by the object's visibility into the box's frame, and again out
/// of it.
pub fn avoidNear(world: gameobj.World, index: u16, point: *Vector) bool {
    const all = world.objects;
    const ship = &all.slots[index].object;
    if (ship.flags.no_avoidance) return false;
    const from = ship.nextPosition();
    const heading = math.normalize(point.* - from);
    var avoided = false;
    for (ship.avoid_near.list()) |listed| {
        const object = &all.slots[@intCast(listed)].object;
        if (object.flags.outOfSearch()) continue;
        const apart = object.nextPosition() - from;
        if (math.dot(apart, heading) < -(object.radius + ship.radius)) continue;
        const closing = gameobj.vector(object.velocity) - gameobj.vector(ship.velocity);
        if (!(math.dot(heading, closing) < 0)) continue;
        const steps = (math.length(apart) - ship.radius - object.radius) / math.length(closing);
        if (!(steps <= near_steps)) continue;

        // Where the object will be then, as it will then be turned.
        const met: math.Place = .{
            .position = object.nextPosition() + gameobj.vector(object.velocity) * @as(Vector, @splat(steps)),
            .orientation = object.root.next_orientation,
        };
        const scale: Vector = @splat(object.visibility);
        const widen: Vector = @splat(ship.radius);
        var box: [2]Vector = .{ gameobj.vector(object.bounds_min) - widen, gameobj.vector(object.bounds_max) + widen };
        const start = met.inverse(from) * scale;
        const end = met.inverse(point.*) * scale;
        const share = objects.boxEntry(start, end, box) orelse continue;
        const entry = math.lerp(start, end, share);
        box = .{ box[0] - widen, box[1] + widen };
        point.* = met.point(roundBox(box, entry, end) * scale);
        avoided = true;
    }
    return avoided;
}

/// Where `avoidNear` moves a point entering `box` at `entry` and heading for `end`: on the face
/// nearest the entry, the nearest to `end` of four points of it, at the entry along one of its
/// two other axes and at an edge of the box along the other.
fn roundBox(box_given: [2]Vector, entry_given: Vector, end: Vector) Vector {
    const box: [2][3]f32 = .{ box_given[0], box_given[1] };
    const entry: [3]f32 = entry_given;
    var face: [3]f32 = undefined;
    var nearest: f32 = std.math.floatMax(f32);
    var axis: usize = 0;
    for (0..3) |i| {
        const low = @abs(entry[i] - box[0][i]);
        const high = @abs(box[1][i] - entry[i]);
        face[i] = if (low <= high) box[0][i] else box[1][i];
        const gap = @min(low, high);
        if (gap < nearest) {
            nearest = gap;
            axis = i;
        }
    }
    const across = (axis + 1) % 3;
    const up = (axis + 2) % 3;
    var best: Vector = undefined;
    var best_distance: f32 = std.math.floatMax(f32);
    for ([4][2]f32{
        .{ entry[across], box[0][up] },
        .{ entry[across], box[1][up] },
        .{ box[0][across], entry[up] },
        .{ box[1][across], entry[up] },
    }) |pair| {
        var candidate: [3]f32 = undefined;
        candidate[axis] = face[axis];
        candidate[across] = pair[0];
        candidate[up] = pair[1];
        const distance = math.distance(candidate, end);
        if (distance < best_distance) {
            best_distance = distance;
            best = candidate;
        }
    }
    return best;
}

/// How far wide of a ship `avoidAhead` keeps, of its own side and of another, and how far it rises
/// or dips past one it would pass too near (`0x004DC438`, `0x004DC44C`).
const ahead_berth: [2]f32 = .{ 1000, 500 };
const ahead_rise: [2]f32 = .{ 2000, 1000 };

/// `avoid_ahead` (`0x00402DC0`): for a ship that lists no components, for each object of its
/// second avoidance list, where that object will be once the ship has flown to where it is now at
/// its cruise speed: where the line from where the ship goes next to the point passes within 1000
/// of it, or 500 of one of another side, the point moves as far ahead of the ship as that is, and
/// to the side of the ship's up and down axis away from it, by both their radii and 2000, or 1000
/// for another side's. Whether it moved the point.
pub fn avoidAhead(world: gameobj.World, index: u16, point: *Vector) bool {
    const all = world.objects;
    const slot = &all.slots[index];
    const ship = &slot.object;
    if (ship.flags.components or ship.flags.no_avoidance) return false;
    const flight = slot.flight orelse return false;
    const next = ship.placeAt(.next);
    const from = next.position;
    var avoided = false;
    for (ship.avoid_ahead.list()) |listed| {
        const object = &all.slots[@intCast(listed)].object;
        const toward = point.* - from;
        const steps = math.distance(object.nextPosition(), from) / cruiseSpeed(ship, flight, world.view);
        const ahead = object.nextPosition() + gameobj.vector(object.velocity) * @as(Vector, @splat(steps));
        const to_ahead = ahead - from;
        const along = math.dot(toward, to_ahead);
        const share: f32 = if (along > 0) @min(along / math.lengthSquared(toward), 1) else 0;
        const other_side: usize = @intFromBool(ship.side != object.side);
        const berth = ahead_berth[other_side];
        if (!(math.lengthSquared(toward * @as(Vector, @splat(share)) - to_ahead) < berth * berth)) continue;
        const rise = object.radius + ship.radius + ahead_rise[other_side];
        const below = math.transformTransposed(next.orientation, from - ahead)[1] < 0;
        point.* = next.point(.{ 0, if (below) -rise else rise, math.distance(from, ahead) });
        avoided = true;
    }
    return avoided;
}

/// `0x00401710`: the turns that bring `direction`, the point in the ship's own frame, onto its
/// nose. A ship flying backwards turns toward the other way about.
///
/// Within `ahead_cosine` of the nose axis it simply yaws. Further off it banks first, rolling to
/// bring the point overhead, or under it while the point is below or the pitch is held up; and it
/// pitches only once the roll is nearly right, so the ship turns the way a pilot would fly it.
fn steerAngles(object: *GameObject, direction: Vector, backward: bool, flags: Steering) void {
    var toward = math.normalize(direction);
    if (backward) toward = -toward;
    if (@abs(toward[2]) >= ahead_cosine) {
        object.yaw_input = std.math.atan2(toward[0], toward[2]);
    } else if (toward[1] < 0 or flags.pitch_up) {
        object.roll_input = -std.math.atan2(-toward[0], -toward[1]);
    } else {
        object.roll_input = -std.math.atan2(toward[0], toward[1]);
    }
    if (@abs(object.roll_input) < roll_before_pitch) object.pitch_input = -std.math.atan2(toward[1], toward[2]);
}

/// `0x00401690`: the turns for a ship whose flight stats hold a word at `+0x24`, which pitches and
/// yaws at the point together and never rolls. With the point behind it, it yaws hard to the side
/// the point lies on. Nothing in the shipped game's ship stats sets that word.
fn steerAxes(object: *GameObject, direction: Vector) void {
    if (direction[2] >= 0) {
        object.pitch_input = -std.math.atan2(direction[1], direction[2]);
        object.yaw_input = std.math.atan2(direction[0], direction[2]);
        return;
    }
    object.yaw_input = if (direction[0] < 0) -1 else 1;
}

/// `ai_roll_upright` (`0x00403170`): rolls the ship level with the world, which it does while it
/// is flying at the point it steers by.
pub fn rollUpright(object: *GameObject, at: Vector) void {
    rollToward(object, at, .{ 0, 1, 0 });
}

/// `0x00403090`: rolls the ship so that `axis` stands up in its own frame, by the same measure the
/// steering turns by. It rolls only while `at` is within `ahead_cosine` of dead ahead, so a ship
/// levels off once it is flying at what it steers by rather than while it is still coming round.
fn rollToward(object: *GameObject, at: Vector, axis: Vector) void {
    const toward = at - object.nextPosition();
    if (math.dot(toward, object.nextHeading()) <= math.length(toward) * ahead_cosine) return;
    const up = math.transformTransposed(object.root.next_orientation, axis);
    const roll = (-std.math.atan2(up[0], up[1]) - object.roll_rate * rate_damping) * input_per_radian;
    object.roll_input = std.math.clamp(roll, -1, 1);
}

/// `object_stop` (`0x00403000`): stops an object dead, keeping where it is and how it is turned.
/// **Unverified:** it lies after this file's known code, before `aidefend.cpp`'s.
pub fn stop(object: *GameObject) void {
    object.velocity = .{ .x = 0, .y = 0, .z = 0 };
    object.rotation = math.identity;
    object.letGo();
    object.lateral_input = 0;
    object.speed = 0;
    object.yaw_rate = 0;
    object.pitch_rate = 0;
    object.roll_rate = 0;
}

/// The flags that bar an object from being aimed at (`targetValid`).
pub const target_barred: GameObject.Flags = .{
    .exploding = true,
    .cloaked = true,
    .disabled = true,
    .ejected = true,
    ._unknown_28 = true,
};

/// `order_target_valid` (`0x00401870`): whether an order's target can still be aimed at. The object
/// must be targetable and none of `target_barred`, save the flags in `allowed`, and a component
/// must be one the object has and neither hidden nor spent (`objects.Model.Part.standing`).
/// **Unverified:** it lies before this file's known code.
pub fn targetValid(all: *const create.Objects, target: aigeneric.Target, allowed: GameObject.Flags) bool {
    // The game reads the index as a ship's slot, whatever the target's kind.
    const index = target.slotIn(all) orelse return false;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (!object.flags.targetable) return false;
    if (object.flags.without(allowed).within(target_barred).any()) return false;
    const component = target.part() orelse return true;
    const part = slot.component(component) orelse return false;
    return part.standing();
}

comptime {
    assert(@as(u32, @bitCast(target_barred)) == 0x10000D40);
}

test playerControlEntry {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    try std.testing.expectEqual(null, playerControlEntry(mission.objects));
    // Found below an order pushed over it.
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .player_control, .none));
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .eject_player, .none));
    const entry = playerControlEntry(mission.objects).?;
    try std.testing.expectEqual(&mission.slot(player).orders[1], entry);
}

test arrive {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const index = try mission.add(.predator, @splat(0));
    const slot = mission.slot(index);
    const world = mission.world();
    const place = struct {
        fn at(ship: *create.Slot, where: Vector) void {
            ship.object.root.next_position = gameobj.vec3(where);
            ship.object.root.next_orientation = math.identity;
            ship.drawn.position = where;
            ship.drawn.orientation = math.identity;
        }
    }.at;
    // Within reach it is there: its turns stop, its throttle the least it was given.
    place(slot, .{ 0, 0, -1000 });
    try std.testing.expect(arrive(world, index, @splat(0), math.identity, 0.3));
    try std.testing.expectEqual(0.3, slot.object.throttle);
    try std.testing.expectEqual(0, slot.object.yaw_input);
    // Behind the point on its line, facing its way, it flies straight at it, slowing as it nears.
    place(slot, .{ 0, 0, -20000 });
    try std.testing.expect(!arrive(world, index, @splat(0), math.identity, 0));
    try std.testing.expectEqual(0, slot.object.yaw_input);
    const far = slot.object.throttle;
    place(slot, .{ 0, 0, -5000 });
    _ = arrive(world, index, @splat(0), math.identity, 0);
    try std.testing.expect(slot.object.throttle < far);
    // Never slower than the least it was given.
    _ = arrive(world, index, @splat(0), math.identity, 0.9);
    try std.testing.expectEqual(0.9, slot.object.throttle);
    // Off to the side, it comes round onto the line, banking first toward the circle's point.
    place(slot, .{ 20000, 0, -20000 });
    _ = arrive(world, index, @splat(0), math.identity, 0);
    try std.testing.expect(slot.object.roll_input != 0);
}

test steer {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const index = try mission.add(.predator, @splat(0));
    const slot = &all.slots[index];

    // Dead ahead, nothing turns.
    turn(slot, .{ 0, 0, 4000 }, 1, 0, .{}, 1, false);
    try std.testing.expectEqual(0, slot.object.yaw_input);
    try std.testing.expectEqual(0, slot.object.pitch_input);
    try std.testing.expectEqual(0, slot.object.roll_input);

    // A point well off the nose is banked toward before it is pitched at.
    turn(slot, .{ 4000, 4000, 1000 }, 1, 0, .{}, 1, false);
    try std.testing.expect(@abs(slot.object.roll_input) > 0);

    // A point a little off the nose is yawed at, within the limit it is given.
    turn(slot, .{ 200, 0, 4000 }, 0.25, 0, .{}, 1, false);
    try std.testing.expectEqual(0.25, @abs(slot.object.yaw_input));
    try std.testing.expectEqual(0, slot.object.roll_input);

    // The turn rate damps the input, the less so the more the ease.
    slot.object.yaw_rate = 0.02;
    turn(slot, .{ 200, 0, 4000 }, 1, 0, .{}, 1, false);
    const damped = slot.object.yaw_input;
    turn(slot, .{ 200, 0, 4000 }, 1, 1, .{}, 1, false);
    try std.testing.expect(damped < slot.object.yaw_input);
    slot.object.yaw_rate = 0;

    // With the pitch held up it never dips below the floor, whichever way the point lies.
    slot.object.pitch_rate = 1;
    turn(slot, .{ 0, -4000, 1000 }, 1, 0, .{ .pitch_up = true }, 1, false);
    try std.testing.expectEqual(pitch_floor, slot.object.pitch_input);
}

test "a ship steered at a point comes round to face it" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const index = try mission.add(.predator, @splat(0));
    const slot = &all.slots[index];
    const at: Vector = .{ 20000, 6000, 10000 };

    const off = struct {
        /// How far the point lies off the ship's nose, in radians.
        fn angle(ship: *const create.Slot, point: Vector) f32 {
            const toward = math.normalize(point - gameobj.vector(ship.object.root.position));
            return std.math.acos(std.math.clamp(math.dot(toward, math.forward(ship.object.root.orientation)), -1, 1));
        }
    }.angle;

    const before = off(slot, at);
    for (0..50) |_| {
        turn(slot, at, 1, 0, .{ .roll_upright = true }, 1, false);
        motion.move(&slot.object, .{ .own = slot.flight.? }, .chase, .forward, null, .{});
        // What the next step commits, which the steering then reads.
        slot.object.root.position = slot.object.root.next_position;
        slot.object.root.orientation = slot.object.root.next_orientation;
        slot.drawn = .{ .position = gameobj.vector(slot.object.root.position), .orientation = slot.object.root.orientation };
    }
    try std.testing.expect(off(slot, at) < before / 4);
}

test "a slow frame halves the small turns" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const index = try mission.add(.predator, @splat(0));
    const slot = &all.slots[index];

    turn(slot, .{ 200, 0, 4000 }, 1, 0, .{}, slow_frame, false);
    const quick = slot.object.yaw_input;
    turn(slot, .{ 200, 0, 4000 }, 1, 0, .{}, slow_frame + 1, false);
    try std.testing.expectApproxEqAbs(quick * 0.5, slot.object.yaw_input, 1e-6);
}

test alongNose {
    const place: math.Place = .{ .position = .{ 0, 0, 100 } };
    // Ahead and near the line, it is; behind, or wide of it, it isn't.
    try std.testing.expect(alongNose(place, .{ 5, 0, 1000 }, 10));
    try std.testing.expect(!alongNose(place, .{ 5, 0, 0 }, 10));
    try std.testing.expect(!alongNose(place, .{ 50, 0, 1000 }, 10));
}

test cosineOff {
    // Dead ahead, square across and straight behind.
    try std.testing.expectEqual(1, cosineOff(.{ 0, 0, 20 }, .{ 0, 0, 1 }));
    try std.testing.expectEqual(0, cosineOff(.{ 20, 0, 0 }, .{ 0, 0, 1 }));
    try std.testing.expectEqual(-1, cosineOff(.{ 0, 0, -5 }, .{ 0, 0, 1 }));
    try std.testing.expectApproxEqAbs(0.6, cosineOff(.{ 4, 0, 3 }, .{ 0, 0, 1 }), 1e-6);
}

test noseCosine {
    // Turned a quarter about Y, the nose points along X.
    const turned = math.rotation(.y, std.math.pi / 2.0);
    try std.testing.expectApproxEqAbs(1, noseCosine(turned, .{ 30, 0, 0 }), 1e-6);
    try std.testing.expectApproxEqAbs(0.8, noseCosine(math.identity, .{ 3, 0, 4 }), 1e-6);
}

test escapeDirection {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var hull: create.testing.Model = undefined;
    try hull.init(gpa);
    defer hull.deinit(gpa);
    hull.withHull();
    const index = try create.createObject(mission.objects, &mission.tables, hull.types(), null, .reaper, 0, @splat(0), &mission.random);
    const slot = mission.slot(index);
    slot.model.?.place(slot.drawn.position, slot.drawn.orientation);

    // Near the hull's box, the way out is straight away from it.
    const out = escapeDirection(slot, .{ 0, 0, 5000 });
    try std.testing.expectApproxEqAbs(1, out[2], 1e-6);
    try std.testing.expectApproxEqAbs(0, out[0], 1e-6);
    // Beyond `escape_reach` nothing pushes, and the way out is what `math.normalize` makes of
    // nothing.
    try std.testing.expectEqual(math.normalize(@splat(0)), escapeDirection(slot, .{ 0, 0, 2 * escape_reach }));
}

test "aiming at a target" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ship = try mission.add(.predator, @splat(0));
    const target = try mission.add(.sabre, .{ 0, 0, 1000 });
    const struck = &all.slots[target];
    struck.drawn = .{ .position = .{ 0, 0, 1000 }, .orientation = math.rotation(.y, std.math.pi / 2.0) };
    struck.object.speed = 10;
    const aimed: aigeneric.Target = .at(target, null);
    try std.testing.expectEqual(Vector{ 0, 0, 1000 }, aimedAt(all, aimed).position);

    // With no gun fast enough to reach it in a quarter of its life, it isn't led.
    const laser = &all.gun_stats.types[guns.GunType.laser_cannon.number()];
    laser.speed = 100;
    laser.lifetime = 20;
    try std.testing.expectEqual(null, leadAim(all, ship, aimed, 1));
    // With one, it is led along its heading by how far it flies while the shot does.
    laser.lifetime = 100;
    const led = leadAim(all, ship, aimed, 1).?;
    try std.testing.expectApproxEqAbs(100, led[0], 1e-3);
    try std.testing.expectApproxEqAbs(1000, led[2], 1e-3);

    // A Turret Flak's shot is led within three of its lifetimes.
    const flak = &all.gun_stats.types[guns.GunType.turret_flak.number()];
    flak.speed = 100;
    flak.lifetime = 13;
    try std.testing.expectEqual(null, leadAimWithGun(all, @splat(0), aimed, .turret_flak, 1));
    flak.lifetime = 14;
    try std.testing.expect(leadAimWithGun(all, @splat(0), aimed, .turret_flak, 1) != null);
}

test collisionCourse {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const world = mission.world();
    const all = mission.objects;
    const ship = try mission.add(.predator, @splat(0));
    const target = try mission.add(.sabre, .{ 0, 0, 2000 });
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 50 };

    // Flying straight at it, it is on course to hit; turned away, or past it, it isn't.
    try std.testing.expect(collisionCourse(world, ship, target, 100, 500));
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = -50 };
    try std.testing.expect(!collisionCourse(world, ship, target, 100, 500));
    all.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 50 };
    all.slots[target].object.root.next_position = .{ .x = 0, .y = 0, .z = -2000 };
    try std.testing.expect(!collisionCourse(world, ship, target, 100, 500));
}

test rollUpright {
    var object = gameobj.testing.object();
    object.root.next_orientation = math.rotation(.z, 0.5);
    // Rolled over, with the point it steers by dead ahead, it rolls back level.
    rollUpright(&object, .{ 0, 0, 1000 });
    try std.testing.expect(object.roll_input < 0);
    // With the point off to the side it holds its roll.
    object.roll_input = 0;
    rollUpright(&object, .{ 1000, 0, 0 });
    try std.testing.expectEqual(0, object.roll_input);
}

test stop {
    var object = gameobj.testing.object();
    object.velocity = .{ .x = 1, .y = 2, .z = 3 };
    object.speed = 10;
    object.throttle = 1;
    object.yaw_rate = 0.5;
    object.rotation = math.rotation(.y, 0.1);
    stop(&object);
    try std.testing.expectEqual(0, object.speed);
    try std.testing.expectEqual(0, object.velocity.z);
    try std.testing.expectEqual(0, object.throttle);
    try std.testing.expectEqual(0, object.yaw_rate);
    try std.testing.expectEqual(math.identity, object.rotation);
}

test avoidAhead {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const world = mission.world();
    const ship = try mission.addOther(@splat(0));
    const other = try mission.addOther(.{ 0, 0, 5000 });
    const object = &mission.slot(ship).object;
    object.radius = 100;
    mission.slot(other).object.radius = 200;
    object.avoid_ahead.add(other);

    // A point beyond the other ship, of the same side: the ship steers over it, as far ahead as it
    // is, by both radii and 2000.
    var point: Vector = .{ 0, 0, 20000 };
    try std.testing.expect(avoidAhead(world, ship, &point));
    try std.testing.expectEqual(Vector{ 0, 2300, 5000 }, point);
    // Well wide of it, the point stands.
    point = .{ 20000, 0, 20000 };
    try std.testing.expect(!avoidAhead(world, ship, &point));
    // A ship told not to avoid avoids nothing.
    object.flags.no_avoidance = true;
    point = .{ 0, 0, 20000 };
    try std.testing.expect(!avoidAhead(world, ship, &point));
}

test avoidNear {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const world = mission.world();
    const ship = try mission.addOther(@splat(0));
    const hull = try mission.addOther(.{ 0, 0, 5000 });
    const object = &mission.slot(ship).object;
    object.radius = 100;
    object.velocity = .{ .x = 0, .y = 0, .z = 50 };
    const big = &mission.slot(hull).object;
    big.flags.components = true;
    big.radius = 1000;
    big.visibility = 1;
    big.bounds_min = .{ .x = -1000, .y = -500, .z = -1000 };
    big.bounds_max = .{ .x = 1000, .y = 500, .z = 1000 };
    object.avoid_near.add(hull);

    // Closing on the hull, the line to the point crosses its box: the point moves onto the box's
    // face it enters nearest, widened twice by the ship's radius, at the corner nearest the point.
    var point: Vector = .{ 0, 0, 20000 };
    try std.testing.expect(avoidNear(world, ship, &point));
    try std.testing.expectEqual(Vector{ 0, -700, 3800 }, point);
    // Heading away from it, the point stands.
    object.velocity = .{ .x = 0, .y = 0, .z = -50 };
    point = .{ 0, 0, 20000 };
    try std.testing.expect(!avoidNear(world, ship, &point));
}
