//! `C:\lancer\game\main.cpp`: a mission's loop. `mission_run` (`0x00494040`) runs a game tick for
//! each tick of the timer and draws a frame with `mission_frame` (`0x004924B0`). **Unverified:**
//! the two lie after `language.cpp`'s code, where `main.cpp`'s begins; by what they do they are
//! this file's.
//!
//! Ported so far: the clocks and the pacing, the mission's start (`startMission`), how
//! `mission_frame` runs the mission's script, frames the objects, reads the controls, moves the
//! camera, plays the frame's sound and puts the scene together and draws it, the damaged ships'
//! smoke (`smoke`), the armour's conditions (`0x00492370`), the pause (`game_pause`) and the paused
//! frame (`pausedFrame`). Not yet: the rest of the effects and of what it adds to the scene.

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../input.zig");
const libcmt = @import("../libcmt.zig");
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const backdrop = @import("backdrop.zig");
const camera = @import("camera.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const guns = @import("guns.zig");
const launch = @import("launch.zig");
const cloak = @import("cloak.zig");
pub const lock = @import("main/lock.zig");
const missiles = @import("missiles.zig");
const explode = @import("explode.zig");
const particles = @import("particles.zig");
const shield = @import("shield.zig");
const erayfx = @import("erayfx.zig");
const tractor = @import("tractor.zig");
const airipper = @import("airipper.zig");
pub const flash = @import("main/flash.zig");
pub const cockpit = @import("main/cockpit.zig");
const shockwave = @import("shockwave.zig");
const sparks = @import("sparks.zig");
const bigfile = @import("bigfile.zig");
const hog_snd = @import("hog_snd.zig");
const betty = hog_snd.betty;
const hud = @import("hud.zig");
const hudoptions = @import("hudoptions.zig");
const sound3d = @import("sound3d.zig");
const matmanager = @import("matmanager.zig");
const nebula = @import("nebula.zig");
const objects = @import("objects.zig");
const srofiles = @import("srofiles.zig");
const xtrabits = @import("xtrabits.zig");
const winmain = @import("winmain.zig");
const Loaded = @import("mission.zig").Loaded;

pub const smoke = @import("main/smoke.zig");

// --- The clocks and the loop ---------------------------------------------------------------

/// The play time `tick_timer` keeps (`play_time_ticks` to `play_time_hours`, `0x00565070` to
/// `0x00565076`). A second takes 101 ticks, as the roll below has it, so the play time runs a
/// hundredth slow.
pub const PlayTime = struct {
    ticks: u16 = 0,
    seconds: u16 = 0,
    minutes: u16 = 0,
    hours: u16 = 0,
};

/// How the mission is ending (`0x00588394`), which its end and the debriefing go by. Nothing ends a
/// mission while it is `playing`. An ejection is `ejecting` until the pilot's pod has drifted its
/// time (`order_eject`, `0x00415C50`), when the mission's odds (`SetRescueProbabilities`; by
/// default always picked up) settle it: the pilot killed, which counts as `destroyed`, picked up by
/// a nanny ship, or picked up by the enemy. The other endings are not known yet.
pub const Ending = enum(u8) {
    playing = 0,
    /// The player's ship destroyed, or the ejected pilot killed.
    destroyed = 1,
    /// The ejected pilot picked up by a nanny ship (type `0x18`).
    rescued = 2,
    /// The ejected pilot picked up by the enemy (type `0x46`).
    captured = 3,
    ejecting = 8,
    _,
};

/// What the mission's scene shows (`0x00587CD4`), which a mission's start sets to `everything`.
pub const Showing = enum(u8) {
    everything = 0,
    /// A launch's cutaway (`launch.reliant`), which leaves out the ship the player launches from
    /// (`input.Player.carrier`), its bay seen from within.
    launch = 2,
    /// **Unknown:** what it shows. The landing orders set it (`0x0040EF55`, `0x0040F9A7`), and
    /// `mission_frame` passes over the mission's events and `0x0045A570` while it is so.
    _unknown_3 = 3,
    /// The end of the player's ejection (`aieject.pickUp`): only the pilot's pod and the ship in
    /// the cutaway slot, which picks it up or shoots it down. The pod bursts at once when it is
    /// destroyed, with neither the camera's watch nor the pilot counted killed on the way.
    ejection = 4,
    _,
};

/// What the mission's scene shows, as the player's state has it: `Showing`, and the ship the
/// player launched from, which a launch's cutaway leaves out.
pub const Shown = struct {
    showing: Showing = .everything,
    carrier: ?u16 = null,

    pub fn of(player: *const input.Player) Shown {
        return .{ .showing = player.showing, .carrier = player.carrier };
    }

    /// Whether the scene leaves out the object in slot `index` of `all` (`mission_frame`,
    /// `0x00492CEF`): a launch's cutaway the ship the player launches from, and the end of the
    /// player's ejection all but the player's pod and the cutaway slot's ship.
    pub fn leavesOut(shown: Shown, all: *const create.Objects, index: u16) bool {
        return switch (shown.showing) {
            .launch => index == shown.carrier,
            .ejection => index != all.player and index != create.cutaway_slot,
            else => false,
        };
    }
};

/// The game's ticks a second: `tick_timer` (`0x004827C0`) runs every hundredth of a second.
pub const ticks_per_second = 100;

/// A mission's clocks, and the pacing they drive: the timer ticks 100 times a second, the loop
/// runs one game tick for each tick of the timer, and the simulation steps on every fourth.
///
/// **Improvement:** OpenReliant has no periodic timer. The platform's monotonic counter of
/// hundredths of a second stands in for the multimedia timer `timer_start` (`0x004A70F0`) sets up,
/// so the clocks advance at the same rate without a thread of their own and without the drift a
/// timer whose period the device rounds would bring.
pub const Clock = struct {
    /// `timer_ticks` (`0x005DB8E8`): every tick of the timer, the paused ones included.
    timer_ticks: u32 = 0,
    /// `game_ticks` (`0x00565064`): ticks since the mission started, the paused ones aside.
    game_ticks: u32 = 0,
    /// `mission_ticks` (`0x00587CC4`): ticks `game_tick` has run, the paused ones aside.
    mission_ticks: i32 = 0,
    /// `paused_ticks` (`0x00587CB0`): ticks `game_tick` skipped while the game was paused.
    paused_ticks: u32 = 0,
    play: PlayTime = .{},
    /// `paused` (`0x0057E04C`), which stops the ticks and the script clock.
    paused: bool = false,
    /// `frame_start` (`0x005883B0`): `mission_ticks` when the current frame began.
    frame_start: i32 = 0,
    /// `frame_duration` (`0x00588330`): ticks between the previous frame and this one.
    frame_duration: i32 = 0,
    /// `simulation_counter` (`0x00588718`).
    simulation_counter: u32 = 0,
    /// `simulation_turn` (`0x00562FFC`): the object whose orientation `simulation_step`
    /// orthonormalizes this step (`nextTurn`).
    simulation_turn: u32 = 0,
    /// What the loop has already run game ticks for, which `mission_run` keeps to itself.
    ran_to: u32 = 0,
    /// Where the platform's count of hundredths stood at the last tick, in place of the timer.
    timer_at: u64 = 0,
    /// OpenReliant's: how far the platform's time has run past the last tick, as a share of a tick,
    /// which `stepFraction` draws between the ticks by.
    past_tick: f32 = 0,

    /// The mission's ticks as a count, none before it starts, which the camera times its views by
    /// (`camera.Camera.switched`).
    pub fn viewTime(clock: *const Clock) u32 {
        return @intCast(@max(clock.mission_ticks, 0));
    }

    /// Zeroes the clocks and takes the platform's count of hundredths of a second as their start,
    /// as `mission_run` zeroes them before it loops.
    pub fn start(clock: *Clock, now: u64) void {
        clock.* = .{ .timer_at = now };
    }

    /// Runs the timer on to `now`, the platform's count of hundredths of a second. The ticks come
    /// from the difference between two counts, never from the length of a frame, so a frame that
    /// falls between two ticks loses nothing, a frame that spans several runs all of them, and the
    /// clocks keep to the platform's count however the frames fall.
    pub fn advanceTo(clock: *Clock, now: u64) void {
        const elapsed = now -% clock.timer_at;
        clock.timer_at = now;
        clock.advanceTimer(@truncate(elapsed));
    }

    /// `advanceTo`, from a finer count: the platform's time in units of which `per_tick` make a
    /// tick. What is left past the last tick is kept for drawing between the ticks.
    pub fn advanceToFine(clock: *Clock, now: u64, per_tick: u64) void {
        clock.advanceTo(now / per_tick);
        clock.past_tick = @as(f32, @floatFromInt(now % per_tick)) / @as(f32, @floatFromInt(per_tick));
    }

    /// Runs `ticks` ticks and takes `now` as where the platform's count has reached, for a
    /// screenshot, which takes a tick a frame so that every run settles alike.
    pub fn advanceBy(clock: *Clock, now: u64, ticks: u32) void {
        clock.timer_at = now;
        clock.past_tick = 0;
        clock.advanceTimer(ticks);
    }

    /// Runs the timer on for `ticks` hundredths of a second.
    pub fn advanceTimer(clock: *Clock, ticks: u32) void {
        for (0..ticks) |_| hog_snd.tickTimer(clock);
    }

    /// Runs the next game tick the loop owes, as `mission_run` (`0x00494040`) paces them: one for
    /// each tick of the timer since the last pass. Returns whether the simulation stepped, or null
    /// once the loop has caught up with the timer.
    pub fn nextTick(clock: *Clock, devices: *input.Devices, world: gameobj.World) ?bool {
        if (clock.ran_to == clock.game_ticks) return null;
        clock.ran_to +%= 1;
        return gameobj.gameTick(clock, devices, world);
    }

    /// Every tick the loop owes. Returns how many simulation steps ran.
    pub fn runTicks(clock: *Clock, devices: *input.Devices, world: gameobj.World) u32 {
        var steps: u32 = 0;
        while (clock.nextTick(devices, world)) |stepped| {
            if (stepped) steps += 1;
        }
        return steps;
    }

    /// `frame_begin` (`0x00491E00`): `frame_duration` becomes the ticks since `frame_start`, and
    /// `frame_start` becomes `mission_ticks`. Code that runs once a frame measures time with these.
    pub fn frameBegin(clock: *Clock) void {
        const began = clock.frame_start;
        clock.frame_start = clock.mission_ticks;
        clock.frame_duration = clock.mission_ticks -% began;
    }

    /// `frame_reset` (`0x00491DE0`).
    pub fn frameReset(clock: *Clock) void {
        clock.frame_start = clock.mission_ticks;
        clock.frame_duration = 0;
    }

    /// The ticks the current frame covers (`frame_duration`), none where the clock ran back.
    pub fn frameTicks(clock: *const Clock) u32 {
        return @intCast(@max(clock.frame_duration, 0));
    }
};

/// What `mission_frame` draws a frame of.
pub const Frame = struct {
    /// The live objects, each drawn by its model's nodes.
    objects: *create.Objects,
    /// The object the camera sits in (`camera.Camera.inside`), which is not drawn but still casts
    /// its shadow.
    seat: ?u16 = null,
    /// What the mission's scene shows.
    shown: Shown = .{},
    space: *backdrop.Backdrop,
    sky: *nebula.Sky,
    view: camera.View,
    cockpit_mode: camera.CockpitMode,
    /// Whether the player's ship jumps in, which cuts the dust's streaks shorter
    /// (`input.Player.jumping_in`).
    jumping_in: bool = false,
    /// Last frame's view (`camera_view_last`, `0x00539A64`).
    last_view: camera.View,
    /// Whether the camera has switched view since the last frame drawn (`camera.Camera.cut`).
    cut: bool = false,
    /// What the models' own lights and engine glows are drawn by; each object's own offset into
    /// its lights' blinks and its glow come from its record.
    attachments: objects.View = .{},
    /// What is drawn over the scene once its layers are done, which is the head-up display.
    overlay: ?srcore.Overlay = null,
    /// The cockpit's model and the radar's backing, which view 0 draws over the world in cockpit
    /// mode 1 under the hardware renderers.
    cockpit: ?*objects.Model = null,
    backing: ?*RadarBacking = null,
    /// Whether DISPLAY KILLS is held, which leaves the backing out.
    kills_shown: bool = false,
    /// The sparks and the particles, the smoke's among them, which go into the world's layer
    /// after the shots, the explosions' bits, pieces and fireballs, and the shockwaves.
    sparks: ?*sparks.Sparks = null,
    particles: ?*particles.Pool = null,
    smoke: ?*smoke.Pools = null,
    gun_particles: ?*guns.effects.Pools = null,
    /// How far past the frame's tick the effects are drawn, as a share of a tick
    /// (`objects.pastTick`).
    ahead: f32 = 0,
    explosions: ?*explode.Explosions = null,
    shockwaves: ?*shockwave.Shockwaves = null,
    trails: ?*missiles.trail.Trails = null,
    countermeasures: ?*cloak.Countermeasures = null,
    /// The player's missile lock and its rings, which go into the overlay's layer while it builds,
    /// from the cockpit's views and the chase view.
    lock: ?*const lock.Lock = null,
    lock_rings: ?*lock.Rings = null,
    /// The chase view's objects, and the display whose reticle, pointer and lead point they
    /// follow.
    chase: ?*hud.chase.Chase = null,
    display: ?*const hud.State = null,
    /// The shields' bubbles, which go into the world's layer after the objects.
    shields: ?*shield.Shields = null,
    /// The electric rays, which go into the world's layer after the explosions.
    rays: ?*erayfx.Rays = null,
    /// The tractors, which go into the world's layer after the objects.
    tractors: ?*tractor.Tractors = null,
    /// The Rippers' beams, which go into the world's layer after the objects.
    rippers: ?*airipper.Rippers = null,
    /// The screen's flash, which goes into the overlay's layer, and the ticks the frame spans
    /// (`frame_duration`), which it counts down.
    flash: ?*flash.Flash = null,
    ticks: i32 = 0,
    /// The display's interference, which the flash shows red in the view ahead and then fades.
    interference: ?*hud.Interference = null,
    /// Whether the game is paused, which holds the bubbles' colours still.
    paused: bool = false,
};

/// What `game_pause` pauses and resumes: the clocks, the voices, and the menu that stands in the
/// display's place while paused.
pub const Pausing = struct {
    gpa: Allocator,
    clock: *Clock,
    sound: *hog_snd.Sound,
    menu: *hudoptions.PauseMenu,
    /// The archive the menu's fonts come from.
    archive: bigfile.Hog,
    /// The camera, which resuming switches to view 0, following the player's ship's slot, when its
    /// cockpit setting (`camera.Camera.setting`) changed while paused.
    camera: *camera.Camera,
    player: *const u16,
};

/// `game_pause` (`0x00491E20`): pauses or resumes the mission. Pausing, where it isn't paused yet,
/// sets `paused`, which stops the ticks and the script clock, pauses the 3D voices and the voices,
/// and opens the menu the display gives its place to. Resuming undoes it, and switches to view 0
/// if the cockpit setting changed in the meantime. The music plays on through the pause. Pausing
/// keeps the cockpit setting, even while already paused.
///
/// Not ported, as what they serve isn't: the chat line and the typed keys it empties, the speech
/// sample it stops, the frame timing it holds, the pause it sends the other players, the paused
/// frame's clock (`paused_clock`), the renderer's `sr + 0x78`, the window it restores, and
/// `0x005DD524`. The radar's backing, which it shows again, the sandbox leaves out while paused.
pub fn pause(pausing: Pausing, on: bool) !void {
    const clock = pausing.clock;
    const sound = pausing.sound;
    const menu = pausing.menu;
    if (on) {
        if (!clock.paused) {
            clock.paused = true;
            sound3d.pause(sound, true);
            sound.pauseAll();
            try menu.open(pausing.gpa, pausing.archive);
        }
        menu.view_setting = pausing.camera.setting;
        return;
    }
    if (clock.paused) {
        clock.paused = false;
        sound3d.pause(sound, false);
        sound.resumeAll();
        menu.close();
        if (menu.view_setting != pausing.camera.setting) {
            _ = pausing.camera.setView(.cockpit, pausing.player.*, false, true, clock.viewTime());
        }
    }
}

/// `mission_paused_frame` (`0x00491FC0`)'s work before the frame is drawn, each frame while the
/// game is paused: the keyboard and the joystick read, which lets go of the keys that are up, and
/// the frame's sounds played and placed, the music playing on (`hog_snd.Sound.frame`), heard from
/// `hearing` in `world`. OpenReliant's: the controller stops rumbling. The pause menu reads the
/// pointer as it is drawn over the scene as it stood (`menu_mouse_update`), and its choice ends the
/// pause once the frame is drawn.
///
/// Not ported: the paused clock (`paused_clock`), the radar's backing's flag, and a multiplayer
/// game's messages, its chat line and the players it drops.
pub fn pausedFrame(devices: *input.Devices, hearing: hog_snd.Hearing, world: gameobj.World) void {
    devices.read();
    if (hearing.sound.stdsmp) |bank| hearing.sound.frame(bank, hearing.scene(world));
    devices.joystick.rumble(.{});
}

/// What the frame's controls, its camera and its sound run with (`controlsFrame`).
pub const Controls = struct {
    /// The world, its clock, and the devices the controls read.
    orders: aigeneric.Context,
    devices: *input.Devices,
    camera: *camera.Camera,
    display: *hud.State,
    /// The scene as last drawn, which the targeting keys find the object under the reticle by, and
    /// the screen's size in pixels.
    sight: ?hud.Sight,
    screen: [2]u32,
    /// Last frame's view (`camera_view_last`).
    last_view: camera.View,
    /// The cockpit's model, where the player's ship has one, which the camera's frame moves.
    cockpit: ?*cockpit.Cockpit.Shown,
    forces: *input.force.Forces,
    random: *libcmt.Rand,
    /// Whether what moves is drawn between the game's ticks (`objects.pastTick`).
    smooth_motion: bool,
};

/// `mission_frame`'s work for the controls, the camera and the sound, once a frame over the ticks
/// it spans: `frame_controls` (the camera's keys, then the targeting keys, `hud.targetKeys`, then
/// its own, `input.frameKeys`); the camera's frame, of the view's own object, which the ejection's
/// views show, or else the player's ship, the cockpit's model moved by the ship's rates of turn
/// over its full ones and its speed over its cruise speed; the player's ship left undrawn from its
/// cockpit, as `camera_set_view` sees to; and the frame's sound, heard from where the camera now is:
/// the fades `tick_timer` steps, the music waiting its turn, the positional sounds gathered, and
/// the 3D sounds placed again. OpenReliant's: the effects playing turn the controller's motors
/// (`input.force`).
pub fn controlsFrame(controls: Controls) void {
    const world = controls.orders.world;
    const clock = controls.orders.clock;
    const all = world.objects;
    const view = controls.camera;
    const devices = controls.devices;
    const ticks = clock.frameTicks();
    const at = clock.viewTime();
    const slot = &all.slots[all.player];
    view.frameControls(devices, all.player, ticks, at);
    hud.targetKeys(controls.display, .{
        .devices = devices,
        .player = world.player,
        .all = all,
        .sight = controls.sight,
        .last_view = controls.last_view,
        .scale = hud.scaleFor(controls.screen),
        .multiplayer = false,
        .world = world,
    });
    input.frameKeys(.{
        .display = controls.display,
        .player = world.player,
        .devices = devices,
        .slot = slot,
        .view = view.view,
        .game_ticks = clock.game_ticks,
        .multiplayer = false,
        .world = world,
        .all = all,
    });
    const cockpit_input: ?camera.Cockpit.Input = if (controls.cockpit) |shown| moved: {
        const live = &slot.object;
        const flight = slot.flight orelse break :moved null;
        const rates: [3]f32 = .{
            live.pitch_rate / flight.pitch_rate,
            live.yaw_rate / flight.yaw_rate,
            live.roll_rate / flight.roll_rate,
        };
        const speed = live.speed / ai.cruiseSpeed(live, flight, view.view);
        break :moved cockpit.input(&shown.model, shown.source, rates, speed);
    } else null;
    const subject = camera.Subject.of(slot);
    const seen = if (view.object) |object| camera.Subject.of(&all.slots[object]) else subject;
    const marker = if (world.explosions) |explosions| if (explosions.marker) |left| left.position else null else null;
    if (view.frame(.{
        .object = seen,
        .player = subject,
        .ticks = ticks,
        .now = at,
        .ahead = objects.pastTick(clock, controls.smooth_motion),
        .marker = marker,
        .cockpit = cockpit_input,
        .random = controls.random,
        .forces = controls.forces,
        .dropping = launch.dropping(all, all.player),
        .showing = &world.player.showing,
        .game = world,
    })) |next| {
        _ = view.setView(next, all.player, false, true, at);
    }
    slot.object.flags.hidden = view.inside(all.player);
    if (world.hearing) |hearing| {
        hearing.sound.timerTick(clock.game_ticks);
        if (hearing.sound.stdsmp) |bank| hearing.sound.frame(bank, hearing.scene(world));
    }
    devices.joystick.rumble(controls.forces.motors(clock.frame_start));
}

/// `mission_frame` (`0x004924B0`), as far as the objects go: the player's ship pointed to the
/// flyback marker it has strayed from (`input.nextNavPoint`), then the player's ship uncloaked where
/// the display ran the cloak's charge dry last frame (`hud.State.uncloakSpent`), then every
/// object's orders, which fly the ships and read the player's controls, then the frames they are
/// drawn at, then the missiles (`missiles.frame`) and the shots in flight (`guns.bulletsFrame`),
/// then the sparks (`sparks.Sparks.frame`) and the particles (`particles.Pool.frame`,
/// `smoke.Pools.frame`, `guns.effects.Pools.frame`), which `particles_frame` runs together, the
/// damaged ships' smoke (`smoke.frame`), the explosions (`explode.Explosions.frame`), the
/// countermeasures (`cloak.Countermeasures.frame`) and the shockwaves
/// (`shockwave.Shockwaves.frame`). Between them the frame's hits on the player's ship push its
/// controller (`input.force.Forces.pushFrame`). A mission and the sandbox alike run this once a
/// frame, before the camera's own frame and anything drawn.
///
/// Before the orders, in a frame that runs ticks while the mission plays on and its scene isn't
/// the landing's, the mission (`loaded`) raises the events waiting (`mission.Loaded.flush`) and its
/// script runs its frame's work (`mission.Loaded.process`), its clock ticking first for the
/// seconds past (`mission.Loaded.tickClock`).
///
/// Whether the mission is over: as the camera has it (`missionOver`), which sets the script's
/// `mission_over`, or as the script has it, which ends the mission before the frame's work.
pub fn missionFrame(orders: aigeneric.Context, timing: objects.Timing, loaded: ?*Loaded) bool {
    input.nextNavPoint(orders.world);
    const over = missionOver(orders.world);
    const player = orders.world.player;
    if (loaded) |playing| {
        const variables = &playing.script.variables;
        if (over) variables.mission_over = 1;
        if (variables.mission_over != 0) return true;
        if (orders.clock.frame_duration != 0 and player.ending == .playing and player.showing != ._unknown_3) {
            playing.tickClock(orders.clock.game_ticks);
            playing.flush(orders);
            playing.process(orders);
        }
    }
    if (orders.world.display) |display| display.uncloakSpent(orders.world);
    aigeneric.ordersUpdate(orders);
    frameObjects(orders.world.objects, timing, orders.clock.frame_start);
    missiles.frame(orders.world, timing.fraction);
    guns.bulletsFrame(orders.world, orders.clock, timing.fraction);
    if (orders.world.sparks) |thrown| thrown.frame(orders.clock);
    if (orders.world.particles) |pool| pool.frame(orders.clock);
    if (orders.world.smoke) |pools| pools.frame(orders.clock);
    if (orders.world.gun_particles) |pools| pools.frame(orders.clock);
    smoke.frame(orders.world);
    objectsPass(orders);
    followCarrier(orders.world);
    if (orders.world.forces) |forces| forces.pushFrame(orders.clock.frame_start);
    orders.world.objects.exhaust.burn(orders.world);
    if (orders.world.explosions) |explosions| explosions.frame(orders.world);
    if (orders.world.countermeasures) |dropped| dropped.frame(orders.world);
    if (orders.world.shockwaves) |waves| waves.frame(orders.world);
    if (orders.world.display) |display| {
        if (orders.world.view.showsLock()) display.lock.frame(orders.world, &display.missiles);
    }
    return over;
}

/// `mission_frame`'s care of the ship the player launched from (`0x004932D4`): once that ship
/// explodes, the first Yamato among the objects takes its place, where there is one.
pub fn followCarrier(world: gameobj.World) void {
    const all = world.objects;
    const carrier = world.player.carrier orelse return;
    if (carrier >= all.slots.len or !all.slots[carrier].object.flags.exploding) return;
    for (all.slots[0..all.count], 0..) |*slot, index| {
        if (slot.object.type != .yamato) continue;
        world.player.carrier = @intCast(index);
        return;
    }
}

test followCarrier {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, @splat(0));
    const yamato = try mission.add(.yamato, @splat(0));
    mission.player.carrier = reliant;
    // While the Reliant holds, it stays the ship the player launched from.
    followCarrier(mission.world());
    try std.testing.expectEqual(reliant, mission.player.carrier.?);
    // Once it explodes, the Yamato takes its place.
    mission.slot(reliant).object.flags.exploding = true;
    followCarrier(mission.world());
    try std.testing.expectEqual(yamato, mission.player.carrier.?);
}

/// How long the camera watches the player's ship's end, the pilot's pod picked up, and the pod
/// shot down once it bursts, before the mission is over, in ticks (`0x0049267E`, `0x0049268D`,
/// `0x004926AD`).
const end_watched = 600;
const pickup_watched = 1200;
const shot_watched = 500;

/// `mission_frame`'s end of the mission by what the camera watches (`0x00492651`): once the
/// player's ship's end, the pod's pickup or the pod shot down has been watched its time, the
/// mission is over. Watching the pod shot down, the time counts from when it bursts.
///
/// Not ported: a multiplayer game, where the camera goes on to watch another player.
pub fn missionOver(world: gameobj.World) bool {
    const watching = world.camera orelse return false;
    const now = world.clock.viewTime();
    const watched: u32 = switch (watching.view) {
        .pull_back, .watch, .watch_marker => end_watched,
        .pickup => pickup_watched,
        .pod_shot => watched: {
            if (world.objects.slots[world.objects.player].object.flags.exploding) break :watched shot_watched;
            watching.switched = now;
            return false;
        },
        else => return false,
    };
    return now > watching.switched + watched;
}

/// `mission_frame`'s pass that draws the objects, beyond drawing them: over each object drawn
/// this frame, whether one fights the player with its missile ready, which lights the display's
/// enemy lock, what its destroyed components leave (`objects.loseComponents`, which `object_draw`
/// runs), and each one's avoidance lists (`avoidanceScan`). The damaged ships' smoke is
/// `smoke.frame`'s.
fn objectsPass(orders: aigeneric.Context) void {
    const world = orders.world;
    const all = world.objects;
    var enemy_lock = false;
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        if (slot.object.flags.outOfFrame()) continue;
        if (slot.object.order_count > 0) {
            const order = slot.orders[0];
            if (order.order == .fight and order.target.slot() == all.player and slot.state.fight.missile_ready) enemy_lock = true;
        }
        objects.loseComponents(orders, index);
        avoidanceScan(world, index);
    }
    if (world.display) |display| display.enemy_lock = enemy_lock;
}

/// How much wider than the two objects' spheres an object that lists components is watched for
/// (`0x004DC43C`), and how far ahead, in steps, and how near, the others are
/// (`ai.collisionCourse`).
const avoid_widening: f32 = 10000;
const avoid_steps: f32 = 50;
const avoid_margin: f32 = 2000;

/// `avoidance_scan` (`0x00492190`): for a ship whose current order avoids
/// (`orders.Flags.avoidance`) and that has no `no_avoidance`, the objects it could hit, for the
/// avoidance code (`ai.avoidNear`, `ai.avoidAhead`), up to ten of each: those that list components
/// whose spheres, 10000 wider, overlap its own where the step takes them both; and, where the ship
/// lists none itself, the rest it is on course to hit within 50 steps by 2000. It passes over
/// stand-ins, disabled and jumping objects, planets, the ship itself, what it fights, and what
/// either passes through the other.
///
/// Not ported: in a multiplayer game, the other players' ships a ship passes by.
fn avoidanceScan(world: gameobj.World, index: u16) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const ship = &slot.object;
    if (ship.flags.no_avoidance or ship.order_count == 0) return;
    const info = ai.orders.info(slot.orders[0].order) orelse return;
    if (!info.flags.avoidance) return;
    ship.avoid_near.count = 0;
    ship.avoid_ahead.count = 0;
    for (all.slots[0..all.count], 0..) |*other_slot, other_index| {
        const other: u16 = @intCast(other_index);
        const object = &other_slot.object;
        if (object.flags.outOfFrame() or other == index) continue;
        if (other_slot.combat) |combat| if (combat.class == .planet) continue;
        if (ship.passes_through[0].index() == other or ship.fighting.index() == other) continue;
        if (object.passes_through[0].index() == index) continue;
        if (object.flags.components) {
            if (ship.overlaps(object, avoid_widening)) ship.avoid_near.add(other);
        } else if (!ship.flags.components and ai.collisionCourse(world, index, other, avoid_steps, avoid_margin)) {
            ship.avoid_ahead.add(other);
        }
    }
}

/// `mission_frame`'s pass over the objects before the camera's frame: each live object, save
/// stand-ins and disabled and jumping ones, has `missile_homing` cleared, stands on the node it
/// rides where it is launching (`launch.hold`), and is framed as far through the simulation's step
/// as `timing` says (`objects.frameTree`), one the orders placed going on by its glide for the time
/// past the tick, which the orders set afresh each frame; a cloaked one's frame then wobbles as its
/// cloak changes, by the frame's tick `now` (`cloak.wobble`).
pub fn frameObjects(all: *create.Objects, timing: objects.Timing, now: i32) void {
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.flags.outOfFrame()) continue;
        object.missile_homing = 0;
        // Gliding, or the frame after, it is drawn from where the orders placed it.
        const gliding = @reduce(.Or, slot.glide != @as(math.Vector, @splat(0)));
        const glide: ?math.Vector = if (gliding or slot.glided) slot.glide * @as(math.Vector, @splat(timing.ahead)) else null;
        slot.glided = gliding;
        slot.glide = @splat(0);
        launch.hold(all, index);
        objects.frameTree(&object.root, if (slot.model) |*model| model else null, &slot.drawn, timing.fraction, glide);
        cloak.wobble(slot, now);
    }
}

/// Puts the frame's scene together and draws it, in `mission_frame`'s order: the objects
/// (`drawObjects`), the backdrop, the sky; the star streaks are reset when the view has changed
/// since the last frame, or the camera has switched view (`camera_set_view`); then `sr_render`. `arena` holds what the frame needs until it is drawn.
pub fn drawFrame(gpa: Allocator, arena: Allocator, scene: *srcore.Scene, context: *srapi.Context, frame: Frame, driver: srcore.Driver) Allocator.Error!void {
    scene.clear();
    // How far off an object stops being worth drawing follows the frame's own projection, so the
    // caller does not have to hand it over with the rest.
    var attachments = frame.attachments;
    attachments.scale = context.projection.scale[0];
    attachments.hardware = context.hardware;
    attachments.paused = frame.paused;
    try drawObjects(gpa, scene, frame.objects, attachments, frame.seat, if (frame.explosions) |explosions| &explosions.splits else null, frame.shown);
    if (frame.tractors) |tractors| try tractors.draw(gpa, scene, frame.objects);
    if (frame.rippers) |rippers| try rippers.draw(gpa, scene, frame.objects);
    try missiles.draw(frame.objects, gpa, scene, attachments);
    if (frame.trails) |trails| try trails.draw(gpa, scene);
    if (frame.countermeasures) |dropped| try dropped.draw(gpa, scene, attachments);
    if (frame.lock_rings) |rings| if (frame.lock) |held| if (frame.view.showsLock()) {
        try rings.draw(gpa, scene, held, .{ .position = context.camera.position, .orientation = context.camera.orientation }, context.projection);
    };
    if (frame.chase) |seen_behind| if (frame.display) |display| if (frame.view == .cockpit and frame.cockpit_mode == .chase) {
        const ship = &frame.objects.slots[frame.objects.player];
        const aim: ?math.Vector = if (ship.object.blind_fire_aim != 0) display.lead_point else null;
        try seen_behind.draw(gpa, scene, ship.drawn, display.reticle_bright, aim, display.chase_pointer, display.chase_nav_roll);
    };
    if (frame.shields) |bubbles| try bubbles.draw(gpa, arena, scene, frame.objects, .{
        .camera = attachments.camera,
        .inside = camera.inCockpit(frame.view, frame.cockpit_mode),
        .frame_start = attachments.frame_start,
        .ahead = frame.ahead,
        .paused = frame.paused,
        .random = attachments.random,
    });
    try guns.drawBullets(gpa, scene, &frame.objects.bullets, context.hardware);
    if (frame.sparks) |thrown| try thrown.draw(gpa, scene, frame.ahead);
    if (frame.particles) |pool| try pool.draw(gpa, scene, frame.ahead);
    if (frame.smoke) |pools| try pools.draw(gpa, scene, frame.ahead);
    if (frame.gun_particles) |pools| try pools.draw(gpa, scene, frame.ahead);
    if (frame.explosions) |explosions| try explosions.draw(gpa, scene, frame.ahead);
    if (frame.rays) |rays| if (attachments.random) |random| try rays.draw(gpa, scene, frame.objects, attachments.frame_start, random);
    if (frame.flash) |lit| if (!frame.paused) {
        const shaken = frame.interference;
        // In a capital ship's exhaust the flash is white alone (`exhaust_burning`).
        const red = if (shaken != null and frame.view == .cockpit and !frame.objects.exhaust.burning) shaken.?.level else 0;
        try lit.draw(gpa, scene, .{ .position = context.camera.position, .orientation = context.camera.orientation }, context.projection, frame.ticks, red);
        if (shaken) |interference| interference.fade(attachments.frame_start);
    };
    if (frame.shockwaves) |waves| try waves.draw(gpa, scene, frame.ahead);
    frame.space.shortenDust(frame.jumping_in);
    try frame.space.frame(gpa, scene, context, frame.view, frame.cockpit_mode);
    if (context.hardware) try frame.sky.frame(gpa, scene, context);
    if (frame.view == .cockpit and frame.cockpit_mode == .cockpit and context.hardware) {
        // The backing, then the hands, then the cockpit, all over the world, sorted by depth.
        if (frame.backing) |backing| if (!frame.kills_shown) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &backing.object }, .overlay);
        if (frame.cockpit) |model| {
            for ([_]usize{ cockpit.hands, cockpit.frame }) |index| {
                if (index < model.parts.len) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &model.parts[index].object }, .overlay);
            }
        }
    }
    if (frame.view != frame.last_view or frame.cut) frame.space.resetStreaks();
    try srcore.render(arena, context, scene, driver, frame.overlay);
}

/// Where `mission_frame` holds `detail_divisor` (`srapi.Context.detail`) at the high detail setting
/// on a machine that keeps up: it raises it by 0.05 each frame whose timed sections take under 1/60
/// s, up to 3, and lowers it by 0.5 each frame over 1/40 s, down to 1.5. OpenReliant holds it at
/// the top.
pub const high_detail: f32 = 3;

/// How far the finer levels of detail reach (`srapi.Context.finer`).
pub const DetailReach = enum {
    /// **Improvement:** eight times as far as the original has them, so that a ship keeps its
    /// finest mesh until it is far off and no level change shows up close; its last level still
    /// ends, and the ship leaves sight, where the original's does.
    far,
    /// As far as the original has them.
    original,

    pub fn finer(reach: DetailReach) f32 {
        return switch (reach) {
            .far => 8,
            .original => 1,
        };
    }
};

/// How much a frame may draw (`srapi.Context.budget`).
pub const DrawBudget = enum {
    /// **Improvement:** ten times the original's, 200000 vertices and as many polygons, which
    /// a current computer draws with ease. OpenReliant keeps up to 4000 burning bits where the
    /// original keeps 500 (`explode.BitPool`), and a view full of them and of a split's bodies
    /// takes the original's budget; since the layers are drawn from what went in last, the bits
    /// then crowd out the ships' parts, which vanish while the view is full.
    roomy,
    /// The original's, 19999 of each (`srapi.original_budget`).
    original,

    pub fn limit(budget: DrawBudget) usize {
        return switch (budget) {
            .roomy => 200_000,
            .original => srapi.original_budget,
        };
    }
};

/// `mission_frame`'s pass that draws the objects: each live object, save stand-ins and disabled
/// and jumping ones, has its cloak's frame run where it has one (`cloak.frame`), and is drawn with
/// `object_draw` (`objects.Model.draw`), with its own offset into its lights' blinks, its lights
/// unless `lights_disabled`, its engine glows burning by the throttle of its last update times the
/// share of its engines left, but none while it is among `splits`, and nothing at all while it is
/// `hidden`, as the ship the camera sits in is. That ship, `seat`, still casts its shadow
/// (`objects.Model.castShadows`), cloaked as its hull stands (`cloak.shadeUnseen`). A cloaked
/// object is drawn with neither lights nor glows, its parts as its cloak draws them
/// (`cloak.Drawing`).
///
/// Not ported yet: what else the pass draws for a few types, the protogate's power core
/// pulsing, the Boridin breakaway's core and the Dark Reign's hat
/// ([#238](https://github.com/vdmkenny/openreliant/issues/238)); the cutaway scenes' own rules, and
/// the gate's tunnel, in which no object is drawn. The pass's smoke is `smoke.frame`.
pub fn drawObjects(gpa: Allocator, scene: *srcore.Scene, all: *create.Objects, attachments: objects.View, seat: ?u16, splits: ?*const explode.split.Splits, shown: Shown) Allocator.Error!void {
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.flags.outOfFrame()) continue;
        cloak.frame(slot, attachments.frame_start);
        const model = if (slot.model) |*model| model else continue;
        if (object.flags.hidden or shown.leavesOut(all, index)) {
            if (index == seat) {
                if (slot.cloak) |cloaking| cloak.shadeUnseen(model, cloaking.hull);
                try model.castShadows(gpa, scene);
            }
            continue;
        }
        var view = attachments;
        view.blink_offset = object.blink_offset;
        view.lights = !object.flags.lights_disabled;
        view.throttle = object.last_throttle * object.engines_intact;
        if (splits) |under_way| view.glows = !under_way.splitting(index);
        // A cloaked object's lights and engine glows are out, and its cloak draws its parts.
        if (slot.cloak) |*cloaking| {
            view.lights = false;
            view.glows = false;
            view.cloak = .{ .cloak = cloaking, .kafelnikof = object.type == .kafelnikof };
        }
        try model.draw(gpa, scene, .world, view);
    }
}

test "the objects are framed and drawn, save those left out" {
    const gpa = std.testing.allocator;
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(gpa, &random);
    defer all.destroy();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    var tables = create.testing.tables();
    for (0..4) |place| {
        const at: math.Vector = .{ @floatFromInt(place * 100), 0, 0 };
        _ = try create.createObject(all, &tables, model.types(), null, .predator, 0, at, &random);
    }
    // The first is the ship the camera sits in, the second is disabled and the third jumping.
    all.slots[0].object.flags.hidden = true;
    all.slots[1].object.flags.disabled = true;
    all.slots[2].object.flags.jumping = true;
    all.slots[3].object.missile_homing = 1;
    frameObjects(all, .{}, 0);
    // Each framed one stands where it was made, and the pass clears the missile warning.
    try std.testing.expectEqual(math.Vector{ 300, 0, 0 }, all.slots[3].drawn.position);
    try std.testing.expectEqual(0, all.slots[3].object.missile_homing);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try drawObjects(gpa, &scene, all, .{}, 0, null, .{});
    // Only the fourth is drawn: its one part. The first, which the camera sits in, casts its
    // shadow without being drawn.
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(math.Vector{ 300, 0, 0 }, scene.layers.get(.world).items[0].mesh.position);
    try std.testing.expectEqual(1, scene.casters.items.len);
    try std.testing.expectEqual(math.Vector{ 0, 0, 0 }, scene.casters.items[0].position);

    // The ejection's cutaway shows the player's pod and the cutaway slot's ship alone.
    all.slots[0].object.flags.hidden = false;
    const seen = try create.createObject(all, &tables, model.types(), create.cutaway_slot, .predator, 0, .{ 0, 0, 500 }, &random);
    frameObjects(all, .{}, 0);
    scene.clear();
    try drawObjects(gpa, &scene, all, .{}, null, null, .{ .showing = .ejection });
    const drawn = scene.layers.get(.world).items;
    try std.testing.expectEqual(2, drawn.len);
    for (drawn) |item| try std.testing.expect(std.meta.eql(item.mesh.position, all.slots[0].drawn.position) or std.meta.eql(item.mesh.position, all.slots[seen].drawn.position));

    // A launch's cutaway leaves out the ship the player launches from.
    scene.clear();
    try drawObjects(gpa, &scene, all, .{}, null, null, .{ .showing = .launch, .carrier = 3 });
    for (scene.layers.get(.world).items) |item| try std.testing.expect(!std.meta.eql(item.mesh.position, all.slots[3].drawn.position));
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
}

test "an object the orders place is drawn on by its glide, for the time past the tick" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const index = try mission.add(.predator, .{ 0, 0, 100 });
    const slot = mission.slot(index);
    // Placed at 100 and going 8 a tick, half a tick on it is drawn 4 further along.
    slot.glide = .{ 0, 0, 8 };
    frameObjects(mission.objects, .{ .ahead = 0.5 }, 0);
    try std.testing.expectEqual(math.Vector{ 0, 0, 104 }, slot.drawn.position);
    // Its glide goes once used: placed no more, it is drawn back where it was placed.
    try std.testing.expectEqual(math.Vector{ 0, 0, 0 }, slot.glide);
    frameObjects(mission.objects, .{ .ahead = 0.5 }, 0);
    try std.testing.expectEqual(math.Vector{ 0, 0, 100 }, slot.drawn.position);
    try std.testing.expect(!slot.glided);
    slot.glide = .{ 0, 0, 8 };
    frameObjects(mission.objects, .{ .ahead = 0.25 }, 0);
    try std.testing.expectEqual(math.Vector{ 0, 0, 102 }, slot.drawn.position);
}

/// A driver that draws nothing and counts the frames it is handed, for the tests of what goes into
/// a frame.
const IdleDriver = struct {
    frames: usize = 0,

    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const srbmo = @import("../surrender/surrenderlib/srbmo.zig");
    const srstars = @import("../surrender/surrenderlib/srstars.zig");
    const srlight = @import("../surrender/surrenderlib/srlight.zig");

    fn driver(idle: *IdleDriver) srcore.Driver {
        return .{ .ptr = idle, .vtable = &.{
            .begin = begin,
            .lights = lights,
            .mesh = mesh,
            .sprites = sprites,
            .stars = stars,
            .overlay = mark,
            .flush = flush,
            .end = mark,
        } };
    }

    fn begin(ptr: *anyopaque, _: *srapi.Context) void {
        const idle: *IdleDriver = @ptrCast(@alignCast(ptr));
        idle.frames += 1;
    }

    fn lights(_: *anyopaque, _: []srlight.Light) Allocator.Error!void {}
    fn mesh(_: *anyopaque, _: *const srmesh.Drawn, _: srcore.Layer, _: *srcore.Blended) Allocator.Error!void {}
    fn sprites(_: *anyopaque, _: *const srbmo.Drawn, _: srcore.Layer, _: *srcore.Blended) Allocator.Error!void {}
    fn stars(_: *anyopaque, _: *const srstars.Drawn, _: srcore.Layer, _: *srcore.Blended) Allocator.Error!void {}
    fn mark(_: *anyopaque) void {}
    fn flush(_: *anyopaque, _: []const srcore.Deferred, _: srcore.Layer) void {}
};

test drawFrame {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    const ship = try create.createObject(mission.objects, &mission.tables, model.types(), null, .predator, 0, .{ 0, 0, 1000 }, &mission.random);
    frameObjects(mission.objects, .{}, 0);

    // The backdrop, the sky, and the radar's backing, from textures of their own names.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    try names.appendSlice(gpa, backdrop.testing.names);
    try names.append(gpa, RadarBacking.texture_name);
    const textures = try srtexture.testing.Textures.init(gpa, names.items);
    defer textures.deinit(gpa);
    const map = try gpa.alloc(u8, backdrop.star_map_size * backdrop.star_map_size * 3);
    defer gpa.free(map);
    @memset(map, 0);
    const space = try backdrop.Backdrop.create(gpa, &textures.table, .{ .width = backdrop.star_map_size, .height = backdrop.star_map_size, .rgb = map }, &mission.random, 100, .original);
    defer space.destroy(gpa);
    const dome = try gpa.alloc(u8, nebula.dome_image_size * nebula.dome_image_size * 3);
    defer gpa.free(dome);
    @memset(dome, 0);
    const sky = try nebula.Sky.create(gpa, &textures.table, .{ .width = nebula.dome_image_size, .height = nebula.dome_image_size, .rgb = dome });
    defer sky.destroy(gpa);
    const backing = try RadarBacking.create(gpa, &textures.table);
    defer gpa.destroy(backing);
    var cockpit_model = try cockpit.create(arena, &model.source, &model.loaded);

    var context: srapi.Context = .{ .projection = .init(640, 480, srapi.full_screen, camera.factors) };
    backing.place(context.projection, .{}, 1);
    var idle: IdleDriver = .{};
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var frame: Frame = .{
        .objects = mission.objects,
        .space = space,
        .sky = sky,
        .view = .chase,
        .cockpit_mode = .open,
        .last_view = .chase,
        .cockpit = &cockpit_model,
        .backing = backing,
    };

    // Behind the ship: the ship in the world, the backdrop's stars first in the background and the
    // sky's dome and nebula last, and the frame handed to the driver.
    try drawFrame(gpa, arena, &scene, &context, frame, idle.driver());
    try std.testing.expectEqual(1, idle.frames);
    const world = scene.layers.get(.world).items;
    try std.testing.expectEqual(1, world.len);
    try std.testing.expectEqual(&mission.slot(ship).model.?.parts[0].object, world[0].mesh);
    const background = scene.layers.get(.background).items;
    try std.testing.expectEqual(&space.fields[0], background[0].stars);
    try std.testing.expectEqual(&sky.dome, background[background.len - 2].mesh);
    try std.testing.expectEqual(&sky.patches[sky.shown], background[background.len - 1].mesh);

    // From the cockpit with its model, the radar's backing and then the cockpit go over it all:
    // this cockpit has no hands.
    frame.view = .cockpit;
    frame.cockpit_mode = .cockpit;
    try drawFrame(gpa, arena, &scene, &context, frame, idle.driver());
    var overlay = scene.layers.get(.overlay).items;
    try std.testing.expectEqual(2, overlay.len);
    try std.testing.expectEqual(&backing.object, overlay[0].mesh);
    try std.testing.expectEqual(&cockpit_model.parts[cockpit.frame].object, overlay[1].mesh);
    // DISPLAY KILLS held, the backing is left out.
    frame.kills_shown = true;
    try drawFrame(gpa, arena, &scene, &context, frame, idle.driver());
    overlay = scene.layers.get(.overlay).items;
    try std.testing.expectEqual(1, overlay.len);
    try std.testing.expectEqual(&cockpit_model.parts[cockpit.frame].object, overlay[0].mesh);

    // The software renderer draws neither the sky nor the cockpit.
    context.hardware = false;
    frame.kills_shown = false;
    try drawFrame(gpa, arena, &scene, &context, frame, idle.driver());
    try std.testing.expectEqual(4, idle.frames);
    try std.testing.expectEqual(0, scene.layers.get(.overlay).items.len);
    for (scene.layers.get(.background).items) |item| {
        if (item == .mesh) try std.testing.expect(item.mesh != &sky.dome);
    }
}

test "the passes draw a cloaked object through its cloak" {
    const gpa = std.testing.allocator;
    var stage: cloak.testing.Cloaked = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    const part = stage.part();
    cloak.set(stage.mission.world(), stage.index, true);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);

    // Halfway on, the frame wobbles, and the part is drawn see-through, half solid, under its
    // shimmer.
    const halfway = cloak.change_ticks / 2;
    frameObjects(stage.mission.objects, .{}, halfway);
    try std.testing.expect(!std.meta.eql(math.identity, stage.slot().drawn.orientation));
    try drawObjects(gpa, &scene, stage.mission.objects, .{ .frame_start = halfway }, null, null, .{});
    const drawn = scene.layers.get(.world).items;
    try std.testing.expectEqual(2, drawn.len);
    try std.testing.expectEqual(&part.cloak.?.shimmer, drawn[0].mesh);
    try std.testing.expectEqual(&part.object, drawn[1].mesh);
    try std.testing.expectApproxEqAbs(0.5, part.object.colour[3], 1e-6);

    // Once it has come on and gone again, the part alone, as it was.
    scene.clear();
    cloak.frame(stage.slot(), cloak.change_ticks);
    cloak.toggle(stage.mission.world(), stage.index);
    try drawObjects(gpa, &scene, stage.mission.objects, .{ .frame_start = 2 * cloak.change_ticks }, null, null, .{});
    try std.testing.expectEqual(null, stage.slot().cloak);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
}

/// The radar's backing (`0x005883BC`), which the mission's start makes and the cockpit's view
/// draws first: a rectangle across the radar, from 65 left of the middle of the screen to 67
/// right, and 32 either side of the radar's height, `radaralpha`'s disc on it, 75% black. The
/// start unprojects its corners to 1000 in front of the camera, and the object stands in the
/// camera's frame, so it keeps its place on the screen.
///
/// **Improvement.** OpenReliant keeps it on the radar as the display is scaled: its corners are
/// measured in the display's pixels from where the radar stands, and worked out again each frame
/// for the window's size.
pub const RadarBacking = struct {
    positions: [4]math.Vector,
    normals: [4]math.Vector = @splat(@splat(0)),
    polygons: [1]srapiext.Polygon = .{.{ .kind = .triangle, .continues = 0, .first = 0, .count = 4 }},
    indices: [4]u16 = .{ 0, 1, 2, 3 },
    planes: [1]srapiext.Plane = .{.{ .normal = @splat(0), .distance = 0 }},
    biases: [1]f32 = .{0},
    surfaces: [1]srapiext.Surface,
    baked: [4][4]f32 = @splat(colour),
    uv: [4][2]f32 = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } },
    mesh: srapiext.Mesh,
    levels: [1]srapiext.Level,
    object: srapiext.MeshObject,

    /// Its corners across from the middle of the screen, and down from the radar's point.
    pub const across: [2]i32 = .{ -65, 67 };
    pub const down: [2]i32 = .{ -32, 32 };
    /// How far in front of the camera the corners stand.
    pub const depth: f32 = 1000;
    pub const colour: [4]f32 = .{ 0, 0, 0, 0.75 };
    pub const texture_name = "radaralpha";

    /// Makes the backing, with its texture from `textures`, as the start does: lit by its own
    /// colours, textured by its own coordinates and blended by alpha, never culled.
    pub fn create(gpa: Allocator, textures: *srtexture.Table) matmanager.Error!*RadarBacking {
        const texture = try matmanager.textureRequire(textures, texture_name);
        const backing = try gpa.create(RadarBacking);
        backing.* = .{
            .positions = @splat(@splat(0)),
            .surfaces = .{.{ .polygons = 1, .material = .onePass(.{ .coordinates = .generated, .lit = true, .blend = .alpha }), .textures = .{ .{ .image = texture }, .none } }},
            .mesh = undefined,
            .levels = undefined,
            .object = undefined,
        };
        backing.mesh = .{
            .positions = &backing.positions,
            .normals = &backing.normals,
            .polygons = &backing.polygons,
            .indices = &backing.indices,
            .uv = .{ null, null },
            .planes = &backing.planes,
            .biases = &backing.biases,
            .surfaces = &backing.surfaces,
            .baked = &backing.baked,
            .bounds = undefined,
            .radius = undefined,
        };
        backing.levels = .{.{ .mesh = &backing.mesh, .until = std.math.inf(f32) }};
        backing.object = .{
            .flags = .{ .not_culled = true, .baked_mesh = true, .own_first = true },
            .position = @splat(0),
            .radius = 0,
            .levels = &backing.levels,
            .own_uv = .{ &backing.uv, null },
        };
        return backing;
    }

    /// Puts the corners on the radar for this frame's `projection`, and the object at the camera.
    pub fn place(backing: *RadarBacking, projection: srapi.Projection, at: camera.Place, scale: f32) void {
        backing.positions = corners(projection, scale);
        srapi.findBoundingBox(&backing.mesh);
        backing.object.radius = backing.mesh.radius;
        backing.object.position = at.position;
        backing.object.orientation = at.orientation;
    }

    /// The corners in the camera's frame: across from the middle of the screen and down from the
    /// radar's height, in the display's pixels, unprojected to `depth`.
    pub fn corners(projection: srapi.Projection, scale: f32) [4]math.Vector {
        const radar = hud.place(projection.screen, hud.Radar.offset, hud.Radar.across, hud.Radar.down, scale);
        const around = [4][2]i32{ .{ across[0], down[0] }, .{ across[1], down[0] }, .{ across[1], down[1] }, .{ across[0], down[1] } };
        var out: [4]math.Vector = undefined;
        for (&out, around) |*position, corner| {
            const x = @as(f32, @floatFromInt(corner[0])) * scale;
            const y = @as(f32, @floatFromInt(radar[1])) + @as(f32, @floatFromInt(corner[1])) * scale - projection.centre[1];
            position.* = .{ x * depth / projection.scale[0], y * depth / projection.scale[1], depth };
        }
        return out;
    }
};

test missionOver {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const index = try mission.add(.predator, @splat(0));
    var watching: camera.Camera = .{};
    var world = mission.world();
    // Without a camera, or in a view of the mission, the mission goes on.
    try std.testing.expect(!missionOver(world));
    world.camera = &watching;
    mission.clock.mission_ticks = 100_000;
    try std.testing.expect(!missionOver(world));
    // The player's end is watched for six seconds, the pickup for twelve.
    for ([_]struct { camera.View, u32 }{ .{ .pull_back, end_watched }, .{ .pickup, pickup_watched } }) |case| {
        const view, const watched = case;
        _ = watching.setView(view, index, true, true, 1000);
        mission.clock.mission_ticks = @intCast(1000 + watched);
        try std.testing.expect(!missionOver(world));
        mission.clock.mission_ticks += 1;
        try std.testing.expect(missionOver(world));
    }
    // The pod shot down is watched from when it bursts.
    _ = watching.setView(.pod_shot, index, true, true, 0);
    mission.clock.mission_ticks = 5000;
    try std.testing.expect(!missionOver(world));
    try std.testing.expectEqual(5000, watching.switched);
    mission.slot(index).object.flags.exploding = true;
    mission.clock.mission_ticks = 5001 + shot_watched;
    try std.testing.expect(missionOver(world));
}

test "the radar's backing stands where the radar does" {
    // At 640 by 480 and the game's scale, the corners project back to 65 left of the middle to
    // 67 right, and 32 either side of the radar's height, 68 above the foot.
    const projection = srapi.Projection.init(640, 480, .{ 0, 0, 1, 1 }, camera.factors);
    const corners = RadarBacking.corners(projection, 1);
    for (corners, [4][2]f32{ .{ 320 - 65, 480 - 68 - 32 }, .{ 320 + 67, 480 - 68 - 32 }, .{ 320 + 67, 480 - 68 + 32 }, .{ 320 - 65, 480 - 68 + 32 } }) |corner, expected| {
        const screen = projection.transform(corner);
        try std.testing.expectApproxEqAbs(expected[0], screen.x, 0.01);
        try std.testing.expectApproxEqAbs(expected[1], screen.y, 0.01);
    }
}

// --- The armour ---------------------------------------------------------------------------

/// `0x00492370`: what an object's armour does to it, from how much of each quadrant's armour is
/// left of its full armour, `6 * ShipCombat.armor_class - 1`, the fore quadrant being the third
/// and the aft the fourth: the guns' condition (`gun_condition`), half the fore one's share and a
/// quarter of each side's; the cruise speed (`armor_speed_factor`), a quarter plus three quarters
/// of the aft one's; and the shields' recharge (`shield_condition`), a quarter of each quadrant's.
/// `create_object` runs it once the armour is full, and the damage as it wears. **Unverified:** it
/// lies after `language.cpp`'s code, where `main.cpp`'s begins, next to `mission_frame`. For the
/// player's ship it goes on to the warning (`armorWarning`).
pub fn armorConditions(object: *gameobj.GameObject, combat: *const create.ShipCombat) void {
    const full = combat.startingArmor();
    const fore = object.armor.fore / full;
    const aft = object.armor.aft / full;
    const sides = (object.armor.left / full) * quadrant_share + (object.armor.right / full) * quadrant_share;
    object.gun_condition = fore * fore_gun_share + sides;
    object.armor_speed_factor = aft * aft_speed_share + least_speed_share;
    object.shield_condition = fore * quadrant_share + aft * quadrant_share + sides;
}

/// What `armorConditions` weighs each quadrant's share of its armour by: a quarter of each toward
/// the shields, and of each side toward the guns (`0x004DC3D4`); half the fore's toward the guns
/// (`0x004DC408`); and three quarters of the aft's toward the cruise speed (`0x004DC550`), over the
/// quarter it keeps with no aft armour at all (`0x004DC3D4`).
const quadrant_share: f32 = 0.25;
const fore_gun_share: f32 = 0.5;
const aft_speed_share: f32 = 0.75;
const least_speed_share: f32 = 0.25;

/// The rest of `object_armor_conditions` (`0x00492370`), for the player's ship: once a quadrant has
/// lost its shield and `armor_warning_share` of its armour, the cockpit's warning, sound 1 of
/// `betty.fat`, no more than once in `armor_warning_interval` ticks.
pub fn armorWarning(hearing: hog_snd.Hearing, object: *const gameobj.GameObject, combat: *const create.ShipCombat) void {
    const sound = hearing.sound;
    const frame_start = hearing.clock.frame_start;
    if (frame_start - sound.armor_warned_at <= armor_warning_interval) return;
    const half = combat.startingArmor() * armor_warning_share;
    for (object.shields.values(), object.armor.values()) |held, armor| {
        if (held > 0 or armor >= half) continue;
        _ = betty.say(sound, .armor_failing);
        sound.armor_warned_at = frame_start;
        return;
    }
}

/// How long the armour's warning keeps quiet once given, in ticks (`0x00492432`), and the share of
/// a quadrant's armour below which it is given (`0x004DC408`).
const armor_warning_interval = 500;
const armor_warning_share: f32 = 0.5;

test armorWarning {
    const mss = @import("../mss.zig");
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: hog_snd.Sound = undefined;
    sound.init(driver, 2, null);
    const bytes = comptime hog_snd.testing.bank(2);
    sound.betty = try @import("../../formats/fat.zig").Bank.parse(&bytes);
    var clock: Clock = .{ .frame_start = 1000 };
    const view: camera.Place = .{ .position = @splat(0), .orientation = math.identity };
    const hearing: hog_snd.Hearing = .{ .sound = &sound, .camera = &view, .clock = &clock };
    const combat = std.mem.zeroInit(create.ShipCombat, .{ .armor_class = 5 });
    var object = gameobj.testing.object();
    object.shields = .all(10);
    object.armor = .all(29);

    // Whole, or with its shields up, no warning.
    armorWarning(hearing, &object, &combat);
    object.armor.left = 10;
    armorWarning(hearing, &object, &combat);
    try std.testing.expectEqual(0, sound.armor_warned_at);
    // A quadrant with its shield gone and under half its armour warns, and not again for 500
    // ticks.
    object.shields.left = 0;
    armorWarning(hearing, &object, &combat);
    try std.testing.expectEqual(1000, sound.armor_warned_at);
    clock.frame_start = 1400;
    armorWarning(hearing, &object, &combat);
    try std.testing.expectEqual(1000, sound.armor_warned_at);
}

test armorConditions {
    var object = gameobj.testing.object();
    const combat = std.mem.zeroInit(create.ShipCombat, .{ .armor_class = 5 });
    // Whole, everything works fully.
    object.armor = .all(29);
    armorConditions(&object, &combat);
    try std.testing.expectEqual(1, object.gun_condition);
    try std.testing.expectEqual(1, object.armor_speed_factor);
    try std.testing.expectEqual(1, object.shield_condition);
    // With the aft armour gone the ship is down to a quarter of its speed, and its shields to
    // three quarters; the guns, at the fore, are untouched.
    object.armor.aft = 0;
    armorConditions(&object, &combat);
    try std.testing.expectEqual(1, object.gun_condition);
    try std.testing.expectEqual(0.25, object.armor_speed_factor);
    try std.testing.expectEqual(0.75, object.shield_condition);
}

// --- The mission's start -------------------------------------------------------------------

/// A ship the player can fly, as the mission's start (`0x004934F0`) knows it.
pub const PlayerShip = struct {
    /// The model of the cockpit's frame, which the start loads into `0x0057E048`.
    cockpit: []const u8,
    /// The gunnery display's wire frame of the ship, a shape of the display's set, which the start
    /// keeps at `0x005883C0` (`hud.gunnery`).
    wire_frame: u16,
    /// The shape the wing status window shows the ship by (`GameObject.wing_icon`), which the
    /// start gives each ship of the player's wing from the table at `0x004F8890`.
    wing_icon: u16,
    spectral_shields: bool = false,
    blind_fire: bool = false,
};

/// The twelve ships the player can fly, by ship type.
///
/// In mission 25's first part (`mission_number`, `mission25_second_part`), the start loads the
/// Kamov's cockpit, `kamg_frm.shp`, whatever the ship, which OpenReliant does not yet
/// ([#301](https://github.com/vdmkenny/openreliant/issues/301)).
pub const player_ships = [_]PlayerShip{
    .{ .cockpit = "preg_frm.shp", .wire_frame = 0x116, .wing_icon = 0xFC, .blind_fire = true },
    .{ .cockpit = "nagg_frm.shp", .wire_frame = 0x10E, .wing_icon = 0xFA, .spectral_shields = true },
    .{ .cockpit = "gre2_frm.shp", .wire_frame = 0x108, .wing_icon = 0x101 },
    .{ .cockpit = "cru3_frm.shp", .wire_frame = 0x107, .wing_icon = 0xFF, .spectral_shields = true },
    .{ .cockpit = "coyg_frm.shp", .wire_frame = 0x106, .wing_icon = 0x102, .blind_fire = true },
    .{ .cockpit = "mirg_frm.shp", .wire_frame = 0x10B, .wing_icon = 0xFB },
    .{ .cockpit = "temg_frm.shp", .wire_frame = 0x11B, .wing_icon = 0x100, .spectral_shields = true },
    .{ .cockpit = "pat2_frm.shp", .wire_frame = 0x10F, .wing_icon = 0x103, .blind_fire = true },
    .{ .cockpit = "wolv_frm.shp", .wire_frame = 0x11E, .wing_icon = 0xFE },
    .{ .cockpit = "rea2_frm.shp", .wire_frame = 0x117, .wing_icon = 0x105, .blind_fire = true },
    .{ .cockpit = "shr2_frm.shp", .wire_frame = 0x11A, .wing_icon = 0xFD, .spectral_shields = true, .blind_fire = true },
    .{ .cockpit = "phe2_frm.shp", .wire_frame = 0x112, .wing_icon = 0x104, .blind_fire = true },
};

/// The player's ship of `ship_type`, a twin as the ship it twins (`gameobj.Type.untwinned`), or null
/// for a type the start has none for.
pub fn playerShip(ship_type: gameobj.Type) ?PlayerShip {
    const index = ship_type.untwinned().number();
    return if (index < player_ships.len) player_ships[index] else null;
}

/// `mission_start`'s part in the player's wing, once the mission has listed it: the player's ship
/// takes the wing's first slot, and each ship in the wing the icon of its type
/// (`PlayerShip.wing_icon`), or none for a type the player can't fly.
pub fn startWing(all: *create.Objects) void {
    all.wing[0] = all.player;
    for (all.wing) |listed| {
        const index = listed orelse continue;
        const object = &all.slots[index].object;
        object.wing_icon = if (playerShip(object.type)) |ship| ship.wing_icon else 0;
    }
}

test startWing {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.reaper, @splat(0));
    const wingman = try mission.add(.predator, .{ 1000, 0, 0 });
    const twin = try mission.add(.t_phoenix, .{ 2000, 0, 0 });
    const capital = try mission.add(.reliant, .{ 0, 0, 9000 });
    all.wing = .{ null, wingman, twin, capital, null, null };
    startWing(all);
    // The player first, and each ship by its type's icon: a twin as the ship it twins, a type the
    // player can't fly none.
    try std.testing.expectEqual(player, all.wing[0].?);
    try std.testing.expectEqual(player_ships[9].wing_icon, all.slots[player].object.wing_icon);
    try std.testing.expectEqual(0xFC, all.slots[wingman].object.wing_icon);
    try std.testing.expectEqual(0x104, all.slots[twin].object.wing_icon);
    try std.testing.expectEqual(0, all.slots[capital].object.wing_icon);
}

/// What a mission's start readies the mission in, and starts it with.
pub const Start = struct {
    /// What the objects' orders and the mission's script act on: the world, whose pools the start
    /// empties and whose objects it makes afresh, and its clock.
    orders: aigeneric.Context,
    /// The mission's clocks, whose frame the start resets (`frame_reset`).
    clock: *Clock,
    /// The ship types' stats, and their models, which the objects are made from: the start lets go
    /// of the models no object is of any more, and loads each type the mission places
    /// (`ship_type_load`).
    tables: *create.Stats,
    types: *create.library.TypeCache,
    /// The cockpit it loads for the player's ship, and the display it readies for it.
    cockpit: *cockpit.Cockpit,
    display: *hud.State,
};

/// Where the mission's start makes the camera's marker (`0x00588390`), which the flyby and target
/// views move about (`frame_controls`, `camera_set_view`): an immediate of `mission_start`.
/// OpenReliant's camera keeps its own place for those views, and nothing reads the marker.
const camera_marker_at: math.Vector = .{ 0, 0, -8000 };

/// A mission's start: the loading before `mission_start` (`0x004AD0A0`) and `mission_start`
/// (`0x004934F0`), for the mission `image`, made in `gpa`, which the mission then owns, played as
/// mission `number`. Returns the mission loaded for play, which the caller destroys once it ends.
///
/// The loading readies the display's objectives and the launch's caption for the mission, and drops
/// the flyback markers (`hud_init`), empties the effects' pools and the missiles in flight, puts a
/// stand-in in every object's slot (`create.Objects.reset`), loads the Turret Flak's shell and the
/// debris (`guns_load_shell`, `explosions_init`), and clears the mark of the player's ship jumping
/// in (`jump_init`). Then the start:
/// 1. ends the 3D sounds, has the mission play with everything shown, no ship the player launched
///    from, no primary target, the camera free in view 0 on the player's ship, in the cockpit mode
///    the options' setting picks, and the ejected pilot always picked up, and puts back the pilot's
///    kills (`winmain.startMission`);
/// 2. binds the mission, whose records the orders then reach (`gameobj.World.mission`), and starts
///    its script (`mission.Loaded.start`), whose start part makes the mission's first ships and
///    gives them their orders, a launch among them;
/// 3. lists the player's wing's icons (`startWing`), and makes the camera's marker in the next
///    slot;
/// 4. lets go of the types no object is of any more, and loads the model of each type the mission
///    places;
/// 5. resets the frame's clock (`frame_reset`), loads the cockpit of the player's ship, and readies
///    the display for it as `hud_init` and the start have it: its devices fitted (`fitDevices`),
///    its missiles in the missile display, no missile lock, and the eject marker out.
///
/// The start clears the keyboard's state (`0x004BD7E0`), which the next read of the keyboard fills
/// again; OpenReliant's keeps what the device reports.
///
/// Not ported: the renderer's and the textures' setting up and the loading screen, which are the
/// front end's ([#43](https://github.com/vdmkenny/openreliant/issues/43)); the chat line and a
/// multiplayer game; and what the start does for the campaign: the pilots it gives the player's
/// wing, mission 25's first part's cockpit, and the pilot's profile
/// ([#301](https://github.com/vdmkenny/openreliant/issues/301)).
pub fn startMission(gpa: Allocator, start: Start, image: []u8, number: u16) !*Loaded {
    const types = start.types.types();
    var orders = start.orders;
    orders.world.spawn = .{ .tables = start.tables, .types = types };
    const world = orders.world;
    const all = world.objects;
    if (world.explosions) |explosions| explosions.reset();
    if (world.shockwaves) |waves| waves.reset();
    if (world.sparks) |thrown| thrown.reset();
    if (world.particles) |pool| pool.reset();
    if (world.smoke) |pools| pools.reset();
    if (world.gun_particles) |pools| pools.reset();
    all.missiles.reset(all.gpa);
    if (world.trails) |trails| trails.reset();
    if (world.rays) |rays| rays.reset();
    if (world.tractors) |tractors| tractors.reset();
    if (world.rippers) |rippers| rippers.reset();
    if (world.flash) |lit| lit.* = .{};
    start.display.interference = .{};
    start.display.caption = .{};
    start.display.objectives.reset(number, all.mission25_second_part);
    if (world.countermeasures) |dropped| dropped.reset();
    all.reset(world.random);
    // The shell and the debris, counted as used so the sweep below keeps them.
    if (all.bullets.looks) |looks| looks.loadShell(all, types);
    if (world.explosions) |explosions| explosions.debris = .load(all, types);

    if (world.hearing) |hearing| sound3d.endAll(hearing.sound);
    world.player.ending = .playing;
    world.player.showing = .everything;
    world.player.rescue_odds = .{};
    world.player.carrier = null;
    world.player.cutaway = .none;
    world.player.jumping_in = false;
    world.player.flyback = .{};
    world.player.primary_target = null;
    if (world.camera) |view| {
        view.view = .cockpit;
        view.object = all.player;
        view.locked = false;
        view.cockpit_mode = view.setting.mode();
    }
    winmain.startMission(world.player);
    all.mission_number = number;
    const loaded = try Loaded.create(gpa, image, world.random);
    errdefer loaded.destroy();
    orders.world.mission = &loaded.bound;
    orders.world.events = &loaded.events;
    try loaded.start(orders);

    startWing(all);
    _ = create.createObject(all, start.tables, types, null, .marker, 0, camera_marker_at, world.random) catch |err| {
        std.log.warn("the camera's marker is left out: {s}", .{@errorName(err)});
    };
    start.types.sweep(&all.types);
    // The schematics the target display last showed went with the types let go.
    start.display.target_pictures = .{};
    for (try loaded.bound.ships()) |ship| {
        if (std.math.cast(u8, ship.kind)) |kind| _ = types.load(types.context, kind);
    }
    start.clock.frameReset();

    const player = &all.slots[all.player];
    const player_type = all.slotType(all.player, if (try loaded.bound.file.player()) |record| @enumFromInt(record.kind) else player.object.type);
    try start.cockpit.load(start.types.resources, start.types.textures, player_type);
    start.display.ejected = false;
    fitDevices(start.display, player_type, if (player.type) |loaded_type| loaded_type.model.header.flags.cloak else false);
    start.display.missiles.build(&player.object);
    start.display.lock.reset();
    return loaded;
}

/// Fits the display's devices to the player's ship, as the start does after `hud_init` has set
/// the display up: every ship carries an ECM, the ships of `player_ships` that say so spectral
/// shields and blind fire, and a ship whose model can cloak (`shp.Header.Flags.cloak`) a cloak.
/// Blind fire starts on where it is carried; elsewhere it is left as it was.
pub fn fitDevices(display: *hud.State, ship_type: gameobj.Type, can_cloak: bool) void {
    const ship = playerShip(ship_type);
    display.devices.getPtr(.ecm).setting = .off;
    const spectral = if (ship) |known| known.spectral_shields else false;
    display.devices.getPtr(.spectral_shields).setting = if (spectral) .off else .absent;
    display.devices.getPtr(.cloak).setting = if (can_cloak) .off else .absent;
    display.blind_fire_fitted = if (ship) |known| known.blind_fire else false;
    display.wire_frame = if (ship) |known| known.wire_frame else null;
    if (display.blind_fire_fitted) display.blind_fire = true;
}

test fitDevices {
    // The Shroud carries all three, and a cloak where its model has one.
    const shroud: gameobj.Type = @enumFromInt(10);
    var display: hud.State = .{ .blind_fire = false };
    fitDevices(&display, shroud, true);
    try std.testing.expectEqual(.off, display.devices.get(.spectral_shields).setting);
    try std.testing.expectEqual(.off, display.devices.get(.cloak).setting);
    try std.testing.expect(display.blind_fire_fitted and display.blind_fire);
    // Its twin is the same ship.
    try std.testing.expectEqual(playerShip(shroud), playerShip(@enumFromInt(0xFE)));
    // The Grendel carries only the ECM.
    fitDevices(&display, .grendel, false);
    try std.testing.expectEqual(.off, display.devices.get(.ecm).setting);
    try std.testing.expectEqual(.absent, display.devices.get(.spectral_shields).setting);
    try std.testing.expectEqual(.absent, display.devices.get(.cloak).setting);
    try std.testing.expect(!display.blind_fire_fitted);
    // A capital ship is none of the player's.
    try std.testing.expectEqual(null, playerShip(.yamato));
}

test startMission {
    const gpa = std.testing.allocator;
    const dte = @import("../../formats/dte.zig");
    const vm = @import("../vm.zig");
    // The start part: the player's flight group, then the other ship's, which fights the player.
    var routine: vm.machine.testing.Routine = .init(gpa);
    defer routine.deinit();
    for (0..2) |group| {
        try routine.op(.push_flight_group, &.{@intCast(group)});
        try routine.command("CreateFlightGroup");
    }
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_byte, &.{@intCast(@intFromEnum(ai.orders.Order.fight))});
    try routine.op(.push_byte, &.{1});
    try routine.op(.push_ship, &.{0});
    try routine.command("SetAI");
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);
    var ships: [2]dte.Ship = @splat(std.mem.zeroes(dte.Ship));
    // The player flies a torpedo, a type with a model but no schematic nor cockpit, and the other
    // is of a type the game names no model for.
    const torpedo: gameobj.Type = @enumFromInt(74);
    const modelless: gameobj.Type = @enumFromInt(14);
    for (&ships, [_]gameobj.Type{ torpedo, modelless }, 0..) |*ship, kind, index| {
        ship.object_id = @intCast(index);
        ship.flight_group = @intCast(index);
        ship.kind = @intCast(kind.number());
        ship.pilot = dte.Ship.no_pilot;
        ship.launch_gate = dte.Ship.no_launch;
        ship.position = .{ 0, 0, @floatFromInt(index * 5000) };
    }
    var groups: [2]dte.FlightGroup = @splat(std.mem.zeroes(dte.FlightGroup));
    groups[0].wing = 0;
    groups[1].wing = dte.FlightGroup.no_wing;
    var part = std.mem.zeroes(dte.Part);
    part.flags.start = true;
    part.length = @intCast(code.len / @sizeOf(u16));
    var sections: dte.write.Sections = @splat(.{});
    sections[@intFromEnum(dte.Section.ships)] = .{ .count = ships.len, .bytes = std.mem.sliceAsBytes(&ships) };
    sections[@intFromEnum(dte.Section.flight_groups)] = .{ .count = groups.len, .bytes = std.mem.sliceAsBytes(&groups) };
    sections[@intFromEnum(dte.Section.script)] = .{ .count = @intCast(code.len / @sizeOf(u16)), .bytes = code };
    sections[@intFromEnum(dte.Section.parts)] = .{ .count = 1, .bytes = std.mem.asBytes(&part) };
    const image = try dte.write.write(gpa, &sections, .{});

    // The game's files: the torpedo's model alone.
    var files: create.library.testing.Files = try .init(gpa, create.models.ship_types[torpedo.number()].model.?);
    defer files.deinit(gpa);
    var types: create.library.TypeCache = .{ .gpa = gpa, .resources = &files.resources, .textures = &files.textures.table, .looks = .{}, .global_palette = null };
    defer types.deinit();
    var shown: cockpit.Cockpit = .{};
    defer shown.deinit();
    var state: hud.State = .{ .ejected = true };
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    mission.player.rescue_odds = .{ .rescued = 1, .captured = 1, .killed = 1 };
    const loaded = try startMission(gpa, .{
        .orders = mission.orders(),
        .clock = &mission.clock,
        .tables = &mission.tables,
        .types = &types,
        .cockpit = &shown,
        .display = &state,
    }, image, 0);
    defer loaded.destroy();

    // The mission's ships in the first slots, the player's with its model, then the camera's marker.
    const all = mission.objects;
    try std.testing.expectEqual(3, all.count);
    try std.testing.expect(all.slots[0].type != null);
    try std.testing.expectEqual(gameobj.Type.marker, all.slots[2].object.type);
    try std.testing.expectEqual(camera_marker_at[2], all.slots[2].object.root.position.z);
    // The player's ship on its controls, and the other under the order the script gave it.
    try std.testing.expectEqual(ai.orders.Order.player_control, all.slots[0].orders[0].order);
    try std.testing.expectEqual(ai.orders.Order.fight, all.slots[1].orders[0].order);
    // The player first in the wing, the pilot always picked up, and the display readied.
    try std.testing.expectEqual(0, all.wing[0].?);
    try std.testing.expectEqual(100, mission.player.rescue_odds.rescued);
    try std.testing.expect(!state.ejected);
}

test missionFrame {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    // The player's slot, then a ship that turns on the spot under an order of its own.
    for (0..2) |_| _ = try mission.add(.predator, @splat(0));
    const orders = mission.orders();
    try std.testing.expect(try aigeneric.push(orders, 1, .slow_rotate, .{ .kind = .ship, .index = -1, .component = -1 }));

    _ = missionFrame(orders, .{}, null);
    // The frame ran the ship's order, and framed every object where it is drawn.
    try std.testing.expect(mission.objects.slots[1].object.yaw_input > 0);
    try std.testing.expect(!mission.objects.slots[1].object.root.flags.unframed);
}

test "the simulation steps on every fourth tick" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    // A second of the timer: 100 ticks, 100 game ticks, 25 steps.
    clock.advanceTimer(100);
    try std.testing.expectEqual(100, clock.game_ticks);
    try std.testing.expectEqual(25, clock.runTicks(&devices, mission.world()));
    try std.testing.expectEqual(100, clock.mission_ticks);
    // The ticks already run are not run again.
    try std.testing.expectEqual(0, clock.runTicks(&devices, mission.world()));
}

test "a paused game stops its clocks but not the timer" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    clock.advanceTimer(8);
    _ = clock.runTicks(&devices, mission.world());
    clock.paused = true;
    clock.advanceTimer(100);
    // The timer counts the paused ticks; the mission's clocks do not move.
    try std.testing.expectEqual(108, clock.timer_ticks);
    try std.testing.expectEqual(8, clock.game_ticks);
    try std.testing.expectEqual(8, clock.mission_ticks);
    try std.testing.expectEqual(0, clock.runTicks(&devices, mission.world()));
    // Paused ticks are counted only for the game ticks the loop asks for.
    clock.paused = false;
    clock.advanceTimer(4);
    try std.testing.expectEqual(1, clock.runTicks(&devices, mission.world()));
    try std.testing.expectEqual(12, clock.mission_ticks);
}

test "the step reads the keyboard, and the latches it clears" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const keyboard = &devices.keyboard;
    keyboard.down[scan_test_key] = true;
    keyboard.latched[scan_test_key] = true;
    // Three ticks do no work, so the latch stands; the fourth reads and keeps it while held.
    clock.advanceTimer(3);
    _ = clock.runTicks(&devices, mission.world());
    try std.testing.expect(keyboard.latched[scan_test_key]);
    clock.advanceTimer(1);
    try std.testing.expectEqual(1, clock.runTicks(&devices, mission.world()));
    try std.testing.expect(keyboard.latched[scan_test_key]);
    // Released, the next read clears it.
    keyboard.down[scan_test_key] = false;
    clock.advanceTimer(4);
    _ = clock.runTicks(&devices, mission.world());
    try std.testing.expect(!keyboard.latched[scan_test_key]);
}

const scan_test_key: u8 = 0x10;

test "play time rolls a second over after 101 ticks" {
    var clock: Clock = .{};
    clock.advanceTimer(101);
    try std.testing.expectEqual(0, clock.play.ticks);
    try std.testing.expectEqual(1, clock.play.seconds);
    // A minute takes 60 of those seconds, and an hour 60 minutes.
    clock.advanceTimer(101 * 59);
    try std.testing.expectEqual(0, clock.play.seconds);
    try std.testing.expectEqual(1, clock.play.minutes);
    clock.advanceTimer(101 * 60 * 59);
    try std.testing.expectEqual(0, clock.play.minutes);
    try std.testing.expectEqual(1, clock.play.hours);
}

test "a frame measures the ticks since the last one" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    clock.advanceTimer(10);
    _ = clock.runTicks(&devices, mission.world());
    clock.frameBegin();
    try std.testing.expectEqual(10, clock.frame_duration);
    try std.testing.expectEqual(10, clock.frameTicks());
    try std.testing.expectEqual(10, clock.frame_start);
    // A frame with no tick between takes no time.
    clock.frameBegin();
    try std.testing.expectEqual(0, clock.frame_duration);
    clock.advanceTimer(3);
    _ = clock.runTicks(&devices, mission.world());
    clock.frameReset();
    try std.testing.expectEqual(13, clock.frame_start);
    try std.testing.expectEqual(0, clock.frame_duration);
}

test "the clocks keep to the platform's count however the frames fall" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const began: u64 = 12_345;
    clock.start(began);
    // Frames of uneven length: several shorter than a tick, one spanning many, one long stall.
    const frames = [_]u64{ 1, 0, 3, 1, 0, 0, 7, 2, 500, 1, 4, 0, 1 };
    var steps: u32 = 0;
    var now = began;
    for (frames) |frame| {
        now += frame;
        clock.advanceTo(now);
        steps += clock.runTicks(&devices, mission.world());
    }
    // Every hundredth between the first count and the last is a tick, and every fourth a step.
    const elapsed: u32 = @intCast(now - began);
    try std.testing.expectEqual(520, elapsed);
    try std.testing.expectEqual(elapsed, clock.timer_ticks);
    try std.testing.expectEqual(elapsed, clock.game_ticks);
    try std.testing.expectEqual(@as(i32, @intCast(elapsed)), clock.mission_ticks);
    try std.testing.expectEqual(elapsed / 4, steps);
    // Frames shorter than a tick neither run one nor lose one: the count rules.
    try std.testing.expectEqual(now, clock.timer_at);
}

test "the frame rate is decoupled from the tick rate" {
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    // The same second of play, drawn at three very different frame rates.
    const rates = [_]u64{ 4, 60, 240 };
    for (rates) |frames| {
        var clock: Clock = .{};
        clock.start(1_000);
        var steps: u32 = 0;
        var drawn: u32 = 0;
        for (1..frames + 1) |frame| {
            // Frame `frame` of `frames` ends this far into the second, in hundredths.
            clock.advanceTo(1_000 + @as(u64, @intCast(frame)) * 100 / frames);
            steps += clock.runTicks(&devices, mission.world());
            clock.frameBegin();
            drawn += 1;
        }
        // However often it drew, a second of play is 100 ticks and 25 simulation steps.
        try std.testing.expectEqual(frames, drawn);
        try std.testing.expectEqual(100, clock.game_ticks);
        try std.testing.expectEqual(100, clock.mission_ticks);
        try std.testing.expectEqual(25, steps);
    }
}

test "a frame faster than the tick runs none, and a slow one runs the lot" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    clock.start(0);
    // Four frames inside one hundredth: no tick falls in them, so the simulation stands still.
    for (0..4) |_| {
        clock.advanceTo(0);
        try std.testing.expectEqual(0, clock.runTicks(&devices, mission.world()));
        clock.frameBegin();
        try std.testing.expectEqual(0, clock.frame_duration);
    }
    // One frame that took a quarter of a second catches up all 25 ticks at once.
    clock.advanceTo(25);
    try std.testing.expectEqual(6, clock.runTicks(&devices, mission.world()));
    clock.frameBegin();
    try std.testing.expectEqual(25, clock.frame_duration);
}

test avoidanceScan {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const world = mission.world();
    const ship = try mission.addOther(@splat(0));
    const hull = try mission.addOther(.{ 0, 0, 10000 });
    const ahead = try mission.addOther(.{ 0, 0, 3000 });
    const far = try mission.addOther(.{ 0, 0, 900000 });
    // The player's ship, which `addOther` puts first, out of the way.
    objects.setPosition(&mission.slot(0).object, &mission.slot(0).drawn, .{ 500000, 0, 0 });
    mission.slot(hull).object.flags.components = true;
    mission.slot(hull).object.radius = 1000;
    mission.slot(ship).object.velocity = .{ .x = 0, .y = 0, .z = 50 };
    // Without an order that avoids, nothing is listed.
    avoidanceScan(world, ship);
    try std.testing.expectEqual(0, mission.slot(ship).object.avoid_near.count);
    // Flying, the hull within its widened reach and the ship ahead it would meet are, but not the
    // far one.
    _ = try aigeneric.pushShip(mission.orders(), ship, .fly, far, -1);
    avoidanceScan(world, ship);
    try std.testing.expectEqualSlices(i32, &.{hull}, mission.slot(ship).object.avoid_near.list());
    try std.testing.expectEqualSlices(i32, &.{ahead}, mission.slot(ship).object.avoid_ahead.list());
}
