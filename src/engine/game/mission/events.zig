//! The mission's events (`mission.cpp`). The game's code posts each as it happens, where a trigger
//! would answer it (`vm.triggers.wouldFire`), to the queue that the frame then raises on the
//! script's triggers (`event_post`, `event_post_group`, `events_flush`); the routines here post
//! each kind. Once a second the watches of the proximity conditions look for ships close by.
//! [docs/engine/script-vm.md](../../../../docs/engine/script-vm.md#events) describes them.
//!
//! **Unverified:** the queue's own routines (`0x0045B690` to `0x0045B840`) lie past this file's
//! known code, before the interpreter's; they do its queue's work.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.mission);

const dte = @import("../../../formats/dte.zig");
const math = @import("../../surrender/math.zig");
const vm = @import("../../vm.zig");
const gameobj = @import("../gameobj.zig");

const triggers = vm.triggers;
const Event = triggers.Event;

/// The events waiting for the frame, and the watches of the proximity conditions.
pub const Events = struct {
    gpa: Allocator,
    /// The script whose triggers the events are raised on.
    script: *vm.Machine,
    /// `event_queue` (`0x0052ABD8`), `count` of them waiting (`event_queue_count`, `0x005373E4`).
    waiting: [capacity]Queued = undefined,
    count: usize = 0,
    /// `0x00545860`: set while a collision's test against a hull runs again, which holds back the
    /// ShotAt of the knocks it deals (`objects_collide`).
    shots_held: bool = false,
    /// Whether an event past the queue's room has been logged.
    overflowed: bool = false,
    /// The watches of CloseProximity, Proximity and ShipReached.
    watches: std.EnumArray(Watched, []Watch) = .initFill(&.{}),

    /// The events the queue has room for, past which the game stops (`0x0045B330`).
    pub const capacity = 1000;

    /// The queue of a mission that starts, empty (`init_mission`, `0x0045A4E0`), for `script`.
    pub fn init(gpa: Allocator, script: *vm.Machine) Events {
        return .{ .gpa = gpa, .script = script };
    }

    pub fn deinit(events: *Events) void {
        for (&events.watches.values) |list| events.gpa.free(list);
        events.watches = .initFill(&.{});
    }

    /// `event_post` (`0x0045B7C0`): queues `event` on the mission's ship `ship`, where one of the
    /// ship's own triggers would answer it.
    pub fn post(events: *Events, ship: u16, event: Event) void {
        if (!triggers.wouldFire(events.script, events.objectOf(ship), event)) return;
        events.take(false, ship, event);
    }

    /// `event_post_group` (`0x0045B690`): queues `event` on the mission's ship `ship`, to be raised
    /// on its flight group and on the squads that hold it too, where a trigger would answer it:
    /// the ship's own, or its flight group's, or one of a squad's that holds it (`Machine.inSquad`,
    /// as the component the event concerns), in that order, each group only where its slice holds
    /// triggers. A group's triggers answer the event as one on the group itself.
    pub fn postGroup(events: *Events, ship: u16, event: Event) void {
        if (!events.anyWouldFire(ship, event)) return;
        events.take(true, ship, event);
    }

    fn anyWouldFire(events: *Events, ship: u16, event: Event) bool {
        const machine = events.script;
        if (triggers.wouldFire(machine, events.objectOf(ship), event)) return true;
        const file = machine.mission.file;
        const on_group: Event = .{ .condition = event.condition, .values = event.values };
        const ships = file.ships() catch return false;
        if (ship >= ships.len) return false;
        if (ships[ship].flightGroup()) |index| {
            const groups = file.flightGroups() catch return false;
            if (index < groups.len) {
                const group = groups[index].object_id;
                if (triggers.holdsTriggers(machine, group) and triggers.wouldFire(machine, group, on_group)) return true;
            }
        }
        const squads = file.squads() catch return false;
        const place = machine.recordPlace(.ships, ship);
        for (squads, 0..) |squad, index| {
            if (!triggers.holdsTriggers(machine, squad.object_id)) continue;
            const holds = machine.inSquad(machine.recordPlace(.squads, index), place, event.qualifier, 0) catch false;
            if (holds and triggers.wouldFire(machine, squad.object_id, on_group)) return true;
        }
        return false;
    }

    /// Takes `event` on the ship `ship` into the queue, once `0x0045B330` has looked at its room.
    ///
    /// **Fix:** the game stops with the assertion "Trigger List exceeded" once a thousand events
    /// wait, listing them first; OpenReliant passes over each event past them, and logs it once.
    fn take(events: *Events, groups: bool, ship: u16, event: Event) void {
        if (events.count >= capacity) {
            if (!events.overflowed) log.warn("more than {d} events in a frame; the rest are passed over", .{capacity});
            events.overflowed = true;
            return;
        }
        const count = @min(event.values.len, max_values);
        var queued: Queued = .{ .groups = groups, .ship = ship, .condition = event.condition, .qualifier = event.qualifier, .count = @intCast(count) };
        @memcpy(queued.values[0..count], event.values[0..count]);
        events.waiting[events.count] = queued;
        events.count += 1;
    }

    /// `events_flush` (`0x0045B840`), once a frame from `mission_frame`, before the script runs:
    /// each event waiting, in turn, is raised on its ship's object (`vm.triggers.raise`) and, where
    /// it was posted for them, on the ship's flight group and squads
    /// (`vm.triggers.raiseOnGroups`). An event that a trigger's thread posts as it runs at once
    /// waits its turn in the same pass. Then the queue is empty.
    pub fn flush(events: *Events) void {
        const machine = events.script;
        var at: usize = 0;
        while (at < events.count) : (at += 1) {
            const queued = &events.waiting[at];
            const ships = machine.mission.ships() catch break;
            if (queued.ship >= ships.len) continue;
            const event: Event = .{ .condition = queued.condition, .qualifier = queued.qualifier, .values = queued.values[0..queued.count] };
            triggers.raise(machine, events.objectOf(queued.ship), event);
            if (queued.groups) triggers.raiseOnGroups(machine, queued.ship, event);
        }
        events.count = 0;
    }

    /// The object ID of the mission's ship `ship`, which its triggers are held by.
    fn objectOf(events: *const Events, ship: u16) u16 {
        const ships = events.script.mission.ships() catch return triggers.no_object;
        return if (ship < ships.len) @truncate(ships[ship].object_id) else triggers.no_object;
    }

    /// The mission's ship the object in slot `index` stands for (`object_ship`, `0x0045A970`): a
    /// mission's ship takes the slot of its index, so the ship of the slot's index, and none past
    /// the mission's ships.
    fn shipOf(events: *const Events, index: u16) ?u16 {
        const ships = events.script.mission.ships() catch return null;
        return if (index < ships.len) index else null;
    }

    /// What an event names the object in slot `index` by: where the record of the mission's ship
    /// it stands for lies, or 0 for none.
    fn value(events: *const Events, index: ?u16) u32 {
        const ship = events.shipOf(index orelse return none) orelse return none;
        return events.script.recordPlace(.ships, ship);
    }

    /// `0x0045AE10`, as the mission's tables are made (`mission_bind_tables`): a watch for each
    /// trigger of CloseProximity, Proximity and ShipReached, in the trigger list's order, on the
    /// object whose slice holds it, each armed. A trigger of the player's ship watches for the
    /// other players' ships too, with a watch on each of them.
    ///
    /// **Fix:** the game writes the lists into tables of a fixed size without looking at their
    /// room; OpenReliant makes them as long as the mission needs.
    pub fn watch(events: *Events, players: u16) !void {
        events.deinit();
        const file = events.script.mission.file;
        const all = try file.triggers();
        const ships = try file.ships();
        const owners = try file.triggerObjects(events.gpa);
        defer events.gpa.free(owners);
        for (std.enums.values(Watched)) |watched| {
            var list: std.ArrayList(Watch) = .empty;
            errdefer list.deinit(events.gpa);
            for (all, owners, 0..) |trigger, owner, index| {
                if (trigger.condition != watched.condition()) continue;
                try list.append(events.gpa, .{ .trigger = @intCast(index), .object = owner });
                if (!events.playersShip(owner)) continue;
                var other: usize = 1;
                while (other < players and other < ships.len) : (other += 1) {
                    try list.append(events.gpa, .{ .trigger = @intCast(index), .object = @truncate(ships[other].object_id) });
                }
            }
            events.watches.set(watched, try list.toOwnedSlice(events.gpa));
        }
    }

    /// Whether the object `object` is the player's ship, the mission's first.
    fn playersShip(events: *const Events, object: ?u16) bool {
        const id = object orelse return false;
        const record = events.script.mission.records[id] orelse return false;
        return switch (record) {
            .ship => |ship| ship == 0,
            else => false,
        };
    }

    /// `0x0045B2D0`: each watch of trigger `trigger` is armed, or not, as the script arms the
    /// trigger (`SetTriggerState`).
    pub fn arm(events: *Events, trigger: u16, armed: bool) void {
        for (&events.watches.values) |list| {
            for (list) |*each| {
                if (each.trigger == trigger) each.armed = armed;
            }
        }
    }

    /// `0x0045AF60`, once the script's clock has ticked, after the timers
    /// (`mission.Loaded.process`): the watches look for ships close by (`scan`), each on a mission's
    /// ship that is not destroyed and whose object is no stand-in, while the script has it armed.
    /// CloseProximity's look within `close_reach` of the ship's radii, once a ship; each of
    /// Proximity's within its trigger's distance, in the ship's radii; and ShipReached's, on a
    /// waypoint or a nav point, within `reached_reach`, once a ship.
    pub fn checkProximity(events: *Events, world: gameobj.World) void {
        const ships = events.script.mission.ships() catch return;
        const all = world.objects;
        const all_triggers = events.script.mission.file.triggers() catch return;
        for (std.enums.values(Watched)) |watched| {
            const list = events.watches.get(watched);
            if (list.len == 0) continue;
            for (ships, 0..) |ship, index| {
                if (ship.flags.destroyed or index >= all.slots.len) continue;
                const object = &all.slots[index].object;
                if (object.type == .stand_in) continue;
                const id: u16 = @truncate(ship.object_id);
                switch (watched) {
                    .close => {
                        if (firstArmed(list, id) == null) continue;
                        const reach = object.radius * close_reach;
                        const squared = reach * reach;
                        if (squared > 0) events.scan(world, @intCast(index), squared, .proximity_close);
                    },
                    .proximity => for (list) |each| {
                        if (each.object != id or !each.armed or each.trigger >= all_triggers.len) continue;
                        const distance = all_triggers[each.trigger].operands[proximity_operand];
                        if (@as(u16, @truncate(distance)) == dte.Reference.unset) continue;
                        const reach = @as(f32, @floatFromInt(distance)) * object.radius;
                        events.scan(world, @intCast(index), reach * reach, .proximity_general);
                    },
                    .reached => {
                        if (ship.kind != dte.Ship.waypoint_kind and ship.kind != nav_point_kind) continue;
                        if (firstArmed(list, id) == null) continue;
                        events.scan(world, @intCast(index), reached_reach * reached_reach, .ship_reached);
                    },
                }
            }
        }
    }

    /// `0x0045B170`: each mission's ship but `subject`, not destroyed and whose object is no
    /// stand-in, whose object stands within the square root of `reach` of the subject's, has the
    /// subject's event posted for the subject's own triggers: for ShipReached, with the ship; for
    /// the proximity conditions, with the ship and how far it stands, in the subject's radii,
    /// truncated.
    fn scan(events: *Events, world: gameobj.World, subject: u16, reach: f32, condition: dte.Condition) void {
        const ships = events.script.mission.ships() catch return;
        const all = world.objects;
        const own = &all.slots[subject].object;
        for (ships, 0..) |ship, index| {
            if (ship.flags.destroyed or index == subject or index >= all.slots.len) continue;
            const other = &all.slots[index].object;
            if (other.type == .stand_in) continue;
            const apart = gameobj.vector(own.root.position) - gameobj.vector(other.root.position);
            const squared = apart * apart;
            const distance = squared[2] + squared[1] + squared[0];
            if (!(distance <= reach)) continue;
            var values = [_]u32{ events.script.recordPlace(.ships, index), 0 };
            switch (condition) {
                .ship_reached => events.post(subject, .{ .condition = condition, .values = values[0..1] }),
                .proximity_close, .proximity_general => {
                    values[1] = @bitCast(math.ftol(@sqrt(distance) / own.radius));
                    events.post(subject, .{ .condition = condition, .values = &values });
                },
                else => {},
            }
        }
    }
};

/// An event waiting in the queue (`vm.QueuedEvent`).
const Queued = struct {
    /// Whether it goes on to its ship's flight group and the squads that hold it
    /// (`event_post_group`).
    groups: bool,
    /// The mission's ship it happened to.
    ship: u16,
    condition: dte.Condition,
    qualifier: u8,
    values: [max_values]u32 = undefined,
    count: u8,
};

/// The values a waiting event has room for (`vm.QueuedEvent.values`).
const max_values = 8;

/// What an event names no ship by.
const none: u32 = 0;

/// What the watches of each list watch for.
pub const Watched = enum {
    /// CloseProximity's (`0x00536DD8`): a ship within `close_reach` of the subject's radii.
    close,
    /// Proximity's (`0x00536758`): a ship within the trigger's distance, in the subject's radii.
    proximity,
    /// ShipReached's (`0x0052A5D0`): a ship within `reached_reach` of a waypoint or a nav point.
    reached,

    /// The condition of the triggers the list watches for.
    pub fn condition(watched: Watched) dte.Condition {
        return switch (watched) {
            .close => .proximity_close,
            .proximity => .proximity_general,
            .reached => .ship_reached,
        };
    }
};

/// A watch: a trigger of the watched condition, the object whose slice holds it, and whether the
/// script has it armed.
pub const Watch = struct {
    trigger: u16,
    /// The object's ID, or null where no slice holds the trigger, which watches for nothing.
    object: ?u16,
    armed: bool = true,
};

/// The first armed watch on the object `object`.
fn firstArmed(list: []const Watch, object: u16) ?Watch {
    for (list) |each| {
        if (each.object == object and each.armed) return each;
    }
    return null;
}

/// How far CloseProximity's watches look, in the subject's radii (`0x004DC72C`).
const close_reach: f32 = 20;

/// How far ShipReached's watches look (`0x4B742400`, its square).
const reached_reach: f32 = 4000;

/// The operand of a Proximity trigger that gives its distance, in the subject's radii.
const proximity_operand = 1;

/// The kind of a mission's nav points, which ShipReached's watches look from as from a waypoint.
const nav_point_kind = 999;

/// What an event names no weapon by: ShotAt's weapon is always so.
const no_weapon: u32 = 0xFFFF_FFFF;

/// `event_launched` (`0x0045A9B0`): the object in slot `index` has launched. Its ship's Launched,
/// with the ship, goes on to its groups.
pub fn launched(world: gameobj.World, index: u16) void {
    postWithShip(world, index, .launched);
}

/// `event_jumped_in` (`0x0045B300`): the object in slot `index` has jumped in (`jump.inUpdate`).
/// Its ship's JumpedIn, with the ship, goes on to its groups.
pub fn jumpedIn(world: gameobj.World, index: u16) void {
    postWithShip(world, index, .jumped_in);
}

/// The ship of the object in slot `index` posts `condition` with itself as its value, which goes
/// on to its groups, as `event_launched`, `event_jumped_in` and `event_post_explosion` do. An
/// object that stands for no mission's ship posts nothing.
fn postWithShip(world: gameobj.World, index: u16, condition: dte.Condition) void {
    const events = world.events orelse return;
    const ship = events.shipOf(index) orelse return;
    var values = [_]u32{events.value(index)};
    events.postGroup(ship, .{ .condition = condition, .values = &values });
}

/// `event_shot_at` (`0x0045A9E0`): the object in slot `index` is hit by the one in slot
/// `attacker`, on its component `component` or on itself (`dte.Trigger.whole_object`). Its ship's
/// ShotAt goes on to its groups, with the attacker's ship, its own damage value for the shields
/// and for the hull alike (`vm.triggers.damageValue`), the ship itself, and no weapon. A hit by
/// what stands for no mission's ship posts nothing.
pub fn shotAt(world: gameobj.World, index: u16, attacker: u16, component: u8) void {
    const events = world.events orelse return;
    const ship = events.shipOf(index) orelse return;
    if (events.shipOf(attacker) == null) return;
    const damage = triggers.damageValue(world, ship, component);
    var values = [_]u32{ events.value(attacker), damage, damage, events.value(index), no_weapon };
    events.postGroup(ship, .{ .condition = .shot_at, .qualifier = component, .values = &values });
}

/// `event_destroyed` (`0x0045AA60`): the object in slot `index` is destroyed, or its component
/// `component`, which its ship's record notes: the ship's own Destroyed comes only once
/// (`dte.Ship.Flags.destroyed`), and a component clears its bit (`dte.Ship.intact_components`).
/// Its ship's Destroyed goes on to its groups, with the ship of what last struck it
/// (`GameObject.last_attacker`) and the ship itself.
pub fn destroyed(world: gameobj.World, index: u16, component: u8) void {
    const events = world.events orelse return;
    const ship = events.shipOf(index) orelse return;
    if (index >= world.objects.slots.len) return;
    const records = events.script.mission.ships() catch return;
    const record = &records[ship];
    var values = [_]u32{ events.value(world.objects.slots[index].object.last_attacker.index()), events.value(index) };
    if (component == dte.Trigger.whole_object) {
        if (record.flags.destroyed) return;
        record.flags.destroyed = true;
    } else {
        record.intact_components &= ~(@as(u32, 1) << @truncate(component));
    }
    events.postGroup(ship, .{ .condition = .destroyed, .qualifier = component, .values = &values });
}

/// `0x0045AAD0`: the object in slot `index` has taken the one in slot `object` aboard
/// (`order_scoop_up`). Its ship's ObjectScooped, with the ship of what it took, goes on to its
/// groups.
pub fn scooped(world: gameobj.World, index: u16, object: u16) void {
    const events = world.events orelse return;
    const ship = events.shipOf(index) orelse return;
    var values = [_]u32{events.value(object)};
    events.postGroup(ship, .{ .condition = .object_scooped, .values = &values });
}

/// `event_post_explosion` (`0x0045AB50`): the explosion that the object in slot `index` set off is
/// over. Its ship's ExplosionShip, with the ship, goes on to its groups.
pub fn exploded(world: gameobj.World, index: u16) void {
    postWithShip(world, index, .explosion_ship);
}

/// The object in slot `index` cloaks, or uncloaks (`object_cloak`, `object_uncloak`): its ship's
/// Cloaked or Decloaked, with no values, for its own triggers.
///
/// **Fix:** the game faults on an object that stands for no mission's ship; OpenReliant posts
/// nothing.
pub fn cloaked(world: gameobj.World, index: u16, on: bool) void {
    const events = world.events orelse return;
    const ship = events.shipOf(index) orelse return;
    events.post(ship, .{ .condition = if (on) .cloaked else .decloaked });
}

/// JUMP DRIVE took the jump the mission had ready, or the warp (`player_jump`): the player's ship,
/// the mission's first, has its PlayerReadyToJump or its PlayerReadyToWarp, with no values, for its
/// own triggers.
pub fn readyToJump(world: gameobj.World, warp: bool) void {
    const events = world.events orelse return;
    const player = events.shipOf(0) orelse return;
    events.post(player, .{ .condition = if (warp) .player_ready_to_warp else .player_ready_to_jump });
}

/// A mission for the tests: a script with its events, and a world of objects that stand for its
/// ships, one a slot, whose events the world posts.
const TestMission = struct {
    fixture: vm.machine.testing.Fixture,
    game: gameobj.testing.Mission,
    events: Events,

    /// `parts` and `records` make the script; an object of the ship's slot stands at each of `at`,
    /// with a radius of `test_radius`.
    fn init(mission: *TestMission, parts: []const vm.machine.testing.Part, records: vm.machine.testing.Records, at: []const math.Vector) !void {
        const gpa = std.testing.allocator;
        try mission.fixture.init(gpa, parts, records);
        errdefer mission.fixture.deinit();
        try mission.game.init(gpa);
        errdefer mission.game.deinit();
        for (at) |place| {
            const index = try mission.game.add(.predator, place);
            mission.game.slot(index).object.radius = test_radius;
        }
        mission.events = .init(gpa, &mission.fixture.machine);
        errdefer mission.events.deinit();
        try mission.events.watch(1);
        try mission.fixture.machine.start();
        mission.fixture.machine.game = .{ .world = mission.world(), .clock = &mission.game.clock };
    }

    fn deinit(mission: *TestMission) void {
        mission.events.deinit();
        mission.game.deinit();
        mission.fixture.deinit();
    }

    fn world(mission: *TestMission) gameobj.World {
        var seen = mission.game.world();
        seen.events = &mission.events;
        return seen;
    }

    const test_radius: f32 = 100;
};

/// Ships of the test missions, each in no flight group, its object ID its index.
fn testShips(comptime count: usize) [count]dte.Ship {
    var ships: [count]dte.Ship = undefined;
    for (&ships, 0..) |*ship, index| ship.* = std.mem.zeroInit(dte.Ship, .{ .object_id = @as(u32, @intCast(index)), .flight_group = dte.Ship.no_flight_group });
    return ships;
}

test "an event waits where a trigger would answer it, and goes off with the frame" {
    const gpa = std.testing.allocator;
    const code = try triggers.testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]vm.machine.testing.Part{.{ .code = code }};
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{0},
        .ships = &testShips(2),
        .objects = &.{ triggers.testing.object(.ship, 0, 1), triggers.testing.object(.ship, 1, 0) },
        .triggers = &.{triggers.testing.trigger(&parts, 0, .launched, .always)},
    }, &.{ @splat(0), .{ 1000, 0, 0 } });
    defer mission.deinit();

    // No trigger of ship 1's answers its launch.
    launched(mission.world(), 1);
    try std.testing.expectEqual(0, mission.events.count);
    // Ship 0's waits for the frame.
    launched(mission.world(), 0);
    try std.testing.expectEqual(1, mission.events.count);
    try std.testing.expectEqual(0, mission.fixture.global(0));
    mission.events.flush();
    try std.testing.expectEqual(1, mission.fixture.global(0));
    try std.testing.expectEqual(0, mission.events.count);
}

test "a ship's Destroyed comes once, and a component's clears its bit" {
    const gpa = std.testing.allocator;
    const whole = try triggers.testing.counting(gpa, 0);
    defer gpa.free(whole);
    const part = try triggers.testing.counting(gpa, 1);
    defer gpa.free(part);
    const parts = [_]vm.machine.testing.Part{ .{ .code = whole }, .{ .code = part } };
    var on_component = triggers.testing.trigger(&parts, 1, .destroyed, .always);
    on_component.qualifier = 3;
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{ 0, 0 },
        .ships = &testShips(2),
        .objects = &.{ triggers.testing.object(.ship, 0, 2), triggers.testing.object(.ship, 2, 0) },
        .triggers = &.{ triggers.testing.trigger(&parts, 0, .destroyed, .always), on_component },
    }, &.{ @splat(0), .{ 1000, 0, 0 } });
    defer mission.deinit();
    const machine = &mission.fixture.machine;
    const records = try mission.fixture.mission.ships();

    // Ship 1 struck it last: the event names it the killer, and the ship keeps the event.
    mission.game.slot(0).object.last_attacker = .of(1);
    destroyed(mission.world(), 0, dte.Trigger.whole_object);
    destroyed(mission.world(), 0, dte.Trigger.whole_object);
    mission.events.flush();
    try std.testing.expectEqual(1, mission.fixture.global(0));
    try std.testing.expect(records[0].flags.destroyed);
    try std.testing.expectEqual(machine.recordPlace(.ships, 1), machine.event_values[0].destroyed[0]);
    // Component 3's answers its own trigger alone.
    destroyed(mission.world(), 0, 3);
    mission.events.flush();
    try std.testing.expectEqual(1, mission.fixture.global(0));
    try std.testing.expectEqual(1, mission.fixture.global(1));
    try std.testing.expectEqual(~@as(u32, 1 << 3), records[0].intact_components);
}

test "JUMP DRIVE takes the jump the mission has ready" {
    const gpa = std.testing.allocator;
    const code = try triggers.testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]vm.machine.testing.Part{.{ .code = code }};
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{0},
        .ships = &testShips(1),
        .objects = &.{triggers.testing.object(.ship, 0, 1)},
        .triggers = &.{triggers.testing.trigger(&parts, 0, .player_ready_to_jump, .always)},
    }, &.{@splat(0)});
    defer mission.deinit();
    const machine = &mission.fixture.machine;
    const input = @import("../../input.zig");

    // Nothing ready, nothing happens.
    input.playerJump(mission.world());
    try std.testing.expectEqual(0, mission.events.count);
    // A jump ready is taken, the clock noting when.
    machine.variables.ready.jump = .shown;
    machine.clock = 7;
    input.playerJump(mission.world());
    mission.events.flush();
    try std.testing.expectEqual(1, mission.fixture.global(0));
    try std.testing.expectEqual(.no, machine.variables.ready.jump);
    try std.testing.expectEqual(7, machine.last_jumped);
}

test "the watches look for ships close by, while their triggers are armed" {
    const gpa = std.testing.allocator;
    const near = try triggers.testing.counting(gpa, 0);
    defer gpa.free(near);
    const close = try triggers.testing.counting(gpa, 1);
    defer gpa.free(close);
    const disarm = disarm: {
        var routine: vm.machine.testing.Routine = .init(gpa);
        defer routine.deinit();
        try routine.op(.push_ship, &.{1});
        try routine.op(.push_byte, &.{@intFromEnum(dte.Condition.proximity_general)});
        try routine.op(.push_byte, &.{0});
        try routine.command("SetTriggerState");
        try routine.op(.push_byte, &.{1});
        try routine.op(.@"return", &.{});
        break :disarm try routine.finish();
    };
    defer gpa.free(disarm);
    const parts = [_]vm.machine.testing.Part{ .{ .code = near }, .{ .code = close }, .{ .code = disarm } };
    // Ship 1 watches for the player's ship within 15 of its radii, and for any ship within 20.
    var proximity = triggers.testing.trigger(&parts, 0, .proximity_general, .always);
    proximity.operands[0] = 0;
    proximity.operands[1] = 15;
    const close_by = triggers.testing.trigger(&parts, 1, .proximity_close, .always);
    var mission: TestMission = undefined;
    try mission.init(&parts, .{
        .globals = &.{ 0, 0 },
        .ships = &testShips(3),
        .objects = &.{ triggers.testing.object(.ship, 0, 0), triggers.testing.object(.ship, 0, 2), triggers.testing.object(.ship, 2, 0) },
        .triggers = &.{ proximity, close_by },
    }, &.{ .{ 1000, 0, 0 }, @splat(0), .{ 0, 0, 1800 } });
    defer mission.deinit();
    const machine = &mission.fixture.machine;

    // The player's ship, 10 radii off, answers both; ship 2, 18 off, the close watch alone.
    mission.events.checkProximity(mission.world());
    mission.events.flush();
    try std.testing.expectEqual(1, mission.fixture.global(0));
    try std.testing.expectEqual(2, mission.fixture.global(1));
    // Disarmed, the Proximity trigger's watch looks no more.
    _ = machine.startThread(mission.fixture.mission.parts[2].block, null, false, null, null);
    try std.testing.expectEqual(0, (try mission.fixture.mission.file.triggers())[0].armed);
    try std.testing.expect(!mission.events.watches.get(.proximity)[0].armed);
    mission.events.checkProximity(mission.world());
    mission.events.flush();
    try std.testing.expectEqual(1, mission.fixture.global(0));
    try std.testing.expectEqual(4, mission.fixture.global(1));
}
