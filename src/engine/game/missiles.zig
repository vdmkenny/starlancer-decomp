//! `C:\lancer\game\missiles.cpp`: missiles. `stats_load_missiles` (`0x00494BC0`) fills
//! `missile_stats` and `missile_flight_stats` from `missilestats.bin`,
//! [`formats/stats.zig`](../../formats/stats.zig). **Unverified:** the file spans
//! `0x00494BC0`-`0x00498443`, the loader and `order_torpedo` among it, by the strings and the data
//! its code uses; the assertions name the path only from `0x00494CB0` to `0x00496B0E`.
//! [`missiles.md`](../../../docs/engine/missiles.md) describes the file.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const formats = @import("../../formats/stats.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const cloak = @import("cloak.zig");
const collision = @import("collision.zig");
const create = @import("create.zig");
const explode = @import("explode.zig");
const gameobj = @import("gameobj.zig");
const objects = @import("objects.zig");
const shield = @import("shield.zig");
const shieldfx = @import("shieldfx.zig");
const shockwave_mod = @import("shockwave.zig");
const sound3d = @import("sound3d.zig");
const Linked = @import("table.zig").Linked;
pub const trail = @import("missiles/trail.zig");
const FlightModel = create.FlightModel;
const GameObject = gameobj.GameObject;

/// How many missile types the tables hold: the loader reads no more records than this.
pub const type_count = 11;

/// A missile type: the id of a missile hardpoint (attachment kind 0), the type of a missile's
/// object, and the index into every missile table.
pub const Type = enum(i16) {
    /// A hardpoint that holds none, where a player's loadout leaves it empty.
    none = -1,
    screamer = 0,
    raptor = 1,
    havoc = 2,
    jack_hammer = 3,
    bandit = 4,
    vagabond = 5,
    solomon = 6,
    imp = 7,
    hawk = 8,
    /// Only the torpedoes' trail and sound: nothing launches a missile of this type.
    torpedo = 9,
    fuel_pod = 10,
    _,

    /// Its index into the tables, or null for none or a type past them.
    pub fn index(missile: Type) ?usize {
        const number = @intFromEnum(missile);
        if (number < 0 or number >= type_count) return null;
        return @intCast(number);
    }

    /// Whether the player needs a lock to launch it: not for a Screamer or a Solomon, which fly
    /// without one (`player_launch_missile`).
    pub fn needsLock(missile: Type) bool {
        return switch (missile) {
            .raptor, .havoc, .jack_hammer, .bandit, .vagabond, .imp, .hawk => true,
            else => false,
        };
    }

    /// The shockwave a Havoc's or an Imp's end sets off, which does all it does: their hits do
    /// no damage, and they end where they touch anything.
    pub fn shockwave(missile: Type) ?shockwave_mod.Kind {
        return switch (missile) {
            .havoc => .havoc,
            .imp => .imp,
            else => null,
        };
    }

    /// The type a hardpoint's id names.
    pub fn of(id: u16) Type {
        return @enumFromInt(@as(i16, @bitCast(id)));
    }
};

/// A missile's order (`missile_orders`, `0x00503D20`): the launch it starts with, the guidance
/// that follows, which `Stats.order` names for each type, or the jettison of what is let fall.
pub const Order = enum(u32) {
    /// From a pod: 50 ticks at full thrust (`missile_order_pod_launch`, `0x00496B20`).
    pod_launch = 0,
    /// From a rail: a drop, a stop, and a burn (`missile_order_rail_launch`, `0x00496B60`).
    rail_launch = 1,
    screamer = 2,
    raptor = 3,
    havoc = 4,
    jack_hammer = 5,
    bandit = 6,
    vagabond = 7,
    solomon = 8,
    imp = 9,
    hawk = 10,
    /// Let fall, and blown up 100 ticks later: an empty pod, or a fuel pod
    /// (`missile_order_jettison`, `0x00498410`).
    jettison = 11,
};

/// A missile type's figures (`missile_stats`, `0x005037A0`, `0x28` bytes a type): the
/// executable's own words, and what `stats_load_missiles` reads of `missilestats.bin`.
pub const Stats = extern struct {
    /// 30 for every type. **Unknown:** nothing reads it.
    _unknown_00: f32,
    /// The 3D sound its launch plays, which follows the missile (`sound3d.sounds`); 0 for none.
    launch_sound: i32,
    /// `Missile.flight_time`, in ticks: the file's seconds times `main.ticks_per_second`
    /// (`0x004DC440`), truncated.
    flight_time: i32,
    /// What a hit does to a shield and to a hull, and to a component of a ship that lists them.
    damage: formats.Damage,
    component_damage: f32,
    /// The guidance it flies under once its launch is over.
    order: Order,
    /// `Missile.lock_time`, truncated: the ticks a lock on a target takes.
    lock_time: i32,
    /// `Missile.decoy_chance`, truncated: in percent.
    decoy_chance: i32,
    /// `Missile.lock_range`.
    lock_range: f32,

    comptime {
        assert(@offsetOf(Stats, "flight_time") == 0x08);
        assert(@offsetOf(Stats, "lock_time") == 0x1C);
        assert(@offsetOf(Stats, "lock_range") == 0x24);
        assert(@sizeOf(Stats) == 0x28);
    }
};

/// `missile_stats` and `missile_flight_stats` (`0x005035E8`): every missile type's figures.
pub const Table = struct {
    stats: [type_count]Stats,
    flight: [type_count]FlightModel,

    /// The tables as the executable holds them before `stats_load_missiles` runs.
    pub const initial: Table = built: {
        var table: Table = undefined;
        for (&table.stats, &table.flight, 0..) |*record, *flight, number| {
            const missile: Type = @enumFromInt(number);
            record.* = .{
                ._unknown_00 = 30,
                .launch_sound = switch (missile) {
                    // `MISSILE01` to `MISSILE09`, then `MISSILE10`.
                    .fuel_pod => 0,
                    else => launch_sounds + @as(i32, @intCast(number)),
                },
                .flight_time = switch (missile) {
                    .torpedo, .fuel_pod => 12000,
                    else => 1000,
                },
                .damage = .{ .shield = 290, .hull = 180 },
                .component_damage = 180,
                .order = switch (missile) {
                    .torpedo => .pod_launch,
                    .fuel_pod => .jettison,
                    else => @enumFromInt(number + @intFromEnum(Order.screamer)),
                },
                .lock_time = 200,
                .decoy_chance = 50,
                .lock_range = 50000,
            };
            flight.* = switch (missile) {
                .torpedo => flightOf(50, 0.05),
                .fuel_pod => std.mem.zeroes(FlightModel),
                else => flightOf(300, 0.14),
            };
        }
        break :built table;
    };

    /// The first missile's launch sound: `MISSILE01`.
    const launch_sounds = 15;

    fn flightOf(speed: f32, turn_rate: f32) FlightModel {
        return .{
            .max_speed = speed,
            .roll_rate = turn_rate,
            .pitch_rate = turn_rate,
            .yaw_rate = turn_rate,
            .inertia = 0.84,
            .roll_inertia = 0.71,
            .pitch_inertia = 0.71,
            .yaw_inertia = 0.71,
            .speed_per_pitch_rate = 0,
            .turns = .flat,
            ._unknown_26 = 0,
        };
    }

    /// `stats_load_missiles` (`0x00494BC0`): each record of `missilestats.bin` in turn, up to the
    /// last type, keeping in whole numbers what the runtime's `__ftol` cuts down. The flight model
    /// takes the speed, and the turn rate for all three rates.
    pub fn load(table: *Table, file: []align(1) const formats.Missile) void {
        const count = @min(file.len, type_count);
        for (table.stats[0..count], table.flight[0..count], file[0..count]) |*record, *flight, missile| {
            flight.max_speed = missile.speed;
            flight.pitch_rate = missile.turn_rate;
            flight.yaw_rate = missile.turn_rate;
            flight.roll_rate = missile.turn_rate;
            record.flight_time = std.math.lossyCast(i32, missile.flight_time * @as(f32, @import("main.zig").ticks_per_second));
            record.damage = missile.damage;
            record.component_damage = missile.component_damage;
            record.lock_time = std.math.lossyCast(i32, missile.lock_time);
            record.decoy_chance = std.math.lossyCast(i32, missile.decoy_chance);
            record.lock_range = missile.lock_range;
        }
    }

    /// The figures of `missile`, or null for none or a type past the tables.
    pub fn of(table: *const Table, missile: Type) ?*const Stats {
        return &table.stats[missile.index() orelse return null];
    }
};

/// The least cosine of the angle off a nose at which what lies there is ahead of it: where a
/// launcher's missile can lock on, and what a Solomon counts as ahead (`0x004DC484`).
const nose_cone: f32 = 0.7;

/// Whether what lies `toward` a launcher whose nose points along `nose` is where a missile of
/// `stats` can lock on: within its lock range, and within `nose_cone` of the nose. The player's
/// lock and the Fight order's both ask it (`missile_lock_possible`, `fight_fire`).
pub fn inLockReach(stats: *const Stats, toward: Vector, nose: Vector) bool {
    if (math.lengthSquared(toward) > stats.lock_range * stats.lock_range) return false;
    return math.dot(math.normalize(toward), nose) >= nose_cone;
}

// --- In flight -------------------------------------------------------------------------------

/// How many missiles fly at once (`missiles_init`, `0x00494CB0`).
pub const max_missiles = 200;

/// A missile in flight (`0x28` bytes of `missiles`, `0x005887F0`): the object it owns, which
/// `object_alloc` makes and no slot of `game_objects` holds, what launched it, and what it flies
/// at. So nothing else collides with it, targets it or shows it on the radar.
pub const Missile = struct {
    /// When its launch, or its jettison, began (`+0x00`), which its flight time counts from.
    started: i32 = 0,
    /// Its object (`+0x04`), with the model it flies with and where that is drawn.
    slot: create.Slot,
    /// Its launcher's slot (`+0x08`), which it never strikes and which its damage is credited to.
    launcher: u16,
    /// The countermeasure it chases (`+0x0C`), or null.
    decoy: ?u8 = null,
    /// Its trail (`+0x10`), where it has one.
    trail: ?u8 = null,
    type: Type,
    /// Its order, and what it flies at: the one entry of its object's order stack
    /// (`GameObject + 0x684`), whose target is at `+0x04` and its component at `+0x06`.
    order: Order = .pod_launch,
    target: aigeneric.Target = .none,
    /// Whether it is drawn this frame: not once it has touched something. The game draws it as
    /// it goes.
    shown: bool = false,
    /// The live missiles' list, newest first (`+0x20`, `+0x24`).
    newer: ?u8 = null,
    older: ?u8 = null,

    fn object(missile: *Missile) *GameObject {
        return &missile.slot.object;
    }

    /// Lets go of its object's model.
    pub fn release(missile: *Missile, gpa: Allocator) void {
        missile.slot.release(gpa);
    }

    fn flight(missile: *const Missile) *const FlightModel {
        return missile.slot.flight.?;
    }

    /// Its type's figures.
    pub fn stats(missile: *const Missile, table: *const Table) *const Stats {
        return table.of(missile.type).?;
    }
};

/// The missiles in flight (`missiles`, and `missile_list`, `0x005887F4`, the newest), which the
/// game keeps in `missiles.cpp`'s globals. `reset` is `missiles_reset` (`0x00494D80`), as a mission
/// ends.
pub const Missiles = Linked(Missile, max_missiles);

/// `missile_launch` (`0x00496290`): a missile from the launcher's rack at `rack`, at `target`,
/// where the launcher may launch them and a record is free. A pod launches a missile of its own,
/// built there; a rail launches what hangs on it, which the launcher lets go. The missile starts
/// where that stood, at the launcher's velocity, and its launch sound follows it, on a sure voice
/// for the player's. It flies its pod or rail launch, with its trail, and then its type's guidance.
/// A fuel pod, and a pod launched once empty, are let fall instead. A pod whose last missile this
/// was is launched itself, empty, at nothing.
///
/// The player's launch plays the missile's effect on the player's controller.
///
/// Where memory runs out for a pod's missile, nothing is launched, and for a trail, the missile
/// flies without one.
///
/// Not ported: what a multiplayer game sends.
pub fn launch(world: gameobj.World, launcher: u16, rack: usize, target: aigeneric.Target) void {
    const all = world.objects;
    const missiles = &all.missiles;
    const carrier = &all.slots[launcher];
    if (carrier.object.flags.missiles_disabled or missiles.full()) return;
    const racked = &carrier.object.racks[rack];
    const number = racked.type.index() orelse return;
    const model = if (carrier.model) |*carried| carried else return;
    if (rack >= model.hung.len) return;
    const hung = if (model.hung[rack]) |*mount| mount else return;
    const places = hungPlaces(carrier, model, hung);
    const held = create.models.attachment(.missile, @intCast(number)) orelse create.models.Attachment{};
    const pod = held.second_model != null;
    const built: objects.Model = if (pod and racked.count > 0)
        (buildModel(all.gpa, carrier, held.second_model.?) catch return) orelse return
    else taken: {
        defer model.hung[rack] = null;
        break :taken hung.model;
    };

    const at = spawn(world, launcher, racked.type, built, places) orelse return;
    if (launcher == all.player) if (world.forces) |forces| forces.start(.missile, world.clock.frame_start);

    const class: sound3d.Class = if (launcher == all.player) .guaranteed else .not_reserved;
    const which: sound3d.sounds.Sound = @enumFromInt(missiles.records[at].?.stats(&all.missile_stats).launch_sound);
    sound3d.playIn(world, null, null, at, which, 1, class);
    racked.count -= 1;
    const order: Order = if (pod and racked.count < 0) .jettison else if (pod) .pod_launch else if (racked.type == .fuel_pod) .jettison else .rail_launch;
    // The game lays a rail's trail after the launch's first run, and a pod's before it.
    if (order == .pod_launch) startTrail(world, at);
    setOrder(world, at, order);
    if (order == .rail_launch) startTrail(world, at);
    if (missiles.get(at)) |live| live.target = target;
    if (pod and racked.count == 0) launch(world, launcher, rack, .none);
}

/// `missile_launch_turret` (`0x004967F0`): a Screamer from part `launcher` of `model`, a missile
/// turret's launcher on the object in slot `ship` or on a model mounted on it, at `target`, where
/// the object may launch missiles and a record is free. It is built as a Screamer pod's missile,
/// starts where the launcher stands, at the object's velocity, and flies its pod launch with its
/// trail, then its guidance. No sound is played.
///
/// Where memory runs out for it, or the game lacks its model, nothing is launched.
pub fn launchFromTurret(world: gameobj.World, ship: u16, model: *const objects.Model, launcher: usize, target: aigeneric.Target) void {
    const all = world.objects;
    const carrier = &all.slots[ship];
    if (carrier.object.flags.missiles_disabled or all.missiles.full()) return;
    const top = if (carrier.model) |*carried| carried else return;
    const places: Places = .{
        .now = top.partAt(carrier.object.placeAt(.now), model, launcher, .now) orelse return,
        .next = top.partAt(carrier.object.placeAt(.next), model, launcher, .next) orelse return,
        .drawn = model.parts[launcher].drawn(),
    };
    const held = create.models.attachment(.missile, comptime Type.screamer.index().?) orelse return;
    const built = (buildModel(all.gpa, carrier, held.second_model orelse return) catch return) orelse return;
    const at = spawn(world, ship, .screamer, built, places) orelse return;
    startTrail(world, at);
    setOrder(world, at, .pod_launch);
    if (all.missiles.get(at)) |live| live.target = target;
}

/// Where a launch starts a missile: where its launcher stood at the last step, where the step is
/// taking it, and where it is drawn (`node_world_place`, `node_next_place`, and its node's frame).
const Places = struct { now: math.Place, next: math.Place, drawn: math.Place };

/// A missile of type `kind` of the model `built`, from the object in slot `launcher`, standing at
/// `places`: its object's type is the missile's, as in the game, and it takes the launcher's side
/// and velocity. Its record's index, or null where none is free, which lets the model go.
fn spawn(world: gameobj.World, launcher: u16, kind: Type, built: objects.Model, places: Places) ?u8 {
    const all = world.objects;
    const carrier = &all.slots[launcher];
    const number = kind.index() orelse return null;
    var slot: create.Slot = .{ .object = gameobj.objectAlloc(@enumFromInt(number), world.random), .model = built };
    const object = &slot.object;
    slot.flight = &all.missile_stats.flight[number];
    object.side = carrier.object.side;
    object.velocity = carrier.object.velocity;
    object.radius = built.radius;
    object.bounds_min = gameobj.vec3(built.bounds[0]);
    object.bounds_max = gameobj.vec3(built.bounds[1]);
    object.root.position = gameobj.vec3(places.now.position);
    object.root.orientation = places.now.orientation;
    object.root.next_position = gameobj.vec3(places.next.position);
    object.root.next_orientation = places.next.orientation;
    object.root.flags.committed = true;
    object.root.flags.unframed = true;
    slot.drawn = places.drawn;
    return all.missiles.add(.{ .slot = slot, .launcher = launcher, .type = kind }) orelse {
        slot.release(all.gpa);
        return null;
    };
}

/// `missile_trail_create` for the missile at `at`, where it is still flying and the world has
/// trails.
fn startTrail(world: gameobj.World, at: u8) void {
    const trails = world.trails orelse return;
    const missile = world.objects.missiles.get(at) orelse return;
    missile.trail = trails.start(world, .{ .missile = at }, missile.type) catch null;
}

/// Where the pod or missile a rack holds stands.
fn hungPlaces(carrier: *const create.Slot, model: *const objects.Model, hung: *const objects.Model.Mount) Places {
    return .{
        .now = model.mountRoot(hung, carrier.object.placeAt(.now), .now),
        .next = model.mountRoot(hung, carrier.object.placeAt(.next), .next),
        .drawn = .{ .position = hung.model.position, .orientation = hung.model.orientation },
    };
}

/// The model of `file`, a pod's missile, built as the launcher's own mounts are; null where the
/// game lacks it.
fn buildModel(gpa: Allocator, carrier: *const create.Slot, file: []const u8) Allocator.Error!?objects.Model {
    const effects = if (carrier.type) |loaded| loaded.effects else return null;
    const mounts = effects.mounts orelse return null;
    const mounted = mounts.load(mounts.context, file) orelse return null;
    var built: objects.Model = try .create(gpa, mounted.model, mounted.loaded, effects);
    gameobj.linkParts(&built, mounted.model);
    return built;
}

/// `missile_order_set` (`0x00496AA0`): the missile's new order, begun and then run once. A launch
/// and a jettison count their time from now, and a jettison lets the missile fall, 50 along its Y
/// axis.
fn setOrder(world: gameobj.World, at: u8, order: Order) void {
    const missile = world.objects.missiles.get(at) orelse return;
    switch (order) {
        .pod_launch, .rail_launch => missile.started = world.clock.frame_start,
        .jettison => {
            missile.started = world.clock.frame_start;
            push(missile.object(), math.yAxis(missile.slot.drawn.orientation), jettison_drop);
        },
        else => {},
    }
    missile.order = order;
    run(world, at);
}

/// How fast a jettisoned missile falls away, and how long before it blows up.
const jettison_drop: f32 = 50;
const jettison_ticks = 100;

/// The throttle of a pod's launch, twice full thrust, and how long it lasts
/// (`missile_order_pod_launch`, `0x00496B20`); and how long a rail's drop, stop and burn last
/// (`missile_order_rail_launch`), in ticks.
const pod_launch_throttle: f32 = 2;
const pod_launch_ticks = 50;
const rail_drop_ticks = 25;
const rail_stop_ticks = 50;
const rail_burn_ticks = 100;
/// How hard a rail drops the missile, for its top speed, a tick.
const rail_drop: f32 = 0.005;

/// Havoc and Imp end within this of their target (`missile_order_proximity`).
const proximity: f32 = 10000;

fn push(object: *GameObject, direction: Vector, by: f32) void {
    object.velocity = gameobj.vec3(gameobj.vector(object.velocity) + direction * @as(Vector, @splat(by)));
}

/// The missile's order for the frame (`missile_orders`, `0x00503D20`).
fn run(world: gameobj.World, at: u8) void {
    const all = world.objects;
    const missile = all.missiles.get(at) orelse return;
    const object = missile.object();
    const ticks = world.clock.frame_start - missile.started;
    switch (missile.order) {
        .pod_launch => {
            if (ticks >= pod_launch_ticks) return setOrder(world, at, missile.stats(&all.missile_stats).order);
            steady(object, pod_launch_throttle);
        },
        .rail_launch => {
            if (ticks >= rail_burn_ticks) return setOrder(world, at, missile.stats(&all.missile_stats).order);
            if (ticks >= rail_stop_ticks) return steady(object, 1);
            steady(object, 0);
            const drop = @as(f32, @floatFromInt(world.clock.frame_duration)) * missile.flight().max_speed * rail_drop;
            push(object, math.yAxis(missile.slot.drawn.orientation), if (ticks < rail_drop_ticks) drop else -drop);
        },
        // A player's Screamer flies straight, outside a multiplayer game.
        .screamer => if (missile.launcher < all.players) steady(object, 1) else home(world, at),
        // Where it has no target, the game measures from whatever lies before the first slot, and
        // homing ends it.
        .havoc, .imp => {
            if (missile.target.slot()) |target| {
                const aimed = all.slots[target].drawn.position;
                if (math.lengthSquared(aimed - missile.slot.drawn.position) < proximity * proximity) return end(world, at);
            }
            home(world, at);
        },
        .solomon => solomon(world, at),
        .jettison => {
            steady(object, 0);
            if (ticks >= jettison_ticks) end(world, at);
        },
        .raptor, .jack_hammer, .bandit, .vagabond, .hawk => home(world, at),
    }
}

/// Flies it on at `throttle`, steering nowhere (`missile_fly_straight`, `0x00496C60`, at 1).
fn steady(object: *GameObject, throttle: f32) void {
    object.throttle = throttle;
    object.pitch_input = 0;
    object.yaw_input = 0;
}

/// Beyond this a missile has lost its target, and within this it has caught its decoy
/// (`missile_home`, `0x004DC964` and `0x004DC4F8` hold their squares).
const lost_range: f32 = 1_000_000;
const caught_range: f32 = 1000;
/// How much of its rates a missile's steering takes off its aim, and how hard it steers: fully ten
/// degrees off (`0x004DC424`, `0x004DC960`).
///
/// **Improvement:** the gain is worked out from pi, where the game rounds it to 5.72958.
const rate_damping: f32 = 4;
const steer_gain: f32 = 18.0 / std.math.pi;

/// `missile_home` (`0x00496C90`): steers at the target, where it is still one to aim at, cloaked
/// too for a Vagabond: at the point it aims at (`ai.aimedAt`), led along the target's nose by how
/// far off it is times the target's speed over the missile's top speed; or, drawn away, at the
/// countermeasure, which it catches within `caught_range`, ending both. Its throttle is the cosine
/// of the angle off its aim, and its pitch and yaw inputs the angles off it, less four times its
/// rates, times `steer_gain`, within 1 either way; with its aim behind it, full over toward its
/// side. A target lost, or beyond `lost_range`, ends it, but a Solomon flies straight on.
fn home(world: gameobj.World, at: u8) void {
    const all = world.objects;
    const missile = all.missiles.get(at) orelse return;
    const object = missile.object();
    const allowed: GameObject.Flags = if (missile.type == .vagabond) .{ .cloaked = true } else .{};
    if (ai.targetValid(all, missile.target, allowed)) {
        const from = missile.slot.drawn.position;
        const aim = if (decoyAt(world, missile)) |decoy| decoyed: {
            if (math.lengthSquared(decoy.place().position - from) < caught_range * caught_range) {
                world.countermeasures.?.end(world, missile.decoy.?);
                return end(world, at);
            }
            break :decoyed decoy.place().position;
        } else led: {
            const aimed = ai.aimedAt(all, missile.target).position;
            const target = &all.slots[@intCast(missile.target.index)];
            const lead = math.distance(aimed, from) * target.object.speed / missile.flight().max_speed;
            break :led aimed + math.forward(target.drawn.orientation) * @as(Vector, @splat(lead));
        };
        const toward = aim - from;
        if (math.lengthSquared(toward) <= lost_range * lost_range) return steer(object, missile.slot.drawn.orientation, toward);
    }
    // The game asks whether the missile's trail has the Solomon's look.
    if (missile.type == .solomon) return steady(object, 1);
    end(world, at);
}

/// The countermeasure that has drawn the missile away, where one has.
fn decoyAt(world: gameobj.World, missile: *const Missile) ?*cloak.Countermeasure {
    const decoy = missile.decoy orelse return null;
    const dropped = world.countermeasures orelse return null;
    return dropped.get(decoy);
}

/// Sets the missile's controls to fly at what lies `toward` it, turned by `orientation`.
fn steer(object: *GameObject, orientation: math.Matrix, toward: Vector) void {
    object.throttle = @max(math.dot(math.forward(orientation), toward) / math.length(toward), 0);
    const local = math.transformTransposed(orientation, toward);
    if (local[2] >= 0) {
        object.pitch_input = std.math.clamp((-std.math.atan2(local[1], local[2]) - object.pitch_rate * rate_damping) * steer_gain, -1, 1);
        object.yaw_input = std.math.clamp((std.math.atan2(local[0], local[2]) - object.yaw_rate * rate_damping) * steer_gain, -1, 1);
    } else {
        object.pitch_input = 0;
        object.yaw_input = if (local[0] < 0) -1 else 1;
    }
    object.roll_input = 0;
}

/// `missile_order_solomon` (`0x00497F80`): while its target is not one to aim at, a Solomon picks
/// its own (`choose`), and homes on it; with nothing to pick it flies straight.
fn solomon(world: gameobj.World, at: u8) void {
    const all = world.objects;
    const missile = all.missiles.get(at) orelse return;
    if (!ai.targetValid(all, missile.target, .{})) {
        missile.target = choose(all, missile) orelse return steady(missile.object(), 1);
    }
    home(world, at);
}

/// The target a Solomon picks among the objects of other sides to its own: of those that list no
/// components, the nearest ahead, else the nearest at all; with none, likewise among the
/// components of those that list them, or the object itself where none of its components is one to
/// aim at.
fn choose(all: *const create.Objects, missile: *const Missile) ?aigeneric.Target {
    var choice: Choice = .{ .from = missile.slot.drawn.position, .nose = math.forward(missile.slot.drawn.orientation) };
    for ([_]bool{ false, true }) |components| {
        var walk = all.walk();
        while (walk.next()) |index| {
            const slot = &all.slots[index];
            if (slot.object.side == missile.slot.object.side or slot.object.flags.components != components) continue;
            const whole: aigeneric.Target = .{ .kind = .ship, .index = @intCast(index), .component = -1 };
            if (!ai.targetValid(all, whole, .{})) continue;
            var any = false;
            for (0..@intCast(@max(slot.object.component_count, 0))) |component| {
                const part: aigeneric.Target = .{ .kind = .ship, .index = @intCast(index), .component = @intCast(component) };
                if (!ai.targetValid(all, part, .{})) continue;
                choice.consider(part, ai.targetPart(all, part).?.object.position);
                any = true;
            }
            if (!any) choice.consider(whole, slot.drawn.position);
        }
        if (choice.chosen()) |target| return target;
    }
    return null;
}

/// The nearest target ahead of a Solomon, and the nearest at all, so far.
const Choice = struct {
    from: Vector,
    nose: Vector,
    ahead: ?Candidate = null,
    any: ?Candidate = null,

    const Candidate = struct { target: aigeneric.Target, distance: f32 };

    fn consider(choice: *Choice, target: aigeneric.Target, at: Vector) void {
        const toward = at - choice.from;
        const candidate: Candidate = .{ .target = target, .distance = math.lengthSquared(toward) };
        if (nearer(candidate, choice.ahead) and math.dot(math.normalize(toward), choice.nose) > nose_cone) choice.ahead = candidate;
        if (nearer(candidate, choice.any)) choice.any = candidate;
    }

    fn nearer(candidate: Candidate, than: ?Candidate) bool {
        return if (than) |best| candidate.distance < best.distance else true;
    }

    fn chosen(choice: Choice) ?aigeneric.Target {
        return if (choice.ahead orelse choice.any) |candidate| candidate.target else null;
    }
};

/// `missiles_move` (`0x00495720`), once a simulation step after `objects_update`: each missile
/// takes up its next place, turns by its rates, which close on its inputs times its type's turn
/// rate by its rate inertia, and moves: its velocity damped by its inertia, save in its launch and
/// its jettison, and driven along its nose by the rest of it times its throttle and top speed. Its
/// root is marked committed and unframed, so it is drawn between its places.
pub fn move(all: *create.Objects) void {
    const missiles = &all.missiles;
    var walk = missiles.walk();
    while (walk.next()) |index| {
        const missile = missiles.get(index) orelse continue;
        const object = missile.object();
        const flight = missile.flight();
        const root = &object.root;
        root.position = root.next_position;
        root.orientation = root.next_orientation;
        object.pitch_rate = flight.pitch_inertia * object.pitch_rate + (1 - flight.pitch_inertia) * object.pitch_input * flight.pitch_rate;
        object.yaw_rate = flight.yaw_inertia * object.yaw_rate + (1 - flight.yaw_inertia) * object.yaw_input * flight.yaw_rate;
        object.rotation = math.fromAngles(object.pitch_rate, object.yaw_rate, 0);
        root.next_orientation = math.product(root.orientation, object.rotation);
        var velocity = gameobj.vector(object.velocity);
        switch (missile.order) {
            .pod_launch, .rail_launch, .jettison => {},
            else => velocity *= @splat(flight.inertia),
        }
        velocity += math.forward(root.next_orientation) * @as(Vector, @splat((1 - flight.inertia) * object.throttle * flight.max_speed));
        object.velocity = gameobj.vec3(velocity);
        root.next_position = gameobj.vec3(gameobj.vector(root.next_position) + velocity);
        root.flags.committed = true;
        root.flags.unframed = true;
    }
}

/// `missiles_update` (`0x004960F0`), once a frame after the objects are framed: each missile runs
/// its order, and then, within its flight time, is tested for contact, and with none framed, to be
/// drawn `fraction` of the way to its next place, and, with a target and no decoy, lights that
/// target's missile warning; but not a player's Screamer's outside a multiplayer game. Past its
/// flight time it ends.
///
/// Then each trail's frame (`trail.Trails.frame`).
///
/// Not ported: in a multiplayer game, a missile whose lock is lost or whose launcher is gone.
pub fn frame(world: gameobj.World, fraction: f32) void {
    const all = world.objects;
    const missiles = &all.missiles;
    var walk = missiles.walk();
    while (walk.next()) |index| {
        const missile = missiles.get(index) orelse continue;
        missile.shown = false;
        run(world, index);
        const live = missiles.get(index) orelse continue;
        if (world.clock.frame_start - live.started >= live.stats(&all.missile_stats).flight_time) {
            end(world, index);
            continue;
        }
        if (collide(world, index)) continue;
        objects.frameTree(&live.object().root, if (live.slot.model) |*model| model else null, &live.slot.drawn, fraction, null);
        live.shown = true;
        const warns = live.type != .screamer or live.launcher >= all.players;
        if (live.decoy == null and warns) if (live.target.slot()) |target| {
            all.slots[target].object.missile_homing = 1;
        };
    }
    if (world.trails) |trails| trails.frame(world);
}

/// Adds each missile `frame` left drawn to the world's layer, as `object_draw` does for it there:
/// with its lights, and its engine glows burning by its throttle.
pub fn draw(all: *create.Objects, gpa: Allocator, scene: *srcore.Scene, attachments: objects.View) Allocator.Error!void {
    var walk = all.missiles.walk();
    while (walk.next()) |index| {
        const missile = all.missiles.get(index) orelse continue;
        if (!missile.shown) continue;
        const model = if (missile.slot.model) |*built| built else continue;
        var view = attachments;
        view.blink_offset = missile.object().blink_offset;
        view.throttle = missile.object().throttle;
        try model.draw(gpa, scene, .world, view);
    }
}

/// `missile_end` (`0x00495870`): the missile's end, however it comes: its object's voice ended,
/// where it holds one; a Havoc's shockwave, or an Imp's, where it is drawn, sparing its launcher's
/// side (`shockwave.Shockwave.strike`); its blast (`explode.missileBlast`); and its record freed.
///
/// Its trail fades out from here. Not ported: in a multiplayer game, a remote missile's id.
pub fn end(world: gameobj.World, at: u8) void {
    const all = world.objects;
    const missile = all.missiles.get(at) orelse return;
    const object = missile.object();
    if (object.sound_voice.index()) |voice| if (world.hearing) |hearing| hearing.sound.end3D(voice);
    if (missile.type.shockwave()) |kind| shockwave_mod.setOff(world, missile.slot.drawn, .{
        .kind = kind,
        .size = end_wave_size,
        .life = end_wave_life,
        .owner = missile.launcher,
        .side = all.slots[missile.launcher].object.side,
    });
    explode.missileBlast(world, missile.slot.drawn.position, gameobj.vector(object.velocity), object.radius);
    if (missile.trail) |left| if (world.trails) |trails| if (trails.get(left)) |fading| {
        fading.follows = .nothing;
    };
    all.missiles.remove(all.gpa, at);
}

/// The shockwave a Havoc's or an Imp's end sets off: how far across, and for how long.
const end_wave_size: f32 = 50000;
const end_wave_life = 500;

// --- Contact -------------------------------------------------------------------------------

/// `missile_collide` (`0x00495CF0`): whether the missile touches anything this frame, along the
/// segment from where it is drawn to its next place, testing every object but its launcher, of any
/// side. An object that lists components is tested part by part (`hitComponents`); any other where
/// the segment passes within its radius. A Havoc or an Imp just ends there, to its blast and
/// shockwave. Otherwise, where the segment first meets the sphere: with the quadrant's shield down,
/// the hull takes it (`hitHull`); up, the shield takes the type's shield damage, with its hull
/// damage over that as the share that passes through, and flares, unless the object is cloaked;
/// and the missile ends.
///
/// A hit on the player's fore or aft shield is taken off that side's reserve first, while it holds
/// anything (`ShieldReserves.spare`); one that runs it out, or finds none, reaches the shield.
///
/// **Fix:** the game takes a missile's hit on the player's shields only on the fore quadrant, and
/// only as it empties a reserve, the fore's while it holds any, else the aft's; with neither
/// holding anything, or on any other quadrant, it does the player's shields no harm. Every other
/// hit on the player's shields, a shot's, a knock's and a shockwave's, draws the reserve of the
/// side struck and then reaches the shield, so OpenReliant takes a missile's the same way.
///
/// Not ported: in a multiplayer mission, the shield damage five times over.
fn collide(world: gameobj.World, at: u8) bool {
    const all = world.objects;
    const missile = all.missiles.get(at) orelse return false;
    const from = missile.slot.drawn.position;
    const segment: objects.Segment = .between(from, gameobj.vector(missile.object().root.next_position));
    const span = segment.span;
    const along = 1 / math.dot(span, span);
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (!object.type.hasStats() or object.flags.no_collisions or index == missile.launcher) continue;
        if (object.flags.components) {
            if (hitComponents(world, at, index)) return true;
            continue;
        }
        const to = slot.drawn.position - from;
        const when = std.math.clamp(math.dot(span, to) * along, 0, 1);
        if (math.lengthSquared(span * @as(Vector, @splat(when)) - to) >= object.radius * object.radius) continue;
        if (missile.type.shockwave() != null) return stop(world, at);
        const point = segment.point(segment.sphereEntry(slot.drawn.position, object.radius));
        const struck = collision.quadrant(object, slot.drawn.inverse(point));
        if (object.shields.get(struck) < 0 or object.invulnerable == ._unknown_4) return hitHull(world, at, index, struck);
        const stats = missile.stats(&all.missile_stats);
        if (stats.damage.shield > 0) {
            const reaches = index != all.player or !world.player.shield_reserves.spare(struck, stats.damage.shield);
            if (reaches) collision.damage(world, index, struck, stats.damage.shield, stats.damage.hullShare(), missile.launcher, damageKind(missile.type));
        }
        if (!object.flags.cloaked) shield.flare(world, index, point);
        return stop(world, at);
    }
    return false;
}

/// What a missile's hit counts as: a Screamer's apart from the rest.
fn damageKind(missile: Type) collision.Kind {
    return if (missile == .screamer) .screamer else .missile;
}

/// The missile stopped where it touched, and ended: true, for `collide`.
fn stop(world: gameobj.World, at: u8) bool {
    if (world.objects.missiles.get(at)) |missile| missile.object().velocity = gameobj.vec3(@splat(0));
    end(world, at);
    return true;
}

/// `missile_hit_hull` (`0x00495BB0`): the part of the object's hull the missile reaches, the first
/// of its parts, hidden or not, whose box the segment meets; the quadrant's armour takes the type's
/// hull damage, but a Havoc's or an Imp's, and the hit is heard (`shieldfx.hullHit`), and the
/// missile stops and ends.
///
/// **Fix.** Where the segment meets no part's box, the game still reports contact without ending
/// the missile, which is then left out of the frame's drawing and flies on; OpenReliant reports
/// none, and draws it.
fn hitHull(world: gameobj.World, at: u8, index: u16, struck: collision.Quadrant) bool {
    const all = world.objects;
    const missile = all.missiles.get(at) orelse return false;
    const model = if (all.slots[index].model) |*live| live else return false;
    const from = missile.slot.drawn.position;
    const to = gameobj.vector(missile.object().root.next_position);
    const entry = objects.partEntry(model, from, to, .first) orelse return false;
    if (missile.type.shockwave() == null) {
        collision.armorDamage(world, index, struck, missile.stats(&all.missile_stats).damage.hull, missile.launcher, damageKind(missile.type));
        shieldfx.hullHit(world, index, from + (to - from) * @as(Vector, @splat(entry)));
    }
    return stop(world, at);
}

/// `missile_hit_components` (`0x00495AC0`): for an object that lists components, the face of its
/// parts, or of the models mounted on it, the segment meets (`objects.hitSegment`); but for a Havoc
/// or an Imp, the hit leaves what it leaves on the part (`shieldfx.componentHit`) and the part
/// takes the type's component damage. The missile stops and ends.
fn hitComponents(world: gameobj.World, at: u8, index: u16) bool {
    const all = world.objects;
    const missile = all.missiles.get(at) orelse return false;
    const slot = &all.slots[index];
    const model = if (slot.model) |*live| live else return false;
    const hit = objects.hitSegment(model, slot.object.placeAt(.next), missile.slot.drawn.position, gameobj.vector(missile.object().root.next_position)) orelse return false;
    if (missile.type.shockwave() == null) {
        shieldfx.componentHit(world, index, hit, .component);
        collision.componentDamage(world, index, hit.part, missile.stats(&all.missile_stats).component_damage, missile.launcher, damageKind(missile.type));
    }
    return stop(world, at);
}

test "Table.initial" {
    const table = Table.initial;
    // The executable's own words: the launch sounds, the orders, and the torpedo's flight model.
    try std.testing.expectEqual(15, table.of(.screamer).?.launch_sound);
    try std.testing.expectEqual(24, table.of(.torpedo).?.launch_sound);
    try std.testing.expectEqual(0, table.of(.fuel_pod).?.launch_sound);
    try std.testing.expectEqual(Order.hawk, table.of(.hawk).?.order);
    try std.testing.expectEqual(Order.pod_launch, table.of(.torpedo).?.order);
    try std.testing.expectEqual(Order.jettison, table.of(.fuel_pod).?.order);
    try std.testing.expectEqual(50, table.flight[9].max_speed);
    try std.testing.expectEqual(0.84, table.flight[0].inertia);
    try std.testing.expectEqual(0, table.flight[10].inertia);
    try std.testing.expectEqual(null, table.of(.none));
}

test "Table.load" {
    var table = Table.initial;
    var record = std.mem.zeroes(formats.Missile);
    record.speed = 500;
    record.turn_rate = 0.2;
    record.flight_time = 50.009;
    record.damage = .{ .shield = 250, .hull = 200 };
    record.lock_time = 300.9;
    record.decoy_chance = 30.5;
    record.lock_range = 160000;
    record.component_damage = 120;
    table.load(&.{ record, record });
    const raptor = table.of(.raptor).?;
    try std.testing.expectEqual(5000, raptor.flight_time);
    try std.testing.expectEqual(300, raptor.lock_time);
    try std.testing.expectEqual(30, raptor.decoy_chance);
    try std.testing.expectEqual(120, raptor.component_damage);
    try std.testing.expectEqual(0.2, table.flight[1].roll_rate);
    // What the file doesn't reach keeps the executable's figures, and its own words stay.
    try std.testing.expectEqual(1000, table.of(.havoc).?.flight_time);
    try std.testing.expectEqual(Order.raptor, raptor.order);
}

pub const testing = struct {
    const shp = @import("../../formats/shp.zig");

    /// A mission whose ships are made on the fixture's model, carrying a Raptor pod and a Havoc on
    /// its two hardpoints, each hardpoint and each missile the fixture's own part.
    pub const Armed = struct {
        mission: gameobj.testing.Mission,
        model: create.testing.Model,
        points: [2]shp.Attachment,

        pub fn init(armed: *Armed, gpa: Allocator) !void {
            try armed.mission.init(gpa);
            errdefer armed.mission.deinit();
            try armed.model.init(gpa);
            armed.points = @splat(std.mem.zeroes(shp.Attachment));
            for (&armed.points, [_]Type{ .raptor, .havoc }) |*point, held| {
                point.kind = .missile;
                point.id = @intCast(@intFromEnum(held));
                point.orientation = math.identity;
            }
            armed.model.data[0].attachments = &armed.points;
            armed.model.type.effects.mounts = objects.testing.mountsOf(&armed.model);
        }

        pub fn deinit(armed: *Armed) void {
            armed.mission.deinit();
            armed.model.deinit(std.testing.allocator);
        }

        /// An armed ship of `side` at `at`, facing along Z, in the next slot.
        pub fn add(armed: *Armed, side: gameobj.Side(i32), at: Vector) !u16 {
            const index = try create.createObject(armed.mission.objects, &armed.mission.tables, armed.model.types(), null, .predator, 0, at, &armed.mission.random);
            armed.mission.slot(index).object.side = side;
            armed.mission.slot(index).object.flags.targetable = true;
            return index;
        }

        pub fn missile(armed: *Armed, at: u8) *Missile {
            return armed.mission.objects.missiles.get(at).?;
        }

        pub fn live(armed: *Armed) usize {
            var count: usize = 0;
            var walk = armed.mission.objects.missiles.walk();
            while (walk.next()) |_| count += 1;
            return count;
        }
    };
};

test launchFromTurret {
    var armed: testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    const world = armed.mission.world();
    const ship = try armed.add(.hostile, .{ 0, 0, 500 });
    const enemy = try armed.add(.friendly, .{ 0, 0, 20000 });
    const target: aigeneric.Target = .{ .kind = .ship, .index = @intCast(enemy), .component = -1 };
    const slot = armed.mission.slot(ship);
    slot.object.velocity = .{ .x = 0, .y = 0, .z = 30 };
    const model = &slot.model.?;

    // A Screamer leaves the launcher on its pod launch, at the target, at the ship's velocity,
    // from where the launcher stands.
    launchFromTurret(world, ship, model, 0, target);
    const missile = armed.missile(0);
    try std.testing.expectEqual(Type.screamer, missile.type);
    try std.testing.expectEqual(Order.pod_launch, missile.order);
    try std.testing.expectEqual(target, missile.target);
    try std.testing.expectEqual(ship, missile.launcher);
    try std.testing.expectEqual(30, missile.object().velocity.z);
    const next = model.partPlace(0, .next).within(slot.object.placeAt(.next));
    try std.testing.expectEqual(next.position, gameobj.vector(missile.object().root.next_position));
    // A ship whose missiles are disabled launches none.
    slot.object.flags.missiles_disabled = true;
    launchFromTurret(world, ship, model, 0, target);
    try std.testing.expectEqual(1, armed.live());
}

test launch {
    var armed: testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    const world = armed.mission.world();
    const ship = try armed.add(.friendly, @splat(0));
    const enemy = try armed.add(.hostile, .{ 0, 0, 20000 });
    const object = &armed.mission.slot(ship).object;
    const hung = armed.mission.slot(ship).model.?.hung;
    try std.testing.expectEqual(3, object.racks[0].count);

    // A pod launches a missile of its own, at the target, and keeps hanging.
    const target: aigeneric.Target = .{ .kind = .ship, .index = @intCast(enemy), .component = -1 };
    launch(world, ship, 0, target);
    try std.testing.expectEqual(2, object.racks[0].count);
    try std.testing.expect(hung[0] != null);
    const first = armed.missile(0);
    try std.testing.expectEqual(Type.raptor, first.type);
    try std.testing.expectEqual(Order.pod_launch, first.order);
    try std.testing.expectEqual(target, first.target);
    try std.testing.expectEqual(2, first.object().throttle);
    try std.testing.expect(first.object().root.flags.committed);

    // A rail lets its missile go.
    launch(world, ship, 1, target);
    try std.testing.expect(hung[1] == null);
    try std.testing.expectEqual(Order.rail_launch, armed.missile(1).order);
    try std.testing.expectEqual(1, armed.mission.objects.missiles.newest);

    // The pod's last missile takes the pod with it, fallen away at nothing.
    launch(world, ship, 0, target);
    launch(world, ship, 0, target);
    try std.testing.expect(hung[0] == null);
    try std.testing.expectEqual(-1, object.racks[0].count);
    try std.testing.expectEqual(5, armed.live());
    const pod = armed.missile(4);
    try std.testing.expectEqual(Order.jettison, pod.order);
    try std.testing.expectEqual(aigeneric.Target.none, pod.target);
    // An empty rack launches nothing more.
    launch(world, ship, 0, target);
    try std.testing.expectEqual(5, armed.live());
}

test move {
    var armed: testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    const ship = try armed.add(.friendly, @splat(0));
    launch(armed.mission.world(), ship, 0, .none);
    const object = armed.missile(0).object();

    // In its launch it burns at twice its thrust, undamped: 0.16 of 600 a step.
    move(armed.mission.objects);
    try std.testing.expectApproxEqAbs(96, object.velocity.z, 1e-3);
    try std.testing.expectApproxEqAbs(96, object.root.next_position.z - object.root.position.z, 1e-3);
    try std.testing.expect(object.root.flags.unframed);
    // Past it, its speed settles at its throttle's share of its top speed.
    armed.missile(0).order = .raptor;
    object.throttle = 1;
    for (0..200) |_| move(armed.mission.objects);
    try std.testing.expectApproxEqAbs(300, object.velocity.z, 1e-2);
}

test frame {
    var armed: testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    const world = armed.mission.world();
    const clock = &armed.mission.clock;
    const ship = try armed.add(.friendly, @splat(0));
    const enemy = try armed.add(.hostile, .{ 0, 0, 200000 });
    const target: aigeneric.Target = .{ .kind = .ship, .index = @intCast(enemy), .component = -1 };
    launch(world, ship, 0, target);
    launch(world, ship, 0, .none);

    // Through the launch both burn, and are drawn; the one at a target warns it.
    clock.frame_start = 49;
    frame(world, 0);
    try std.testing.expect(armed.missile(0).shown and armed.missile(1).shown);
    try std.testing.expectEqual(1, armed.mission.slot(enemy).object.missile_homing);
    // Then each homes: the one with nothing to home on ends, the other steers.
    clock.frame_start = 50;
    frame(world, 0);
    try std.testing.expectEqual(1, armed.live());
    try std.testing.expectEqual(Order.raptor, armed.missile(0).order);
    try std.testing.expectEqual(1, armed.missile(0).object().throttle);
    // Its flight time over, it ends.
    clock.frame_start = armed.missile(0).stats(&armed.mission.objects.missile_stats).flight_time;
    frame(world, 0);
    try std.testing.expectEqual(0, armed.live());
}

test "a player's Screamer flies straight" {
    var armed: testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    armed.points[0].id = @intCast(@intFromEnum(Type.screamer));
    const world = armed.mission.world();
    const player = try armed.add(.friendly, @splat(0));
    const other = try armed.add(.hostile, .{ 0, 0, 50000 });
    launch(world, player, 0, .none);
    launch(world, other, 0, .none);
    armed.mission.clock.frame_start = 50;
    frame(world, 0);
    // The player's flies on at nothing; another's has nothing to home on and ends.
    try std.testing.expectEqual(1, armed.live());
    try std.testing.expectEqual(player, armed.missile(0).launcher);
    try std.testing.expectEqual(1, armed.missile(0).object().throttle);
}

test steer {
    var object = gameobj.testing.object();
    // A little off to the right, it yaws right by the angle's share of ten degrees, at nearly full
    // throttle.
    steer(&object, math.identity, .{ 0.01, 0, 1 });
    try std.testing.expectApproxEqAbs(0.01 * steer_gain, object.yaw_input, 1e-4);
    try std.testing.expectEqual(0, object.pitch_input);
    try std.testing.expect(object.throttle > 0.99);
    // Well off, it yaws fully; its turn so far takes off it.
    object.yaw_rate = 0.1;
    steer(&object, math.identity, .{ 1, 0, 1 });
    try std.testing.expectEqual(1, object.yaw_input);
    // Behind, it turns hard toward the aim's side, with no thrust.
    steer(&object, math.identity, .{ -1, 1, -1 });
    try std.testing.expectEqual(-1, object.yaw_input);
    try std.testing.expectEqual(0, object.pitch_input);
    try std.testing.expectEqual(0, object.throttle);
}

test choose {
    var armed: testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    armed.points[0].id = @intCast(@intFromEnum(Type.solomon));
    const world = armed.mission.world();
    const player = try armed.add(.friendly, @splat(0));
    const behind = try armed.add(.hostile, .{ 0, 0, -3000 });
    const ahead = try armed.add(.hostile, .{ 0, 0, 9000 });
    _ = try armed.add(.friendly, .{ 0, 0, 1000 });
    launch(world, player, 0, .none);
    // The nearest ahead, though another is nearer behind.
    const all = armed.mission.objects;
    try std.testing.expectEqual(@as(i16, @intCast(ahead)), choose(all, armed.missile(0)).?.index);
    // With none ahead, the nearest at all.
    all.slots[ahead].object.flags.targetable = false;
    try std.testing.expectEqual(@as(i16, @intCast(behind)), choose(all, armed.missile(0)).?.index);
    all.slots[behind].object.flags.targetable = false;
    try std.testing.expectEqual(null, choose(all, armed.missile(0)));
}

test collide {
    var armed: testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    const world = armed.mission.world();
    const all = armed.mission.objects;
    const player = try armed.add(.friendly, @splat(0));
    const enemy = try armed.add(.hostile, .{ 0, 0, 5000 });
    all.slots[enemy].object.radius = 100;

    // A missile passing through its sphere with its shields up spends itself on them.
    launch(world, player, 0, .none);
    var missile = armed.missile(0);
    missile.slot.drawn.position = .{ 0, 0, 4800 };
    missile.object().root.next_position = .{ .x = 0, .y = 0, .z = 5200 };
    const shields = all.slots[enemy].object.shields;
    try std.testing.expect(collide(world, 0));
    try std.testing.expectEqual(0, armed.live());
    try std.testing.expect(all.slots[enemy].object.shields.aft < shields.aft);

    // One that passes wide touches nothing.
    launch(world, player, 0, .none);
    missile = armed.missile(0);
    missile.slot.drawn.position = .{ 500, 0, 4800 };
    missile.object().root.next_position = .{ .x = 500, .y = 0, .z = 5200 };
    try std.testing.expect(!collide(world, 0));

    // The enemy's on the player's fore shield is taken off the fore reserve while it holds,
    // sparing the shield.
    all.slots[player].object.radius = 100;
    const reserves = &world.player.shield_reserves;
    const fore = all.slots[player].object.shields.fore;
    launch(world, enemy, 0, .none);
    var theirs: u8 = all.missiles.newest.?;
    missile = armed.missile(theirs);
    const damage = missile.stats(&all.missile_stats).damage.shield;
    reserves.fore = damage * 2;
    missile.slot.drawn.position = .{ 0, 0, 300 };
    missile.object().root.next_position = .{ .x = 0, .y = 0, .z = -300 };
    try std.testing.expect(collide(world, theirs));
    try std.testing.expectEqual(damage, reserves.fore);
    try std.testing.expectEqual(fore, all.slots[player].object.shields.fore);

    // With no reserve, the shield takes it, as it takes a shot.
    reserves.fore = 0;
    launch(world, enemy, 0, .none);
    theirs = all.missiles.newest.?;
    missile = armed.missile(theirs);
    missile.slot.drawn.position = .{ 0, 0, 300 };
    missile.object().root.next_position = .{ .x = 0, .y = 0, .z = -300 };
    try std.testing.expect(collide(world, theirs));
    try std.testing.expect(all.slots[player].object.shields.fore < fore);
}

test {
    std.testing.refAllDecls(@This());
}
