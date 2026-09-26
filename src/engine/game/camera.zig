//! `C:\lancer\game\camera.cpp`: the views and where each puts the camera. `camera_set_view`
//! (`0x0045F1B0`) switches view, `camera_frame` (`0x0045FC90`) places the camera once a frame, and
//! `frame_controls` (`0x00414060`) picks views and steers the orbiting ones from the keyboard.

const std = @import("std");

const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const input = @import("../input.zig");
const controls = @import("../input/controls.zig");
const libcmt = @import("../libcmt.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const missiles = @import("missiles.zig");
const Vector = math.Vector;

/// The view table, which [`camera/views.zig`](camera/views.zig) transcribes.
pub const views = @import("camera/views.zig");
/// The director's shots, which the director's view shows.
pub const shots = @import("camera/shots.zig");
const director = @import("executor/director.zig");
const Matrix = math.Matrix;

/// Where the camera is and which way it looks.
pub const Place = math.Place;

// --- Projection ---------------------------------------------------------------------------------

/// The factors every view but `View.launch_bay` projects with (`sr_set_projection`): the screen
/// spans 5/6 of a view unit either side of the middle across and 5/8 up and down, square on a 4:3
/// screen: about 80 degrees across and 64 down.
pub const factors = [2]f32{ 0.6, 0.8 };

/// `View.launch_bay` projects wider, about 110 degrees across, over the whole screen.
pub const wide_factors = [2]f32{ 0.35, 0.467 };

/// The tenth of a pixel `sr_set_projection` takes off the screen's size before it scales it
/// (`0x004DC420`, `srapi.Projection.init`), which `unstretched` takes off likewise so that its
/// pixels come out square.
const projection_trim: f32 = 0.1;

/// The cinematic views' bars: the viewport leaves out this much of the screen at the top and the
/// bottom once they have slid in (`camera_frame`, `0x004DC420`).
pub const letterbox: f32 = 0.1;

/// OpenReliant's factors for a screen of any shape: the game's down, and across whatever keeps
/// pixels square. **Improvement:** the game uses its factors on every screen, which stretches the
/// picture on any but a 4:3 one; OpenReliant shows more at the sides instead. On a 4:3 screen the
/// factors are the game's to within a thousandth of a percent.
pub fn unstretched(width: u32, height: u32, base: [2]f32) [2]f32 {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    return .{ base[1] * (h - projection_trim) / (w - projection_trim), base[1] };
}

// --- Views --------------------------------------------------------------------------------------

/// A view, numbered as the game numbers them (`camera_view`, `0x00539A34`). The numbers not named
/// here are the game's cutaways: launches, landings, jumps, deaths and the like.
pub const View = enum(u8) {
    /// From the cockpit, ahead; `CockpitMode` says which of three ways.
    cockpit = 0,
    cockpit_left = 1,
    cockpit_right = 2,
    cockpit_rear = 3,
    /// Behind and above an object, lagging its turns.
    chase = 4,
    /// The chase view again, under a number of its own.
    chase_too = 0x1E,
    /// The first of a launch's three cutaways (`launch_reliant_run`), from inside the carrier's
    /// bay beside the ship, which projects wider than the rest (`wide_factors`) and tilts down
    /// after the ship as it drops out.
    launch_bay = 0x20,
    /// The second: from far below the ship, looking up at it as it drops out.
    launch_below = 0x21,
    /// The third: from beside and below the carrier, which the view shows whole, looking at the
    /// ship as it drops out.
    launch_aside = 0x22,
    /// The player's Jump Out ([jumps](../../../docs/engine/jump.md)): from out along each of the
    /// ship's axes where it began, watching it go.
    jump_out = 0x27,
    /// The first of three views the player's Jump In picks from at random: from close ahead of the
    /// ship and above it, looking back at it as it flies in, pulling away a little and shaking as
    /// hits shake the cockpit.
    jump_in_close = 0x17,
    /// The second: from far ahead, beyond where the ship arrives and below it, held, looking level
    /// in the ship's frame at where it came in from.
    jump_in_ahead = 0x18,
    /// The third: from beside where the ship arrives and above it, watching it fly in.
    jump_in_aside = 0x19,
    /// Around the player's target, looking at it, steered from the keyboard.
    target = 6,
    /// Around the player's ship, likewise.
    external = 0xC,
    /// The director's: the mission's script's shots (`shots`), each flown along the mission's
    /// curves or standing at a ship, locked, the ships each holds kept still. A ship keeps its
    /// undamaged speed in it (`ai.cruiseSpeed`), the player's engine and afterburner are not heard
    /// (`sound3d`), and CLOAK SHIP does nothing (`input.playerWeapons`).
    director = 0xD,
    /// Behind the camera's object, turning slowly with it and pulling away, as the player's ship is
    /// destroyed.
    pull_back = 8,
    /// Behind a missile.
    missile = 0x12,
    /// Circling the pilot's pod as the pilot ejects: Eject Camera.
    eject = 7,
    /// Round the ship picking the pilot's pod up, a Nanny or the enemy's Antanov, closing in.
    pickup = 0x1C,
    /// From behind the pilot's pod, at the Sabre that shoots it down, pulling back as it bursts.
    pod_shot = 0x1D,
    /// From where the camera was, watching its object.
    watch = 0x1A,
    /// From where the camera was, watching where the player's ship burst
    /// (`explode.Explosions.marker`).
    watch_marker = 0x1B,
    /// From a point the player flies past.
    flyby = 0x24,
    /// **Unknown:** two views after the fly-by that share its name, which `hud_draw` leaves unnamed
    /// with it.
    _unknown_37 = 0x25,
    _unknown_38 = 0x26,
    /// **Unknown:** in which the player's own ship is heard flying past no more than from the
    /// cockpit (`sound3d_engine_update`).
    _unknown_15 = 0x0F,
    _,

    /// The view's record in the view table (`0x004F72A8`), or null for a number past it, which
    /// `camera_set_view` stops the game for as an invalid camera type.
    pub fn record(view: View) ?views.Record {
        const n = @intFromEnum(view);
        return if (n < views.records.len) views.records[n] else null;
    }

    /// Whether the bars slide in: for the cutaways from 7 to `0x27` and `0x2B`, but not the
    /// external view.
    pub fn letterboxed(view: View) bool {
        return if (view.record()) |found| found.bars else false;
    }

    /// Whether the view is from the cockpit, so the object's own model is not drawn: views 0 to 3.
    pub fn fromCockpit(view: View) bool {
        return if (view.record()) |found| found.cockpit else false;
    }

    /// The language string that names the view, which `hud_draw` shows at the top of the screen
    /// in every view but the one ahead from the cockpit.
    pub fn name(view: View) ?u16 {
        return if (view.record()) |found| found.name else null;
    }

    /// Whether the player's missile lock builds and its rings show in the view: the cockpit's
    /// views and the chase view, views 0 to 4 (`mission_frame`, `0x004933D7`), but not the chase
    /// view under its second number.
    pub fn showsLock(view: View) bool {
        return switch (view) {
            .cockpit, .cockpit_left, .cockpit_right, .cockpit_rear, .chase => true,
            else => false,
        };
    }

    /// How far the view turns from ahead, about the object's down axis, in degrees: the cockpit's
    /// side and rear views, and no other (`camera_frame`'s table, `0x0045FC9B`).
    pub fn cockpitTurn(view: View) f32 {
        return switch (view) {
            .cockpit_left => -90,
            .cockpit_right => 90,
            .cockpit_rear => 180,
            else => 0,
        };
    }
};

/// What the cockpit view shows (`cockpit_mode`, `0x00539A9C`). The cockpit key cycles it while
/// that view is up; the options set it at the start of a mission.
/// Whether a view puts the camera in its ship's cockpit: one of the views from the cockpit, save
/// the view ahead in the chase mode.
pub fn inCockpit(view: View, mode: CockpitMode) bool {
    return view.fromCockpit() and !(view == .cockpit and mode == .chase);
}

pub const CockpitMode = enum(u2) {
    /// From the eye, with no cockpit drawn.
    open = 0,
    /// From the eye, with the cockpit's model over the view (hardware renderers only).
    cockpit = 1,
    /// The chase view instead.
    chase = 2,

    pub fn next(mode: CockpitMode) CockpitMode {
        return switch (mode) {
            .open => .cockpit,
            .cockpit => .chase,
            .chase => .open,
        };
    }
};

/// The options' cockpit setting (`cockpit_mode_setting`, `0x005D5A78`), which the game keeps in
/// its ini as `[Device] View`, 0 when the ini has none.
pub const CockpitSetting = enum(u32) {
    cockpit = 0,
    chase = 1,
    none = 2,
    _,

    /// The cockpit mode a mission's launch ends in (`launch_reliant_run`, `0x0041B240`), as it switches
    /// the camera from the launch's cutaway to view 0: the cockpit's model for 0, the chase view
    /// for 1, and no cockpit for any other.
    pub fn mode(setting: CockpitSetting) CockpitMode {
        return switch (setting) {
            .cockpit => .cockpit,
            .chase => .chase,
            else => .open,
        };
    }
};

/// The camera keys, in the order `frame_controls` reads them.
pub const camera_actions = [_]controls.Action{
    .cockpit_camera, .left_view_camera, .right_view_camera, .rear_view_camera,
    .flyby_camera,   .target_camera,    .external_camera,   .missile_camera,
};

/// The view the joystick's hat switches to (`frame_controls`) for each of its four straight
/// directions, given in DirectInput's hundredths of a degree clockwise from forward: the cockpit's
/// front, right, rear or left view. Diagonals and the center select nothing.
pub fn hatView(pov: u32) ?View {
    return switch (pov) {
        0 => .cockpit,
        9000 => .cockpit_right,
        18000 => .cockpit_rear,
        27000 => .cockpit_left,
        else => null,
    };
}

/// The view a camera key picks (`frame_controls`), or null for another action. The cockpit key
/// picks the cockpit view, and, pressed in it, cycles the cockpit mode.
pub fn keyView(action: controls.Action) ?View {
    return switch (action) {
        .cockpit_camera => .cockpit,
        .left_view_camera => .cockpit_left,
        .right_view_camera => .cockpit_right,
        .rear_view_camera => .cockpit_rear,
        .flyby_camera => .flyby,
        .target_camera => .target,
        .external_camera => .external,
        .missile_camera => .missile,
        else => null,
    };
}

// --- The camera ---------------------------------------------------------------------------------

/// What a view reads of an object.
pub const Subject = struct {
    position: Vector,
    orientation: Matrix,
    /// The model header's eye point.
    eye: Vector = @splat(0),
    /// `GameObject.radius`: its farthest vertex from its origin.
    radius: f32 = 0,
    motion: Chase.Motion = .{},
    /// Whether it is exploding, which the pod-shot view waits for.
    exploding: bool = false,

    /// Where it stands and how it is turned.
    pub fn place(subject: Subject) Place {
        return .{ .position = subject.position, .orientation = subject.orientation };
    }

    /// What the camera follows of the object in `slot`: where its root's frame has it drawn, its
    /// model's eye point and its size, and for the chase view its type, its throttle and its rates
    /// of turn.
    pub fn of(slot: *const create.Slot) Subject {
        const live = &slot.object;
        return .{
            .position = slot.drawn.position,
            .orientation = slot.drawn.orientation,
            .eye = if (slot.type) |loaded| gameobj.vector(loaded.model.header.eye) else @splat(0),
            .radius = live.radius,
            // The chase view sits farther back the more throttle the ship carries and swings
            // against its rates of turn, so it lags a turn rather than riding rigidly behind the
            // ship.
            .motion = .{
                .ship_type = live.type,
                .throttle = live.throttle,
                .afterburner = live.afterburner,
                .pitch_rate = live.pitch_rate,
                .yaw_rate = live.yaw_rate,
                .roll_rate = live.roll_rate,
            },
            .exploding = live.flags.exploding,
        };
    }
};

/// What `Camera.frame` reads of the world.
pub const World = struct {
    /// The object the view shows, `Camera.object`.
    object: Subject,
    /// The player's ship.
    player: Subject,
    /// The player's target, when it has one.
    target: ?Subject = null,
    /// Hundredths of a second since the last frame (`frame_duration`).
    ticks: u32,
    /// The mission's ticks this frame (`frame_start`), which the views that move with time go by,
    /// from when the view was switched to.
    now: u32 = 0,
    /// How far past `now` the frame is drawn, as a share of a tick (`objects.pastTick`), which
    /// those views go on by as well.
    ///
    /// **Improvement:** with smooth motion the views that move with time move on every frame, as
    /// the objects they watch do; the game moves them on a tick at a time, which a display's frames
    /// fall between unevenly.
    ahead: f32 = 0,
    /// Where the player's ship burst, for `watch_marker`; null before it has.
    marker: ?Vector = null,
    /// The cockpit's model and what moves it, for view 0 outside the chase mode; null for an
    /// object with no cockpit.
    cockpit: ?Cockpit.Input = null,
    /// The runtime's `rand`, which the cockpit's jitter and the shake from hits draw on.
    random: ?*libcmt.Rand = null,
    /// Whether the player's ship has begun to drop out of its carrier's bay, which the bay view
    /// tilts down after (`launch.dropping`).
    dropping: bool = false,
    /// What the mission's scene shows, which the view aside shows whole each frame; null where
    /// there is no scene.
    showing: ?*@import("main.zig").Showing = null,
    /// The force feedback the player's controller plays, which the shake from hits shakes too.
    forces: ?*input.force.Forces = null,
    /// The game's world, through which the director's view flies along the mission's curves; null
    /// where no game runs, as in a test.
    game: ?gameobj.World = null,
};

/// The camera: the state `camera_set_view` and `camera_frame` keep in globals, and Surrender's
/// camera frame they place, with the cockpit's model it moves in view 0. Leaves out the views not
/// named in `View`, and the shake from hits in any view but 0.
pub const Camera = struct {
    place: Place = .{ .position = @splat(0), .orientation = math.identity },
    view: View = .cockpit,
    /// The object the view shows (`camera_object`, `0x00539A8C`).
    object: ?u16 = null,
    cockpit_mode: CockpitMode = .open,
    /// The options' cockpit setting (`cockpit_mode_setting`, `0x005D5A78`), which the video screen
    /// changes: a mission's start, and the end of the player's launch, put the camera in the
    /// cockpit mode it picks (`CockpitSetting.mode`).
    setting: CockpitSetting = .cockpit,
    /// Set while a script holds the camera (`0x00539ACC`): the camera keys do nothing.
    locked: bool = false,
    /// How much of the screen each bar covers (`0x00539A38`), and how fast they move
    /// (`0x00539A50`).
    bars: f32 = 0,
    bar_speed: f32 = 0,
    /// `frame_start` when the view last changed (`0x00539AA4`).
    switched: u32 = 0,
    /// Where the ejection's views stand off from what they watch, as they are switched to
    /// (`0x00539A44`): the eject view's reach out to its object's right, the pickup's way to half
    /// between the picking ship and the pod, and the pod shot's way from the pod to the Sabre.
    cutaway: Vector = @splat(0),
    chase: Chase = .{},
    orbit: Orbit = .{},
    /// How hard the last hit shook the camera (`hit_shake`, `0x00588724`): at most 2, and less by
    /// 0.02 a tick.
    hit_shake: f32 = 0,
    /// The guns' kick on the cockpit's hands (`0x005636E0`): 1 as the player's guns fire
    /// (`0x0047BE3A`), and a twentieth less each frame.
    recoil: f32 = 0,
    /// Where the cockpit's model stands this frame, in view 0 outside the chase mode; null in the
    /// rest.
    cockpit_place: ?Cockpit.Placed = null,
    /// Set while the joystick's hat is held (`0x0051CF8C`), so that the view returns to the front
    /// when it is released.
    hat_glancing: bool = false,
    /// The missiles in flight, which the missile view follows one of: the record it follows
    /// (`camera_missile`, `0x00539A94`), and whether that has ended (`0x00539A7C`), after which the
    /// camera holds still for `missile_linger` ticks and goes back to the cockpit.
    missiles: ?*const missiles.Missiles = null,
    missile: u8 = 0,
    missile_gone: bool = false,
    /// The director's shots waiting, and what the director keeps of the one on screen.
    shots: shots.Shots = .{},
    director: director.Director = .{},
    /// The ships the director's shot on screen holds still (`camera_held_kind`, `0x00539A30`, and
    /// `camera_held_index`, `0x00539A40`), and those the first shot waiting holds, as the view
    /// takes it (`camera_shot_hold_kind`, `0x00539A5C`, and `camera_shot_hold_index`,
    /// `0x00539938`).
    held: ?shots.Held = null,
    holding: ?shots.Held = null,
    /// Set as the view switches, which resets the star streaks (`backdrop_reset_streaks`), so that
    /// the frame drawn next draws none, even where the view switches back to what it was.
    cut: bool = false,

    /// Bars grow this share of the screen a tick, times their speed (`camera_frame`, `0x004DC418`).
    pub const bar_rate: f32 = 0.001;

    /// Switches view (`camera_set_view`): `object` is the one the view shows, `lock` keeps the
    /// camera keys off it. Refused while the camera is locked, unless `force`. The game then
    /// places the camera at once, as `frame` does, and has the stars draw no streaks this frame.
    ///
    /// The missile view follows the next missile in flight, from the one it last followed, that
    /// `object` launched; with none, it is refused. Out of the director's view, the ships its shot
    /// held go (`shots.Held.hold`), and into it, the shot's own are held.
    pub fn setView(camera: *Camera, view: View, object: ?u16, lock: bool, force: bool, now: u32) bool {
        if (camera.locked and !force) return false;
        if (view == .missile) {
            const records = camera.missiles orelse return false;
            camera.missile = nextMissile(records, camera.missile, object orelse return false) orelse return false;
            camera.missile_gone = false;
        }
        if (camera.view == .director) if (camera.held) |held| held.hold(false);
        camera.cut = true;
        if (view.letterboxed()) {
            camera.bar_speed = 1;
        } else {
            camera.bars = 0;
            camera.bar_speed = 0;
        }
        if (view == .chase and (camera.view != .chase or camera.object != object)) {
            camera.chase.distance = Chase.start_distance;
        }
        camera.locked = lock;
        camera.object = object;
        camera.switched = now;
        camera.view = view;
        switch (view) {
            .cockpit => if (camera.cockpit_mode == .chase) camera.chase.resetTurns(),
            .chase, .chase_too => camera.chase.resetTurns(),
            .target, .external => camera.orbit = .{},
            .director => {
                camera.held = camera.holding;
                if (camera.held) |held| held.hold(true);
            },
            else => {},
        }
        return true;
    }

    /// Switches to one of the ejection's views, `view`, of `object`, locked and forced
    /// (`camera_set_view`), with what it stands off by taken from `seen`, the object, and `pod`,
    /// the pilot's, as they stand now.
    pub fn setCutaway(camera: *Camera, view: View, object: u16, now: u32, seen: Subject, pod: Subject) bool {
        if (!camera.setView(view, object, true, true, now)) return false;
        camera.cutaway = switch (view) {
            .eject => math.xAxis(seen.orientation) * @as(Vector, @splat(eject_reach)),
            .pickup => (pod.position - seen.position) * @as(Vector, @splat(pickup_share)),
            .pod_shot => math.normalize(seen.position - pod.position),
            else => camera.cutaway,
        };
        return true;
    }

    /// Switches to one of a launch's views, `view`, of `object`, locked and forced
    /// (`camera_set_view`), placing the camera once where the view stands: the bay view beside
    /// `seen`, the object, on its left where `even_gate` and else on its right; the view from below
    /// under `player`, the player's ship, looking up at it; and the view aside beside and below the
    /// object. `frame` then turns it.
    pub fn setLaunch(camera: *Camera, view: View, object: u16, now: u32, seen: Subject, player: Subject, even_gate: bool) bool {
        if (!camera.setView(view, object, true, true, now)) return false;
        switch (view) {
            .launch_bay => {
                const across: Vector = .{ if (even_gate) -bay_offset[0] else bay_offset[0], bay_offset[1], bay_offset[2] };
                camera.place.position = seen.place().point(across);
            },
            // Looking at the player's ship (`camera_look_at_player`, `0x00461D00`).
            .launch_below => camera.place = lookingAt(player.place().point(below_offset), player.position),
            .launch_aside => camera.place.position = seen.place().point(aside_offset),
            else => {},
        }
        return true;
    }

    /// Switches to one of a jump's views, `view`, of `object`, locked and forced
    /// (`camera_set_view`), placing the camera once where the view stands: Jump Out's view
    /// `jump_out_reach` out from `seen`, the object, along each of its axes; the view ahead
    /// `jump_ahead_offset` from it, looking at it level in the frame of `player`, the player's ship;
    /// and the view aside `jump_aside_offset` from it. `frame` then moves it. The close view needs
    /// no placing: `frame` places it from the player's ship every frame, as it does at the switch.
    pub fn setJump(camera: *Camera, view: View, object: u16, now: u32, seen: Subject, player: Subject) bool {
        if (!camera.setView(view, object, true, true, now)) return false;
        switch (view) {
            .jump_out => camera.place.position = seen.place().point(@splat(jump_out_reach)),
            .jump_in_ahead => camera.place = levelLookingAt(seen.place().point(jump_ahead_offset), seen.position, player.orientation),
            .jump_in_aside => camera.place.position = seen.place().point(jump_aside_offset),
            else => {},
        }
        return true;
    }

    /// Whether `object` is not drawn because the camera is in its cockpit: `camera_set_view` sets
    /// the object's flag bit 0 then.
    pub fn inside(camera: Camera, object: u16) bool {
        return camera.object == object and inCockpit(camera.view, camera.cockpit_mode);
    }

    /// A camera key (`frame_controls`): the cockpit key, in the cockpit view, cycles the cockpit
    /// mode first. Returns the view to switch to, with the player's ship as its object for the
    /// views from it, or null for another action or while the camera is locked.
    pub fn key(camera: *Camera, action: controls.Action) ?View {
        const view = keyView(action) orelse return null;
        if (action == .cockpit_camera and camera.view == .cockpit and !camera.locked) {
            camera.cockpit_mode = camera.cockpit_mode.next();
            if (camera.cockpit_mode == .chase) camera.chase.distance = Chase.start_distance;
        }
        return view;
    }

    /// The camera's part of `frame_controls` for a frame `ticks` hundredths of a second long: in
    /// the target and external views, the arrow keys steer the orbit, with Shift up and down to
    /// zoom. With `HatEnable`, holding the hat in a straight direction switches to the matching
    /// cockpit view, and releasing it returns to the front view. Then each camera key that was
    /// pressed selects its view (the last one in the game's order wins), with `player` as the
    /// object. The keys are read in the game's order, since `key_pressed` clears latches.
    pub fn frameControls(camera: *Camera, devices: *input.Devices, player: u16, ticks: u32, now: u32) void {
        const keyboard = &devices.keyboard;
        if (camera.view == .target or camera.view == .external) {
            const scan = input.scan;
            var keys: Orbit.Keys = .{};
            if (keyboard.pressed(scan.left, .none, false)) {
                keys.left = true;
            } else if (keyboard.pressed(scan.right, .none, false)) {
                keys.right = true;
            }
            if (keyboard.pressed(scan.up, .shift, false)) {
                keys = .{ .left = keys.left, .right = keys.right, .up = true, .shift = true };
            } else if (keyboard.pressed(scan.down, .shift, false)) {
                keys = .{ .left = keys.left, .right = keys.right, .down = true, .shift = true };
            } else if (keyboard.pressed(scan.up, .none, false)) {
                keys.up = true;
            } else if (keyboard.pressed(scan.down, .none, false)) {
                keys.down = true;
            }
            camera.orbit.steer(keys, @floatFromInt(ticks));
        }
        var chosen: ?View = null;
        const glancing = camera.hat_glancing;
        camera.hat_glancing = false;
        if (devices.settings.hat_enabled and devices.joystick.hats != 0) {
            if (hatView(devices.joystick.state.pov[0])) |view| {
                chosen = view;
                camera.hat_glancing = true;
            }
        }
        if (glancing and !camera.hat_glancing) chosen = .cockpit;
        for (camera_actions) |action| {
            if (devices.active(action, true)) chosen = camera.key(action);
        }
        if (chosen) |view| _ = camera.setView(view, player, false, false, now);
    }

    /// How long the view has been up at `world`'s frame, in ticks: since it was switched to, and on
    /// by as much past the tick as the frame is drawn (`World.ahead`).
    fn shown(camera: Camera, world: World) f32 {
        return @as(f32, @floatFromInt(world.now -| camera.switched)) + world.ahead;
    }

    /// Places the camera for a frame (`camera_frame`): while it shakes from hits by more than
    /// `shake_rumbles`, plays the shake on the controller too (`force_shake`, `0x004BE000`); moves
    /// the bars, then puts the camera where the view says. Returns a view to switch to when this
    /// one cannot go on, as the game does.
    pub fn frame(camera: *Camera, world: World) ?View {
        if (world.forces) |forces| if (camera.hit_shake > shake_rumbles) forces.startUnlessPlaying(.shake, @intCast(world.now));
        const ticks: f32 = @floatFromInt(world.ticks);
        // What the shake from hits jitters by this frame, before it dies away some more.
        var shake: f32 = 0;
        if (camera.hit_shake > 0) {
            if (camera.hit_shake > Cockpit.shake_most) camera.hit_shake = Cockpit.shake_most;
            shake = camera.hit_shake * Cockpit.shake_share;
            camera.hit_shake -= ticks * Cockpit.shake_fade;
            if (camera.hit_shake < 0) camera.hit_shake = 0;
        }
        camera.cockpit_place = null;
        if (camera.bar_speed != 0) {
            camera.bars += ticks * camera.bar_speed * bar_rate;
            if (camera.bars >= 0) {
                if (camera.bars > letterbox) {
                    camera.bars = letterbox;
                    camera.bar_speed = 0;
                }
            } else {
                camera.bars = 0;
                camera.bar_speed = 0;
            }
        }
        switch (camera.view) {
            .cockpit => if (camera.cockpit_mode == .chase) {
                camera.place = camera.chase.frame(world.object.motion, world.object.position, world.object.orientation);
            } else {
                camera.place = cockpit(.cockpit, world.object.position, world.object.orientation, world.object.eye);
                if (world.cockpit) |model| camera.cockpit_place = Cockpit.place(model, &camera.recoil, shake, world.random);
                // The camera itself shakes with a hit, by what is left of it.
                if (shake > 0) camera.place.orientation = math.product(
                    Cockpit.jitter(camera.hit_shake * Cockpit.camera_shake, world.random),
                    camera.place.orientation,
                );
            },
            .cockpit_left, .cockpit_right, .cockpit_rear => |side| {
                camera.place = if (side == .cockpit_rear and world.object.motion.ship_type == .kamov)
                    kamovRear(world.object.position, world.object.orientation)
                else
                    cockpit(side, world.object.position, world.object.orientation, world.object.eye);
            },
            .chase, .chase_too => {
                if (!world.object.motion.ship_type.hasStats()) return .cockpit;
                camera.place = camera.chase.frame(world.object.motion, world.object.position, world.object.orientation);
            },
            .target => {
                const target = world.target orelse return .cockpit;
                camera.place = camera.orbit.place(.target, target.position, target.radius);
            },
            .external => camera.place = camera.orbit.place(.external, world.player.position, world.player.radius),
            .flyby => camera.place = flyby(camera.place.position, world.player.position, world.player.orientation, world.player.radius),
            .pull_back => camera.place = pullBack(world.object.position, world.object.orientation, camera.shown(world)),
            .eject => camera.place = ejected(camera.cutaway, world.object.position, camera.shown(world)),
            .pickup => camera.place = pickedUp(camera.cutaway, world.object.position, world.object.orientation, camera.shown(world)),
            .pod_shot => {
                // Until the pod bursts, the view holds its time at nothing.
                if (!world.player.exploding) camera.switched = world.now;
                const since = if (world.player.exploding) camera.shown(world) else 0;
                camera.place = podShot(camera.cutaway, world.player.position, world.object.position, since);
            },
            .launch_bay => {
                // Until the ship drops, the view holds its time at nothing.
                if (!world.dropping) camera.switched = world.now;
                const since = if (world.dropping) camera.shown(world) else 0;
                camera.place.orientation = math.product(world.player.orientation, math.fromAngles(bay_pitch - since * bay_tilt, 0, 0));
            },
            // `camera_ease_to_player` (`0x00461C60`) eases the view's angles toward looking at the
            // player's ship by a share, which every call gives as all the way: the look itself.
            .launch_below => camera.place = lookingAt(camera.place.position, world.player.position),
            .launch_aside => {
                if (world.showing) |showing| showing.* = .everything;
                camera.place = lookingAt(camera.place.position, world.player.position);
            },
            .jump_out => camera.place = lookingAt(camera.place.position, world.object.position),
            .jump_in_close => {
                camera.place = lookingAt(world.player.place().point(jumpCloseOffset(camera.shown(world))), world.player.position);
                // The camera shakes with a hit, as the cockpit's does.
                if (shake > 0) camera.place.orientation = math.product(
                    Cockpit.jitter(camera.hit_shake * Cockpit.camera_shake, world.random),
                    camera.place.orientation,
                );
            },
            .jump_in_ahead => {},
            .jump_in_aside => camera.place = lookingAt(camera.place.position, world.player.position),
            // The director moves the camera on; once its shot is over, and the view with it, the
            // next shot waiting begins.
            .director => if (world.game) |game| {
                director.frame(game, camera, world.ahead);
                if (camera.view != .director) {
                    camera.shots.pop();
                    shots.start(game, camera);
                }
            },
            .watch => camera.place = lookingAt(camera.place.position, world.object.position),
            .watch_marker => if (world.marker) |marker| {
                camera.place = lookingAt(camera.place.position, marker);
            },
            .missile => {
                if (camera.missile_gone) return if (camera.switched < world.now) .cockpit else null;
                const followed = if (camera.missiles) |records| records.records[camera.missile] else null;
                const missile = followed orelse {
                    camera.switched = world.now + missile_linger;
                    camera.missile_gone = true;
                    return null;
                };
                if (!world.object.motion.ship_type.hasStats()) return .cockpit;
                const object = &missile.slot.object;
                camera.place = camera.chase.follow(.{
                    .throttle = object.throttle,
                    .pitch_rate = object.pitch_rate,
                    .yaw_rate = object.yaw_rate,
                    .roll_rate = object.roll_rate,
                }, missile.slot.drawn.position, missile.slot.drawn.orientation);
            },
            else => {},
        }
        return null;
    }

    /// The projection for the view and the bars on a screen of `width` by `height`, unstretched:
    /// the bay view's wide over the whole screen, whatever the bars (`camera_frame`).
    pub fn projection(camera: Camera, width: u32, height: u32) srapi.Projection {
        if (camera.view == .launch_bay) return .init(width, height, .{ 0, 0, 1, 1 }, unstretched(width, height, wide_factors));
        return .init(width, height, .{ 0, camera.bars, 1, 1 - camera.bars }, unstretched(width, height, factors));
    }
};

/// How long the missile view holds still once its missile has ended, before it goes back to the
/// cockpit (`camera_frame`, `0x00460C90`).
const missile_linger = 150;

/// The next missile in flight after `from`, going round the records, that `launcher` launched
/// (`camera_set_view`), or null for none.
fn nextMissile(records: *const missiles.Missiles, from: u8, launcher: u16) ?u8 {
    var at = from;
    for (0..missiles.max_missiles) |_| {
        at = @intCast((@as(usize, at) + 1) % missiles.max_missiles);
        const missile = records.records[at] orelse continue;
        if (missile.launcher == launcher) return at;
    }
    return null;
}

/// How hard the camera shakes from hits before the controller shakes with it (`0x004DC420`).
const shake_rumbles: f32 = 0.1;

// --- Cockpit ------------------------------------------------------------------------------------

/// The Kamov's rear view is from this far along its back instead of from its eye (`camera_frame`,
/// `0x00461307`).
pub const kamov_rear_distance: f32 = 1500;

fn kamovRear(position: Vector, orientation: Matrix) Place {
    const turned = math.turned(orientation, .y, std.math.pi);
    return .{ .position = position + math.transform(turned, .{ 0, 0, kamov_rear_distance }), .orientation = turned };
}

/// The camera in a cockpit view: turned from the object's orientation by the view's turn
/// (`View.cockpitTurn`), and at its eye point, the model header's `eye`, turned likewise.
pub fn cockpit(view: View, position: Vector, orientation: Matrix, eye: Vector) Place {
    const turned = math.turned(orientation, .y, std.math.degreesToRadians(view.cockpitTurn()));
    return .{ .position = position + math.transform(turned, eye), .orientation = turned };
}

// --- The cockpit's model ------------------------------------------------------------------------

/// The cockpit's model as `camera_frame` moves it in view 0 outside the chase mode. The mission's
/// start makes an object of the ship's cockpit frame (`0x005883F4`) and hangs its root from the
/// camera's frame; each frame the camera sways the root against the ship's turns and slides it
/// with its speed, and turns the hands, its second part, with the stick.
pub const Cockpit = struct {
    /// How far the root turns against each rate of turn at its full: its pitch, its yaw and its
    /// roll.
    pub const sway: [3]f32 = .{ -0.1, -0.15, -0.1 };
    /// How far it slides back at the cruise speed.
    pub const slide: f32 = 50;
    /// How far the hands turn: their pitch with the ship's pitch rate, and their roll with its
    /// roll and its yaw rates together.
    pub const hands_pitch: f32 = 0.15;
    pub const hands_roll: f32 = 0.2;
    /// How far the guns' kick moves the hands back at its full, and what is left of it the frame
    /// after.
    pub const recoil_kick: f32 = 30;
    pub const recoil_fade: f32 = 0.95;
    /// The shake from a hit: `hit_shake` goes no higher than `shake_most` (`0x004DC480`) and dies
    /// away by `shake_fade` a tick (`0x004DC4AC`); the root jitters by a random share of
    /// `root_jitter_share` (`0x004DC408`) of `shake_share` of it (`0x004DC420`), up to half of that
    /// either way, and the camera by a share of `camera_shake` of what is left (`0x004DC754`).
    pub const shake_most: f32 = 2;
    pub const shake_share: f32 = 0.1;
    pub const shake_fade: f32 = 0.02;
    pub const camera_shake: f32 = 0.03;
    pub const root_jitter_share: f32 = 0.5;

    /// What moves the cockpit, and where its model stands.
    pub const Input = struct {
        /// The ship's rates of turn over its flight model's full ones: pitch, yaw and roll.
        rates: [3]f32,
        /// Its speed over its cruise speed (`object_cruise_speed`).
        speed: f32,
        /// The cockpit frame model's eye (its header's vector at `0x08`), which the root is set
        /// back by so that the eye stands at the camera.
        eye: Vector,
        /// Where the hands stand from the root, their part's position less the object's centre,
        /// and the point they turn about, their part's mount point.
        hands_origin: Vector,
        hands_pivot: Vector,
    };

    /// Where the root stands in the camera's frame, and the hands in the root's.
    pub const Placed = struct {
        root: Place,
        hands: Place,
    };

    /// Moves the cockpit for a frame. The rates and the speed count to 1 either way at most.
    pub fn place(model: Input, recoil: *f32, shake: f32, random: ?*libcmt.Rand) Placed {
        var rates = model.rates;
        for (&rates) |*rate| rate.* = std.math.clamp(rate.*, -1, 1);
        const speed = std.math.clamp(model.speed, -1, 1);
        const swayed = math.fromAngles(rates[0] * sway[0], rates[1] * sway[1], rates[2] * sway[2]);
        const root: Place = .{
            .position = Vector{ 0, 0, speed * slide } - model.eye,
            // The game halves each of the jitter's angles rather than the shake, which comes to the
            // same, since halving is exact.
            .orientation = math.product(jitter(shake * root_jitter_share, random), swayed),
        };

        const turn = math.fromAngles(rates[0] * hands_pitch, 0, (rates[2] + rates[1]) * hands_roll);
        var at = model.hands_origin;
        at[2] -= recoil.* * recoil_kick;
        recoil.* *= recoil_fade;
        // They turn about their mount point rather than their origin.
        at += model.hands_pivot - math.transform(turn, model.hands_pivot);
        return .{ .root = root, .hands = .{ .position = at, .orientation = turn } };
    }

    /// A turn of up to half of `amount` either way in yaw and in roll, as `camera_frame` draws two
    /// of `rand`'s numbers (`libcmt.Rand.centred`), the first for the roll. Without a `rand` it
    /// draws none, and does not turn.
    pub fn jitter(amount: f32, random: ?*libcmt.Rand) Matrix {
        const source = random orelse return math.identity;
        const roll = source.centred() * amount;
        const yaw = source.centred() * amount;
        return math.fromAngles(0, yaw, roll);
    }
};

test Cockpit {
    const model: Cockpit.Input = .{
        .rates = .{ 0, 0, 0 },
        .speed = 0,
        .eye = .{ 0, -100, 300 },
        .hands_origin = .{ 10, 20, 30 },
        .hands_pivot = .{ 0, 0, 50 },
    };
    // At rest the root stands back by the eye, unturned, and the hands where their part does.
    var recoil: f32 = 0;
    const still = Cockpit.place(model, &recoil, 0, null);
    try expectVector(.{ 0, 100, -300 }, still.root.position);
    try std.testing.expectEqual(math.identity, still.root.orientation);
    try expectVector(.{ 10, 20, 30 }, still.hands.position);

    // Flying at the cruise speed, the root slides 50 back; turning, it sways against the turn,
    // to no more than a full rate's worth.
    var moving = model;
    moving.speed = 3;
    moving.rates = .{ 2, 0, 0 };
    const swayed = Cockpit.place(moving, &recoil, 0, null);
    try expectVector(.{ 0, 100, -250 }, swayed.root.position);
    for (math.fromAngles(-0.1, 0, 0), swayed.root.orientation) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-6);

    // The guns' kick moves the hands back, and fades by a twentieth each frame.
    recoil = 1;
    const kicked = Cockpit.place(model, &recoil, 0, null);
    try expectVector(.{ 10, 20, 0 }, kicked.hands.position);
    try std.testing.expectApproxEqAbs(0.95, recoil, 1e-6);

    // The hands turn about their mount point: that point stays where it is.
    var turning = model;
    turning.rates = .{ 1, 0, 0 };
    const turned = Cockpit.place(turning, &recoil, 0, null);
    const pivot_after = turned.hands.position + math.transform(turned.hands.orientation, model.hands_pivot);
    try expectVector(model.hands_origin + model.hands_pivot - Vector{ 0, 0, 0.95 * 30 }, pivot_after);
}

test "the shake from a hit dies away and turns the camera" {
    var camera: Camera = .{ .hit_shake = 3 };
    var random: libcmt.Rand = .{};
    const ship: Subject = .{ .position = @splat(0), .orientation = math.identity };
    _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 10, .random = &random });
    // It goes no higher than 2, then dies away by 0.02 a tick.
    try std.testing.expectApproxEqAbs(1.8, camera.hit_shake, 1e-6);
    // The camera is turned off the ship's own orientation.
    try std.testing.expect(!std.meta.eql(math.identity, camera.place.orientation));
    // Without a cockpit model there is nothing to place.
    try std.testing.expectEqual(null, camera.cockpit_place);
}

// --- Chase --------------------------------------------------------------------------------------

/// The chase view (`camera_chase`, `0x0045ED60`): behind the object and above it, the farther the
/// more throttle, swinging with its turns. Its state carries from frame to frame and is smoothed
/// once a frame.
pub const Chase = struct {
    /// Along the object's forward axis; negative is behind.
    distance: f32 = start_distance,
    pitch: f32 = 0,
    yaw: f32 = 0,
    roll: f32 = 0,

    /// Where the camera starts on switching to the view, ahead of the object, to swing round
    /// (`chase_distance`, `0x004F72A4`, as the executable holds it).
    pub const start_distance: f32 = 1500;

    /// A ship type's height, negative for above, and distance behind at no throttle.
    pub const Offset = struct { height: f32, distance: f32 };

    /// The type's offset (`camera_chase`): the heights are its immediates, and the distances
    /// `0x004DC580`, `0x004DC438`, `0x004DC744` and `0x004DC740`.
    pub fn offset(ship_type: gameobj.Type) Offset {
        return switch (ship_type) {
            .grendel => .{ .height = -650, .distance = 1800 },
            .wolverine => .{ .height = -850, .distance = 2000 },
            .reaper => .{ .height = -800, .distance = 2400 },
            .kamov => .{ .height = -1000, .distance = 3400 },
            else => .{ .height = -750, .distance = 1800 },
        };
    }

    /// Farther back for each unit of throttle (`0x004DC5A8`); the afterburner counts as 1.5
    /// (`0x004DC4E0`).
    pub const throttle_distance: f32 = 400;
    pub const afterburner_throttle: f32 = 1.5;

    /// How the camera turns against the object's rates of turn, in radians per update, and how
    /// far it may: at most a sixteenth of a turn up or down and a tenth either way (`0x004F7288`
    /// to `0x004F72A0`, the limits each way).
    pub const pitch_swing: f32 = 5.7;
    pub const yaw_swing: f32 = 5;
    pub const roll_swing: f32 = 3;
    pub const pitch_limit: f32 = std.math.pi / 8.0;
    pub const turn_limit: f32 = std.math.pi / 5.0;

    /// What the pitch's swing is scaled by as the nose goes down, and as it goes up (`0x004DC4E0`,
    /// `0x004DC408`): nose up swings the camera a third as far as nose down.
    pub const nose_down_swing: f32 = 1.5;
    pub const nose_up_swing: f32 = 0.5;

    /// The share of the way to its target the distance, and the turns, go each frame (`0x004DC420`,
    /// `0x004DC474`).
    pub const distance_smoothing: f32 = 0.1;
    pub const turn_smoothing: f32 = 0.05;

    /// What the view follows of the object.
    pub const Motion = struct {
        ship_type: gameobj.Type = .predator,
        throttle: f32 = 0,
        afterburner: bool = false,
        pitch_rate: f32 = 0,
        yaw_rate: f32 = 0,
        roll_rate: f32 = 0,
    };

    /// Levels the swing, as switching to the view does (`0x0045ED40`).
    pub fn resetTurns(chase: *Chase) void {
        chase.pitch = 0;
        chase.yaw = 0;
        chase.roll = 0;
    }

    /// Places the camera for this frame and moves the state on.
    pub fn frame(chase: *Chase, motion: Motion, position: Vector, orientation: Matrix) Place {
        const to = offset(motion.ship_type);
        const throttle = if (motion.afterburner) afterburner_throttle else motion.throttle;
        chase.distance = math.lerp(chase.distance, -(throttle * throttle_distance + to.distance), distance_smoothing);

        var swing = swings(motion);
        swing.pitch *= if (swing.pitch < 0) nose_up_swing else nose_down_swing;
        chase.pitch = math.lerp(chase.pitch, swing.pitch, turn_smoothing);
        chase.yaw = math.lerp(chase.yaw, swing.yaw, turn_smoothing);
        // The roll goes toward the roll's swing and the yaw's together, adding in the game's order.
        chase.roll += (swing.roll - chase.roll + swing.yaw) * turn_smoothing;
        return chase.placed(position, orientation, to.height);
    }

    /// The missile view's `camera_frame` (`0x0045FC90`, view `0x12`): the chase view's, behind a
    /// missile, 800 back and 400 more at full throttle, 300 above, swinging ten times slower, and
    /// rolling with a twentieth of its yaw.
    pub fn follow(chase: *Chase, motion: Motion, position: Vector, orientation: Matrix) Place {
        chase.distance = math.lerp(chase.distance, -(motion.throttle * throttle_distance + missile_distance), distance_smoothing);
        const swing = swings(motion);
        chase.pitch = math.lerp(chase.pitch, swing.pitch, missile_smoothing);
        chase.yaw = math.lerp(chase.yaw, swing.yaw, missile_smoothing);
        chase.roll += swing.yaw * missile_roll + (swing.roll - chase.roll) * missile_smoothing;
        return chase.placed(position, orientation, missile_height);
    }

    /// Behind a missile at no throttle, and above it (`0x004DC5EC`); how far the missile view's
    /// swings go a frame (`0x004DC4D0`), and how much of its yaw it rolls with (`0x004DC474`).
    pub const missile_distance: f32 = 800;
    pub const missile_height: f32 = -300;
    pub const missile_smoothing: f32 = 0.005;
    pub const missile_roll: f32 = 0.05;

    /// The swings the object's rates of turn ask for, each within its limit.
    fn swings(motion: Motion) struct { pitch: f32, yaw: f32, roll: f32 } {
        return .{
            .pitch = std.math.clamp(-pitch_swing * motion.pitch_rate, -pitch_limit, pitch_limit),
            .yaw = std.math.clamp(-yaw_swing * motion.yaw_rate, -turn_limit, turn_limit),
            .roll = std.math.clamp(-roll_swing * motion.roll_rate, -turn_limit, turn_limit),
        };
    }

    /// The camera `height` below the object and `distance` along it, swung by the pitch and then
    /// the yaw, and rolled by the roll.
    fn placed(chase: *const Chase, position: Vector, orientation: Matrix, height: f32) Place {
        const swung = math.turned(math.turned(orientation, .x, chase.pitch), .y, chase.yaw);
        return .{
            .position = position + math.transform(swung, .{ 0, height, chase.distance }),
            .orientation = math.turned(orientation, .z, chase.roll),
        };
    }
};

// --- Orbit --------------------------------------------------------------------------------------

/// The target and external views: the camera goes round an object, in the world's axes, and looks
/// at it. The arrow keys turn it, Shift with up or down moves it in or out. Its state is reset on
/// switching to either view.
pub const Orbit = struct {
    /// Degrees about `Y`, from 0 to 360.
    yaw: f32 = 0,
    /// Degrees about `X`, from -89.5 to 89.5.
    pitch: f32 = 0,
    /// Degrees a tick.
    yaw_speed: f32 = 0,
    pitch_speed: f32 = 0,
    /// Kept between `near` and the view's farthest, in the object's radii.
    distance: f32 = 0,

    /// How fast the arrow keys speed its turns up and let them settle, in degrees a tick for each
    /// tick, and how fast they turn it at most (`frame_controls`: `0x004DC420`, `0x004DC474`, and
    /// immediates at `0x004140ED`); how far up or down it goes (`0x004DC558`); and a full turn
    /// about `Y` (`0x004DC3E0`).
    pub const acceleration: f32 = 0.1;
    pub const deceleration: f32 = 0.05;
    pub const max_speed: f32 = 5;
    pub const max_pitch: f32 = 89.5;
    pub const full_turn: f32 = 360;
    /// Units a tick, with Shift held (`0x004DC560`).
    pub const zoom_speed: f32 = 60;

    /// The nearest it comes, and the farthest in the target view and in the external view, in the
    /// object's radii (`camera_frame`: `0x004DC794`, `0x004DC790`, `0x004DC78C`).
    pub const near: f32 = 1.8;
    pub const target_far: f32 = 5.8;
    pub const external_far: f32 = 3.8;

    pub fn far(view: View) f32 {
        return if (view == .target) target_far else external_far;
    }

    /// The keys that steer it, held this frame.
    pub const Keys = struct {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        shift: bool = false,
    };

    /// Steers the orbit for a frame `ticks` hundredths of a second long.
    pub fn steer(orbit: *Orbit, keys: Keys, ticks: f32) void {
        if (keys.left) {
            orbit.yaw_speed -= ticks * acceleration;
        } else if (keys.right) {
            orbit.yaw_speed += ticks * acceleration;
        }
        orbit.yaw_speed = settle(std.math.clamp(orbit.yaw_speed, -max_speed, max_speed), ticks);
        orbit.yaw += ticks * orbit.yaw_speed;
        if (orbit.yaw >= 0) {
            if (orbit.yaw > full_turn) orbit.yaw -= full_turn;
        } else {
            orbit.yaw += full_turn;
        }

        if (keys.shift and keys.up) {
            orbit.distance -= ticks * zoom_speed;
        } else if (keys.shift and keys.down) {
            orbit.distance += ticks * zoom_speed;
        } else if (keys.up) {
            orbit.pitch_speed += ticks * acceleration;
        } else if (keys.down) {
            orbit.pitch_speed -= ticks * acceleration;
        }
        orbit.pitch_speed = std.math.clamp(settle(orbit.pitch_speed, ticks), -max_speed, max_speed);
        orbit.pitch = std.math.clamp(orbit.pitch + ticks * orbit.pitch_speed, -max_pitch, max_pitch);
        if (@abs(orbit.pitch) == max_pitch) orbit.pitch_speed = 0;
    }

    /// A speed slowed toward 0 by the deceleration, stopping there.
    fn settle(speed: f32, ticks: f32) f32 {
        if (speed > 0) return @max(speed - ticks * deceleration, 0);
        if (speed < 0) return @min(speed + ticks * deceleration, 0);
        return 0;
    }

    /// Places the camera round an object of `radius` at `centre`, keeping the distance in range.
    pub fn place(orbit: *Orbit, view: View, centre: Vector, radius: f32) Place {
        orbit.distance = std.math.clamp(orbit.distance, radius * near, radius * far(view));
        const turn = math.turned(math.turned(math.identity, .y, std.math.degreesToRadians(orbit.yaw)), .x, std.math.degreesToRadians(orbit.pitch));
        const position = centre + math.transform(turn, .{ 0, 0, orbit.distance });
        return .{ .position = position, .orientation = math.lookAt(math.normalize(centre - position)) };
    }
};

// --- Pull back ---------------------------------------------------------------------------------

/// How `pull_back` starts behind the object and how fast it pulls away, a tick (`0x004DC508`,
/// `0x004DC788`).
const pull_back_distance: f32 = 3000;
const pull_back_speed: f32 = 10;
/// How fast `pull_back` and `eject` turn about their object, a tick (`0x004DC4D0`).
const slow_turn: f32 = 0.005;

/// View `pull_back` (`camera_frame`, view 8), `since` ticks after it was switched to: looking along
/// the object's heading turned about its own `Y`, from behind it along that heading.
pub fn pullBack(position: Vector, orientation: Matrix, since: f32) Place {
    return behind(position, orientation, since * slow_turn, pull_back_distance + since * pull_back_speed);
}

/// Turned as `orientation` turned by `angle` about its own `Y`, and standing `back` behind `point`
/// along its axis ahead, so looking at it: views 8 and `0x1C`.
fn behind(point: Vector, orientation: Matrix, angle: f32, back: f32) Place {
    const turned = math.turned(orientation, .y, angle);
    return .{ .position = point - math.forward(turned) * @as(Vector, @splat(back)), .orientation = turned };
}

/// Standing at `at` and looking at `target`, with no roll (`mat3_look_at`): the views that watch a
/// point from where they stand.
pub fn lookingAt(at: Vector, target: Vector) Place {
    return .{ .position = at, .orientation = math.lookAt(target - at) };
}

test pullBack {
    // It starts behind the object, looking along its heading, and pulls away as it turns.
    const start = pullBack(.{ 0, 0, 100 }, math.identity, 0);
    try std.testing.expectEqual(Vector{ 0, 0, 100 - pull_back_distance }, start.position);
    const later = pullBack(.{ 0, 0, 100 }, math.identity, 100);
    const away = later.position - Vector{ 0, 0, 100 };
    try std.testing.expectApproxEqAbs(pull_back_distance + 100 * pull_back_speed, @sqrt(math.dot(away, away)), 1e-2);
    try std.testing.expect(later.position[0] != 0);
}

// --- The launch ---------------------------------------------------------------------------------

/// Where the launch's views stand, in the frame of what they watch as they are switched to
/// (`camera_set_view`): the bay view 750 to the side of its ship, 600 above it and 300 behind
/// (`0x0045F6BF`), on the left for a gate of even number; the view from below 600 to the right of
/// the player's ship, 10000 below it and 100 ahead (`0x0045F737`); and the view aside 1700 to the
/// left of its ship and 6000 below (`0x0045F7B0`).
const bay_offset: Vector = .{ 750, -600, -300 };
const below_offset: Vector = .{ 600, 10000, 100 };
const aside_offset: Vector = .{ -1700, 6000, 0 };

/// How far down the bay view looks, turned about the player's ship's X axis from its nose
/// (`0x004DC760`), and how much further it tilts a tick once the ship drops (`0x004DC764`).
/// **Improvement:** 54 degrees, which the game rounds to 0.942478.
const bay_pitch: f32 = std.math.degreesToRadians(-54.0);
const bay_tilt: f32 = 0.0007;

// --- The jumps ----------------------------------------------------------------------------------

/// How far out along each of its ship's axes Jump Out's view stands (`camera_set_view`,
/// `0x0045FB18`).
const jump_out_reach: f32 = 8000;

/// Where the arrival's views stand from the player's ship as they are switched to, while it stands
/// far behind where it arrives (`jump.arrival_distance`): the view ahead 300 below it and 27000
/// ahead (`0x0045F8E7`), and the view aside 2000 to its left, 100 above it and 25000 ahead
/// (`0x0045F91E`).
const jump_ahead_offset: Vector = .{ 0, 300, 27000 };
const jump_aside_offset: Vector = .{ -2000, -100, 25000 };

/// The close view (`camera_frame`, `0x00460EC5`): 200 to the right of the player's ship and 500
/// above it (`0x00460F1A`), and ahead of it by `jump_close_near` for its first `jump_close_hold`
/// ticks, then by `jump_close_pull` a tick more until `jump_close_end`, and by `jump_close_far`
/// from then on (`0x00460ED2`, `0x004DC48C`, `0x004DC520`, `0x004DC75C`, `0x00460F09`).
const jump_close_side: f32 = 200;
const jump_close_height: f32 = -500;
const jump_close_near: f32 = 1200;
const jump_close_hold: f32 = 50;
const jump_close_pull: f32 = 10;
const jump_close_end: f32 = 70;
const jump_close_far: f32 = 1400;

/// Where the close view stands from the player's ship, `since` ticks after it was switched to.
fn jumpCloseOffset(since: f32) Vector {
    const ahead = if (since < jump_close_hold)
        jump_close_near
    else if (since < jump_close_end)
        (since - jump_close_hold) * jump_close_pull + jump_close_near
    else
        jump_close_far;
    return .{ jump_close_side, jump_close_height, ahead };
}

/// Standing at `at` and looking at `target`, with no roll in the frame `upright` turns to
/// (`camera_set_view`, `0x0045F956`): the look is taken between the two points turned back into
/// that frame, and turned out of it again.
fn levelLookingAt(at: Vector, target: Vector, upright: Matrix) Place {
    return .{ .position = at, .orientation = math.product(upright, math.lookAt(math.transformTransposed(upright, target - at))) };
}

test "Jump Out's view watches its ship go" {
    var camera: Camera = .{};
    const turned = math.rotation(.y, 1);
    const ship: Subject = .{ .position = .{ 100, 200, 300 }, .orientation = turned };
    try std.testing.expect(camera.setJump(.jump_out, 3, 10, ship, ship));
    try std.testing.expect(camera.locked);
    try expectVector(ship.place().point(@splat(jump_out_reach)), camera.place.position);
    // As the ship goes, the camera stays and turns after it.
    const gone: Subject = .{ .position = .{ 100, 200, 50000 }, .orientation = turned };
    _ = camera.frame(.{ .object = gone, .player = gone, .ticks = 1, .now = 20 });
    try expectVector(ship.place().point(@splat(jump_out_reach)), camera.place.position);
    try expectVector(math.normalize(gone.position - camera.place.position), math.forward(camera.place.orientation));
}

test "the arrival's views" {
    const turned = math.product(math.rotation(.x, 0.5), math.rotation(.y, 1));
    const ship: Subject = .{ .position = .{ 1000, -2000, 3000 }, .orientation = turned };

    // Close: ahead of the ship, looking back at it, pulling away between 50 and 70 ticks in.
    var close: Camera = .{};
    try std.testing.expect(close.setJump(.jump_in_close, 0, 100, ship, ship));
    for ([_]struct { u32, f32 }{ .{ 100, 1200 }, .{ 150, 1200 }, .{ 160, 1300 }, .{ 170, 1400 }, .{ 400, 1400 } }) |at| {
        _ = close.frame(.{ .object = ship, .player = ship, .ticks = 1, .now = at[0] });
        try expectVector(ship.place().point(.{ 200, -500, at[1] }), close.place.position);
        try expectVector(math.normalize(ship.position - close.place.position), math.forward(close.place.orientation));
    }

    // Ahead: held where it was put, level in the ship's frame, looking at where the ship was.
    var ahead: Camera = .{};
    try std.testing.expect(ahead.setJump(.jump_in_ahead, 0, 100, ship, ship));
    const held = ahead.place;
    try expectVector(ship.place().point(jump_ahead_offset), held.position);
    try expectVector(math.normalize(ship.position - held.position), math.forward(held.orientation));
    try std.testing.expectApproxEqAbs(0, math.dot(math.xAxis(held.orientation), math.yAxis(turned)), 1e-5);
    const moved: Subject = .{ .position = ship.place().point(.{ 0, 0, 25000 }), .orientation = turned };
    _ = ahead.frame(.{ .object = moved, .player = moved, .ticks = 1, .now = 200 });
    try std.testing.expectEqual(held, ahead.place);

    // Aside: where it was put, watching the ship fly in.
    var aside: Camera = .{};
    try std.testing.expect(aside.setJump(.jump_in_aside, 0, 100, ship, ship));
    _ = aside.frame(.{ .object = moved, .player = moved, .ticks = 1, .now = 200 });
    try expectVector(ship.place().point(jump_aside_offset), aside.place.position);
    try expectVector(math.normalize(moved.position - aside.place.position), math.forward(aside.place.orientation));
}

// --- The ejection -------------------------------------------------------------------------------

/// How far out to its object's right the eject view stands (`0x0045F479`).
const eject_reach: f32 = 5000;

/// View `eject` (`camera_frame`, view 7), `since` ticks after it was switched to: `cutaway` out
/// from the pod at `position`, turned about the world's `Y` by `slow_turn` a tick, looking at the
/// pod.
pub fn ejected(cutaway: Vector, position: Vector, since: f32) Place {
    return lookingAt(math.transform(math.rotation(.y, since * slow_turn), cutaway) + position, position);
}

/// The share of the way from the picking ship to the pod that the pickup view looks at
/// (`0x0045FAAC`); how fast it turns about the picking ship, a tick, and from where it starts
/// (`0x004DC74C`, `0x004DC51C`); and how far off it starts, how fast it closes in, a tick, and how
/// near it comes (`0x004DC43C`, `0x004DC44C`).
///
/// **Improvement:** it starts a quarter turn round exactly, where the game has 0.785398.
const pickup_share: f32 = 0.5;
const pickup_turn: f32 = 0.002;
const pickup_start: f32 = std.math.pi / 4.0;
const pickup_reach: f32 = 10000;
const pickup_closing: f32 = 2;
const pickup_nearest: f32 = 1000;

/// View `pickup` (view `0x1C`), `since` ticks after it was switched to: the picking ship's
/// orientation turned about its own `Y`, `pickup_start` on and more by `pickup_turn` a tick,
/// looking along it at `cutaway` from the ship at `position`, from `pickup_reach` off and closing.
pub fn pickedUp(cutaway: Vector, position: Vector, orientation: Matrix, since: f32) Place {
    const off = @max(pickup_reach - since * pickup_closing, pickup_nearest);
    return behind(cutaway + position, orientation, since * pickup_turn + pickup_start, off);
}

/// How far behind the pod the pod-shot view stands, and how fast it pulls back once the pod bursts,
/// a tick (`0x004DC44C`, `0x004DC72C`).
const pod_shot_reach: f32 = 1000;
const pod_shot_pull: f32 = 20;

/// View `pod_shot` (view `0x1D`), `since` ticks after the pod at `pod` began to burst:
/// `pod_shot_reach` and more from it, the other way from `cutaway`, the way to the Sabre, looking
/// at the Sabre at `sabre`.
pub fn podShot(cutaway: Vector, pod: Vector, sabre: Vector, since: f32) Place {
    return lookingAt(pod - cutaway * @as(Vector, @splat(pod_shot_reach + since * pod_shot_pull)), sabre);
}

test ejected {
    // Out to the right of the pod, looking at it, and a quarter turn round after a while.
    const start = ejected(.{ eject_reach, 0, 0 }, .{ 0, 0, 100 }, 0);
    try std.testing.expectEqual(Vector{ eject_reach, 0, 100 }, start.position);
    const quarter = std.math.pi / 2.0 / slow_turn;
    const later = ejected(.{ eject_reach, 0, 0 }, .{ 0, 0, 100 }, quarter);
    try std.testing.expectApproxEqAbs(0, later.position[0], 5);
    try std.testing.expectApproxEqAbs(eject_reach, @abs(later.position[2] - 100), 5);
    const looking = math.forward(later.orientation);
    try std.testing.expect(math.dot(looking, math.normalize(Vector{ 0, 0, 100 } - later.position)) > 0.999);
}

test pickedUp {
    // It starts out at its reach, closes in two a tick, and comes no nearer than its nearest.
    const cutaway: Vector = .{ 0, 0, 7500 };
    const start = pickedUp(cutaway, @splat(0), math.identity, 0);
    try std.testing.expectApproxEqAbs(pickup_reach, math.distance(start.position, cutaway), 1e-2);
    const later = pickedUp(cutaway, @splat(0), math.identity, 1000);
    try std.testing.expectApproxEqAbs(pickup_reach - 2000, math.distance(later.position, cutaway), 1e-2);
    const last = pickedUp(cutaway, @splat(0), math.identity, 100000);
    try std.testing.expectApproxEqAbs(pickup_nearest, math.distance(last.position, cutaway), 1e-2);
}

test "Camera.setCutaway" {
    var camera: Camera = .{};
    const turned: Subject = .{ .position = .{ 0, 0, 100 }, .orientation = math.rotation(.y, std.math.pi / 2.0) };
    const pod: Subject = .{ .position = .{ 0, 0, 1000 }, .orientation = math.identity };
    // The eject view stands off the object's right.
    try std.testing.expect(camera.setCutaway(.eject, 0, 10, turned, turned));
    try expectVector(math.xAxis(turned.orientation) * @as(Vector, @splat(eject_reach)), camera.cutaway);
    try std.testing.expect(camera.locked);
    try std.testing.expectEqual(10, camera.switched);
    // The pickup view looks halfway from the picking ship to the pod.
    try std.testing.expect(camera.setCutaway(.pickup, 1, 20, turned, pod));
    try expectVector(.{ 0, 0, 450 }, camera.cutaway);
    // The pod-shot view stands off the pod the other way from the Sabre.
    try std.testing.expect(camera.setCutaway(.pod_shot, 1, 30, turned, pod));
    try expectVector(.{ 0, 0, -1 }, camera.cutaway);
    // Locked as they are, only another forced switch takes the camera from them.
    try std.testing.expect(!camera.setView(.chase, 0, false, false, 40));
}

test "Camera.setLaunch" {
    var camera: Camera = .{};
    // The ship faces along the world's X axis, its own left along +Z.
    const ship: Subject = .{ .position = .{ 0, 0, 1000 }, .orientation = math.rotation(.y, std.math.pi / 2.0) };
    // The bay view stands beside it, on the left for a gate of even number, above and behind.
    try std.testing.expect(camera.setLaunch(.launch_bay, 0, 10, ship, ship, true));
    try expectVector(.{ -300, -600, 1750 }, camera.place.position);
    try std.testing.expect(camera.locked);
    try std.testing.expect(camera.setLaunch(.launch_bay, 0, 10, ship, ship, false));
    try expectVector(.{ -300, -600, 250 }, camera.place.position);
    // The view from below stands far under the player's ship, looking up at it.
    try std.testing.expect(camera.setLaunch(.launch_below, 0, 20, ship, ship, true));
    try expectVector(.{ 100, 10000, 400 }, camera.place.position);
    try expectVector(math.normalize(ship.position - camera.place.position), math.forward(camera.place.orientation));
    // The view aside stands to the ship's left and below it.
    try std.testing.expect(camera.setLaunch(.launch_aside, 0, 30, ship, ship, true));
    try expectVector(.{ 0, 6000, 2700 }, camera.place.position);
}

test "the launch's views follow the ship" {
    var camera: Camera = .{};
    var ship: Subject = .{ .position = .{ 0, 0, 1000 }, .orientation = math.identity };
    _ = camera.setLaunch(.launch_bay, 0, 10, ship, ship, true);
    // Until the ship drops, the bay view looks 54 degrees down from its nose, holding its time.
    _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 1, .now = 50 });
    try std.testing.expectEqual(50, camera.switched);
    const looking = math.forward(camera.place.orientation);
    try std.testing.expectApproxEqAbs(@sin(std.math.degreesToRadians(54.0)), looking[1], 1e-6);
    // Once it drops, the view tilts further down after it.
    _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 1, .now = 150, .dropping = true });
    try std.testing.expect(math.forward(camera.place.orientation)[1] > looking[1]);
    try std.testing.expectEqual(50, camera.switched);

    // The views from below and aside keep looking at the ship as it goes, the view aside showing
    // the whole scene.
    var showing: @import("main.zig").Showing = .launch;
    _ = camera.setLaunch(.launch_aside, 0, 200, ship, ship, true);
    ship.position = .{ 0, 3000, 1000 };
    _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 1, .now = 210, .showing = &showing });
    try expectVector(math.normalize(ship.position - camera.place.position), math.forward(camera.place.orientation));
    try std.testing.expectEqual(.everything, showing);
}

test "the views that move with time go on between ticks" {
    var camera: Camera = .{};
    const ship: Subject = .{ .position = .{ 0, 0, 100 }, .orientation = math.identity };
    // Half a tick past its hundredth, view 8 stands where it would a hundred and a half ticks on.
    _ = camera.setView(.pull_back, 0, true, true, 0);
    _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 1, .now = 100, .ahead = 0.5 });
    try expectVector(pullBack(ship.position, ship.orientation, 100.5).position, camera.place.position);
    // The pod-shot view holds at nothing until the pod bursts, the time past the tick with it.
    const sabre: Subject = .{ .position = .{ 0, 0, 5000 }, .orientation = math.identity };
    try std.testing.expect(camera.setCutaway(.pod_shot, 1, 0, sabre, ship));
    _ = camera.frame(.{ .object = sabre, .player = ship, .ticks = 1, .now = 200, .ahead = 0.5 });
    try expectVector(podShot(camera.cutaway, ship.position, sabre.position, 0).position, camera.place.position);
    try std.testing.expectEqual(200, camera.switched);
}

test podShot {
    // Behind the pod from the Sabre, looking at it, and pulling back once the pod bursts.
    const way = math.normalize(Vector{ 2, 1, -2 });
    const sabre = way * @as(Vector, @splat(30000));
    const start = podShot(way, @splat(0), sabre, 0);
    try std.testing.expectApproxEqAbs(pod_shot_reach, math.length(start.position), 1e-2);
    try std.testing.expect(math.dot(math.forward(start.orientation), way) > 0.999);
    const later = podShot(way, @splat(0), sabre, 100);
    try std.testing.expectApproxEqAbs(pod_shot_reach + 100 * pod_shot_pull, math.length(later.position), 1e-2);
}

// --- Flyby --------------------------------------------------------------------------------------

/// The flyby view stays where it is, looking at the player, until the player is farther than this
/// (`camera_frame`, `0x004DC778`); then it moves ahead of the player, a radius below and
/// `flyby_ahead` radii ahead (`0x004DC424`).
pub const flyby_range: f32 = 23000;
pub const flyby_ahead: f32 = 4;

/// Places the flyby camera, from where it was, for a ship at `position` with `orientation` and
/// `radius`. It never comes nearer than a radius.
pub fn flyby(from: Vector, position: Vector, orientation: Matrix, radius: f32) Place {
    var at = from;
    if (math.length(at - position) > flyby_range) {
        at = position + math.transform(orientation, .{ 0, radius, radius * flyby_ahead });
    }
    if (math.length(at - position) < radius) {
        at = position + math.normalize(at - position) * @as(Vector, @splat(radius));
    }
    return lookingAt(at, position);
}

fn expectVector(expected: Vector, actual: Vector) !void {
    inline for (0..3) |i| try std.testing.expectApproxEqAbs(expected[i], actual[i], 1e-3);
}

test unstretched {
    // At 4:3 the game's own; wider screens widen the view rather than stretch it.
    const four_three = unstretched(1024, 768, factors);
    try std.testing.expectApproxEqAbs(factors[0], four_three[0], 1e-4);
    const camera: Camera = .{};
    const sixteen_nine = camera.projection(1920, 1080);
    try std.testing.expectApproxEqAbs(sixteen_nine.scale[0], sixteen_nine.scale[1], 1e-3);
    try std.testing.expect(sixteen_nine.bounds[2] > 1.1);
    try std.testing.expectApproxEqAbs(0.625, sixteen_nine.bounds[3], 1e-4);
    // The bay view projects wider, over the whole screen whatever the bars.
    const wide: Camera = .{ .view = .launch_bay, .bars = letterbox };
    const bay = wide.projection(1024, 768);
    try std.testing.expect(bay.scale[1] < four_three[1] * 768);
    try std.testing.expectEqual(0, bay.viewport[1]);
    try std.testing.expectEqual(768, bay.viewport[3]);
}

test Camera {
    const ship: Subject = .{
        .position = .{ 0, 0, 1000 },
        .orientation = math.identity,
        .eye = .{ 0, -100, 300 },
        .radius = 500,
    };
    var camera: Camera = .{};
    try std.testing.expect(camera.setView(.cockpit, 0, false, false, 10));
    try std.testing.expectEqual(null, camera.frame(.{ .object = ship, .player = ship, .ticks = 3 }));
    try expectVector(.{ 0, -100, 1300 }, camera.place.position);
    try std.testing.expect(camera.inside(0));
    try std.testing.expect(!camera.inside(1));

    // The cockpit key in the cockpit view cycles the mode: to the cockpit model, then the chase.
    try std.testing.expectEqual(View.cockpit, camera.key(.cockpit_camera).?);
    try std.testing.expectEqual(CockpitMode.cockpit, camera.cockpit_mode);
    _ = camera.key(.cockpit_camera);
    try std.testing.expectEqual(CockpitMode.chase, camera.cockpit_mode);
    try std.testing.expect(!camera.inside(0));
    _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 3 });
    try std.testing.expect(camera.place.position[2] > 1000);

    // A locked camera refuses a switch unless forced; cutaways bring in the bars. A switch that
    // goes ahead is a cut, which the frame drawn next draws no streaks across.
    camera.cut = false;
    try std.testing.expect(camera.setView(.pull_back, 0, true, false, 20));
    try std.testing.expect(camera.cut);
    camera.cut = false;
    try std.testing.expect(!camera.setView(.external, 0, false, false, 30));
    try std.testing.expect(!camera.cut);
    try std.testing.expectEqual(1, camera.bar_speed);
    for (0..40) |_| _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 3 });
    try std.testing.expectEqual(letterbox, camera.bars);
    try std.testing.expectEqual(0, camera.bar_speed);
    try std.testing.expectApproxEqAbs(76.8, camera.projection(1024, 768).viewport[1], 1e-3);

    // Forced to the external view: bars gone, orbiting the player at the nearest it may.
    try std.testing.expect(camera.setView(.external, 0, false, true, 40));
    try std.testing.expectEqual(0, camera.bars);
    _ = camera.frame(.{ .object = ship, .player = ship, .ticks = 3 });
    try expectVector(.{ 0, 0, 1000 + 500 * Orbit.near }, camera.place.position);

    // The target view needs a target; without one it asks for the cockpit.
    _ = camera.setView(.target, 0, false, false, 50);
    try std.testing.expectEqual(View.cockpit, camera.frame(.{ .object = ship, .player = ship, .ticks = 3 }).?);
}

test View {
    try std.testing.expect(View.cockpit_rear.fromCockpit());
    try std.testing.expect(!View.chase.fromCockpit());
    try std.testing.expect(!View.external.letterboxed());
    try std.testing.expect(View.missile.letterboxed());
    try std.testing.expect(!View.target.letterboxed());
    // The last few views have no bars, but for the table's last.
    try std.testing.expect(!@as(View, @enumFromInt(0x28)).letterboxed());
    try std.testing.expect(@as(View, @enumFromInt(0x2B)).letterboxed());
    // A view past the table has no record.
    try std.testing.expectEqual(null, @as(View, @enumFromInt(0x2C)).record());
    try std.testing.expect(!@as(View, @enumFromInt(0x2C)).fromCockpit());
    // Each named view has its own string; the cutaways share theirs.
    try std.testing.expectEqual(170, View.cockpit.name().?);
    try std.testing.expectEqual(180, View.external.name().?);
    try std.testing.expectEqual(View.chase.name(), @as(View, @enumFromInt(0x0D)).name());
    // The lock shows from the cockpit's views and the chase view, but not under its second number.
    try std.testing.expect(View.cockpit_rear.showsLock() and View.chase.showsLock());
    try std.testing.expect(!View.chase_too.showsLock() and !View.target.showsLock());
    try std.testing.expectEqual(-90, View.cockpit_left.cockpitTurn());
    try std.testing.expectEqual(0, View.chase.cockpitTurn());
    try std.testing.expectEqual(View.external, keyView(.external_camera).?);
    try std.testing.expectEqual(null, keyView(.fire_lasers));
    try std.testing.expectEqual(CockpitMode.open, CockpitMode.chase.next());
    try std.testing.expectEqual(CockpitMode.cockpit, CockpitSetting.cockpit.mode());
    try std.testing.expectEqual(CockpitMode.chase, CockpitSetting.chase.mode());
    try std.testing.expectEqual(CockpitMode.open, CockpitSetting.none.mode());
    try std.testing.expectEqual(CockpitMode.open, @as(CockpitSetting, @enumFromInt(7)).mode());
}

test cockpit {
    const eye: Vector = .{ 0, -100, 300 };
    const ahead = cockpit(.cockpit, .{ 10, 0, 0 }, math.identity, eye);
    try expectVector(.{ 10, -100, 300 }, ahead.position);
    // Looking back, the eye point turns with the view.
    const rear = cockpit(.cockpit_rear, .{ 0, 0, 0 }, math.identity, eye);
    try expectVector(.{ 0, -100, -300 }, rear.position);
    try expectVector(.{ 0, 0, -1 }, math.transform(rear.orientation, .{ 0, 0, 1 }));
    // Looking left: forward turns to -X.
    try expectVector(.{ -1, 0, 0 }, math.transform(cockpit(.cockpit_left, @splat(0), math.identity, eye).orientation, .{ 0, 0, 1 }));
}

test Chase {
    var chase: Chase = .{};
    // Level flight at half throttle: the distance closes on -2000, a tenth of the way a frame.
    const still = chase.frame(.{ .throttle = 0.5 }, .{ 0, 0, 0 }, math.identity);
    try std.testing.expectApproxEqAbs(1500 + (-2000 - 1500) * 0.1, chase.distance, 1e-3);
    try expectVector(.{ 0, -750, chase.distance }, still.position);
    for (0..200) |_| _ = chase.frame(.{ .throttle = 0.5 }, .{ 0, 0, 0 }, math.identity);
    try std.testing.expectApproxEqAbs(-2000, chase.distance, 1e-2);

    // Turning, the camera swings the other way, within its limit.
    for (0..400) |_| _ = chase.frame(.{ .yaw_rate = 1 }, .{ 0, 0, 0 }, math.identity);
    try std.testing.expectApproxEqAbs(-Chase.turn_limit, chase.yaw, 1e-3);
    try std.testing.expectEqual(Chase.Offset{ .height = -1000, .distance = 3400 }, Chase.offset(.kamov));
}

test Orbit {
    var orbit: Orbit = .{};
    // Held right for a while, the orbit turns ever faster up to its limit, less the frame's
    // slowing, which comes after.
    for (0..100) |_| orbit.steer(.{ .right = true }, 3);
    try std.testing.expectApproxEqAbs(Orbit.max_speed - 3 * Orbit.deceleration, orbit.yaw_speed, 1e-5);
    // Let go, it slows to a stop.
    for (0..100) |_| orbit.steer(.{}, 3);
    try std.testing.expectEqual(0, orbit.yaw_speed);
    try std.testing.expect(orbit.yaw >= 0 and orbit.yaw < 360);
    // Pitched all the way, it stops at the limit.
    for (0..400) |_| orbit.steer(.{ .up = true }, 3);
    try std.testing.expectEqual(Orbit.max_pitch, orbit.pitch);

    var level: Orbit = .{};
    const place = level.place(.external, .{ 0, 0, 100 }, 50);
    // Pulled out to the nearest it may be, ahead along +Z, looking back at the centre.
    try std.testing.expectEqual(90, level.distance);
    try expectVector(.{ 0, 0, 190 }, place.position);
    try expectVector(.{ 0, 0, -1 }, math.transform(place.orientation, .{ 0, 0, 1 }));
}

test flyby {
    // Too far: the camera moves ahead of the ship, and looks back at it.
    const place = flyby(.{ 0, 0, 30000 + 23000 }, .{ 0, 0, 0 }, math.identity, 100);
    try expectVector(.{ 0, 100, 400 }, place.position);
    // Too near: it backs off to a radius.
    try expectVector(.{ 0, 0, 100 }, flyby(.{ 0, 0, 10 }, .{ 0, 0, 0 }, math.identity, 100).position);
}

test "Camera.frameControls" {
    var camera: Camera = .{};
    var devices: input.Devices = .{};
    const keyboard = &devices.keyboard;
    // The external camera's key, 7, picks its view once for the press.
    keyboard.down[controls.binding(.external_camera).key] = true;
    camera.frameControls(&devices, 0, 1, 100);
    try std.testing.expectEqual(View.external, camera.view);
    try std.testing.expectEqual(100, camera.switched);
    camera.switched = 0;
    camera.frameControls(&devices, 0, 1, 200);
    try std.testing.expectEqual(0, camera.switched);

    // In it, the left arrow turns the orbit.
    keyboard.down[input.scan.left] = true;
    camera.frameControls(&devices, 0, 10, 300);
    try std.testing.expect(camera.orbit.yaw_speed < 0);

    // The cockpit key, pressed in the cockpit view, cycles the cockpit mode.
    _ = camera.setView(.cockpit, 0, false, false, 0);
    keyboard.* = .{};
    keyboard.down[controls.binding(.cockpit_camera).key] = true;
    camera.frameControls(&devices, 0, 1, 400);
    try std.testing.expectEqual(CockpitMode.cockpit, camera.cockpit_mode);
}

test "the hat switches views while it is held" {
    var camera: Camera = .{};
    var devices: input.Devices = .{};
    devices.joystick.hats = 1;
    const pov = &devices.joystick.state.pov[0];

    // Holding the hat left selects the left view, again every frame.
    pov.* = 27000;
    camera.frameControls(&devices, 0, 1, 100);
    try std.testing.expectEqual(View.cockpit_left, camera.view);
    camera.frameControls(&devices, 0, 1, 200);
    try std.testing.expectEqual(200, camera.switched);
    // Releasing it returns to the front view; a diagonal selects nothing.
    pov.* = input.JoystickState.centred;
    camera.frameControls(&devices, 0, 1, 300);
    try std.testing.expectEqual(View.cockpit, camera.view);
    pov.* = 4500;
    camera.frameControls(&devices, 0, 1, 400);
    try std.testing.expectEqual(300, camera.switched);

    // Without HatEnable, the hat does nothing.
    pov.* = 18000;
    devices.settings.hat_enabled = false;
    camera.frameControls(&devices, 0, 1, 500);
    try std.testing.expectEqual(View.cockpit, camera.view);
    devices.settings.hat_enabled = true;
    camera.frameControls(&devices, 0, 1, 600);
    try std.testing.expectEqual(View.cockpit_rear, camera.view);
}

test "the missile view" {
    var armed: missiles.testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    const player = try armed.add(.friendly, @splat(0));
    const other = try armed.add(.hostile, .{ 0, 0, 50000 });
    var camera: Camera = .{ .missiles = &armed.mission.objects.missiles };
    // With none of the player's in flight, the view is refused.
    try std.testing.expect(!camera.setView(.missile, player, false, false, 0));
    missiles.launch(armed.mission.world(), other, 0, .none);
    missiles.launch(armed.mission.world(), player, 0, .none);
    try std.testing.expect(!camera.setView(.missile, other + 1, false, false, 0));
    // It follows the player's, behind and above it, easing out from where the chase view left it.
    try std.testing.expect(camera.setView(.missile, player, false, false, 0));
    try std.testing.expectEqual(1, camera.missile);
    const subject: Subject = .{ .position = @splat(0), .orientation = math.identity, .motion = .{ .ship_type = .predator } };
    try std.testing.expectEqual(null, camera.frame(.{ .object = subject, .player = subject, .ticks = 1, .now = 10 }));
    const missile = armed.missile(1);
    try std.testing.expectEqual(missile.slot.drawn.position[1] + Chase.missile_height, camera.place.position[1]);
    // Once it ends, the camera holds for a second and a half, then goes back to the cockpit.
    missiles.end(armed.mission.world(), 1);
    try std.testing.expectEqual(null, camera.frame(.{ .object = subject, .player = subject, .ticks = 1, .now = 20 }));
    try std.testing.expect(camera.missile_gone);
    try std.testing.expectEqual(null, camera.frame(.{ .object = subject, .player = subject, .ticks = 1, .now = 170 }));
    try std.testing.expectEqual(View.cockpit, camera.frame(.{ .object = subject, .player = subject, .ticks = 1, .now = 171 }).?);
}
