//! A mission file read and bound for play, as a mission's start has `mission_bind_sections`
//! (`0x00451D90`) do it: the file read from the game's `missions` folder or from `resource.hog`
//! (`read`), each of its sections bound (`Mission.bind`), and the tables the rest of the mission
//! reads made from them. [`docs/engine/missions.md`](../../../../docs/engine/missions.md)
//! describes it. **Unverified:** these functions lie between `loadout.cpp`'s code and
//! `Executor.cpp`'s; by what they do they are the mission's.
//!
//! Elsewhere: the script's clock and start (`vm.Machine.start`), the watches of the proximity
//! conditions (`0x0045AE10`), which the mission's events make as it starts
//! (`events.Events.watch`), and the wings (`mission_wings_build`, `mission.buildWings`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const dte = @import("../../../formats/dte.zig");
const files = @import("../../files.zig");
const vm = @import("../../vm.zig");
const bigfile = @import("../bigfile.zig");

const log = std.log.scoped(.mission);

/// How much of a loose mission file the game reads: its buffer's size (`0x00451DA0`).
pub const loose_limit = 0xFA000;

/// Where a mission's file came from.
pub const Source = enum { loose, archive };

pub const File = struct {
    /// The file's bytes as the mission binds them, made in the allocator `read` is given.
    image: []u8,
    source: Source,
};

/// `mission_file_read` (`0x0045A300`): the mission file `path`, a path of the game's under its
/// directory `dir`. The loose file comes first, where there is one (`file_exists`,
/// `0x004AD6E0`), found whatever the case of its names, as Windows finds it, and read as it is,
/// no further than `loose_limit`; then the member of `resources` it names (`hog_load`),
/// expanded where RefPack packed it. Null where there is neither, on which the archive's reader
/// reports the member missing and the mission's start stops the game: "The mission number is
/// invalid". OpenReliant leaves saying so to the caller.
pub fn read(io: Io, gpa: Allocator, dir: Io.Dir, resources: *const bigfile.Hog, path: []const u8) !?File {
    if (try files.readFile(io, gpa, dir, path, .limited(files.max_file_size))) |bytes| {
        if (bytes.len <= loose_limit) return .{ .image = bytes, .source = .loose };
        // The game reads no more than its buffer holds, and binds what it read.
        log.warn("{s} is {d} bytes: the game reads the first {d}", .{ path, bytes.len, loose_limit });
        defer gpa.free(bytes);
        return .{ .image = try gpa.dupe(u8, bytes[0..loose_limit]), .source = .loose };
    }
    if (!resources.has(path)) return null;
    return .{ .image = try resources.readFile(gpa, path), .source = .archive };
}

/// A mission bound for play: its image, from which its records are read and into which the engine
/// writes their run-time fields, as the game writes into its buffer, and the tables binding makes.
pub const Mission = struct {
    gpa: Allocator,
    image: []u8,
    file: dte.Mission,
    /// `mission_format_flags` (`0x00525F9A`, `0x00525FA4`, `0x005267C6`, `0x005294E8`): the four
    /// flags of the directory's entries, each set where any section has it. Nothing reads them.
    formats: dte.DirectoryEntry.Formats,
    /// The flight groups' ships, group after group (`flight_group_ships`, `0x004EF2F8`), each by
    /// its index among the mission's ships. A group's `first_ship` and `ship_count` give its run.
    group_ships: []u16,
    /// The waypoints (`waypoints`, `0x00525710`), grouped by flight group, each group's in the
    /// order the mission lists them. A Patrol Route flies a group's from the entry its target
    /// names (`order_patrol_route_init`).
    waypoints: []Waypoint,
    /// The record each entry of the object table stands for (`object_records`, `0x00538C90`),
    /// by object ID; null where none does.
    records: []?Record,
    /// The part tables (`part_table`, `part_table_b`): section 8's parts, whose code is in the
    /// script, and section 17's, whose code is in `script_b`.
    parts: vm.Parts,
    parts_b: vm.Parts,

    pub const Waypoint = struct {
        /// The waypoint's flight group, by its index.
        group: u8,
        /// The waypoint, by its index among the mission's ships.
        ship: u16,
    };

    /// A record of the mission's that an entry of the object table stands for, by its index in
    /// its section.
    pub const Record = union(enum) {
        ship: u16,
        flight_group: u16,
        squad: u16,
    };

    /// Binds `image`, made in `gpa`, which the mission then owns (`mission_bind_sections`): each
    /// section's records, the ships at their spawn places (`resetShips`), and the tables. A
    /// section that runs past the image fails, where the game would read past its buffer.
    pub fn bind(gpa: Allocator, image: []u8) !Mission {
        errdefer gpa.free(image);
        const file: dte.Mission = try .parse(image);
        var mission: Mission = .{
            .gpa = gpa,
            .image = image,
            .file = file,
            .formats = .{},
            .group_ships = &.{},
            .waypoints = &.{},
            .records = &.{},
            .parts = @splat(.{}),
            .parts_b = @splat(.{}),
        };
        for (file.directory) |entry| mission.formats = mission.formats.noting(entry.formats);
        resetShips(try mission.ships());
        // What `mission_bind_tables` (`0x00453050`) makes of the sections once they are bound.
        mission.parts = try partTable(file, .parts, .script);
        mission.parts_b = try partTable(file, .parts_b, .script_b);
        mission.waypoints = try listWaypoints(gpa, try mission.ships());
        errdefer gpa.free(mission.waypoints);
        mission.group_ships = try listGroupShips(gpa, try mission.flightGroups(), try mission.ships());
        errdefer gpa.free(mission.group_ships);
        mission.records = try resolveObjects(gpa, file);
        return mission;
    }

    pub fn deinit(mission: *Mission) void {
        mission.gpa.free(mission.records);
        mission.gpa.free(mission.group_ships);
        mission.gpa.free(mission.waypoints);
        mission.gpa.free(mission.image);
    }

    /// The mission's ships, as the engine writes them.
    pub fn ships(mission: Mission) dte.Error![]align(1) dte.Ship {
        // The image is the mission's own, and writable.
        return @constCast(try mission.file.ships());
    }

    pub fn flightGroups(mission: Mission) dte.Error![]align(1) dte.FlightGroup {
        return @constCast(try mission.file.flightGroups());
    }

    /// The ships of flight group `group`.
    pub fn groupShips(mission: Mission, group: dte.FlightGroup) []const u16 {
        const first = @min(group.firstShip() orelse return &.{}, mission.group_ships.len);
        return mission.group_ships[first..][0..@min(group.ship_count, mission.group_ships.len - first)];
    }
};

/// `mission_build_part_tables` (`0x00452F50`)'s filling of one part table from the part
/// descriptors of section `descriptors`, each part's block in section `code` (`mission_fill_part`,
/// `0x00452FD0`). **Fix:** the game fills the table from every descriptor, past its 256 entries.
fn partTable(file: dte.Mission, descriptors: dte.Section, code: dte.Section) dte.Error!vm.Parts {
    var table: vm.Parts = @splat(.{});
    const found = try file.records(dte.Part, descriptors);
    const script = file.entry(code);
    const count = @min(found.len, table.len);
    for (table[0..count], found[0..count]) |*entry, part| entry.* = .{
        .block = if (part.isEmpty() or !script.isUsed()) null else @intCast(script.offset + part.start()),
        .argument_count = part.arguments,
    };
    return table;
}

/// `mission_ships_reset` (`0x00452010`): each ship's run-time place and angles set to those it is
/// placed at.
pub fn resetShips(ships: []align(1) dte.Ship) void {
    for (ships) |*ship| {
        ship.runtime_position = ship.position;
        ship.runtime_yaw = ship.yaw;
        ship.runtime_pitch = ship.pitch;
        ship.runtime_roll = ship.roll;
    }
}

/// `mission_list_waypoints` (`0x00452100`): the waypoints in flight groups, a group at a time. It
/// takes the first waypoint not yet listed, then every later one of the same group, marking each
/// listed, until none is left.
fn listWaypoints(gpa: Allocator, ships: []align(1) dte.Ship) Allocator.Error![]Mission.Waypoint {
    for (ships) |*ship| ship.waypoint_listed = 0;
    var listed: std.ArrayList(Mission.Waypoint) = .empty;
    errdefer listed.deinit(gpa);
    while (true) {
        var group: ?u8 = null;
        for (ships, 0..) |*ship, index| {
            if (!ship.isWaypoint() or ship.waypoint_listed != 0) continue;
            const own = ship.flightGroup() orelse continue;
            if (group == null) group = own;
            if (own != group.?) continue;
            ship.waypoint_listed = 1;
            try listed.append(gpa, .{ .group = own, .ship = @intCast(index) });
        }
        if (group == null) break;
    }
    return listed.toOwnedSlice(gpa);
}

/// `mission_list_group_ships` (`0x00452EC0`): each flight group's ships, in the order the mission
/// lists them, and the group's count of them and the first one's place.
fn listGroupShips(gpa: Allocator, groups: []align(1) dte.FlightGroup, ships: []align(1) const dte.Ship) Allocator.Error![]u16 {
    var listed: std.ArrayList(u16) = .empty;
    errdefer listed.deinit(gpa);
    for (groups, 0..) |*group, index| {
        group.ship_count = 0;
        group.first_ship = dte.FlightGroup.no_ship;
        for (ships, 0..) |ship, at| {
            if (ship.flight_group != index) continue;
            if (group.firstShip() == null) group.first_ship = @intCast(listed.items.len);
            try listed.append(gpa, @intCast(at));
            group.ship_count +%= 1;
        }
    }
    return listed.toOwnedSlice(gpa);
}

/// `mission_resolve_objects` (`0x00452DB0`): for each entry of the object table, the record it
/// stands for (`mission_object_record`, `0x00452DF0`): of its kind, the first whose object ID is
/// the entry's.
fn resolveObjects(gpa: Allocator, file: dte.Mission) !([]?Mission.Record) {
    const objects = try file.objects();
    const records = try gpa.alloc(?Mission.Record, objects.len);
    errdefer gpa.free(records);
    for (objects, records, 0..) |object, *record, id| {
        record.* = switch (object.kind) {
            .ship => if (firstWithId(dte.Ship, try file.ships(), id)) |at| .{ .ship = at } else null,
            .flight_group => if (firstWithId(dte.FlightGroup, try file.flightGroups(), id)) |at| .{ .flight_group = at } else null,
            .squad => if (firstWithId(dte.Squad, try file.squads(), id)) |at| .{ .squad = at } else null,
            _ => null,
        };
    }
    return records;
}

/// The index of the first of `records` whose object ID, taken as 16 bits, is `id`.
fn firstWithId(comptime T: type, records: []align(1) const T, id: usize) ?u16 {
    for (records, 0..) |record, at| {
        if (@as(u16, @truncate(record.object_id)) == id) return @intCast(at);
    }
    return null;
}

/// A mission image built by hand, for the tests: a directory whose sections lie one after another,
/// each with the flags `formats`.
pub const testing = struct {
    pub const Sections = struct {
        ships: []const dte.Ship = &.{},
        flight_groups: []const dte.FlightGroup = &.{},
        objects: []const dte.Object = &.{},
        squads: []const dte.Squad = &.{},
        formats: dte.DirectoryEntry.Formats = .all,
    };

    pub fn image(gpa: Allocator, sections: Sections) Allocator.Error![]u8 {
        const header = dte.section_count * @sizeOf(dte.DirectoryEntry);
        const size = header + std.mem.sliceAsBytes(sections.ships).len + std.mem.sliceAsBytes(sections.flight_groups).len +
            std.mem.sliceAsBytes(sections.objects).len + std.mem.sliceAsBytes(sections.squads).len;
        const bytes = try gpa.alloc(u8, size);
        const directory: []align(1) dte.DirectoryEntry = @alignCast(std.mem.bytesAsSlice(dte.DirectoryEntry, bytes[0..header]));
        for (directory) |*entry| entry.* = .{ .count = 0, ._unused = 0, .formats = sections.formats, .offset = dte.DirectoryEntry.unused_offset };
        var at: usize = header;
        inline for (.{ .{ dte.Section.ships, sections.ships }, .{ dte.Section.flight_groups, sections.flight_groups }, .{ dte.Section.objects, sections.objects }, .{ dte.Section.squads, sections.squads } }) |pair| {
            const records = std.mem.sliceAsBytes(pair[1]);
            directory[@intFromEnum(pair[0])] = .{ .count = @intCast(pair[1].len), ._unused = 0, .formats = sections.formats, .offset = @intCast(at) };
            @memcpy(bytes[at..][0..records.len], records);
            at += records.len;
        }
        return bytes;
    }
};

fn testShip(object_id: u32, group: u8, kind: u16) dte.Ship {
    var ship = std.mem.zeroes(dte.Ship);
    ship.object_id = object_id;
    ship.flight_group = group;
    ship.kind = kind;
    return ship;
}

fn testGroup(object_id: u16) dte.FlightGroup {
    var group = std.mem.zeroes(dte.FlightGroup);
    group.object_id = object_id;
    group.wing = dte.FlightGroup.no_wing;
    return group;
}

test "Mission.bind" {
    const gpa = std.testing.allocator;
    const waypoint = dte.Ship.waypoint_kind;
    var placed = testShip(0, 0, 43);
    placed.position = .{ 100, 200, 300 };
    placed.yaw = 90;
    placed.pitch = 10;
    placed.roll = -1;
    const image = try testing.image(gpa, .{
        .ships = &.{
            placed,
            testShip(1, 1, waypoint),
            testShip(2, 2, waypoint),
            testShip(3, 1, waypoint),
            testShip(4, 0, 43),
            testShip(5, dte.Ship.no_flight_group, waypoint),
        },
        .flight_groups = &.{ testGroup(6), testGroup(7), testGroup(8) },
        .objects = &.{
            .{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 },
            .{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 },
            .{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 },
            .{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 },
            .{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 },
            .{ .kind = .ship, .count = 0, .first = 0, ._unknown_04 = 0 },
            .{ .kind = .flight_group, .count = 0, .first = 0, ._unknown_04 = 0 },
            .{ .kind = .flight_group, .count = 0, .first = 0, ._unknown_04 = 0 },
            .{ .kind = .squad, .count = 0, .first = 0, ._unknown_04 = 0 },
            .{ .kind = @enumFromInt(7), .count = 0, .first = 0, ._unknown_04 = 0 },
        },
        .formats = .{ .first = true, .second = true, .third = true },
    });
    var mission: Mission = try .bind(gpa, image);
    defer mission.deinit();

    try std.testing.expectEqual(dte.DirectoryEntry.Formats{ .first = true, .second = true, .third = true }, mission.formats);
    // Each ship stands where it is placed.
    const ships = try mission.ships();
    try std.testing.expectEqual([3]f32{ 100, 200, 300 }, ships[0].runtime_position);
    try std.testing.expectEqual(90, ships[0].runtime_yaw);
    try std.testing.expectEqual(10, ships[0].runtime_pitch);
    try std.testing.expectEqual(-1, ships[0].runtime_roll);

    // The waypoints a group at a time, each group's in order; one in no group is left out.
    try std.testing.expectEqualSlices(Mission.Waypoint, &.{ .{ .group = 1, .ship = 1 }, .{ .group = 1, .ship = 3 }, .{ .group = 2, .ship = 2 } }, mission.waypoints);
    try std.testing.expectEqual(0, ships[5].waypoint_listed);

    // Each group's ships, and their place in the list.
    const groups = try mission.flightGroups();
    try std.testing.expectEqualSlices(u16, &.{ 0, 4 }, mission.groupShips(groups[0]));
    try std.testing.expectEqualSlices(u16, &.{ 1, 3 }, mission.groupShips(groups[1]));
    try std.testing.expectEqual(2, groups[1].first_ship);

    // Each object's record: its ship or group; none for a squad the mission lacks, or an unknown
    // kind.
    try std.testing.expectEqual(Mission.Record{ .ship = 3 }, mission.records[3].?);
    try std.testing.expectEqual(Mission.Record{ .flight_group = 1 }, mission.records[7].?);
    try std.testing.expectEqual(null, mission.records[8]);
    try std.testing.expectEqual(null, mission.records[9]);
}

test read {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try bigfile.testing.write(gpa, io, tmp.dir, bigfile.resource_name, &.{
        .{ .name = "mission1.dte", .data = "archive one" },
        .{ .name = "mission2.dte", .data = "archive two" },
    });
    var resources: bigfile.Hog = try .open(gpa, io, tmp.dir, bigfile.resource_name);
    defer resources.close(gpa);
    try tmp.dir.createDirPath(io, "Missions");
    try tmp.dir.writeFile(io, .{ .sub_path = "Missions/MISSION1.DTE", .data = "loose one" });

    // A loose file stands in for the archive's, whatever its case.
    const one = (try read(io, gpa, tmp.dir, &resources, ".\\missions\\mission1.dte")).?;
    defer gpa.free(one.image);
    try std.testing.expectEqualStrings("loose one", one.image);
    try std.testing.expectEqual(.loose, one.source);
    const two = (try read(io, gpa, tmp.dir, &resources, ".\\missions\\mission2.dte")).?;
    defer gpa.free(two.image);
    try std.testing.expectEqualStrings("archive two", two.image);
    try std.testing.expectEqual(.archive, two.source);
    // A mission in neither is none.
    try std.testing.expectEqual(null, try read(io, gpa, tmp.dir, &resources, ".\\missions\\mission3.dte"));
}
