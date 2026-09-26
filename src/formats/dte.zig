//! `.DTE` missions: the 44 campaign and multiplayer missions, and everything scripted in them.
//!
//! A mission is a fixed-capacity image. A 27-entry directory at offset zero gives each section a
//! count and an offset, and the offsets are the same in every mission built from the same
//! template, so a section is a reservation that a mission fills as far as it needs.
//!
//! Inside a `.HOG` the image is RefPack compressed; a mission sitting loose in `missions\` is
//! stored expanded. `hog.Archive.read` handles the first case, so this module always sees the
//! expanded form.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const layout = @import("layout.zig");
const refpack = @import("refpack.zig");
const commands = @import("../engine/game/executor/commands.zig");
const conditions = @import("../engine/vm/conditions.zig");
const opcodes = @import("../engine/vm/opcodes.zig");

pub const section_count = 27;

/// Writing mission files and their scripts.
pub const write = @import("dte/write.zig");
pub const assemble = @import("dte/assemble.zig");

/// What each directory slot holds. Sections the loader reads but this module does not interpret
/// keep their index as a name.
pub const Section = enum(u8) {
    /// NUL-terminated names, addressed by byte offset rather than by index.
    strings = 0,
    operands_a = 1,
    /// `u16` name offset and a `u32` value, read and written by script.
    globals = 2,
    /// The ships: every ship, station and nav point the mission places.
    ships = 3,
    /// Flight groups, stride `0x14`. Each starts with its object ID.
    flight_groups = 4,
    triggers = 5,
    /// The script bytecode. Its count is in **halfwords**, so the section is `count * 2` bytes.
    script = 6,
    /// The object table, indexed by object ID: see [`Object`].
    objects = 7,
    /// One [`Part`] per named script routine in `script`, which the loader turns into the table
    /// `call_part` indexes.
    parts = 8,
    unknown_9 = 9,
    /// One flag per bytecode byte, which the interpreter consults for the script debugger.
    script_flags = 10,
    targets = 11,
    /// Squads, stride `0x0C`. Each starts with its object ID, and lists its members in
    /// `squad_members`.
    squads = 12,
    /// Squad membership records, stride `0x0C`: the member's object ID at `+0` and the owning
    /// squad's index at `+4`. A squad's records are consecutive.
    squad_members = 13,
    /// Ship formations, stride 8: each names its first point in `formation_points` at `+4`, which
    /// the formation orders read (`0x00404230`).
    formations = 14,
    /// The points of the formations, stride `0x10` (`order_formation_regroup_init`).
    formation_points = 15,
    sub_objects = 16,
    /// Part descriptors for `script_b`, in the same form as `parts`.
    parts_b = 17,
    /// A second bytecode section, counted in halfwords like `script`. Empty in every shipped
    /// mission.
    script_b = 18,
    unused_19 = 19,
    unused_20 = 20,
    /// **OpenReliant's own:** the mission's name, as `OpenReliantName` keeps it. The game binds
    /// this section into a local variable of its binder and reads nothing of it, and no shipped
    /// mission has one.
    openreliant_name = 21,
    operands_b = 22,
    unknown_23 = 23,
    /// One `u16` of flags per Executor command, which `command` sets its flag by before each call:
    /// with bit 0 clear, `for_each_ship` passes over the players' ships in a flight group or a
    /// squad. In the missions of the writer's template each word has a bit for each of the
    /// command's parameters, save six whose word is 0 (`write.template.command_flags`); the other
    /// missions leave the section empty, which clears the bit for every command.
    command_flags = 24,
    /// The same for the second, empty command catalogue.
    command_flags_b = 25,
    /// A third table of operands, which `0x004529D0` picks among `operands_a` and `operands_b` by a
    /// bank number.
    operands_c = 26,
    _,

    /// The bytes each of the section's records takes, which its directory count counts: bytes for
    /// the string pool, the script flags and OpenReliant's name, halfwords for the scripts. Null
    /// where the record's size is not known, as for section 20, which every shipped mission leaves
    /// empty.
    pub fn stride(section: Section) ?u8 {
        return switch (section) {
            .strings, .script_flags, .openreliant_name => 1,
            .operands_a, .script, .script_b, .operands_b, .operands_c, .unknown_23, .command_flags, .command_flags_b => 2,
            .unknown_9, .targets => 4,
            .formations => 8,
            .objects => @sizeOf(Object),
            .globals, .squads, .squad_members, .unused_19 => 0x0C,
            .formation_points => 0x10,
            .flight_groups => @sizeOf(FlightGroup),
            .parts, .parts_b => @sizeOf(Part),
            .triggers => @sizeOf(Trigger),
            .sub_objects => 0x44,
            .ships => @sizeOf(Ship),
            .unused_20, _ => null,
        };
    }
};

pub const DirectoryEntry = extern struct {
    /// Records in use, not the capacity reserved for them.
    count: u16,
    _unused: u8,
    formats: Formats,
    offset: u32,

    /// Sections the template reserves but this mission does not use.
    pub const unused_offset: u32 = 0xFFFF;

    /// Four flags, in the low bits, which binding the mission notes where any section has them
    /// (`mission_bind_section`); nothing reads them. Every entry of a shipped mission holds the
    /// same: all four in most, the first three in `mission191` and `mission271`, the first two in
    /// `mission801` and the first alone in `mission88`.
    pub const Formats = packed struct(u8) {
        first: bool = false,
        second: bool = false,
        third: bool = false,
        fourth: bool = false,
        /// Kept as the file has them, though no shipped mission sets them.
        _unused: u4 = 0,

        pub const all: Formats = .{ .first = true, .second = true, .third = true, .fourth = true };

        /// These flags, with each that `other` sets set too, as binding notes them section by
        /// section. The bits past the four are left as they are.
        pub fn noting(formats: Formats, other: Formats) Formats {
            return .{
                .first = formats.first or other.first,
                .second = formats.second or other.second,
                .third = formats.third or other.third,
                .fourth = formats.fourth or other.fourth,
                ._unused = formats._unused,
            };
        }

        /// The flags as the file holds them, for a listing.
        pub fn byte(formats: Formats) u8 {
            return @bitCast(formats);
        }
    };

    pub fn isUsed(entry: DirectoryEntry) bool {
        return entry.offset != unused_offset;
    }

    comptime {
        assert(@sizeOf(DirectoryEntry) == 8);
    }
};

/// One placed object: a ship, a capital ship, a station or a nav point.
pub const Ship = extern struct {
    /// The ship's object ID: its index into the object table.
    object_id: u32,
    /// Byte offset into the string pool.
    name: u16,
    _unknown_06: u16,
    /// Mirrored from `position` when the mission loads, then copied from the live object's position
    /// by `mission_ships_sync` (`0x0045A5F0`).
    runtime_position: [3]f32,
    /// Index of the ship's flight group, or `no_flight_group`.
    flight_group: u8,
    /// The record of `pilotstats.bin` that flies the ship (`object_set_pilot`), or `no_pilot`, as
    /// the player's own record, the nav points and the planets have.
    pilot: u8,
    _unknown_16: u8,
    /// The engine's own state: zero in the files, and cleared for every ship when the mission's
    /// script starts.
    flags: Flags,
    /// Role. Ordinary ships stay below `0x100`; nav points and markers use 999 and the `0x3E3` to
    /// `0x3E8` range, so reading this as a byte truncates many of them.
    kind: u16,
    _unknown_1a: u8,
    /// Set for a waypoint once binding the mission has listed it (`mission_list_waypoints`).
    waypoint_listed: u8,
    /// As authored. The loader copies it into `runtime_position`.
    position: [3]f32,
    /// The kind of the ship it launches from, where `launch_gate` names a gate: the first of the
    /// mission's ships of that kind (`mission_ship_create`).
    launch_from: u16,
    _unknown_2a: u8,
    /// The gate of that ship it launches through, which its Launch order takes as its target's
    /// component, or `no_launch`.
    launch_gate: u8,
    runtime_yaw: i16,
    /// Whole degrees. The engine scales it by pi/180, which is what proves the unit.
    yaw: i16,
    /// The ship's components that are still intact, a bit each. Set to all ones when the mission's
    /// script starts; destroying component `n` clears bit `n & 31`.
    intact_components: u32,
    /// The point of section `formation_points` that Formation Regroup flies the ship to
    /// (`order_formation_regroup_init`), or `no_formation_point`.
    formation_point: u16,
    _unknown_36: u16,
    runtime_pitch: i16,
    pitch: i16,
    _unknown_3c: u8,
    /// The loadout tier its missile racks are fitted by (`create_object`), as `create.settledTier`
    /// settles it: 0 or 255, as most records hold, asks for the campaign's.
    tier: u8,
    _unknown_3e: [10]u8,
    runtime_roll: i16,
    roll: i16,

    /// The `flight_group` of a ship in none.
    pub const no_flight_group: u8 = 0xFF;

    /// The `pilot` of a record flown by no pilot of `pilotstats.bin`.
    pub const no_pilot: u8 = 0xFF;

    /// The `launch_gate` of a ship that does not launch.
    pub const no_launch: u8 = 0xFF;

    /// The `formation_point` of a ship in no formation.
    pub const no_formation_point: u16 = 0xFFFF;

    /// The `kind` of a waypoint: a point a flight group's Patrol Route flies through, in the order
    /// the mission lists them.
    pub const waypoint_kind: u16 = 0x3E5;

    /// Its flight group, where it is in one.
    pub fn flightGroup(ship: Ship) ?u8 {
        return if (ship.flight_group == no_flight_group) null else ship.flight_group;
    }

    /// Its pilot, where it has one.
    pub fn pilotRecord(ship: Ship) ?u8 {
        return if (ship.pilot == no_pilot) null else ship.pilot;
    }

    /// The gate it launches through, where it launches.
    pub fn launchGate(ship: Ship) ?u8 {
        return if (ship.launch_gate == no_launch) null else ship.launch_gate;
    }

    /// Whether it is a waypoint (`waypoint_kind`).
    pub fn isWaypoint(ship: Ship) bool {
        return ship.kind == waypoint_kind;
    }

    pub const Flags = packed struct(u8) {
        /// Set when the engine raises the ship's Destroyed event, which it then raises no more.
        destroyed: bool,
        _unknown: u7,
    };

    comptime {
        assert(@offsetOf(Ship, "name") == 0x04);
        assert(@offsetOf(Ship, "pilot") == 0x15);
        assert(@offsetOf(Ship, "kind") == 0x18);
        assert(@offsetOf(Ship, "position") == 0x1C);
        assert(@offsetOf(Ship, "launch_from") == 0x28);
        assert(@offsetOf(Ship, "launch_gate") == 0x2B);
        assert(@offsetOf(Ship, "yaw") == 0x2E);
        assert(@offsetOf(Ship, "formation_point") == 0x34);
        assert(@offsetOf(Ship, "pitch") == 0x3A);
        assert(@offsetOf(Ship, "tier") == 0x3D);
        assert(@offsetOf(Ship, "roll") == 0x4A);
        assert(@sizeOf(Ship) == 0x4C);
    }
};

/// One named script routine.
///
/// The loader expands each of these into a 0x74-byte runtime entry, of which only the block
/// address and the argument count come from here; `call_part` and `spawn_part` index that table by
/// a single byte, so a mission has at most 256 parts. An `offset` of `no_block` leaves the entry
/// empty.
///
/// Parts are contiguous and in address order: each one's `offset + length` is the next one's
/// `offset`, and the last ends at the end of the script section.
pub const Part = extern struct {
    /// Byte offset into the string pool. Missions ship with their authors' own names for these,
    /// such as `(F)Arrival at CONVOY`.
    name: u16,
    _unknown_02: u16,
    _unknown_04: [6]u8,
    /// Start of the part, in **halfwords** from the start of the script section.
    offset: u16,
    flags: Flags,
    /// Arguments the part takes. The caller reserves `4 * arguments + 16` bytes of frame for it.
    arguments: u8,
    _unknown_0e: u16,
    /// Extent of the part, in halfwords: its entry block, then a trailer of zero or more 8-byte
    /// records whose meaning is not yet known.
    length: u16,
    _unknown_12: [7]u8,
    /// Read by the loader and passed to the routine that fills the runtime entry.
    kind: u8,
    _unknown_1a: u16,

    /// An `offset` meaning the part has no block.
    pub const no_block: u16 = 0xFFFF;

    pub const Flags = packed struct(u8) {
        /// Run when the mission starts, before any trigger is armed. Every mission has one such
        /// part (`mission_script_start`, `0x0045CBC0`).
        start: bool,
        _unknown: u7,
    };

    pub fn isEmpty(part: Part) bool {
        return part.offset == no_block;
    }

    /// Byte offset of the part's entry block within the script section.
    pub fn start(part: Part) usize {
        return halfwords(part.offset);
    }

    /// Bytes the part spans.
    pub fn size(part: Part) usize {
        return halfwords(part.length);
    }

    comptime {
        assert(@offsetOf(Part, "name") == 0x00);
        assert(@offsetOf(Part, "offset") == 0x0A);
        assert(@offsetOf(Part, "arguments") == 0x0D);
        assert(@offsetOf(Part, "length") == 0x10);
        assert(@offsetOf(Part, "kind") == 0x19);
        assert(@sizeOf(Part) == 0x1C);
    }
};

/// A block of script, the constants after it, and what runs it.
///
/// The script section is a sequence of these. Each is a block, then the block's constant table: a
/// whole number of 8-byte units, which `push_constant` reads a dword at a time. The table runs to
/// the start of the next routine.
pub const Routine = struct {
    /// Byte offset of the block within the script.
    start: usize,
    /// Bytes of block and constants together.
    extent: usize,
    owner: Owner,

    pub const Owner = union(enum) {
        /// The indices of the triggers that run this block. Only triggers some object's slice
        /// holds are counted, since no other can fire.
        triggers: []const u16,
        /// The index of the part this block is.
        part: u16,
    };

    /// The constant table: the dwords from the block's end to the routine's.
    pub fn constants(routine: Routine, script: []const u8) []align(1) const u32 {
        const block = BlockReader.at(script, routine.start) orelse return &.{};
        const from = routine.start + block.code.len + BlockReader.header_len;
        const to = @min(routine.start + routine.extent, script.len);
        if (from >= to) return &.{};
        const bytes = script[from..to];
        return std.mem.bytesAsSlice(u32, bytes[0 .. bytes.len - bytes.len % 4]);
    }
};

/// A named value the script reads and writes.
pub const Global = extern struct {
    name: u16,
    _unknown_02: u16,
    value: u32,
    _unknown_08: u32,

    comptime {
        assert(@sizeOf(Global) == 0x0C);
    }
};

pub const Objective = extern struct {
    data: [0x14]u8,

    comptime {
        assert(@sizeOf(Objective) == 0x14);
    }
};

/// Runs a block of script when an event it watches happens to its subject.
///
/// A trigger holds no subject. It is reached through the subject object's entry in `objects`,
/// which gives the index of the ship's first trigger and how many follow, so a trigger that no
/// ship lists can never fire. When an event happens to a ship, the engine fires each of that
/// ship's triggers that is armed, whose `condition` and `qualifier` are the event's, and whose
/// operands pass the condition's checks. Firing starts a thread on the block `link` names, unless
/// a thread the trigger started is still running.
pub const Trigger = extern struct {
    condition: Condition,
    repeat: Repeat,
    /// The block to run, as a halfword offset into the script, like a part's start. `0xFFFF` for
    /// none. The blocks fill the script ahead of the first part.
    link: u16,
    _unknown_04: [16]u8,
    /// Set for every trigger when the mission starts. Firing clears it, per `repeat`.
    armed: u8,
    /// The component of the subject the trigger watches, by its index among the subject's
    /// components, or `whole_object`. It must equal the event's: a ShotAt or Destroyed event on a
    /// component, such as a capital ship's turret, carries the component's index, and every other
    /// event `whole_object`.
    qualifier: u8,
    /// Zero runs the new thread at once, inside the event; any other value leaves it to the
    /// scheduler.
    deferred: u8,
    /// Byte arrays rather than wider types: these sit at odd offsets, and an `extern struct` would
    /// pad a `u16` here into the wrong place.
    _unknown_17: [2]u8,
    /// Firings left, for `counted`.
    repeat_counter: u8,
    /// The firings a `counted` trigger has each time the script arms it (`SetTriggerState`), which
    /// `repeat_counter` takes again then (`trigger_set_armed`).
    repeat_count: u8,
    _unknown_1b: u8,
    /// Condition arguments, four bytes each, checked against the event's values: those the
    /// condition marks as checked, and of those, the ones whose low halfword is not `0xFFFF`.
    operands: [5]u32,

    /// The qualifier of an event on the subject itself rather than one of its components.
    pub const whole_object: u8 = 0xFF;

    pub const Repeat = enum(u8) {
        /// Disarms when it fires.
        once = 0,
        /// Never disarms, so it fires every time.
        always = 1,
        /// Disarms when `repeat_counter`, counted down on each firing, reaches zero.
        counted = 2,
        _,

        pub fn format(repeat: Repeat, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return layout.formatTag(Repeat, repeat, writer);
        }
    };

    /// The component its event is on, or null for the subject itself (`whole_object`).
    pub fn component(trigger: Trigger) ?u8 {
        return if (trigger.qualifier == whole_object) null else trigger.qualifier;
    }

    /// The block this trigger runs, as a byte offset into the script.
    pub fn block(trigger: Trigger) ?usize {
        if (trigger.link == Part.no_block) return null;
        return halfwords(trigger.link);
    }

    comptime {
        assert(@offsetOf(Trigger, "condition") == 0x00);
        assert(@offsetOf(Trigger, "link") == 0x02);
        assert(@offsetOf(Trigger, "armed") == 0x14);
        assert(@offsetOf(Trigger, "qualifier") == 0x15);
        assert(@offsetOf(Trigger, "deferred") == 0x16);
        assert(@offsetOf(Trigger, "repeat_counter") == 0x19);
        assert(@offsetOf(Trigger, "operands") == 0x1C);
        assert(@sizeOf(Trigger) == 0x30);
    }
};

/// How a trigger operand names a ship, a flight group or a squad: an index into the section the tag
/// selects. The matcher turns a reference into the address of the record (`FUN_004530A0`), which is
/// how event values name them.
pub const Reference = packed struct(u32) {
    index: u16,
    tag: Tag,
    /// **Unknown.** The matcher ignores it.
    _unknown_24: u8,

    pub const Tag = enum(u8) {
        ship = 0x00,
        flight_group = 0x01,
        squad = 0x16,
        _,
    };

    /// An operand whose low halfword is this is not set, and is not checked.
    pub const unset: u16 = 0xFFFF;

    /// Set in the index of an operand for a ship value, it matches any of the players' ships: in a
    /// game of one, the player's.
    pub const any_ship: u16 = 0x2000;
};

/// A trigger operand, read the way the matcher reads it for a value of the given kinds.
pub const Operand = union(enum) {
    unset,
    /// For a value that is a number: taken as it is.
    number: u32,
    /// For a ship value: any of the players' ships matches.
    any_ship,
    reference: Reference,
    /// A tag the matcher cannot resolve.
    other: u32,

    pub fn read(raw: u32, kinds: commands.Kinds) Operand {
        const reference: Reference = @bitCast(raw);
        if (reference.index == Reference.unset) return .unset;
        if (kinds.number) return .{ .number = raw };
        if (kinds.ship and reference.index & Reference.any_ship != 0) return .any_ship;
        return switch (reference.tag) {
            .ship, .flight_group, .squad => .{ .reference = reference },
            _ => .{ .other = raw },
        };
    }
};

test Operand {
    const Kinds = commands.Kinds;
    const ship: Kinds = @bitCast(@as(u32, 0x400));
    const number: Kinds = @bitCast(@as(u32, 0x80));
    try std.testing.expectEqual(Operand.unset, Operand.read(0xFFFFFFFF, ship));
    try std.testing.expectEqual(Operand{ .number = 50 }, Operand.read(50, number));
    try std.testing.expectEqual(Operand.any_ship, Operand.read(0xFF002000, ship));
    const reference = Operand.read(0x00010004, ship).reference;
    try std.testing.expectEqual(Reference.Tag.flight_group, reference.tag);
    try std.testing.expectEqual(@as(u16, 4), reference.index);
    try std.testing.expectEqual(Operand{ .other = 0x000C0050 }, Operand.read(0x000C0050, @bitCast(@as(u32, 0x1000))));
}

/// One entry of the object table, section `objects`, indexed by object ID.
///
/// Ships, flight groups and squads each carry an object ID at their start, and an event names its
/// subject by one. The entry gives the object's kind and its slice of the trigger list.
pub const Object = extern struct {
    kind: Kind,
    /// Triggers in the object's slice.
    count: u8,
    /// Index of the first trigger in it.
    first: u16,
    _unknown_04: u32,

    pub const Kind = enum(u8) {
        ship = 0,
        flight_group = 1,
        squad = 2,
        _,

        pub fn format(kind: Kind, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return layout.formatTag(Kind, kind, writer);
        }
    };

    /// A set of kinds, a bit for each.
    pub const KindSet = packed struct(u16) {
        ship: bool,
        flight_group: bool,
        squad: bool,
        _unused: u13,

        pub fn has(set: KindSet, kind: Kind) bool {
            return switch (kind) {
                .ship => set.ship,
                .flight_group => set.flight_group,
                .squad => set.squad,
                _ => false,
            };
        }

        comptime {
            for (.{ "ship", "flight_group", "squad" }) |name| {
                assert(@bitOffsetOf(KindSet, name) == @intFromEnum(@field(Kind, name)));
            }
        }
    };

    comptime {
        assert(@sizeOf(Object) == 8);
    }
};

/// **OpenReliant's own:** a mission's name, which OpenReliant keeps in section `openreliant_name`,
/// a section the game binds but never reads. The section's count is its size in bytes: this header,
/// then `length` bytes of the name in UTF-8, then a NUL. A mission is complete without it, and the
/// game plays one with it as it plays any other.
pub const OpenReliantName = extern struct {
    tag: [4]u8 = OpenReliantName.expected_tag,
    version: u16 = OpenReliantName.current_version,
    length: u16,

    /// The tag that marks the section as holding a name of this kind, and the one version so far.
    pub const expected_tag = "ORMN".*;
    pub const current_version: u16 = 1;

    /// The name `section` holds, where it starts with a header of this kind and the name fits;
    /// null for anything else, which OpenReliant leaves alone.
    pub fn read(section: []const u8) ?[]const u8 {
        if (section.len < @sizeOf(OpenReliantName)) return null;
        const header: *align(1) const OpenReliantName = @ptrCast(section[0..@sizeOf(OpenReliantName)]);
        if (!std.mem.eql(u8, &header.tag, &expected_tag) or header.version != current_version) return null;
        const name = section[@sizeOf(OpenReliantName)..];
        if (header.length > name.len) return null;
        return name[0..header.length];
    }

    comptime {
        assert(@sizeOf(OpenReliantName) == 8);
    }
};

/// A flight group: its object ID, the wing it is listed in, and where its ships stand in the list
/// of the groups' ships that binding the mission makes.
pub const FlightGroup = extern struct {
    object_id: u16,
    _unknown_02: u16,
    /// Byte offset into the string pool, such as `(FG)Reliant`.
    name: u16,
    _unknown_06: u16,
    /// The wing the mission lists the group's ships in (`mission_wings_build`): 0 the player's, 1
    /// and 2 two more, or `no_wing`.
    wing: u8,
    /// How many of the mission's ships are in the group, and where the first stands in the list of
    /// the groups' ships, or `no_ship`: both worked out as the mission is bound
    /// (`mission_list_group_ships`, `0x00452EC0`), whatever the file holds.
    ship_count: u8,
    _unknown_0a: u16,
    first_ship: u32,
    _unknown_10: u32,

    pub const no_wing: u8 = 0xFF;
    pub const no_ship: u32 = 0xFFFFFFFF;

    /// Where its ships start in the flight groups' list, where it has any.
    pub fn firstShip(group: FlightGroup) ?u32 {
        return if (group.first_ship == no_ship) null else group.first_ship;
    }

    comptime {
        assert(@offsetOf(FlightGroup, "name") == 0x04);
        assert(@offsetOf(FlightGroup, "wing") == 0x08);
        assert(@offsetOf(FlightGroup, "ship_count") == 0x09);
        assert(@offsetOf(FlightGroup, "first_ship") == 0x0C);
        assert(@sizeOf(FlightGroup) == 0x14);
    }
};

/// A squad. Only its object ID and its first membership record are identified.
pub const Squad = extern struct {
    object_id: u16,
    _unknown_02: [6]u8,
    /// Index of its first record in `squad_members`, or `no_member`.
    first_member: u16,
    _unknown_0a: u16,

    /// The `first_member` of a squad with none.
    pub const no_member: u16 = 0xFFFF;

    /// Its first record in `squad_members`, where it has one.
    pub fn firstMember(squad: Squad) ?u16 {
        return if (squad.first_member == no_member) null else squad.first_member;
    }

    comptime {
        assert(@sizeOf(Squad) == 0x0C);
    }
};

/// One member of a squad, in section `squad_members`. A member can itself be a flight group or a
/// squad, and `in_squad` follows those.
pub const SquadMember = extern struct {
    object_id: u16,
    _unknown_02: u16,
    /// Index of the squad in `squads`. A squad's members are consecutive.
    squad: u16,
    _unknown_06: u16,
    /// The member's component, by its index among the object's components, or
    /// `Trigger.whole_object`: a squad can hold single components of a ship, such as a capital
    /// ship's turrets. An event on a squad member counts for the squad only on the component
    /// named here.
    component: u8,
    _unknown_09: [3]u8,

    comptime {
        assert(@offsetOf(SquadMember, "squad") == 0x04);
        assert(@sizeOf(SquadMember) == 0x0C);
    }
};

/// The 35 conditions, in the order of the engine's descriptor table at `0x4F6698`, named after its
/// `TT_*` constants. The last two are internal and cannot be scripted. What each applies to and
/// what its events carry is in [`engine/vm/conditions.zig`](../engine/vm/conditions.zig), generated
/// from that table.
pub const Condition = enum(u8) {
    shot_at = 0x00,
    destroyed = 0x01,
    launched = 0x02,
    camera_reached = 0x03,
    ship_reached = 0x04,
    proximity_close = 0x05,
    proximity_general = 0x06,
    object_scooped = 0x07,
    player_ready_to_jump = 0x08,
    jumped_in = 0x09,
    flight_group_jumped_in = 0x0A,
    player_ready_to_warp = 0x0B,
    jumped_through_hoop = 0x0C,
    player_wants_backup = 0x0D,
    ripper_grabbed_object = 0x0E,
    ripper_dropped_object = 0x0F,
    cloaked = 0x10,
    decloaked = 0x11,
    targetted = 0x12,
    player_l1_doubletap = 0x13,
    player_l2_doubletap = 0x14,
    player_r1_doubletap = 0x15,
    player_r2_doubletap = 0x16,
    player_l1_l2_r1_r2_pressed = 0x17,
    player_l1_r1_pressed = 0x18,
    game_timer_expired = 0x19,
    tractor_beam_locked = 0x1A,
    tractor_beam_broken = 0x1B,
    inside_object = 0x1C,
    outside_object = 0x1D,
    docked = 0x1E,
    undocked = 0x1F,
    being_chased = 0x20,
    call_reinforcements = 0x21,
    explosion_ship = 0x22,
    _,

    /// Conditions above this are internal to the engine.
    pub const last_scriptable: Condition = .being_chased;

    /// The condition's entry in the engine's catalogue, or null for a value the catalogue lacks.
    pub fn descriptor(condition: Condition) ?conditions.Condition {
        return conditions.find(@intFromEnum(condition));
    }

    comptime {
        const tags = @typeInfo(Condition).@"enum".fields;
        if (tags.len != conditions.table.len) {
            @compileError("dte.Condition does not name every entry of conditions.table");
        }
        for (tags, 0..) |tag, index| {
            if (tag.value != index) @compileError("dte.Condition." ++ tag.name ++ " is out of order");
        }
    }

    pub fn format(condition: Condition, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return layout.formatTag(Condition, condition, writer);
    }
};

/// Script bytecode.
///
/// The interpreter is a plain dispatch loop: fetch one byte, index a 256-entry handler table,
/// advance the instruction pointer by one, call the handler, and repeat until a handler returns
/// zero. A parallel flag array, section `script_flags`, is indexed by the same instruction pointer:
/// with the script debugger attached, the interpreter can stop a thread at a flagged byte and
/// report where it is.
///
/// The handler table holds 86 entries, of which 71 are filled: `0x02` to `0x07` and `0x14` to
/// `0x55`, minus `0x50`. Those 71 are the whole instruction set. Their sizes and shapes are in
/// [`engine/vm/opcodes.zig`](../engine/vm/opcodes.zig), derived from the handlers themselves by
/// `src/tools/tablegen`.
pub const Opcode = enum(u8) {
    // Comparisons pop `b`, then `a`, and push 1 or 0. Values are unsigned.
    equal = 0x02,
    not_equal = 0x03,
    greater = 0x04,
    greater_equal = 0x05,
    less = 0x06,
    less_equal = 0x07,
    /// Whether ship `a` belongs to flight group `b`.
    in_flight_group = 0x14,
    not_in_flight_group = 0x15,

    // Stores pop the value and the target's old value, and write to the target the last `select_`
    // opcode chose.
    assign = 0x16,
    add_assign = 0x17,
    sub_assign = 0x18,
    mul_assign = 0x19,
    div_assign = 0x1A,

    // Arithmetic pops `b`, then `a`, and pushes the result.
    add = 0x1B,
    sub = 0x1C,
    mul = 0x1D,
    div = 0x1E,
    logical_and = 0x1F,
    logical_or = 0x20,

    /// Calls Executor command `n`,
    /// [`engine/game/executor/commands.zig`](../engine/game/executor/commands.zig), with its
    /// arguments popped off the stack. Its result is kept for `push_result`.
    command = 0x21,
    /// Calls part `n` through the part table.
    call_part = 0x22,
    /// Pops a value and branches when it is zero, over a big-endian displacement counted from the
    /// displacement's own position. `0x24` runs the same handler.
    branch_if_zero = 0x23,
    branch_if_zero_alt = 0x24,
    /// Returns from a part: restores the caller's frame, instruction pointer and block end. When
    /// the call depth is already zero the thread is finished instead. `0x25` is the same handler.
    @"return" = 0x43,
    return_alt = 0x25,

    // Pushes.
    /// Array slot `n`'s value.
    push_array = 0x26,
    /// Global `n`'s value.
    push_global = 0x27,
    /// Constant `n` of the running block: the `n`th dword after the block's end.
    push_constant = 0x28,
    /// `push_constant` with a big-endian 16-bit index.
    push_constant_wide = 0x29,
    /// A pointer to the bytes that follow, which it steps over. The operand byte is the length of
    /// the run, itself included, and the bytes are a NUL-terminated string: the name of a speech,
    /// cutscene or movie file, or text. `0x2B` runs the same handler.
    push_string = 0x2A,
    push_string_alt = 0x2B,
    /// A pointer to ship record `n`.
    push_ship = 0x2C,
    /// `push_ship` with a big-endian 16-bit index.
    push_ship_wide = 0x52,
    /// A pointer to ship record `n`, naming its component `c`, the second operand byte: a command
    /// that takes the value acts on that component, such as the turret `DestroySubObject`
    /// destroys or `SetPrimaryTarget` targets. `0x55` runs the same handler.
    push_component = 0x47,
    push_component_alt = 0x55,
    /// A pointer to flight group record `n`.
    push_flight_group = 0x2D,
    /// A pointer to squad record `n`.
    push_squad = 0x44,
    /// A pointer to record `n` of `sub_objects`.
    push_sub_object = 0x49,
    /// A pointer to record `n` of section 19, which no mission uses.
    push_section_19 = 0x54,
    /// The operand byte itself. `0x2E` runs the same handler.
    push_byte = 0x32,
    push_byte_alt = 0x2E,
    /// `n` percent of the value on top of the stack, which stays.
    push_percent = 0x2F,
    /// Value `n` of the running thread: a trigger block's thread holds the event's arguments.
    push_local = 0x30,
    /// Argument `n` of the running part.
    push_argument = 0x31,
    /// `-1`, which the parameters labelled "can be NULL" take for none.
    push_null = 0x48,
    /// The result of the last `command`.
    push_result = 0x4C,
    /// A value the event matcher stored for an object: three operand bytes name the condition,
    /// the value and the object.
    push_event_value = 0x4B,

    // The same operations with a floating-point step. Operands still come off the stack as
    // unsigned integers; the comparisons give the same results as `0x04` to `0x07`.
    greater_f = 0x33,
    greater_equal_f = 0x34,
    less_f = 0x35,
    less_equal_f = 0x36,
    /// Stores to a float target.
    add_assign_f = 0x37,
    sub_assign_f = 0x38,
    mul_assign_f = 0x39,
    div_assign_f = 0x3A,
    /// Computed in floating point and truncated.
    add_f = 0x3B,
    sub_f = 0x3C,
    mul_f = 0x3D,
    div_f = 0x3E,

    // Selecting a store target also pushes its current value.
    select_array = 0x3F,
    select_global = 0x40,
    select_argument = 0x41,

    /// Whether object `a` belongs to squad `b`, following squads within squads.
    in_squad = 0x45,
    not_in_squad = 0x46,

    /// Jumps forward by a **big-endian** 16-bit displacement, as all the script's two-byte operands
    /// are big-endian.
    jump = 0x42,
    /// `call_part` through the second part table, which serves `script_b`.
    call_part_b = 0x4A,
    /// Starts part `n` on a thread of its own and carries on. The part's arguments move from this
    /// thread's stack to the new one's.
    spawn_part = 0x4D,
    /// `spawn_part` through the second part table.
    spawn_part_b = 0x4E,
    /// `command` through the second command table, which is empty.
    command_b = 0x4F,
    /// Branches to one of a table of arms, chosen by a roll below 100 against each arm's
    /// threshold. A count byte, a big-endian default target, then that many four-byte arms.
    random_branch = 0x51,
    nop = 0x53,
    _,

    /// Opcodes the payload's handler table implements.
    pub fn isImplemented(opcode: Opcode) bool {
        return opcodes.find(@intFromEnum(opcode)) != null;
    }

    pub fn format(opcode: Opcode, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return layout.formatTag(Opcode, opcode, writer);
    }
};

/// What an opcode does to the instruction pointer.
pub const Instruction = struct {
    /// Offset of the opcode within whatever the instruction was decoded from.
    address: usize,
    opcode: Opcode,
    /// The operand bytes, including any inline data or arm table.
    operands: []const u8,
    /// Where execution goes next.
    flow: Flow,

    /// Bytes the whole instruction occupies.
    pub fn size(instruction: Instruction) usize {
        return 1 + instruction.operands.len;
    }

    /// Whether execution can continue at the following instruction.
    pub fn fallsThrough(instruction: Instruction) bool {
        return switch (instruction.flow) {
            .next, .inline_data, .call => true,
            .branch => |branch| branch.conditional,
            .random, .@"return" => false,
        };
    }
};

/// Where execution goes after an instruction.
pub const Flow = union(enum) {
    /// To the next instruction.
    next,
    /// To the next instruction, past the inline bytes the instruction carries, a pointer to which
    /// it has pushed.
    inline_data: []const u8,
    /// To `target`, and when `conditional` possibly to the next instruction instead.
    branch: Branch,
    /// To one of several targets, chosen by a roll: `random_branch`.
    random: ArmIterator,
    /// Into a part, coming back to the next instruction when it returns.
    call,
    /// Out of the part, or when nothing called it, out of the thread.
    @"return",

    pub const Branch = struct {
        /// In the same coordinates as the instruction's `address`.
        target: usize,
        conditional: bool,
    };
};

/// Walks a `random_branch`'s targets: its default first, then one per arm.
///
/// Like a branch's, each target is big-endian and relative, but counted from the opcode rather
/// than from the operands: the handler adds it to the instruction pointer and subtracts one.
pub const ArmIterator = struct {
    /// Address of the `random_branch` opcode.
    origin: usize,
    operands: []const u8,
    index: usize = 0,

    /// The operands before the arms: the arm count and the default target.
    pub const Header = extern struct {
        count: u8,
        default: layout.Big(u16),
    };

    /// An arm: a big-endian target, a threshold, and one byte not yet identified.
    pub const Arm = extern struct {
        target: layout.Big(u16),
        threshold: u8,
        _unknown_3: u8,
    };

    comptime {
        assert(@sizeOf(Header) == 3);
        assert(@sizeOf(Arm) == 4);
    }

    pub fn next(iterator: *ArmIterator) ?usize {
        const header = layout.view(Header, iterator.operands) catch return null;
        if (iterator.index > header.count) return null;
        defer iterator.index += 1;
        // The default target first, then each arm's.
        if (iterator.index == 0) return iterator.origin + header.default.get();
        const arms = layout.array(Arm, iterator.operands[@sizeOf(Header)..], header.count) catch return null;
        return iterator.origin + arms[iterator.index - 1].target.get();
    }
};

/// Decodes the instruction at `pos` in `code`, whose addresses it reports as offsets into `code`.
pub fn decodeAt(code: []const u8, pos: usize) ?Instruction {
    const length = instructionSize(code, pos) orelse return null;
    const info = opcodes.find(code[pos]) orelse return null;
    const opcode: Opcode = @enumFromInt(code[pos]);
    const operands = code[pos + 1 ..][0 .. length - 1];

    const flow: Flow = switch (info.form) {
        .sequential => .next,
        .inline_data => .{ .inline_data = operands[1..] },
        // The displacement is big-endian, as the script's two-byte operands all are, unsigned, and
        // counts from its own position rather than from the end of the instruction.
        .branch => .{ .branch = .{
            .target = pos + 1 + (layout.view(layout.Big(u16), operands) catch return null).get(),
            .conditional = info.falls_through,
        } },
        // Every transfer in the table is classified, which the check below enforces.
        .transfer => switch (transferKind(opcode) orelse unreachable) {
            .call => .call,
            .@"return" => .@"return",
            .random => .{ .random = .{ .origin = pos, .operands = operands } },
        },
    };
    return .{ .address = pos, .opcode = opcode, .operands = operands, .flow = flow };
}

/// The name of opcode `byte`, or null when the VM does not implement it.
pub fn opcodeName(byte: u8) ?[]const u8 {
    return std.enums.tagName(Opcode, @enumFromInt(byte));
}

// Every opcode the handler table implements has a name, and every name is one it implements.
comptime {
    @setEvalBranchQuota(20_000);
    for (opcodes.table) |info| {
        if (std.enums.tagName(Opcode, @enumFromInt(info.opcode)) == null) {
            @compileError(std.fmt.comptimePrint("opcode 0x{X:0>2} has no name", .{info.opcode}));
        }
    }
    for (std.meta.fields(Opcode)) |field| {
        if (opcodes.find(field.value) == null) {
            @compileError("no handler for opcode " ++ field.name);
        }
    }
}

/// What a `transfer` opcode does, by name.
///
/// The derived table cannot say this. For a call, the only path it sees that leaves the
/// instruction pointer sequential is the one taken when the part is missing; the return that
/// brings execution back happens in another handler. For `return`, the path that leaves it alone
/// is the one that ends the thread, signalled through the handler's return value, which the
/// analysis does not model.
const TransferKind = enum { call, @"return", random };

fn transferKind(opcode: Opcode) ?TransferKind {
    return switch (opcode) {
        .call_part, .call_part_b => .call,
        .@"return", .return_alt => .@"return",
        .random_branch => .random,
        else => null,
    };
}

comptime {
    for (opcodes.table) |info| {
        if (info.form == .transfer and transferKind(@enumFromInt(info.opcode)) == null) {
            @compileError(std.fmt.comptimePrint("transfer opcode 0x{X:0>2} has no kind", .{info.opcode}));
        }
    }
}

/// How many bytes the instruction at `code[pos]` occupies, or null when it cannot be decoded.
///
/// Most opcodes are a fixed size. Three shapes are not, and each carries its length in its own
/// operands, so the size is still known without tracking any state:
///
/// - `inline_data` (`0x2A`, `0x2B`): one byte holding the total length of the operand run.
/// - `jump_table` (`0x51`): a count, a two-byte default target, then that many four-byte arms.
///   The handler is the only one whose encoding this module reads rather than `tablegen` deriving
///   it, because its length depends on a byte the instruction-pointer analysis cannot follow.
/// - `branch` and `transfer` are fixed sizes; only where execution resumes differs.
pub fn instructionSize(code: []const u8, pos: usize) ?usize {
    if (pos >= code.len) return null;
    const info = opcodes.find(code[pos]) orelse return null;
    const operands = code[pos + 1 ..];
    const length: usize = switch (info.form) {
        .inline_data => blk: {
            if (operands.len < 1) return null;
            // The byte counts itself, so a run of 1 is the byte alone.
            break :blk @max(operands[0], 1);
        },
        else => if (@as(Opcode, @enumFromInt(info.opcode)) == .random_branch) blk: {
            const header = layout.view(ArmIterator.Header, operands) catch return null;
            break :blk @sizeOf(ArmIterator.Header) + @sizeOf(ArmIterator.Arm) * @as(usize, header.count);
        } else info.operands,
    };
    if (pos + 1 + length > code.len) return null;
    return 1 + length;
}

/// A part's instructions, in address order, reached by following control flow from its entry.
///
/// A linear sweep is not enough: three opcodes never fall through, so the bytes after them are
/// reached only by a branch, and sweeping past one decodes whatever happens to sit there.
pub const Disassembly = struct {
    instructions: []const Instruction,
    /// Bytes of the block that nothing reaches. Trailing alignment padding is not counted.
    unreached: usize,
    /// Set when an instruction could not be decoded, which means a reachable byte is not an
    /// opcode this module knows.
    incomplete: bool,
};

/// Disassembles the block at `entry` in `script`, following every branch it can see.
///
/// Addresses are offsets into `script`. Returns null when there is no block at `entry`.
pub fn disassemble(allocator: Allocator, script: []const u8, entry: usize) Allocator.Error!?Disassembly {
    const block = BlockReader.at(script, entry) orelse return null;
    const first = entry + BlockReader.header_len;
    const limit = first + block.code.len;

    const decoded = try allocator.alloc(bool, block.code.len);
    defer allocator.free(decoded);
    @memset(decoded, false);

    var instructions: std.ArrayList(Instruction) = .empty;
    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, first);

    var incomplete = false;
    while (pending.pop()) |start| {
        var pos = start;
        while (pos >= first and pos < limit and !decoded[pos - first]) {
            const instruction = decodeAt(script[0..limit], pos) orelse {
                incomplete = true;
                break;
            };
            decoded[pos - first] = true;
            try instructions.append(allocator, instruction);

            switch (instruction.flow) {
                .branch => |branch| try pending.append(allocator, branch.target),
                .random => |arms| {
                    var iterator = arms;
                    while (iterator.next()) |target| try pending.append(allocator, target);
                },
                .next, .inline_data, .call, .@"return" => {},
            }
            if (!instruction.fallsThrough()) break;
            pos += instruction.size();
        }
    }

    std.mem.sort(Instruction, instructions.items, {}, struct {
        fn lessThan(_: void, a: Instruction, b: Instruction) bool {
            return a.address < b.address;
        }
    }.lessThan);

    var covered: usize = 0;
    for (instructions.items) |instruction| covered += instruction.size();

    // Up to three bytes at the end of the block are alignment padding rather than a hole, but
    // only when everything before them was reached.
    var unreached = (limit - first) - covered;
    if (unreached < BlockReader.alignment) unreached = 0;

    return .{
        .instructions = try instructions.toOwnedSlice(allocator),
        .unreached = unreached,
        .incomplete = incomplete,
    };
}

/// Decodes one block of bytecode.
///
/// A block begins with a `u16` length that **counts its own two bytes**: the engine starts a
/// thread with its instruction pointer at `block + 2` and its limit at `block + length`, so the
/// instructions occupy `length - 2` bytes. The last of those is a `return`, followed by up to
/// three bytes of padding that bring the block to a four-byte boundary. Decoding therefore runs to
/// the limit rather than stopping at the first `return`, which may be an early exit from a branch,
/// and treats only a short run after a `return` as padding.
///
/// Blocks are entered by address, from a part table a `call_part` reaches, so a section cannot
/// simply be walked from its start.
pub const BlockReader = struct {
    code: []const u8,
    pos: usize = 0,
    /// Set once a `return` has been decoded, after which a short tail is padding.
    returned: bool = false,
    /// The length the block's header declares. A handful of missions declare more than their
    /// script section holds, so `code` is clamped to the section and this records the claim.
    declared: u16 = 0,

    /// Blocks are padded out to this many bytes.
    pub const alignment = 4;

    /// Bytes of a block header, which its length field includes.
    pub const header_len = 2;

    /// Reads the block at `offset` in `section`, returning a reader over its instructions.
    pub fn at(section: []const u8, offset: usize) ?BlockReader {
        if (offset > section.len) return null;
        const declared = (layout.view(u16, section[offset..]) catch return null).*;
        if (declared <= header_len) return null;
        const body = section[offset + header_len ..];
        return .{
            .code = body[0..@min(declared - header_len, body.len)],
            .declared = declared,
        };
    }

    /// Whether the block runs past the end of its section.
    pub fn isShort(reader: BlockReader) bool {
        return reader.code.len + header_len < reader.declared;
    }

    /// Why decoding stopped, once `next` has returned null.
    pub const Stop = enum {
        /// The block's instructions were decoded in full.
        complete,
        /// A byte the handler table leaves unimplemented.
        unimplemented,
        /// An instruction runs past the block's end.
        truncated,
    };

    /// The bytes from the cursor to the end of the block.
    pub fn rest(reader: BlockReader) []const u8 {
        return reader.code[reader.pos..];
    }

    /// The block's trailing padding, once decoding has reached it. Empty until then, and empty
    /// once the block is exhausted.
    pub fn padding(reader: BlockReader) []const u8 {
        const left = reader.rest();
        const is_padding = reader.returned and left.len != 0 and left.len < alignment;
        return if (is_padding) left else &.{};
    }

    pub fn next(reader: *BlockReader) ?Instruction {
        const left = reader.rest();
        if (left.len == 0 or reader.padding().len != 0) return null;

        const instruction = decodeAt(reader.code, reader.pos) orelse return null;
        reader.pos += instruction.size();
        if (instruction.opcode == .@"return") reader.returned = true;
        return instruction;
    }

    pub fn stop(reader: BlockReader) Stop {
        const left = reader.rest();
        if (left.len == 0 or reader.padding().len != 0) return .complete;
        return if (opcodes.find(left[0]) == null) .unimplemented else .truncated;
    }
};

pub const Error = error{
    /// Too small to hold a directory.
    NotAMission,
    /// A section runs past the end of the image.
    Truncated,
    /// Still RefPack compressed. Read it through a `.HOG` archive, which expands it.
    Compressed,
};

/// The bytes of `count` halfwords, as the script's offsets and lengths count them.
fn halfwords(count: u16) usize {
    return @as(usize, count) * @sizeOf(u16);
}

pub const Mission = struct {
    image: []const u8,
    directory: []align(1) const DirectoryEntry,

    pub fn parse(image: []const u8) Error!Mission {
        if (refpack.gameExpands(image)) return error.Compressed;
        const directory = layout.array(DirectoryEntry, image, section_count) catch return error.NotAMission;
        return .{ .image = image, .directory = directory };
    }

    pub fn entry(mission: Mission, section: Section) DirectoryEntry {
        const index = @intFromEnum(section);
        return if (index < mission.directory.len) mission.directory[index] else .{
            .count = 0,
            ._unused = 0,
            .formats = .{},
            .offset = DirectoryEntry.unused_offset,
        };
    }

    /// The records of a fixed-stride section, as `T`.
    pub fn records(mission: Mission, comptime T: type, section: Section) Error![]align(1) const T {
        const slot = mission.entry(section);
        if (!slot.isUsed() or slot.count == 0) return &.{};
        if (slot.offset > mission.image.len) return error.Truncated;
        return layout.array(T, mission.image[slot.offset..], slot.count);
    }

    /// The script bytecode, which the directory counts in halfwords.
    pub fn script(mission: Mission) Error![]const u8 {
        return std.mem.sliceAsBytes(try mission.records(u16, .script));
    }

    /// The mission's name as OpenReliant keeps it in section `openreliant_name`; null for a mission
    /// without one, or one whose section holds anything else.
    pub fn openReliantName(mission: Mission) ?[]const u8 {
        const slot = mission.entry(.openreliant_name);
        if (!slot.isUsed() or slot.offset > mission.image.len) return null;
        const bytes = mission.image[slot.offset..];
        return OpenReliantName.read(bytes[0..@min(slot.count, bytes.len)]);
    }

    /// The script's named routines, in the order the loader installs them.
    pub fn parts(mission: Mission) Error![]align(1) const Part {
        return mission.records(Part, .parts);
    }

    pub fn ships(mission: Mission) Error![]align(1) const Ship {
        return mission.records(Ship, .ships);
    }

    /// The player's own record: the first, since in a single-player game the player's ship is the
    /// first object (`player_index`), and the mission's ships take the objects' places in turn
    /// (`mission_ship_create`). Null for a mission with no ships.
    pub fn player(mission: Mission) Error!?Ship {
        const all = try mission.ships();
        return if (all.len > 0) all[0] else null;
    }

    pub fn triggers(mission: Mission) Error![]align(1) const Trigger {
        return mission.records(Trigger, .triggers);
    }

    /// The object table, indexed by object ID.
    pub fn objects(mission: Mission) Error![]align(1) const Object {
        return mission.records(Object, .objects);
    }

    pub fn flightGroups(mission: Mission) Error![]align(1) const FlightGroup {
        return mission.records(FlightGroup, .flight_groups);
    }

    pub fn squads(mission: Mission) Error![]align(1) const Squad {
        return mission.records(Squad, .squads);
    }

    /// For each trigger, the ID of the object whose slice holds it, or null when none does and
    /// the trigger can never fire. No shipped trigger is in two slices; for one that is, the first
    /// object's, as the engine finds it (`0x00453530`).
    pub fn triggerObjects(mission: Mission, allocator: Allocator) (Error || Allocator.Error)![]?u16 {
        const all = try mission.triggers();
        const owners = try allocator.alloc(?u16, all.len);
        @memset(owners, null);
        for (try mission.objects(), 0..) |object, id| {
            const first: usize = object.first;
            const end = @min(first + object.count, all.len);
            if (first >= end) continue;
            for (owners[first..end]) |*owner| {
                if (owner.* == null) owner.* = @intCast(id);
            }
        }
        return owners;
    }

    /// The script section as routines in address order: first the blocks that triggers run, then
    /// the parts. Together, with their constants, they cover the whole section.
    pub fn routines(mission: Mission, allocator: Allocator) (Error || Allocator.Error)![]Routine {
        const code = try mission.script();
        const all_triggers = try mission.triggers();
        const owners = try mission.triggerObjects(allocator);
        defer allocator.free(owners);

        var result: std.ArrayList(Routine) = .empty;
        errdefer result.deinit(allocator);

        var first_part: usize = code.len;
        for (try mission.parts(), 0..) |part, index| {
            if (part.isEmpty()) continue;
            first_part = @min(first_part, part.start());
            try result.append(allocator, .{
                .start = part.start(),
                .extent = part.size(),
                .owner = .{ .part = @intCast(index) },
            });
        }

        // Group the triggers that can fire by the block they run. Blocks shared by several
        // triggers are common.
        var by_block: std.AutoArrayHashMapUnmanaged(usize, std.ArrayList(u16)) = .empty;
        defer {
            for (by_block.values()) |*list| list.deinit(allocator);
            by_block.deinit(allocator);
        }
        for (all_triggers, owners, 0..) |trigger, owner, index| {
            if (owner == null) continue;
            const start = trigger.block() orelse continue;
            if (start >= first_part) continue;
            const slot = try by_block.getOrPut(allocator, start);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(allocator, @intCast(index));
        }
        const starts = try allocator.dupe(usize, by_block.keys());
        defer allocator.free(starts);
        std.mem.sort(usize, starts, {}, std.sort.asc(usize));
        for (starts, 0..) |start, i| {
            // A trigger block's constants run up to the next block.
            const next = if (i + 1 < starts.len) starts[i + 1] else first_part;
            const list = by_block.getPtr(start).?;
            try result.append(allocator, .{
                .start = start,
                .extent = next - start,
                .owner = .{ .triggers = try list.toOwnedSlice(allocator) },
            });
        }

        std.mem.sort(Routine, result.items, {}, struct {
            fn lessThan(_: void, a: Routine, b: Routine) bool {
                return a.start < b.start;
            }
        }.lessThan);
        return result.toOwnedSlice(allocator);
    }

    pub fn globals(mission: Mission) Error![]align(1) const Global {
        return mission.records(Global, .globals);
    }

    /// Resolves a name. Offsets are relative to the start of the string pool, not to the file, and
    /// the pool is a run of NUL-terminated strings rather than an indexed table.
    pub fn name(mission: Mission, offset: u16) []const u8 {
        const pool = mission.entry(.strings);
        if (!pool.isUsed()) return "";
        const start = pool.offset + offset;
        if (start >= mission.image.len) return "";
        const rest = mission.image[start..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return "";
        return rest[0..end];
    }

    /// Where the string pool ends, which is where the next used section begins.
    pub fn stringPoolEnd(mission: Mission) usize {
        const pool = mission.entry(.strings);
        if (!pool.isUsed()) return 0;
        var end = mission.image.len;
        for (mission.directory) |slot| {
            if (slot.isUsed() and slot.offset > pool.offset and slot.offset < end) end = slot.offset;
        }
        return end;
    }
};

test "directory and records line up" {
    // A mission image with a string pool and one ship.
    var image: [0x400]u8 = @splat(0);
    const directory: []align(1) DirectoryEntry =
        @alignCast(std.mem.bytesAsSlice(DirectoryEntry, image[0 .. section_count * 8]));
    for (directory) |*slot| slot.* = .{
        .count = 0,
        ._unused = 0,
        .formats = .{},
        .offset = DirectoryEntry.unused_offset,
    };

    const pool_at = 0x100;
    directory[@intFromEnum(Section.strings)] = .{
        .count = 2,
        ._unused = 0,
        .formats = .all,
        .offset = pool_at,
    };
    @memcpy(image[pool_at..][0..12], "Player_Ship\x00");

    const ships_at = 0x200;
    directory[@intFromEnum(Section.ships)] = .{
        .count = 1,
        ._unused = 0,
        .formats = .all,
        .offset = ships_at,
    };
    const ship: *align(1) Ship = @ptrCast(image[ships_at..][0..@sizeOf(Ship)]);
    ship.* = std.mem.zeroes(Ship);
    ship.object_id = 3;
    ship.name = 0;
    ship.pilot = Ship.no_pilot;
    ship.kind = 999;
    ship.yaw = 90;
    ship.roll = -1;

    const mission: Mission = try .parse(&image);
    const list = try mission.ships();
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("Player_Ship", mission.name(list[0].name));
    try std.testing.expectEqual(@as(u16, 999), list[0].kind);
    try std.testing.expectEqual(@as(i16, 90), list[0].yaw);

    // The player's own record is the first.
    try std.testing.expectEqual(@as(u32, 3), (try mission.player()).?.object_id);
    // Without OpenReliant's section, the mission has no name of OpenReliant's.
    try std.testing.expectEqual(null, mission.openReliantName());
    const name_at = 0x300;
    directory[@intFromEnum(Section.openreliant_name)] = .{ .count = 8 + 12, ._unused = 0, .formats = .all, .offset = name_at };
    @as(*align(1) OpenReliantName, @ptrCast(image[name_at..][0..8])).* = .{ .length = 11 };
    @memcpy(image[name_at + 8 ..][0..12], "The Sandbox\x00");
    try std.testing.expectEqualStrings("The Sandbox", (try Mission.parse(&image)).openReliantName().?);

    // An unused section yields nothing rather than reading stray bytes.
    try std.testing.expectEqual(@as(usize, 0), (try mission.triggers()).len);
}

test OpenReliantName {
    var section: [@sizeOf(OpenReliantName) + 8]u8 = undefined;
    @as(*align(1) OpenReliantName, @ptrCast(section[0..8])).* = .{ .length = 7 };
    @memcpy(section[8..], "Sandbox\x00");
    try std.testing.expectEqualStrings("Sandbox", OpenReliantName.read(&section).?);
    // Too short for its name, of another tag or of a later version, it is left alone.
    try std.testing.expectEqual(null, OpenReliantName.read(section[0..10]));
    section[0] = 'X';
    try std.testing.expectEqual(null, OpenReliantName.read(&section));
    section[0] = 'O';
    section[4] = 2;
    try std.testing.expectEqual(null, OpenReliantName.read(&section));
}

test "rejects a compressed or truncated image" {
    try std.testing.expectError(error.Compressed, Mission.parse(&.{ 0x10, 0xFB, 0, 0, 0 }));
    try std.testing.expectError(error.NotAMission, Mission.parse(&.{ 0, 1, 2 }));
}

test "condition names cover the scriptable range" {
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(Condition.last_scriptable));
    try std.testing.expectEqual(Condition.proximity_close, @as(Condition, @enumFromInt(5)));
    // The two internal conditions are named; past them the enum stays open.
    try std.testing.expectEqual(Condition.explosion_ship, @as(Condition, @enumFromInt(0x22)));
    const internal: Condition = @enumFromInt(0x23);
    try std.testing.expect(std.enums.tagName(Condition, internal) == null);
}

test "decodes a block down to its alignment padding" {
    // The opening block of mission1: call, command, read a global, push a constant, compare,
    // branch, call, jump, call, command, push a byte, return, then two bytes that pad the block to
    // a multiple of four.
    const section = [_]u8{
        0x1C, 0x00, 0x22, 0x01, 0x21, 0x17, 0x27, 0x00, 0x28, 0x00, 0x02, 0x24, 0x00, 0x07,
        0x22, 0x15, 0x42, 0x00, 0x04, 0x22, 0x18, 0x21, 0x17, 0x32, 0x01, 0x43, 0x32, 0x01,
    };
    var reader = BlockReader.at(&section, 0).?;
    try std.testing.expectEqual(@as(u16, 0x1C), reader.declared);
    try std.testing.expect(!reader.isShort());
    try std.testing.expectEqual(@as(usize, 26), reader.code.len);

    const expected = [_]Opcode{
        .call_part, .command, .push_global, .push_constant, .equal,     .branch_if_zero_alt,
        .call_part, .jump,    .call_part,   .command,       .push_byte, .@"return",
    };
    for (expected) |opcode| {
        try std.testing.expectEqual(opcode, reader.next().?.opcode);
    }
    try std.testing.expectEqual(@as(?Instruction, null), reader.next());
    try std.testing.expectEqual(BlockReader.Stop.complete, reader.stop());
    try std.testing.expectEqual(@as(usize, 24), reader.pos);
    try std.testing.expectEqualSlices(u8, &.{ 0x32, 0x01 }, reader.padding());
}

test "decodes an inline string and steps over it" {
    // The opening block of mission81, which cues a speech file by name.
    const section = [_]u8{
        0x58, 0x00, 0x28, 0x00, 0x21, 0x05, 0x2A, 0x0F,
    } ++ "new_sim02.wav\x00".* ++ [_]u8{ 0x28, 0x01 };
    var reader = BlockReader.at(&section, 0).?;
    // The block claims more than the section holds, so it is clamped rather than rejected.
    try std.testing.expect(reader.isShort());

    try std.testing.expectEqual(Opcode.push_constant, reader.next().?.opcode);
    try std.testing.expectEqual(Opcode.command, reader.next().?.opcode);

    const speech = reader.next().?;
    try std.testing.expectEqual(Opcode.push_string, speech.opcode);
    try std.testing.expectEqualStrings("new_sim02.wav\x00", speech.flow.inline_data);
    try std.testing.expectEqual(Opcode.push_constant, reader.next().?.opcode);
}

test "the records' none values" {
    var ship = std.mem.zeroes(Ship);
    ship.flight_group = Ship.no_flight_group;
    ship.kind = Ship.waypoint_kind;
    ship.pilot = Ship.no_pilot;
    ship.launch_gate = Ship.no_launch;
    try std.testing.expectEqual(null, ship.flightGroup());
    try std.testing.expect(ship.isWaypoint());
    try std.testing.expectEqual(null, ship.pilotRecord());
    try std.testing.expectEqual(null, ship.launchGate());
    ship.flight_group = 3;
    ship.pilot = 42;
    ship.launch_gate = 2;
    try std.testing.expectEqual(3, ship.flightGroup());
    try std.testing.expectEqual(42, ship.pilotRecord());
    try std.testing.expectEqual(2, ship.launchGate());

    var group = std.mem.zeroes(FlightGroup);
    group.first_ship = FlightGroup.no_ship;
    try std.testing.expectEqual(null, group.firstShip());
    group.first_ship = 4;
    try std.testing.expectEqual(4, group.firstShip());

    var squad = std.mem.zeroes(Squad);
    squad.first_member = Squad.no_member;
    try std.testing.expectEqual(null, squad.firstMember());

    var trigger = std.mem.zeroes(Trigger);
    trigger.qualifier = Trigger.whole_object;
    try std.testing.expectEqual(null, trigger.component());
    trigger.qualifier = 2;
    try std.testing.expectEqual(2, trigger.component());
}

test "DirectoryEntry.Formats" {
    const first: DirectoryEntry.Formats = .{ .first = true, ._unused = 5 };
    const noted = first.noting(.{ .third = true, ._unused = 0xF });
    // The four flags gather; the bits past them stay as they were.
    try std.testing.expectEqual(DirectoryEntry.Formats{ .first = true, .third = true, ._unused = 5 }, noted);
    try std.testing.expectEqual(0x0F, DirectoryEntry.Formats.all.byte());
}

test "the implemented opcode range matches the payload's handler table" {
    try std.testing.expect(Opcode.equal.isImplemented());
    try std.testing.expect(Opcode.spawn_part.isImplemented());
    try std.testing.expect(@as(Opcode, @enumFromInt(0x55)).isImplemented());
    // Null entries in the table: no handler, so the opcode does not exist.
    try std.testing.expect(!@as(Opcode, @enumFromInt(0x00)).isImplemented());
    try std.testing.expect(!@as(Opcode, @enumFromInt(0x10)).isImplemented());
    try std.testing.expect(!@as(Opcode, @enumFromInt(0x56)).isImplemented());
    // Between the second command table and the random branch, the table holds no handler.
    try std.testing.expect(!@as(Opcode, @enumFromInt(0x50)).isImplemented());
}

test "an unnamed value formats as a number instead of panicking" {
    var buffer: [32]u8 = undefined;

    var named: std.Io.Writer = .fixed(&buffer);
    try named.print("{f}", .{Condition.destroyed});
    try std.testing.expectEqualStrings("destroyed", named.buffered());

    // `{t}` would panic here; this path is generated per tag at comptime and cannot.
    var unnamed: std.Io.Writer = .fixed(&buffer);
    try unnamed.print("{f}", .{@as(Condition, @enumFromInt(0x23))});
    try std.testing.expectEqualStrings("35", unnamed.buffered());

    var repeat: std.Io.Writer = .fixed(&buffer);
    try repeat.print("{f}", .{@as(Trigger.Repeat, @enumFromInt(3))});
    try std.testing.expectEqualStrings("3", repeat.buffered());
}

test "follows a branch rather than sweeping past a jump" {
    // The opening block of mission1, as a section with its length prefix. The `jump` at 14 never
    // falls through, so 17 is reached only by the `branch_if_zero_alt` at 9.
    const section = [_]u8{
        0x1C, 0x00, 0x22, 0x01, 0x21, 0x17, 0x27, 0x00, 0x28, 0x00, 0x02, 0x24, 0x00, 0x07,
        0x22, 0x15, 0x42, 0x00, 0x04, 0x22, 0x18, 0x21, 0x17, 0x32, 0x01, 0x43, 0x32, 0x01,
    };
    const listing = (try disassemble(std.testing.allocator, &section, 0)).?;
    defer std.testing.allocator.free(listing.instructions);

    try std.testing.expect(!listing.incomplete);
    try std.testing.expectEqual(@as(usize, 0), listing.unreached);

    // Addresses are offsets into the section, so the header shifts them by two.
    const expected = [_]struct { usize, Opcode }{
        .{ 2, .call_part },     .{ 4, .command },    .{ 6, .push_global },
        .{ 8, .push_constant }, .{ 10, .equal },     .{ 11, .branch_if_zero_alt },
        .{ 14, .call_part },    .{ 16, .jump },      .{ 19, .call_part },
        .{ 21, .command },      .{ 23, .push_byte }, .{ 25, .@"return" },
    };
    try std.testing.expectEqual(expected.len, listing.instructions.len);
    for (expected, listing.instructions) |want, got| {
        try std.testing.expectEqual(want[0], got.address);
        try std.testing.expectEqual(want[1], got.opcode);
    }
    // The branch and the jump agree on where the two arms are, and only the jump is unconditional.
    const branch = listing.instructions[5].flow.branch;
    try std.testing.expectEqual(@as(usize, 19), branch.target);
    try std.testing.expect(branch.conditional);
    const jump = listing.instructions[7].flow.branch;
    try std.testing.expectEqual(@as(usize, 21), jump.target);
    try std.testing.expect(!jump.conditional);
    try std.testing.expect(!listing.instructions[11].fallsThrough());
}

test "reads a weighted branch's arms" {
    // The one shape whose encoding is read by hand: a count, a default target, then that many
    // four-byte arms of target and threshold. This one is the 50/50 split in mission18.
    const code = [_]u8{ 0x51, 0x02, 0x00, 0x43, 0x00, 0x2C, 0x32, 0x00, 0x00, 0x39, 0x64, 0x00 };
    const instruction = decodeAt(&code, 0).?;
    try std.testing.expectEqual(Opcode.random_branch, instruction.opcode);
    try std.testing.expectEqual(@as(usize, code.len), instruction.size());
    try std.testing.expect(!instruction.fallsThrough());

    var iterator = instruction.flow.random;
    try std.testing.expectEqual(@as(?usize, 0x43), iterator.next());
    try std.testing.expectEqual(@as(?usize, 0x2C), iterator.next());
    try std.testing.expectEqual(@as(?usize, 0x39), iterator.next());
    try std.testing.expectEqual(@as(?usize, null), iterator.next());
}

test "a part's offset and length are in halfwords" {
    var part = std.mem.zeroes(Part);
    part.offset = 870;
    part.length = 96;
    part.arguments = 2;
    try std.testing.expectEqual(@as(usize, 1740), part.start());
    try std.testing.expectEqual(@as(usize, 192), part.size());
    try std.testing.expect(!part.isEmpty());

    part.offset = Part.no_block;
    try std.testing.expect(part.isEmpty());
}

test "maps the script into trigger blocks and parts, with their constants" {
    var image: [0x300]u8 = @splat(0);
    const directory: []align(1) DirectoryEntry =
        @alignCast(std.mem.bytesAsSlice(DirectoryEntry, image[0 .. section_count * 8]));
    for (directory) |*slot| slot.* = .{
        .count = 0,
        ._unused = 0,
        .formats = .{},
        .offset = DirectoryEntry.unused_offset,
    };
    const place = struct {
        fn at(dir: []align(1) DirectoryEntry, section: Section, count: u16, offset: u32) void {
            dir[@intFromEnum(section)] = .{ .count = count, ._unused = 0, .formats = .all, .offset = offset };
        }
    }.at;

    // Two triggers. Only the first is in an object's slice; the second links to junk, which is
    // harmless because nothing can fire it.
    const triggers_at = 0x100;
    place(directory, .triggers, 2, triggers_at);
    const both: []align(1) Trigger = @alignCast(std.mem.bytesAsSlice(Trigger, image[triggers_at..][0 .. 2 * @sizeOf(Trigger)]));
    both[0] = std.mem.zeroes(Trigger);
    both[0].condition = .destroyed;
    both[0].link = 0;
    both[0].armed = 1;
    both[0].qualifier = Trigger.whole_object;
    both[1] = both[0];
    both[1].condition = .shot_at;
    both[1].link = 1;

    const slices_at = 0x180;
    place(directory, .objects, 1, slices_at);
    (try layout.viewMut(Object, image[slices_at..])).* = .{ .kind = .ship, .count = 1, .first = 0, ._unknown_04 = 0 };

    // One part, at byte 16, spanning its block and one 8-byte unit of constants.
    const parts_at = 0x1A0;
    place(directory, .parts, 1, parts_at);
    const part = try layout.viewMut(Part, image[parts_at..]);
    part.offset = 8;
    part.length = 6;

    const script_at = 0x200;
    const script = [_]u8{
        // The trigger's block: push constant 0, return, padding. Then its constants.
        0x08, 0x00, 0x28, 0x00, 0x43, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // The part's block: return, padding. Then its constants.
        0x04, 0x00, 0x43, 0x00, 0x2A, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    place(directory, .script, script.len / 2, script_at);
    @memcpy(image[script_at..][0..script.len], &script);

    const mission: Mission = try .parse(&image);
    const objects = try mission.triggerObjects(std.testing.allocator);
    defer std.testing.allocator.free(objects);
    try std.testing.expectEqualSlices(?u16, &.{ 0, null }, objects);

    const map = try mission.routines(std.testing.allocator);
    defer {
        for (map) |routine| switch (routine.owner) {
            .triggers => |indices| std.testing.allocator.free(indices),
            .part => {},
        };
        std.testing.allocator.free(map);
    }
    try std.testing.expectEqual(@as(usize, 2), map.len);

    try std.testing.expectEqual(@as(usize, 0), map[0].start);
    try std.testing.expectEqual(@as(usize, 16), map[0].extent);
    try std.testing.expectEqualSlices(u16, &.{0}, map[0].owner.triggers);
    const code = try mission.script();
    try std.testing.expectEqual(@as(u32, 7), map[0].constants(code)[0]);

    try std.testing.expectEqual(@as(usize, 16), map[1].start);
    try std.testing.expectEqual(@as(u16, 0), map[1].owner.part);
    try std.testing.expectEqual(@as(u32, 0x2A), map[1].constants(code)[0]);
}

test {
    _ = commands;
    _ = opcodes;
    _ = write;
    _ = assemble;
}
