//! The triggers at run time. An event raised on an object fires each of the object's triggers that
//! answers it (`trigger_raise_event`, `trigger_match`), and an event on a ship goes on to its
//! flight group and to the squads that hold it, once the condition's handlers have given their
//! verdict on the group (`condition_raise`). The mission's queue raises the events
//! ([`game/mission/events.zig`](../game/mission/events.zig));
//! [docs/engine/script-vm.md](../../../docs/engine/script-vm.md#events) describes them.
//!
//! **Unknown:** the source file. The matcher lies with the interpreter, past `mission.cpp`'s code,
//! and `condition_raise` and the handlers with the mission's binding, past `loadout.cpp`'s.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.vm);

const dte = @import("../../formats/dte.zig");
const math = @import("../surrender/math.zig");
const vm = @import("../vm.zig");
const gameobj = @import("../game/gameobj.zig");
const Kinds = @import("../game/executor/commands.zig").Kinds;

const conditions = vm.conditions;
const Machine = vm.Machine;
const Call = vm.machine.Call;

/// An event as it is raised on an object.
pub const Event = struct {
    condition: dte.Condition,
    /// The component of the ship the event concerns, by its index among the components of the
    /// ship's live object, or `dte.Trigger.whole_object` for the ship itself. An event on a flight
    /// group or a squad concerns the group itself.
    qualifier: u8 = dte.Trigger.whole_object,
    /// Its values, in the order the condition lists them: a ship, a flight group or a squad by
    /// where its record lies in the mission image (`Machine.recordPlace`), 0 for none, and a
    /// number as it is. ShotAt's handlers put a group's damage values in place of the ship's.
    values: []u32 = &.{},
};

/// The object ID that names no object, on which no event is raised.
pub const no_object: u16 = 0xFFFF;

/// `trigger_raise_event` (`0x0045CE70`): raises `event` on the object `object` (`match`), unless
/// it names none. Then the handlers' verdict lets every trigger answer again.
pub fn raise(machine: *Machine, object: u16, event: Event) void {
    if (object != no_object) match(machine, object, event);
    machine.verdict = true;
}

/// `trigger_match` (`0x0045CEA0`): each trigger in the object's slice of the trigger list that
/// answers `event` (`answers`) gives the event's values to the first free thread's locals. Where
/// its operands then pass (`passes`), the trigger starts that thread on its block, at once or for
/// the scheduler as the trigger says, unless a thread it started still runs (`threadRunning`), and
/// is disarmed as its repeat mode says (`disarm`), whether or not a thread started. The object
/// first keeps the event where the condition keeps its last one (`keep`).
fn match(machine: *Machine, object: u16, event: Event) void {
    keep(machine, object, event);
    const script = machine.mission.file.entry(.script);
    const slice = triggersOf(machine, object);
    for (slice.triggers, slice.first..) |*trigger, index| {
        if (!answers(machine.verdict, trigger.*, event)) continue;
        const thread = machine.allocThread();
        if (thread) |free| giveLocals(machine, free, event);
        if (!passes(machine, trigger.*, event)) continue;
        log.debug("trigger {d} of object {d} fires on {s}", .{ index, object, if (event.condition.descriptor()) |known| known.name else "?" });
        if (!threadRunning(machine, @intCast(index))) if (trigger.block()) |block| {
            // A thread keeps its trigger's index in a byte (`vm.Thread.trigger`).
            _ = machine.startThread(@intCast(script.offset + block), thread, trigger.deferred != 0, null, @truncate(index));
        };
        disarm(trigger);
    }
}

/// `0x0045B4E0`: whether `event` on the object `object` would fire any of the object's triggers,
/// as the matcher finds them, whatever their threads; the queue asks it before it takes an event
/// (`game.mission.events`). Like the matcher, it has the object keep the event first, and gives the
/// event's values to the first free thread for each trigger that answers. **Unverified:** it lies
/// past `mission.cpp`'s known code, before the queue's routines.
pub fn wouldFire(machine: *Machine, object: u16, event: Event) bool {
    keep(machine, object, event);
    const slice = triggersOf(machine, object);
    for (slice.triggers) |trigger| {
        if (!answers(machine.verdict, trigger, event)) continue;
        if (machine.allocThread()) |free| giveLocals(machine, free, event);
        if (passes(machine, trigger, event)) return true;
    }
    return false;
}

/// The triggers of an object's slice of the trigger list, and where the slice starts in it.
const Slice = struct {
    triggers: []align(1) dte.Trigger,
    first: usize,

    const empty: Slice = .{ .triggers = &.{}, .first = 0 };
};

/// The slice of the trigger list that the object `object` holds (`MissionObject.first`, `count`).
///
/// **Fix:** the game reads an object past the object table, and a slice past the trigger list,
/// from past them; OpenReliant takes what lies within.
fn triggersOf(machine: *Machine, object: u16) Slice {
    const file = machine.mission.file;
    const objects = file.objects() catch return .empty;
    if (object >= objects.len) return .empty;
    // The image is the mission's own, and writable, as `bind.Mission` holds it.
    const all: []align(1) dte.Trigger = @constCast(file.triggers() catch return .empty);
    const first = @min(objects[object].first, all.len);
    const end = @min(first + objects[object].count, all.len);
    return .{ .triggers = all[first..end], .first = first };
}

/// Whether the object `object` holds any triggers, which an event on a group is raised for only
/// where it does.
pub fn holdsTriggers(machine: *Machine, object: u16) bool {
    const objects = machine.mission.file.objects() catch return false;
    return object < objects.len and objects[object].count != 0;
}

/// Whether `trigger` answers `event`: armed, of the event's condition and qualifier, with a block
/// to run, and, where the handlers have vetoed the event (`verdict` false), of the repeat mode the
/// condition exempts from a veto.
fn answers(verdict: bool, trigger: dte.Trigger, event: Event) bool {
    if (trigger.armed == 0 or trigger.condition != event.condition or trigger.qualifier != event.qualifier) return false;
    if (!verdict and @intFromEnum(trigger.repeat) != exempt(event.condition)) return false;
    return trigger.link != dte.Part.no_block;
}

/// The repeat mode, as its byte, that the condition exempts from a veto
/// (`ConditionDescriptor.veto_exempt`): `0xFF` for none, which a trigger's byte may yet hold.
fn exempt(condition: dte.Condition) u8 {
    const descriptor = condition.descriptor() orelse return none_exempt;
    const mode = descriptor.veto_exempt orelse return none_exempt;
    return @intFromEnum(mode);
}

const none_exempt: u8 = 0xFF;

/// Whether `trigger`'s operands pass `event`'s values: each operand the trigger sets, for a value
/// the condition marks as checked (`checkOperand`).
fn passes(machine: *Machine, trigger: dte.Trigger, event: Event) bool {
    const descriptor = event.condition.descriptor() orelse return true;
    const count = @min(event.values.len, trigger.operands.len, descriptor.values.len);
    for (event.values[0..count], trigger.operands[0..count], descriptor.values[0..count]) |value, operand, described| {
        if (@as(u16, @truncate(operand)) == dte.Reference.unset or !described.checked) continue;
        if (!checkOperand(machine, described.kinds, operand, value, trigger.condition)) return false;
    }
    return true;
}

/// `trigger_check_operand` (`0x0045D810`): whether a trigger's `operand`, for a value of `kinds`,
/// passes the event's `value`, as the operand reads (`trigger_operand_value`, `0x004530A0`). An
/// operand for any ship passes the players' ships (`dte.Reference.any_ship`); a number of the
/// proximity conditions is the most the value may be; and anything else is the value itself, a
/// reference being where its record lies.
///
/// **Fix:** an operand that names no ship, flight group or squad, which the game stops for ("NULL
/// entity referenced in script"), passes nothing.
fn checkOperand(machine: *Machine, kinds: Kinds, operand: u32, value: u32, condition: dte.Condition) bool {
    return switch (dte.Operand.read(operand, kinds)) {
        .unset => true,
        .number => |number| switch (condition) {
            .proximity_close, .proximity_general => value <= number,
            else => value == number,
        },
        .any_ship => playersShip(machine, value),
        .reference => |reference| value == machine.recordPlace(switch (reference.tag) {
            .ship => .ships,
            .flight_group => .flight_groups,
            .squad => .squads,
            _ => unreachable,
        }, reference.index),
        .other => |raw| other: {
            if (!machine.named_nothing) log.warn("a trigger's operand names no ship, flight group or squad: 0x{X:0>8}", .{raw});
            machine.named_nothing = true;
            break :other false;
        },
    };
}

/// Whether `value` is where the record of one of the players' ships lies: the ships of the first
/// slots, one in a game of one.
fn playersShip(machine: *const Machine, value: u32) bool {
    const players: u32 = if (machine.game) |game| game.world.objects.players else 1;
    const first = machine.recordPlace(.ships, 0);
    return value >= first and value < machine.recordPlace(.ships, players);
}

/// `trigger_thread_running` (`0x0045D0D0`): whether a thread that trigger `index` started still
/// runs. Each such thread that waits for its trigger (`InterruptTriggerCode`) runs on again.
fn threadRunning(machine: *Machine, index: u16) bool {
    var running = false;
    var left = machine.thread_count;
    for (&machine.threads) |*thread| {
        if (left == 0) break;
        if (thread.ip == null) continue;
        left -= 1;
        if (thread.record.trigger != index) continue;
        thread.record.interrupted = false;
        running = true;
    }
    return running;
}

/// A trigger that has fired: `once` is disarmed, and `counted` once it has used up its count;
/// `always`, or a mode the game has no name for, stays armed.
fn disarm(trigger: *align(1) dte.Trigger) void {
    switch (trigger.repeat) {
        .once => trigger.armed = 0,
        .counted => {
            if (trigger.repeat_counter != 0) trigger.repeat_counter -= 1;
            if (trigger.repeat_counter == 0) trigger.armed = 0;
        },
        else => {},
    }
}

/// `cmd_SetTriggerState` (`0x0045D300`, command `0x0F`): arms, or disarms, each trigger of the
/// condition the second argument names in the slice of the object the first names, where it
/// watches a component `push_component` named for the command, or the object itself
/// (`Machine.tagged`); arming it gives it its count again (`setArmed`). Its proximity watches
/// follow it (`mission.events.Events.arm`).
pub fn setTriggerState(call: Call) u32 {
    setState(call, null);
    return 1;
}

/// `cmd_SetAnyTriggerState` (`0x0045D3A0`, command `0x4F`): the same for the one trigger of that
/// condition the fourth argument numbers among the slice's, counting from 0, where it watches a
/// component named or the object itself, its count left as it stands.
pub fn setAnyTriggerState(call: Call) u32 {
    setState(call, call.args[3]);
    return 1;
}

fn setState(call: Call, number: ?u32) void {
    const machine = call.machine;
    const object = machine.objectId(call.args[0]) orelse return;
    const condition: u8 = @truncate(call.args[1]);
    const armed: u8 = @truncate(call.args[2]);
    const slice = triggersOf(machine, object);
    var counted: u8 = 0;
    for (slice.triggers, slice.first..) |*trigger, index| {
        if (@intFromEnum(trigger.condition) != condition) continue;
        defer counted +%= 1;
        if (!machine.tagged(trigger.qualifier)) continue;
        if (number) |wanted| {
            if (wanted != counted) continue;
            trigger.armed = armed;
        } else {
            setArmed(trigger, armed);
        }
        if (machine.game) |game| if (game.world.events) |events| events.arm(@intCast(index), armed != 0);
    }
}

/// `trigger_set_armed` (`0x0045D390`): `trigger` is armed or disarmed as `armed` says; armed, it
/// has its count again (`dte.Trigger.repeat_count`).
fn setArmed(trigger: *align(1) dte.Trigger, armed: u8) void {
    trigger.armed = armed;
    if (armed != 0) trigger.repeat_counter = trigger.repeat_count;
}

/// The locals of thread `thread` take `event`'s values, as far as they go.
fn giveLocals(machine: *Machine, thread: u8, event: Event) void {
    const locals = &machine.threads[thread].record.locals;
    const count = @min(event.values.len, locals.len);
    @memcpy(locals[0..count], event.values[0..count]);
}

/// Where the condition keeps each object's last event (`ConditionDescriptor.slot`), the object
/// `object` keeps `event`'s values, which `push_event_value` reads.
fn keep(machine: *Machine, object: u16, event: Event) void {
    const descriptor = event.condition.descriptor() orelse return;
    const slot = descriptor.slot orelse return;
    if (object >= machine.event_values.len) return;
    const kept: *[@sizeOf(vm.ObjectEvents) / @sizeOf(u32)]u32 = @ptrCast(&machine.event_values[object]);
    const from = @as(usize, slot) * kept_values;
    if (from >= kept.len) return;
    const count = @min(event.values.len, kept_values);
    @memcpy(kept[from..][0..count], event.values[0..count]);
}

/// The values each kept event has room for (`vm.ObjectEvents`).
const kept_values = 5;

/// `condition_raise` (`0x00453210`): `event`, raised on the mission's ship `ship`, goes on to the
/// ship's flight group, and then to each squad that holds the ship (`Machine.inSquad`, as the
/// component the event concerns), each where its slice holds triggers. For each group the
/// condition's handlers first count its members (`Tally`), and their verdict decides which of the
/// group's triggers answer (`Machine.verdict`).
pub fn raiseOnGroups(machine: *Machine, ship: u16, event: Event) void {
    const file = machine.mission.file;
    const ships = file.ships() catch return;
    if (ship >= ships.len) return;
    const on_group: Event = .{ .condition = event.condition, .values = event.values };
    const handlers = Handlers.of(event.condition);
    if (ships[ship].flightGroup()) |index| flight_group: {
        const groups = file.flightGroups() catch break :flight_group;
        if (index >= groups.len) break :flight_group;
        const group = groups[index];
        if (!holdsTriggers(machine, group.object_id)) break :flight_group;
        var tally: Tally = .{ .handlers = handlers };
        for (machine.mission.groupShips(group)) |member| tally.add(machine, member, dte.Trigger.whole_object);
        tally.count +%= group.ship_count;
        machine.verdict = tally.verdict(event.values);
        raise(machine, group.object_id, on_group);
    }
    const squads = file.squads() catch return;
    const place = machine.recordPlace(.ships, ship);
    for (squads, 0..) |squad, index| {
        if (!holdsTriggers(machine, squad.object_id)) continue;
        const holds = machine.inSquad(machine.recordPlace(.squads, index), place, event.qualifier, 0) catch false;
        if (!holds) continue;
        var tally: Tally = .{ .handlers = handlers };
        if (handlers != null) tally.addSquad(machine, @intCast(index), 0);
        machine.verdict = tally.verdict(event.values);
        raise(machine, squad.object_id, on_group);
    }
}

/// What a condition's handlers do with its events on a flight group or a squad
/// (`ConditionDescriptor.begin`, `add_member`, `verdict`), by the routines the catalogue names.
const Handlers = enum {
    /// ShotAt's: the group's event carries its members' average damage values (`damageValue`) in
    /// place of the ship's, and goes ahead.
    average_damage,
    /// Destroyed's: the group's event goes ahead only once every member, or the component a squad
    /// names of it, is destroyed.
    all_destroyed,
    /// Cloaked's and Decloaked's: Destroyed's first and last, with a routine for each member that
    /// does nothing (`cloak_group_add`), so every event goes ahead.
    pass,

    const average_damage_routines: conditions.Handlers = .{ .begin = 0x00452BB0, .add_member = 0x00452BD0, .verdict = 0x00452C00 };
    const all_destroyed_routines: conditions.Handlers = .{ .begin = 0x00452C40, .add_member = 0x00452C50, .verdict = 0x00452CA0 };
    const pass_routines: conditions.Handlers = .{ .begin = 0x00452C40, .add_member = 0x0045D800, .verdict = 0x00452CA0 };

    /// The condition's handlers, where it has any.
    fn of(condition: dte.Condition) ?Handlers {
        const descriptor = condition.descriptor() orelse return null;
        return known(descriptor.handlers orelse return null);
    }

    fn known(routines: conditions.Handlers) ?Handlers {
        if (std.meta.eql(routines, average_damage_routines)) return .average_damage;
        if (std.meta.eql(routines, all_destroyed_routines)) return .all_destroyed;
        if (std.meta.eql(routines, pass_routines)) return .pass;
        return null;
    }

    comptime {
        for (conditions.table) |condition| {
            if (condition.handlers) |routines| assert(known(routines) != null);
        }
    }
};

/// What a group's members come to as its condition's handlers count them.
const Tally = struct {
    handlers: ?Handlers,
    /// The members counted, which ShotAt's averages over.
    count: u16 = 0,
    /// ShotAt's total of the members' damage values, which the game keeps twice, once for each of
    /// the event's damage values (`0x005294E6`, `0x0052950A`).
    damage: u16 = 0,
    /// Destroyed's (`0x00525F7C`): whether every member counted so far is destroyed.
    all_destroyed: bool = true,

    /// The member ship `ship`, whole or as its component `component` (`add_member`: ShotAt's
    /// `0x00452BD0`, Destroyed's `0x00452C50`). A component is destroyed once the ship's record has
    /// its bit clear (`dte.Ship.intact_components`).
    fn add(tally: *Tally, machine: *Machine, ship: u16, component: u8) void {
        const handlers = tally.handlers orelse return;
        switch (handlers) {
            .average_damage => {
                const game = machine.game orelse return;
                tally.damage +%= damageValue(game.world, ship, component);
            },
            .all_destroyed => {
                if (!tally.all_destroyed) return;
                const ships = machine.mission.file.ships() catch return;
                if (ship >= ships.len) return;
                const record = ships[ship];
                tally.all_destroyed = if (component == dte.Trigger.whole_object)
                    record.flags.destroyed
                else
                    record.intact_components & (@as(u32, 1) << @truncate(component)) == 0;
            },
            .pass => {},
        }
    }

    /// `0x004533D0`: the members of squad `squad`, from its first until a record of another
    /// squad: a ship as the component its membership names, each ship of a flight group whole, and
    /// a squad's own members in turn, `depth` squads down.
    ///
    /// **Fix:** the game stops with a fatal error at a member of a kind it has no name for
    /// ("unknown ai group member"), walks a member no record stands for from its address, and a
    /// squad that holds itself round for ever; OpenReliant passes over the first two, and stops
    /// once it has gone down more squads than the mission has.
    fn addSquad(tally: *Tally, machine: *Machine, squad: u16, depth: usize) void {
        const file = machine.mission.file;
        const squads = file.squads() catch return;
        if (squad >= squads.len or depth > squads.len) return;
        const members = file.records(dte.SquadMember, .squad_members) catch return;
        const objects = file.objects() catch return;
        const groups = file.flightGroups() catch return;
        for (members[@min(squads[squad].first_member, members.len)..]) |member| {
            if (member.squad != squad) return;
            if (member.object_id >= objects.len) continue;
            const record = machine.mission.records[member.object_id] orelse continue;
            switch (objects[member.object_id].kind) {
                .ship => switch (record) {
                    .ship => |ship| {
                        tally.add(machine, ship, member.component);
                        tally.count +%= 1;
                    },
                    else => {},
                },
                .flight_group => switch (record) {
                    .flight_group => |at| if (at < groups.len) {
                        for (machine.mission.groupShips(groups[at])) |ship| tally.add(machine, ship, dte.Trigger.whole_object);
                        tally.count +%= groups[at].ship_count;
                    },
                    else => {},
                },
                .squad => switch (record) {
                    .squad => |at| tally.addSquad(machine, at, depth + 1),
                    else => {},
                },
                _ => {},
            }
        }
    }

    /// The handlers' verdict on the group's event (`verdict`: ShotAt's `0x00452C00`, Destroyed's
    /// `0x00452CA0`), which ShotAt's gives the members' average damage value for both of the
    /// event's damage values first; true for a condition without handlers.
    fn verdict(tally: Tally, values: []u32) bool {
        const handlers = tally.handlers orelse return true;
        return switch (handlers) {
            .average_damage => {
                // The game divides by the count, which never comes to zero: the ship the event
                // is on is among the members.
                if (tally.count == 0) return true;
                const average = tally.damage / tally.count;
                for ([_]usize{ shield_damage, hull_damage }) |value| {
                    if (value < values.len) values[value] = average;
                }
                return true;
            },
            .all_destroyed, .pass => tally.all_destroyed,
        };
    }
};

/// ShotAt's damage values, among its event's values.
const shield_damage = 1;
const hull_damage = 2;

/// `ship_damage_value` (`0x00452CB0`): how much of its armour the mission's ship `ship` has lost,
/// in whole hundredths, a hundred once any of it has run out. The ship's own is its weakest
/// quadrant's against the full armour of its type (`create.ShipCombat.fullArmor`); its component
/// `component`'s is the component's against what it starts with, and a hundred for a component the
/// ship lists no more.
pub fn damageValue(world: gameobj.World, ship: u16, component: u8) u16 {
    const all = world.objects;
    if (ship >= all.slots.len) return 0;
    const slot = &all.slots[ship];
    const left: f32, const full: f32 = if (component == dte.Trigger.whole_object)
        .{ slot.object.armor.weakest(), if (slot.combat) |combat| combat.fullArmor() else 0 }
    else if (slot.component(component)) |part|
        .{ part.armor, @floatFromInt(part.component_armor) }
    else
        .{ 0, all_lost };
    if (left < 0) return all_lost;
    return @truncate(@as(u32, @bitCast(math.ftol((full - left) / full * all_lost))));
}

/// The damage value of a ship or a component with no armour left (`0x004DC440`).
const all_lost = 100;

const machine_testing = vm.machine.testing;

/// Fixtures for the tests of the triggers, and of what posts the events.
pub const testing = struct {
    /// A trigger, armed as the script's start arms it, watching its object itself, with no operand
    /// set, whose block is part `part` of `parts`.
    pub fn trigger(parts: []const machine_testing.Part, part: usize, condition: dte.Condition, repeat: dte.Trigger.Repeat) dte.Trigger {
        var made = std.mem.zeroes(dte.Trigger);
        made.condition = condition;
        made.repeat = repeat;
        made.link = machine_testing.Fixture.link(parts, part);
        made.qualifier = dte.Trigger.whole_object;
        made.operands = @splat(0xFFFF_FFFF);
        return made;
    }

    /// An entry of the object table holding `count` triggers from `first`.
    pub fn object(kind: dte.Object.Kind, first: u16, count: u8) dte.Object {
        return .{ .kind = kind, .count = count, .first = first, ._unknown_04 = 0 };
    }

    /// A block that adds one to global `global`, which the caller frees.
    pub fn counting(gpa: std.mem.Allocator, global: u8) ![]u8 {
        var routine: machine_testing.Routine = .init(gpa);
        defer routine.deinit();
        try routine.op(.select_global, &.{global});
        try routine.op(.push_byte, &.{1});
        try routine.op(.add_assign, &.{});
        try routine.op(.push_byte, &.{1});
        try routine.op(.@"return", &.{});
        return routine.finish();
    }
};

test "an event fires the triggers that answer it, as their repeat modes allow" {
    const gpa = std.testing.allocator;
    // The block stores its first local, the event's first value, in global 0, and counts in
    // global 1.
    var routine: machine_testing.Routine = .init(gpa);
    defer routine.deinit();
    try routine.op(.select_global, &.{0});
    try routine.op(.push_local, &.{0});
    try routine.op(.assign, &.{});
    try routine.op(.select_global, &.{1});
    try routine.op(.push_byte, &.{1});
    try routine.op(.add_assign, &.{});
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const stores = try routine.finish();
    defer gpa.free(stores);
    const again = try testing.counting(gpa, 2);
    defer gpa.free(again);
    const parts = [_]machine_testing.Part{ .{ .code = stores }, .{ .code = again } };

    var once = testing.trigger(&parts, 0, .launched, .once);
    once.operands[0] = 1; // Ship 1.
    var counted = testing.trigger(&parts, 1, .launched, .counted);
    counted.repeat_counter = 2;
    const ships: [2]dte.Ship = .{ std.mem.zeroInit(dte.Ship, .{ .object_id = 0, .flight_group = dte.Ship.no_flight_group }), std.mem.zeroInit(dte.Ship, .{ .object_id = 1, .flight_group = dte.Ship.no_flight_group }) };
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{
        .globals = &.{ 0, 0, 0 },
        .ships = &ships,
        .objects = &.{ testing.object(.ship, 0, 2), testing.object(.ship, 2, 0) },
        .triggers = &.{ once, counted },
    });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();

    // Ship 0 launched: the counted trigger answers, the other's operand wants ship 1.
    var zero = [_]u32{machine.recordPlace(.ships, 0)};
    raise(machine, 0, .{ .condition = .launched, .values = &zero });
    try std.testing.expectEqual(0, fixture.global(1));
    try std.testing.expectEqual(1, fixture.global(2));
    // Ship 1: both fire, the first with the ship in its local.
    var one = [_]u32{machine.recordPlace(.ships, 1)};
    try std.testing.expect(wouldFire(machine, 0, .{ .condition = .launched, .values = &one }));
    raise(machine, 0, .{ .condition = .launched, .values = &one });
    try std.testing.expectEqual(one[0], fixture.global(0));
    try std.testing.expectEqual(1, fixture.global(1));
    try std.testing.expectEqual(2, fixture.global(2));
    // Both are spent: the one fired once, the other twice.
    try std.testing.expect(!wouldFire(machine, 0, .{ .condition = .launched, .values = &one }));
    raise(machine, 0, .{ .condition = .launched, .values = &one });
    try std.testing.expectEqual(1, fixture.global(1));
    try std.testing.expectEqual(2, fixture.global(2));
    // Another condition, or a component, answers nothing.
    try std.testing.expect(!wouldFire(machine, 0, .{ .condition = .destroyed, .values = &one }));
}

test "a trigger whose thread still runs lets it go on instead" {
    const gpa = std.testing.allocator;
    // The block counts, waits for its trigger to fire again, and counts again.
    var routine: machine_testing.Routine = .init(gpa);
    defer routine.deinit();
    for (0..2) |_| {
        try routine.op(.select_global, &.{0});
        try routine.op(.push_byte, &.{1});
        try routine.op(.add_assign, &.{});
        try routine.command("InterruptTriggerCode");
    }
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);
    const parts = [_]machine_testing.Part{.{ .code = code }};
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{
        .globals = &.{0},
        .ships = &.{std.mem.zeroInit(dte.Ship, .{ .flight_group = dte.Ship.no_flight_group })},
        .objects = &.{testing.object(.ship, 0, 1)},
        .triggers = &.{testing.trigger(&parts, 0, .player_ready_to_jump, .always)},
    });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();

    raise(machine, 0, .{ .condition = .player_ready_to_jump });
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expectEqual(1, machine.thread_count);
    // Held, the thread waits; the trigger firing again lets it go on, starting no other.
    machine.runThreads();
    try std.testing.expectEqual(1, fixture.global(0));
    raise(machine, 0, .{ .condition = .player_ready_to_jump });
    try std.testing.expectEqual(1, machine.thread_count);
    machine.runThreads();
    try std.testing.expectEqual(2, fixture.global(0));
}

test "a group's Destroyed goes ahead once every member is destroyed" {
    const gpa = std.testing.allocator;
    const always = try testing.counting(gpa, 0);
    defer gpa.free(always);
    const once = try testing.counting(gpa, 1);
    defer gpa.free(once);
    const in_squad = try testing.counting(gpa, 2);
    defer gpa.free(in_squad);
    const parts = [_]machine_testing.Part{ .{ .code = always }, .{ .code = once }, .{ .code = in_squad } };

    // Ships 0 and 1 make flight group 0, which squad 0 holds as its only member.
    var ships: [2]dte.Ship = .{ std.mem.zeroInit(dte.Ship, .{ .object_id = 0 }), std.mem.zeroInit(dte.Ship, .{ .object_id = 1 }) };
    var group = std.mem.zeroes(dte.FlightGroup);
    group.object_id = 2;
    var squad = std.mem.zeroes(dte.Squad);
    squad.object_id = 3;
    const member: dte.SquadMember = .{ .object_id = 2, ._unknown_02 = 0, .squad = 0, ._unknown_06 = 0, .component = dte.Trigger.whole_object, ._unknown_09 = @splat(0) };
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{
        .globals = &.{ 0, 0, 0 },
        .ships = &ships,
        .flight_groups = &.{group},
        .squads = &.{squad},
        .squad_members = &.{member},
        .objects = &.{ testing.object(.ship, 0, 0), testing.object(.ship, 0, 0), testing.object(.flight_group, 0, 2), testing.object(.squad, 2, 1) },
        .triggers = &.{
            testing.trigger(&parts, 0, .destroyed, .always),
            testing.trigger(&parts, 1, .destroyed, .once),
            testing.trigger(&parts, 2, .destroyed, .once),
        },
    });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();
    const records = try fixture.mission.ships();

    // One of two gone: only the group's trigger of the mode the veto spares answers.
    records[0].flags.destroyed = true;
    var values = [_]u32{ 0, machine.recordPlace(.ships, 0) };
    raiseOnGroups(machine, 0, .{ .condition = .destroyed, .values = &values });
    try std.testing.expectEqual([3]u32{ 1, 0, 0 }, [3]u32{ fixture.global(0), fixture.global(1), fixture.global(2) });
    try std.testing.expect(machine.verdict);
    // Both gone: the group's and the squad's go ahead.
    records[1].flags.destroyed = true;
    values[1] = machine.recordPlace(.ships, 1);
    raiseOnGroups(machine, 1, .{ .condition = .destroyed, .values = &values });
    try std.testing.expectEqual([3]u32{ 2, 1, 1 }, [3]u32{ fixture.global(0), fixture.global(1), fixture.global(2) });
}

test "an operand for any ship passes the players' ships alone" {
    const gpa = std.testing.allocator;
    const code = try testing.counting(gpa, 0);
    defer gpa.free(code);
    const parts = [_]machine_testing.Part{.{ .code = code }};
    var trigger = testing.trigger(&parts, 0, .proximity_general, .always);
    trigger.operands[0] = 0xFF00_0000 | @as(u32, dte.Reference.any_ship);
    // The distance is not checked, however far the event's.
    trigger.operands[1] = 1;
    const ships: [2]dte.Ship = @splat(std.mem.zeroInit(dte.Ship, .{ .flight_group = dte.Ship.no_flight_group }));
    var fixture: machine_testing.Fixture = undefined;
    try fixture.init(gpa, &parts, .{ .globals = &.{0}, .ships = &ships, .objects = &.{testing.object(.ship, 0, 1)}, .triggers = &.{trigger} });
    defer fixture.deinit();
    const machine = &fixture.machine;
    try machine.start();

    var other = [_]u32{ machine.recordPlace(.ships, 1), 30 };
    raise(machine, 0, .{ .condition = .proximity_general, .values = &other });
    try std.testing.expectEqual(0, fixture.global(0));
    var player = [_]u32{ machine.recordPlace(.ships, 0), 30 };
    raise(machine, 0, .{ .condition = .proximity_general, .values = &player });
    try std.testing.expectEqual(1, fixture.global(0));
}

test "ShotAt's handlers average the members' damage values" {
    var values = [_]u32{ 0, 90, 90, 0, 0xFFFF_FFFF };
    const tally: Tally = .{ .handlers = .average_damage, .count = 3, .damage = 100 };
    try std.testing.expect(tally.verdict(&values));
    try std.testing.expectEqualSlices(u32, &.{ 0, 33, 33, 0, 0xFFFF_FFFF }, &values);
    // Destroyed's vetoes while a member stands; the cloak's never do.
    try std.testing.expect(!(Tally{ .handlers = .all_destroyed, .all_destroyed = false }).verdict(&values));
    try std.testing.expect((Tally{ .handlers = .pass }).verdict(&values));
    try std.testing.expectEqual(.average_damage, Handlers.of(.shot_at).?);
    try std.testing.expectEqual(.pass, Handlers.of(.decloaked).?);
    try std.testing.expectEqual(null, Handlers.of(.launched));
}

test damageValue {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ship = try mission.add(.predator, @splat(0));
    const slot = mission.slot(ship);
    const full = slot.combat.?.fullArmor();
    // Untouched, a ship has lost nothing; its weakest quadrant at a quarter off, 25.
    slot.object.armor = .all(full);
    try std.testing.expectEqual(0, damageValue(mission.world(), ship, dte.Trigger.whole_object));
    slot.object.armor.aft = full * 0.75;
    try std.testing.expectEqual(25, damageValue(mission.world(), ship, dte.Trigger.whole_object));
    // Any quadrant run out, 100; a component it lists no more, 100.
    slot.object.armor.left = -1;
    try std.testing.expectEqual(100, damageValue(mission.world(), ship, dte.Trigger.whole_object));
    try std.testing.expectEqual(100, damageValue(mission.world(), ship, 3));
}
