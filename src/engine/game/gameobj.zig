//! `C:\lancer\game\gameobj.cpp`: the game's live objects, the ships, stations, gates, missiles and
//! markers of a running mission. `object_alloc` (`0x00475DD0`) allocates one.
//!
//! `create_object` (`0x00466C10`) fills a slot of `game_objects`, which it calls the GO array: 400
//! pointers to objects, a mission ship's slot being its index among the mission's ship records.
//! [`create.Objects`](create.zig) is OpenReliant's. Each object embeds the root of a hierarchy of
//! nodes, one for each part of its model.

const std = @import("std");
const assert = std.debug.assert;

const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const camera = @import("camera.zig");
const engine = @import("../../engine.zig");
const aigeneric = @import("aigeneric.zig");
const objects = @import("objects.zig");
const Node = objects.Node;
const Pointer = engine.Pointer;
const create = @import("create.zig");
const guns = @import("guns.zig");
const missiles = @import("missiles.zig");
const libcmt = @import("../libcmt.zig");
const motion = @import("motion.zig");
const input = @import("../input.zig");
const Clock = @import("main.zig").Clock;
const collision = @import("collision.zig");

/// A slot of the object array as an object names one, or `none` for no slot, which the game holds
/// as -1.
pub const Slot = enum(i32) {
    none = -1,
    _,

    pub fn of(slot: u16) Slot {
        return @enumFromInt(slot);
    }

    /// The slot `index` names, or none.
    pub fn from(found: ?u16) Slot {
        return if (found) |slot| of(slot) else .none;
    }

    /// The slot it names, or null for none.
    pub fn index(slot: Slot) ?u16 {
        return if (slot == .none) null else @intCast(@intFromEnum(slot));
    }
};

/// One of the positional voices (`hog_snd.Sound.voices3d`) as an object names the one following
/// it, or `none`, which the game holds as `0xFFFF`.
pub const Voice = enum(u16) {
    none = 0xFFFF,
    _,

    pub fn of(voice: u8) Voice {
        return @enumFromInt(voice);
    }

    /// The voice it names, or null for none.
    pub fn index(voice: Voice) ?u8 {
        return if (voice == .none) null else @intCast(@intFromEnum(voice));
    }
};

test Voice {
    try std.testing.expectEqual(null, Voice.none.index());
    try std.testing.expectEqual(3, Voice.of(3).index());
}

/// Code that acts for the object in a slot: its `motion`, which moves it for one update, such as
/// `motion_forward` (`0x004744C0`), which flies it forward by the flight model, and the routines
/// of its orders.
pub const Routine = engine.Code("void __fastcall (int slot)");

/// Slots in `game_objects`. `create_object` stops the game with a fatal error past the last.
pub const max_objects = 400;

/// Whose side something is on: an object's (`GameObject.side`, four bytes) and a ship type's
/// (`create.ShipCombat.side`, two). The Alliance's types start friendly and the Coalition's
/// hostile; `SetHostile` makes an object one or the other. Two objects on different sides are
/// enemies.
pub fn Side(comptime Tag: type) type {
    return enum(Tag) {
        /// On the player's side.
        friendly = 0,
        hostile = 1,
        neutral = 2,
        _,
    };
}

/// How far harm reaches an object (`GameObject.invulnerable`). The first four are the values
/// `SetInvulnerability`'s catalogue entry lists; the game sets the last two itself. Any but `none`
/// keeps its armour whole (`collision.armorDamage`).
pub const Invulnerability = enum(u8) {
    none = 0,
    /// Only a player's ship can harm it: an ejected pilot, until it is picked up
    /// (`order_eject_spin`).
    player_can_hit = 1,
    /// Nothing harms it: what the Ripper has grabbed, and some types as they are created.
    full = 2,
    /// Its pilot ejects before it explodes.
    eject_before_exploding = 3,
    /// **Unknown.** Set as some types are created and as a deathmatch ship respawns. Shots pass its
    /// shields to the hull (`guns.bulletHit`).
    _unknown_4 = 4,
    /// **Unknown.** Its shields are emptied each step (`rechargeShields`), shots pass them to the
    /// hull, and a shield generator does not soften a component's hits.
    _unknown_5 = 5,
    _,

    /// Whether it keeps off a hit: always under `full`, and under `player_can_hit` where a player's
    /// ship did not deal it.
    pub fn protects(invulnerable: Invulnerability, by_player: bool) bool {
        return switch (invulnerable) {
            .full => true,
            .player_can_hit => !by_player,
            else => false,
        };
    }
};

test "Invulnerability.protects" {
    try std.testing.expect(Invulnerability.full.protects(true));
    try std.testing.expect(Invulnerability.player_can_hit.protects(false));
    try std.testing.expect(!Invulnerability.player_can_hit.protects(true));
    try std.testing.expect(!Invulnerability.none.protects(false));
}

/// A deathmatch power-up (`GameObject.power_up`): its record of 0x28 bytes in the table at
/// `0x0050C510`, which gives how long it lasts and the routines that start and end it. `0x004B1C00`
/// hands one out, by the weights at `0x005DB4C4` where none is named, and `0x004B18E0` ends it
/// once it runs out. **Unknown:** what most of them do.
pub const PowerUp = enum(i32) {
    none = -1,
    /// **Unknown.** In a multiplayer game, `0x00412820` and `0x00491520` act differently while the
    /// player holds it.
    _unknown_5 = 5,
    /// The player's throttle goes no higher than half (`player_controls`).
    half_throttle = 7,
    /// Its shields don't recharge (`rechargeShields`).
    no_shield_recharge = 8,
    /// The player's controls steer the other way round (`player_controls`).
    reversed_controls = 9,
    _,
};

/// A value for each quadrant of an object's shields or armour (`collision.Quadrant`), in the order
/// the game keeps them.
pub const Quadrants = extern struct {
    left: f32,
    right: f32,
    fore: f32,
    aft: f32,

    /// The same value in each.
    pub fn all(value: f32) Quadrants {
        return .{ .left = value, .right = value, .fore = value, .aft = value };
    }

    pub fn get(quadrants: Quadrants, quadrant: collision.Quadrant) f32 {
        return switch (quadrant) {
            inline else => |named| @field(quadrants, @tagName(named)),
        };
    }

    pub fn at(quadrants: *Quadrants, quadrant: collision.Quadrant) *f32 {
        return switch (quadrant) {
            inline else => |named| &@field(quadrants, @tagName(named)),
        };
    }

    /// Each, in the game's order.
    pub fn values(quadrants: Quadrants) [4]f32 {
        return .{ quadrants.left, quadrants.right, quadrants.fore, quadrants.aft };
    }

    /// The least of the four.
    pub fn weakest(quadrants: Quadrants) f32 {
        const each = quadrants.values();
        return @reduce(.Min, @as(@Vector(each.len, f32), each));
    }

    /// The four added together.
    pub fn total(quadrants: Quadrants) f32 {
        const each = quadrants.values();
        return @reduce(.Add, @as(@Vector(each.len, f32), each));
    }

    comptime {
        for (std.enums.values(collision.Quadrant), @typeInfo(Quadrants).@"struct".fields) |quadrant, field| {
            assert(std.mem.eql(u8, @tagName(quadrant), field.name));
            assert(@offsetOf(Quadrants, field.name) == @as(usize, @intFromEnum(quadrant)) * @sizeOf(f32));
        }
        assert(@sizeOf(Quadrants) == 0x10);
    }
};

/// Components an object can list.
pub const max_components = 60;

/// A part of an object that events and scripts can name by its index in `GameObject.components`,
/// such as a capital ship's turret: a trigger's qualifier, a squad member's component.
pub const Component = extern struct {
    node: Pointer(Node),
    /// Where the node's parent lists it.
    slot: Pointer(Pointer(Node)),
    /// Nonzero while the component is invulnerable: `SetInvulnerability` on the component.
    invulnerable: u16,
    _unknown_0a: u16,

    comptime {
        assert(@sizeOf(Component) == 0x0C);
    }
};

/// Missile racks an object can carry: one for each of its missile hardpoints.
pub const max_racks = 20;

/// One of an object's missile racks (`GameObject + 0x158`): what a missile hardpoint of its model
/// holds, a pod of missiles or one missile hung on a rail, and how many are left.
pub const Rack = extern struct {
    type: missiles.Type,
    _unknown_02: u16 = 0,
    /// Where the node of the part that carries the hardpoint lists the hung pod or missile.
    slot: Pointer(Pointer(Node)) = .null,
    /// Missiles left: a pod's capacity, or 1 for a rail, when fitted; -1 once an empty pod is let
    /// fall.
    count: i32 = 0,

    comptime {
        assert(@sizeOf(Rack) == 0x0C);
    }
};

/// Flags for the multiplayer code about an object (`GameObject + 0x0C`).
pub const NetworkFlags = packed struct(u32) {
    /// Set by `object_move` when the object moves, and by code that places it. The multiplayer
    /// code (`0x004BB2D0`) then sends the object's position.
    moved: bool,
    /// Set by `object_move` when the object turns. The multiplayer code then sends its
    /// orientation.
    turned: bool,
    /// Set while the Scoop Up order runs (`order_scoop_up_init`, `order_scoop_up`) and cleared
    /// when it ends. The multiplayer code's round of updates (`0x004BBEF0`) skips the object.
    _unknown_2: bool,
    _unknown_3: u29,
};

/// The wing a mission lists an object in, by its flight group (`mission.listPlayerWing`), which
/// the object keeps (`GameObject.wing`).
pub const Wing = enum(u16) {
    /// The player's: the wing status window shows its ships, and an AI pilot in it may eject.
    player = 0,
    /// Two more wings a mission can list. **Unknown:** what reads them.
    second = 1,
    third = 2,
    /// None, as the object is created.
    none = 0xFFFF,
    _,
};

/// An object's type (`GameObject.type`): for a ship, missile, mine or asteroid its record in
/// `shipstats.bin`, and past those what else the game places, markers and nav points among them,
/// which have no stats. The names are OpenReliant's, for the types the game's code singles out.
pub const Type = enum(u32) {
    predator = 0x00,
    /// The Grendel, the Wolverine and the Reaper, whose guns fire rounds, which the gunnery display
    /// counts.
    grendel = 0x02,
    wolverine = 0x08,
    reaper = 0x09,
    /// The Phoenix (`uspf_phx.shp`), which carries the Nova Cannon.
    phoenix = 0x0B,
    reliant = 0x0C,
    /// The Yamato (`yamato.shp`), the carrier that takes the place of the ship the player launched
    /// from once that ship explodes.
    yamato = 0x0D,
    /// The Victorious (`victorious.shp`), and the carriers after it whose ships launch from a bay
    /// as its do: the Endeavour, the Mitchell and the Bremen.
    victorious = 0x11,
    endeavour = 0x12,
    mitchell = 0x13,
    bremen = 0x14,
    /// The Ulysses (`ulysses.shp`), whose escape pods launch even as it is lost.
    ulysses = 0x16,
    /// The Nanny (`nanny.shp`).
    nanny = 0x18,
    /// The limpet car (`limpet_t_car.shp`).
    limpet_car = 0x1D,
    /// The Prowler (`us_prowler.shp`).
    prowler = 0x1E,
    ripper = 0x1F,
    /// The Stork (`stork.shp`).
    stork = 0x25,
    sabre = 0x2B,
    kamov = 0x2D,
    scimitar = 0x30,
    /// The Ramases (`ramases.shp`).
    ramases = 0x34,
    /// The Badanov (`cs_badanov.shp`), the smallest of the Coalition's capital ships.
    badanov = 0x37,
    /// The Pukov (`pukov.shp`).
    pukov = 0x38,
    /// The Kurgan (`rus_kurgan.shp`).
    kurgan = 0x3C,
    /// The Gurevich (`rmc_gurevich.shp`).
    gurevich = 0x3E,
    /// Capital ships (`saladin.shp`, `stalag.shp`, `antanov.shp`, `kronstadt.shp`, `boridin.shp`).
    saladin = 0x43,
    /// The Dark Reign (`darkreign.shp`).
    darkreign = 0x44,
    stalag = 0x45,
    antanov = 0x46,
    kronstadt = 0x47,
    boridin = 0x48,
    /// The Russian troop car (`rus_troopcar.shp`).
    troop_car = 0x49,
    torpedo = 0x4A,
    /// An escape pod (`uly_escape.shp`).
    escape_pod = 0x4D,
    /// The first of ten pieces of debris an explosion throws out (`deb_1.shp` to `deb_10.shp`).
    debris = 0x4E,
    /// The first of four bodies an explosion throws out (`rus_man1.shp` to `rus_man4.shp`).
    crewman = 0x58,
    /// The Russian torpedo (`rus_torp.shp`).
    russian_torpedo = 0x5C,
    /// The Coalition's gates: the prototype (`coalprotogate.shp`) and the advanced one
    /// (`coaladvgate.shp`).
    proto_gate = 0x6D,
    advanced_gate = 0x6E,
    /// The proximity mine (`mine_prox.shp`).
    proximity_mine = 0x6F,
    /// A black box (`black_box.shp`).
    black_box = 0x70,
    satellite = 0x71,
    /// The wrecks a capital ship leaves as it splits (`explode.split`), which burn
    /// (`create.wreckMade`): the Mammoth's front and back (`mamdest.shp`, `mamdest2.shp`), the
    /// Badanov's back and front (`cs_baddead.shp`, `cs_baddead2.shp`), and the Kurgan's
    /// (`rus_kurgan_dest.shp`).
    mammoth_wreck_front = 0x72,
    mammoth_wreck_back = 0x73,
    badanov_wreck_back = 0x75,
    badanov_wreck_front = 0x76,
    kurgan_wreck = 0x77,
    /// The Krasnaya (`krasnaya.shp`).
    krasnaya = 0x78,
    /// The Latov (`latov.shp`).
    latov = 0x81,
    /// The Czar, docked (`czar_docked.shp`).
    czar_docked = 0x84,
    /// A deathmatch beacon (`DMBeacon.shp`).
    dm_beacon = 0x8E,
    /// The Kafelnikof (`kafelnikof.shp`).
    kafelnikof = 0x95,
    /// The Krasny (`krasny.shp`), whose ships launch as the Badanov's do.
    krasny = 0x9A,
    /// The Varyag (`varyag.shp`), and a second Ramases and Mitchell, of the same models.
    varyag = 0x9B,
    other_ramases = 0x9C,
    other_mitchell = 0xA0,
    /// The rogue base (`rogue_base.shp`).
    rogue_base = 0xA5,
    /// The part of the Boridin that breaks away (`boridin breakaway.shp`).
    boridin_breakaway = 0xA8,
    /// Another escape pod (`ber_escape.shp`).
    other_escape_pod = 0x90,
    /// The Zakov (`zakov.shp`).
    zakov = 0xB0,
    /// The Turret Flak's shell (`shell.shp`).
    shell = 0xB1,
    /// The first of five chunks of rock (`rockchunk00.SHP` to `rockchunk04.SHP`).
    rock_chunk = 0xB2,
    /// The limpet pod, which rides on a hull.
    limpet_pod = 0xBC,
    /// The Kiev (`kiev.shp`).
    kiev = 0xC2,
    /// The Reliant's hangar (`reliant_hang.shp`): the cutaway the Reliant's launch shows the
    /// player's ship in.
    reliant_hangar = 0xD6,
    /// A comms relay (`comms relay.shp`).
    comms_relay = 0xD7,
    /// Escape pods again, of the same models as `escape_pod` and `other_escape_pod`.
    late_escape_pod = 0xDF,
    other_late_escape_pod = 0xE0,
    /// A second Phoenix (`t_uspf_phx.shp`), the last type of the table.
    t_phoenix = 0xFF,
    /// The markers `backdrop_place` reads a mission's sun and nebula from.
    sun_marker = 0x3DC,
    nebula_marker = 0x3DD,
    /// What `mission_ship_create` makes of a mission's nav points and markers, and the mission's
    /// start of the camera's marker.
    marker = 1000,
    /// What a slot holds until `create_object` fills it, and what a destroyed object becomes.
    stand_in = 1001,
    _,

    /// What is made of rock: the asteroids, `ast_1.shp` to `ast_7.shp`; the turret asteroids,
    /// `turast_1.shp` to `turast_7.shp`; and the holes, `ast_hole1.shp` to `ast_hole4.shp`.
    pub const Rock = enum { asteroid, turret, hole };
    const rocks: std.EnumArray(Rock, [2]u32) = .init(.{
        .asteroid = .{ 0x79, 0x7F },
        .turret = .{ 0x85, 0x8B },
        .hole = .{ 0xF0, 0xF3 },
    });

    comptime {
        // The numbers are the game's own, so the models they stand for say which types they are.
        const models = [_]struct { Type, []const u8 }{
            .{ .predator, "uslf_prd.shp" },
            .{ .phoenix, "uspf_phx.shp" },
            .{ .t_phoenix, "t_uspf_phx.shp" },
            .{ .reliant, "reliant.shp" },
            .{ .nanny, "nanny.shp" },
            .{ .victorious, "victorious.shp" },
            .{ .darkreign, "darkreign.shp" },
            .{ .mammoth_wreck_front, "mamdest.shp" },
            .{ .mammoth_wreck_back, "mamdest2.shp" },
            .{ .badanov_wreck_back, "cs_baddead.shp" },
            .{ .badanov_wreck_front, "cs_baddead2.shp" },
            .{ .kurgan_wreck, "rus_kurgan_dest.shp" },
            .{ .latov, "latov.shp" },
            .{ .czar_docked, "czar_docked.shp" },
            .{ .kafelnikof, "kafelnikof.shp" },
            .{ .prowler, "us_prowler.shp" },
            .{ .stalag, "stalag.shp" },
            .{ .antanov, "antanov.shp" },
            .{ .limpet_car, "limpet_t_car.shp" },
            .{ .ripper, "ripper_2.shp" },
            .{ .sabre, "rus_sabre.shp" },
            .{ .kamov, "rus_kamov.shp" },
            .{ .scimitar, "scimitar.shp" },
            .{ .badanov, "cs_badanov.shp" },
            .{ .kurgan, "rus_kurgan.shp" },
            .{ .gurevich, "rmc_gurevich.shp" },
            .{ .troop_car, "rus_troopcar.shp" },
            .{ .saladin, "saladin.shp" },
            .{ .kronstadt, "kronstadt.shp" },
            .{ .boridin, "boridin.shp" },
            .{ .proto_gate, "coalprotogate.shp" },
            .{ .advanced_gate, "coaladvgate.shp" },
            .{ .boridin_breakaway, "boridin breakaway.shp" },
            .{ .torpedo, "torpedo.shp" },
            .{ .russian_torpedo, "rus_torp.shp" },
            .{ .proximity_mine, "mine_prox.shp" },
            .{ .black_box, "black_box.shp" },
            .{ .dm_beacon, "DMBeacon.shp" },
            .{ .comms_relay, "comms relay.shp" },
            .{ .satellite, "stork_sat.shp" },
            .{ .escape_pod, "uly_escape.shp" },
            .{ .other_escape_pod, "ber_escape.shp" },
            .{ .late_escape_pod, "uly_escape.shp" },
            .{ .other_late_escape_pod, "ber_escape.shp" },
            .{ .debris, "deb_1.shp" },
            .{ @enumFromInt(Type.debris.number() + 9), "deb_10.shp" },
            .{ .crewman, "rus_man1.shp" },
            .{ @enumFromInt(Type.crewman.number() + 3), "rus_man4.shp" },
            .{ .rock_chunk, "rockchunk00.SHP" },
            .{ @enumFromInt(Type.rock_chunk.number() + 4), "rockchunk04.SHP" },
            .{ .shell, "shell.shp" },
            .{ .limpet_pod, "limpet_pod.shp" },
            .{ @enumFromInt(rocks.get(.asteroid)[0]), "ast_1.shp" },
            .{ @enumFromInt(rocks.get(.asteroid)[1]), "ast_7.shp" },
            .{ @enumFromInt(rocks.get(.turret)[0]), "turast_1.shp" },
            .{ @enumFromInt(rocks.get(.turret)[1]), "turast_7.shp" },
            .{ @enumFromInt(rocks.get(.hole)[0]), "ast_hole1.shp" },
            .{ @enumFromInt(rocks.get(.hole)[1]), "ast_hole4.shp" },
        };
        for (models) |named| assert(std.mem.eql(u8, create.models.ship_types[named[0].number()].model.?, named[1]));
    }

    pub fn number(object_type: Type) u32 {
        return @intFromEnum(object_type);
    }

    /// Whether it has a record in the ship tables.
    pub fn hasStats(object_type: Type) bool {
        return object_type.number() < create.ship_type_count;
    }

    /// Where the second set of the player's ship types starts: types `0xF4` to `0xFF`, whose models
    /// are the first twelve's `t_` twins, are the same twelve ships to the start.
    pub const player_twins_first = 0xF4;

    /// The type it stands for among the player's ships: one of the second set, from
    /// `player_twins_first`, stands for the first set's in the same place, and any other for itself.
    pub fn untwinned(object_type: Type) Type {
        const at = object_type.number();
        return @enumFromInt(if (at >= player_twins_first) at - player_twins_first else at);
    }

    /// How many of the player's ship types have twins: the first twelve, from 0.
    pub const player_twins = 0x100 - player_twins_first;

    /// Its twin among the second set of the player's ship types, for one of the first set's; null
    /// for any other.
    pub fn twin(object_type: Type) ?Type {
        const at = object_type.number();
        return if (at < player_twins) @enumFromInt(at + player_twins_first) else null;
    }

    /// Whether it is a Phoenix, the ship that carries the Nova Cannon, or its twin.
    pub fn carriesNova(object_type: Type) bool {
        return object_type == .phoenix or object_type == .t_phoenix;
    }

    /// What rock it is, if any.
    pub fn rock(object_type: Type) ?Rock {
        const n = object_type.number();
        for (std.enums.values(Rock)) |kind| {
            const range = rocks.get(kind);
            if (n >= range[0] and n <= range[1]) return kind;
        }
        return null;
    }

    pub fn isAsteroid(object_type: Type) bool {
        return object_type.rock() == .asteroid;
    }

    /// Asteroid `n`, from `ast_1.shp`, round and round the seven.
    pub fn asteroid(n: usize) Type {
        const range = rocks.get(.asteroid);
        return @enumFromInt(range[0] + n % (range[1] - range[0] + 1));
    }

    /// The child of the root the AI aims at on an object of this type, where it aims at a part
    /// rather than the whole (`0x004018F0`): the Saladin's and the troop car's twenty-first, the
    /// Kronstadt's eighteenth, the Boridin's twentieth.
    pub fn aimedChild(object_type: Type) ?usize {
        return switch (object_type) {
            .saladin, .troop_car => 0x14,
            .kronstadt => 0x11,
            .boridin => 0x13,
            else => null,
        };
    }
};

/// A list of objects the avoidance code steers round (`avoidance_scan`), `max_avoided` at most.
pub const Avoided = extern struct {
    count: i32,
    slots: [max_avoided]i32,

    pub fn list(avoided: *const Avoided) []const i32 {
        return avoided.slots[0..@intCast(std.math.clamp(avoided.count, 0, max_avoided))];
    }

    /// Adds `slot`, where there is room.
    pub fn add(avoided: *Avoided, slot: u16) void {
        if (avoided.count >= max_avoided) return;
        avoided.slots[@intCast(avoided.count)] = slot;
        avoided.count += 1;
    }

    comptime {
        assert(@sizeOf(Avoided) == 0x2C);
    }
};

pub const max_avoided = 10;

/// A live object (`gameobj.cpp`), allocated at `0x00475DD0`.
pub const GameObject = extern struct {
    type: Type,
    /// Its slot in `game_objects`.
    index: u32,
    flags: Flags,
    network: NetworkFlags,
    combat: Pointer(create.ShipCombat),
    flight: Pointer(create.FlightModel),
    /// The type's model, as loaded.
    model: Pointer(anyopaque),
    /// Data kept for the ship type and shared by its objects.
    type_data: Pointer(anyopaque),
    /// The renderer's object for it, or null.
    render: Pointer(anyopaque),
    /// The shape the wing status window shows it by, which the mission's start gives each ship of
    /// the player's wing by its type (`main.startWing`); 0 for none, as created.
    wing_icon: u16,
    _unknown_26: u16,
    /// The root of its model hierarchy.
    root: Node,
    /// **Unknown.** 1.0 when created; the collision sweep multiplies `radius` by it.
    /// How far off it stays worth drawing, over the distance its radius alone would give it
    /// (`node_draw`). `object_alloc` and `create_object` both leave it at 1, so nothing in the
    /// shipped game sees further or less far than its size says.
    visibility: f32,
    /// Its guns: `gun_count` records of 0x60 bytes at `guns`, which `create_object` walks to set up
    /// the gun groups (#131).
    gun_count: i16,
    _unknown_132: u16,
    guns: Pointer(anyopaque),
    /// The count each gun keeps of the steps it has been firing (`guns.Fitted.sounded`), which
    /// the game allocates with the guns, one word each.
    _unknown_138: u32,
    /// The rounds its guns have left: `ShipCombat.rounds` when created, one for each shot of a gun
    /// of kind `rounds` (`guns.step`). The gunnery window shows them.
    rounds: i32,
    /// The guns' charge: `ShipCombat.gun_energy` when created, which the guns recharge to
    /// (`0x00477114`). The display's right arc shows it against that.
    gun_charge: f32,
    /// How its guns fire, which the gun keys set.
    gun_mode: GunMode,
    _unknown_146: u16,
    /// How far a gun that charges up before it fires has charged, from 0 to 1, which scales its
    /// damage. Only gun type 11, the Nova Cannon, uses it. Its guns' charge does not recharge
    /// while it is not zero (`guns.step`).
    nova_charge: f32,
    /// Which side of a gun group fires next, 0 or 1, while the ship fires one group out of step
    /// (`guns.step`).
    gun_turn: guns.GroupSide,
    /// Its missile racks, `rack_count` of them, which `create_object` fits from its missile
    /// hardpoints and each launch takes from.
    rack_count: i16,
    component_count: i16,
    /// For an object that lists components, how many part nodes it has, its model's and those of
    /// the models mounted on it (`object_number_parts`).
    part_count: i16,
    _unknown_156: [2]u8,
    racks: [max_racks]Rack,
    /// The parts of its model whose flags mark them as components, in the order `0x00468760`
    /// finds them: each node's marked children, then each child's in turn.
    components: [max_components]Component,
    /// For an object that lists components, its part nodes by their numbers
    /// (`object_number_parts`), which a shot's candidates name its parts by; null for any other.
    part_nodes: Pointer(Pointer(objects.Node)),
    /// How many knocks, from collisions and explosions, the object has taken since its last move
    /// (`knock`). The next `object_move` applies them in place of the object's own motion
    /// (`applyKnocks`).
    knocks: u32,
    /// The sum of its parts' masses (`object_recentre`).
    mass: f32,
    /// How far `object_recentre` moved the object's origin to its centre of mass
    /// (`objects.Model.centre`).
    centre: shp.Vec3,
    /// The sum of the forces of the knocks since the last move.
    impulse: shp.Vec3,
    /// The sum of each knock's force × lever, in world coordinates: the opposite of the torque.
    angular_impulse: shp.Vec3,
    /// The inverse of the object's inertia tensor, which `object_recentre` builds from its parts
    /// (`object_bounds`) and inverts (`0x004AD9F0`). `applyKnocks` turns the angular impulse by it.
    /// Not filled in by OpenReliant yet (#87).
    angular_response: [9]f32,
    /// The turn applied to its orientation each update, which `object_steer` builds from the
    /// angular rates.
    rotation: [9]f32,
    /// Added to its position each update.
    velocity: shp.Vec3,
    /// The radius of the sphere collisions test it by.
    radius: f32,
    /// **Unverified:** the corners of its model's bounding box, which `object_recentre`
    /// (`0x004769F0`) accumulates.
    bounds_min: shp.Vec3,
    bounds_max: shp.Vec3,
    /// Up to 1 in flight, 2 while `afterburner` is set, and -1 while `reverse_thrust` is.
    throttle: f32,
    /// Steering inputs, each between -1 and 1.
    roll_input: f32,
    pitch_input: f32,
    yaw_input: f32,
    /// Pushes it sideways: its lateral speed follows a quarter of its cruise speed times this.
    lateral_input: f32,
    /// Set while the afterburner burns, 4 units of `afterburner_fuel` an update.
    afterburner: bool,
    /// Set while reverse thrust burns: the throttle is -1, and it uses afterburner fuel.
    reverse_thrust: bool,
    _unknown_5ce: u16,
    /// Engines in its model: parts of subsystem class 5.
    engines: u32,
    /// The share of its engines left: 1.0 when created, less `1 / engines` for each one destroyed.
    engines_intact: f32,
    /// The length of `velocity`.
    speed: f32,
    /// Angular rates, which `object_steer` moves toward the inputs.
    roll_rate: f32,
    pitch_rate: f32,
    yaw_rate: f32,
    /// In hundredths of a second: `100 * ShipCombat.afterburner_fuel` when created, or zero in one
    /// of the game's modes.
    afterburner_fuel: i32,
    /// Countermeasures left, which the display shows under its coil. 29 when the object is created
    /// (`create_object`, `object_alloc`), and `object_spend_countermeasure` (`0x00462550`) takes
    /// one at a time; with none left, the player's COUNTERMEASURES key gets only the display's
    /// sound 3.
    countermeasures: u16,
    _unknown_5ee: u16,
    /// Each `6 * ShipCombat.shield_power - 1` when created.
    shields: Quadrants,
    /// Each `6 * ShipCombat.armor_class - 1` when created. `ship_damage_value` reports the lowest.
    armor: Quadrants,
    /// What the explosions' routines note of it as it comes apart.
    ends: Ends,
    /// The routine in `explode.cpp` that `create_object` gives most capital ships, bases and
    /// stations, which `node_draw` runs as one of the object's components is destroyed. OpenReliant
    /// leaves it null and picks the routine by type as it needs it (`explode.ComponentLoss`).
    component_loss: Pointer(Routine),
    /// The slots of two objects it passes through: the collision sweep of `objects_update` tests
    /// no pair where either names the other. Both are `none` when created.
    passes_through: [2]Slot,
    /// The slot of the ship Fight has it attack: Fight sets it as it starts (`order_fight_init`),
    /// an attack run leaves it clear until it is done, and a new order clears it. None when created.
    fighting: Slot,
    _unknown_624: u8,
    _unknown_625: [3]u8,
    _unknown_628: shp.Vec3,
    /// Where its lights stand in their blinks, in ticks added to the mission's clock
    /// (`node_draw`): from 0 to 100 at random when allocated (`blinkOffset`), so that ships of one
    /// type don't blink together.
    blink_offset: i16,
    _unknown_636: u16,
    /// The seed of its own random numbers (`object_random`): C's `rand()` when created.
    random_seed: u32,
    /// Its cloak's state, 0x2C bytes that `object_cloak` allocates; null until then.
    cloak: Pointer(anyopaque),
    /// Moves it each update; `motion_forward` when created.
    motion: Pointer(Routine),
    /// Its side: its type's (`ShipCombat.side`) when created, save for other players' ships in a
    /// multiplayer game, and hostile or friendly once `SetHostile` says.
    side: Side(i32),
    /// The loadout tier a re-arm fits its racks by (`order_dock`, `cmd_ReplenishWeapons`).
    /// **Unverified:** nothing writes it, so it holds what the allocator leaves.
    loadout_tier: u32,
    /// Nonzero while a missile homes on it, which lights the display's missile warning.
    /// `mission_frame` zeroes it on every object each frame, and `missiles_update` (`0x004960F0`)
    /// then sets it on the object each live missile's order targets. **Unverified:** the
    /// conditions it sets it under, which are not all read.
    missile_homing: i32,
    /// The throttle of the last update.
    last_throttle: f32,
    /// Until when a shockwave that harms what it passes leaves it alone, having harmed it
    /// (`shockwave.Shockwave.harmPlayer`).
    shockwave_until: i32,
    /// Its smoke's template, which its level picks (`0x00494400`), and its smoke's emitter, or
    /// null for none. OpenReliant keeps its smoke in its slot (`create.Slot.smoke`).
    smoke_template: Pointer(@import("particles.zig").Template),
    smoke: Pointer(anyopaque),
    /// How damaged it shows itself to be, by its smoke (`smoke.Level.of`).
    smoke_level: @import("main/smoke.zig").Level,
    _unknown_661: [3]u8,
    /// How well its shields recharge as its armour wears: a quarter of each quadrant's armour over
    /// its full armour, added up (`armorConditions`). 1 when created. The damage display's shield
    /// bar shows it.
    shield_condition: f32,
    /// Scales the cruise speed as its armor falls, which `object_cruise_speed` applies unless the
    /// camera is in view 13 or the object is invulnerable: a quarter, and three quarters of the
    /// aft quadrant's armour over its full armour (`armorConditions`). 1 when created.
    armor_speed_factor: f32,
    /// How well its guns work as its armour wears: half the fore quadrant's armour over its full
    /// armour, and a quarter of each side's (`armorConditions`). 1 when created. The guns
    /// recharge by it, and below 0.9 each shot goes off only as often as it plus a tenth
    /// (`0x004770E0`).
    gun_condition: f32,
    /// The gun type its spectral shields are tuned to, which turning them on sets
    /// (`player_spectral_shields_set`): the one most dangerous near it.
    spectral_gun_type: i32,
    /// Nonzero while blind fire aims the guns at the target: `hud_draw` sets it each frame it
    /// draws the reticle.
    blind_fire_aim: i32,
    _unknown_678: i32,
    /// The frame (`Clock.frame_start`) it was last heard flying past the camera
    /// (`sound3d.engineUpdate`).
    flyby_at: i32,
    /// Orders on its stack.
    order_count: i16,
    _unknown_682: u16,
    /// Its order stack, the current order first: `aigeneric.max_stack` entries, allocated with its
    /// first order.
    orders: Pointer(aigeneric.Entry),
    /// Set while the current order has yet to start: `object_orders` runs its `init` first.
    order_starting: bool,
    _unknown_689: [3]u8,
    /// What the current order keeps between updates, allocated with the stack.
    order_state: Pointer(aigeneric.State),
    /// Damage of kinds 0, 1 and 5 taken since `orders_update` last zeroed it, which it does every
    /// 500 ticks.
    recent_damage: f32,
    /// The slot of the object that last damaged it.
    last_attacker: Slot,
    _unknown_698: u32,
    /// Fight's timers: until when it holds its fire, until when it holds its missiles, and until
    /// when it holds its countermeasures, each from the pilot's `timings`.
    fire_at: i32,
    missile_at: i32,
    countermeasure_at: i32,
    /// How many Fight orders have taken it as their target.
    fought_by: u32,
    /// **Unknown.** -1 when created.
    _unknown_6ac: i32,
    _unknown_6b0: u32,
    /// What `avoidance_scan` finds the ship could hit, for the avoidance code: the objects that
    /// list components (`ai.avoidNear`), and the rest (`ai.avoidAhead`).
    avoid_near: Avoided,
    avoid_ahead: Avoided,
    /// A number from 0 to 99 the object draws from its own seed when created: where a mission lets
    /// the pilot eject, it does below `ai.eject_below` (`object_destroyed`). The `WillsBlag`
    /// command sets it to 100, which never does.
    eject_roll: i32,
    _unknown_710: [4]u32,
    /// The object of the nav point the display points to, set by the mission's `SetNavPoint` and
    /// `nav_point_next` (`0x004152A0`), which passes on to the next the player's ship has not
    /// reached; none when created.
    nav_point: Slot,
    /// **Unknown.** -1 when created.
    _unknown_724: i32,
    /// Where the power distribution stands on the power ball (`input.power`): a point within a disc
    /// of radius 64, in `x` and `y`. `z` is 1 when created, and moving the point sets it to 0.
    /// `create_object` puts the point at (1, 1).
    power_setting: shp.Vec3,
    /// How fast its guns recharge, from its share of the power: 0.5 to 1.5, 1 for an even third
    /// (`input.power.distribute`). 1 when created.
    gun_factor: f32,
    /// Scales the cruise speed: the engines' share of the power, as `gun_factor` is the guns'.
    /// 1 when created.
    speed_factor: f32,
    /// How fast its shields recharge (`rechargeShields`): the shields' share of the power, as
    /// `gun_factor` is the guns'. 1 when created.
    shield_factor: f32,
    /// Its pilot: the record in `pilotstats.bin`, which `object_set_pilot` gives it.
    pilot: i32,
    /// **Unknown.** A 24-byte record for the pilot, from a table at `0x5048D8`.
    pilot_record: Pointer(anyopaque),
    pilot_stats: Pointer(@import("pilots.zig").Pilot),
    /// The wing the mission lists it in (`mission.listPlayerWing`).
    wing: Wing,
    _unknown_74e: u16,
    _unknown_750: u32,
    /// The deathmatch power-up it holds.
    power_up: PowerUp,
    /// **Unknown.** Set as a power-up is handed out, where it is given (`0x004B1C00`).
    _unknown_758: i32,
    /// The frame (`Clock.frame_start`) the power-up runs out at, or -1 for never.
    power_up_until: i32,
    /// The frame it was handed out at, from which the display flashes its icon (`hud_draw`).
    power_up_since: i32,
    /// **Unknown.** -1 when allocated.
    _unknown_764: i32,
    _unknown_768: [0x424]u8,
    /// Orders from other players waiting for their frame, in a multiplayer game.
    queued_order_count: i32,
    /// Its queue of `aigeneric.max_queued` entries, allocated when the first order arrives.
    queued_orders: Pointer(aigeneric.Queued),
    /// Set once `create_object` has filled the slot; it stops with a fatal error if it is set
    /// already.
    created: bool,
    /// How far harm reaches it (`SetInvulnerability`).
    invulnerable: Invulnerability,
    /// The 3D voice following it: `sound_3d_voice_end` sets it back to none, and the missiles'
    /// code reads it (`0x00495CF0`).
    sound_voice: Voice,

    /// The names of the script commands that set a bit are the developers' own.
    /// What the explosions' routines note of an object as it comes apart (`+0x610`).
    pub const Ends = packed struct(u32) {
        /// The Ulysses has lost its fin (`explode_ulysses_component`).
        fin_lost: bool = false,
        /// Its split has ended (`split_update`), which it does once.
        split_ended: bool = false,
        _unknown_2: u30 = 0,
    };

    pub const Flags = packed struct(u32) {
        /// Not drawn: `camera_set_view` sets it on the object whose cockpit the camera is in, and
        /// the warp orders while it warps. `mission_frame` hands `node_draw` flag `0x10` for it,
        /// which adds none of its parts to the scene.
        hidden: bool = false,
        /// Its components are listed, as its model's header asks. The collision code treats such
        /// objects apart.
        components: bool = false,
        /// The collision sweep of `objects_update` leaves it out.
        no_collisions: bool = false,
        /// `object_move` runs no motion routine for it, so it drifts at its velocity; knocks still
        /// move it. Set while the object is disrupted (`order_disrupted_init`) and once it is
        /// wrecked, and together with `frozen` during gate jumps and warps and by `object_reset`.
        unpowered: bool = false,
        /// `object_move` isn't run for it (`objects_update`), and returns straight away if it is.
        frozen: bool = false,
        /// Set on objects of types above 255, such as the type-1001 stand-in an empty slot holds;
        /// the per-object loops skip them.
        stand_in: bool = false,
        /// Set as it starts to explode. It takes no more orders.
        exploding: bool = false,
        /// Reverse thrust works only while it is set: `object_orders` clears `reverse_thrust`
        /// otherwise.
        can_reverse: bool = false,
        /// Set by `object_cloak`, which posts the Cloaked event.
        cloaked: bool = false,
        /// `SetTargetable` for the whole object, which sets it only when the word at `+0x24` of its
        /// combat stats is nonzero.
        targetable: bool = false,
        /// Not processed: `DisableObject`, and `DisableObjectAtNextJump` at the next jump.
        disabled: bool = false,
        /// Set once its pilot ejects. It takes no more orders, and destroying it now makes it
        /// explode.
        ejected: bool = false,
        /// Held in a ship's tractor beams, which Scoop Up sets and lets go of (`tractor.scoopUp`):
        /// no second ship takes it.
        tractored: bool = false,
        /// `DisableLights`.
        lights_disabled: bool = false,
        /// It has a shield generator, a part of subsystem class 6, which destroying the part
        /// clears.
        shield_generator: bool = false,
        /// `DisableGuns`. `orders_update` skips `0x0047C950` for it.
        guns_disabled: bool = false,
        /// `DisableMissiles`.
        missiles_disabled: bool = false,
        /// `DisableEngines`. `object_orders` holds its throttle at zero and stops both burns.
        engines_disabled: bool = false,
        /// `DisableEject`. The player cannot eject.
        eject_disabled: bool = false,
        /// `DoNotDisturb`: "dont disturb". It does not retaliate either.
        do_not_disturb: bool = false,
        /// `SetShipAvoidance` with "Disable Avoidance code": the avoidance code passes it over.
        no_avoidance: bool = false,
        /// Set during the jump orders: it cannot fire, and the avoidance code passes it over.
        jumping: bool = false,
        /// Set while the Dock and Ripper orders hold it to another object; their ends clear it.
        attached: bool = false,
        _unknown_23: bool = false,
        /// **Unknown.** `mission_frame` lets the object's smoke go while it is set
        /// (`smoke.frame`).
        _unknown_24: bool = false,
        /// Set by `create_object` on an object whose model has an eject point
        /// (`shp.Attachment.Kind.eject_point`). **Unknown:** what reads it.
        eject_point: bool = false,
        /// Its ECM is on: `player_ecm_set` (`0x00415370`).
        ecm: bool = false,
        /// Its spectral shields are on: `player_spectral_shields_set` (`0x00415430`).
        spectral_shields: bool = false,
        /// **Unknown.** Set by `0x00474B40` as it sends a ship off, the player's into Friendly
        /// Fire and others into Jump Out, and cleared by Friendly Fire. It takes no orders while
        /// it is set.
        _unknown_28: bool = false,
        /// `DisableListing`: "stop listing".
        unlisted: bool = false,
        _unknown_30: u2 = 0,

        /// What a slot holds until `create_object` fills it (`objects_reset`, `object_reset`), and
        /// what an object of a type above 255 is given: it takes no part in collisions, never
        /// moves, and the loops over the objects pass it over.
        pub const standing_in: Flags = .{ .no_collisions = true, .unpowered = true, .frozen = true, .stand_in = true };

        /// Whether the object is out of the action: exploding, its pilot ejected, or being sent
        /// off (`_unknown_28`). It takes no orders then, and the AI passes over a player's ship
        /// that is.
        pub fn outOfAction(flags: Flags) bool {
            return flags.exploding or flags.ejected or flags._unknown_28;
        }

        /// Whether `mission_frame`'s passes over the objects pass it over: a stand-in, or a
        /// disabled or jumping object.
        pub fn outOfFrame(flags: Flags) bool {
            return flags.stand_in or flags.disabled or flags.jumping;
        }

        /// Whether the AI's searches pass it over: a stand-in, or an exploding or disabled object.
        pub fn outOfSearch(flags: Flags) bool {
            return flags.stand_in or flags.exploding or flags.disabled;
        }

        /// The flags set in either.
        pub fn with(flags: Flags, more: Flags) Flags {
            return @bitCast(word(flags) | word(more));
        }

        /// The flags set in both.
        pub fn within(flags: Flags, other: Flags) Flags {
            return @bitCast(word(flags) & word(other));
        }

        /// The flags set here but not in `other`.
        pub fn without(flags: Flags, other: Flags) Flags {
            return @bitCast(word(flags) & ~word(other));
        }

        /// Whether any flag is set.
        pub fn any(flags: Flags) bool {
            return word(flags) != 0;
        }

        fn word(flags: Flags) u32 {
            return @bitCast(flags);
        }
    };

    /// Where it will stand at the next step (`root.next_position`), which the AI, the collisions
    /// and the sounds go by.
    pub fn nextPosition(object: *const GameObject) Vector {
        return vector(object.root.next_position);
    }

    /// Lets go of the turns: no roll, pitch or yaw.
    pub fn holdTurns(object: *GameObject) void {
        object.roll_input = 0;
        object.pitch_input = 0;
        object.yaw_input = 0;
    }

    /// Lets go of the controls: no throttle and no turns.
    pub fn letGo(object: *GameObject) void {
        object.throttle = 0;
        object.holdTurns();
    }

    /// Whether its sphere and `other`'s, their radii together `widen` wider, overlap where the
    /// next step has them: the collision sweep's test (`objects_update`, `objects_collide`), and
    /// `avoidance_scan`'s for an object that lists components.
    pub fn overlaps(object: *const GameObject, other: *const GameObject, widen: f32) bool {
        const reach = object.radius + other.radius + widen;
        return math.lengthSquared(object.nextPosition() - other.nextPosition()) < reach * reach;
    }

    /// Where its root stands at `step`: its committed place, or its next.
    pub fn placeAt(object: *const GameObject, step: objects.Model.Step) math.Place {
        return switch (step) {
            .now => .{ .position = vector(object.root.position), .orientation = object.root.orientation },
            .next => .{ .position = object.nextPosition(), .orientation = object.root.next_orientation },
        };
    }

    /// Its racks, `rack_count` of them.
    pub fn fittedRacks(object: *const GameObject) []const Rack {
        return object.racks[0..@intCast(@max(object.rack_count, 0))];
    }

    /// The way its nose will point at the next step.
    pub fn nextHeading(object: *const GameObject) Vector {
        return math.forward(object.root.next_orientation);
    }

    comptime {
        assert(@bitOffsetOf(Flags, "components") == 1);
        assert(@bitOffsetOf(Flags, "unpowered") == 3);
        assert(@bitOffsetOf(Flags, "stand_in") == 5);
        assert(@bitOffsetOf(Flags, "disabled") == 10);
        assert(@bitOffsetOf(Flags, "shield_generator") == 14);
        assert(@bitOffsetOf(Flags, "engines_disabled") == 17);
        assert(@bitOffsetOf(Flags, "attached") == 22);
        assert(@bitOffsetOf(Flags, "ecm") == 26);
        assert(@bitOffsetOf(Flags, "spectral_shields") == 27);
        assert(@bitOffsetOf(Flags, "unlisted") == 29);
        assert(@offsetOf(GameObject, "combat") == 0x10);
        assert(@offsetOf(GameObject, "root") == 0x28);
        assert(@offsetOf(GameObject, "visibility") == 0x12C);
        assert(@offsetOf(GameObject, "gun_charge") == 0x140);
        assert(@offsetOf(GameObject, "gun_mode") == 0x144);
        assert(@offsetOf(GameObject, "component_count") == 0x152);
        assert(@offsetOf(GameObject, "part_count") == 0x154);
        assert(@offsetOf(GameObject, "part_nodes") == 0x518);
        assert(@offsetOf(GameObject, "components") == 0x248);
        assert(@offsetOf(GameObject, "engines") == 0x5D0);
        assert(@offsetOf(GameObject, "afterburner_fuel") == 0x5E8);
        assert(@offsetOf(GameObject, "countermeasures") == 0x5EC);
        assert(@offsetOf(GameObject, "shields") == 0x5F0);
        assert(@offsetOf(GameObject, "armor") == 0x600);
        assert(@offsetOf(GameObject, "knocks") == 0x51C);
        assert(@offsetOf(GameObject, "centre") == 0x524);
        assert(@offsetOf(GameObject, "impulse") == 0x530);
        assert(@offsetOf(GameObject, "angular_impulse") == 0x53C);
        assert(@offsetOf(GameObject, "angular_response") == 0x548);
        assert(@offsetOf(GameObject, "rotation") == 0x56C);
        assert(@offsetOf(GameObject, "roll_rate") == 0x5DC);
        assert(@offsetOf(GameObject, "pitch_rate") == 0x5E0);
        assert(@offsetOf(GameObject, "yaw_rate") == 0x5E4);
        assert(@offsetOf(GameObject, "velocity") == 0x590);
        assert(@offsetOf(GameObject, "throttle") == 0x5B8);
        assert(@offsetOf(GameObject, "afterburner") == 0x5CC);
        assert(@offsetOf(GameObject, "speed") == 0x5D8);
        assert(@offsetOf(GameObject, "blink_offset") == 0x634);
        assert(@offsetOf(GameObject, "random_seed") == 0x638);
        assert(@offsetOf(GameObject, "motion") == 0x640);
        assert(@offsetOf(GameObject, "side") == 0x644);
        assert(@offsetOf(GameObject, "gun_count") == 0x130);
        assert(@offsetOf(GameObject, "guns") == 0x134);
        assert(@offsetOf(GameObject, "rounds") == 0x13C);
        assert(@offsetOf(GameObject, "gun_turn") == 0x14C);
        assert(@offsetOf(GameObject, "ends") == 0x610);
        assert(@offsetOf(GameObject, "component_loss") == 0x614);
        assert(@offsetOf(GameObject, "passes_through") == 0x618);
        assert(@offsetOf(GameObject, "_unknown_624") == 0x624);
        assert(@offsetOf(GameObject, "_unknown_628") == 0x628);
        assert(@offsetOf(GameObject, "smoke") == 0x65C);
        assert(@offsetOf(GameObject, "smoke_level") == 0x660);
        assert(@offsetOf(GameObject, "gun_condition") == 0x66C);
        assert(@offsetOf(GameObject, "_unknown_678") == 0x678);
        assert(@offsetOf(GameObject, "_unknown_6ac") == 0x6AC);
        assert(@offsetOf(GameObject, "avoid_near") == 0x6B4);
        assert(@offsetOf(GameObject, "avoid_ahead") == 0x6E0);
        assert(@offsetOf(GameObject, "eject_roll") == 0x70C);
        assert(@offsetOf(GameObject, "nav_point") == 0x720);
        assert(@offsetOf(GameObject, "wing") == 0x74C);
        assert(@offsetOf(GameObject, "_unknown_764") == 0x764);
        assert(@bitOffsetOf(Flags, "frozen") == 4);
        assert(@as(u32, @bitCast(Flags.standing_in)) == 0x3C);
        assert(@offsetOf(GameObject, "missile_homing") == 0x64C);
        assert(@offsetOf(GameObject, "spectral_gun_type") == 0x670);
        assert(@offsetOf(GameObject, "blind_fire_aim") == 0x674);
        assert(@offsetOf(GameObject, "last_throttle") == 0x650);
        assert(@offsetOf(GameObject, "armor_speed_factor") == 0x668);
        assert(@offsetOf(GameObject, "shield_condition") == 0x664);
        assert(@offsetOf(GameObject, "power_setting") == 0x728);
        assert(@offsetOf(GameObject, "gun_factor") == 0x734);
        assert(@offsetOf(GameObject, "speed_factor") == 0x738);
        assert(@offsetOf(GameObject, "shield_factor") == 0x73C);
        assert(@offsetOf(GameObject, "power_up") == 0x754);
        assert(@offsetOf(GameObject, "order_count") == 0x680);
        assert(@offsetOf(GameObject, "orders") == 0x684);
        assert(@offsetOf(GameObject, "order_state") == 0x68C);
        assert(@offsetOf(GameObject, "last_attacker") == 0x694);
        assert(@offsetOf(GameObject, "queued_orders") == 0xB90);
        assert(@offsetOf(GameObject, "pilot") == 0x740);
        assert(@offsetOf(GameObject, "created") == 0xB94);
        assert(@sizeOf(GameObject) == 0xB98);
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// How many countermeasures an object is created with (`0x00407AAE`, `0x0045A0A4`).
pub const countermeasures_when_created: u16 = 29;

/// How a ship's guns fire (`GameObject.gun_mode`): the group chosen, and the two ways of firing
/// them all. `create_object` gives a ship of one group of guns `0x20` and one of more `0x30`.
pub const GunMode = packed struct(u16) {
    /// The group of guns chosen. GUNNERY WINDOW moves to the next, going round, or only clears
    /// `all` if it is set.
    group: u3,
    _unknown_3: bool,
    /// Every group fires: FULL GUNS flips it on a ship of more than one group. It keeps the
    /// display's blind fire light out.
    all: bool,
    /// SYNCHRONISE GUNS flips it. **Unverified:** that it has the guns fire together rather than
    /// in turn, which the manual's CTRL and G does.
    synchronised: bool,
    _unknown_6: u10,

    /// What `create_object` starts a ship on, by how many groups of guns it has.
    pub fn created(groups: i16) GunMode {
        return .{ .group = 0, ._unknown_3 = false, .all = groups != 1, .synchronised = true, ._unknown_6 = 0 };
    }
};

test "Type.untwinned" {
    try std.testing.expectEqual(.predator, Type.untwinned(@enumFromInt(0xF4)));
    try std.testing.expectEqual(.grendel, Type.untwinned(@enumFromInt(0xF6)));
    try std.testing.expectEqual(.grendel, Type.grendel.untwinned());
    try std.testing.expectEqual(@as(Type, @enumFromInt(0xF3)), Type.untwinned(@enumFromInt(0xF3)));
}

test "GameObject.Flags" {
    const flags: GameObject.Flags = .{ .stand_in = true, .targetable = true };
    try std.testing.expectEqual(GameObject.Flags{ .stand_in = true, .targetable = true, .frozen = true }, flags.with(.{ .frozen = true }));
    try std.testing.expectEqual(GameObject.Flags{ .targetable = true }, flags.without(.{ .stand_in = true }));
    try std.testing.expectEqual(GameObject.Flags{ .stand_in = true }, flags.within(.{ .stand_in = true, .frozen = true }));
    try std.testing.expect(flags.any());
    try std.testing.expect(!flags.within(.{ .frozen = true }).any());
    try std.testing.expect(flags.outOfSearch());
}

test "GameObject.overlaps" {
    var object = testing.object();
    var other = testing.object();
    object.radius = 100;
    other.radius = 50;
    other.root.next_position = .{ .x = 0, .y = 0, .z = 149 };
    try std.testing.expect(object.overlaps(&other, 0));
    // Touching is not overlapping; widened, they overlap again.
    other.root.next_position.z = 150;
    try std.testing.expect(!object.overlaps(&other, 0));
    try std.testing.expect(object.overlaps(&other, 1));
    // Only where the next step has them counts, not where they stand now.
    other.root.position = .{ .x = 0, .y = 0, .z = 10 };
    try std.testing.expect(!other.overlaps(&object, 0));
}

test "GameObject.letGo" {
    var object = testing.object();
    object.throttle = 1;
    object.yaw_input = 0.5;
    object.pitch_input = -0.5;
    object.roll_input = 0.25;
    object.letGo();
    try std.testing.expectEqual(0, object.throttle);
    try std.testing.expectEqual(0, object.yaw_input);
    try std.testing.expectEqual(0, object.pitch_input);
    try std.testing.expectEqual(0, object.roll_input);
}

test "Type.twin" {
    // The first twelve types have their twins from `player_twins_first`, which stand for them again.
    try std.testing.expectEqual(Type.t_phoenix, Type.phoenix.twin().?);
    try std.testing.expectEqual(Type.grendel, Type.grendel.twin().?.untwinned());
    try std.testing.expectEqual(null, Type.reliant.twin());
    try std.testing.expectEqual(null, Type.t_phoenix.twin());
}

test "Type.rock" {
    try std.testing.expectEqual(.asteroid, Type.rock(@enumFromInt(0x7F)));
    try std.testing.expectEqual(.turret, Type.rock(@enumFromInt(0x85)));
    try std.testing.expectEqual(.hole, Type.rock(@enumFromInt(0xF3)));
    try std.testing.expectEqual(null, Type.rock(@enumFromInt(0x80)));
    try std.testing.expectEqual(null, Type.predator.rock());
    try std.testing.expect(!Type.isAsteroid(@enumFromInt(0x85)));
    try std.testing.expectEqual(0x79, Type.asteroid(0).number());
    try std.testing.expectEqual(0x7F, Type.asteroid(6).number());
    try std.testing.expectEqual(0x79, Type.asteroid(7).number());
}

test GunMode {
    try std.testing.expectEqual(0x20, @as(u16, @bitCast(GunMode.created(1))));
    try std.testing.expectEqual(0x30, @as(u16, @bitCast(GunMode.created(3))));
}

/// A record's `Vec3` as a vector, and back.
pub fn vector(v: shp.Vec3) math.Vector {
    return .{ v.x, v.y, v.z };
}

pub fn vec3(v: math.Vector) shp.Vec3 {
    return .{ .x = v[0], .y = v[1], .z = v[2] };
}

/// `object_knock` (`0x004763C0`): a push of `force` on the object at the world point `at`, from a
/// collision or an explosion. The force is added to the impulse, and force × lever, the lever
/// running from the object's position to `at`, to the angular impulse. The next move applies both
/// (`applyKnocks`).
pub fn knock(object: *GameObject, force: math.Vector, at: math.Vector) void {
    const lever = at - vector(object.root.position);
    object.impulse = vec3(vector(object.impulse) + force);
    object.angular_impulse = vec3(vector(object.angular_impulse) + math.cross(force, lever));
    object.knocks += 1;
}

/// `object_knock_local` (`0x00476430`): `knock` with `force` in the object's own frame and the
/// lever given directly. The Disrupted order pushes a ship with it, with no lever
/// (`order_disrupted_init`).
pub fn knockLocal(object: *GameObject, force: math.Vector, lever: math.Vector) void {
    const push = math.transform(object.root.orientation, force);
    object.impulse = vec3(vector(object.impulse) + push);
    object.angular_impulse = vec3(vector(object.angular_impulse) + math.cross(push, lever));
    object.knocks += 1;
}

/// `object_apply_knocks` (`0x00476270`): applies the knocks taken since the last move, then
/// clears them. The impulse divided by the mass is added to the velocity. The angular impulse is
/// converted to the object's frame and multiplied by `angular_response`, and `rotation` is turned
/// by the result, to first order, and orthonormalized. The angular rates are set to the angles of
/// the new rotation, so the object keeps spinning until its steering takes over again.
pub fn applyKnocks(object: *GameObject) void {
    if (object.knocks == 0) return;
    object.knocks = 0;
    // `vec3_divide_by` multiplies by the reciprocal.
    const impulse = vector(object.impulse) * @as(math.Vector, @splat(1 / object.mass));
    object.velocity = vec3(vector(object.velocity) + impulse);
    const angular = vector(object.angular_impulse);
    if (@reduce(.Or, angular != @as(math.Vector, @splat(0)))) {
        const turn = math.transform(object.angular_response, math.transformTransposed(object.root.orientation, angular));
        // The angular impulse is the opposite of the torque, so the object turns by its negative.
        object.rotation = math.orthonormalize(math.product(object.rotation, math.smallTurn(-turn)));
        const rates = math.angles(object.rotation);
        object.pitch_rate = rates[0];
        object.yaw_rate = rates[1];
        object.roll_rate = rates[2];
    }
    object.impulse = vec3(@splat(0));
    object.angular_impulse = vec3(@splat(0));
}

/// What the player has shifted into the fore and aft shields beyond their full charge with SHIELD
/// BALANCING (`input.power.balanceShields`), which keeps the other side's charge down as the
/// shields recharge (`rechargeShields`).
pub const ShieldReserves = struct {
    /// Beyond the fore shield, `shields.fore` (`0x0051CF78`).
    fore: f32 = 0,
    /// Beyond the aft shield, `shields.aft` (`0x0051CF34`).
    aft: f32 = 0,

    /// The reserve a hit on `quadrant` draws on before the shield does, where it has one.
    pub fn of(reserves: *ShieldReserves, quadrant: collision.Quadrant) ?*f32 {
        return switch (quadrant) {
            .fore => &reserves.fore,
            .aft => &reserves.aft,
            .left, .right => null,
        };
    }

    /// A shot, a knock or a missile of `amount` on `quadrant`, taken off the reserve there while it
    /// holds anything (`bullet_hit`, `collision_damage`, `missiles.collide`): whether it held,
    /// sparing the shield. One that
    /// runs out is emptied, and the shield takes the whole hit.
    pub fn spare(reserves: *ShieldReserves, quadrant: collision.Quadrant, amount: f32) bool {
        const reserve = reserves.of(quadrant) orelse return false;
        if (!(reserve.* > 0)) return false;
        reserve.* -= amount;
        if (reserve.* > 0) return true;
        reserve.* = 0;
        return false;
    }
};

test ShieldReserves {
    var reserves: ShieldReserves = .{ .fore = 1, .aft = 2 };
    try std.testing.expectEqual(&reserves.fore, reserves.of(.fore).?);
    try std.testing.expectEqual(&reserves.aft, reserves.of(.aft).?);
    try std.testing.expectEqual(null, reserves.of(.left));

    // A hit the fore reserve holds spares the shield; one it runs out on doesn't, and empties it.
    try std.testing.expect(reserves.spare(.fore, 0.5));
    try std.testing.expectEqual(0.5, reserves.fore);
    try std.testing.expect(!reserves.spare(.fore, 1));
    try std.testing.expectEqual(0, reserves.fore);
    try std.testing.expect(!reserves.spare(.fore, 1));
    try std.testing.expect(!reserves.spare(.left, 1));
}

/// `object_recharge_shields` (`0x00476FC0`), which `simulation_step` runs for every object after
/// its node update. Each shield gains its full charge, `6 * ShipCombat.shield_power - 1`, times
/// `shield_factor` and `shield_condition`, over `ShipCombat.shield_recharge` seconds of steps,
/// and stops at the full charge. For the player's ship, `reserves` are the shields shifted fore or
/// aft: the full charge of the fore and aft shields is lower by however far the other one and its
/// reserve go beyond it.
///
/// An object whose components are listed recharges no shields here, and neither does one holding
/// the `no_shield_recharge` power-up. One whose `invulnerable` is `_unknown_5` has its shields
/// emptied instead. **Unknown:** what that value means. Not ported: the case in a multiplayer game
/// where the player's shields aren't recharged (`0x005D76F0` at 4 with `0x005DB538` naming the
/// player).
pub fn rechargeShields(object: *GameObject, combat: *const create.ShipCombat, reserves: ?ShieldReserves) void {
    if (object.flags.components) return;
    if (object.invulnerable == ._unknown_5) {
        object.shields = .all(0);
        return;
    }
    if (object.power_up == .no_shield_recharge) return;
    const full = combat.fullShields() - 1;
    const rate = full * object.shield_factor * object.shield_condition / (combat.shield_recharge * recharge_steps);
    for (std.enums.values(collision.Quadrant)) |quadrant| {
        const shield = object.shields.at(quadrant);
        var most = full;
        if (reserves) |shifted| {
            const other: ?f32 = switch (quadrant) {
                .fore => shifted.aft + object.shields.aft,
                .aft => shifted.fore + object.shields.fore,
                .left, .right => null,
            };
            if (other) |beside| if (beside > most) {
                most -= beside - most;
            };
        }
        shield.* = rate + shield.*;
        if (shield.* > most) shield.* = most;
    }
}

/// Simulation steps a second, which `ShipCombat.shield_recharge` is counted in (`0x004DC7F0`).
const recharge_steps: f32 = 25;

/// A new object's `blink_offset` (`object_alloc`, `0x00475DD0`): C's `rand()` over its largest
/// value (`libcmt.Rand.fraction`), times `blink_range`, truncated.
pub fn blinkOffset(random: *libcmt.Rand) i16 {
    return @intFromFloat(random.fraction() * blink_range);
}

/// The ticks a new object's lights may stand into their blinks, at most (`0x004DC440`).
const blink_range: f32 = 100;

/// `object_alloc` (`0x00475DD0`): a new object of `object_type`. `SR_MEM_allocate` clears what
/// it hands out, so everything the allocation doesn't set starts at zero: the object is at rest,
/// turned by nothing each update, and has no motion, orders or renderer's object. Its root is
/// flagged as a component, and it draws its `blink_offset` from `random`.
pub fn objectAlloc(object_type: Type, random: *libcmt.Rand) GameObject {
    var object = std.mem.zeroes(GameObject);
    object.type = object_type;
    object.rotation = math.identity;
    object.power_up = .none;
    object._unknown_764 = -1;
    object.root.flags.component = true;
    object.sound_voice = .none;
    object.blink_offset = blinkOffset(random);
    object.visibility = 1;
    return object;
}

test objectAlloc {
    var random: libcmt.Rand = .{};
    const object = objectAlloc(.stand_in, &random);
    try std.testing.expectEqual(Type.stand_in, object.type);
    try std.testing.expectEqual(math.identity, object.rotation);
    try std.testing.expect(object.root.flags.component);
    try std.testing.expectEqual(1, object.visibility);
    // The runtime's first number from its first seed gives the first object no offset.
    try std.testing.expectEqual(0, object.blink_offset);
    try std.testing.expect(!object.created);
}

// --- The simulation's step ---------------------------------------------------------------

/// The game ticks a simulation step takes: it steps on every fourth.
pub const ticks_per_step = 4;

/// What a simulation step works on besides the clock and the devices, which the game keeps in
/// globals: the live objects, the player's controls, and the camera's view and shake. The cruise
/// speed reads the view (`object_cruise_speed`), and the player's speed raises the shake
/// (`object_move`).
pub const World = struct {
    objects: *create.Objects,
    player: *input.Player,
    /// The mission's clocks, whose `frame_start` the game's code reads as a global.
    clock: *const Clock,
    /// The game's difficulty, which scales damage (`collision.byDifficulty`).
    difficulty: collision.Difficulty = .medium,
    view: camera.View,
    shake: *f32,
    /// The runtime's numbers (`libcmt.Rand`), which the guns' step draws a damaged gun's misfire
    /// from.
    random: *libcmt.Rand,
    /// The sound the objects are heard through, and where from; null where nothing is heard.
    hearing: ?@import("hog_snd.zig").Hearing = null,
    /// The camera, whose view the game's code switches (`camera_set_view`); null where nothing is
    /// seen, as in a test.
    camera: ?*camera.Camera = null,
    /// What the explosions leave for the frames after them (`explode.cpp`); null where nothing
    /// explodes.
    explosions: ?*@import("explode.zig").Explosions = null,
    /// The pool particles come from; null where none are sent out.
    particles: ?*@import("particles.zig").Pool = null,
    /// The shockwaves spreading (`shockwave.cpp`); null where none spread.
    shockwaves: ?*@import("shockwave.zig").Shockwaves = null,
    /// The missiles' and torpedoes' trails; null where none are left.
    trails: ?*missiles.trail.Trails = null,
    /// The countermeasures in flight (`cloak.cpp`); null where none are dropped.
    countermeasures: ?*@import("cloak.zig").Countermeasures = null,
    /// The shields' bubbles' meshes and colours (`shield.cpp`); null where none are drawn.
    shields: ?*@import("shield.zig").Shields = null,
    /// The electric rays (`erayfx.cpp`); null where none are made.
    rays: ?*@import("erayfx.zig").Rays = null,
    /// The tractors (`tractor.cpp`); null where no ship takes another aboard.
    tractors: ?*@import("tractor.zig").Tractors = null,
    /// The screen's flash (`main.cpp`); null where nothing flashes.
    flash: ?*@import("main/flash.zig").Flash = null,
    /// The force feedback the player's controller plays; null where it plays none.
    forces: ?*input.force.Forces = null,
    /// The sparks flying (`sparks.cpp`); null where none are thrown.
    sparks: ?*@import("sparks.zig").Sparks = null,
    /// The head-up display's state (`hud.cpp`'s globals), which smart targeting and the target
    /// display answer the player's hits through; null where there is none.
    display: ?*@import("hud.zig").State = null,
    /// The cockpit's model (`cockpit_object`, `0x005883F4`), where the player's ship has one.
    cockpit: ?*objects.Model = null,
    /// The pools a damaged ship's smoke comes from; null where none is sent out.
    smoke: ?*@import("main/smoke.zig").Pools = null,
    /// The guns' pools, a flak shell's burst's and the spent cases'; null where none are sent out.
    gun_particles: ?*@import("guns.zig").effects.Pools = null,
    /// What objects are made from while the mission runs, as a capital ship's split makes its
    /// other half (`create_object`), and the ship types' flight models, which the plain motions fly
    /// fighters by (`motion.Flight`); null where none are made.
    spawn: ?Spawn = null,
    /// The mission's records, through which an order aimed at a flight group or a squad reaches
    /// their ships (`ai.eachShip`); null where no mission is bound, as in a test.
    mission: ?*const @import("mission/bind.zig").Mission = null,
    /// What the mission's script asks of its space (`environfx.cpp`); null where nothing is drawn.
    environment: ?*@import("environfx.zig").Environment = null,

    /// The ship types' stats and their models.
    pub const Spawn = struct {
        tables: *create.Stats,
        types: create.Types,
    };

    /// What particles are sent out with, as the camera sees them, their sparks going to the
    /// explosions; null where nothing is seen.
    pub fn sending(world: World) ?@import("particles.zig").Sending {
        const seen = world.camera orelse return null;
        return .{ .view = seen.place, .clock = world.clock, .random = world.random, .explosions = world.explosions };
    }
};

/// `simulation_step` (`0x004774D0`): the work of every fourth tick, so 25 times a second, which
/// is why the [flight model](../../../docs/engine/objects.md#motion) moves at that rate.
/// **Unverified:** it and `game_tick` lie after this file's known code, before `guns.cpp`'s. It
/// reads the input devices and moves `simulation_turn` on (`nextTurn`). Then each live object in
/// the loops' order (`create.Objects.walk`), stand-ins and disabled ones passed over, has its own
/// updates: the one whose turn it is is orthonormalized (`orthonormalizeTurn`), then comes its
/// node update (`updateTree`), its shields' recharge (`rechargeShields`) and its guns' step
/// (`guns.step`). Then
/// the player's controls fly the player's ship, `objects_update` moves them all
/// (`create.objectsUpdate`), and the missiles (`missiles.move`) and the shots (`guns.moveBullets`)
/// move after them. Returns whether it did that work.
///
/// The player's own order runs here as well as once a frame, while its top order is Player
/// Control, so the controls are read on every step.
///
/// Not ported yet: the mouse.
pub fn simulationStep(clock: *Clock, devices: *input.Devices, world: World) bool {
    clock.simulation_counter += 1;
    if (clock.simulation_counter < ticks_per_step) return false;
    devices.read();
    clock.simulation_counter = 0;
    const all = world.objects;
    const turn = nextTurn(clock, all.count);
    var slots = all.walk();
    while (slots.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.flags.stand_in or object.flags.disabled) continue;
        if (index == turn) orthonormalizeTurn(&object.root);
        var live = world;
        updateTree(&object.root, if (slot.model) |*model| model else null, guns.clipEvents(&live, @intCast(index)));
        const combat = slot.combat orelse continue;
        rechargeShields(object, combat, if (index == all.player) world.player.shield_reserves else null);
        guns.step(world, clock, index);
    }
    // The player's own order runs again here, before the objects move, so the controls tell on
    // every step rather than once a frame.
    const player = &all.slots[all.player];
    if (player.object.order_count > 0 and player.orders[0].order == .player_control) {
        aigeneric.objectOrders(.{ .world = world, .clock = clock, .devices = devices }, all.player);
    }
    create.objectsUpdate(world);
    missiles.move(world.objects);
    guns.moveBullets(world);
    return true;
}

/// Moves `simulation_turn` on to the next of `objects` live objects, as `simulation_step` does
/// once a step before the objects' own updates, and returns it. That object's orientation is
/// orthonormalized this step (`orthonormalizeTurn`), so each object gets its turn in rotation.
pub fn nextTurn(clock: *Clock, objects_live: u32) u32 {
    clock.simulation_turn += 1;
    if (clock.simulation_turn >= objects_live) clock.simulation_turn = 0;
    return clock.simulation_turn;
}

/// `game_tick` (`0x00477850`): one tick of the mission. Paused, it counts the tick and does
/// nothing else. Returns whether the simulation stepped.
///
/// Not ported: the countdown at `0x0052A474` that it steps once a second, and the timed
/// sections it brackets the tick with outside a network game.
pub fn gameTick(clock: *Clock, devices: *input.Devices, world: World) bool {
    if (clock.paused) {
        clock.paused_ticks +%= 1;
        return false;
    }
    clock.mission_ticks +%= 1;
    return simulationStep(clock, devices, world);
}

/// What `simulation_step` does for the object whose turn it is (`Clock.nextTurn`), before its node
/// update: orthonormalizes the root's next orientation (`mat3_orthonormalize`), so that rounding
/// doesn't build up in the matrix from one step to the next. The game does the same to the
/// orientation at `GameObject + 0x7A4`, which a multiplayer game draws other players' ships by;
/// OpenReliant doesn't keep that one yet (#55).
pub fn orthonormalizeTurn(root: *objects.Node) void {
    root.next_orientation = math.orthonormalize(root.next_orientation);
}

// --- The node tree -------------------------------------------------------------------------

/// `object_link_parts` (`0x00476130`): links each part to the part it names, or to the root
/// (`linkPart`), then moves the object's origin to its parts' centre of mass (`recentre`).
/// `source` is the model the parts come from.
pub fn linkParts(model: *objects.Model, source: *const shp.Model) void {
    for (0..model.parts.len) |index| linkPart(model, index);
    recentre(model, source);
}

/// `object_link_part` (`0x00476180`) once the part hangs from its parent: poses it as its track
/// has it at the start (`node_animate` at time zero), which is its first unless one was started,
/// and takes the place that gives it, but not the pose, as its node's place and its frame's. Its
/// next place stays in the node, and the four flags the steps and the frames keep of it are
/// cleared: pending, committed, unframed and posed.
pub fn linkPart(model: *objects.Model, index: usize) void {
    const part = &model.parts[index];
    model.animate(index, 0);
    const a = &part.animation;
    a.now.place = a.next.place;
    part.origin = a.next.place.position;
    part.turn = a.next.place.orientation;
    a.pending = false;
    a.committed = false;
    a.unframed = false;
    a.posed = false;
}

/// `object_recentre` (`0x004769F0`) for a live object in `slot`: moves its origin to the centre of
/// mass of its shown parts (`recentre`), its root's place and next place, and its frame, going
/// with it, so that it stays where it was, and keeps what that works out.
pub fn recentreObject(slot: *create.Slot) void {
    const model = if (slot.model) |*live| live else return;
    const source = (slot.type orelse return).model;
    const object = &slot.object;
    const before = model.centre;
    recentre(model, source);
    const shift = math.transform(object.root.orientation, model.centre - before);
    object.root.position = vec3(vector(object.root.position) + shift);
    object.root.next_position = vec3(vector(object.root.next_position) + shift);
    slot.drawn.position += shift;
    object.mass = model.mass;
    object.centre = vec3(model.centre);
    object.radius = model.radius;
    object.angular_response = model.angular_response;
    object.bounds_min = vec3(model.bounds[0]);
    object.bounds_max = vec3(model.bounds[1]);
}

/// Moves the object's origin to its parts' centre of mass, as `object_link_parts` ends
/// (`object_recentre`, `0x004769F0`). `node_mass_add` (`0x004764A0`) sums, over the shown
/// parts, the density times the part's first moment about the root, its origin times its
/// volume plus its own first moment; over the parts' masses, density times volume, that is the
/// centre. `object_bounds` (`0x00476680`) takes it off each part's origin, then finds the
/// object's radius and bounding box over the vertices of each part's current level, hidden ones
/// too but not those taken out of the model (`objects.Model.Part.removed`), whose nodes the game
/// has gone from the root. `source` is the model the parts come from.
pub fn recentre(model: *objects.Model, source: *const shp.Model) void {
    // Each part's origin in the model, which is where it stands with the root at rest.
    model.place(@splat(0), math.identity);
    var moment: [3]f32 = @splat(0);
    var mass: f32 = 0;
    for (model.parts, source.parts) |part, data| {
        if (part.hidden) continue;
        const p = data.part;
        const origin: [3]f32 = part.object.position;
        for (&moment, origin, p.first_moments) |*m, o, first| m.* = (o * p.volume + first) * p.density + m.*;
        mass = p.density * p.volume + mass;
    }
    model.mass = mass;
    if (mass > 0) {
        const scale = 1 / mass;
        for (&moment) |*m| m.* = scale * m.*;
    }
    const centre: Vector = moment;
    model.centre += centre;
    // Only a part standing at the root moves: one hanging from another keeps the origin it has
    // in its parent, and follows it. What stands on a part likewise moves with the part.
    // `object_bounds` moves the node's place, its next place and its frame alike.
    for (model.parts) |*part| {
        if (part.parent != null) continue;
        part.origin -= centre;
        part.animation.now.place.position -= centre;
        part.animation.next.place.position -= centre;
    }

    model.place(@splat(0), math.identity);
    model.radius = 0;
    model.bounds = .{ @splat(std.math.floatMax(f32)), @splat(-std.math.floatMax(f32)) };
    var tensor: math.Matrix = @splat(0);
    for (model.parts, source.parts) |part, data| {
        if (part.removed) continue;
        if (part.object.levels.len > 0) {
            for (part.object.levels[part.object.level].mesh.positions) |position| {
                const at = position + part.object.position;
                model.bounds = .{ @min(model.bounds[0], at), @max(model.bounds[1], at) };
                model.radius = @max(model.radius, math.length(at));
            }
        }
        if (part.hidden) continue;
        for (&tensor, partInertia(part.object.position, &data.part)) |*sum, term| sum.* += term;
    }
    // The tensor is built as its own lower half, which the upper half mirrors before it is
    // inverted, since the two are the same for it.
    tensor[1] = tensor[3];
    tensor[2] = tensor[6];
    tensor[5] = tensor[7];
    // A model whose parts have no volume, as a few do, leaves a tensor that cannot be inverted: the
    // game divides by its determinant whatever it is, and OpenReliant leaves nothing to turn by.
    model.angular_response = math.inverse(tensor) orelse @splat(0);
}

/// What a part adds to its object's inertia tensor (`object_bounds`), with `at` its origin in the
/// object's frame: its second moments about the two other axes on the diagonal and its products off
/// it, each with the term its distance from the object's own origin adds, all times its density.
///
/// The part's own frame is not taken into account, so a part that its model turns counts as though
/// it stood square.
fn partInertia(at: math.Vector, part: *const shp.Part) math.Matrix {
    const first = part.first_moments;
    const second = part.second_moments;
    const products = part.products;
    const volume = part.volume;
    var own: math.Matrix = @splat(0);
    own[0] = -(2 * at[1] * first[1] + 2 * at[2] * first[2] + at[2] * at[2] * volume + at[1] * at[1] * volume + second[1] + second[2]);
    own[4] = -(2 * at[0] * first[0] + 2 * at[2] * first[2] + at[2] * at[2] * volume + at[0] * at[0] * volume + second[0] + second[2]);
    own[8] = -(2 * at[1] * first[1] + 2 * at[0] * first[0] + at[1] * at[1] * volume + at[0] * at[0] * volume + second[1] + second[0]);
    own[3] = at[1] * first[0] + (at[1] * volume + first[1]) * at[0] + products[0];
    own[6] = at[2] * first[0] + (at[2] * volume + first[2]) * at[0] + products[2];
    own[7] = at[2] * first[1] + (at[2] * volume + first[2]) * at[1] + products[1];
    for (&own) |*term| term.* *= -part.density;
    return own;
}

/// `node_tree_update` (`0x00476C90`), which `simulation_step` runs for every live object at the
/// start of each step, before the objects move. For the object's root and each descendant that is
/// animating, it commits the node's pending next place (`Node.commitNext`), advances the node's
/// animation and fires its keyframe events. So an object moves from the place the previous step
/// worked out, and until the next step its `position` stays one step behind `next_position`, which
/// is what the rest of the game reads as its place.
///
/// The root has no part, so it plays no track of its own: it stays marked as animating while a part
/// standing at it does. OpenReliant keeps the part nodes in the object's `Model`, which goes on
/// with the walk (`walk`).
pub fn updateTree(root: *Node, model: ?*objects.Model, events: ?Events) void {
    root.commitNext();
    root.flags.animating = if (model) |parts| walk(parts, events) else false;
}

/// The nodes `node_tree_update` can hold on its stack at once, which is as far into a model as
/// OpenReliant's walks go.
pub const walk_room = 500;

/// The spans of a track's time whose events `node_tree_update` sets off as a node passes
/// them: two, each from its first figure up to but not including its second. The game keeps
/// them from node to node, so a node that sets neither checks the last node's.
const Windows = struct {
    first: [2]i32 = .{ 0, 0 },
    second: [2]i32 = .{ 0, 0 },

    fn passes(windows: Windows, time: i32) bool {
        return (windows.first[0] <= time and time < windows.first[1]) or
            (windows.second[0] <= time and time < windows.second[1]);
    }
};

/// The part nodes' share of `node_tree_update` (`updateTree`), once each simulation step. It keeps
/// a stack of nodes: the root pushes each of its children that is shown and animating, which is
/// every part whatever it is linked to, in part order; the node on top is taken off and visited,
/// and pushes in turn the roots of the models it carries that are animating, and each of those its
/// own parts. So the nodes are visited depth first, the last pushed first. A visit commits the
/// place the last step worked out, moves the node on through its track, poses the part for the
/// next step, and sets off the track's events it passes; a node playing no track stops animating,
/// but one that pushes an animating node stays marked. Returns whether the root pushed any part,
/// which keeps the root marked.
///
/// The game marks a node animating and every node it hangs from, up through a model's root to the
/// part carrying it (`node_mark_animating`); OpenReliant marks up to a model's root
/// (`objects.Model.markAnimating`), and takes a part as animating, or a model's root, while it
/// carries a model that has an animating part.
fn walk(model: *objects.Model, events: ?Events) bool {
    var windows: Windows = .{};
    var stack: Stack = .{};
    const any = stack.pushParts(model);
    while (stack.pop()) |node| switch (node) {
        .root => |held| _ = stack.pushParts(held),
        .part => |at| {
            visit(at.model, at.index, &windows, events);
            var each = at.model.carriedBy(at.index);
            while (each.next()) |mount| {
                if (!rootAnimating(&mount.model)) continue;
                stack.push(.{ .root = &mount.model });
                at.model.parts[at.index].animation.animating = true;
            }
        },
    };
    return any;
}

/// `node_tree_update`'s stack of nodes still to visit (`walk_room` of them): a model's root, or one
/// of its parts. A node past its room is passed over, where the game writes past the stack.
const Stack = struct {
    nodes: [walk_room]Entry = undefined,
    count: usize = 0,

    const Entry = union(enum) {
        root: *objects.Model,
        part: objects.PartRef,
    };

    fn push(stack: *Stack, node: Entry) void {
        if (stack.count == walk_room) return;
        stack.nodes[stack.count] = node;
        stack.count += 1;
    }

    fn pop(stack: *Stack) ?Entry {
        if (stack.count == 0) return null;
        stack.count -= 1;
        return stack.nodes[stack.count];
    }

    /// A root's visit: each of its parts, in order, that is shown and animating. Whether it pushed
    /// any.
    fn pushParts(stack: *Stack, model: *objects.Model) bool {
        var any = false;
        for (0..model.parts.len) |index| {
            if (!pushed(model, index)) continue;
            stack.push(.{ .part = .{ .model = model, .index = index } });
            any = true;
        }
        return any;
    }
};

/// Whether its root pushes part `index` of `model`: one that is shown and animating, or carries a
/// model whose root is.
fn pushed(model: *const objects.Model, index: usize) bool {
    const part = &model.parts[index];
    return !part.hidden and (part.animation.animating or carriesAnimating(model, index));
}

/// Whether a model's root is marked animating: while it pushes any of its parts.
fn rootAnimating(model: *const objects.Model) bool {
    for (0..model.parts.len) |index| {
        if (pushed(model, index)) return true;
    }
    return false;
}

fn carriesAnimating(model: *const objects.Model, index: usize) bool {
    var each = model.carriedBy(index);
    while (each.next()) |mount| {
        if (rootAnimating(&mount.model)) return true;
    }
    return false;
}

/// One part node's visit in `node_tree_update`.
fn visit(model: *objects.Model, index: usize, windows: *Windows, events: ?Events) void {
    const a = &model.parts[index].animation;
    a.committed = false;
    a.posed = false;
    if (a.pending) {
        a.now = a.next;
        a.pending = false;
        a.committed = true;
        a.unframed = true;
    }
    if (a.mode == .none or a.speed == 0) {
        a.animating = false;
        return;
    }
    if (a.track >= a.tracks.len) return;
    const track = &a.tracks[a.track];
    const was = a.time;
    const time = a.speed + a.time;
    a.time = time;
    const length: f32 = @floatFromInt(track.clip.length);
    if (length > 0) switch (a.mode) {
        .once => {
            // To the end, or back to the start, and there it stops.
            if (time >= length) {
                a.time = length;
                a.speed = 0;
            }
            if (!(a.time > 0)) {
                a.time = 0;
                a.speed = 0;
            }
            const span: [2]i32 = .{ math.round(was), math.round(a.time) };
            windows.* = .{ .first = span, .second = span };
            model.animate(index, a.time);
        },
        .loop => {
            const span: [2]i32 = .{ math.round(was), math.round(time) };
            windows.* = .{ .first = span, .second = span };
            // Past the end it starts again: the events from where it was to the end go off,
            // then those from the start to where it is.
            if (a.time > length) {
                windows.second[0] = 0;
                while (true) {
                    a.time -= length;
                    windows.first = .{ math.round(was), math.round(length) };
                    windows.second[1] = math.round(a.time);
                    if (!(a.time > length)) break;
                }
            }
            model.animate(index, a.time);
        },
        .swing => {
            // Out to the end over the first length and back over the second; no events go off.
            const both = length + length;
            if (time > both) {
                while (true) {
                    a.time -= both;
                    if (!(a.time > both)) break;
                }
            }
            model.animate(index, if (a.time > length) both - a.time else a.time);
            windows.* = .{};
        },
        else => {},
    };
    const sink = events orelse return;
    for (track.events) |event| {
        if (!windows.passes(event.time)) continue;
        switch (event.kind) {
            .muzzles, .puff => sink.fire(sink.context, sink.owner, model, index, event.kind),
            _ => {},
        }
    }
}

/// Whoever sets off the effects of the events the tracks of the model of the object in slot
/// `owner` pass: the game's own (`guns.clipEvents`), or a test's.
pub const Events = struct {
    context: *anyopaque,
    owner: u16 = 0,
    fire: *const fn (context: *anyopaque, owner: u16, model: *objects.Model, part: usize, kind: shp.ClipEvent.Kind) void,
};

/// Fixtures for the tests here and in the modules that move objects.
pub const testing = struct {
    /// A light fighter's flight stats, near the Predator's.
    pub const flight: create.FlightModel = .{
        .max_speed = 320,
        .roll_rate = 3,
        .pitch_rate = 2,
        .yaw_rate = 1.5,
        .inertia = 0.9,
        .roll_inertia = 0.8,
        .pitch_inertia = 0.8,
        .yaw_inertia = 0.8,
        .speed_per_pitch_rate = 160,
        ._unknown_24 = 0,
    };

    /// An object as `create_object` leaves one: undamaged, at rest, facing along its own nose.
    pub fn object() GameObject {
        var made: GameObject = std.mem.zeroes(GameObject);
        made.root.orientation = math.identity;
        made.root.next_orientation = math.identity;
        made.speed_factor = 1;
        made.armor_speed_factor = 1;
        made.engines_intact = 1;
        return made;
    }

    /// A mission with nothing in it but what a test puts there: objects with no models, the stats
    /// they are made from, and what their world points at. It stays where `init` fills it in, as
    /// the world points into it.
    pub const Mission = struct {
        random: libcmt.Rand,
        objects: *create.Objects,
        tables: create.Stats,
        player: input.Player,
        shake: f32,
        clock: Clock,
        view: camera.View,

        /// Fills in every field, so a field added here has to be filled in too.
        pub fn init(mission: *Mission, gpa: std.mem.Allocator) !void {
            mission.* = .{
                .random = .{},
                .objects = undefined,
                .tables = create.testing.tables(),
                .player = .{},
                .shake = 0,
                .clock = .{},
                .view = .chase,
            };
            mission.objects = try .create(gpa, &mission.random);
        }

        pub fn deinit(mission: *Mission) void {
            mission.objects.destroy();
        }

        pub fn world(mission: *Mission) World {
            return .{ .objects = mission.objects, .player = &mission.player, .clock = &mission.clock, .view = mission.view, .shake = &mission.shake, .random = &mission.random };
        }

        /// What the objects' orders run against.
        pub fn orders(mission: *Mission) aigeneric.Context {
            return .{ .world = mission.world(), .clock = &mission.clock };
        }

        /// An object of `ship_type` at `at`, in the next slot.
        pub fn add(mission: *Mission, ship_type: Type, at: Vector) !u16 {
            return create.createObject(mission.objects, &mission.tables, create.testing.no_models, null, ship_type, 0, at, &mission.random);
        }

        /// A ship that is nobody's, at `at`, which takes the orders the player's refuses: the
        /// player holds the first slot, so the ship comes after it.
        pub fn addOther(mission: *Mission, at: Vector) !u16 {
            if (mission.objects.count == 0) _ = try mission.add(.predator, @splat(0));
            return mission.add(.predator, at);
        }

        pub fn slot(mission: *Mission, index: u16) *create.Slot {
            return &mission.objects.slots[index];
        }
    };
};

test Quadrants {
    var shields: Quadrants = .all(5);
    shields.at(.aft).* = 2;
    // Each quadrant is the field of its name, and in the game's order among them.
    try std.testing.expectEqual(2, shields.aft);
    try std.testing.expectEqual(5, shields.get(.fore));
    try std.testing.expectEqual([4]f32{ 5, 5, 5, 2 }, shields.values());
    try std.testing.expectEqual(17, shields.total());
    try std.testing.expectEqual(2, shields.weakest());
}

test "a knock pushes and turns an object" {
    var object = testing.object();
    object.rotation = math.identity;
    object.mass = 4;
    object.angular_response = math.identity;
    object.throttle = 1;
    // A push to the side on the nose: the object moves off to that side and turns its nose there.
    knock(&object, .{ 0.02, 0, 0 }, .{ 0, 0, 1 });
    try std.testing.expectEqual(1, object.knocks);
    motion.move(&object, .{ .own = &testing.flight }, .chase, .forward, null);
    try std.testing.expectEqual(0, object.knocks);
    // The knock replaces the motion routine, so the throttle adds nothing this update.
    try std.testing.expectEqual(math.Vector{ 0.005, 0, 0 }, vector(object.velocity));
    try std.testing.expectApproxEqAbs(0.02, object.yaw_rate, 2e-4);
    try std.testing.expectApproxEqAbs(0, object.pitch_rate, 2e-4);
    try std.testing.expectApproxEqAbs(0, object.roll_rate, 2e-4);
    try std.testing.expect(object.root.next_orientation[2] > 0);
    try std.testing.expectEqual(math.Vector{ 0, 0, 0 }, vector(object.impulse));
    try std.testing.expectEqual(math.Vector{ 0, 0, 0 }, vector(object.angular_impulse));
}

test knockLocal {
    // Facing +X, a push forward in its own frame moves the object along +X.
    var object = testing.object();
    object.root.orientation = math.rotation(.y, std.math.pi / 2.0);
    object.rotation = math.identity;
    object.mass = 2;
    knockLocal(&object, .{ 0, 0, 4 }, .{ 0, 0, 0 });
    applyKnocks(&object);
    try std.testing.expectApproxEqAbs(2, object.velocity.x, 1e-6);
    try std.testing.expectApproxEqAbs(0, object.velocity.z, 1e-6);
    // With no lever, it doesn't turn.
    try std.testing.expectEqual(0, object.yaw_rate);
}

test blinkOffset {
    var random: libcmt.Rand = .{};
    // The runtime's first number from its first seed is 41, 41 / 32767 of the way to 100.
    try std.testing.expectEqual(0, blinkOffset(&random));
    for (0..1000) |_| {
        const offset = blinkOffset(&random);
        try std.testing.expect(offset >= 0 and offset <= 100);
    }
    // The largest number C's `rand()` gives makes 100, its share of the way rounding up to 1 in
    // single precision. The seed that gives it is the runtime's step run backwards from one whose
    // bits 16 to 30 are all set.
    const step: u32 = 214013;
    var inverse: u32 = step;
    for (0..5) |_| inverse *%= 2 -% step *% inverse;
    var largest: libcmt.Rand = .{ .seed = (0x7FFF_0000 -% 2531011) *% inverse };
    try std.testing.expectEqual(100, blinkOffset(&largest));
}

test rechargeShields {
    var object = testing.object();
    object.shield_factor = 1;
    object.shield_condition = 1;
    const combat = std.mem.zeroInit(create.ShipCombat, .{ .shield_power = 8, .shield_recharge = 10 });
    // From empty, the full charge, 47, comes back over the ten seconds of steps, and no further.
    for (0..249) |_| rechargeShields(&object, &combat, null);
    try std.testing.expect(object.shields.left < 47);
    rechargeShields(&object, &combat, null);
    try std.testing.expectApproxEqAbs(47, object.shields.left, 1e-3);
    rechargeShields(&object, &combat, null);
    try std.testing.expectEqual(47, object.shields.left);
    // With shields shifted aft beyond its full charge, the fore one charges only as far as the
    // full charge less the excess.
    object.shields = .{ .left = 47, .right = 47, .fore = 45, .aft = 40 };
    rechargeShields(&object, &combat, .{ .aft = 9 });
    try std.testing.expectEqual(45, object.shields.fore);
    // One holding the power-up that stops them recharges none.
    object.shields = .all(0);
    object.power_up = .no_shield_recharge;
    rechargeShields(&object, &combat, null);
    try std.testing.expectEqual(Quadrants.all(0), object.shields);
    object.power_up = .none;
    // An object whose `invulnerable` is `_unknown_5` loses its shields.
    object.invulnerable = ._unknown_5;
    rechargeShields(&object, &combat, null);
    try std.testing.expectEqual(Quadrants.all(0), object.shields);
}

test "a step updates and moves every live object" {
    const gpa = std.testing.allocator;
    var mission: testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.predator, @splat(0));
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });
    const off = try mission.add(.sabre, .{ 0, 0, 2000 });
    all.slots[other].object.throttle = 1;
    all.slots[off].object.throttle = 1;
    all.slots[off].object.flags.disabled = true;
    // Its shields down, the player's recharge.
    all.slots[player].object.shields = .all(0);
    var devices: input.Devices = .{};
    var steps: usize = 0;
    for (0..ticks_per_step * 10) |_| {
        if (gameTick(&mission.clock, &devices, mission.world())) steps += 1;
    }
    try std.testing.expectEqual(10, steps);
    // The other ship has flown on along its nose, its committed place a step behind.
    const flown = all.slots[other].object.root;
    try std.testing.expect(flown.next_position.z > 1000);
    try std.testing.expect(flown.position.z > 1000 and flown.position.z < flown.next_position.z);
    // The disabled one is passed over: never moved, nothing committed.
    try std.testing.expectEqual(2000, all.slots[off].object.root.next_position.z);
    try std.testing.expect(!all.slots[off].object.root.flags.next_pending);
    // No key held, the player's throttle stays at nothing, and it stays where it was.
    try std.testing.expectEqual(0, all.slots[player].object.root.next_position.z);
    try std.testing.expect(all.slots[player].object.shields.left > 0);
}

test "each object's turn comes round in rotation" {
    var clock: Clock = .{};
    var turns: [4]u32 = undefined;
    for (&turns) |*turn| turn.* = nextTurn(&clock, 3);
    try std.testing.expectEqual([4]u32{ 1, 2, 0, 1 }, turns);
    // With one object, every step is its turn.
    clock = .{};
    for (0..3) |_| try std.testing.expectEqual(0, nextTurn(&clock, 1));
}

test recentreObject {
    const gpa = std.testing.allocator;
    var mission: testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    const index = try create.createObject(mission.objects, &mission.tables, model.types(), null, .predator, 0, .{ 0, 0, 100 }, &mission.random);
    const slot = mission.slot(index);
    try std.testing.expect(slot.object.radius > 0);
    // A part taken out of the model, as an ejection takes the ship off the pod, counts toward
    // neither the object's size nor its mass, and the object stays where it was.
    slot.model.?.parts[0].removed = true;
    slot.model.?.parts[0].hidden = true;
    recentreObject(slot);
    try std.testing.expectEqual(0, slot.object.radius);
    try std.testing.expectEqual(0, slot.object.mass);
    try std.testing.expectEqual(Vector{ 0, 0, 100 }, slot.drawn.position);
}

test orthonormalizeTurn {
    // A skewed next orientation comes back square, keeping its forward axis.
    var root: Node = std.mem.zeroes(objects.Node);
    root.next_orientation = .{ 1.01, 0.02, 0, 0, 0.99, 0, 0.01, 0, 1 };
    orthonormalizeTurn(&root);
    const m = root.next_orientation;
    const back = math.product(math.transpose(m), m);
    for (math.identity, back) |expected, found| try std.testing.expectApproxEqAbs(expected, found, 1e-6);
    try std.testing.expectEqual(0, m[2]);
    try std.testing.expectEqual(0, m[5]);
}
