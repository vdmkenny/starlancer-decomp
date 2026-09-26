//! `C:\lancer\game\Create.cpp`: creating live objects. `create_object` (`0x00466C10`) fills a slot
//! of `game_objects`, which OpenReliant keeps in `Objects`, with an object of a ship type, and
//! `objects_reset` (`0x00466630`) fills every slot with a stand-in as a mission starts.
//! `stats_load_ships` (`0x00466500`) fills `ship_flight_stats` and `ship_combat_stats` from
//! `shipstats.bin`, [`formats/stats.zig`](../../formats/stats.zig).
//! [`create/models.zig`](create/models.zig) names each ship type's and attachment's models,
//! [`create/flight.zig`](create/flight.zig) and [`create/combat.zig`](create/combat.zig) hold the
//! flight and combat stats' words that the executable keeps, and
//! [`create/library.zig`](create/library.zig) reads the models the types and their attachment
//! points use. **Unverified:** the loader, `objects_reset`, `ship_type_load` and the
//! ship type table lie between `collision.cpp`'s code and data and this file's, and `object_reset`
//! and `objects_update` after this file's known code, before `environfx.cpp`'s.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const engine = @import("../../engine.zig");
const shp = @import("../../formats/shp.zig");
const stats = @import("../../formats/stats.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const Pointer = engine.Pointer;
const libcmt = @import("../libcmt.zig");
const ai = @import("ai.zig");
const camera = @import("camera.zig");
const cloak = @import("cloak.zig");
const aigeneric = @import("aigeneric.zig");
const collision = @import("collision.zig");
const gameobj = @import("gameobj.zig");
const guns = @import("guns.zig");
const missiles = @import("missiles.zig");
const WingSlots = @import("mission.zig").WingSlots;
const GameObject = gameobj.GameObject;
const main = @import("main.zig");
const motion = @import("motion.zig");
const objects = @import("objects.zig");
const pilots = @import("pilots.zig");
const shield = @import("shield.zig");
const environfx = @import("environfx.zig");
const explode = @import("explode.zig");
const smoke = @import("main/smoke.zig");
const srofiles = @import("srofiles.zig");
const xtrabits = @import("xtrabits.zig");

pub const models = @import("create/models.zig");
pub const flight_stats = @import("create/flight.zig");
pub const combat_stats = @import("create/combat.zig");
pub const library = @import("create/library.zig");

/// Ship types: the records of `shipstats.bin`, and the entries of the tables they index. Types
/// above the last, markers and nav points among them, have no stats.
pub const ship_type_count = 256;

/// `ship_flight_stats` (`0x004F9E70`) and `ship_combat_stats` (`0x004FC670`): each ship type's
/// flight model and combat stats, which `create_object` points each object of the type at.
pub const Stats = struct {
    flight: [ship_type_count]FlightModel,
    combat: [ship_type_count]ShipCombat,

    /// The tables as the executable holds them before `stats_load_ships` runs: every figure zero,
    /// and each record's own words, how the AI turns the type and what its combat record says it is.
    pub const initial: Stats = built: {
        var tables: Stats = .{
            .flight = @splat(std.mem.zeroes(FlightModel)),
            .combat = @splat(std.mem.zeroes(ShipCombat)),
        };
        for (&tables.flight, 0..) |*flight, ship_type| flight.turns = flight_stats.turns(ship_type);
        for (&tables.combat, combat_stats.ship_types) |*record, static| {
            record.targeting = .{ .targetable = static.targetable };
            record.name = static.name;
            record.class = static.class;
            record.side = static.side;
            record.display = static.display;
        }
        break :built tables;
    };

    /// `stats_load_ships` (`0x00466500`): each record of `shipstats.bin` in turn fills in its
    /// type's figures, up to the last type, and then every type's `speed_per_pitch_rate` is worked
    /// out. How each type turns stays as the executable has it. The combat stats keep in whole numbers what the runtime's `__ftol` cuts the record's
    /// figures down to, and a `shield_recharge` of zero becomes
    /// `stats.Ship.default_shield_recharge`.
    pub fn load(tables: *Stats, ships: []align(1) const stats.Ship) void {
        const count = @min(ships.len, ship_type_count);
        for (tables.flight[0..count], tables.combat[0..count], ships[0..count]) |*flight, *record, ship| {
            flight.max_speed = ship.max_speed;
            flight.roll_rate = ship.roll_rate;
            flight.pitch_rate = ship.pitch_rate;
            flight.yaw_rate = ship.yaw_rate;
            flight.inertia = ship.inertia;
            flight.roll_inertia = ship.roll_inertia;
            flight.pitch_inertia = ship.pitch_inertia;
            flight.yaw_inertia = ship.yaw_inertia;
            record.shield_power = std.math.lossyCast(i32, ship.shield_power);
            record.armor_class = std.math.lossyCast(i32, ship.armor_class);
            record.afterburner_fuel = std.math.lossyCast(i32, ship.afterburner_fuel);
            record.shield_recharge = if (ship.shield_recharge == 0) stats.Ship.default_shield_recharge else ship.shield_recharge;
            record.gun_energy = ship.gun_energy;
            record.gun_recharge = ship.gun_recharge;
            record.rounds = std.math.lossyCast(i32, ship.rounds);
        }
        for (&tables.flight) |*flight| flight.speed_per_pitch_rate = flight.max_speed / flight.pitch_rate;
    }

    /// What `create_object` does for a type that is `from` under another number (`donor`): the
    /// type takes `from`'s flight model and its combat stats, save for its own gun groups and
    /// name.
    fn borrow(tables: *Stats, ship_type: u8, from: u8) void {
        const own = tables.combat[ship_type];
        tables.combat[ship_type] = tables.combat[from];
        tables.combat[ship_type].gun_groups = own.gun_groups;
        tables.combat[ship_type].gun_group_table = own.gun_group_table;
        tables.combat[ship_type].name = own.name;
        tables.flight[ship_type] = tables.flight[from];
    }
};

/// The ship type a type is under another number, or null for none (`create_object`): the
/// Krasnaya, the Kiev, the Mitchell, the Zakov, the Kestrel and the Mammoth are each more than one
/// type, one model under several numbers. An object of such a type takes the stats of the first
/// (`Stats.borrow`), and then its number.
pub fn donor(ship_type: u8) ?u8 {
    return switch (ship_type) {
        0x35, 0xDB, 0xDC => 0x78,
        0x36, 0x40, 0xDD, 0xDE => 0xC2,
        0xA0 => 0x13,
        0xA1, 0xA2, 0xE2 => 0xB0,
        0xDA => 0x0F,
        0xE3...0xEF => 0x21,
        else => null,
    };
}

/// How a ship or a missile flies. `ship_flight_stats` holds one per ship, `missile_flight_stats`
/// one per missile; a missile's has only its speed and rates set.
pub const FlightModel = extern struct {
    /// `Ship.max_speed`, or `Missile.speed`.
    max_speed: f32,
    /// `Ship.roll_rate`, or `Missile.turn_rate`.
    roll_rate: f32,
    /// `Ship.pitch_rate`, or `Missile.turn_rate`.
    pitch_rate: f32,
    /// `Ship.yaw_rate`, or `Missile.turn_rate`.
    yaw_rate: f32,
    /// `Ship.inertia`.
    inertia: f32,
    roll_inertia: f32,
    pitch_inertia: f32,
    yaw_inertia: f32,
    /// `max_speed / pitch_rate`, which the ship loader computes after reading the file.
    speed_per_pitch_rate: f32,
    /// How the AI turns it (`ai_steer`). No file sets it: the executable holds it for each ship
    /// type ([`create/flight.zig`](create/flight.zig)) and each missile, and the loaders leave it.
    turns: Turns,
    _unknown_26: u16,

    /// How the AI turns a ship at a point, a word the game tests for zero.
    pub const Turns = enum(u16) {
        /// Rolling the point overhead, then pitching up at it (`0x00401710`): the fighters, and
        /// some support ships, the Nanny and the limpet car among them.
        banking = 0,
        /// Pitching and yawing at it together, never rolling (`0x00401690`): the capital ships,
        /// most other types that are not fighters, and every missile but the fuel pod.
        flat = 1,
        _,
    };

    comptime {
        assert(@offsetOf(FlightModel, "inertia") == 0x10);
        assert(@offsetOf(FlightModel, "speed_per_pitch_rate") == 0x20);
        assert(@offsetOf(FlightModel, "turns") == 0x24);
        assert(@sizeOf(FlightModel) == 0x28);
    }
};

/// A ship type's defences and what it is, one per type in `ship_combat_stats`: its figures from
/// `shipstats.bin` up to `+0x1C`, which `stats_load_ships` fills in, then the gun groups, which
/// the gun code works out at run time, then words the executable holds
/// ([`create/combat.zig`](create/combat.zig)).
pub const ShipCombat = extern struct {
    /// `Ship.shield_power`, truncated.
    shield_power: i32,
    /// `Ship.armor_class`, truncated.
    armor_class: i32,
    /// `Ship.afterburner_fuel`, truncated.
    afterburner_fuel: i32,
    /// `Ship.shield_recharge`, or 10 in place of zero.
    shield_recharge: f32,
    /// `Ship.gun_energy`: the most the guns' charge holds.
    gun_energy: f32,
    /// `Ship.gun_recharge`: the seconds the guns take to charge fully, over which the guns' step
    /// adds `gun_energy * gun_factor * gun_condition` to their charge (`guns.step`).
    gun_recharge: f32,
    /// `Ship.rounds`, truncated: the rounds a new object's guns have (`GameObject.rounds`).
    rounds: i32,
    /// The type's guns in groups, which `0x004667F0` works out from its first object's guns,
    /// pairing each gun with its mirror image across the ship; zero until then (#131).
    gun_groups: i16,
    _unknown_1e: u16,
    /// The groups, `0x00545900 + type * 0x78`, set with `gun_groups`.
    gun_group_table: Pointer(anyopaque),
    targeting: Targeting,
    /// The language string that names the type.
    name: u16,
    class: Class,
    /// The side the type's objects start on.
    side: gameobj.Side(i16),
    /// Which form of the target display shows the type's objects.
    display: TargetDisplay,

    /// Which form of the target display shows a type's objects: the small window
    /// (`hud.windows.Window.target`) for fighters and most small craft, the large one
    /// (`Window.big_target`) for most capital and support ships. `hud_ship_status` draws a small
    /// form's schematic mirrored and a large form's as it stands.
    pub const TargetDisplay = enum(u32) {
        small = 0,
        large = 1,
        _,
    };

    pub const Targeting = packed struct(u16) {
        /// The type's objects can be picked as targets: `object_set_targetable` sets an object's
        /// `targetable` flag only where this is set.
        targetable: bool = false,
        _unknown_1: u15 = 0,
    };

    /// What a ship type is, going by the models of each class.
    pub const Class = enum(u16) {
        /// The player's ships, their twins, and the Coalition's fighters.
        fighter = 1,
        /// Capital ships and their wrecks, and other large bodies such as the asteroids of types
        /// 0x79 to 0x7F.
        capital = 2,
        /// Bombers, transports, tugs, escape pods, some stations: what lies between fighters and
        /// capital ships.
        support = 3,
        /// Gates, containers, satellites, beacons, pods, rock chunks and the like.
        other = 4,
        torpedo = 5,
        /// Wreckage, floating crew, doors and plates. `create_object` gives an object of the class
        /// a tenth of its mass.
        debris = 6,
        /// The proximity mine, which `create_object` gives a radius of 2000.
        mine = 7,
        planet = 8,
        _,
    };

    /// Six times its `armor_class`: a quadrant's full armour, which the game measures the
    /// armour's wear against. `create_object` starts each quadrant one below it.
    pub fn fullArmor(combat: *const ShipCombat) f32 {
        return @floatFromInt(combat.armor_class * 6);
    }

    /// A quadrant's armour as `create_object` fills it, one short of `fullArmor`, which the
    /// armour's conditions and warning count from (`main.armorConditions`).
    pub fn startingArmor(combat: *const ShipCombat) f32 {
        return combat.fullArmor() - 1;
    }

    /// Six times its `shield_power`: a quadrant's full shields, likewise.
    pub fn fullShields(combat: *const ShipCombat) f32 {
        return @floatFromInt(combat.shield_power * 6);
    }

    comptime {
        assert(@offsetOf(ShipCombat, "shield_recharge") == 0x0C);
        assert(@offsetOf(ShipCombat, "gun_groups") == 0x1C);
        assert(@offsetOf(ShipCombat, "gun_group_table") == 0x20);
        assert(@offsetOf(ShipCombat, "targeting") == 0x24);
        assert(@offsetOf(ShipCombat, "name") == 0x26);
        assert(@offsetOf(ShipCombat, "class") == 0x28);
        assert(@offsetOf(ShipCombat, "side") == 0x2A);
        assert(@offsetOf(ShipCombat, "display") == 0x2C);
        assert(@sizeOf(ShipCombat) == 0x30);
    }
};

/// An entry of `ship_types`, one for each ship type; [`create/models.zig`](create/models.zig) has
/// the names.
pub const ShipType = extern struct {
    model_name: Pointer(u8),
    schematic_name: Pointer(u8),
    /// Objects of the type, which `create_object` counts up, loading the model for the first.
    objects: u16,
    _unknown_0a: u16,
    /// The model, once loaded.
    model: Pointer(anyopaque),
    /// What its objects keep as `GameObject.type_data`: the schematic `ship_type_load` loads with
    /// the model.
    type_data: Pointer(anyopaque),

    comptime {
        assert(@offsetOf(ShipType, "model") == 0x0C);
        assert(@sizeOf(ShipType) == 0x14);
    }
};

/// An entry of `attachment_models`: what attachment points of one kind and id mount, as loaded.
/// [`create/models.zig`](create/models.zig) has the file names.
pub const MountedModel = extern struct {
    model: Pointer(anyopaque),
    /// A second model: the missile, for a missile pod.
    second_model: Pointer(anyopaque),
    /// **Unknown.** 1 unless the loader sets it.
    count: u32,
    sprite: Pointer(anyopaque),

    comptime {
        assert(@sizeOf(MountedModel) == 0x10);
    }
};

/// A ship type's model as `ship_type_load` (`0x00466740`) loads it for the type's first object.
/// It loads the type's schematic as well, which OpenReliant leaves with whoever loads the model,
/// since the display draws it.
pub const Type = struct {
    model: *const shp.Model,
    loaded: *const srofiles.Loaded,
    /// What the type's objects light themselves with and mount.
    effects: objects.Effects = .{},
    /// The type's own sprite (`GameObject.type_data`), which for a ship is its schematic, where
    /// the game has one: the ship status indicator and the target display draw it.
    schematic: ?@import("hud.zig").Schematic = null,
};

/// Where ship types' models come from: whoever has the game's files answers, as for
/// `objects.Mounts`.
pub const Types = struct {
    context: *anyopaque,
    /// Null for a type with no model, or one the game lacks or cannot read; whoever answers says
    /// why.
    load: *const fn (context: *anyopaque, ship_type: u8) ?*const Type,
};

/// What `ship_types` keeps of a ship type while a mission runs: how many objects of it
/// `create_object` has made, and what it loaded for the first.
pub const TypeUse = struct {
    objects: u16 = 0,
    loaded: ?*const Type = null,
};

/// The slot the loops over the objects walk after those handed out (`0x0057E04E`), which the
/// mission's start sets to 399, the last. The cutaway scenes use it: in one of them only the
/// player's ship and this slot's object are drawn.
pub const cutaway_slot: u16 = gameobj.max_objects - 1;

/// A slot of `game_objects`: the object's record, and what OpenReliant keeps beside it where the
/// record holds the original's 32-bit pointers.
pub const Slot = struct {
    object: GameObject,
    /// Its type's stats in `Stats` (`GameObject.combat`, `flight`); null for a stand-in.
    combat: ?*const ShipCombat = null,
    flight: ?*const FlightModel = null,
    /// Its type's model as loaded (`GameObject.model`), and the nodes of the model's parts, which
    /// hang from its root; null for a stand-in, or a type the game has no model for.
    type: ?*const Type = null,
    model: ?objects.Model = null,
    /// What moves it each update (`GameObject.motion`); null for nothing.
    motion: ?motion.Motion = null,
    /// The motion a jump puts aside while it flies its own, and gives back as it ends
    /// (`jump.State.motion`, which the game keeps as the routine's address).
    motion_aside: ?motion.Motion = null,
    /// How far it goes a tick where the orders place it from tick to tick rather than move it: it
    /// is drawn that much further along for the time the frame is past its tick
    /// (`objects.frameTree`). The orders set it each frame they place it, and the frame's pass
    /// lets it go (`main.frameObjects`), keeping whether it glided, so that the frame after it is
    /// drawn back where it was placed.
    glide: Vector = @splat(0),
    glided: bool = false,
    /// Where its root's frame has it drawn (`objects.frameTree`), which stays put between the
    /// steps that move it.
    drawn: objects.Model.Local = .{},
    /// The node it rides while it launches (`launch.State.node`, which the game keeps as the
    /// node's address); null for none.
    riding: ?objects.NodeOf = null,
    /// Its stack of orders, the current one first, `GameObject.order_count` of them
    /// (`GameObject.orders`), which the game allocates with the object's first order.
    orders: [aigeneric.max_stack]aigeneric.Entry = @splat(std.mem.zeroes(aigeneric.Entry)),
    /// What the current order keeps between its updates (`GameObject.order_state`), allocated with
    /// the stack.
    state: aigeneric.State = .{ .bytes = @splat(0) },
    /// Its guns, one for each muzzle of its model (`GameObject.guns`), made in the objects'
    /// allocator.
    guns: []guns.Fitted = &.{},
    /// Its type's gun groups (`ShipCombat.gun_group_table`), in `Objects.gun_groups`.
    gun_groups: *const [guns.max_groups]guns.Group = &guns.no_groups,
    /// The parts of its model that count as components, `GameObject.component_count` of them, the
    /// models mounted on it among them (`GameObject.components`, which holds their nodes).
    components: [gameobj.max_components]?*objects.Model.Part = @splat(null),
    /// Its shields' bubble (`GameObject.render`), which a ship that lists no components and is not
    /// debris has.
    shield: ?*shield.Bubble = null,
    /// Its cloak, from the moment it starts to come on until it has gone (`GameObject.cloak`).
    cloak: ?cloak.Cloak = null,
    /// Its smoke, while its damage shows (`GameObject.smoke`).
    smoke: ?smoke.Stream = null,

    /// Lets go of what the slot holds for its object: its cloak (`cloak.drop`), its model, its guns
    /// and its shield bubble (`object_free`).
    pub fn release(slot: *Slot, gpa: Allocator) void {
        cloak.drop(slot);
        if (slot.model) |model| model.deinit(gpa);
        slot.dropGuns(gpa);
        if (slot.shield) |bubble| bubble.destroy(gpa);
        slot.shield = null;
    }

    /// Its current order, the first of its stack, where it has one: as mutable as `slot` is.
    pub fn current(slot: anytype) ?@TypeOf(&slot.orders[0]) {
        if (slot.object.order_count == 0) return null;
        return &slot.orders[0];
    }

    /// The parts it lists as components, `GameObject.component_count` of them.
    pub fn listed(slot: *const Slot) []const ?*objects.Model.Part {
        return slot.components[0..@intCast(@max(slot.object.component_count, 0))];
    }

    /// Its component `n`, where it lists one there.
    pub fn component(slot: *const Slot, n: usize) ?*objects.Model.Part {
        const parts = slot.listed();
        return if (n < parts.len) parts[n] else null;
    }

    /// `object_component_index` (`0x0045ADE0`): where it lists `part` among its components, by
    /// which the mission's events and its triggers name a component; null where it does not.
    pub fn componentIndex(slot: *const Slot, part: *const objects.Model.Part) ?u8 {
        for (slot.listed(), 0..) |entry, n| {
            if (entry == part) return @truncate(n);
        }
        return null;
    }

    /// Lets its guns go: it has none from now on.
    pub fn dropGuns(slot: *Slot, gpa: Allocator) void {
        gpa.free(slot.guns);
        slot.guns = &.{};
        slot.object.gun_count = 0;
    }

    /// How many groups of guns its type has (`ShipCombat.gun_groups`); none for a stand-in.
    pub fn groupCount(slot: *const Slot) i16 {
        const combat = slot.combat orelse return 0;
        return combat.gun_groups;
    }

    /// Draws the object at `size` of its own, as `explode_asteroid` makes its fragments: its
    /// `visibility`, which scales the sphere it collides by and how far off it is drawn, and the
    /// scale its model's first part is drawn at (that part's frame's `+0x48`).
    pub fn shrink(slot: *Slot, size: f32) void {
        slot.object.visibility = size;
        const model = if (slot.model) |*live| live else return;
        model.visibility = size;
        if (model.parts.len > 0) model.parts[0].object.scale = size;
    }

    /// The gun type leading its group `group` (`guns.groupLead`).
    pub fn groupLead(slot: *const Slot, group: usize) ?guns.GunType {
        return guns.groupLead(slot.guns, slot.gun_groups, group);
    }

    /// Its guns and their groups, for firing them from `frame_start` (`guns.fire`).
    pub fn trigger(slot: *const Slot, frame_start: i32) guns.Trigger {
        return .{ .fitted = slot.guns, .groups = slot.gun_groups, .frame_start = frame_start };
    }
};

/// `game_objects` (`0x00587CE0`), the GO array: 400 slots, none ever empty. As a mission starts
/// every slot gets a stand-in (`reset`), and `create_object` fills them with objects
/// (`createObject`), in turn or at the slot it is given, such as a mission ship's index among the
/// ship records. The loops over the objects walk the slots handed out, then the cutaway slot
/// (`walk`).
pub const Objects = struct {
    gpa: Allocator,
    slots: [gameobj.max_objects]Slot,
    /// `game_object_count` (`0x00539AA0`): the slots `create_object` has handed out in turn.
    count: u16 = 0,
    /// `player_slots` (`0x0058832C`): the slots from the first that belong to players, one in a
    /// single-player game.
    players: u16 = 1,
    /// `player_index` (`0x005883FA`): the player's slot, the first in a single-player game.
    player: u16 = 0,
    types: [ship_type_count]TypeUse = @splat(.{}),
    /// Each ship type's gun groups (`0x00545900`), which `gun_groups_build` works out from an
    /// object of the type.
    gun_groups: [ship_type_count][guns.max_groups]guns.Group = @splat(@splat(.{})),
    /// `gun_stats` (`0x00500CA4`): every gun type's figures, which `stats_load_guns` fills from
    /// `gunstats.bin`.
    gun_stats: guns.Stats = .initial,
    /// `missile_stats` and `missile_flight_stats`: every missile type's figures, which
    /// `stats_load_missiles` fills from `missilestats.bin`.
    missile_stats: missiles.Table = .initial,
    /// `campaign_tier` (`0x00562DF0`): the loadout tier the campaign has reached, which a fighter
    /// asked for none is fitted by. 0 for a new pilot; the missions after the 11th, 19th and 21st
    /// raise it to 1, 2 and 3 (`mission_end_record`).
    campaign_tier: u2 = 0,
    /// `pilot_stats` (`0x0058A968`): every pilot, which `stats_load_pilots` fills from
    /// `pilotstats.bin`.
    pilots: pilots.Table = .{},
    /// The shots in flight (`0x00563148`), which the game keeps in `guns.cpp`'s own globals. The
    /// port keeps them here, beside the objects they fly among.
    bullets: guns.Bullets = .{},
    /// The missiles in flight (`0x005887F0`), which the game keeps in `missiles.cpp`'s own globals.
    /// OpenReliant keeps them here too.
    missiles: missiles.Missiles = .{},
    /// The player's wing (`player_wing`, `0x00515D88`), which the game keeps in `mission.cpp`'s
    /// own globals and a mission lists (`mission.listPlayerWing`). OpenReliant keeps it here too.
    wing: WingSlots = @splat(null),
    /// The working lists of the collision sweep `objectsUpdate` runs.
    sweep: Sweep = .{},
    /// `0x005185AC`: the tick at which `aigeneric.ordersUpdate` next clears what every object has
    /// lately taken.
    damage_cleared_at: u32 = 0,
    /// `mission_number` (`0x00562DC8`): the number of the mission being played, from 1, or 0 for
    /// OpenReliant's mission 0. A few of the game's rules single a mission out by it:
    /// `create_object` and `mission_ship_create` give the player's wing the `t_` twins of the
    /// player's ships from `twins_from_mission` on, the turrets launch their missiles sooner in
    /// mission 28, and the launch's caption and the objectives go by it.
    mission_number: u16 = 0,
    /// `mission25_second_part` (`0x00587CDC`): whether mission 25's first part is won and its
    /// second is played, before which the player flies a Kamov.
    mission25_second_part: bool = false,
    /// The ship the loadout screen chose for each player's slot (`player_loadouts`, `0x00588400`,
    /// the first word of each), which `create_object` makes the player's ship of (`slotType`).
    /// Until the loadout screen is ported
    /// ([#44](https://github.com/vdmkenny/openreliant/issues/44)), OpenReliant's driver chooses it,
    /// and where it chooses none the mission's own kind stands.
    loadout_ships: [max_loadouts]?gameobj.Type = @splat(null),
    /// `0x005185A8`, while the byte at `0x005185B1` is set: the number the next order pushed takes
    /// (`aigeneric.Entry.sequence`), as `SetAI` numbers a group's orders
    /// (`aigeneric.startNumbering`); null otherwise, when an order takes 0.
    order_number: ?i32 = null,
    /// The sphere the action keeps to.
    action_sphere: aigeneric.ActionSphere = .default,
    /// The ships whose engine exhaust burns the player's ship, which the game keeps in
    /// `environfx.cpp`'s own globals. OpenReliant keeps them here, as `create_object` adds to them.
    exhaust: environfx.Exhaust = .{},

    /// Every slot standing in, as a mission's start leaves them (`reset`), made in `gpa`.
    pub fn create(gpa: Allocator, random: *libcmt.Rand) Allocator.Error!*Objects {
        const all = try gpa.create(Objects);
        all.* = .{ .gpa = gpa, .slots = @splat(.{ .object = undefined }) };
        all.reset(random);
        return all;
    }

    pub fn destroy(all: *Objects) void {
        all.missiles.reset(all.gpa);
        for (&all.slots) |*slot| slot.release(all.gpa);
        all.gpa.destroy(all);
    }

    /// `objects_reset` (`0x00466630`), as a mission starts: every slot gets a new stand-in, of
    /// `gameobj.Type.stand_in` and flagged `stand_in` (`object_alloc`), no slot is handed out, and
    /// no ship type has objects or a model loaded. OpenReliant lets go of the objects' nodes as
    /// well, which the game frees as the mission before ends.
    ///
    /// Not ported: the planets' atmospheres, whose texture it loads and whose table it empties.
    pub fn reset(all: *Objects, random: *libcmt.Rand) void {
        for (&all.slots) |*slot| {
            slot.release(all.gpa);
            var object = gameobj.objectAlloc(.stand_in, random);
            object.flags.stand_in = true;
            slot.* = .{ .object = object };
        }
        all.types = @splat(.{});
        all.count = 0;
        // The game lets the exhaust's list go as the mission before ends (`exhaust_ships_reset`).
        all.exhaust.reset();
    }

    /// `object_reset` (`0x004688B0`): replaces the object in slot `index` with a new stand-in
    /// flagged as one (`GameObject.Flags.standing_in`), and lets its nodes go, its orders with
    /// them. Its type's count of objects stays as it was.
    ///
    /// Not ported: the `exit` routines popping those orders would run, none of which is ported yet
    /// ([#30](https://github.com/vdmkenny/openreliant/issues/30)).
    pub fn resetSlot(all: *Objects, index: u16, random: *libcmt.Rand) void {
        const slot = &all.slots[index];
        slot.release(all.gpa);
        var object = gameobj.objectAlloc(.stand_in, random);
        object.flags = .standing_in;
        slot.* = .{ .object = object };
    }

    /// A type's model, loaded for its first object where it isn't held, and one more object of it
    /// counted, so that it stays (`create_object`, `ship_type_first_levels`). Null where the game
    /// has no model for it.
    pub fn useType(all: *Objects, types: Types, ship_type: u8) ?*const Type {
        const use = &all.types[ship_type];
        if (use.objects == 0 and use.loaded == null) use.loaded = types.load(types.context, ship_type);
        use.objects += 1;
        return use.loaded;
    }

    /// The type `create_object` makes an object asked for as `asked` of in slot `index`: in a
    /// player's slot, a Kamov in mission 25's first part, or else the ship the loadout chose, its
    /// `t_` twin from `twins_from_mission` on; in any other slot, `asked`.
    ///
    /// Not ported: a multiplayer game, where every slot takes `asked`, and the rule of
    /// `0x00524FE4` by which a type 13 becomes a Reliant.
    pub fn slotType(all: *const Objects, index: u16, asked: gameobj.Type) gameobj.Type {
        if (index >= all.players or index >= all.loadout_ships.len) return asked;
        if (all.mission_number == kamov_mission and !all.mission25_second_part) return .kamov;
        const chosen = all.loadout_ships[index] orelse return asked;
        if (all.mission_number < twins_from_mission) return chosen;
        return chosen.twin() orelse chosen;
    }

    /// The slots the loops over the objects walk, in their order.
    pub fn walk(all: *const Objects) Walk {
        return .{ .all = all };
    }

    /// Each slot handed out, from the first, then the cutaway slot. The loops read the count at
    /// every slot, so an object created on the way is walked as well.
    ///
    /// **Improvement:** with every slot handed out, the cutaway slot comes round again and again in
    /// the game's loops, which never end; OpenReliant walks it once.
    pub const Walk = struct {
        all: *const Objects,
        at: u16 = 0,

        pub fn next(w: *Walk) ?u16 {
            if (w.at < w.all.count) {
                defer w.at += 1;
                return w.at;
            }
            if (w.at > cutaway_slot) return null;
            w.at = cutaway_slot + 1;
            return cutaway_slot;
        }
    };
};

/// The players' loadouts `player_loadouts` (`0x00588400`) holds, a slot each.
pub const max_loadouts = 8;

/// The first mission in which the player's wing flies the `t_` twins of the player's ships, and the
/// mission whose first part has the player fly a Kamov (immediates in `create_object` and
/// `mission_ship_create`).
pub const twins_from_mission = 14;
pub const kamov_mission = 25;

/// What goes wrong in `create_object`, which stops the game with a fatal error for either.
pub const Error = error{
    /// "Overrun in GO array": the slot is past the last, or none is left to hand out.
    Overrun,
    /// "Trying to create object %s twice".
    CreatedTwice,
} || Allocator.Error;

/// The radius `create_object` gives an object of a type above the last ship type.
pub const stand_in_radius: f32 = 4000;

/// The pilot `create_object` gives the Coalition's types, record 66 of `pilotstats.bin`; every
/// other type gets record 0.
pub const coalition_pilot = 66;

/// A mine's radius (`ShipCombat.Class.mine`).
const mine_radius: f32 = 2000;

/// What a piece of debris's mass is scaled by (`ShipCombat.Class.debris`).
const debris_mass: f32 = 0.1;

/// A wreck's part that burns (`create_object`, `0x00466C10`): its name, and whether it shows first,
/// as a Badanov's half is hidden until then.
const Wreck = struct {
    part: []const u8,
    shown: bool = false,
};

/// The part each wreck burns.
fn wreckOf(object_type: gameobj.Type) ?Wreck {
    return switch (object_type) {
        .mammoth_wreck_front => .{ .part = "Mam frnt dest 2" },
        .mammoth_wreck_back => .{ .part = "Mam back dest" },
        .badanov_wreck_back => .{ .part = "Bad dead back", .shown = true },
        .badanov_wreck_front => .{ .part = "BAD dead frnt", .shown = true },
        .kurgan_wreck => .{ .part = "Box07" },
        else => null,
    };
}

/// The part of `create_object` for a wreck, once it is made where the world can see it: its part
/// burns for good, its rays flickering, with its burn lights and smoke (`explode.burnPart`). The
/// port does it once the object is made, as the split makes the wreck (`explode.split`).
///
/// Not ported: the rest of `create_object` for single types, such as the Protogate's power core,
/// which burns with rays alone ([#233](https://github.com/vdmkenny/openreliant/issues/233)).
pub fn wreckMade(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const wreck = wreckOf(slot.object.type) orelse return;
    if (wreck.shown) if (slot.model) |*model| if (model.partNamed(wreck.part)) |ref| {
        ref.part().hidden = false;
    };
    explode.burnPart(world, index, wreck.part, .{ .forever = true, .flickers = true, .lights = true });
}

/// `create_object` (`0x00466C10`): fills slot `wanted`, or the next where null, with an object of
/// `ship_type` at `at`, facing along the world's Z axis, and returns the slot. Types above the
/// last ship type are stand-ins for markers and nav points: `Flags.standing_in` and a sphere of
/// `stand_in_radius`, and nothing else. Any other is set up at rest, undamaged and flying itself
/// forward (`motion.Motion.forward`), on its type's side, with its model's parts playing their
/// `startup` tracks (`startUp`) and linked (`gameobj.linkParts`). A ship that lists no components
/// and is not debris gets its shields' bubble (`shield.Bubble`). A type that is another under a
/// second number takes the other's stats (`donor`), and its number once it is made.
///
/// Its missile racks are fitted by the loadout `tier` a mission's ship record asks for, as
/// `settledTier` settles it for the type asked for (`loadoutByTier`, `fitRacks`), with 5000 more of
/// the afterburner's fuel for each fuel pod. Given a player's slot, it makes the type the loadout
/// chose (`Objects.slotType`).
///
/// Not ported: the components (#40); what it does for capital ships, planets, gates and other
/// single types but the wrecks (#233, `wreckMade`); for a player's slot, the missiles the player
/// chose on the loadout screen (#44), where OpenReliant fits a player's ship by the tier as the
/// game does when the briefing is skipped; and what differs in a multiplayer game.
pub fn createObject(all: *Objects, tables: *Stats, types: Types, wanted: ?u16, asked: gameobj.Type, tier: i32, at: Vector, random: *libcmt.Rand) Error!u16 {
    const index = wanted orelse all.count;
    if (index >= gameobj.max_objects) return error.Overrun;
    const ship_type = if (wanted != null) all.slotType(index, asked) else asked;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (object.created) return error.CreatedTwice;
    if (wanted == null) all.count += 1;

    object.type = ship_type;
    object.index = index;
    object.flags = .{};
    object.root.flags._unknown_9 = true;
    // At rest, and steering nothing.
    object.speed = 0;
    object.roll_rate = 0;
    object.pitch_rate = 0;
    object.yaw_rate = 0;
    object.throttle = 0;
    object.roll_input = 0;
    object.pitch_input = 0;
    object.yaw_input = 0;
    object.wing = .none;
    object.random_seed = random.rand();
    object.invulnerable = .none;
    object.visibility = 1;
    object.engines = 0;
    object.set_aside = .none;
    object.set_aside_until = 0;
    object.eject_roll = xtrabits.objectRandom15(object) % 100;
    objects.setPosition(object, &slot.drawn, at);
    objects.setOrientation(object, &slot.drawn, math.identity);
    // No orders, and no attacker yet.
    object.order_count = 0;
    object.orders = .null;
    object.created = true;
    object.last_attacker = .none;
    object.nav_point = .none;
    object.escort_point = .none;
    object.fought_by = 0;
    object.motion = .null;
    object.side = .neutral;
    object.smoke = .null;
    slot.smoke = null;
    // Its armour whole.
    object.shield_condition = 1;
    object.armor_speed_factor = 1;
    object.gun_condition = 1;
    object._unknown_750 = 0;
    object.sound_voice = .none;
    object.gun_turn = .first;
    object.blind_fire_aim = 0;
    object._unknown_678 = 0;
    object._unknown_710 = @splat(0);

    const stats_type = std.math.cast(u8, ship_type.number()) orelse {
        object.type_data = .null;
        object.pilot_record = .null;
        object._unknown_628 = .zero;
        object.shields = .all(0);
        object.armor = .all(0);
        object.flags = .standing_in;
        object.radius = stand_in_radius;
        return index;
    };
    const becomes = donor(stats_type) orelse stats_type;
    if (becomes != stats_type) tables.borrow(stats_type, becomes);
    const combat = &tables.combat[stats_type];
    slot.combat = combat;
    slot.flight = &tables.flight[stats_type];
    slot.motion = .forward;
    object.side = @enumFromInt(@intFromEnum(combat.side));

    slot.type = all.useType(types, stats_type);
    if (slot.type) |loaded| {
        var model: objects.Model = try .create(all.gpa, loaded.model, loaded.loaded, loaded.effects);
        startUp(&model);
        for (loaded.model.parts) |part| {
            switch (part.part.class) {
                .shield_generator => object.flags.shield_generator = true,
                .engine => object.engines += 1,
                else => {},
            }
            for (part.attachments) |attachment| {
                if (attachment.kind == .eject_point) object.flags.eject_point = true;
            }
        }
        gameobj.linkParts(&model, loaded.model);
        slot.model = model;
        // `object_recentre` puts what it works out in the record.
        object.mass = model.mass;
        object.centre = gameobj.vec3(model.centre);
        object.radius = model.radius;
        object.angular_response = model.angular_response;
        object.bounds_min = gameobj.vec3(model.bounds[0]);
        object.bounds_max = gameobj.vec3(model.bounds[1]);
        objects.setPosition(object, &slot.drawn, at);
        switch (combat.class) {
            .debris => object.mass *= debris_mass,
            .mine => object.radius = mine_radius,
            else => {},
        }
        if (!loaded.model.header.flags.components and index >= all.players) object.flags.ecm = true;
        if (loaded.model.header.flags.components) {
            object.flags.components = true;
            object.flags.attached = true;
        }
    }
    object.wing_icon = 0;
    pilots.setPilot(object, if (combat.side == .hostile) coalition_pilot else 0);
    // Each quadrant's shields and armour full.
    object.shields = .all(combat.fullShields() - 1);
    object.armor = .all(combat.startingArmor());
    main.armorConditions(object, combat);
    if (!object.flags.components and combat.class != .debris) slot.shield = try shield.Bubble.create(all.gpa, object.radius, combat.side);

    object.engines_intact = 1;
    object.passes_through = @splat(.none);
    object.fighting = .none;
    object.power_up = .none;
    object.afterburner_fuel = combat.afterburner_fuel * 100;
    object.countermeasures = gameobj.countermeasures_when_created;
    // The power shared evenly, at (1, 1) on the power ball.
    object.gun_factor = 1;
    object.speed_factor = 1;
    object.shield_factor = 1;
    object.power_setting = .{ .x = 1, .y = 1, .z = 1 };
    object.gun_count = 0;
    object.component_count = 0;
    // The components are listed once the count is clear, as the game lists them, and the guns are
    // fitted after them (`object_fit_guns`): a turret fires within its component's firing arc.
    if (object.flags.components) collectComponents(slot);
    if (slot.model) |*model| slot.guns = try guns.fit(all.gpa, model, .{
        .components = slot.listed(),
        .arcs = if (slot.type) |loaded| loaded.model.firing_arcs else &.{},
    });
    object.gun_count = @intCast(slot.guns.len);
    // The type's gun groups follow from this object's guns, and each gun learns its side.
    // `gun_groups_build` leaves a type with no model alone.
    if (slot.model != null and combat._unknown_1e == 0) {
        tables.combat[stats_type].gun_groups = @intCast(guns.buildGroups(slot.guns, &all.gun_groups[stats_type]));
    }
    slot.gun_groups = &all.gun_groups[stats_type];
    for (all.gun_groups[stats_type][0..@intCast(tables.combat[stats_type].gun_groups)]) |group| {
        const first, const second = group.members();
        const lead = guns.gunAt(slot.guns, first) orelse continue;
        lead.side = .first;
        if (guns.gunAt(slot.guns, second)) |other| other.side = .second;
    }
    // Its guns charged.
    object.gun_charge = combat.gun_energy;
    object.rounds = combat.rounds;
    object.gun_mode = .created(combat.gun_groups);
    if (slot.model) |*model| {
        loadoutByTier(object, model, settledTier(tier, asked, all.campaign_tier));
        try fitRacks(all.gpa, object, model, if (slot.type) |loaded| loaded.effects else .{});
    }
    for (object.fittedRacks()) |rack| {
        if (rack.type == .fuel_pod) object.afterburner_fuel += fuel_pod_fuel;
    }
    ai.setTargetable(object, combat, true);
    all.exhaust.offer(all, index);
    object.type = @enumFromInt(becomes);
    return index;
}

/// The afterburner's fuel a fuel pod adds, in hundredths of a second: 50 seconds.
pub const fuel_pod_fuel = 5000;

/// The last ship type the campaign's tier fits: the player's twelve fighters.
const last_fighter = 11;

/// The loadout tier `create_object` settles on for an object of `ship_type` asked for `asked`: 5
/// is 4, and what lies outside 0 to 4 is 0. A fighter asked for 0 takes the campaign's `campaign`,
/// and then any 4 is 0. So a mission's record asks for the campaign's tier with 0 or 255, and for
/// tier 0 with 4 or 5.
pub fn settledTier(asked: i32, ship_type: gameobj.Type, campaign: u2) u2 {
    var tier: i32 = if (asked == 5) 4 else if (asked < 0 or asked > 4) 0 else asked;
    if (tier == 0 and @intFromEnum(ship_type) <= last_fighter) tier = campaign;
    return if (tier == 4) 0 else @intCast(tier);
}

/// A missile hardpoint: an attachment of kind `missile` on a part of the model.
pub const Hardpoint = struct {
    part: usize,
    /// Which of the part's attachments it is.
    index: usize,
    attachment: *const shp.Attachment,
};

/// The missile hardpoints the loadout walks, in turn (`object_fit_missiles`): those of each part in
/// the root's child list, every part in order whatever it is linked to, each part's in order.
pub fn hardpoints(model: *const objects.Model) Hardpoints {
    return .{ .parts = model.parts };
}

pub const Hardpoints = struct {
    parts: []const objects.Model.Part,
    part: usize = 0,
    attachment: usize = 0,

    pub fn next(each: *Hardpoints) ?Hardpoint {
        while (each.part < each.parts.len) : ({
            each.part += 1;
            each.attachment = 0;
        }) {
            const part = &each.parts[each.part];
            if (part.removed) continue;
            while (each.attachment < part.attachments.len) {
                const attachment = &part.attachments[each.attachment];
                each.attachment += 1;
                if (attachment.kind == .missile) return .{ .part = each.part, .index = each.attachment - 1, .attachment = attachment };
            }
        }
        return null;
    }
};

/// `object_loadout_by_tier` (`0x0045E500`): each missile hardpoint, in turn, takes a rack of the
/// missile its attachment names for `tier`.
///
/// Not ported: the player's own ship in the simulator and in missions 30 to 35, which takes a
/// Vagabond, a Jack Hammer and a Raptor in turn.
pub fn loadoutByTier(object: *GameObject, model: *const objects.Model, tier: u2) void {
    object.rack_count = 0;
    var each = hardpoints(model);
    while (each.next()) |hardpoint| {
        if (object.rack_count == gameobj.max_racks) break;
        object.racks[@intCast(object.rack_count)] = .{ .type = .of(hardpoint.attachment.idFor(tier)) };
        object.rack_count += 1;
    }
}

/// `object_fit_missiles` (`0x0045E1A0`): hangs on each missile hardpoint, in turn, what its rack
/// holds, a pod or a missile on its rail, and fills the rack: a pod's capacity, or 1. A rack of no
/// missile ends the loadout: its count is 0, and each hardpoint after it reads the same rack, so
/// stays empty. What hung there before is let go first, as a re-arm does. A model the game lacks
/// hangs nothing, and its rack stays filled.
pub fn fitRacks(gpa: Allocator, object: *GameObject, model: *objects.Model, effects: objects.Effects) Allocator.Error!void {
    if (model.hung.len == 0) {
        model.hung = try gpa.alloc(?objects.Model.Mount, gameobj.max_racks);
        @memset(model.hung, null);
    }
    for (model.hung) |*held| if (held.*) |mount| {
        mount.model.deinit(gpa);
        held.* = null;
    };
    object.rack_count = 0;
    var each = hardpoints(model);
    while (each.next()) |hardpoint| {
        if (object.rack_count == gameobj.max_racks) break;
        const at: usize = @intCast(object.rack_count);
        const rack = &object.racks[at];
        const held = models.attachment(.missile, @intCast(rack.type.index() orelse {
            rack.count = 0;
            continue;
        })) orelse models.Attachment{};
        rack.count = @intCast(held.count);
        model.hung[at] = try hang(gpa, effects, hardpoint, held.model);
        object.rack_count += 1;
    }
}

/// What a hardpoint holds, built from `file` and standing on its own centre of mass at the
/// hardpoint's place; null where the game lacks the model.
fn hang(gpa: Allocator, effects: objects.Effects, hardpoint: Hardpoint, file: ?[]const u8) Allocator.Error!?objects.Model.Mount {
    const mounts = effects.mounts orelse return null;
    const mounted = mounts.load(mounts.context, file orelse return null) orelse return null;
    var built: objects.Model = try .create(gpa, mounted.model, mounted.loaded, effects);
    gameobj.linkParts(&built, mounted.model);
    return .{
        .part = hardpoint.part,
        .attachment = hardpoint.index,
        .origin = gameobj.vector(hardpoint.attachment.position),
        .orientation = hardpoint.attachment.orientation,
        .model = built,
    };
}

/// `objects_update` (`0x00468FA0`), once a simulation step after the objects' own updates: moves
/// each live object of a ship type (`motion.move`), in the loops' order, passing over stand-ins
/// and disabled and frozen objects. The player's shakes the camera (`shake`).
///
/// Not ported yet: the collision sweep that follows (#40), and in a multiplayer game, what places
/// the other players' ships (#55).
pub fn objectsUpdate(world: gameobj.World) void {
    const all = world.objects;
    var sweep = &all.sweep;
    sweep.count = 0;
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (!object.type.hasStats() or object.flags.stand_in or object.flags.disabled) continue;
        // A frozen object stays where it is, and is still there to be run into.
        if (!object.flags.frozen) motion.moveSlot(world, index);
        if (object.flags.no_collisions) continue;
        sweep.add(index, object);
    }
    sweep.run(world);
}

/// The sweep for the pairs of objects that meet, which `objects_update` runs once every object has
/// moved. It holds what the game keeps in globals: an extent along X for each object that collides
/// (`0x0054D110`), the order they sort in (`0x0054E3D4`) and how many there are (`0x0054EA14`).
///
/// Sorting by the far end of each extent leaves every object that can reach a given one after it in
/// the order, so each object is tested against those that follow while their extents still reach
/// back to it. A pass that moves anything is followed by another, up to `passes` of them; the game
/// puts a "collision" message on the screen when the last one still finds a pair, which OpenReliant
/// leaves out.
pub const Sweep = struct {
    entries: [gameobj.max_objects]Entry = @splat(.{}),
    order: [gameobj.max_objects]u16 = @splat(0),
    count: u16 = 0,

    /// How many passes `objects_update` makes over the pairs at most.
    pub const passes = 10;

    pub const Entry = struct {
        index: u16 = 0,
        /// Its radius for the sweep: the sphere it collides by, times `visibility`.
        radius: f32 = 0,
        /// Where its sphere reaches along X, which the entries sort by.
        far: f32 = 0,
    };

    fn add(sweep: *Sweep, index: u16, object: *const gameobj.GameObject) void {
        const radius = object.radius * object.visibility;
        sweep.entries[sweep.count] = .{
            .index = index,
            .radius = radius,
            .far = object.root.next_position.x + radius,
        };
        sweep.order[sweep.count] = sweep.count;
        sweep.count += 1;
    }

    /// The far end of an entry's extent, which they sort by, the farthest first.
    fn farthestFirst(entries: []const Entry, a: u16, b: u16) bool {
        return entries[a].far > entries[b].far;
    }

    fn run(sweep: *Sweep, world: gameobj.World) void {
        const all = world.objects;
        for (0..passes) |pass| {
            std.mem.sort(u16, sweep.order[0..sweep.count], sweep.entries[0..sweep.count], farthestFirst);
            var moved = false;
            for (0..sweep.count) |first| {
                const near = sweep.entries[sweep.order[first]];
                const object = &all.slots[near.index].object;
                const back = object.root.next_position.x - near.radius;
                for (sweep.order[first + 1 .. sweep.count]) |entry| {
                    const far = sweep.entries[entry];
                    // Past the first entry that cannot reach back this far, neither can any after
                    // it.
                    if (far.far < back) break;
                    if (!meets(all, near.index, far.index)) continue;
                    if (!collision.collide(world, near.index, far.index, @intCast(pass))) continue;
                    moved = true;
                    // Both have been moved, so their extents are worked out again for the pass
                    // that follows.
                    sweep.entries[sweep.order[first]].far = object.root.next_position.x + near.radius;
                    sweep.entries[entry].far = all.slots[far.index].object.root.next_position.x + far.radius;
                }
            }
            if (!moved) break;
        }
    }

    /// Whether the two objects are near enough to collide and not a pair that passes through: each
    /// object names up to two slots it goes through, which a launch and the Ripper set.
    fn meets(all: *const Objects, first: u16, second: u16) bool {
        const near = &all.slots[first].object;
        const far = &all.slots[second].object;
        for (near.passes_through) |through| if (through.index() == second) return false;
        for (far.passes_through) |through| if (through.index() == first) return false;
        return near.overlaps(far, 0);
    }
};

/// `object_collect_components` (`0x00468760`): lists the parts of the object's model that count as
/// components, a node's marked children before their own subtrees, which is the order missions,
/// triggers and the display name them by. The parts of the models mounted on a part follow it, so
/// a turret's own components come after the hull's. Each one is marked on its part, and a part the
/// model marks as targetable becomes targetable.
///
/// The game stops with a fatal error past `max_components`; OpenReliant leaves the rest unlisted,
/// since nothing can name them.
pub fn collectComponents(slot: *Slot) void {
    const model = if (slot.model) |*live| live else return;
    slot.object.component_count = 0;
    collectFrom(slot, model, null);
}

/// The parts of `model` hanging from `parent`, or from its root for null: the marked ones, then
/// each part's own children and whatever stands mounted on it.
fn collectFrom(slot: *Slot, model: *objects.Model, parent: ?usize) void {
    for (model.parts) |*part| {
        if (part.parent != parent or !part.flags.component) continue;
        if (slot.object.component_count >= gameobj.max_components) return;
        slot.components[@intCast(slot.object.component_count)] = part;
        slot.object.component_count += 1;
        part.component = true;
        if (part.flags.targetable) part.targetable = true;
    }
    for (model.parts, 0..) |part, index| {
        if (part.parent != parent) continue;
        collectFrom(slot, model, index);
        for (model.mounts) |*mount| {
            if (mount.part != index) continue;
            collectFrom(slot, &mount.model, null);
        }
    }
}

/// How far `create_object` has a part's `startup` track move on each simulation step.
const startup_speed: f32 = 4;

/// What `create_object` starts on each part it adds: the part's `startup` track, from its start,
/// as the track says to play it, at 4 a step. The parts are linked after, so each starts from
/// where its `startup` track has it.
pub fn startUp(model: *objects.Model) void {
    for (model.parts, 0..) |part, index| {
        if (part.animation.tracks.len > 0) model.play(index, .startup, 0, null, startup_speed);
    }
}

/// Fixtures for the tests here and in the modules that use the objects.
pub const testing = struct {
    /// A model of one part, to create objects of: a mesh and a level, and a part of mass 6.
    pub const Model = struct {
        mesh: @import("../surrender/surrenderlib/srapiext.zig").Mesh,
        levels: [1]@import("../surrender/surrenderlib/srapiext.zig").Level,
        loaded_parts: [1]srofiles.LoadedPart,
        data: [1]shp.PartData,
        source: shp.Model,
        loaded: srofiles.Loaded,
        type: Type,
        /// A collision tree of one leaf over the part's two faces, which `withHull` hands the
        /// part, and the file's own record of those faces, which the tree's leaf names.
        nodes: [1]shp.TreeNode,
        faces: [2]u32,
        node_faces: [1][]u32,
        vertices: [4]shp.Vertex,
        triangles: [2]shp.Face,
        level: [1]shp.Mesh,

        /// Fills in every field, so a field added here has to be filled in too.
        pub fn init(model: *Model, gpa: Allocator) !void {
            const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
            model.* = .{
                .mesh = try srmesh.testing.square(gpa),
                .levels = undefined,
                .loaded_parts = undefined,
                .data = .{objects.testing.part()},
                .source = undefined,
                .loaded = undefined,
                .type = undefined,
                .nodes = .{.{
                    ._unknown_00 = 0,
                    .orientation = math.identity,
                    .half_size = .{ .x = 100, .y = 100, .z = 10 },
                    .centre = .{ .x = 0, .y = 0, .z = 0 },
                    .children = .{ -1, -1 },
                }},
                .faces = .{ 0, 1 },
                .node_faces = undefined,
                .vertices = undefined,
                .triangles = undefined,
                .level = undefined,
            };
            // The square the test mesh draws, as the file holds it: two triangles facing -Z.
            const square = [_]shp.Vec3{
                .{ .x = -100, .y = -100, .z = 0 },
                .{ .x = 100, .y = -100, .z = 0 },
                .{ .x = 100, .y = 100, .z = 0 },
                .{ .x = -100, .y = 100, .z = 0 },
            };
            for (&model.vertices, square) |*vertex, at| {
                vertex.* = std.mem.zeroes(shp.Vertex);
                vertex.position = at;
            }
            for (&model.triangles, [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 3, 2 } }) |*face, corners| {
                face.* = std.mem.zeroes(shp.Face);
                face.vertices = corners;
                face.normal = .{ .x = 0, .y = 0, .z = -1 };
            }
            model.level = .{.{ .lod = std.mem.zeroes(shp.Lod), .vertices = &model.vertices, .faces = &model.triangles, .materials = &.{} }};
            model.data[0].meshes = &model.level;
            // What points at the rest of the fixture, once it stands where it will stay.
            model.levels = .{.{ .mesh = &model.mesh, .until = std.math.inf(f32) }};
            model.loaded_parts = .{.{ .flags = .{}, .levels = &model.levels, .meshes = &.{} }};
            model.node_faces = .{&model.faces};
            model.data[0].part.volume = 2;
            model.data[0].part.density = 3;
            model.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &model.data, .trailing_bytes = 0 };
            model.loaded = .{ .parts = &model.loaded_parts };
            model.type = .{ .model = &model.source, .loaded = &model.loaded };
        }

        /// Gives the part its collision tree, which a hull's objects are tested against.
        pub fn withHull(model: *Model) void {
            model.data[0].nodes = &model.nodes;
            model.data[0].node_faces = &model.node_faces;
        }

        /// Lets the model cloak, its part shimmering with `image` (`srofiles.Cloaking`).
        pub fn withCloak(model: *Model, gpa: Allocator, image: *@import("../surrender/surrenderlib/srtexture.zig").Image) Allocator.Error!void {
            model.source.header.flags.cloak = true;
            model.loaded_parts[0].cloaking = try .build(gpa, &model.levels, image, true);
        }

        pub fn deinit(model: *Model, gpa: Allocator) void {
            if (model.loaded_parts[0].cloaking) |cloaking| cloaking.deinit(gpa);
            model.mesh.deinit(gpa);
        }

        /// Answers every ship type with the one model.
        pub fn types(model: *Model) Types {
            return .{ .context = model, .load = load };
        }

        fn load(context: *anyopaque, ship_type: u8) ?*const Type {
            _ = ship_type;
            const model: *Model = @ptrCast(@alignCast(context));
            return &model.type;
        }
    };

    /// Types with no model at all.
    pub const no_models: Types = .{ .context = @constCast(&{}), .load = noModel };

    fn noModel(context: *anyopaque, ship_type: u8) ?*const Type {
        _ = context;
        _ = ship_type;
        return null;
    }

    /// The tables with a fighter's figures for every type.
    pub fn tables() Stats {
        var made: Stats = .initial;
        for (&made.flight) |*flight| flight.* = gameobj.testing.flight;
        for (&made.combat) |*record| {
            record.shield_power = 8;
            record.armor_class = 5;
            record.afterburner_fuel = 60;
            record.shield_recharge = 10;
            record.gun_energy = 100;
        }
        return made;
    }
};

/// `0x004688E0`: what the Explode order leaves of an object once it has blown up. It stands in
/// where it was, of type `stand_in`, as flagged as a slot's stand-in and exploding, and with no
/// orders. Nothing moves, draws, collides with or targets it. **Unverified:** it lies after
/// `object_reset`, before this file's known code.
///
/// Not ported: the `exit` routines popping its orders would run, none of which is ported yet
/// ([#30](https://github.com/vdmkenny/openreliant/issues/30)).
pub fn retire(ctx: aigeneric.Context, index: u16) void {
    const object = &ctx.world.objects.slots[index].object;
    object.type = .stand_in;
    object.flags = object.flags.with(.standing_in);
    object.flags.exploding = true;
    object.flags.targetable = false;
    aigeneric.popAll(ctx, index);
}

test wreckMade {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var rays: @import("erayfx.zig").testing.Built = try .init(gpa);
    defer rays.deinit(gpa);
    var world = stage.world();
    world.rays = &rays.rays;

    // A Badanov's half shows its part, and burns for good, lit and smoking.
    const index = try stage.mission.add(.badanov_wreck_back, @splat(0));
    const slot = stage.mission.slot(index);
    var burning: explode.testing.Burning = undefined;
    try burning.init(gpa, "Bad dead back");
    defer burning.deinit(gpa);
    burning.put(slot);
    defer burning.take(slot);
    wreckMade(world, index);
    try std.testing.expect(!burning.parts[0].hidden);
    try std.testing.expect(rays.rays.slots[0].?.flags.flickers);
    try std.testing.expect(stage.explosions.burn_lights[0] != null);

    // Another type burns nothing.
    try std.testing.expectEqual(null, wreckOf(.badanov));
    try std.testing.expectEqualStrings("Box07", wreckOf(.kurgan_wreck).?.part);
}

test retire {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const object = &mission.objects.slots[index].object;
    object.flags.targetable = true;
    try std.testing.expect(try aigeneric.push(ctx, index, .do_nothing, .none));
    retire(ctx, index);
    try std.testing.expectEqual(gameobj.Type.stand_in, object.type);
    try std.testing.expect(object.flags.stand_in and object.flags.no_collisions and object.flags.exploding);
    try std.testing.expect(!object.flags.targetable);
    try std.testing.expectEqual(0, object.order_count);
}

test "a mission starts with every slot standing in" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    try std.testing.expectEqual(0, all.count);
    for (all.slots) |slot| {
        try std.testing.expect(slot.object.flags.stand_in and !slot.object.created);
        try std.testing.expectEqual(gameobj.Type.stand_in, slot.object.type);
    }
    // With nothing handed out, the loops walk the cutaway slot alone.
    var walk = all.walk();
    try std.testing.expectEqual(cutaway_slot, walk.next().?);
    try std.testing.expectEqual(null, walk.next());
}

test "the loops walk the slots handed out, then the cutaway slot" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    all.count = 3;
    var walked: std.ArrayList(u16) = .empty;
    defer walked.deinit(std.testing.allocator);
    var walk = all.walk();
    while (walk.next()) |index| {
        try walked.append(std.testing.allocator, index);
        // An object created on the way is walked as well.
        if (index == 1 and all.count == 3) all.count = 4;
    }
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3, cutaway_slot }, walked.items);
    // With every slot handed out, the cutaway slot is walked once, as the last.
    all.count = gameobj.max_objects;
    walk = all.walk();
    var count: usize = 0;
    var last: u16 = 0;
    while (walk.next()) |index| {
        count += 1;
        last = index;
    }
    try std.testing.expectEqual(gameobj.max_objects, count);
    try std.testing.expectEqual(cutaway_slot, last);
}

test collectComponents {
    const gpa = std.testing.allocator;
    // Four parts: one plain at the root, one component at the root, and a component under each.
    var data: [4]shp.PartData = @splat(objects.testing.part());
    const parents = [_]i32{ -1, -1, 1, 0 };
    const marked = [_]bool{ false, true, true, true };
    for (&data, parents, marked) |*part, parent, is_component| {
        part.part.parent = parent;
        part.part.flags.component = is_component;
    }
    data[2].part.flags.targetable = true;
    var loaded_parts: [4]srofiles.LoadedPart = @splat(.{ .flags = .{}, .levels = &.{}, .meshes = &.{} });
    const source: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &data, .trailing_bytes = 0 };
    const loaded: srofiles.Loaded = .{ .parts = &loaded_parts };
    var kind: Type = .{ .model = &source, .loaded = &loaded };

    var slot: Slot = .{ .object = std.mem.zeroes(gameobj.GameObject) };
    slot.model = try objects.Model.create(gpa, &source, &loaded, .{});
    defer slot.model.?.deinit(gpa);
    slot.type = &kind;

    collectComponents(&slot);
    // The root's marked children come first, then each child's own: part 1, then 0's child 3, then
    // 1's child 2.
    try std.testing.expectEqual(3, slot.object.component_count);
    // The root's marked child first, then part 0's child and part 1's.
    for (slot.components[0..3], [_]usize{ 1, 3, 2 }) |listed, part| {
        try std.testing.expectEqual(&slot.model.?.parts[part], listed.?);
    }
    for ([_]usize{ 1, 2, 3 }) |part| try std.testing.expect(slot.model.?.parts[part].component);
    try std.testing.expect(!slot.model.?.parts[0].component);
    // Only the part the model marks is targetable.
    try std.testing.expect(slot.model.?.parts[2].targetable);
    try std.testing.expect(!slot.model.?.parts[1].targetable);

    // A model of nothing but components lists no more than the object holds.
    var many: [gameobj.max_components + 4]shp.PartData = @splat(objects.testing.part());
    var many_loaded: [gameobj.max_components + 4]srofiles.LoadedPart = @splat(.{ .flags = .{}, .levels = &.{}, .meshes = &.{} });
    for (&many) |*part| {
        part.part.parent = -1;
        part.part.flags.component = true;
    }
    const crowded: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &many, .trailing_bytes = 0 };
    const crowded_loaded: srofiles.Loaded = .{ .parts = &many_loaded };
    var crowded_kind: Type = .{ .model = &crowded, .loaded = &crowded_loaded };
    slot.model.?.deinit(gpa);
    slot.model = try objects.Model.create(gpa, &crowded, &crowded_loaded, .{});
    slot.type = &crowded_kind;
    collectComponents(&slot);
    try std.testing.expectEqual(gameobj.max_components, slot.object.component_count);
}

test "Objects.slotType" {
    var random: libcmt.Rand = .{};
    const all = try Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    // With no loadout, the player's slot takes the mission's own kind; other slots always do.
    try std.testing.expectEqual(gameobj.Type.grendel, all.slotType(0, .grendel));
    all.loadout_ships[0] = .reaper;
    try std.testing.expectEqual(gameobj.Type.reaper, all.slotType(0, .grendel));
    try std.testing.expectEqual(gameobj.Type.sabre, all.slotType(1, .sabre));
    // From the 14th mission on the loadout's twin, and in mission 25's first part a Kamov.
    all.mission_number = twins_from_mission;
    try std.testing.expectEqual(gameobj.Type.reaper.twin().?, all.slotType(0, .grendel));
    all.mission_number = kamov_mission;
    try std.testing.expectEqual(gameobj.Type.kamov, all.slotType(0, .grendel));
    all.mission25_second_part = true;
    try std.testing.expectEqual(gameobj.Type.reaper.twin().?, all.slotType(0, .grendel));
}

test settledTier {
    // A fighter asked for 0 or 255 takes the campaign's tier; asked for 4 or 5, tier 0.
    try std.testing.expectEqual(2, settledTier(0, .predator, 2));
    try std.testing.expectEqual(2, settledTier(255, .predator, 2));
    try std.testing.expectEqual(0, settledTier(4, .predator, 2));
    try std.testing.expectEqual(0, settledTier(5, .predator, 2));
    try std.testing.expectEqual(3, settledTier(3, .predator, 2));
    // What isn't a fighter keeps what it was asked for.
    try std.testing.expectEqual(0, settledTier(0, .sabre, 2));
}

test hardpoints {
    const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
    var points: [2]shp.Attachment = @splat(std.mem.zeroes(shp.Attachment));
    for (&points) |*point| point.kind = .missile;
    const shown: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 0, .levels = &.{} };
    var parts = [_]objects.Model.Part{
        .{ .hidden = false, .parent = null, .origin = @splat(0), .object = shown, .attachments = points[0..1] },
        .{ .hidden = false, .parent = 0, .origin = @splat(0), .object = shown, .attachments = points[1..2] },
    };
    const model: objects.Model = .{ .parts = &parts, .order = &.{}, .lights = &.{}, .glows = &.{}, .mounts = &.{} };

    // A part linked to another is in the root's child list as well, and its hardpoints are walked.
    var each = hardpoints(&model);
    try std.testing.expectEqual(0, each.next().?.part);
    try std.testing.expectEqual(1, each.next().?.part);
    try std.testing.expectEqual(null, each.next());
    // One taken out of the model is not.
    parts[1].removed = true;
    each = hardpoints(&model);
    try std.testing.expectEqual(0, each.next().?.part);
    try std.testing.expectEqual(null, each.next());
}

test "a ship's racks are fitted by its tier" {
    const gpa = std.testing.allocator;
    var random: libcmt.Rand = .{};
    const all = try Objects.create(gpa, &random);
    defer all.destroy();
    var tables = testing.tables();
    var model: testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    // Four hardpoints: for tier 0 a Screamer pod, a Havoc, none, and a Raptor after the gap; for
    // tier 1 a fuel pod first. A light among them is passed over.
    var points: [5]shp.Attachment = @splat(std.mem.zeroes(shp.Attachment));
    for (&points, [_]u32{ 0, 2, 0xFFFF, 1, 0 }) |*point, id| {
        point.kind = .missile;
        point.id = id;
    }
    points[0].later_tiers[0] = 10;
    points[2].kind = .light;
    points[2].id = 0;
    points[3].id = 0xFFFF;
    points[4].id = 1;
    model.data[0].attachments = &points;
    // Every model a hardpoint holds is the fixture's own part.
    const Loader = struct {
        fn load(context: *anyopaque, _: []const u8) ?objects.Mounts.Mounted {
            const fixture: *testing.Model = @ptrCast(@alignCast(context));
            return .{ .model = &fixture.source, .loaded = &fixture.loaded };
        }
    };
    model.type.effects.mounts = .{ .context = &model, .load = Loader.load };
    var index = try createObject(all, &tables, model.types(), null, .predator, 0, @splat(0), &random);
    var object = &all.slots[index].object;
    // The gap ends the loadout: the Raptor after it stays off.
    try std.testing.expectEqual(2, object.rack_count);
    try std.testing.expectEqual(missiles.Type.screamer, object.racks[0].type);
    try std.testing.expectEqual(20, object.racks[0].count);
    try std.testing.expectEqual(missiles.Type.havoc, object.racks[1].type);
    try std.testing.expectEqual(1, object.racks[1].count);
    const hung = all.slots[index].model.?.hung;
    try std.testing.expect(hung[0] != null and hung[1] != null and hung[2] == null);

    // At tier 1, the first holds a fuel pod, which adds to the afterburner's fuel.
    all.campaign_tier = 1;
    const fuel = object.afterburner_fuel;
    index = try createObject(all, &tables, model.types(), null, .predator, 0, @splat(0), &random);
    object = &all.slots[index].object;
    try std.testing.expectEqual(missiles.Type.fuel_pod, object.racks[0].type);
    try std.testing.expectEqual(fuel + fuel_pod_fuel, object.afterburner_fuel);
}

test createObject {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    var model: testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    mission.tables.combat[0x2B].side = .hostile;

    // The player first, in the next slot, at rest where it is put and facing along Z.
    const player = try createObject(all, &mission.tables, model.types(), null, .predator, 0, .{ 0, 0, 500 }, &mission.random);
    try std.testing.expectEqual(0, player);
    try std.testing.expectEqual(1, all.count);
    const made = &all.slots[player];
    const object = &made.object;
    try std.testing.expect(object.created and !object.flags.stand_in);
    try std.testing.expectEqual(math.Vector{ 0, 0, 500 }, gameobj.vector(object.root.position));
    try std.testing.expectEqual(math.identity, object.root.orientation);
    try std.testing.expectEqual(motion.Motion.forward, made.motion.?);
    try std.testing.expectEqual(1, all.types[0].objects);
    try std.testing.expectEqual(.friendly, object.side);
    try std.testing.expectEqual(0, object.pilot);
    // Undamaged: each quadrant six times the type's figure, less one.
    try std.testing.expectEqual(gameobj.Quadrants.all(47), object.shields);
    try std.testing.expectEqual(gameobj.Quadrants.all(29), object.armor);
    try std.testing.expectEqual(1, object.shield_condition);
    try std.testing.expectEqual(6000, object.afterburner_fuel);
    try std.testing.expectEqual(100, object.gun_charge);
    try std.testing.expectEqual(gameobj.countermeasures_when_created, object.countermeasures);
    try std.testing.expectEqual([2]gameobj.Slot{ .none, .none }, object.passes_through);
    // Its model's one part, and the mass `object_recentre` put in the record.
    try std.testing.expectEqual(1, made.model.?.parts.len);
    try std.testing.expectEqual(6, object.mass);
    // The player's slot has no ECM on; every other slot's does.
    try std.testing.expect(!object.flags.ecm);

    // A Coalition fighter: hostile, flown by the Coalition's pilot, with its ECM on.
    const enemy = try createObject(all, &mission.tables, model.types(), null, .sabre, 0, .{ 0, 0, 0 }, &mission.random);
    try std.testing.expectEqual(.hostile, all.slots[enemy].object.side);
    try std.testing.expectEqual(coalition_pilot, all.slots[enemy].object.pilot);
    try std.testing.expect(all.slots[enemy].object.flags.ecm);

    // A slot filled once is not filled again, and nothing lies past the last.
    try std.testing.expectError(error.CreatedTwice, createObject(all, &mission.tables, model.types(), player, .predator, 0, @splat(0), &mission.random));
    try std.testing.expectError(error.Overrun, createObject(all, &mission.tables, model.types(), gameobj.max_objects, .predator, 0, @splat(0), &mission.random));

    // Above the last ship type, a stand-in for a marker, at a slot of its own.
    const marker = try createObject(all, &mission.tables, model.types(), 20, @enumFromInt(1000), 0, @splat(0), &mission.random);
    try std.testing.expectEqual(20, marker);
    try std.testing.expectEqual(2, all.count);
    const stand_in = all.slots[marker];
    try std.testing.expectEqual(GameObject.Flags.standing_in, stand_in.object.flags);
    try std.testing.expectEqual(stand_in_radius, stand_in.object.radius);
    try std.testing.expectEqual(null, stand_in.model);
    try std.testing.expectEqual(null, stand_in.combat);

    // Reset, the slot stands in again, and can be filled anew.
    all.resetSlot(player, &mission.random);
    try std.testing.expectEqual(GameObject.Flags.standing_in, all.slots[player].object.flags);
    try std.testing.expectEqual(null, all.slots[player].model);
    _ = try createObject(all, &mission.tables, model.types(), player, .predator, 0, @splat(0), &mission.random);
}

test "an object is created with the guns its model holds" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    var model: testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    // Two muzzles of one type, one either side of the nose.
    var muzzles: [2]shp.Attachment = @splat(std.mem.zeroes(shp.Attachment));
    for (&muzzles, [_]f32{ -100, 100 }) |*muzzle, x| {
        muzzle.kind = .gun_muzzle;
        muzzle.gun_type = 1;
        muzzle.position = .{ .x = x, .y = 0, .z = 0 };
    }
    model.data[0].attachments = &muzzles;

    const index = try createObject(all, &mission.tables, model.types(), null, @enumFromInt(7), 0, @splat(0), &mission.random);
    const slot = &all.slots[index];
    // The guns are fitted after the count is cleared, so the object holds them all.
    try std.testing.expectEqual(2, slot.object.gun_count);
    try std.testing.expectEqual(2, slot.guns.len);
    // They make one group, whose two guns fire in turn as its left and right.
    try std.testing.expectEqual(1, mission.tables.combat[7].gun_groups);
    try std.testing.expectEqual(&all.gun_groups[7], slot.gun_groups);
    try std.testing.expectEqual(0, slot.gun_groups[0].first);
    try std.testing.expectEqual(1, slot.gun_groups[0].second);
    try std.testing.expectEqual(guns.GroupSide.first, slot.guns[0].side);
    try std.testing.expectEqual(guns.GroupSide.second, slot.guns[1].side);
    // One group of guns fires them in step (`GunMode.created`).
    try std.testing.expect(slot.object.gun_mode.synchronised);
    try std.testing.expect(!slot.object.gun_mode.all);
}

test "a type under another number takes its stats, then its number" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    mission.tables.flight[0x21].max_speed = 55;
    mission.tables.combat[0x21].shield_power = 30;
    mission.tables.combat[0xE5].name = 1123;
    mission.tables.combat[0xE5].gun_groups = 2;
    const index = try mission.add(@enumFromInt(0xE5), @splat(0));
    const slot = all.slots[index];
    try std.testing.expectEqual(0x21, slot.object.type.number());
    try std.testing.expectEqual(55, slot.flight.?.max_speed);
    try std.testing.expectEqual(30, slot.combat.?.shield_power);
    // Its own name and guns stay.
    try std.testing.expectEqual(1123, slot.combat.?.name);
    try std.testing.expectEqual(2, slot.combat.?.gun_groups);
    // The table it points into is its own number's, which now holds the other's stats.
    try std.testing.expectEqual(&mission.tables.combat[0xE5], slot.combat.?);
    try std.testing.expectEqual(null, donor(0x21));
}

test "a type with no model still flies" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const index = try mission.add(@enumFromInt(3), @splat(0));
    try std.testing.expectEqual(null, all.slots[index].model);
    all.slots[index].object.throttle = 1;
    all.slots[index].object.rotation = math.identity;
    objectsUpdate(mission.world());
    try std.testing.expect(all.slots[index].object.root.flags.next_pending);
    try std.testing.expect(all.slots[index].object.velocity.z > 0);
}

test objectsUpdate {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    for (0..3) |_| _ = try mission.add(.predator, @splat(0));
    all.slots[1].object.flags.disabled = true;
    all.slots[2].object.flags.frozen = true;
    // Each drifting, with no motion of its own.
    for (all.slots[0..3]) |*slot| {
        slot.object.velocity = .{ .x = 0, .y = 0, .z = 10 };
        slot.motion = null;
    }
    objectsUpdate(mission.world());
    // The first moves on; the disabled and the frozen ones stay where they are.
    try std.testing.expectEqual(10, all.slots[0].object.root.next_position.z);
    try std.testing.expectEqual(0, all.slots[1].object.root.next_position.z);
    try std.testing.expectEqual(0, all.slots[2].object.root.next_position.z);
}

test "the sweep pushes apart the objects that meet" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const world = mission.world();

    // Three ships in a row, the first two of them overlapping, each 1000 units across and drifting
    // nowhere.
    const places = [_]math.Vector{ .{ -200, 0, 0 }, .{ 200, 0, 0 }, .{ 20000, 0, 0 } };
    for (places) |at| {
        const index = try mission.add(.predator, at);
        all.slots[index].object.radius = 1000;
        all.slots[index].motion = null;
    }

    objectsUpdate(world);
    // The pair is set apart, and the ship far off is left where it was.
    try std.testing.expectApproxEqAbs(-1100, all.slots[0].object.root.position.x, 0.01);
    try std.testing.expectApproxEqAbs(1100, all.slots[1].object.root.position.x, 0.01);
    try std.testing.expectEqual(20000, all.slots[2].object.root.position.x);
    try std.testing.expectEqual(3, all.sweep.count);

    // A pair that passes through each other is left alone, and so is an object that collides with
    // nothing.
    objects.setPosition(&all.slots[0].object, &all.slots[0].drawn, .{ -200, 0, 0 });
    objects.setPosition(&all.slots[1].object, &all.slots[1].drawn, .{ 200, 0, 0 });
    all.slots[0].object.passes_through[0] = .of(1);
    objectsUpdate(world);
    try std.testing.expectEqual(-200, all.slots[0].object.root.position.x);

    all.slots[0].object.passes_through[0] = .none;
    all.slots[1].object.flags.no_collisions = true;
    objectsUpdate(world);
    try std.testing.expectEqual(-200, all.slots[0].object.root.position.x);
    try std.testing.expectEqual(2, all.sweep.count);
}

test "the tables hold the executable's words until the file fills in the figures" {
    const initial: Stats = .initial;
    // The Reliant, a capital ship of the player's side that can be targeted.
    try std.testing.expectEqual(.capital, initial.combat[0x0C].class);
    try std.testing.expectEqual(.friendly, initial.combat[0x0C].side);
    try std.testing.expect(initial.combat[0x0C].targeting.targetable);
    // The Sabre, a Coalition fighter.
    try std.testing.expectEqual(.fighter, initial.combat[0x2B].class);
    try std.testing.expectEqual(.hostile, initial.combat[0x2B].side);
    try std.testing.expectEqual(0, initial.combat[0x2B].shield_power);
    // The capital ships turn flat, and the fighters bank.
    try std.testing.expectEqual(.flat, initial.flight[0x0C].turns);
    try std.testing.expectEqual(.banking, initial.flight[0x2B].turns);

    var ship = std.mem.zeroes(stats.Ship);
    ship.max_speed = 320;
    ship.pitch_rate = 2;
    ship.shield_power = 8.9;
    var tables: Stats = .initial;
    tables.load((&ship)[0..1]);
    try std.testing.expectEqual(8, tables.combat[0].shield_power);
    try std.testing.expectEqual(stats.Ship.default_shield_recharge, tables.combat[0].shield_recharge);
    try std.testing.expectEqual(160, tables.flight[0].speed_per_pitch_rate);
    // The file's figures leave the executable's words alone.
    try std.testing.expectEqual(initial.combat[0].name, tables.combat[0].name);
    try std.testing.expectEqual(initial.flight[0].turns, tables.flight[0].turns);
}

test {
    std.testing.refAllDecls(@This());
}
