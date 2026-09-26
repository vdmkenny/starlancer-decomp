//! The turrets of `C:\lancer\game\guns.cpp`: the gun a turret part fits by its turret kind as the
//! object is created (`object_collect_guns`), and what each turret keeps in its gun's record. A
//! turret's parts are its assembly: the shown parts of its model that share its part's link id,
//! each in a slot its part names (`shp.Part.turret_slot`).

const std = @import("std");
const assert = std.debug.assert;

const shp = @import("../../../formats/shp.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const guns = @import("../guns.zig");
const missiles = @import("../missiles.zig");
const objects = @import("../objects.zig");

/// What a turret's fit needs of the object it is fitted to: its components, and its model's firing
/// arcs, one a component.
pub const Ship = struct {
    components: []const ?*objects.Model.Part = &.{},
    arcs: []const shp.FiringArc = &.{},
};

/// A turret that turns to aim at a target of its own and fires by its parts' `fire` tracks (kind
/// 1).
pub const Aimed = struct {
    barrel: guns.Barrel,
    /// The model whose parts it turns (`+0x34`): its object's own, or the one mounted on it that
    /// holds it.
    model: *objects.Model,
    /// Its base (slot 0, `+0x38`), which yaws; the part in slot 1 (`+0x3C`), which pitches, and
    /// is the base where the assembly names none; and those in slots 2 to 4 (`+0x40` to `+0x48`),
    /// the first of which pitches too. Each slot's part fires.
    base: usize,
    pitch: usize,
    slots: [3]?usize,
    /// What it aims at (`+0x18`), or none.
    target: aigeneric.Target = .none,
    /// When it next looks for a target while it has none (`+0x4C`).
    looks_at: i32 = 0,
    /// The yaw and pitch it has still to turn toward its aim (`+0x50`, `+0x54`).
    to_turn: Angles = .{},
    /// Its muzzle faces away from its aim of no yaw and no pitch (`facesBack`), as every fighter's
    /// rear turret's does. **Fix:** OpenReliant turns such a turret in its parts' frames turned a
    /// half turn about their X axis, so it aims along its muzzle; the game's never fires
    /// ([#219](https://github.com/vdmkenny/openreliant/issues/219)).
    reversed: bool = false,
    /// The directions it may fire in (`+0x58`), where a part of its assembly is a component of the
    /// object with a firing arc.
    arc: ?*const shp.FiringArc = null,
};

/// A turret's yaw, about its base's X axis, and pitch, about its pitching part's Y, in radians.
pub const Angles = struct {
    yaw: f32 = 0,
    pitch: f32 = 0,
};

/// A gun whose barrels spin up while its trigger is held (kind 2).
pub const Spin = struct {
    barrel: guns.Barrel,
    /// The model whose parts it plays (`+0x30`).
    model: *objects.Model,
    /// Its barrels (slot 0, `+0x1C`), which spin; its gun (slot 1), whose track loops at their
    /// speed; and two flaps (slots 2 and 3), which open while it fires.
    barrels: usize,
    gun: ?usize,
    flaps: [2]?usize,
};

/// A missile turret, which launches Screamers (kind 3).
pub const Launcher = struct {
    /// The model whose parts it turns (`+0x34`).
    model: *objects.Model,
    /// Its base (slot 0, `+0x38`), which yaws, and the launcher on it (slot 1), which the missiles
    /// leave from and which plays its `reload` track.
    base: usize,
    launcher: usize,
    /// What it launches at (`+0x18`), or none.
    target: aigeneric.Target = .none,
    /// When its state's wait is over (`+0x4C`).
    until: i32 = 0,
    /// The missiles it has left (`+0x58`). It starts empty, and so reloads first.
    missiles: i32 = 0,
    state: State = .searching,

    /// What it is doing (`+0x5C`).
    pub const State = enum(i32) {
        searching = 0,
        tracking = 1,
        /// Out of missiles, waiting to reload.
        empty = 2,
        /// Its launcher playing its `reload` track forward, and then back.
        loading = 3,
        closing = 4,
    };
};

/// Whether a part of a turret's class and `kind` fits a turret gun (`object_collect_guns`, which
/// reads the kind's four bytes). A turret part of any other kind is passed over with its assembly.
pub fn fits(kind: shp.Part.TurretKind) bool {
    return switch (kind) {
        .aimed, .spin, .missile => true,
        .fixed, _ => false,
    };
}

/// The turret that part `index` of `model`, a part of a turret's class, fits by its turret kind
/// (`turret_fit_aimed`, `turret_fit_spin` and `turret_fit_missile`), or null where its assembly
/// lacks a part the turret's steps need, where the game would read through a missing one. Its
/// base's part is marked `turret`.
pub fn fit(model: *objects.Model, index: usize, ship: Ship) ?guns.Turret {
    var slots: [slot_count]?usize = @splat(null);
    var muzzle: ?guns.Muzzle = null;
    var arc: ?*const shp.FiringArc = null;
    const link = model.parts[index].link_id;
    for (model.parts, 0..) |*part, member| {
        if (part.hidden or part.link_id != link) continue;
        // The last muzzle of the assembly is the gun's.
        for (part.attachments) |*attachment| {
            if (attachment.kind == .gun_muzzle) muzzle = .{ .model = model, .part = member, .attachment = attachment };
        }
        if (slotOf(part)) |slot| slots[slot] = member;
        if (part.flags.component and ship.arcs.len > 0) {
            for (ship.components, 0..) |component, number| {
                if (component == part and number < ship.arcs.len) arc = &ship.arcs[number];
            }
        }
    }
    const base = slots[0] orelse return null;
    const turret: guns.Turret = switch (model.parts[index].turret_kind) {
        .aimed => aimed: {
            const at = muzzle orelse return null;
            const reversed = facesBack(model, base, at);
            if (reversed) for (slots) |slot| if (slot) |part| {
                model.parts[part].animation.reversed = true;
            };
            break :aimed .{ .aimed = .{
                .barrel = barrelOf(at),
                .model = model,
                .base = base,
                .pitch = slots[1] orelse base,
                .slots = slots[2..].*,
                .arc = arc,
                .reversed = reversed,
            } };
        },
        .spin => .{ .spin = .{
            .barrel = barrelOf(muzzle orelse return null),
            .model = model,
            .barrels = base,
            .gun = slots[1],
            .flaps = .{ slots[2], slots[3] },
        } },
        .missile => .{ .missile = .{
            .model = model,
            .base = base,
            .launcher = slots[1] orelse return null,
        } },
        .fixed, _ => return null,
    };
    model.parts[base].turret = true;
    return turret;
}

/// Whether an aimed turret's `muzzle` faces away from its aim of no yaw and no pitch, which lies
/// along -Z of its base's frame (`aimAngles`): along the frame's +Z, as every fighter's rear
/// turret's does ([#219](https://github.com/vdmkenny/openreliant/issues/219)).
fn facesBack(model: *const objects.Model, base: usize, muzzle: guns.Muzzle) bool {
    const aim = math.transform(model.parts[base].animation.orientation, .{ 0, 0, -1 });
    return math.dot(math.forward(muzzle.attachment.orientation), aim) < 0;
}

/// Slots a turret's record holds its parts in.
const slot_count = 5;

/// The slot a part of a turret's assembly stands in, or null for none. The game writes a slot
/// past the record's five, or a spinning or missile turret's slot of -1, into the words beside
/// them; OpenReliant passes it over.
fn slotOf(part: *const objects.Model.Part) ?usize {
    const slot = std.math.cast(usize, part.turret_slot) orelse return null;
    return if (slot < slot_count) slot else null;
}

/// The barrel a turret fires from `muzzle`, of the type the muzzle names.
fn barrelOf(muzzle: guns.Muzzle) guns.Barrel {
    return .{ .muzzle = muzzle, .type = .fromNumber(muzzle.attachment.gun_type) };
}

/// Whether some part of `model` of a turret's class shares `link`, which makes the part with it
/// one of the turret's assembly, whose muzzles are the turret's rather than guns of their own
/// (`object_collect_guns`). A turret's class alone counts, whatever its kind.
pub fn inAssembly(model: *const objects.Model, link: u32) bool {
    for (model.parts) |part| {
        if (part.link_id == link and part.class.isTurret()) return true;
    }
    return false;
}

// --- Each frame ----------------------------------------------------------------------------------

/// `object_step_turrets` (`0x0047C950`), once a frame from `orders_update` for the object in slot
/// `index`, where its guns are not disabled: each of its guns runs its turret's step, by kind
/// (`turret_steps`, `0x00500FA0`), unless the object is exploding or docking.
pub fn step(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    if (slot.object.flags.exploding) return;
    if (slot.current()) |entry| if (entry.order == .dock) return;
    for (slot.guns) |*gun| switch (gun.turret) {
        .aimed => |*aimed| aimedStep(world, index, gun, aimed),
        .spin => |*spin| spinStep(world, gun, spin),
        .missile => |*launcher| missileStep(world, index, launcher),
        .fixed, .gone => {},
    };
}

/// How far an aimed turret turns each way a tick (`0x004DC4AC`).
const turn_rate: f32 = 0.02;

/// How long an aimed turret with no target waits before it looks for one again, at least and by
/// how much more at random.
const look_least = 100;
const look_spread = 100;

/// `turret_aimed_step` (`0x0047D3D0`): an aimed turret with a target tracks it (`track`), then
/// turns toward it: its base about its X axis, its part in slot 1 and the one in slot 2 about their
/// Y, by what it still has to turn, at most `turn_rate` a tick, and within their limits
/// (`node_turn`). Every 100 to 199 ticks, where it has none, it looks for a target (`pickTarget`).
///
/// **Quirk:** a turret that drops its target as it tracks it still turns by what it had to turn
/// the frame before.
fn aimedStep(world: gameobj.World, index: u16, gun: *guns.Fitted, aimed: *Aimed) void {
    const clock = world.clock;
    if (aimed.target.slot() != null) {
        track(world, index, gun, aimed);
        const rate = @as(f32, @floatFromInt(clock.frame_duration)) * turn_rate;
        const model = aimed.model;
        turn(model, aimed.base, .{ std.math.clamp(aimed.to_turn.yaw, -rate, rate), 0, 0 });
        const pitch: Vector = .{ 0, std.math.clamp(aimed.to_turn.pitch, -rate, rate), 0 };
        turn(model, aimed.pitch, pitch);
        if (aimed.slots[0]) |part| turn(model, part, pitch);
    }
    if (aimed.looks_at < clock.frame_start) {
        if (aimed.target.slot() == null) pickTarget(world, index, aimed);
        aimed.looks_at = clock.frame_start + look_least + @rem(world.random.rand(), look_spread);
    }
}

/// Turns part `index` of `model` by `delta` (`node_turn`), and places it so (`node_place`).
fn turn(model: *objects.Model, index: usize, delta: Vector) void {
    model.swivel(index, delta);
    model.pose(index);
}

/// How far a target's ECM throws an aimed turret's lead off: to between `ecm_lead_least` and that
/// plus `ecm_lead_spread` of it, at random (`0x004DC408`, `0x004DC4C0`).
const ecm_lead_least: f32 = 0.5;
const ecm_lead_spread: f32 = 0.3;

/// How fast an aimed turret plays its parts' `fire` tracks.
const fire_speed: f32 = 2;

/// `turret_aimed_track` (`0x0047CFA0`): an aimed turret whose target is still valid leads it from
/// its base with its gun (`ai.leadAimWithGun`), by a random share of the lead where the target's
/// ECM is on, and where it can aim there (`aimAngles`) takes the yaw and pitch it still has to turn
/// toward it, each the short way round. Where its muzzle then points, from its base, within twice
/// the target's radius of the aim, at their next places, it holds its trigger for a tick and plays
/// the `fire` track of each of its parts playing none, whose events fire it
/// (`guns.clipEventMuzzles`). A target it can't lead or aim at, or no longer valid, it drops.
///
/// **Quirk:** the muzzle points along its own nose, from where the base stands.
fn track(world: gameobj.World, index: u16, gun: *guns.Fitted, aimed: *Aimed) void {
    const all = world.objects;
    const target = aimed.target.slot() orelse return drop(aimed);
    if (!ai.targetValid(all, aimed.target, .{})) return drop(aimed);
    const struck = &all.slots[target];
    const lead: f32 = if (struck.object.flags.ecm) world.random.fraction() * ecm_lead_spread + ecm_lead_least else 1;
    const model = aimed.model;
    const base = &model.parts[aimed.base];
    const aim = ai.leadAimWithGun(all, base.object.position, aimed.target, aimed.barrel.type, lead) orelse return drop(aimed);
    const angles = aimAngles(aimed, aim) orelse return drop(aimed);
    aimed.to_turn = .{
        .yaw = math.halfTurn(angles.yaw - base.animation.turret[0]),
        .pitch = math.halfTurn(angles.pitch - model.parts[aimed.pitch].animation.turret[1]),
    };

    const slot = &all.slots[index];
    const top = if (slot.model) |*own| own else return;
    const root = slot.object.placeAt(.next);
    const muzzle = aimed.barrel.muzzle.at(top, root, .next) orelse return;
    const from = top.partAt(root, model, aimed.base, .next) orelse return;
    if (!ai.alongNose(.{ .position = from.position, .orientation = muzzle.orientation }, aim, struck.object.radius + struck.object.radius)) return;
    gun.firing_until = world.clock.frame_start + 1;
    for ([_]?usize{ aimed.base, aimed.pitch } ++ aimed.slots) |each| {
        const part = each orelse continue;
        const a = &model.parts[part].animation;
        if (a.mode == .none or a.speed == 0) model.play(part, .fire, 0, null, fire_speed);
    }
}

fn drop(aimed: *Aimed) void {
    aimed.target = .none;
}

/// How far past a pitch limit a Huge Gun's aim is taken at the limit, in degrees (`0x004DC72C`).
const huge_overshoot: f32 = 20;

/// A firing arc's grid (`shp.FiringArc`) as `turret_aim_angles` reads it: its rows go a whole turn
/// round the component's Y axis (`0x004DC894`), and its columns out from the axis are each half a
/// row wide, twice as many a radian (`0x004DC890`). A direction's row and column are its angles, a
/// turn on, in rows and in columns, less `arc_half_cell` (`0x004DC408`), rounded.
const arc_rows = @typeInfo(@FieldType(shp.FiringArc, "rows")).array.len;
const arc_rows_per_radian: f32 = @as(comptime_float, arc_rows) / std.math.tau;
const arc_columns_per_radian: f32 = 2 * @as(comptime_float, arc_rows) / std.math.tau;
const arc_half_cell: f32 = 0.5;

comptime {
    assert(arc_rows_per_radian == 16.0 / std.math.pi);
    assert(arc_columns_per_radian == 32.0 / std.math.pi);
}

/// `turret_aim_angles` (`0x0047CB10`): the yaw and pitch that turn an aimed turret toward `aim`,
/// as its model and its base stand drawn: in the model's root's frame and the base's part's own,
/// the yaw about X, then the pitch about Y. Null where they fall outside the base's yaw limits,
/// where it has any, or the pitching part's pitch limits, or where the direction from the pitching
/// part falls outside the turret's firing arc. A Huge Gun aimed up to `huge_overshoot` past a
/// pitch limit aims at the limit. A turret whose muzzle faces back aims in its base's frame turned
/// a half turn about X (`Aimed.reversed`).
///
/// **Improvement:** the game turns radians to degrees and back by a rounded 57.2958 and 0.0174533,
/// and a turn by 6.28319; OpenReliant by the exact values.
///
/// **Fix:** the game finds the angle from Y of the direction in the arc by dividing across by the
/// sine of its angle about Y, which is nothing for a direction straight ahead or behind;
/// OpenReliant takes the length across itself.
///
/// Not ported: the Stalag's turrets fire anywhere while the byte at `0x005883F8` is set, which the
/// hull's triggers set, perhaps with the player inside it
/// ([#220](https://github.com/vdmkenny/openreliant/issues/220)).
fn aimAngles(aimed: *const Aimed, aim: Vector) ?Angles {
    const model = aimed.model;
    const base = &model.parts[aimed.base];
    const in_base = math.transformTransposed(base.animation.orientation, math.transformTransposed(model.orientation, aim - base.object.position));
    const v: Vector = if (aimed.reversed) .{ in_base[0], -in_base[1], -in_base[2] } else in_base;
    const yaw = std.math.atan2(v[1], -v[2]);
    const along = @cos(yaw) * v[2] - @sin(yaw) * v[1];
    var pitch = math.halfTurn(-std.math.atan2(v[0], -along));
    const yaw_least = base.animation.angles_min[0];
    const yaw_most = base.animation.angles_max[0];
    if (yaw_least != yaw_most) {
        const degrees = math.halfTurn(yaw) * std.math.deg_per_rad;
        if (degrees > yaw_most or degrees < yaw_least) return null;
    }

    const pitching = &model.parts[aimed.pitch];
    const least = pitching.animation.angles_min[1];
    const most = pitching.animation.angles_max[1];
    var degrees = pitch * std.math.deg_per_rad;
    if (aimed.barrel.type.huge()) {
        if (most < degrees and degrees < most + huge_overshoot) {
            degrees = most;
            pitch = most * std.math.rad_per_deg;
        }
        if (degrees < least and least - huge_overshoot < degrees) {
            degrees = least;
            pitch = least * std.math.rad_per_deg;
        }
    }
    if (degrees > most or degrees < least) return null;

    if (aimed.arc) |arc| {
        const w = math.transformTransposed(model.orientation, aim - pitching.object.position);
        const around = std.math.atan2(w[0], w[2]);
        const from = std.math.atan2(@sqrt(w[0] * w[0] + w[2] * w[2]), w[1]);
        const row: u32 = @bitCast(math.round((around + std.math.tau) * arc_rows_per_radian - arc_half_cell));
        const column: i32 = math.round((from + std.math.tau) * arc_columns_per_radian - arc_half_cell);
        const rows = [2]u5{ @truncate(row), @truncate(row +% 1) };
        const columns = [2]u4{ @truncate(@as(u32, @bitCast(-%column))), @truncate(@as(u32, @bitCast(1 -% column))) };
        for (rows) |r| for (columns) |c| if (!arc.open(r, c)) return null;
    }
    return .{ .yaw = math.halfTurn(yaw), .pitch = pitch };
}

/// `turret_pick_target` (`0x0047D1F0`): the first object, in slot order, that an aimed turret can
/// lead with its gun from its base and aim at: of a type below 0x100, not the turret's own object,
/// of neither its side nor the neutral one; a Huge Gun only a ship that lists components. A ship
/// that lists no components, or any for a Huge Gun, is aimed at whole; any other only by a turret
/// whose own object lists components and is not a Kurgan, an Antanov, a Nanny or a Prowler, at its
/// first component the turret can reach. None found, the turret has no target.
///
/// **Fix:** the game doesn't ask whether the object is valid to aim at, so an exploding, cloaked or
/// untargetable one early in the slots is picked, dropped by the next track and picked again,
/// keeping the turret from any other; OpenReliant passes over what the track would drop
/// (`ai.targetValid`).
///
/// Not ported: in a multiplayer game, the player who last hurt the turret's object is passed over
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn pickTarget(world: gameobj.World, index: u16, aimed: *Aimed) void {
    const all = world.objects;
    const own = &all.slots[index].object;
    aimed.to_turn = .{};
    const huge = aimed.barrel.type.huge();
    const from = aimed.model.parts[aimed.base].object.position;
    const components_aimed = own.flags.components and switch (own.type) {
        .kurgan, .antanov, .nanny, .prowler => false,
        else => true,
    };
    for (all.slots[0..all.count], 0..) |*slot, at| {
        const candidate: u16 = @intCast(at);
        const object = &slot.object;
        if (aimed.target.slot() == candidate or candidate == index) continue;
        if (!object.type.hasStats() or object.side == own.side or object.side == .neutral) continue;
        if (huge and !object.flags.components) continue;
        aimed.target = .at(candidate, null);
        if (object.component_count < 1 or huge) {
            if (reaches(all, aimed, from)) return;
        } else if (components_aimed) {
            for (slot.listed(), 0..) |component, number| {
                if (component == null) continue;
                aimed.target = .at(candidate, @intCast(number));
                if (reaches(all, aimed, from)) return;
            }
        }
    }
    aimed.target = .none;
}

/// Whether an aimed turret can lead its target, where it is valid, from `from`, and aim at where it
/// leads it.
fn reaches(all: *const create.Objects, aimed: *const Aimed, from: Vector) bool {
    if (!ai.targetValid(all, aimed.target, .{})) return false;
    const aim = ai.leadAimWithGun(all, from, aimed.target, aimed.barrel.type, 1) orelse return false;
    return aimAngles(aimed, aim) != null;
}

/// How fast a spinning gun's barrels spin up and down a tick, and at most (`0x004DC420`,
/// `0x004DC4AC`, `0x004DC424`); how fast its flaps open and shut.
const spin_up: f32 = 0.1;
const spin_down: f32 = 0.02;
const spin_most: f32 = 4;
const flap_speed: f32 = 4;

/// `turret_spin_step` (`0x0047C9B0`): a spinning gun's barrels loop their `fire` track, from a
/// standstill at first. While its trigger is held the barrels spin up, its gun's track loops at
/// their speed and its flaps open; otherwise the barrels spin down, its gun's track stops at its
/// start, and its flaps shut. The gun fires by its trigger (`guns.step`), however fast it spins.
///
/// **Quirk:** the trigger counts as held through the tick it is held until, where the guns' step
/// fires only before it.
fn spinStep(world: gameobj.World, gun: *const guns.Fitted, spin: *const Spin) void {
    const model = spin.model;
    const barrels = &model.parts[spin.barrels].animation;
    if (barrels.mode == .none) model.play(spin.barrels, .fire, 0, .loop, 0);
    const ticks: f32 = @floatFromInt(world.clock.frame_duration);
    const held = gun.firing_until >= world.clock.frame_start;
    barrels.speed = if (held) @min(barrels.speed + ticks * spin_up, spin_most) else @max(barrels.speed - ticks * spin_down, 0);
    model.markAnimating(spin.barrels);
    if (spin.gun) |part| {
        if (held) {
            model.parts[part].animation.mode = .loop;
            model.parts[part].animation.speed = barrels.speed;
            model.markAnimating(part);
        } else model.play(part, .fire, 0, .none, flap_speed);
    }
    for (spin.flaps) |flap| {
        const part = flap orelse continue;
        model.parts[part].animation.mode = .once;
        model.parts[part].animation.speed = if (held) flap_speed else -flap_speed;
        model.markAnimating(part);
    }
}

/// Within this share of its Screamers' lock range a missile turret keeps its target, and within
/// this of the distance to it, up or down from its launcher, and ahead of it, it tracks and
/// launches (`0x004DC408`, `0x004DC484`).
const keep_range: f32 = 0.5;
const missile_cone: f32 = 0.7;

/// How far to either side a missile turret's target may stand, as a share of the distance, before
/// the turret turns toward it, and by how much it turns a frame (`0x004DC420`, `0x004DC4E8`).
const missile_band: f32 = 0.1;
const missile_turn: f32 = 0.1;

/// The odds a missile turret launches each time it may (`0x004DC3F8`), and how long it waits after
/// (1000 ticks in mission 28).
const launch_odds: f32 = 0.2;
const launch_wait: i32 = 2000;
const hurried_launch_wait: i32 = 1000;
const hurried_mission = 28;

/// A missile turret's waits: to look again once it drops its target; empty, before it reloads;
/// and while its launcher plays its `reload` track forward and back. Then it holds `load` missiles.
const retry_wait = 20;
const empty_wait = 100;
const loading_wait = 800;
const closing_wait = 300;
const load = 6;
const reload_speed: f32 = 4;

/// `turret_missile_step` (`0x0047D560`): a missile turret, by its state. Searching, once its wait
/// is over, it picks the object nearest ahead of its launcher, within its Screamers' lock range and
/// within `missile_cone` of the distance up or down, that is targetable, of another side, lists no
/// components, and is neither a stand-in, exploding nor disabled; with one, it tracks. Tracking, it
/// drops a target no longer valid, beyond `keep_range` of its lock range or outside the cone up or
/// down, and looks again 20 ticks later; otherwise it turns its base `missile_turn` toward one
/// standing to either side, and with the target within the cone ahead and its wait over, launches
/// a Screamer at it one time in five (`missiles.launchFromTurret`), waiting 2000 ticks either way.
/// Out of missiles, it waits 100 ticks, then plays its launcher's `reload` track forward for 800
/// ticks and back for 300, and holds six. It starts out of missiles.
///
/// **Quirks:** it turns by `missile_turn` a frame, however long the frame; a missile counts as
/// spent when the roll lets it launch, whether one is launched or not; and a target found within
/// the lock range but beyond half of it is found and dropped in turn.
///
/// Not ported: in a multiplayer game, the player who last hurt the turret's object is passed over
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn missileStep(world: gameobj.World, index: u16, launcher: *Launcher) void {
    const all = world.objects;
    const now = world.clock.frame_start;
    const model = launcher.model;
    const from = model.parts[launcher.launcher].drawn();
    const reach = all.missile_stats.of(.screamer).?.lock_range;
    switch (launcher.state) {
        .searching => {
            if (launcher.missiles == 0) return empty(launcher, now);
            if (launcher.until > now) return;
            const own = &all.slots[index].object;
            launcher.target = .none;
            var best: f32 = -1;
            for (all.slots[0..all.count], 0..) |*slot, candidate| {
                if (candidate == index) continue;
                const flags = slot.object.flags;
                if (flags.components or flags.outOfSearch() or !flags.targetable) continue;
                if (slot.object.side == own.side) continue;
                const seen: Bearing = .of(from, slot.object.nextPosition());
                if (seen.distance > reach or !seen.level()) continue;
                if (seen.distance * best < seen.local[2]) {
                    best = seen.local[2] / seen.distance;
                    launcher.target = .at(@intCast(candidate), null);
                }
            }
            if (launcher.target.slot() != null) launcher.state = .tracking;
        },
        .tracking => {
            if (launcher.missiles == 0) return empty(launcher, now);
            const target = launcher.target.slot() orelse return lose(launcher, now);
            if (!ai.targetValid(all, launcher.target, .{})) return lose(launcher, now);
            const seen: Bearing = .of(from, all.slots[target].object.nextPosition());
            if (seen.distance > reach * keep_range or !seen.level()) return lose(launcher, now);
            if (seen.local[0] < seen.distance * -missile_band) turn(model, launcher.base, .{ 0, -missile_turn, 0 });
            if (seen.local[0] > seen.distance * missile_band) turn(model, launcher.base, .{ 0, missile_turn, 0 });
            if (seen.local[2] <= seen.distance * missile_cone or launcher.until >= now) return;
            if (world.random.fraction() < launch_odds) {
                missiles.launchFromTurret(world, index, model, launcher.launcher, launcher.target);
                launcher.missiles -= 1;
            }
            launcher.until = now + if (world.objects.mission_number == hurried_mission) hurried_launch_wait else launch_wait;
        },
        .empty => if (launcher.until < now) {
            launcher.state = .loading;
            launcher.until = now + loading_wait;
            model.playNamed(launcher.launcher, "reload", 0, .once, reload_speed);
        },
        .loading => if (launcher.until < now) {
            launcher.state = .closing;
            launcher.until = now + closing_wait;
            model.playNamed(launcher.launcher, "reload", -1, .once, -reload_speed);
        },
        .closing => if (launcher.until < now) {
            launcher.missiles = load;
            launcher.state = .searching;
        },
    }
}

/// Where a missile turret's launcher, standing at `from`, sees what stands at `point`: how far off,
/// and in its frame.
const Bearing = struct {
    distance: f32,
    local: Vector,

    fn of(from: math.Place, point: Vector) Bearing {
        return .{ .distance = math.length(point - from.position), .local = from.inverse(point) };
    }

    /// Whether it stands within `missile_cone` of the distance up or down.
    fn level(seen: Bearing) bool {
        return @abs(seen.local[1]) <= seen.distance * missile_cone;
    }
};

/// A missile turret out of missiles waits to reload.
fn empty(launcher: *Launcher, now: i32) void {
    launcher.state = .empty;
    launcher.until = now + empty_wait;
}

/// A missile turret that loses its target looks again shortly.
fn lose(launcher: *Launcher, now: i32) void {
    launcher.state = .searching;
    launcher.until = now + retry_wait;
}

test {
    std.testing.refAllDecls(@This());
}

/// Fixtures for the tests here and in the modules that step turrets.
pub const testing = struct {
    const srofiles = @import("../srofiles.zig");

    /// A model of `count` parts, each standing unturned at the model's origin, with no mesh.
    pub fn Parts(comptime count: usize) type {
        return struct {
            data: [count]shp.PartData,
            loaded_parts: [count]srofiles.LoadedPart,
            source: shp.Model,
            loaded: srofiles.Loaded,

            /// The parts, each hanging from the root, for the test to fill in before `create`.
            pub fn init(parts: *@This()) void {
                for (&parts.data, &parts.loaded_parts) |*data, *loaded| {
                    data.* = objects.testing.part();
                    data.part.parent = -1;
                    data.part.turret_slot = -1;
                    loaded.* = .{ .flags = .{}, .levels = &.{}, .meshes = &.{} };
                }
                parts.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &parts.data, .trailing_bytes = 0 };
                parts.loaded = .{ .parts = &parts.loaded_parts };
            }

            /// Makes part `index` the turret of `kind` of the assembly `link`, in its `slot`.
            pub fn turret(parts: *@This(), index: usize, class: shp.Part.Class, kind: shp.Part.TurretKind, link: u32, slot: i32) void {
                parts.data[index].part.class = class;
                parts.data[index].part.turret_kind = kind;
                parts.member(index, link, slot);
            }

            /// Makes part `index` one of the assembly `link`, in `slot`.
            pub fn member(parts: *@This(), index: usize, link: u32, slot: i32) void {
                parts.data[index].part.link_id = link;
                parts.data[index].part.turret_slot = slot;
            }

            pub fn create(parts: *@This(), gpa: std.mem.Allocator) !objects.Model {
                var model: objects.Model = try .create(gpa, &parts.source, &parts.loaded, .{});
                for (0..model.parts.len) |index| @import("../gameobj.zig").linkPart(&model, index);
                return model;
            }
        };
    }

    /// A muzzle of gun type `gun_type`.
    pub fn muzzle(gun_type: u32) shp.Attachment {
        var attachment = std.mem.zeroes(shp.Attachment);
        attachment.kind = .gun_muzzle;
        attachment.orientation = @import("../../surrender/math.zig").identity;
        attachment.gun_type = gun_type;
        return attachment;
    }
};

test fit {
    const gpa = std.testing.allocator;
    var parts: testing.Parts(9) = undefined;
    parts.init();
    // A hull with a muzzle of its own.
    var hull = [_]shp.Attachment{testing.muzzle(1)};
    parts.data[0].attachments = &hull;
    // An aimed turret: its base, its barrels, and a part of the assembly in no slot, whose muzzle
    // is the last and so the gun's.
    parts.turret(1, .turret, .aimed, 5, 0);
    parts.member(2, 5, 1);
    parts.member(3, 5, -1);
    var barrels = [_]shp.Attachment{testing.muzzle(12)};
    var last = [_]shp.Attachment{testing.muzzle(13)};
    parts.data[2].attachments = &barrels;
    parts.data[3].attachments = &last;
    // A missile turret: its base and its launcher.
    parts.turret(4, .missile_turret, .missile, 7, 0);
    parts.member(5, 7, 1);
    // A turret's class with no kind: it and its assembly are passed over, muzzles and all.
    parts.turret(6, .ion_cannon, .fixed, 9, -1);
    parts.member(7, 9, -1);
    var ion = [_]shp.Attachment{testing.muzzle(2)};
    parts.data[7].attachments = &ion;
    // An aimed turret with no muzzle gives no gun.
    parts.turret(8, .turret, .aimed, 11, 0);

    var model = try parts.create(gpa);
    defer model.deinit(gpa);
    const fitted = try guns.fit(gpa, &model, .{});
    defer gpa.free(fitted);
    try std.testing.expectEqual(3, fitted.len);
    try std.testing.expectEqual(0, fitted[0].turret.fixed.muzzle.part);

    const aimed = fitted[1].turret.aimed;
    try std.testing.expectEqual(1, aimed.base);
    try std.testing.expectEqual(2, aimed.pitch);
    try std.testing.expectEqual([3]?usize{ null, null, null }, aimed.slots);
    try std.testing.expectEqual(3, aimed.barrel.muzzle.part);
    try std.testing.expectEqual(guns.GunType.turret_lasers, aimed.barrel.type);
    try std.testing.expect(model.parts[1].turret and !model.parts[2].turret);
    try std.testing.expectEqual(null, aimed.target.ship());
    try std.testing.expectEqual(null, aimed.arc);

    const launcher = fitted[2].turret.missile;
    try std.testing.expectEqual(4, launcher.base);
    try std.testing.expectEqual(5, launcher.launcher);
    try std.testing.expectEqual(0, launcher.missiles);
    try std.testing.expect(fitted[2].barrel() == null);
}

test "a turret on a component fires within the component's arc" {
    const gpa = std.testing.allocator;
    var parts: testing.Parts(2) = undefined;
    parts.init();
    parts.turret(0, .turret, .aimed, 3, 0);
    parts.member(1, 3, 1);
    parts.data[0].part.flags.component = true;
    var barrels = [_]shp.Attachment{testing.muzzle(12)};
    parts.data[1].attachments = &barrels;
    var model = try parts.create(gpa);
    defer model.deinit(gpa);

    // The base is the object's second component: the second arc is its.
    const components = [_]?*objects.Model.Part{ null, &model.parts[0] };
    const arcs: [2]shp.FiringArc = @splat(std.mem.zeroes(shp.FiringArc));
    const turret = fit(&model, 0, .{ .components = &components, .arcs = &arcs }).?;
    try std.testing.expectEqual(&arcs[1], turret.aimed.arc.?);
    // Without arcs in the model, it fires anywhere its limits let it.
    try std.testing.expectEqual(null, fit(&model, 0, .{ .components = &components }).?.aimed.arc);
    // Nor past the arcs the model has.
    try std.testing.expectEqual(null, fit(&model, 0, .{ .components = &components, .arcs = arcs[0..1] }).?.aimed.arc);
}

/// A mission with a ship at the origin, facing along Z, whose model is `parts`, and a hostile ship
/// for its turrets to aim at.
const Stage = struct {
    mission: gameobj.testing.Mission,
    parts: testing.Parts(4),
    ship: u16,
    target: u16,
    /// Each part's tracks: a `fire` track whose event fires its muzzles, and a `reload` track.
    events: [1]shp.ClipEvent,
    tracks: [2]shp.Track,

    fn init(stage: *Stage, gpa: std.mem.Allocator) !void {
        try stage.mission.init(gpa);
        stage.parts.init();
        stage.events = .{.{ .time = 0, .kind = .muzzles, ._unknown_08 = 0 }};
        stage.tracks = .{
            .{ .clip = objects.testing.clip(10, .once, "fire"), .keyframes = &.{}, .events = &stage.events },
            .{ .clip = objects.testing.clip(10, .once, "reload"), .keyframes = &.{}, .events = &.{} },
        };
        for (&stage.parts.data) |*part| part.tracks = &stage.tracks;
        stage.ship = try stage.mission.add(.predator, @splat(0));
        stage.target = try stage.mission.add(.sabre, .{ 0, 0, 3000 });
        const target = &stage.mission.slot(stage.target).object;
        target.side = .hostile;
        target.flags.targetable = true;
        target.radius = 100;
        stage.mission.slot(stage.target).drawn.position = .{ 0, 0, 3000 };
        stage.mission.slot(stage.ship).object.side = .friendly;
        stage.mission.clock = .{ .frame_start = 1000, .frame_duration = 10 };
        const turret_lasers = &stage.mission.objects.gun_stats.types[guns.GunType.turret_lasers.number()];
        turret_lasers.speed = 1000;
        turret_lasers.lifetime = 100;
    }

    /// Gives the ship its model, with the parts as the test has filled them in, and its guns.
    fn arm(stage: *Stage) !void {
        const gpa = stage.mission.objects.gpa;
        const slot = stage.mission.slot(stage.ship);
        slot.model = try stage.parts.create(gpa);
        slot.guns = try guns.fit(gpa, &slot.model.?, .{});
        slot.model.?.place(@splat(0), math.identity);
    }

    fn gun(stage: *Stage) *guns.Fitted {
        return &stage.mission.slot(stage.ship).guns[0];
    }

    fn deinit(stage: *Stage) void {
        stage.mission.deinit();
    }
};

test aimAngles {
    var stage: Stage = undefined;
    try stage.init(std.testing.allocator);
    defer stage.deinit();
    stage.parts.turret(0, .turret, .aimed, 1, 0);
    stage.parts.member(1, 1, 1);
    // A muzzle facing along the turret's aim of no yaw and no pitch, -Z.
    var barrels = [_]shp.Attachment{testing.muzzle(13)};
    barrels[0].orientation = math.rotation(.y, std.math.pi);
    stage.parts.data[1].attachments = &barrels;
    stage.parts.data[1].part.angles_min.y = -60;
    stage.parts.data[1].part.angles_max.y = 60;
    try stage.arm();
    const aimed = &stage.gun().turret.aimed;

    // Its zero aim is along -Z of its base's frame; it yaws toward Y about X, and pitches toward X
    // about Y.
    try std.testing.expect(!aimed.reversed);
    try std.testing.expectEqual(Angles{}, aimAngles(aimed, .{ 0, 0, -1000 }).?);
    const up = aimAngles(aimed, .{ 0, 1000, -1000 }).?;
    try std.testing.expectApproxEqAbs(std.math.pi / 4.0, up.yaw, 1e-6);
    try std.testing.expectApproxEqAbs(0, up.pitch, 1e-6);
    const aside = aimAngles(aimed, .{ 1000, 0, -1000 }).?;
    try std.testing.expectApproxEqAbs(0, aside.yaw, 1e-6);
    try std.testing.expectApproxEqAbs(-std.math.pi / 4.0, aside.pitch, 1e-6);
    // Past the pitching part's limit it can't aim; nor past its base's, where it has any.
    try std.testing.expectEqual(null, aimAngles(aimed, .{ 3000, 0, -1000 }));
    aimed.model.parts[0].animation.angles_min[0] = -30;
    aimed.model.parts[0].animation.angles_max[0] = 30;
    try std.testing.expectEqual(null, aimAngles(aimed, .{ 0, 1000, -1000 }));
    // A Huge Gun up to 20 degrees past its pitch limit aims at the limit.
    aimed.barrel.type = .allied_huge_gun;
    const past = aimAngles(aimed, .{ 1000, 0, -500 }).?;
    try std.testing.expectApproxEqAbs(-60 * std.math.rad_per_deg, past.pitch, 1e-6);
    aimed.barrel.type = .turret_lasers;
    aimed.model.parts[0].animation.angles_min[0] = 0;
    aimed.model.parts[0].animation.angles_max[0] = 0;
    // A firing arc with nothing open lets it fire nowhere; one open straight back from Z, toward
    // the turret's aim, lets it fire there, where the game divides nothing by nothing.
    var arc = std.mem.zeroes(shp.FiringArc);
    aimed.arc = &arc;
    try std.testing.expectEqual(null, aimAngles(aimed, .{ 0, 0, -1000 }));
    arc.rows[16] = 0b11;
    arc.rows[17] = 0b11;
    try std.testing.expect(aimAngles(aimed, .{ 0, 0, -1000 }) != null);
}

test "a turret whose muzzle faces back aims along it" {
    var stage: Stage = undefined;
    try stage.init(std.testing.allocator);
    defer stage.deinit();
    // A fighter's rear turret: one part, its muzzle along +Z, where its aim of no yaw and no pitch
    // is along -Z.
    stage.parts.turret(0, .turret, .aimed, 1, 0);
    var tail = [_]shp.Attachment{testing.muzzle(1)};
    stage.parts.data[0].attachments = &tail;
    stage.parts.data[0].part.angles_min = .{ .x = -90, .y = -60, .z = 0 };
    stage.parts.data[0].part.angles_max = .{ .x = 90, .y = 60, .z = 0 };
    try stage.arm();
    const aimed = &stage.gun().turret.aimed;
    try std.testing.expect(aimed.reversed);
    try std.testing.expect(aimed.model.parts[0].animation.reversed);

    // It aims along its muzzle, and turns its pitch the other way round as it poses.
    try std.testing.expectEqual(Angles{}, aimAngles(aimed, .{ 0, 0, 1000 }).?);
    const aside = aimAngles(aimed, .{ 1000, 0, 1000 }).?;
    try std.testing.expectApproxEqAbs(-std.math.pi / 4.0, aside.pitch, 1e-6);
    aimed.model.swivel(0, .{ 0, aside.pitch, 0 });
    aimed.model.pose(0);
    try std.testing.expectApproxEqAbs(std.math.pi / 4.0, aimed.model.parts[0].animation.next.pose.angles[1], 1e-6);
    // So posed, its muzzle points at what it aimed at.
    const muzzle = aimed.barrel.muzzle.at(&stage.mission.slot(stage.ship).model.?, .{}, .next).?;
    try std.testing.expect(ai.alongNose(.{ .orientation = muzzle.orientation }, .{ 1000, 0, 1000 }, 10));
}

test "an aimed turret passes over a ship the track would drop" {
    var stage: Stage = undefined;
    try stage.init(std.testing.allocator);
    defer stage.deinit();
    stage.parts.turret(0, .turret, .aimed, 1, 0);
    var barrels = [_]shp.Attachment{testing.muzzle(13)};
    stage.parts.data[0].attachments = &barrels;
    try stage.arm();
    const aimed = &stage.gun().turret.aimed;
    // An untargetable hostile ship before the target in the slots is passed over.
    const hidden = try stage.mission.add(.sabre, .{ 0, 0, 2000 });
    stage.mission.slot(hidden).object.side = .hostile;
    stage.mission.slot(hidden).object.flags.targetable = false;
    const later = try stage.mission.add(.sabre, .{ 0, 0, 2500 });
    stage.mission.slot(later).object.side = .hostile;
    stage.mission.slot(later).object.flags.targetable = true;
    stage.mission.slot(later).drawn.position = .{ 0, 0, 2500 };
    stage.mission.slot(stage.target).object.flags.targetable = false;
    pickTarget(stage.mission.world(), stage.ship, aimed);
    try std.testing.expectEqual(later, aimed.target.ship());
}

test "an aimed turret fires where its muzzle points, and turns toward its target" {
    var stage: Stage = undefined;
    try stage.init(std.testing.allocator);
    defer stage.deinit();
    stage.parts.turret(0, .turret, .aimed, 1, 0);
    stage.parts.member(1, 1, 1);
    var barrels = [_]shp.Attachment{testing.muzzle(13)};
    stage.parts.data[1].attachments = &barrels;
    stage.parts.data[1].part.angles_min.y = -90;
    stage.parts.data[1].part.angles_max.y = 90;
    try stage.arm();
    const world = stage.mission.world();
    const aimed = &stage.gun().turret.aimed;

    // With no target, it looks for one: the hostile ship, not its own side's.
    _ = try stage.mission.add(.predator, .{ 0, 0, 2000 });
    step(world, stage.ship);
    try std.testing.expectEqual(stage.target, aimed.target.ship());
    try std.testing.expect(aimed.looks_at >= 1100 and aimed.looks_at < 1200);

    // Its muzzle points along Z at the target, so it fires: the trigger held for a tick, and the
    // parts' `fire` tracks playing, whose events fire the muzzles.
    step(world, stage.ship);
    try std.testing.expectEqual(1001, stage.gun().firing_until);
    try std.testing.expectEqual(0, aimed.model.parts[1].animation.track);
    try std.testing.expect(aimed.model.parts[1].animation.mode == .once);
    // It aims along its muzzle already, so it doesn't turn; toward a target off to the side it
    // turns at most 0.02 a tick.
    try std.testing.expectApproxEqAbs(0, aimed.model.parts[0].animation.turret[0], 1e-6);
    stage.mission.slot(stage.target).drawn.position = .{ 0, 3000, 3000 };
    step(world, stage.ship);
    try std.testing.expectApproxEqAbs(0.2, @abs(aimed.model.parts[0].animation.turret[0]), 1e-6);

    // A target that is no longer valid is dropped.
    stage.mission.slot(stage.target).object.flags.targetable = false;
    step(world, stage.ship);
    try std.testing.expectEqual(null, aimed.target.ship());
}

test "a spinning gun spins up while its trigger is held" {
    var stage: Stage = undefined;
    try stage.init(std.testing.allocator);
    defer stage.deinit();
    stage.parts.turret(0, .turret, .spin, 1, 0);
    stage.parts.member(1, 1, 1);
    stage.parts.member(2, 1, 2);
    stage.parts.member(3, 1, 3);
    var gun_muzzle = [_]shp.Attachment{testing.muzzle(9)};
    stage.parts.data[1].attachments = &gun_muzzle;
    try stage.arm();
    const world = stage.mission.world();
    const model = &stage.mission.slot(stage.ship).model.?;

    // Held, the barrels spin up a tenth a tick, to at most 4, the gun loops at their speed and
    // the flaps open.
    stage.gun().firing_until = 1000;
    step(world, stage.ship);
    try std.testing.expectEqual(1, model.parts[0].animation.speed);
    try std.testing.expectEqual(objects.Model.Mode.loop, model.parts[1].animation.mode);
    try std.testing.expectEqual(1, model.parts[1].animation.speed);
    try std.testing.expectEqual(4, model.parts[2].animation.speed);
    for (0..5) |_| step(world, stage.ship);
    try std.testing.expectEqual(4, model.parts[0].animation.speed);
    // Let go, they spin down a fiftieth a tick, the gun's track stops, and the flaps shut.
    stage.gun().firing_until = 999;
    step(world, stage.ship);
    try std.testing.expectApproxEqAbs(3.8, model.parts[0].animation.speed, 1e-6);
    try std.testing.expectEqual(objects.Model.Mode.none, model.parts[1].animation.mode);
    try std.testing.expectEqual(-4, model.parts[3].animation.speed);
}

test "a missile turret reloads, then tracks and launches" {
    var stage: Stage = undefined;
    try stage.init(std.testing.allocator);
    defer stage.deinit();
    stage.parts.turret(0, .missile_turret, .missile, 1, 0);
    stage.parts.member(1, 1, 1);
    try stage.arm();
    const world = stage.mission.world();
    const clock = &stage.mission.clock;
    const launcher = &stage.gun().turret.missile;

    // It starts empty: it waits, plays its launcher's reload forward and back, and holds six.
    step(world, stage.ship);
    try std.testing.expectEqual(Launcher.State.empty, launcher.state);
    try std.testing.expectEqual(1100, launcher.until);
    clock.frame_start = 1101;
    step(world, stage.ship);
    try std.testing.expectEqual(Launcher.State.loading, launcher.state);
    try std.testing.expectEqual(4, stage.mission.slot(stage.ship).model.?.parts[1].animation.speed);
    clock.frame_start = 1902;
    step(world, stage.ship);
    try std.testing.expectEqual(Launcher.State.closing, launcher.state);
    clock.frame_start = 2203;
    step(world, stage.ship);
    try std.testing.expectEqual(Launcher.State.searching, launcher.state);
    try std.testing.expectEqual(6, launcher.missiles);

    // It finds the hostile ship ahead, and tracks it.
    step(world, stage.ship);
    try std.testing.expectEqual(Launcher.State.tracking, launcher.state);
    try std.testing.expectEqual(stage.target, launcher.target.ship());
    // Each time its wait is over it launches one time in five, then waits 2000 ticks, or 1000 in
    // mission 28. Where the ship can't build the Screamer, the missile is spent all the same.
    var tries: usize = 0;
    while (launcher.missiles == 6 and tries < 100) : (tries += 1) {
        clock.frame_start = launcher.until + 1;
        step(world, stage.ship);
        try std.testing.expectEqual(clock.frame_start + 2000, launcher.until);
    }
    try std.testing.expectEqual(5, launcher.missiles);
    stage.mission.objects.mission_number = 28;
    clock.frame_start = launcher.until + 1;
    step(world, stage.ship);
    try std.testing.expectEqual(clock.frame_start + 1000, launcher.until);

    // A target beyond half its Screamers' lock range is dropped, and looked for again shortly.
    stage.mission.slot(stage.target).object.root.next_position = .{ .x = 0, .y = 0, .z = 40000 };
    step(world, stage.ship);
    try std.testing.expectEqual(Launcher.State.searching, launcher.state);
    try std.testing.expectEqual(clock.frame_start + 20, launcher.until);
}

test "a ship exploding or docking steps no turrets" {
    var stage: Stage = undefined;
    try stage.init(std.testing.allocator);
    defer stage.deinit();
    stage.parts.turret(0, .missile_turret, .missile, 1, 0);
    stage.parts.member(1, 1, 1);
    try stage.arm();
    stage.mission.slot(stage.ship).object.flags.exploding = true;
    step(stage.mission.world(), stage.ship);
    try std.testing.expectEqual(Launcher.State.searching, stage.gun().turret.missile.state);
}
