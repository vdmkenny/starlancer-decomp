//! The Reliant's launches (`launch_reliant_init`, `0x0041AE20`, and `launch_reliant_run`,
//! `0x0041B240`): a ship drops out of the Reliant through one of its six tubes, each shut by a
//! door above and one below. The player's ship is shown lowered within the Reliant's hangar
//! (`reliant_hang.shp`), a cutaway made in the cutaway slot and laid over the tube, and one of
//! three cutaway views (`Cutaway`) watches it go.

const std = @import("std");
const log = std.log.scoped(.launch);

const shp = @import("../../../formats/shp.zig");
const math = @import("../../surrender/math.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const aigeneric = @import("../aigeneric.zig");
const camera = @import("../camera.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const hog_snd = @import("../hog_snd.zig");
const objects = @import("../objects.zig");
const sound3d = @import("../sound3d.zig");
const srofiles = @import("../srofiles.zig");
const launch = @import("../launch.zig");

/// A launch's steps from the Reliant, each named for what it does as it runs, once the wait the
/// step before set has passed (`launch.State.due`).
pub const Step = enum(i32) {
    /// The ship's engine starts, for the player's with a shake, the cutaway is picked, and the
    /// tube's upper door shows.
    start = 2,
    /// The hangar's retainer lowers the player's ship.
    lower = 3,
    /// The retainer lets go, and the ship no longer rides its node.
    release = 4,
    /// The tube's lower door opens, and the hangar's.
    open = 5,
    /// The ship drops out, the mission's date typed out on the player's screen.
    drop = 6,
    /// Clear of the bay, the cutaway ends.
    clear = 7,
    /// It drops on.
    fall = 8,
    /// It steadies, flying ahead again.
    level = 9,
    /// The launch ends.
    end = 10,
    _,

    fn of(step: launch.Step) Step {
        return @enumFromInt(@intFromEnum(step));
    }

    fn generic(step: Step) launch.Step {
        return @enumFromInt(@intFromEnum(step));
    }
};

/// How long each step waits for the next, in ticks (`launch_reliant_run`, `0x0041B287`,
/// `0x0041B382`, `0x0041B3D9`, `0x0041B4AB`, `0x0041B503`, `0x0041B55E`, `0x0041B575`, and
/// `0x0041B5BE` for a ship not the player's; the player's ends at once).
fn wait(step: Step) i32 {
    return switch (step) {
        .start => 100,
        .lower => 250,
        .release => 50,
        .open => 150,
        .drop => 50,
        .clear => 150,
        .fall => 300,
        .level => 200,
        .end, _ => 0,
    };
}

/// Which of the three cutaways the player's launch shows (`launch_cutaway`, `0x0051D0EC`),
/// picked at random as it starts: none from the mission's load (`launches_init`, `0x00418A70`).
pub const Cutaway = enum(i32) {
    none = -1,
    /// From within the bay, from the start (`camera.View.launch_bay`).
    bay = 1,
    /// From below, once the ship is clear (`camera.View.launch_below`).
    below = 2,
    /// From aside, from the door's opening, the hangar gone (`camera.View.launch_aside`).
    aside = 3,
    _,
};

/// How many cutaways `start` picks among.
const cutaways = 3;

/// The shake the player's ship's engine starts with (`hit_shake`, `0x0041B2A4`).
const start_shake: f32 = 0.1;

/// The door parts of a tube: its upper door is part `gate + door_step` of the Reliant's root's
/// child list, its lower door part `gate`.
const door_step = 6;

/// How far across a tube's middle lies from its doors', in their frames: to the right for a gate
/// of even number, to the left for an odd (`0x004DC5A8`).
const tube_offset: f32 = 400;

/// The hangar's parts that its dim light alone reaches: its hull and its two doors, the first
/// three of its root's child list (`0x0041B10C`).
const lit_parts = 3;

/// The light mask the hangar's hull and doors take (`0x0041B10C`): every light of the backdrop's
/// but its first ambient (`backdrop.Lights`, `0x04`) is kept out, so that only their baked
/// colours, the ambient's glimmer and the lights that reach every object light them.
const hangar_light_mask: u32 = 0x3B;

/// The hangar's parts the launch plays tracks on: its lower door, which opens as the tube's does,
/// and its retainer, which lowers the ship.
const hangar_door = 2;
const hangar_retainer = 3;

/// The hangar's launch points: the first for a gate of odd number, the second, turned half a turn
/// with the hangar, for an even.
const hangar_points = [2]i16{ 0, 1 };

/// The tracks the launch plays, and how fast (`node_play_named`): the doors' opening, the upper
/// door's closing back, and the retainer's lowering, played back to raise it.
const open_track = "opendoor";
const deploy_track = "deploy";
const door_speed: f32 = 2;
const hangar_door_speed: f32 = 4;
const upper_door_speed: f32 = -1;
const retainer_speed: f32 = 2;

/// The standard samples the player hears (`bank_stdsmp`): the retainer's clamps as it lowers the
/// ship, and the doors as they open, as loud as they go.
const lowered_sample = 6;
const opened_sample = 5;
const sample_volume = 127;

/// `launch_reliant_init` (`0x0041AE20`): readies the ship in slot `index` to launch from the
/// Reliant in slot `carrier`, through the gate its order's target names by its component. It
/// rides the Reliant's root, its steering and its throttle nothing, and stands in its tube
/// (`tube`), turned as the Reliant turns next. The player's ship's launch shows the hangar
/// (`showHangar`), in which it rides the retainer; the Reliant becomes the ship the player launched
/// from (`input.Player.carrier`), which the cutaway leaves out, and the camera takes view 0 in the
/// cockpit mode, locked.
///
/// **Fix:** the game reads through a tube door the Reliant's model lacks; OpenReliant leaves the
/// ship where it stands.
pub fn init(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    slot.riding = .{ .object = carrier };
    const object = &slot.object;
    object.roll_input = 0;
    object.pitch_input = 0;
    object.yaw_input = 0;
    object.throttle = 0;
    const gate = slot.orders[0].target.component;
    const reliant = &all.slots[carrier];
    const in_tube = tube(reliant, gate) orelse {
        log.warn("the Reliant in slot {d} has no tube {d}", .{ carrier, gate });
        return;
    };
    const turn = reliant.object.root.next_orientation;
    objects.setPosition(object, &slot.drawn, in_tube);
    objects.setOrientation(object, &slot.drawn, turn);
    if (index != all.player) return;
    world.player.carrier = carrier;
    showHangar(ctx, index, gate, in_tube, turn);
    if (world.camera) |view| {
        view.cockpit_mode = .cockpit;
        _ = view.setView(.cockpit, all.player, true, true, ctx.clock.viewTime());
    }
    world.player.showing = .launch;
}

/// Where a ship launching through `gate` stands in `reliant`: halfway between the middles of the
/// tube's doors, each the middle of the bounds of the level its part drew last, `tube_offset`
/// across in the door's frame. Null where the Reliant's model lacks either door, or its part has
/// no level.
fn tube(reliant: *const create.Slot, gate: i16) ?math.Vector {
    const model = if (reliant.model) |*held| held else return null;
    const lower = std.math.cast(usize, gate) orelse return null;
    const across: f32 = if (@mod(gate, 2) == 0) tube_offset else -tube_offset;
    var sum: math.Vector = @splat(0);
    for ([_]usize{ lower, lower + door_step }) |door| {
        const part = model.rootChild(door) orelse return null;
        const levels = part.object.levels;
        if (part.object.level >= levels.len) return null;
        const bounds = levels[part.object.level].mesh.bounds;
        var middle = (bounds[1] + bounds[0]) * @as(math.Vector, @splat(0.5));
        middle[0] += across;
        sum += model.frameAt(door, reliant.drawn).point(middle);
    }
    return sum * @as(math.Vector, @splat(0.5));
}

/// The hangar the player's ship launches in, as `init` shows it: made in the cutaway slot, passing
/// through everything, its hull and doors lit by its dim light alone (`hangar_light_mask`), and
/// laid over the tube so that the ship stands `in_tube` at one of its launch points
/// (`hangar_points`): the ship is placed at the point with the hangar at the origin, turned as the
/// Reliant is, or half a turn more for a gate of even number (`launch.attach`), the hangar moves by
/// the way from there to the tube, and the ship is placed at the point again, riding the retainer.
fn showHangar(ctx: aigeneric.Context, index: u16, gate: i16, in_tube: math.Vector, turn: math.Matrix) void {
    const world = ctx.world;
    const all = world.objects;
    const spawn = world.spawn orelse return;
    const hangar = create.createObject(all, spawn.tables, spawn.types, create.cutaway_slot, .reliant_hangar, 0, @splat(0), world.random) catch |err| {
        log.warn("the Reliant's hangar is left out: {s}", .{@errorName(err)});
        return;
    };
    const shown = &all.slots[hangar];
    shown.object.flags.no_collisions = true;
    if (shown.model) |*model| {
        for (model.parts[0..@min(lit_parts, model.parts.len)]) |*part| part.object.light_mask = hangar_light_mask;
    }
    const even = @mod(gate, 2) == 0;
    const entry = &all.slots[index].orders[0];
    entry.target.component = hangar_points[@intFromBool(even)];
    objects.setPosition(&shown.object, &shown.drawn, @splat(0));
    objects.setOrientation(&shown.object, &shown.drawn, if (even) math.turned(turn, .y, std.math.pi) else turn);
    launch.attach(all, index, hangar);
    const shift = in_tube - gameobj.vector(all.slots[index].object.root.next_position);
    objects.setPosition(&shown.object, &shown.drawn, shift);
    launch.attach(all, index, hangar);
    entry.target.component = gate;
}

/// `launch_reliant_run` (`0x0041B240`): the launch of the ship in slot `index` from the Reliant, a
/// step (`Step`) each time the wait the last set has passed:
///
/// 1. `start`: for the player's ship, the engine starts sounding with a shake, one of the three
///    cutaways is picked from the runtime's numbers (`Cutaway`), the bay's view taking the camera
///    at once, and the tube's upper door shows, playing its opening backwards.
/// 2. `lower`: the hangar's retainer lowers the player's ship, its clamps heard.
/// 3. `release`: the retainer rises again, and the ship rides its node no more.
/// 4. `open`: the tube's lower door opens. For the player's ship the cutaway shows, the hangar's
///    door opens too, heard, and with the aside cutaway the camera takes that view as the hangar
///    goes.
/// 5. `drop`: the ship drops (`motion.Motion.downward`), at full throttle; on the player's screen
///    the mission's date is typed out (`hud.Caption`).
/// 6. `clear`: out of the bay's view, the player's cutaway ends, and with the cutaway from below
///    the camera takes that view.
/// 7. `fall`, 8. `level`: after a while the ship flies ahead again, steering nothing and at no
///    throttle.
/// 9. `end`: for the player's ship, the date goes, the camera leaves the cutaway for view 0 in the
///    cockpit mode the options' setting picks, and the hangar goes; the ship passes through the
///    Reliant no more, and the launch ends (`launch.finish`).
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.launch;
    const now = ctx.clock.frame_start;
    if (state.due >= now) return;
    const player = index == all.player;
    switch (Step.of(state.step)) {
        .start => {
            moveOn(state, .start, now);
            if (!player) return;
            world.shake.* = start_shake;
            sound3d.playIn(world, null, null, index, sound3d.engineSound(slot.object.type), 0, .player_engines);
            world.player.cutaway = @enumFromInt(@as(i32, world.random.rand() % cutaways) + 1);
            if (world.player.cutaway == .bay) switchView(ctx, .launch_bay, index);
            if (tubeDoor(all, slot, door_step)) |door| {
                door.model.playNamed(door.part, open_track, 0, .swing, upper_door_speed);
                door.model.parts[door.part].hidden = false;
            }
        },
        .lower => {
            if (player) {
                playOnHangar(all, hangar_retainer, deploy_track, 0, retainer_speed);
                playSample(world, lowered_sample);
            }
            moveOn(state, .lower, now);
        },
        .release => {
            if (player) playOnHangar(all, hangar_retainer, deploy_track, keep_time, -retainer_speed);
            state.attached = false;
            moveOn(state, .release, now);
        },
        .open => {
            if (tubeDoor(all, slot, 0)) |door| door.model.playNamed(door.part, open_track, 0, null, door_speed);
            if (player) {
                world.player.showing = .launch;
                playOnHangar(all, hangar_door, open_track, 0, hangar_door_speed);
                playSample(world, opened_sample);
                if (world.player.cutaway == .aside) {
                    switchView(ctx, .launch_aside, all.player);
                    all.resetSlot(create.cutaway_slot, world.random);
                    world.player.showing = .everything;
                }
            }
            moveOn(state, .open, now);
        },
        .drop => {
            if (player) if (world.display) |display| display.caption.start(ctx.clock.game_ticks);
            slot.motion = .downward;
            slot.object.throttle = 1;
            moveOn(state, .drop, now);
        },
        .clear => {
            const in_bay = if (world.camera) |view| view.view == .launch_bay else false;
            if (player and !in_bay) {
                world.player.showing = .everything;
                all.resetSlot(create.cutaway_slot, world.random);
                if (world.player.cutaway == .below) switchView(ctx, .launch_below, index);
            }
            moveOn(state, .clear, now);
        },
        .fall => moveOn(state, .fall, now),
        .level => {
            slot.motion = .forward;
            slot.object.throttle = 0;
            slot.object.pitch_input = 0;
            slot.object.yaw_input = 0;
            slot.object.roll_input = 0;
            // The player's launch ends at the next update.
            if (player) state.step = Step.end.generic() else moveOn(state, .level, now);
        },
        .end => {
            if (player) {
                if (world.display) |display| display.caption.stop();
                if (world.camera) |view| {
                    view.cockpit_mode = view.setting.mode();
                    switch (view.view) {
                        .launch_bay, .launch_below, .launch_aside => _ = view.setView(.cockpit, index, false, true, ctx.clock.viewTime()),
                        else => {},
                    }
                }
                all.resetSlot(create.cutaway_slot, world.random);
                world.player.showing = .everything;
            }
            slot.object.passes_through[0] = .none;
            launch.finish(ctx, index);
        },
        _ => {},
    }
}

/// Moves on from step `from` to the next, which runs once `from`'s wait has passed from `now`.
fn moveOn(state: *launch.State, from: Step, now: i32) void {
    state.advance(@enumFromInt(@intFromEnum(from) + 1), now, wait(from));
}

/// A door of the tube the ship in `slot` launches through: part `step` on from its gate in its
/// carrier's model, where there is one.
fn tubeDoor(all: *create.Objects, slot: *const create.Slot, step: usize) ?struct { model: *objects.Model, part: usize } {
    const carrier = slot.orders[0].target.slot() orelse return null;
    if (carrier >= all.slots.len) return null;
    const model = if (all.slots[carrier].model) |*held| held else return null;
    const part = (std.math.cast(usize, slot.orders[0].target.component) orelse return null) + step;
    if (part >= model.parts.len) return null;
    return .{ .model = model, .part = part };
}

/// The time a track keeps as it is played again (`node_play_named` with a time below zero).
const keep_time: f32 = -1;

/// Plays `track` on the hangar's part `part` from `time` at `speed`, where the hangar stands in
/// the cutaway slot.
fn playOnHangar(all: *create.Objects, part: usize, track: []const u8, time: f32, speed: f32) void {
    const hangar = &all.slots[create.cutaway_slot];
    if (hangar.object.type != .reliant_hangar) return;
    const model = if (hangar.model) |*held| held else return;
    if (part < model.parts.len) model.playNamed(part, track, time, null, speed);
}

/// Plays standard sample `index` in the middle, once, where the world is heard.
fn playSample(world: gameobj.World, index: usize) void {
    const hearing = world.hearing orelse return;
    const bank = hearing.sound.stdsmp orelse return;
    _ = hearing.sound.play(bank, index, sample_volume, hog_snd.once, hog_snd.centre, hog_snd.own_pitch);
}

/// Switches the camera to one of the launch's views, `view`, of the object in slot `object`
/// (`camera.Camera.setLaunch`): the bay's beside the object on the side of its order's gate.
fn switchView(ctx: aigeneric.Context, view: camera.View, object: u16) void {
    const watching = ctx.world.camera orelse return;
    const all = ctx.world.objects;
    const seen = &all.slots[object];
    const gate = seen.orders[0].target.component;
    _ = watching.setLaunch(view, object, ctx.clock.viewTime(), .of(seen), .of(&all.slots[all.player]), @mod(gate, 2) == 0);
}

/// A Reliant's model for the tests: its twelve tube doors, the lower door of gate `g` 1000 along X
/// for each gate and the upper 500 above it, each part's level the square test mesh, whose middle
/// is its origin. Set it up where it stays, as its records point into it.
const TestReliant = struct {
    mesh: srapiext.Mesh,
    levels: [1]srapiext.Level,
    data: [2 * door_step]shp.PartData,
    loaded_parts: [2 * door_step]srofiles.LoadedPart,
    source: shp.Model,
    loaded: srofiles.Loaded,

    fn init(reliant: *TestReliant, gpa: std.mem.Allocator) !void {
        reliant.mesh = try @import("../../surrender/surrenderlib/srmesh.zig").testing.square(gpa);
        reliant.levels = .{.{ .mesh = &reliant.mesh, .until = std.math.inf(f32) }};
        reliant.data = @splat(objects.testing.part());
        for (&reliant.data, 0..) |*part, n| {
            part.part.parent = -1;
            const gate: f32 = @floatFromInt(n % door_step);
            part.part.position = .{ .x = 1000 * gate, .y = if (n < door_step) 0 else -500, .z = 0 };
        }
        reliant.loaded_parts = @splat(.{ .flags = .{}, .levels = &reliant.levels, .meshes = &.{} });
        reliant.source = .{ .header = std.mem.zeroes(shp.Header), .parts = &reliant.data, .trailing_bytes = 0 };
        reliant.loaded = .{ .parts = &reliant.loaded_parts };
    }

    fn deinit(reliant: *TestReliant, gpa: std.mem.Allocator) void {
        reliant.mesh.deinit(gpa);
    }

    fn fit(reliant: *const TestReliant, gpa: std.mem.Allocator, slot: *create.Slot) !void {
        var made: objects.Model = try .create(gpa, &reliant.source, &reliant.loaded, .{});
        for (0..made.parts.len) |index| gameobj.linkPart(&made, index);
        slot.model = made;
    }
};

/// Runs the launch of the ship in slot `index` on to its step `step`, moving the clock past each
/// wait, and returns the frame's tick it came to it at.
fn runTo(mission: *gameobj.testing.Mission, index: u16, step: Step) i32 {
    const ctx = mission.orders();
    const state = &mission.slot(index).state.launch;
    while (Step.of(state.step) != step) {
        mission.clock.frame_start = state.due + 1;
        aigeneric.objectOrders(ctx, index);
    }
    return mission.clock.frame_start;
}

test "a ship drops out of the Reliant's tube, step by step" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var reliant_model: TestReliant = undefined;
    try reliant_model.init(gpa);
    defer reliant_model.deinit(gpa);
    _ = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 10000 });
    try reliant_model.fit(gpa, mission.slot(reliant));
    const ship = try mission.add(.sabre, @splat(0));
    const slot = mission.slot(ship);
    slot.object.throttle = 1;
    const ctx = mission.orders();

    // Through gate 2 it stands between the gate's doors, 400 across to the right, turned as the
    // Reliant, riding its root, its throttle nothing.
    _ = try aigeneric.pushShip(ctx, ship, .launch, reliant, 2);
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(math.Vector{ 2400, -250, 10000 }, slot.drawn.position);
    try std.testing.expectEqual(objects.NodeOf{ .object = reliant }, slot.riding.?);
    try std.testing.expectEqual(0, slot.object.throttle);
    // Through gate 3, 400 to the left.
    try std.testing.expectEqual(math.Vector{ 2600, -250, 10000 }, tube(mission.slot(reliant), 3).?);

    // Started, it waits a moment, then each step waits for the last.
    launch.start(mission.objects, ship);
    aigeneric.objectOrders(ctx, ship);
    const state = &slot.state.launch;
    var at = runTo(&mission, ship, .lower);
    try std.testing.expectEqual(at + wait(.start), state.due);
    at = runTo(&mission, ship, .open);
    try std.testing.expect(!state.attached);
    at = runTo(&mission, ship, .clear);
    // It drops at full throttle.
    try std.testing.expectEqual(.downward, slot.motion.?);
    try std.testing.expectEqual(1, slot.object.throttle);
    at = runTo(&mission, ship, .end);
    // Then it flies ahead again, steering nothing, at no throttle.
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expectEqual(at + wait(.level), state.due);
    // At last its launch ends: it passes through the Reliant no more and can be targeted.
    mission.clock.frame_start = state.due + 1;
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(null, slot.object.passes_through[0].index());
}

test "the player's launch shows the hangar and the cutaways, and ends in view 0" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var reliant_model: TestReliant = undefined;
    try reliant_model.init(gpa);
    defer reliant_model.deinit(gpa);
    const player = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 10000 });
    try reliant_model.fit(gpa, mission.slot(reliant));
    var view: camera.Camera = .{ .setting = .chase };
    var display: @import("../hud.zig").State = .{};
    var ctx = mission.orders();
    ctx.world.camera = &view;
    ctx.world.display = &display;
    ctx.world.spawn = .{ .tables = &mission.tables, .types = create.testing.no_models };

    // The hangar stands in the cutaway slot, the Reliant is the ship the player launched from and
    // the cutaway leaves it out, and the camera is held in the cockpit.
    _ = try aigeneric.pushShip(ctx, player, .launch, reliant, 0);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(.reliant_hangar, mission.objects.slots[create.cutaway_slot].object.type);
    try std.testing.expect(mission.objects.slots[create.cutaway_slot].object.flags.no_collisions);
    try std.testing.expectEqual(reliant, mission.player.carrier.?);
    try std.testing.expectEqual(.launch, mission.player.showing);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expectEqual(.cockpit, view.cockpit_mode);
    try std.testing.expect(view.locked);
    // The gate stays the order's own once the hangar is laid over the tube.
    try std.testing.expectEqual(0, mission.slot(player).orders[0].target.component);

    launch.start(mission.objects, player);
    ctx.clock = &mission.clock;
    aigeneric.objectOrders(ctx, player);
    const state = &mission.slot(player).state.launch;
    while (Step.of(state.step) != .lower) {
        mission.clock.frame_start = state.due + 1;
        aigeneric.objectOrders(ctx, player);
    }
    // The engine starts with a shake, and a cutaway is picked: the bay's takes the camera at once.
    try std.testing.expectEqual(start_shake, mission.shake);
    try std.testing.expect(mission.player.cutaway != .none);
    if (mission.player.cutaway == .bay) try std.testing.expectEqual(camera.View.launch_bay, view.view);
    while (Step.of(state.step) != .clear) {
        mission.clock.frame_start = state.due + 1;
        aigeneric.objectOrders(ctx, player);
    }
    // As the ship drops, the date is typed out.
    try std.testing.expect(display.caption.on);
    while (mission.slot(player).object.order_count > 0) {
        mission.clock.frame_start = state.due + 1;
        aigeneric.objectOrders(ctx, player);
    }
    // At the end the date goes, the hangar goes, everything shows, and the camera is free in view 0
    // in the mode the setting picks.
    try std.testing.expect(!display.caption.on);
    try std.testing.expectEqual(.stand_in, mission.objects.slots[create.cutaway_slot].object.type);
    try std.testing.expectEqual(.everything, mission.player.showing);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expectEqual(.chase, view.cockpit_mode);
    try std.testing.expect(!view.locked);
}
