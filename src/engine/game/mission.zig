//! `C:\lancer\game\mission.cpp`: a mission in play. Its file bound (`bind`), its events raised on
//! its script's triggers (`events`), its script run each frame (`Loaded.process`), its ships kept
//! where their objects are (`syncShips`), and its flight groups listed in the wings
//! (`buildWings`).
//!
//! Not ported: the second and third wings' lists (`0x00515D7C`, `0x00515D94`), which nothing reads.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const bind = @import("mission/bind.zig");
pub const events = @import("mission/events.zig");
pub const Mission = bind.Mission;

const dte = @import("../../formats/dte.zig");
const libcmt = @import("../libcmt.zig");
const math = @import("../surrender/math.zig");
const vm = @import("../vm.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const ticks_per_second = @import("main.zig").ticks_per_second;

/// How many ships a wing lists.
pub const wing_size = 6;

/// A wing's ships (`player_wing`, `0x00515D88`, for the player's): a slot each, null for none.
pub const WingSlots = [wing_size]?u16;

/// A mission loaded for play (`mission_loaded`): its file bound, its script, which runs on it, and
/// its events.
pub const Loaded = struct {
    bound: Mission,
    script: vm.Machine,
    events: events.Events,
    /// The game's ticks when the script's clock started (`vm_clock_start`), from which it counts
    /// the mission's seconds (`tickClock`).
    clock_from: u32 = 0,

    /// Binds `image`, made in `gpa`, which the mission then owns, with its script ready to start
    /// (`mission_bind_sections`) and no events waiting (`init_mission`). The script draws its
    /// random numbers from `random`.
    pub fn create(gpa: Allocator, image: []u8, random: *libcmt.Rand) !*Loaded {
        const loaded = gpa.create(Loaded) catch |err| {
            gpa.free(image);
            return err;
        };
        errdefer gpa.destroy(loaded);
        loaded.* = .{ .bound = try .bind(gpa, image), .script = undefined, .events = undefined };
        loaded.script = .init(gpa, &loaded.bound, random);
        loaded.events = .init(gpa, &loaded.script);
        return loaded;
    }

    pub fn destroy(loaded: *Loaded) void {
        const gpa = loaded.bound.gpa;
        loaded.events.deinit();
        loaded.script.deinit();
        loaded.bound.deinit();
        gpa.destroy(loaded);
    }

    /// The watches of the proximity conditions, as the mission's tables are made
    /// (`events.Events.watch`); the script's start as binding the mission ends (`vm_clock_start`,
    /// `mission_script_start`), its clock counting the seconds from `game`'s; then what the
    /// mission's start does next with the mission: the ships' records kept where their objects are
    /// (`syncShips`), the script's clock back to 0, the objects' count set to the mission's ships'
    /// (`game_object_count`), so that the ships the script makes later take the first slots, and
    /// the frame's work run once (`process`). The script acts on the game through `game`.
    pub fn start(loaded: *Loaded, game: aigeneric.Context) !void {
        try loaded.events.watch(game.world.objects.players);
        loaded.clock_from = game.clock.game_ticks;
        loaded.script.game = game;
        try loaded.script.start();
        const ships = try loaded.bound.ships();
        syncShips(game.world.objects, ships);
        loaded.script.clock = 0;
        game.world.objects.count = @intCast(@min(ships.len, gameobj.max_objects));
        loaded.process(game);
    }

    /// `events_flush` (`0x0045B840`), once a frame from `mission_frame`, before `process`: the
    /// events waiting are raised on the script's triggers (`events.Events.flush`), which act on the
    /// game through `game`.
    pub fn flush(loaded: *Loaded, game: aigeneric.Context) void {
        loaded.script.game = game;
        loaded.events.flush();
    }

    /// `process_mission` (`0x0045A570`), once a frame from `mission_frame`: the script's threads
    /// run on (`vm.Machine.runThreads`), the mission's ships take their objects' places
    /// (`syncShips`), and once the script's clock has ticked, its timers run and the watches of
    /// the proximity conditions look for ships close by (`events.Events.checkProximity`). The
    /// script acts on the game through `game`.
    ///
    /// Not ported: the script debugger's pause, which holds the threads, the timers and the
    /// watches.
    pub fn process(loaded: *Loaded, game: aigeneric.Context) void {
        const script = &loaded.script;
        script.game = game;
        script.runThreads();
        syncShips(game.world.objects, loaded.bound.ships() catch &.{});
        if (script.ticked and script.timers_running) {
            script.runTimers();
            script.ticked = false;
            loaded.events.checkProximity(game.world);
        }
    }

    /// `vm_clock_tick` (`0x00458910`), the script's clock ticking once a second of the mission
    /// (`vm.Machine.tick`), for each second `game_ticks` has run past it since the clock started.
    ///
    /// **Improvement:** the game ticks it from a timer of its own that the pause stops;
    /// OpenReliant counts the game's ticks, which the pause stops too.
    pub fn tickClock(loaded: *Loaded, game_ticks: u32) void {
        const seconds = (game_ticks -% loaded.clock_from) / ticks_per_second;
        while (loaded.script.clock < seconds) loaded.script.tick();
    }
};

/// `mission_ships_sync` (`0x0045A5F0`): each mission ship's run-time place becomes its object's,
/// and its run-time yaw and pitch the heading of the object's nose (`heading`), in whole degrees:
/// the yaw about Y from 0 to 360, and the pitch about X, reversed where the nose points ahead of a
/// right angle from the Z axis and folded under 180 there. A ship not made yet takes the place of
/// its slot's stand-in. The run-time roll stays as it is.
///
/// **Fix:** the game takes a ship past the last object's slot for an object past its array;
/// OpenReliant stops there.
pub fn syncShips(all: *const create.Objects, ships: []align(1) dte.Ship) void {
    for (ships[0..@min(ships.len, all.slots.len)], all.slots[0..@min(ships.len, all.slots.len)]) |*ship, *slot| {
        const root = &slot.object.root;
        ship.runtime_position = .{ root.position.x, root.position.y, root.position.z };
        const nose = math.forward(root.orientation);
        var yaw = math.ftol(heading(nose[0], nose[2]) - half_turn);
        if (@as(i16, @truncate(yaw)) < 0) yaw += full_turn;
        ship.runtime_yaw = @truncate(yaw);
        ship.runtime_pitch = @truncate(math.ftol(heading(nose[1], nose[2])));
        if (ship.runtime_yaw < right_angle or ship.runtime_yaw > full_turn - right_angle) {
            ship.runtime_pitch = @truncate(math.ftol(half_turn - @as(f32, @floatFromInt(ship.runtime_pitch))));
            if (ship.runtime_pitch > half_turn) ship.runtime_pitch = full_turn - ship.runtime_pitch;
        }
    }
}

/// A half turn, a full turn and a right angle, in degrees (`0x004DC3E4`, `0x004DC3E0`, and the
/// immediates of `mission_ships_sync`).
const half_turn = 180;
const full_turn = 360;
const right_angle = 90;

/// `0x00452500`: the angle in degrees of the direction `(x, y)` from the Y axis round to the X
/// axis, half a turn on, from 0 up to 360. `sr_atan2` gives a half turn as a negative one, its
/// table's angles running from -pi up to pi.
///
/// **Improvement:** the game takes the angle from `sr_atan2`'s table of arctangents and turns it
/// into degrees by a rounded 180/pi (`0x004DC3E8`); OpenReliant computes both, which can round a
/// whole degree the other way.
fn heading(x: f32, y: f32) f32 {
    var angle = std.math.radiansToDegrees(std.math.atan2(x, y));
    if (angle == half_turn) angle = -half_turn;
    const offset: f32 = if (y <= 0) half_turn else -half_turn;
    const turned = if (x >= 0) angle + offset else angle - offset;
    return if (turned < 0) turned + full_turn else turned;
}

/// `mission_wings_build` (`0x0045AC60`): each flight group the mission lists in a wing
/// (`dte.FlightGroup.wing`) has its ships join the wing (`GameObject.wing`), in the mission's
/// order, and a group in the player's wing lists them there (`listPlayerWing`), each group from the
/// first slot.
///
/// **Fix:** the game takes the list of a wing past the third from past its lists, and lists the
/// ships of a group of more than the wing holds past the list's end; OpenReliant passes over the
/// first and lists as many as fit, every ship still joining the wing.
pub fn buildWings(all: *create.Objects, mission: *const Mission) void {
    all.wing = @splat(null);
    for (mission.flightGroups() catch return) |group| {
        const wing: gameobj.Wing = switch (group.wing) {
            0 => .player,
            1 => .second,
            2 => .third,
            else => continue,
        };
        const ships = mission.groupShips(group);
        if (wing == .player) listPlayerWing(all, ships);
        for (ships) |ship| {
            if (ship < all.slots.len) all.slots[ship].object.wing = wing;
        }
    }
}

/// `mission_wings_build`'s listing of a flight group of `ships` in the player's wing: each takes
/// the wing's next slot, from the first, and joins the wing (`GameObject.wing`), and the slot after
/// the last is emptied. A group of more ships than the wing holds lists as many as fit.
///
/// **Fix:** the game empties only the slot after the last, and the slots past it keep the ships of
/// the mission before, which the wing status window shows again where they are in the wing.
/// OpenReliant empties every slot first.
pub fn listPlayerWing(all: *create.Objects, ships: []const u16) void {
    all.wing = @splat(null);
    for (all.wing[0..@min(ships.len, wing_size)], ships[0..@min(ships.len, wing_size)]) |*slot, ship| {
        slot.* = ship;
        all.slots[ship].object.wing = .player;
    }
}

/// `object_orient_by_record` (`0x00452240`)'s turn: a mission ship's yaw about Y, then its pitch
/// about X, then its roll about Z, each in whole degrees.
///
/// **Improvement:** the degrees are turned into radians exactly, where the game multiplies by a
/// rounded pi/180 (`0x004DC71C`).
pub fn recordOrientation(ship: dte.Ship) math.Matrix {
    const turn = yawPitch(@floatFromInt(ship.yaw), @floatFromInt(ship.pitch));
    return math.turned(turn, .z, std.math.degreesToRadians(@as(f32, @floatFromInt(ship.roll))));
}

/// Turned by `yaw` about Y, then by `pitch` about X, in degrees, as `object_orient_by_record` turns
/// a ship and the director's camera turns (`mat3_turn_y`, `mat3_turn_x`).
///
/// **Improvement:** the degrees are turned into radians exactly, where the game multiplies by a
/// rounded pi/180 (`0x004DC71C`).
pub fn yawPitch(yaw: f32, pitch: f32) math.Matrix {
    const turn = math.turned(math.identity, .y, std.math.degreesToRadians(yaw));
    return math.turned(turn, .x, std.math.degreesToRadians(pitch));
}

test "Loaded.tickClock" {
    const gpa = std.testing.allocator;
    const image = try bind.testing.image(gpa, .{});
    var random: libcmt.Rand = .{};
    const loaded = try Loaded.create(gpa, image, &random);
    defer loaded.destroy();
    // The clock counts the whole seconds of the game's ticks since it started.
    loaded.clock_from = 250;
    loaded.tickClock(250 + 2 * ticks_per_second - 1);
    try std.testing.expectEqual(1, loaded.script.clock);
    try std.testing.expect(loaded.script.ticked);
    loaded.tickClock(250 + 3 * ticks_per_second);
    try std.testing.expectEqual(3, loaded.script.clock);
}

test listPlayerWing {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.predator, @splat(0));
    const wingman = try mission.add(.grendel, .{ 1000, 0, 0 });
    const outsider = try mission.add(.sabre, .{ 0, 0, 5000 });

    // The ships listed take the first slots and join the wing; the rest stay out of it.
    all.wing = @splat(outsider);
    listPlayerWing(all, &.{ player, wingman });
    try std.testing.expectEqual(WingSlots{ player, wingman, null, null, null, null }, all.wing);
    try std.testing.expectEqual(.player, all.slots[wingman].object.wing);
    try std.testing.expectEqual(.none, all.slots[outsider].object.wing);

    // More ships than the wing holds list as many as fit.
    listPlayerWing(all, &(.{wingman} ** (wing_size + 1)));
    try std.testing.expectEqual(@as(WingSlots, @splat(wingman)), all.wing);
}

test heading {
    // Half a turn on from the angle round from the Y axis to the X axis.
    try std.testing.expectApproxEqAbs(180, heading(0, 1), 1e-4);
    try std.testing.expectApproxEqAbs(270, heading(1, 0), 1e-4);
    try std.testing.expectApproxEqAbs(90, heading(-1, 0), 1e-4);
    try std.testing.expectApproxEqAbs(225, heading(1, 1), 1e-4);
    // Straight down the Y axis the other way, a half turn taken as `sr_atan2` takes it.
    try std.testing.expectEqual(0, heading(0, -1));
}

test recordOrientation {
    var ship = std.mem.zeroes(dte.Ship);
    // Turned a right angle about Y, the nose points along X.
    ship.yaw = 90;
    const nose = math.forward(recordOrientation(ship));
    try std.testing.expectApproxEqAbs(1, nose[0], 1e-6);
    try std.testing.expectApproxEqAbs(0, nose[2], 1e-6);
    // Pitched after the yaw, it rises about its own X axis.
    ship.yaw = 0;
    ship.pitch = -90;
    try std.testing.expectApproxEqAbs(1, math.forward(recordOrientation(ship))[1], 1e-6);
}

test syncShips {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ahead = try mission.add(.predator, .{ 100, 200, 300 });
    const across = try mission.add(.sabre, @splat(0));
    const slot = &all.slots[across];
    @import("objects.zig").setOrientation(&slot.object, &slot.drawn, math.rotation(.y, std.math.pi / 2.0));
    var ships: [2]dte.Ship = @splat(std.mem.zeroes(dte.Ship));
    syncShips(all, &ships);
    // A ship takes its object's place; a nose along Z heads 0, its pitch 0.
    try std.testing.expectEqual([3]f32{ 100, 200, 300 }, ships[ahead].runtime_position);
    try std.testing.expectEqual(0, ships[ahead].runtime_yaw);
    try std.testing.expectEqual(0, ships[ahead].runtime_pitch);
    // Turned a right angle, it heads 90, where its pitch is taken as it comes.
    try std.testing.expectEqual(90, ships[across].runtime_yaw);
    try std.testing.expectEqual(0, ships[across].runtime_pitch);
}

test {
    std.testing.refAllDecls(@This());
}
