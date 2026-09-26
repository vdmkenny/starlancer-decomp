//! Mission 0, OpenReliant's own: the sandbox, a standard mission file that the build writes into
//! `mission0.dte` (`write`) and `openreliant` plays where no other mission is chosen. It holds only
//! what the game's own missions hold, laid out as they are, so that the original plays it too.
//!
//! Its scene: the Reliant at the origin, facing along Z, from whose first four tubes the player's
//! ship and three wingmen, a Grendel, a Wolverine and a Reaper, listed in the player's wing, launch.
//! Ahead, a wing of four Sabres facing the Reliant; beyond them the Badanov, the smallest of the
//! Coalition's capital ships, turned across the way; and past the Badanov, outside the action's
//! sphere, a field of twelve rocks, the seven asteroids in turn, placed and turned from a fixed
//! seed.
//!
//! Its script's start part makes the Reliant's flight group, then every other, so that the wing
//! finds the Reliant to launch from as it is made, has an ejected pilot fare each way as likely and
//! the rocks tumble slowly (Random Spin Slow), and plays the launch's music. It starts the wing's
//! launch and waits until the wing is out (`WaitForJumpOrLaunch`), as mission 1 does. Then the
//! Reliant and the Badanov fly on at a tenth of their speed, the Sabres fight the player and each
//! wingman a Sabre, and the mission's music follows the launch's. The Sabres' pilot is record 42 of
//! `pilotstats.bin`, one of its weakest, where the game gives a Sabre the sharp pilot of record 66,
//! so the player's missiles mostly get past their countermeasures.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const openreliant = @import("openreliant");
const dte = openreliant.dte;
const game = openreliant.engine.game;
const Type = game.gameobj.Type;
const Order = game.ai.orders.Order;
const Routine = dte.assemble.Routine;

/// The name OpenReliant keeps in the file (`dte.OpenReliantName`).
pub const name = "Sandbox";

/// The mission's number, which `openreliant` plays by default.
pub const number = 0;

/// The mission's flight groups, in the order of their records.
const Group = enum(u8) {
    alpha,
    reliant,
    badanov,
    sabres,
    rocks,

    /// The name the group's record carries.
    fn label(group: Group) []const u8 {
        return switch (group) {
            .alpha => "(FG)Alpha",
            .reliant => "(FG)Reliant",
            .badanov => "(FG)Badanov",
            .sabres => "(FG)Sabres",
            .rocks => "(FG)Rocks",
        };
    }

    /// The wing the group is listed in: the player's for the player's own.
    fn wing(group: Group) u8 {
        return if (group == .alpha) 0 else dte.FlightGroup.no_wing;
    }
};

/// A ship the mission places: its name, its kind, its flight group, its pilot, where it stands and
/// how it is turned, in whole degrees, and the Reliant's tube it launches through, where it
/// launches.
const Placed = struct {
    name: []const u8,
    kind: Type,
    group: Group,
    pilot: u8 = dte.Ship.no_pilot,
    at: [3]f32,
    yaw: i16 = 0,
    pitch: i16 = 0,
    roll: i16 = 0,
    gate: ?u8 = null,
};

/// The Badanov's heading: across the wing's way.
const across_yaw = 63;
/// The speed the capital ships fly at once the wing is out: a tenth of the 100 the Reliant's type
/// cruises at.
const crawl_speed = 10;

/// The music the launch plays to, and the mission's after it, from the game's music folder.
const launch_music = "new_launch.wav";
const mission_music = "New_Mission01.wav";

/// The Sabres: `wing_size` of them, `wing_ahead` in front of the player and `wing_spacing` apart,
/// turned to face the player, flown by `wing_pilot`.
pub const wing_size = 4;
pub const wing_ahead: f32 = 150000;
pub const wing_spacing: f32 = 3000;
pub const wing_pilot = 42;

/// The field of rocks: `field_rows` rows of `field_columns`, `field_spacing` apart about
/// `field_centre`, each strayed up to `field_stray` along and across and `field_height` up or down
/// from the grid, from the random numbers of `field_seed`. Each rock is the asteroid `field_step` on
/// from the last, so neighbours differ.
const field_centre: [3]f32 = .{ 6000, -9000, 250000 };
const field_rows = 3;
const field_columns = 4;
const field_spacing: f32 = 26000;
const field_stray: f32 = 7000;
const field_height: f32 = 12000;
const field_step = 3;
const field_seed = 0x5A4D;
const field_size = field_rows * field_columns;

/// The ships before the rocks: the player's ship first, whose slot is the player's. The wing is
/// placed at the Reliant, whose tubes the launch puts it in.
const ships = [_]Placed{
    .{ .name = "Player", .kind = .predator, .group = .alpha, .at = @splat(0), .gate = 0 },
    .{ .name = "(A2)Grendel", .kind = .grendel, .group = .alpha, .at = @splat(0), .gate = 1 },
    .{ .name = "(A3)Wolverine", .kind = .wolverine, .group = .alpha, .at = @splat(0), .gate = 2 },
    .{ .name = "(A4)Reaper", .kind = .reaper, .group = .alpha, .at = @splat(0), .gate = 3 },
    .{ .name = "The Reliant", .kind = .reliant, .group = .reliant, .at = @splat(0) },
    .{ .name = "The Badanov", .kind = .badanov, .group = .badanov, .at = .{ 6000, -9000, 190000 }, .yaw = across_yaw },
} ++ sabres;

const sabres = sabres: {
    var placed: [wing_size]Placed = undefined;
    for (&placed, 0..) |*sabre, n| {
        const across = (@as(f32, @floatFromInt(n)) - @as(f32, wing_size - 1) / 2) * wing_spacing;
        sabre.* = .{ .name = std.fmt.comptimePrint("Sabre {d}", .{n + 1}), .kind = .sabre, .group = .sabres, .pilot = wing_pilot, .at = .{ across, 0, wing_ahead }, .yaw = 180 };
    }
    break :sabres placed;
};

/// Where each ship stands in the list, by what it is.
const player = 0;
const wingmen = [_]u16{ 1, 2, 3 };
const first_sabre = 6;
const first_rock = ships.len;

/// The rocks, placed and turned from `field_seed`.
fn rocks() [field_size]Placed {
    var prng: std.Random.DefaultPrng = .init(field_seed);
    const random = prng.random();
    var placed: [field_size]Placed = undefined;
    for (&placed, 0..) |*rock, n| {
        const column: f32 = @floatFromInt(n % field_columns);
        const row: f32 = @floatFromInt(n / field_columns);
        const middle: [2]f32 = .{ @as(f32, field_columns - 1) / 2, @as(f32, field_rows - 1) / 2 };
        rock.* = .{
            .name = rock_names[n],
            .kind = .asteroid(n * field_step),
            .group = .rocks,
            .at = .{
                field_centre[0] + (column - middle[0]) * field_spacing + (random.float(f32) * 2 - 1) * field_stray,
                field_centre[1] + (random.float(f32) * 2 - 1) * field_height,
                field_centre[2] + (row - middle[1]) * field_spacing + (random.float(f32) * 2 - 1) * field_stray,
            },
            .yaw = random.intRangeLessThan(i16, 0, 360),
            .pitch = random.intRangeLessThan(i16, 0, 360),
            .roll = random.intRangeLessThan(i16, 0, 360),
        };
    }
    return placed;
}

const rock_names = names: {
    var all: [field_size][]const u8 = undefined;
    for (&all, 1..) |*rock, n| rock.* = std.fmt.comptimePrint("Rock {d}", .{n});
    break :names all;
};

/// Mission 0's file, made in `gpa`.
pub fn write(gpa: Allocator) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placed = ships ++ rocks();

    var strings: std.ArrayList(u8) = .empty;
    const part_name = try addString(arena, &strings, "(F)Start");

    const records = try arena.alloc(dte.Ship, placed.len);
    for (records, placed, 0..) |*record, ship, index| record.* = shipRecord(ship, @intCast(index), try addString(arena, &strings, ship.name));

    const groups = std.enums.values(Group);
    const group_records = try arena.alloc(dte.FlightGroup, groups.len);
    var listed: u32 = 0;
    for (group_records, groups) |*record, group| {
        var count: u8 = 0;
        for (placed) |ship| {
            if (ship.group == group) count += 1;
        }
        record.* = .{
            .object_id = @intCast(placed.len + @intFromEnum(group)),
            ._unknown_02 = 0,
            .name = try addString(arena, &strings, group.label()),
            ._unknown_06 = 0,
            .wing = group.wing(),
            .ship_count = count,
            ._unknown_0a = 0,
            .first_ship = listed,
            ._unknown_10 = group_tail,
        };
        listed += count;
    }

    // The object table: the ships' IDs, then the flight groups', none with triggers.
    const objects = try arena.alloc(dte.Object, placed.len + groups.len);
    for (objects, 0..) |*object, id| object.* = .{
        .kind = if (id < placed.len) .ship else .flight_group,
        .count = 0,
        .first = no_triggers,
        ._unknown_04 = 0,
    };

    const code = try script(arena);
    var part = std.mem.zeroes(dte.Part);
    part.name = part_name;
    part.offset = 0;
    part.flags.start = true;
    part.length = @intCast(code.len / @sizeOf(u16));

    var sections: dte.write.Sections = @splat(.{});
    const section = struct {
        fn set(all: *dte.write.Sections, which: dte.Section, count: usize, bytes: []const u8) void {
            all[@intFromEnum(which)] = .{ .count = @intCast(count), .bytes = bytes };
        }
    }.set;
    section(&sections, .strings, strings.items.len, strings.items);
    section(&sections, .ships, records.len, std.mem.sliceAsBytes(records));
    section(&sections, .flight_groups, group_records.len, std.mem.sliceAsBytes(group_records));
    section(&sections, .script, code.len / @sizeOf(u16), code);
    section(&sections, .objects, objects.len, std.mem.sliceAsBytes(objects));
    section(&sections, .parts, 1, std.mem.asBytes(&part));
    section(&sections, .script_flags, code.len, try arena.alloc(u8, code.len));
    @memset(@constCast(sections[@intFromEnum(dte.Section.script_flags)].bytes), 0);
    const flags = dte.write.template.command_flags;
    section(&sections, .command_flags, flags.len, std.mem.sliceAsBytes(&flags));
    return dte.write.write(gpa, &sections, .{ .name = name });
}

/// The object table's `first` for an object with no triggers, as the game's missions give it.
const no_triggers = 0xFFFF;

/// A flight group's last word, as every flight group of the game's missions has it.
/// **Unknown:** what it means.
const group_tail = 0xFF19FFFF;

/// The bytes after a ship's pitch (`_unknown_3c`, `tier`, `_unknown_3e`, the marker's curve and its
/// place on it), as most of the ships of the game's missions have them: tier 255, which asks for
/// the campaign's, and no curve.
const ship_tail = [_]u8{ 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00 };

/// Ship `ship`'s record, as the game's missions have their ships': object ID `id`, named at
/// `name_at`, launching through its tube of the first Reliant, or from none, in no formation, every
/// component intact, standing where it is placed.
fn shipRecord(ship: Placed, id: u32, name_at: u16) dte.Ship {
    var record = std.mem.zeroes(dte.Ship);
    record.object_id = id;
    record.name = name_at;
    record.runtime_position = ship.at;
    record.position = ship.at;
    record.flight_group = @intFromEnum(ship.group);
    record.pilot = ship.pilot;
    record.kind = @intCast(ship.kind.number());
    record.launch_from = if (ship.gate != null) @intCast(Type.reliant.number()) else std.math.maxInt(u16);
    record._unknown_2a = 0xFF;
    record.launch_gate = ship.gate orelse dte.Ship.no_launch;
    record.runtime_yaw = ship.yaw;
    record.yaw = ship.yaw;
    record.intact_components = std.math.maxInt(u32);
    record.formation_point = dte.Ship.no_formation_point;
    record._unknown_36 = 0xFFFF;
    record.runtime_pitch = ship.pitch;
    record.pitch = ship.pitch;
    const tail = std.mem.asBytes(&record)[@offsetOf(dte.Ship, "_unknown_3c")..][0..ship_tail.len];
    tail.* = ship_tail;
    record.runtime_roll = ship.roll;
    record.roll = ship.roll;
    return record;
}

/// Adds `text` to the string pool, NUL-terminated, and gives the byte offset it starts at.
fn addString(gpa: Allocator, strings: *std.ArrayList(u8), text: []const u8) !u16 {
    const at: u16 = @intCast(strings.items.len);
    try strings.appendSlice(gpa, text);
    try strings.append(gpa, 0);
    return at;
}

/// The order the start part makes the flight groups in: the Reliant's first, which the wing
/// launches from as it is made.
const made = [_]Group{ .reliant, .alpha, .badanov, .sabres, .rocks };

comptime {
    for (std.enums.values(Group)) |group| std.debug.assert(std.mem.indexOfScalar(Group, &made, group) != null);
}

/// The start part: every flight group made, the ejected pilot's odds each as likely, the rocks
/// tumbling, the launch's music, and the wing's launch. Once the wing is out, the capital ships fly
/// at a crawl, the Sabres fight the player and each wingman a Sabre, and the mission's music plays.
fn script(gpa: Allocator) ![]u8 {
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    for (made) |group| {
        try routine.op(.push_flight_group, &.{@intFromEnum(group)});
        try routine.command("CreateFlightGroup");
    }
    for ([_]u8{ 33, 33, 34 }) |odds| try routine.pushConstant(odds);
    try routine.command("SetRescueProbabilities");
    try setAI(&routine, .{ .group = .rocks }, .random_spin_slow, null);
    try playMusic(&routine, launch_music);
    try routine.op(.push_flight_group, &.{@intFromEnum(Group.alpha)});
    try routine.command("StartLaunch");
    try routine.op(.push_flight_group, &.{@intFromEnum(Group.alpha)});
    try routine.command("WaitForJumpOrLaunch");
    for ([_]Group{ .reliant, .badanov }) |group| {
        try routine.op(.push_flight_group, &.{@intFromEnum(group)});
        try routine.op(.push_null, &.{});
        try routine.pushConstant(crawl_speed);
        try routine.command("Fly");
    }
    try setAI(&routine, .{ .group = .sabres }, .fight, player);
    for (wingmen, 0..) |wingman, n| try setAI(&routine, .{ .ship = wingman }, .fight, first_sabre + n % wing_size);
    try playMusic(&routine, mission_music);
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    return routine.finish();
}

/// `PlayMusic` of the piece `piece`, once the music playing has faded out.
fn playMusic(routine: *Routine, piece: []const u8) !void {
    try routine.pushString(piece);
    try routine.pushConstant(0);
    try routine.command("PlayMusic");
}

/// What a command names: a ship or a flight group.
const Entity = union(enum) {
    ship: u16,
    group: Group,
};

/// `SetAI` of `order` on `entity`, aimed at the ship `target`, or at nothing, starting at once.
fn setAI(routine: *Routine, entity: Entity, order: Order, target: ?usize) !void {
    switch (entity) {
        .ship => |ship| try routine.op(.push_ship, &.{@intCast(ship)}),
        .group => |group| try routine.op(.push_flight_group, &.{@intFromEnum(group)}),
    }
    try routine.pushConstant(@intCast(@intFromEnum(order)));
    try routine.pushConstant(1);
    if (target) |ship| try routine.op(.push_ship, &.{@intCast(ship)}) else try routine.op(.push_null, &.{});
    try routine.command("SetAI");
}

/// Writes mission 0's file to the path its argument gives, for the build.
pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: mission0 <output>\n", .{});
        return 2;
    }
    const bytes = try write(init.gpa);
    defer init.gpa.free(bytes);
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = bytes });
    return 0;
}

test write {
    const gpa = std.testing.allocator;
    const bytes = try write(gpa);
    defer gpa.free(bytes);
    var mission: game.mission.Mission = try .bind(gpa, try gpa.dupe(u8, bytes));
    defer mission.deinit();

    // A standard mission, the template's, which OpenReliant names.
    try std.testing.expectEqual(dte.write.template.size + @sizeOf(dte.OpenReliantName) + name.len + 1, bytes.len);
    try std.testing.expectEqualStrings(name, mission.file.openReliantName().?);
    // The player's own record first, and each ship where it is placed.
    const records = try mission.ships();
    try std.testing.expectEqual(ships.len + field_size, records.len);
    try std.testing.expectEqualStrings("Player", mission.file.name((try mission.file.player()).?.name));
    try std.testing.expectEqual(@as(u16, @intCast(Type.sabre.number())), records[first_sabre].kind);
    try std.testing.expectEqual(wing_pilot, records[first_sabre].pilot);
    // Each flight group lists its ships, the player's in the player's wing.
    const groups = try mission.flightGroups();
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3 }, mission.groupShips(groups[@intFromEnum(Group.alpha)]));
    try std.testing.expectEqual(0, groups[@intFromEnum(Group.alpha)].wing);
    try std.testing.expectEqual(field_size, mission.groupShips(groups[@intFromEnum(Group.rocks)]).len);
    // One part, run at the start, which disassembles whole.
    const parts = try mission.file.parts();
    try std.testing.expectEqual(1, parts.len);
    try std.testing.expect(parts[0].flags.start);
    const disassembly = (try dte.disassemble(gpa, try mission.file.script(), parts[0].start())).?;
    defer gpa.free(disassembly.instructions);
    try std.testing.expect(!disassembly.incomplete);
    // The command flags as the template's missions have them.
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&dte.write.template.command_flags), std.mem.sliceAsBytes(try mission.file.records(u16, .command_flags)));
    // The wing launches through the Reliant's first four tubes; the rest launch from nothing.
    for (records[0..4], 0..) |record, gate| {
        try std.testing.expectEqual(gate, record.launchGate().?);
        try std.testing.expectEqual(Type.reliant.number(), record.launch_from);
    }
    try std.testing.expectEqual(null, records[4].launchGate());
}

test "the wing waits in the Reliant's tubes as the mission starts, its launch started" {
    const gpa = std.testing.allocator;
    var world: game.gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    var orders = world.orders();
    orders.world.spawn = .{ .tables = &world.tables, .types = game.create.testing.no_models };
    const loaded = try game.mission.Loaded.create(gpa, try write(gpa), &world.random);
    defer loaded.destroy();
    orders.world.mission = &loaded.bound;
    try loaded.start(orders);
    const reliant: u16 = 4;
    for (world.objects.slots[0..4]) |*slot| {
        const entry = slot.current().?;
        try std.testing.expectEqual(Order.launch, entry.order);
        try std.testing.expectEqual(reliant, entry.target.slot().?);
        try std.testing.expect(entry.data.launch.go);
    }
    // The capital ships wait with the script for the wing to be out.
    try std.testing.expectEqual(Order.do_nothing, world.objects.slots[reliant].current().?.order);
}

test "the Reliant flies at a crawl" {
    // Its type cruises at 100 (`shipstats.bin`, type 0x0C). Fly holds the throttle at the speed in
    // its data over that, and the flight model settles the nose speed there, so the Reliant makes
    // its 10 a step.
    const cruise = 100;
    var flight = game.gameobj.testing.flight;
    flight.max_speed = cruise;
    var object = game.gameobj.testing.object();
    object.throttle = @as(f32, crawl_speed) / cruise;
    for (0..200) |_| game.motion.Motion.forward.run(&object, .{ .own = &flight }, .chase, .{});
    const velocity = game.gameobj.vector(object.velocity);
    try std.testing.expectApproxEqAbs(crawl_speed, @sqrt(@reduce(.Add, velocity * velocity)), 0.01);
}

test "the rocks lie beyond the action's sphere, apart" {
    const placed = rocks();
    const sphere = game.aigeneric.ActionSphere.default.radius;
    for (placed, 0..) |rock, n| {
        const at: @Vector(3, f32) = rock.at;
        try std.testing.expect(@sqrt(@reduce(.Add, at * at)) > sphere);
        // No two stand closer than the grid's spacing less both strays, across and along.
        for (placed[n + 1 ..]) |other| {
            const off = at - @as(@Vector(3, f32), other.at);
            try std.testing.expect(@max(@abs(off[0]), @abs(off[2])) >= field_spacing - 2 * field_stray);
        }
    }
    // Every one of the seven asteroids is among them.
    var seen = std.StaticBitSet(7).initEmpty();
    for (placed) |rock| seen.set(rock.kind.number() - Type.asteroid(0).number());
    try std.testing.expectEqual(7, seen.count());
}
