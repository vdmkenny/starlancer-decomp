//! `C:\lancer\game\Executor.cpp`: the mission script's commands.
//! [`executor/commands.zig`](executor/commands.zig) transcribes the command catalogue.
//! **Unverified:** the catalogue lies in the data before this file's path, and some commands lie
//! outside this file's code.

const std = @import("std");
const log = std.log.scoped(.mission);

const dte = @import("../../formats/dte.zig");
const engine = @import("../../engine.zig");
const Code = engine.Code;
const vm = @import("../vm.zig");
const input = @import("../input.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const camera = @import("camera.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const hud = @import("hud.zig");
const launch = @import("launch.zig");
const mission = @import("mission.zig");
const objects = @import("objects.zig");
const pilots = @import("pilots.zig");
const Order = @import("ai/orders.zig").Order;

pub const commands = @import("executor/commands.zig");
pub const curves = @import("executor/curves.zig");
pub const director = @import("executor/director.zig");

const Call = vm.machine.Call;

/// The catalogue's number of the command `name`: the operand of `command` that runs it.
pub fn commandIndex(comptime name: []const u8) u8 {
    return comptime for (commands.table, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) break index;
    } else @compileError("the Executor has no command " ++ name);
}

/// The implementation of command `number`, or null for one not ported yet
/// ([#36](https://github.com/vdmkenny/openreliant/issues/36),
/// [#281](https://github.com/vdmkenny/openreliant/issues/281)).
pub fn implementation(number: u8) ?vm.Implementation {
    return if (number < implementations.len) implementations[number] else null;
}

const implementations = table: {
    @setEvalBranchQuota(10_000);
    var table: [commands.table.len]?vm.Implementation = @splat(null);
    for ([_]struct { []const u8, vm.Implementation }{
        .{ "CreateTimer", vm.Machine.createTimer },
        .{ "DestroyTimer", vm.Machine.destroyTimer },
        .{ "CreateFlightGroup", createFlightGroup },
        .{ "Wait", vm.Machine.wait },
        .{ "SetAI", setAI },
        .{ "InterruptTriggerCode", vm.Machine.interruptTriggerCode },
        .{ "Fly", fly },
        .{ "SetRescueProbabilities", setRescueProbabilities },
        .{ "KillAllScriptExecutionExecptMe", vm.Machine.killAllScriptExecutionExceptMe },
        .{ "WaitForMovie", waitForMovie },
        .{ "SetupLaunch", setupLaunch },
        .{ "StartLaunch", startLaunch },
        .{ "SetInvulnerability", setInvulnerability },
        .{ "PlayMusic", playMusic },
        .{ "DisableTaunts", disableTaunts },
        .{ "DisableGenericComms", disableGenericComms },
        .{ "UpdateEnvironmentFXState", updateEnvironmentFXState },
        .{ "WaitForJumpOrLaunch", waitForJumpOrLaunch },
        .{ "SetEnvironmentFXNebula", setEnvironmentFXNebula },
        .{ "OpenInstrument", openInstrument },
        .{ "CloseInstrument", closeInstrument },
        .{ "SetObjective", setObjective },
        .{ "SetShipAvoidance", setShipAvoidance },
        .{ "MultiplayerScriptSync", multiplayerScriptSync },
        .{ "SetTriggerState", vm.triggers.setTriggerState },
        .{ "SetAnyTriggerState", vm.triggers.setAnyTriggerState },
        .{ "WhenPlayerLastJumped", whenPlayerLastJumped },
        .{ "DestroyFlightGroup", destroyFlightGroup },
        .{ "ClearAI", clearAI },
        .{ "StartShipAnimation", startShipAnimation },
        .{ "StartShipAnimationReverse", startShipAnimationReverse },
        .{ "DisableObject", disableObject },
        .{ "SetPlayerTarget", setPlayerTarget },
        .{ "SetTargetable", setTargetable },
        .{ "SetActionCentre", setActionCentre },
        .{ "DisableGuns", disableGuns },
        .{ "SetEscortPoint", setEscortPoint },
        .{ "SetPrimaryTarget", setPrimaryTarget },
        .{ "SnapToPoint", snapToPoint },
        .{ "IsShipThisPlayer", isShipThisPlayer },
        .{ "SetFlybackMarker", setFlybackMarker },
        .{ "ResetFlybackMarker", resetFlybackMarker },
        .{ "MatchSpeed", matchSpeed },
        .{ "StartDirectorCam", startDirectorCam },
        .{ "StackDirectorCam", stackDirectorCam },
        .{ "StopDirectorCam", stopDirectorCam },
        .{ "WaitForDirectorCam", waitForDirectorCam },
    }) |pair| table[commandIndex(pair[0])] = pair[1];
    break :table table;
};

/// `cmd_CreateFlightGroup` (`0x00457C40`, command `0x03`): creates each ship of the flight group
/// its argument names, in the mission's order (`createShip`), then lists the flight groups in
/// their wings (`mission.buildWings`).
///
/// **Fix:** the game stops with a fatal error where the argument names no flight group; OpenReliant
/// creates nothing.
fn createFlightGroup(call: Call) u32 {
    const machine = call.machine;
    const game = machine.game orelse return 1;
    const group = machine.flightGroupIndex(call.args[0]) orelse return 1;
    const groups = machine.mission.flightGroups() catch return 1;
    if (group >= groups.len) return 1;
    for (machine.mission.groupShips(groups[group])) |ship| createShip(game, machine.mission, ship);
    mission.buildWings(game.world.objects, machine.mission);
    return 1;
}

/// The kinds of a mission's ship records that are nav points and markers, which
/// `mission_ship_create` makes a `gameobj.Type.marker` of.
fn isMarker(kind: u16) bool {
    return switch (kind) {
        nav_point_kind, dte.Ship.waypoint_kind, dte.Ship.curve_point_kind, dte.Ship.point_kind => true,
        else => false,
    };
}

/// The kind of a mission's nav points.
const nav_point_kind = 999;

/// `mission_ship_create` (`0x00457CD0`): creates the object of mission ship `index` in the slot of
/// its index, as its record has it.
///
/// A nav point or a marker is a `gameobj.Type.marker` at its place, turned by its record
/// (`mission.recordOrientation`).
///
/// Any other ship is an object of its kind (`shipType`), fitted by its loadout tier, at its place.
/// It gets its first order: Player Control for the player's ship, whose view the camera takes (view
/// 0), Multiplayer Control for another player's, and Do Nothing for the rest. It is turned by its
/// record. A ship that launches gets a Launch order through the gate it names of the first of the
/// mission's ships of the kind it launches from, which starts at once (`aigeneric.objectOrders`),
/// and a ship flown by a pilot of `pilotstats.bin` gets the pilot.
///
/// Not ported: the count of the nav points made (`0x00565698`), which nothing reads, and the lines
/// it logs.
pub fn createShip(game: aigeneric.Context, bound: *const mission.Mission, index: u16) void {
    const all = game.world.objects;
    const spawn = game.world.spawn orelse return;
    const ships = bound.ships() catch return;
    if (index >= ships.len) return;
    const ship = ships[index];
    const turn = mission.recordOrientation(ship);
    if (isMarker(ship.kind)) {
        const made = create.createObject(all, spawn.tables, spawn.types, index, .marker, 0, ship.position, game.world.random) catch |err| {
            log.warn("mission ship {d} is not made: {s}", .{ index, @errorName(err) });
            return;
        };
        objects.setOrientation(&all.slots[made].object, &all.slots[made].drawn, turn);
        return;
    }
    const made = create.createObject(all, spawn.tables, spawn.types, index, shipType(all, bound, ship), ship.tier, ship.position, game.world.random) catch |err| {
        log.warn("mission ship {d} is not made: {s}", .{ index, @errorName(err) });
        return;
    };
    const first: Order = if (made >= all.players) .do_nothing else if (made == all.player) .player_control else .multiplayer_control;
    _ = aigeneric.push(game, made, first, .none) catch |err| log.warn("mission ship {d} takes no order: {s}", .{ index, @errorName(err) });
    if (made == all.player) if (game.world.camera) |view| {
        _ = view.setView(.cockpit, made, false, false, game.clock.viewTime());
    };
    const slot = &all.slots[made];
    objects.setOrientation(&slot.object, &slot.drawn, turn);
    if (ship.launchGate()) |gate| for (ships, 0..) |carrier, from| {
        if (carrier.kind != ship.launch_from) continue;
        _ = aigeneric.pushShip(game, made, .launch, @intCast(from), gate) catch |err| log.warn("mission ship {d} does not launch: {s}", .{ index, @errorName(err) });
        aigeneric.objectOrders(game, made);
        break;
    };
    if (ship.pilotRecord()) |pilot| pilots.setPilot(&slot.object, pilot);
}

/// `mission_script_start`'s making of the ships of `curve` (`0x0045CD71`): the ship it starts at,
/// those its tangents are drawn to, and the ship it ends at, each where its slot holds no object
/// made yet (`createShip`).
///
/// **Fix:** the game takes the object past its array for a curve that names no ship; OpenReliant
/// passes over it.
pub fn createCurveShips(game: aigeneric.Context, bound: *const mission.Mission, curve: dte.Curve) void {
    const all = game.world.objects;
    for ([_]dte.Reference{ curve.start, curve.leaving_handle, curve.arriving_handle, curve.end }) |ship| {
        if (ship.index >= all.slots.len or all.slots[ship.index].object.created) continue;
        createShip(game, bound, ship.index);
    }
}

/// The type `mission_ship_create` asks for a mission ship of: its kind, save that from
/// `create.twins_from_mission` on a ship of the player's wing flies the `t_` twin of its kind, or
/// a Kamov in mission 25's first part.
///
/// **Fix:** from `create.twins_from_mission` on, the game takes a ship of the player's wing whose
/// kind is none of the player's ships for the object in the slot its record's address gives, and
/// reads the wing of a ship in no flight group from past the groups; OpenReliant makes the first of
/// its own kind, and takes the second for a ship of no wing.
fn shipType(all: *const create.Objects, bound: *const mission.Mission, ship: dte.Ship) gameobj.Type {
    const kind: gameobj.Type = @enumFromInt(ship.kind);
    if (all.mission_number < create.twins_from_mission) return kind;
    const groups = bound.flightGroups() catch return kind;
    const group = ship.flightGroup() orelse return kind;
    if (group >= groups.len or groups[group].wing != 0) return kind;
    if (all.mission_number == create.kamov_mission and !all.mission25_second_part) return .kamov;
    return kind.twin() orelse kind;
}

/// `cmd_SetAI` (`0x004581F0`, command `0x0B`): each ship the first argument names takes the order
/// the second gives (`setAIShip`), the orders numbered from 0 as they are given
/// (`aigeneric.startNumbering`).
fn setAI(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    aigeneric.startNumbering(game.world.objects);
    vm.Machine.forEachShip(call, setAIShip);
    aigeneric.stopNumbering(game.world.objects);
    return 1;
}

/// `cmd_SetAI_ship` (`0x00458220`): pushes the order the command's second argument gives on the
/// ship's stack, aimed at what its fourth names: a flight group or a squad by its index, or a ship
/// by its slot and the component `push_component` named for it, or nothing. The third, whether the
/// order starts at once, is not read. Aimed at anything else, it pushes no order.
fn setAIShip(call: Call, ship: u16) void {
    const machine = call.machine;
    const game = machine.game.?;
    const aim = call.args[2];
    const target: aigeneric.Target = if (machine.recordKind(aim)) |kind| switch (kind) {
        .flight_group => .{ .kind = .flight_group, .index = targetIndex(machine.flightGroupIndex(aim)), .component = aigeneric.Target.whole },
        .squad => .{ .kind = .squad, .index = targetIndex(machine.squadIndex(aim)), .component = aigeneric.Target.whole },
        .ship => shipTarget(machine, call.thread, aim),
        _ => return,
    } else shipTarget(machine, call.thread, aim);
    const order: Order = @enumFromInt(@as(i16, @truncate(@as(i32, @bitCast(call.args[0])))));
    _ = aigeneric.push(game, ship, order, target) catch |err| log.warn("mission ship {d} takes no order {d}: {s}", .{ ship, @intFromEnum(order), @errorName(err) });
}

/// A record's index as an order's target takes it, -1 for none.
fn targetIndex(record: ?u16) i16 {
    return if (record) |at| @bitCast(at) else -1;
}

/// The target `SetAI` aims at the ship `aim` names: its slot, and the component `push_component`
/// named for the command's fourth argument, or none where `aim` names no ship.
fn shipTarget(machine: *const vm.Machine, thread: u8, aim: u32) aigeneric.Target {
    const ship = machine.shipIndex(aim) orelse return .none;
    const component: i16 = if (machine.argumentComponent(thread, 3)) |part| part else aigeneric.Target.whole;
    return .{ .kind = .ship, .index = @bitCast(ship), .component = component };
}

/// `cmd_Fly` (`0x00458F50`, command `0x28`): each ship the first argument names flies
/// (`flyShip`).
fn fly(call: Call) u32 {
    vm.Machine.forEachShip(call, flyShip);
    return 1;
}

/// `cmd_Fly_ship` (`0x00458F70`): pushes a Fly order on the ship's stack, aimed at the ship the
/// command's second argument names, or at none, which holds the heading it starts on, at the speed
/// the third gives, or 0 for its full throttle.
fn flyShip(call: Call, ship: u16) void {
    const machine = call.machine;
    const game = machine.game.?;
    const target: aigeneric.Target = if (machine.shipIndex(call.args[0])) |to| .at(to, null) else .none;
    const all = game.world.objects;
    _ = aigeneric.push(game, ship, .fly, target) catch |err| log.warn("mission ship {d} does not fly: {s}", .{ ship, @errorName(err) });
    if (aigeneric.current(all, ship)) |entry| entry.data.fly = @bitCast(call.args[1]);
}

/// `cmd_SetRescueProbabilities` (`0x004598D0`, command `0x44`): the odds of how the player fares
/// after ejecting: picked up by a nanny ship, by the enemy, and killed.
fn setRescueProbabilities(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    game.world.player.rescue_odds = .{
        .rescued = @truncate(call.args[0]),
        .captured = @truncate(call.args[1]),
        .killed = @truncate(call.args[2]),
    };
    return 1;
}

/// `cmd_WaitForMovie` (`0x00458180`, command `0x09`): the thread waits while a film of the radio's
/// plays (`0x0057C3A8`), running the command again each time.
///
/// Not ported: the radio's films ([#99](https://github.com/vdmkenny/openreliant/issues/99)), none
/// of which plays yet, so the thread runs on.
fn waitForMovie(call: Call) u32 {
    _ = call;
    return 1;
}

/// `cmd_SetupLaunch` (`0x00458970`, command `0x13`): each ship the first argument names takes a
/// Launch order (`setupLaunchShip`), the orders numbered from 0 as they are given
/// (`aigeneric.startNumbering`), which a launch from a flight group or a squad counts its launch
/// points by (`launch.init`).
fn setupLaunch(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    aigeneric.startNumbering(game.world.objects);
    vm.Machine.forEachShip(call, setupLaunchShip);
    aigeneric.stopNumbering(game.world.objects);
    return 1;
}

/// `cmd_SetupLaunch_ship` (`0x004589A0`): pushes a Launch order on the ship's stack, aimed at what
/// the command's second argument names it to launch from: a flight group or a squad by its index,
/// whose ships' launch points the launch searches for a gate, or a ship by its slot, through the
/// gate the third argument gives, counted on by one for each ship the walk reached before this one
/// (`launchGate`). Aimed at anything else, it pushes no order.
fn setupLaunchShip(call: Call, ship: u16) void {
    const machine = call.machine;
    const game = machine.game.?;
    const from = call.args[0];
    const target: aigeneric.Target = if (machine.recordKind(from)) |kind| switch (kind) {
        .flight_group => .{ .kind = .flight_group, .index = targetIndex(machine.flightGroupIndex(from)), .component = aigeneric.Target.whole },
        .squad => .{ .kind = .squad, .index = targetIndex(machine.squadIndex(from)), .component = aigeneric.Target.whole },
        .ship => launchGate(machine, from, call.args[1]),
        _ => return,
    } else launchGate(machine, from, call.args[1]);
    _ = aigeneric.push(game, ship, .launch, target) catch |err| log.warn("mission ship {d} does not launch: {s}", .{ ship, @errorName(err) });
}

/// The target `SetupLaunch` aims a ship at to launch from the ship `from` names: through `gate`,
/// the low half of the command's argument, and on by one for each ship its walk reached before
/// this one (`vm.Machine.walk_count`), wrapping round as a halfword does.
fn launchGate(machine: *const vm.Machine, from: u32, gate: u32) aigeneric.Target {
    const counted = @as(u16, @truncate(gate)) +% machine.walk_count -% 1;
    return .{ .kind = .ship, .index = targetIndex(machine.shipIndex(from)), .component = @bitCast(counted) };
}

/// `cmd_StartLaunch` (`0x00458A40`, command `0x14`): each ship the argument names starts its
/// launch (`launch.start`).
fn startLaunch(call: Call) u32 {
    vm.Machine.forEachShip(call, startLaunchShip);
    return 1;
}

/// `cmd_StartLaunch_ship` (`0x00458A60`).
fn startLaunchShip(call: Call, ship: u16) void {
    launch.start(call.machine.game.?.world.objects, ship);
}

/// `cmd_SetInvulnerability` (`0x00458BC0`, command `0x1A`): each ship the first argument names is
/// made invulnerable or not (`setInvulnerabilityShip`).
fn setInvulnerability(call: Call) u32 {
    vm.Machine.forEachShip(call, setInvulnerabilityShip);
    return 1;
}

/// The missions in which `SetInvulnerability` reaches the players' ships too.
const invulnerable_players = [2]u16{ 30, 35 };

/// `cmd_SetInvulnerability_ship` (`0x00458BE0`): the ship takes the invulnerability the command's
/// second argument gives, or where the first names one of its components (`push_component`), that
/// component does, which its damage does not read yet. Only a ship past the players' slots is
/// reached, save in missions 30 to 35 (`invulnerable_players`).
///
/// Not ported: the game's mode `0x00524FE4` 1, in which the players' ships are reached too.
fn setInvulnerabilityShip(call: Call, ship: u16) void {
    const machine = call.machine;
    const all = machine.game.?.world.objects;
    const mission_number = all.mission_number;
    const players_reached = mission_number >= invulnerable_players[0] and mission_number <= invulnerable_players[1];
    if (ship < all.players and !players_reached) return;
    const object = &all.slots[ship].object;
    const value = call.args[0];
    if (machine.argumentComponent(call.thread, 0)) |component| {
        if (component < object.components.len) object.components[component].invulnerable = @truncate(value);
        return;
    }
    object.invulnerable = @enumFromInt(@as(u8, @truncate(value)));
}

/// How loud a mission's music plays, and how often (`cmd_PlayMusic`, `0x00458E13`): for ever.
const music_level = 80;
const music_forever = 0;

/// The room the game gives a piece's path (`cmd_PlayMusic`'s buffer), and the folder it is in.
const music_path_size = 128;
const music_folder = "music\\";

/// `cmd_PlayMusic` (`0x00458DF0`, command `0x23`): plays the piece the first argument names from the
/// game's music folder, for ever, at once where the second argument is set, or else once the music
/// playing has faded out (`hog_snd.Sound.playMusic`).
///
/// **Fix:** the game writes a path longer than its buffer past it; OpenReliant plays nothing.
fn playMusic(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    const hearing = game.world.hearing orelse return 1;
    const name = call.machine.text(call.args[0]) catch return 1;
    var buffer: [music_path_size]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, music_folder ++ "{s}", .{name}) catch {
        log.warn("the music {s} is left out: its path is too long", .{name});
        return 1;
    };
    hearing.sound.playMusic(path, music_forever, music_level, call.args[1] != 0);
    return 1;
}

/// A command's argument read as the halfword the game stores it as, set or not.
fn halfwordSet(argument: u32) bool {
    return @as(u16, @truncate(argument)) != 0;
}

/// `cmd_DisableTaunts` (`0x00458F40`, command `0x27`): the enemy's taunts on the radio stop, or go
/// on again (`input.Player.taunts_disabled`).
fn disableTaunts(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    game.world.player.taunts_disabled = halfwordSet(call.args[0]);
    return 1;
}

/// `cmd_DisableGenericComms` (`0x004591F0`, command `0x2E`): the remarks the radio makes by itself
/// stop, or go on again (`input.Player.generic_comms_disabled`).
fn disableGenericComms(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    game.world.player.generic_comms_disabled = halfwordSet(call.args[0]);
    return 1;
}

/// `cmd_UpdateEnvironmentFXState` (`0x004591A0`, command `0x38`): what the script asks of its
/// space takes effect at once, rather than at the next jump (`environfx.Environment.update`).
///
/// Not ported: the sun, the lights and the nebula aimed again from the mission's markers
/// (`backdrop_place`, [#72](https://github.com/vdmkenny/openreliant/issues/72)).
fn updateEnvironmentFXState(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    if (game.world.environment) |environment| environment.update();
    return 1;
}

/// `cmd_SetEnvironmentFXNebula` (`0x00459190`, command `0x3C`): asks for the nebula the argument
/// numbers (`environfx.Environment.requested`), which shows once the space is updated.
fn setEnvironmentFXNebula(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    if (game.world.environment) |environment| environment.requested = call.args[0];
    return 1;
}

/// How far back `WaitForJumpOrLaunch` runs again: over its push of the ships and itself.
const wait_back = 4;

/// `cmd_WaitForJumpOrLaunch` (`0x004595A0`, command `0x3A`): the thread waits while any ship the
/// argument names is still jumping or launching (`jumpingOrLaunching`), pushing the argument again
/// and running the command again each time.
fn waitForJumpOrLaunch(call: Call) u32 {
    const machine = call.machine;
    machine.still_moving = false;
    vm.Machine.forEachShip(call, jumpingOrLaunching);
    if (machine.still_moving) return call.again(wait_back);
    return 1;
}

/// `cmd_WaitForJumpOrLaunch_ship` (`0x004595E0`): the ship is still jumping or launching where it
/// is one the AI's searches reach (`gameobj.GameObject.Flags.outOfSearch`) and its current order
/// is one by which a ship jumps, warps or launches.
fn jumpingOrLaunching(call: Call, ship: u16) void {
    const slot = &call.machine.game.?.world.objects.slots[ship];
    if (slot.object.flags.outOfSearch()) return;
    const entry = slot.current() orelse return;
    switch (entry.order) {
        .jump_in, .jump_out, .warp_in, .warp_out, .fixed_gate_jump_in, .fixed_gate_jump_out, .jump_in_40, .jump_out_41, .launch => call.machine.still_moving = true,
        else => {},
    }
}

/// The display's window a command's argument numbers, where there is one.
fn instrument(argument: u32) ?hud.windows.Window {
    const number = std.math.cast(u4, argument) orelse return null;
    return std.enums.fromInt(hud.windows.Window, number);
}

/// `cmd_OpenInstrument` (`0x0045D9D0`, command `0x40`): the display's window the argument numbers
/// opens (`hud.windows.Windows.open`) and is held open until the script closes it. Opening the
/// objectives, window 10, closes the wing status window where it is up. **Unknown:** the byte after
/// the window's hold (`+0x25`), which the command clears.
///
/// Not ported: for the radio's menu, window 11, the menu started afresh (`0x00529530`,
/// `comms_menu_run`, [#99](https://github.com/vdmkenny/openreliant/issues/99)).
///
/// **Fix:** the game opens a window past its fifteen from past its table; OpenReliant opens none.
fn openInstrument(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    const display = game.world.display orelse return 1;
    const window = instrument(call.args[0]) orelse return 1;
    const windows = &display.windows;
    _ = windows.open(window, false);
    windows.status.getPtr(window).held = true;
    if (window == .objectives and windows.up(.wing_status)) windows.close(.wing_status);
    return 1;
}

/// `cmd_CloseInstrument` (`0x0045DA30`, command `0x41`): the display's window the argument numbers
/// closes (`hud.windows.Windows.close`), held open no more.
fn closeInstrument(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    const display = game.world.display orelse return 1;
    const window = instrument(call.args[0]) orelse return 1;
    display.windows.close(window);
    display.windows.status.getPtr(window).held = false;
    return 1;
}

/// `cmd_SetObjective` (`0x00459870`, command `0x43`): the mission's objective the first argument
/// numbers takes the state the second gives (`hud.Objectives.set`).
fn setObjective(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    const display = game.world.display orelse return 1;
    display.objectives.set(call.args[0], @enumFromInt(@as(i16, @truncate(@as(i32, @bitCast(call.args[1]))))));
    return 1;
}

/// `cmd_SetShipAvoidance` (`0x00459A30`, command `0x49`): each ship the first argument names keeps
/// clear of others or not (`setShipAvoidanceShip`).
fn setShipAvoidance(call: Call) u32 {
    vm.Machine.forEachShip(call, setShipAvoidanceShip);
    return 1;
}

/// `cmd_SetShipAvoidance_ship` (`0x00459A50`): the ship, unless a stand-in, keeps clear of others no
/// more where the command's second argument is set, and does again where it is not
/// (`gameobj.GameObject.Flags.no_avoidance`).
fn setShipAvoidanceShip(call: Call, ship: u16) void {
    const object = &call.machine.game.?.world.objects.slots[ship].object;
    if (object.type == .stand_in) return;
    object.flags.no_avoidance = call.args[0] != 0;
}

/// `cmd_MultiplayerScriptSync` (`0x00459DF0`, command `0x56`): in a single-player game, the thread
/// runs on at once.
///
/// Not ported: a multiplayer game's players' scripts kept in step
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn multiplayerScriptSync(call: Call) u32 {
    _ = call;
    return 1;
}

/// `cmd_WhenPlayerLastJumped` (`0x00458580`, command `0x1E`): how many seconds of the script's
/// clock ago JUMP DRIVE last took a jump or a warp (`vm.Machine.last_jumped`), at least 1; and
/// `never_jumped` while the clock stands before it, as it does before the first.
fn whenPlayerLastJumped(call: Call) u32 {
    const machine = call.machine;
    const ago: i32 = @bitCast(machine.clock -% machine.last_jumped);
    if (ago < 0) return vm.Machine.never_jumped;
    return @max(@as(u32, @intCast(ago)), 1);
}

/// The slot of the object that stands for the ship at `place` (`ship_index`, `ship_object`), where
/// it is one of the objects: the game takes any place for a ship's.
fn shipSlot(machine: *const vm.Machine, all: *const create.Objects, place: u32) ?u16 {
    const ship = machine.shipIndex(place) orelse return null;
    return if (ship < all.slots.len) ship else null;
}

/// `cmd_DestroyFlightGroup` (`0x00457FD0`, command `0x04`): each ship of the flight group the
/// argument names leaves the mission at once, a stand-in in its place (`create.retire`).
///
/// Not ported: the atmosphere of a planet among them let go of (`0x00545868`), as the planets'
/// atmospheres are not ported ([#233](https://github.com/vdmkenny/openreliant/issues/233)).
fn destroyFlightGroup(call: Call) u32 {
    const machine = call.machine;
    const game = machine.game orelse return 1;
    const group = machine.flightGroupIndex(call.args[0]) orelse return 1;
    const groups = machine.mission.flightGroups() catch return 1;
    if (group >= groups.len) return 1;
    const all = game.world.objects;
    for (machine.mission.groupShips(groups[group])) |ship| {
        if (ship < all.slots.len) create.retire(game, ship);
    }
    return 1;
}

/// `cmd_ClearAI` (`0x004588C0`, command `0x0C`): each ship the argument names drops its orders
/// (`clearAIShip`).
fn clearAI(call: Call) u32 {
    vm.Machine.forEachShip(call, clearAIShip);
    return 1;
}

/// `cmd_ClearAI_ship` (`0x004588E0`): a ship past the players' slots drops every order, where its
/// current one gives way (`aigeneric.clear`).
fn clearAIShip(call: Call, ship: u16) void {
    const game = call.machine.game.?;
    if (ship < game.world.objects.players) return;
    aigeneric.clear(game, ship) catch |err| log.warn("mission ship {d} keeps its orders: {s}", .{ ship, @errorName(err) });
}

/// How fast `StartShipAnimation` plays its track, a step, forwards and backwards (`0x0045874B`).
const animation_speed: f32 = 4;

/// `cmd_StartShipAnimation` (`0x00458720`, command `0x11`): each part of the ship the first
/// argument names plays its track the second names, from the start, in the track's own mode, at
/// `animation_speed` (`objects.Model.playNamed`).
fn startShipAnimation(call: Call) u32 {
    playShipAnimation(call, false);
    return 1;
}

/// `cmd_StartShipAnimationReverse` (`0x004587D0`, command `0x3D`): the same backwards, each part's
/// track from where it stands.
fn startShipAnimationReverse(call: Call) u32 {
    playShipAnimation(call, true);
    return 1;
}

fn playShipAnimation(call: Call, backwards: bool) void {
    const machine = call.machine;
    const game = machine.game orelse return;
    const all = game.world.objects;
    const ship = shipSlot(machine, all, call.args[0]) orelse return;
    const model = if (all.slots[ship].model) |*live| live else return;
    const name = machine.text(call.args[1]) catch return;
    for (model.parts, 0..) |*part, index| {
        const time: f32 = if (backwards) part.animation.time else 0;
        model.playNamed(index, name, time, null, if (backwards) -animation_speed else animation_speed);
    }
}

/// `cmd_DisableObject` (`0x004583C0`, command `0x1C`): each ship the first argument names is
/// disabled, or enabled again (`disableObjectShip`).
fn disableObject(call: Call) u32 {
    vm.Machine.forEachShip(call, disableObjectShip);
    return 1;
}

/// `cmd_DisableObject_ship` (`0x004583E0`): where the first argument names one of the ship's
/// components (`push_component`), the component's assembly shows its damaged model while the second
/// argument is set, and its own again while it is not; otherwise the ship is disabled, which leaves
/// it out of the mission's work (`GameObject.Flags.disabled`), or enabled again.
fn disableObjectShip(call: Call, ship: u16) void {
    const machine = call.machine;
    const slot = &machine.game.?.world.objects.slots[ship];
    const disabled = call.args[0] != 0;
    const component = machine.argumentComponent(call.thread, 0) orelse {
        slot.object.flags.disabled = disabled;
        return;
    };
    const part = slot.component(component) orelse return;
    const model = if (slot.model) |*live| live.holding(part) orelse return else return;
    var each = model.assembly(part.link_id);
    while (each.next()) |at| {
        const piece = &model.parts[at];
        piece.hidden = if (piece.flags.damaged) !disabled else disabled;
    }
}

/// `cmd_SetPlayerTarget` (`0x00458C80`, command `0x21`): where the first argument names the
/// player's ship, the ship the second names, or its component (`push_component`), becomes the
/// player's target, where it can be aimed at (`ai.targetValid`): the player's Player Control order
/// is aimed at it, the display follows (`hud.State.targetChanged`), and the player stops matching
/// speeds (`input.Player.matching_speed`).
///
/// Not ported: a ship past the players' slots aimed through its Multiplayer Control order, which
/// no ship has outside a multiplayer game ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn setPlayerTarget(call: Call) u32 {
    const machine = call.machine;
    const game = machine.game orelse return 1;
    const world = game.world;
    const all = world.objects;
    if (shipSlot(machine, all, call.args[0]) != all.player) return 1;
    const component: i16 = if (machine.argumentComponent(call.thread, 1)) |part| part else aigeneric.Target.whole;
    const aimed: aigeneric.Target = .{ .kind = .ship, .index = targetIndex(machine.shipIndex(call.args[1])), .component = component };
    if (!ai.targetValid(all, aimed, .{})) return 1;
    const entry = ai.playerControlEntry(all) orelse return 1;
    entry.target.index = aimed.index;
    entry.target.component = aimed.component;
    if (world.display) |display| display.targetChanged(all, false);
    world.player.matching_speed = false;
    return 1;
}

/// `cmd_SetTargetable` (`0x00458D50`, command `0x22`): each ship the first argument names can be
/// targeted, or not (`setTargetableShip`).
fn setTargetable(call: Call) u32 {
    vm.Machine.forEachShip(call, setTargetableShip);
    return 1;
}

/// `cmd_SetTargetable_ship` (`0x00458D70`): where the first argument names one of the ship's
/// components (`push_component`), the component can be picked as a subtarget, or not
/// (`objects.Model.Part.targetable`); otherwise the ship can be targeted, where its type allows, or
/// not (`ai.setTargetable`).
fn setTargetableShip(call: Call, ship: u16) void {
    const machine = call.machine;
    const slot = &machine.game.?.world.objects.slots[ship];
    const targetable = call.args[0] != 0;
    const component = machine.argumentComponent(call.thread, 0) orelse return ai.setTargetable(&slot.object, slot.combat, targetable);
    if (slot.component(component)) |part| part.targetable = targetable;
}

/// `cmd_SetActionCentre` (`0x00458E60`, command `0x25`): the sphere the fighters keep to
/// (`aigeneric.ActionSphere`) centres on the object the first argument names, its radius the
/// second, or the default one for none.
///
/// **Fix:** where the first argument names no object, the game centres the sphere on the slot
/// before the objects; OpenReliant keeps its centre.
fn setActionCentre(call: Call) u32 {
    const machine = call.machine;
    const game = machine.game orelse return 1;
    const all = game.world.objects;
    const sphere = &all.action_sphere;
    if (shipSlot(machine, all, call.args[0])) |centre| sphere.centre = centre;
    const radius: f32 = @floatFromInt(call.args[1]);
    sphere.radius = if (radius == 0) aigeneric.ActionSphere.default.radius else radius;
    return 1;
}

/// `cmd_DisableGuns` (`0x00459200`, command `0x2F`): each ship the first argument names fires no
/// guns, or fires them again (`disableGunsShip`).
fn disableGuns(call: Call) u32 {
    vm.Machine.forEachShip(call, disableGunsShip);
    return 1;
}

/// `cmd_DisableGuns_ship` (`0x00459220`): the ship's guns are disabled while the command's second
/// argument is set, and enabled again while it is not (`GameObject.Flags.guns_disabled`), which
/// rests its turrets too.
fn disableGunsShip(call: Call, ship: u16) void {
    call.machine.game.?.world.objects.slots[ship].object.flags.guns_disabled = call.args[0] != 0;
}

/// `cmd_SetEscortPoint` (`0x004592F0`, command `0x31`): each ship the first argument names takes
/// the object the second names as its escort point (`setEscortPointShip`).
fn setEscortPoint(call: Call) u32 {
    vm.Machine.forEachShip(call, setEscortPointShip);
    return 1;
}

/// `cmd_SetEscortPoint_ship` (`0x00459310`): the ship's escort point becomes the object the
/// command's second argument names, or none (`GameObject.escort_point`).
fn setEscortPointShip(call: Call, ship: u16) void {
    const machine = call.machine;
    const all = machine.game.?.world.objects;
    all.slots[ship].object.escort_point = .from(shipSlot(machine, all, call.args[0]));
}

/// `cmd_SetPrimaryTarget` (`0x00459550`, command `0x39`): the ship the argument names, or its
/// component (`push_component`), becomes the mission's primary target, which PRIMARY TARGET makes
/// the player's (`input.Player.primary_target`); none where it names no object.
fn setPrimaryTarget(call: Call) u32 {
    const machine = call.machine;
    const game = machine.game orelse return 1;
    const all = game.world.objects;
    const index = shipSlot(machine, all, call.args[0]) orelse {
        game.world.player.primary_target = null;
        return 1;
    };
    game.world.player.primary_target = .{ .index = index, .component = machine.argumentComponent(call.thread, 0) };
    return 1;
}

/// `cmd_SnapToPoint` (`0x004596A0`, command `0x3E`): the ship the first argument names, unless it
/// is exploding, ejected or out of a multiplayer game (`GameObject.Flags._unknown_28`), is put where
/// the object the second names will stand next, turned as it will be, and stopped (`ai.stop`).
///
/// Not ported: in a multiplayer game, the move told to the other players
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn snapToPoint(call: Call) u32 {
    const machine = call.machine;
    const game = machine.game orelse return 1;
    const all = game.world.objects;
    const ship = shipSlot(machine, all, call.args[0]) orelse return 1;
    const slot = &all.slots[ship];
    const flags = slot.object.flags;
    if (flags.exploding or flags.ejected or flags._unknown_28) return 1;
    const point = shipSlot(machine, all, call.args[1]) orelse return 1;
    const to = all.slots[point].object.root;
    objects.setPosition(&slot.object, &slot.drawn, gameobj.vector(to.next_position));
    objects.setOrientation(&slot.object, &slot.drawn, to.next_orientation);
    ai.stop(&slot.object);
    return 1;
}

/// What `IsShipThisPlayer` answers: 1 for yes, which the scripts test for, and 2 for no; a command's
/// result of 0 would suspend its thread.
const answer_yes: u32 = 1;
const answer_no: u32 = 2;

/// `cmd_IsShipThisPlayer` (`0x004598F0`, command `0x45`): whether the argument names the player's
/// ship.
fn isShipThisPlayer(call: Call) u32 {
    const machine = call.machine;
    const game = machine.game orelse return answer_no;
    return if (machine.shipIndex(call.args[0]) == game.world.objects.player) answer_yes else answer_no;
}

/// `cmd_SetFlybackMarker` (`0x00459910`, command `0x46`): the flyback markers start afresh with
/// each ship the first argument names (`setFlybackMarkerShip`).
fn setFlybackMarker(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    game.world.player.flyback = .{};
    vm.Machine.forEachShip(call, setFlybackMarkerShip);
    return 1;
}

/// `cmd_SetFlybackMarker_ship` (`0x00459960`): the ship, unless it is a stand-in, is marked, the
/// command's second argument its reach (`input.Flyback.mark`).
fn setFlybackMarkerShip(call: Call, ship: u16) void {
    const game = call.machine.game.?;
    if (game.world.objects.slots[ship].object.type == .stand_in) return;
    game.world.player.flyback.mark(ship, @floatFromInt(call.args[0]));
}

/// `cmd_ResetFlybackMarker` (`0x004599E0`, command `0x47`): the flyback markers are dropped, and the
/// player's ship points to no nav point.
fn resetFlybackMarker(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    const all = game.world.objects;
    game.world.player.flyback = .{};
    all.slots[all.player].object.nav_point = .none;
    return 1;
}

/// `cmd_MatchSpeed` (`0x00459A90`, command `0x4A`): where the first argument names the player's
/// ship, the player matches the target's speed from now on, where the second is set, having
/// matched it at once where it already did (`input.matchTargetSpeed`), or stops matching it.
fn matchSpeed(call: Call) u32 {
    const machine = call.machine;
    const game = machine.game orelse return 1;
    const world = game.world;
    const all = world.objects;
    if (machine.shipIndex(call.args[0]) != all.player) return 1;
    if (call.args[1] != 0) {
        input.matchTargetSpeed(world.player, all, world.view);
        world.player.matching_speed = true;
    } else {
        world.player.matching_speed = false;
    }
    return 1;
}

/// `cmd_StartDirectorCam` (`0x004582E0`, command `0x10`): the director's shots waiting are
/// dropped, and the camera takes this one at once (`stackDirectorCam`).
fn startDirectorCam(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    const view = game.world.camera orelse return 1;
    view.shots.count = 0;
    return stackDirectorCam(call);
}

/// `cmd_StackDirectorCam` (`0x00458300`, command `0x52`): the director's camera takes the shot the
/// arguments give after those waiting (`camera.shots.stack`): the curve its path starts along, or
/// the ship it stands at; the ship it looks at; its seconds; the ship its path rides along with;
/// and the ship, flight group or squad it holds still while it is on screen.
fn stackDirectorCam(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    const view = game.world.camera orelse return 1;
    camera.shots.stack(game.world, view, directorShot(call.machine, call.args));
    return 1;
}

/// The shot `StackDirectorCam`'s arguments `args` give. The first names a curve unless it names one
/// of the mission's records, which it takes for a ship's (`record_kind`, `ship_index`), and the
/// seconds are a whole number.
fn directorShot(machine: *vm.Machine, args: []const u32) camera.shots.Shot {
    const path: ?camera.shots.Shot.Path = if (machine.recordKind(args[0]) != null)
        if (machine.shipIndex(args[0])) |ship| .{ .ship = ship } else null
    else if (machine.curveIndex(args[0])) |curve| .{ .curve = curve } else null;
    const held: ?aigeneric.Target = if (machine.recordKind(args[4])) |kind| switch (kind) {
        .ship => if (machine.shipIndex(args[4])) |ship| .at(ship, null) else null,
        .flight_group => if (machine.flightGroupIndex(args[4])) |group| .{ .kind = .flight_group, .index = @bitCast(group), .component = aigeneric.Target.whole } else null,
        .squad => if (machine.squadIndex(args[4])) |squad| .{ .kind = .squad, .index = @bitCast(squad), .component = aigeneric.Target.whole } else null,
        _ => null,
    } else null;
    return .{
        .path = path,
        .tracked = machine.shipIndex(args[1]),
        .seconds = @floatFromInt(args[2]),
        .pace = machine.shipIndex(args[3]),
        .held = held,
    };
}

/// `cmd_StopDirectorCam` (`0x00458E30`, command `0x24`): the camera goes back to the player's
/// cockpit, forced, unless the player's slot holds a stand-in. The shots waiting stay.
fn stopDirectorCam(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    const view = game.world.camera orelse return 1;
    const all = game.world.objects;
    if (all.slots[all.player].object.type != .stand_in) _ = view.setView(.cockpit, all.player, false, true, game.clock.viewTime());
    return 1;
}

/// `cmd_WaitForDirectorCam` (`0x00459C90`, command `0x50`): the thread waits while the camera is in
/// the director's view, running the command again each time.
fn waitForDirectorCam(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    const view = game.world.camera orelse return 1;
    return if (view.view == .director) call.again(director_wait_back) else 1;
}

/// How far back `WaitForDirectorCam` runs again: over itself.
const director_wait_back = 2;

/// A command's implementation. `args` points at its first argument on the stack. The result is
/// stored in `Thread.result`, and a zero result also ends the handler loop.
pub const Command = Code("uint __fastcall (byte **ip, uint *args)");

/// What a command hands `for_each_ship` to run for each ship its first argument names: the ship,
/// and the command's remaining arguments.
pub const ShipCommand = Code("uint __fastcall (MissionShip *ship, uint *args)");

test commandIndex {
    try std.testing.expectEqual(0x05, commandIndex("Wait"));
    try std.testing.expectEqualStrings("Wait", commands.table[commandIndex("Wait")].name);
}

test implementation {
    try std.testing.expect(implementation(commandIndex("Wait")) != null);
    try std.testing.expectEqual(null, implementation(commandIndex("PrintShipName")));
    try std.testing.expectEqual(null, implementation(0xFF));
}

test whenPlayerLastJumped {
    var machine: vm.Machine = .{ .gpa = std.testing.allocator, .mission = undefined, .random = undefined };
    const call: Call = .{ .machine = &machine, .thread = 0, .args = &.{} };
    // Before the first jump, never.
    machine.clock = 5;
    try std.testing.expectEqual(vm.Machine.never_jumped, whenPlayerLastJumped(call));
    // In the second of the jump, 1; then the seconds since.
    machine.last_jumped = 5;
    try std.testing.expectEqual(1, whenPlayerLastJumped(call));
    machine.clock = 12;
    try std.testing.expectEqual(7, whenPlayerLastJumped(call));
}

/// A mission ship record for the tests: in `group`, of `kind`, flown by `pilot`, launching from
/// none.
fn testShip(id: u32, group: u8, kind: u16, pilot: u8) dte.Ship {
    var ship = std.mem.zeroes(dte.Ship);
    ship.object_id = id;
    ship.flight_group = group;
    ship.kind = kind;
    ship.pilot = pilot;
    ship.launch_gate = dte.Ship.no_launch;
    ship.tier = 0xFF;
    return ship;
}

fn testGroup(id: u16, wing: u8) dte.FlightGroup {
    var group = std.mem.zeroes(dte.FlightGroup);
    group.object_id = id;
    group.wing = wing;
    return group;
}

test "a mission's start part makes its ships and gives them their orders" {
    const gpa = std.testing.allocator;
    const Routine = vm.machine.testing.Routine;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    for (0..4) |group| {
        try routine.op(.push_flight_group, &.{@intCast(group)});
        try routine.command("CreateFlightGroup");
    }
    // The Sabres fight the player's ship.
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_byte, &.{@intCast(@intFromEnum(Order.fight))});
    try routine.op(.push_byte, &.{1});
    try routine.op(.push_ship, &.{0});
    try routine.command("SetAI");
    // The Reliant flies at 10, holding its heading.
    try routine.op(.push_ship, &.{5});
    try routine.op(.push_null, &.{});
    try routine.op(.push_byte, &.{10});
    try routine.command("Fly");
    try routine.op(.push_byte, &.{33});
    try routine.op(.push_byte, &.{33});
    try routine.op(.push_byte, &.{34});
    try routine.command("SetRescueProbabilities");
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);

    var sabre = testShip(2, 1, @intFromEnum(gameobj.Type.sabre), 42);
    sabre.yaw = 180;
    var fixture: vm.machine.testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            testShip(0, 0, @intFromEnum(gameobj.Type.predator), dte.Ship.no_pilot),
            testShip(1, 0, @intFromEnum(gameobj.Type.grendel), 5),
            sabre,
            testShip(3, 1, @intFromEnum(gameobj.Type.sabre), 42),
            testShip(4, 2, nav_point_kind, dte.Ship.no_pilot),
            testShip(5, 3, @intFromEnum(gameobj.Type.reliant), 60),
        },
        .flight_groups = &.{ testGroup(6, 0), testGroup(7, dte.FlightGroup.no_wing), testGroup(8, dte.FlightGroup.no_wing), testGroup(9, dte.FlightGroup.no_wing) },
    });
    defer fixture.deinit();
    var world: gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    var game = world.orders();
    game.world.spawn = .{ .tables = &world.tables, .types = create.testing.no_models };
    fixture.machine.game = game;
    try fixture.machine.start();

    const all = world.objects;
    // Each ship in the slot of its index, of its kind; the nav point a marker.
    const types = [_]gameobj.Type{ .predator, .grendel, .sabre, .sabre, .marker, .reliant };
    for (types, all.slots[0..types.len]) |made, slot| {
        try std.testing.expect(slot.object.created);
        try std.testing.expectEqual(made, slot.object.type);
    }
    // The player's ship on its controls, the others at rest until the script says otherwise.
    try std.testing.expectEqual(Order.player_control, all.slots[0].orders[0].order);
    try std.testing.expectEqual(Order.do_nothing, all.slots[1].orders[0].order);
    // The Sabres fight the player, numbered in turn, each naming the first of them but the first.
    for ([_]u16{ 2, 3 }, 0..) |at, n| {
        const entry = all.slots[at].orders[0];
        try std.testing.expectEqual(Order.fight, entry.order);
        try std.testing.expectEqual(0, entry.target.ship());
        try std.testing.expectEqual(@as(i16, @intCast(n)), entry.sequence);
        try std.testing.expectEqual(42, all.slots[at].object.pilot);
    }
    try std.testing.expectEqual(0xFF00FFFF, all.slots[2].object._unknown_698);
    try std.testing.expectEqual(0xFF000002, all.slots[3].object._unknown_698);
    // Turned by its record: the first Sabre faces back along Z.
    try std.testing.expectApproxEqAbs(-1, @import("../surrender/math.zig").forward(all.slots[2].object.root.orientation)[2], 1e-6);
    // The Reliant flies at 10, at nothing.
    try std.testing.expectEqual(Order.fly, all.slots[5].orders[0].order);
    try std.testing.expectEqual(null, all.slots[5].orders[0].target.ship());
    try std.testing.expectEqual(10, all.slots[5].orders[0].data.fly);
    // The player's flight group is the player's wing.
    try std.testing.expectEqual(mission.WingSlots{ 0, 1, null, null, null, null }, all.wing);
    try std.testing.expectEqual(.player, all.slots[1].object.wing);
    try std.testing.expectEqual(.none, all.slots[2].object.wing);
    try std.testing.expectEqual(@import("aieject.zig").RescueOdds{ .rescued = 33, .captured = 33, .killed = 34 }, world.player.rescue_odds);
}

test "the launch commands set ships up, start them, and wait for them" {
    const gpa = std.testing.allocator;
    const Routine = vm.machine.testing.Routine;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    // The Reliant's flight group first, then the two Sabres', which launch from it through its
    // tubes from the fourth on, and wait until they are out.
    for ([_]u8{ 2, 0, 1 }) |group| {
        try routine.op(.push_flight_group, &.{group});
        try routine.command("CreateFlightGroup");
    }
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_ship, &.{4});
    try routine.op(.push_byte, &.{3});
    try routine.command("SetupLaunch");
    try routine.op(.push_flight_group, &.{1});
    try routine.command("StartLaunch");
    try routine.op(.push_flight_group, &.{1});
    try routine.command("WaitForJumpOrLaunch");
    try routine.op(.select_global, &.{0});
    try routine.op(.push_byte, &.{1});
    try routine.op(.assign, &.{});
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);

    var fixture: vm.machine.testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{0},
        .ships = &.{
            testShip(0, 0, @intFromEnum(gameobj.Type.predator), dte.Ship.no_pilot),
            testShip(1, 0, @intFromEnum(gameobj.Type.grendel), 5),
            testShip(2, 1, @intFromEnum(gameobj.Type.sabre), 42),
            testShip(3, 1, @intFromEnum(gameobj.Type.sabre), 42),
            testShip(4, 2, @intFromEnum(gameobj.Type.reliant), 60),
        },
        .flight_groups = &.{ testGroup(5, 0), testGroup(6, dte.FlightGroup.no_wing), testGroup(7, dte.FlightGroup.no_wing) },
    });
    defer fixture.deinit();
    var world: gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    var game = world.orders();
    game.world.spawn = .{ .tables = &world.tables, .types = create.testing.no_models };
    fixture.machine.game = game;
    try fixture.machine.start();

    // Each Sabre launches from the Reliant through a tube of its own, started.
    const all = world.objects;
    for ([_]u16{ 2, 3 }, 3..) |ship, gate| {
        const entry = all.slots[ship].orders[0];
        try std.testing.expectEqual(Order.launch, entry.order);
        try std.testing.expectEqual(4, entry.target.ship());
        try std.testing.expectEqual(@as(i16, @intCast(gate)), entry.target.component);
        try std.testing.expect(entry.data.launch.go);
    }
    // The script waits while they launch, and runs on once they are out.
    try std.testing.expectEqual(0, fixture.global(0));
    fixture.second();
    try std.testing.expectEqual(0, fixture.global(0));
    for ([_]u16{ 2, 3 }) |ship| _ = aigeneric.pop(game, ship);
    fixture.second();
    try std.testing.expectEqual(1, fixture.global(0));
}

test "the commands that set ships, the radio, the display and the space" {
    const gpa = std.testing.allocator;
    const Routine = vm.machine.testing.Routine;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    for ([_]u8{ 0, 1 }) |group| {
        try routine.op(.push_flight_group, &.{group});
        try routine.command("CreateFlightGroup");
    }
    // The Sabres keep clear of nothing; the player's ship, and the second Sabre, invulnerable.
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_byte, &.{1});
    try routine.command("SetShipAvoidance");
    for ([_]u8{ 0, 2 }) |ship| {
        try routine.op(.push_ship, &.{ship});
        try routine.op(.push_byte, &.{@intFromEnum(gameobj.Invulnerability.full)});
        try routine.command("SetInvulnerability");
    }
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableTaunts");
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableGenericComms");
    // The objectives window opens, the second objective current, and nebula 6 asked for.
    try routine.op(.push_byte, &.{@intFromEnum(hud.windows.Window.objectives)});
    try routine.command("OpenInstrument");
    try routine.op(.push_byte, &.{1});
    try routine.op(.push_byte, &.{@intFromEnum(hud.Objectives.Status.current)});
    try routine.command("SetObjective");
    try routine.op(.push_byte, &.{6});
    try routine.command("SetEnvironmentFXNebula");
    try routine.op(.push_byte, &.{0});
    try routine.command("MultiplayerScriptSync");
    try routine.command("WaitForMovie");
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);

    var fixture: vm.machine.testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            testShip(0, 0, @intFromEnum(gameobj.Type.predator), dte.Ship.no_pilot),
            testShip(1, 1, @intFromEnum(gameobj.Type.sabre), 42),
            testShip(2, 1, @intFromEnum(gameobj.Type.sabre), 42),
        },
        .flight_groups = &.{ testGroup(3, 0), testGroup(4, dte.FlightGroup.no_wing) },
    });
    defer fixture.deinit();
    var world: gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    world.objects.mission_number = 1;
    var display: hud.State = .{};
    display.objectives.reset(1, false);
    var environment: @import("environfx.zig").Environment = .{ .sky = undefined, .textures = undefined, .lights = undefined };
    var game = world.orders();
    game.world.spawn = .{ .tables = &world.tables, .types = create.testing.no_models };
    game.world.display = &display;
    game.world.environment = &environment;
    fixture.machine.game = game;
    try fixture.machine.start();

    const all = world.objects;
    try std.testing.expect(!all.slots[0].object.flags.no_avoidance and all.slots[1].object.flags.no_avoidance and all.slots[2].object.flags.no_avoidance);
    // Outside missions 30 to 35 the player's ship is not reached.
    try std.testing.expectEqual(.none, all.slots[0].object.invulnerable);
    try std.testing.expectEqual(.full, all.slots[2].object.invulnerable);
    try std.testing.expect(world.player.taunts_disabled and world.player.generic_comms_disabled);
    try std.testing.expect(display.windows.up(.objectives));
    try std.testing.expect(display.windows.status.get(.objectives).held);
    try std.testing.expectEqual(.current, display.objectives.states[1]);
    try std.testing.expectEqual(1, display.objectives.shown);
    try std.testing.expectEqual(6, environment.requested);
    // Neither the sync nor the films hold the thread in a game of one player with no films.
    try std.testing.expect(fixture.machine.finished);
}

test "the commands mission 1 runs at the convoy" {
    const gpa = std.testing.allocator;
    const Routine = vm.machine.testing.Routine;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    for ([_]u8{ 0, 1, 2, 3 }) |group| {
        try routine.op(.push_flight_group, &.{group});
        try routine.command("CreateFlightGroup");
    }
    // The second Sabre becomes the player's target and the primary one; the action centres on the
    // first Sabre, 50000 across; the Sabres' guns are disabled.
    try routine.op(.push_ship, &.{2});
    try routine.op(.push_byte, &.{1});
    try routine.command("SetTargetable");
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_ship, &.{2});
    try routine.command("SetPlayerTarget");
    try routine.op(.push_ship, &.{2});
    try routine.command("SetPrimaryTarget");
    try routine.op(.push_ship, &.{1});
    try routine.pushConstant(50000);
    try routine.command("SetActionCentre");
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableGuns");
    // The player escorts the nav point, which also marks where to fly back to, 20000 about it; a
    // Grendel is put on the nav point, and the other disabled.
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_ship, &.{3});
    try routine.command("SetEscortPoint");
    try routine.op(.push_ship, &.{3});
    try routine.pushConstant(20000);
    try routine.command("SetFlybackMarker");
    try routine.op(.push_ship, &.{4});
    try routine.op(.push_ship, &.{3});
    try routine.command("SnapToPoint");
    try routine.op(.push_ship, &.{5});
    try routine.op(.push_byte, &.{1});
    try routine.command("DisableObject");
    // Which of two ships is the player's.
    for ([_]u8{ 0, 1 }, [_]u8{ 0, 2 }) |global, ship| {
        try routine.op(.select_global, &.{global});
        try routine.op(.push_ship, &.{ship});
        try routine.command("IsShipThisPlayer");
        try routine.op(.push_result, &.{});
        try routine.op(.assign, &.{});
    }
    // The player matches its target's speed; the Sabres drop their orders.
    try routine.op(.push_ship, &.{0});
    try routine.op(.push_byte, &.{1});
    try routine.command("MatchSpeed");
    try routine.op(.push_flight_group, &.{1});
    try routine.command("ClearAI");
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);

    var marker = testShip(3, 2, nav_point_kind, dte.Ship.no_pilot);
    marker.position = .{ 0, 0, 30000 };
    var fixture: vm.machine.testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{ 0, 0 },
        .ships = &.{
            testShip(0, 0, @intFromEnum(gameobj.Type.predator), dte.Ship.no_pilot),
            testShip(1, 1, @intFromEnum(gameobj.Type.sabre), 42),
            testShip(2, 1, @intFromEnum(gameobj.Type.sabre), 42),
            marker,
            testShip(4, 3, @intFromEnum(gameobj.Type.grendel), 5),
            testShip(5, 3, @intFromEnum(gameobj.Type.grendel), 5),
        },
        .flight_groups = &.{ testGroup(6, 0), testGroup(7, dte.FlightGroup.no_wing), testGroup(8, dte.FlightGroup.no_wing), testGroup(9, dte.FlightGroup.no_wing) },
    });
    defer fixture.deinit();
    var world: gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    world.tables.combat[@intFromEnum(gameobj.Type.sabre)].targeting.targetable = true;
    var game = world.orders();
    game.world.spawn = .{ .tables = &world.tables, .types = create.testing.no_models };
    fixture.machine.game = game;
    try fixture.machine.start();

    const all = world.objects;
    try std.testing.expectEqual(2, ai.playerControlEntry(all).?.target.slot());
    try std.testing.expectEqual(2, world.player.primary_target.?.index);
    try std.testing.expectEqual(null, world.player.primary_target.?.component);
    try std.testing.expectEqual(1, all.action_sphere.centre);
    try std.testing.expectEqual(50000, all.action_sphere.radius);
    try std.testing.expect(all.slots[1].object.flags.guns_disabled and all.slots[2].object.flags.guns_disabled);
    try std.testing.expect(!all.slots[0].object.flags.guns_disabled);
    try std.testing.expectEqual(gameobj.Slot.of(3), all.slots[0].object.escort_point);
    try std.testing.expectEqual(1, world.player.flyback.count);
    try std.testing.expectEqual(3, world.player.flyback.markers[0].slot);
    try std.testing.expectEqual(20000, world.player.flyback.markers[0].reach);
    try std.testing.expectEqual(30000, all.slots[4].object.root.position.z);
    try std.testing.expect(all.slots[5].object.flags.disabled);
    try std.testing.expectEqual(answer_yes, fixture.global(0));
    try std.testing.expectEqual(answer_no, fixture.global(1));
    try std.testing.expect(world.player.matching_speed);
    try std.testing.expectEqual(0, all.slots[1].object.order_count);
    // The player's ship, 30000 from the nav point, points back to it.
    input.nextNavPoint(game.world);
    try std.testing.expectEqual(gameobj.Slot.of(3), all.slots[0].object.nav_point);
}

test "the flyback markers and the Grendels go, and the action sphere takes its default" {
    const gpa = std.testing.allocator;
    const Routine = vm.machine.testing.Routine;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    for ([_]u8{ 0, 1 }) |group| {
        try routine.op(.push_flight_group, &.{group});
        try routine.command("CreateFlightGroup");
    }
    try routine.op(.push_ship, &.{1});
    try routine.pushConstant(0);
    try routine.command("SetActionCentre");
    try routine.command("ResetFlybackMarker");
    try routine.op(.push_flight_group, &.{1});
    try routine.command("DestroyFlightGroup");
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);

    var fixture: vm.machine.testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            testShip(0, 0, @intFromEnum(gameobj.Type.predator), dte.Ship.no_pilot),
            testShip(1, 1, @intFromEnum(gameobj.Type.grendel), 5),
            testShip(2, 1, @intFromEnum(gameobj.Type.grendel), 5),
        },
        .flight_groups = &.{ testGroup(3, 0), testGroup(4, dte.FlightGroup.no_wing) },
    });
    defer fixture.deinit();
    var world: gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    var game = world.orders();
    game.world.spawn = .{ .tables = &world.tables, .types = create.testing.no_models };
    fixture.machine.game = game;
    world.player.flyback.mark(0, 10);
    world.objects.action_sphere.radius = 5;
    try fixture.machine.start();

    const all = world.objects;
    try std.testing.expectEqual(aigeneric.ActionSphere.default.radius, all.action_sphere.radius);
    try std.testing.expectEqual(0, world.player.flyback.count);
    try std.testing.expectEqual(.none, all.slots[0].object.nav_point);
    for ([_]u16{ 1, 2 }) |ship| try std.testing.expectEqual(.stand_in, all.slots[ship].object.type);
}

test shipType {
    var world: gameobj.testing.Mission = undefined;
    try world.init(std.testing.allocator);
    defer world.deinit();
    const all = world.objects;
    const image = try mission.bind.testing.image(std.testing.allocator, .{
        .ships = &.{ testShip(0, 0, 2, dte.Ship.no_pilot), testShip(1, 1, 2, 5) },
        .flight_groups = &.{ testGroup(2, 0), testGroup(3, dte.FlightGroup.no_wing) },
    });
    var bound: mission.Mission = try .bind(std.testing.allocator, image);
    defer bound.deinit();
    const ships = try bound.ships();
    // Before the 14th mission every ship is of its kind.
    try std.testing.expectEqual(gameobj.Type.grendel, shipType(all, &bound, ships[0]));
    // From it on, the player's wing flies the twins, and mission 25's first part a Kamov.
    all.mission_number = create.twins_from_mission;
    try std.testing.expectEqual(gameobj.Type.grendel.twin().?, shipType(all, &bound, ships[0]));
    try std.testing.expectEqual(gameobj.Type.grendel, shipType(all, &bound, ships[1]));
    all.mission_number = create.kamov_mission;
    try std.testing.expectEqual(gameobj.Type.kamov, shipType(all, &bound, ships[0]));
}

test "the director's commands stack shots, wait for them and stop them" {
    const gpa = std.testing.allocator;
    const Routine = vm.machine.testing.Routine;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    try routine.op(.push_flight_group, &.{0});
    try routine.command("CreateFlightGroup");
    // Along the curve for a second, looking at the Sabre, the player's flight group held still.
    try routine.op(.push_curve, &.{0});
    try routine.op(.push_ship, &.{3});
    try routine.op(.push_byte, &.{1});
    try routine.op(.push_null, &.{});
    try routine.op(.push_flight_group, &.{0});
    try routine.command("StartDirectorCam");
    try routine.command("WaitForDirectorCam");
    try routine.op(.select_global, &.{0});
    try routine.op(.push_byte, &.{1});
    try routine.op(.assign, &.{});
    // Then at the Sabre for five seconds, stopped at once.
    try routine.op(.push_ship, &.{3});
    try routine.op(.push_null, &.{});
    try routine.op(.push_byte, &.{5});
    try routine.op(.push_null, &.{});
    try routine.op(.push_null, &.{});
    try routine.command("StackDirectorCam");
    try routine.command("StopDirectorCam");
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);

    const point = dte.Ship.curve_point_kind;
    var fixture: vm.machine.testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{0},
        .ships = &.{
            testShip(0, 0, @intFromEnum(gameobj.Type.predator), dte.Ship.no_pilot),
            testShip(1, dte.Ship.no_flight_group, point, dte.Ship.no_pilot),
            testShip(2, dte.Ship.no_flight_group, point, dte.Ship.no_pilot),
            testShip(3, 0, @intFromEnum(gameobj.Type.sabre), 42),
        },
        .flight_groups = &.{testGroup(4, 0)},
        .curves = &.{curves.testCurve(1, 2, .{ 0, 0, 0 }, .{ 0, 0, 1000 })},
    });
    defer fixture.deinit();
    var world: gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    var view: camera.Camera = .{};
    var game = world.orders();
    game.world.spawn = .{ .tables = &world.tables, .types = create.testing.no_models };
    game.world.mission = &fixture.mission;
    game.world.camera = &view;
    fixture.machine.game = game;
    try fixture.machine.start();

    // The curve's points are made as markers, the start part having left them.
    const all = world.objects;
    for (all.slots[1..3]) |slot| try std.testing.expectEqual(gameobj.Type.marker, slot.object.type);
    // The shot on screen, the flight group held, and the script waiting for it.
    try std.testing.expectEqual(camera.View.director, view.view);
    try std.testing.expectEqual(3, view.director.tracked);
    try std.testing.expectEqual(100, view.director.total);
    for ([_]u16{ 0, 3 }) |ship| try std.testing.expect(all.slots[ship].object.flags.jumping);
    fixture.second();
    try std.testing.expectEqual(0, fixture.global(0));
    const seen: camera.Subject = .{ .position = @splat(0), .orientation = @import("../surrender/math.zig").identity };
    world.clock.frame_duration = 100;
    _ = view.frame(.{ .object = seen, .player = seen, .ticks = 100, .game = game.world });
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    for ([_]u16{ 0, 3 }) |ship| try std.testing.expect(!all.slots[ship].object.flags.jumping);
    // Over, the script runs on: the next shot begins and is stopped, and stays stacked.
    fixture.second();
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expectEqual(1, view.shots.count);
    try std.testing.expectEqual(camera.shots.Shot.Path{ .ship = 3 }, view.shots.first().?.path.?);
}

test {
    std.testing.refAllDecls(@This());
}
