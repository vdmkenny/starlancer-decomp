//! The game's sound effects placed in 3D: shots, hits, explosions, the player's engine and the
//! ships flying past, each a definition of [`sound3d/sounds.zig`](sound3d/sounds.zig) played from
//! `smp3d.fat` on one of the 3D voices [`hog_snd.zig`](hog_snd.zig) opens. **Unverified:** which
//! source file this is; its code lies between `pilots.cpp`'s and `shield.cpp`'s (`0x0049D160` to
//! `0x0049E36F`), after the frame profiler, with no path of its own.

const std = @import("std");
const assert = std.debug.assert;

const fat = @import("../../formats/fat.zig");
const shp = @import("../../formats/shp.zig");
const libcmt = @import("../libcmt.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const mss = @import("../mss.zig");
const camera = @import("camera.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const hog_snd = @import("hog_snd.zig");
const Sound = hog_snd.Sound;
const Scene = hog_snd.Scene;

pub const sounds = @import("sound3d/sounds.zig");

/// What a sound's place comes from, as it starts and each frame after (`hog_snd.Sound.update3D`).
pub const Follows = enum(i32) {
    /// A voice with nothing on it.
    none = -1,
    /// A shot in flight, by its record in the bullet pool: where it is, and its heading.
    shot = 0,
    /// A point and a direction given as it starts, which the voice keeps.
    point_facing = 1,
    /// A point given as it starts, facing the listener.
    point = 2,
    /// A missile, by its record (`0x005887F0`, `0x28` bytes each): where it goes next as it
    /// starts, facing the way it flies, and there after, still; or with `MissileSound.follows`,
    /// where it is, its heading and its velocity.
    missile = 3,
    /// An object, by its slot: where it is, its heading and its velocity. The player's own sounds
    /// `player_sound_offset` from its ship.
    object = 4,
    _,
};

/// Where a missile's sound is heard from (`hog_snd.Sound.missile_sound`).
pub const MissileSound = enum {
    /// **Improvement:** from the missile as it flies, moving with it, so it can be told where it
    /// is and its pitch shifts as it passes; it ends with the missile, as `missile_end` would end
    /// the voice it held.
    follows,
    /// From where the missile was launched, still, as the original leaves it: `sound_3d_update`
    /// places a missile's voice no further, and nothing gives the missile its voice.
    stays,
};

/// **Improvement:** how much farther than its definition has it a missile's sound that follows it
/// keeps its full volume, so it carries a little as the missile flies off.
const followed_missile_reach: f32 = 1.5;

/// Where along its nose the player's own sounds are heard from its ship: `sound3d_play` starts
/// them this far ahead (an immediate in `sound3d_play`), and `sound_3d_update` places them as far
/// behind each frame after.
pub const player_sound_offset: Vector = .{ 0, 0, 200 };

/// The rate every 3D sound plays at (an immediate in `sound3d_play`), but the explosions: they play
/// at `explosion_rate` less a share drawn at random of `explosion_spread` (`0x004DC9B8`), which is
/// negative, so from 18,050 to 25,050.
pub const sample_rate = 22050;
const explosion_rate = 18050;
const explosion_spread: f32 = -7000;

/// Which of the 3D voices a sound may take (`0x0058CB1C`): voices set aside for a class, which
/// other sounds borrow only while they are free. The names are the executable's own (`0x00508614`).
pub const Class = enum(u8) {
    not_reserved = 0,
    player_guns = 1,
    player_fx = 2,
    explosions = 3,
    guaranteed = 4,
    /// The one voice of the player's engine (`hog_snd.Sound.engine_voice`).
    player_engines = 5,
    /// The one voice of its afterburner (`hog_snd.Sound.burner_voice`).
    player_burners = 6,
    flyby = 7,
    _,
};

/// A 3D sound's definition (`0x00507140`, `0x44` bytes each).
pub const Definition = extern struct {
    /// Its sound in `smp3d.fat`.
    entry: u32,
    /// Its share of the effects volume.
    volume: f32,
    /// Times it plays; 0 for ever.
    loop_count: u32,
    follows: Follows,
    /// Within this it is heard at its full volume, in the game's units.
    min_distance: f32,
    /// Beyond this it is not started, and a playing one is ended (`hog_snd.Sound.update3D`).
    max_distance: f32,
    /// Its cone, in degrees: at full volume within half the inner angle, at `cone_outer_volume`
    /// outside half the outer.
    cone_inner: f32,
    cone_outer: f32,
    /// Of 127.
    cone_outer_volume: f32,
    name: [32]u8,

    comptime {
        assert(@offsetOf(Definition, "follows") == 0x0C);
        assert(@offsetOf(Definition, "cone_outer_volume") == 0x20);
        assert(@sizeOf(Definition) == 0x44);
    }

    /// Its name, as the table has it, up to its first zero.
    pub fn nameText(definition: *const Definition) []const u8 {
        return std.mem.sliceTo(&definition.name, 0);
    }
};

/// How the player's engine sounds for its ship type (`0x00508740`, `0x00508774`, `0x005087A8` and
/// `0x005087DC`, 13 each): its playback rate and its volume, each at no throttle and what full
/// throttle adds.
pub const Engine = struct {
    rate: i32,
    rate_by_throttle: i32,
    volume: i32,
    volume_by_throttle: i32,
};

/// The voice classes, one row for each size of provider (`0x005085B4`): up to 14 voices, up to 30,
/// and more. A voice past the row's 32 has none.
pub const class_rows = 3;
pub const classes_per_row = 32;

/// The most voices of a provider that takes the first row of classes, and the second (immediates
/// in `sound3d_init`).
const first_row_voices = 14;
const second_row_voices = 30;

/// The 3D sounds' own state (`0x0050713C`, `0x0058CB00` on).
pub const Effects = struct {
    /// Set up for the open provider (`0x0058CB65`).
    ready: bool = false,
    /// `smp3d.fat` (`bank_smp3d`, `0x0058CB10`).
    bank: ?fat.Bank = null,
    /// Each 3D voice's class (`0x0058CB1C`).
    classes: [hog_snd.max_voices_3d]Class = @splat(.not_reserved),
    /// The player's engine sound (`0x0058CB04`), and when its afterburner last came on or went off
    /// (`0x0050713C`).
    engine: EngineState = .idle,
    engine_changed_at: i32 = -1,
};

pub const EngineState = enum(u32) {
    /// The engine's own sound, pitched and loudened by the throttle.
    idle = 0,
    /// The afterburner's or reverse thrust's, growing louder.
    burning = 1,
    /// The afterburner's fading out on its own voice, once let go.
    cooling = 3,
    _,
};

/// Whether the player's own ship is heard flying past in `view`: not from the cockpit, nor around
/// it, nor in view 15 (`sound3d_engine_update`).
fn hearsOwnFlyby(view: camera.View) bool {
    return !(view.fromCockpit() or view == .external or view == ._unknown_15);
}

/// The player's engine's sounds (`sound3d_engine_update`). The afterburner's own voice plays at
/// `burner_volume` times the engine's volume factor (`0x004DC75C`). Burning, its sound grows
/// from `burner_start` by `burner_growth` a tick (`0x004DC410`), rounded, to at most
/// `burner_most`; it is as loud as that and `burner_base` (`0x004DC9C0`) more, and plays at
/// `burner_rate` less `burner_pitch_step` (`0x004DC9BC`) for each, or at `reverse_rate` for
/// reverse thrust. Let go, it fades by `cooling_step` (`0x004DC9C4`) of the loudest a tick, and
/// ends past `cooling_ticks`. The integers are immediates in `sound3d_engine_update`.
const burner_volume: f32 = 70;
const burner_start = 5;
const burner_growth: f32 = 0.8;
const burner_most = 70;
const burner_base: f32 = 57;
const burner_rate = 12000;
const burner_pitch_step: f32 = -90;
const reverse_rate = 7000;
const cooling_step: f32 = 0.04;
const cooling_ticks = 25;

/// A fighter is heard flying past the camera within the square root of `flyby_reach_squared`
/// (`0x004DC878`), at a throttle of `flyby_throttle` (`0x004DC4DC`) or more and a speed of
/// `flyby_speed` (`0x004DC440`) or more, heading away from where the camera looks: no nearer it
/// than the cosine `hostile_flyby_cosine` (`0x004DC550`) for a hostile ship, or than a right
/// angle for the rest (`0x004DC3D0`). Each is heard once in `flyby_gap` ticks, or `own_flyby_gap`
/// for the player's own ship (immediates in `sound3d_engine_update`).
const flyby_reach_squared: f32 = 1e8;
const flyby_throttle: f32 = 0.4;
const flyby_speed: f32 = 100;
const hostile_flyby_cosine: f32 = 0.75;
const friendly_flyby_cosine: f32 = 0;
const flyby_gap = 500;
const own_flyby_gap = 200;

/// `sound3d_init` (`0x0049D160`), once a provider is open: `smp3d` the bank, each 3D voice given
/// its class from the row for as many voices as there are, and the engine's and the afterburner's
/// voice found. The game scales the table's distances into Miles's units here; OpenReliant scales
/// them where it uses them.
pub fn init(sound: *Sound, smp3d: fat.Bank) void {
    const effects = &sound.effects;
    effects.* = .{ .bank = smp3d };
    const count = sound.voice_3d_count;
    const row: usize = if (count > first_row_voices) (if (count > second_row_voices) 2 else 1) else 0;
    for (0..count) |v| {
        effects.classes[v] = if (v < classes_per_row) sounds.classes[row][v] else .not_reserved;
        sound.end3D(@intCast(v));
    }
    sound.engine_voice = null;
    sound.burner_voice = null;
    for (effects.classes[0..count], 0..) |class, v| switch (class) {
        .player_engines => sound.engine_voice = @intCast(v),
        .player_burners => sound.burner_voice = @intCast(v),
        else => {},
    };
    effects.ready = true;
}

/// `sound3d_end_all` (`0x0049D330`): every 3D voice playing is ended and freed.
pub fn endAll(sound: *Sound) void {
    for (0..sound.voice_3d_count) |v| sound.end3D(@intCast(v));
}

/// `sound3d_play` (`0x0049D360`): plays a sound, placed by what its definition follows: `owner`'s
/// shot or object, or `at` and `facing` for a point. `volume` is its share of the definition's
/// volume. It is not started beyond its maximum distance, but for the engines' sounds. It takes a
/// voice of `class`, else one not reserved, else borrows a free one of another class. Returns the
/// voice, or null.
///
/// The game passes a fourth argument it never reads.
pub fn play(sound: *Sound, scene: Scene, at: ?Vector, facing: ?Vector, owner: i32, which: sounds.Sound, volume: f32, class: Class) ?u8 {
    const driver = sound.driver orelse return null;
    if (!sound.effects.ready) return null;
    const bank = sound.effects.bank orelse return null;
    const definition = &sounds.definitions[@intFromEnum(which)];
    const level = sound.volumes.masterShare() * @as(f32, @floatFromInt(sound.volumes.effects)) * definition.volume * volume;

    var position: Vector = @splat(0);
    var velocity: Vector = @splat(0);
    var direction: ?Vector = null;
    var radius: f32 = 0;
    var followed: ?*gameobj.GameObject = null;
    var min_distance = definition.min_distance;
    switch (definition.follows) {
        .shot => {
            if (owner < 0 or owner >= scene.objects.bullets.pool.len) return null;
            const shot = &scene.objects.bullets.pool[@intCast(owner)];
            position = shot.at;
            direction = math.normalize(shot.velocity);
        },
        .point_facing => {
            position = at orelse return null;
            direction = facing orelse return null;
        },
        .point => position = at orelse return null,
        // Where the missile goes next, facing the way it flies, still; or moving with it, and
        // its voice its own.
        .missile => {
            if (owner < 0) return null;
            const missile = scene.objects.missiles.get(@intCast(owner)) orelse return null;
            position = missile.slot.object.nextPosition();
            direction = math.normalize(gameobj.vector(missile.slot.object.velocity));
            if (sound.missile_sound == .follows) {
                velocity = gameobj.vector(missile.slot.object.velocity);
                followed = &missile.slot.object;
                min_distance *= followed_missile_reach;
            }
        },
        .none, _ => return null,
        .object => {
            if (owner < 0 or owner >= scene.objects.slots.len) return null;
            const slot = &scene.objects.slots[@intCast(owner)];
            position = slot.object.nextPosition();
            if (owner == scene.objects.player) position += math.transform(slot.drawn.orientation, player_sound_offset);
            velocity = gameobj.vector(slot.object.velocity);
            direction = math.forward(slot.drawn.orientation);
            if (slot.model) |model| radius = model.radius;
        },
    }
    const relative = (position - scene.camera.position) * @as(Vector, @splat(hog_snd.distance_scale));
    velocity *= @as(Vector, @splat(hog_snd.velocity_scale));
    const range = definition.max_distance * hog_snd.distance_scale;
    if (!heardAnywhere(which) and range * range < math.dot(relative, relative)) return null;

    const v = chooseVoice(sound, class) orelse return null;
    const voice = &sound.voices_3d[v];
    if (!voice.isFree()) sound.end3D(v);
    if (definition.follows == .point_facing) {
        voice.position = gameobj.vec3(position);
        voice.direction = gameobj.vec3(direction.?);
    }
    const file = bank.sound(definition.entry) orelse return null;
    voice.follows = definition.follows;
    voice.owner = owner;
    voice.priority = @intCast(bank.entries[definition.entry].priority);
    voice.sound = @intFromEnum(which);
    voice.started = scene.clock.frame_start;
    voice.range = range;

    const turned = math.transformTransposed(scene.camera.orientation, relative);
    // A sound that faces nowhere faces away from the listener; its cone is whole anyway.
    const heading = if (direction) |d| math.transformTransposed(scene.camera.orientation, d) else math.normalize(turned);
    const moving = math.transformTransposed(scene.camera.orientation, velocity);
    if (!driver.set3DSampleFile(voice.sample, file)) return null;
    driver.set3DSampleLoopCount(voice.sample, definition.loop_count);
    driver.set3DSampleVolume(voice.sample, math.ftol(level));
    driver.set3DPosition(voice.sample, hog_snd.miles(turned));
    driver.set3DOrientation(voice.sample, hog_snd.miles(heading), .{ 0, 1, 0 });
    driver.set3DVelocity(voice.sample, hog_snd.miles(moving));
    driver.set3DSampleCone(voice.sample, definition.cone_inner, definition.cone_outer, math.ftol(definition.cone_outer_volume));
    driver.set3DSampleDistances(voice.sample, range, min_distance * hog_snd.distance_scale);
    // Not the game's: how far the sound of what it follows spreads, its model's radius, which the
    // software mixer leaves out.
    driver.set3DSampleRadius(voice.sample, radius * hog_snd.distance_scale);
    const rate: u32 = switch (which) {
        .explosion01, .explosion02 => @intCast(explosion_rate - math.ftol(scene.random.fraction() * explosion_spread)),
        else => sample_rate,
    };
    driver.set3DSamplePlaybackRate(voice.sample, rate);
    driver.start3DSample(voice.sample);
    if (followed) |object| object.sound_voice = .of(v);
    return v;
}

/// `play` where `world` is heard, in its scene; nothing where it is not.
pub fn playIn(world: gameobj.World, at: ?Vector, facing: ?Vector, owner: i32, which: sounds.Sound, volume: f32, class: Class) void {
    const hearing = world.hearing orelse return;
    _ = play(hearing.sound, hearing.scene(world), at, facing, owner, which, volume, class);
}

/// The engines' and the afterburner's sounds, which are started however far off they are.
fn heardAnywhere(which: sounds.Sound) bool {
    const n = @intFromEnum(which);
    return (n >= @intFromEnum(sounds.Sound.pship01) and n <= @intFromEnum(sounds.Sound.pship12)) or which == .burner01;
}

/// A voice for a sound of `class`: the engine's or the afterburner's own for theirs; else a free
/// or borrowed voice of the class, then of none; else a free voice of another class, but not of
/// the guaranteed ones nor the engine's, which the sound then borrows.
fn chooseVoice(sound: *Sound, class: Class) ?u8 {
    switch (class) {
        .player_engines => if (sound.engine_voice) |v| return v,
        .player_burners => if (sound.burner_voice) |v| return v,
        .not_reserved => {},
        else => if (takes(sound, class)) |v| return v,
    }
    if (takes(sound, .not_reserved)) |v| return v;
    for (sound.voices_3d[0..sound.voice_3d_count], sound.effects.classes[0..sound.voice_3d_count], 0..) |*voice, voice_class, index| {
        const v: u8 = @intCast(index);
        if (sound.reserved(v)) continue;
        if (voice_class == .guaranteed or !voice.isFree()) continue;
        voice.borrowed = true;
        return v;
    }
    return null;
}

/// The first voice of `class`, past the engine's, that is free or borrowed.
fn takes(sound: *Sound, class: Class) ?u8 {
    for (sound.voices_3d[0..sound.voice_3d_count], sound.effects.classes[0..sound.voice_3d_count], 0..) |*voice, voice_class, index| {
        const v: u8 = @intCast(index);
        if (sound.engine_voice == v or voice_class != class) continue;
        if (!voice.isFree() and !voice.borrowed) continue;
        voice.borrowed = false;
        return v;
    }
    return null;
}

/// `sound3d_engine_sound` (`0x0049DCB0`): the player's engine sound for its ship type, the
/// player's twin types sounding as the first set's (`gameobj.Type.untwinned`). A type past the
/// engine tables' rows sounds as the first.
pub fn engineSound(ship_type: gameobj.Type) sounds.Sound {
    const own = ship_type.untwinned();
    if (own == .kamov) return .pship07;
    if (own.number() < sounds.engines.len) return @enumFromInt(@intFromEnum(sounds.Sound.pship01) + own.number());
    return .pship01;
}

/// The engine tables' row for the Kamov, their last (an immediate in `sound3d_engine_update`).
const kamov_row = sounds.engines.len - 1;

/// The row of the engine tables for the player's ship type, the twin types taking the first set's.
/// A type the tables have no row for takes the last, where the game reads past them.
fn engineRow(ship_type: gameobj.Type) usize {
    const own = ship_type.untwinned();
    return if (own == .kamov) kamov_row else @min(own.number(), sounds.engines.len - 1);
}

/// The engine's volume factor: the effects volume and the master volume, each over the loudest.
/// **Improvement:** an exact division, where the game multiplies by a rounded reciprocal of the
/// loudest squared (`0x004DC9C8`).
fn engineScale(sound: *const Sound) f32 {
    return @as(f32, @floatFromInt(sound.volumes.master * sound.volumes.effects)) / (hog_snd.loudest * hog_snd.loudest);
}

/// `sound3d_engine_update` (`0x0049DCF0`), once a frame from `hog_snd.Sound.update3D`: the player's
/// engine pitched and loudened by its throttle; the afterburner's or reverse thrust's sound while
/// either is on, growing louder for a while, and once let go the afterburner's fading out over 25
/// ticks while the engine's comes back. Then each fighter flying past the camera is heard.
pub fn engineUpdate(sound: *Sound, scene: Scene) void {
    const driver = sound.driver orelse return;
    const engine = sound.engine_voice orelse return;
    if (sound.voices_3d[engine].isFree()) return;
    const all = scene.objects;
    const player = &all.slots[all.player].object;
    const scale = engineScale(sound);
    const frame_start = scene.clock.frame_start;
    const effects = &sound.effects;
    // The voice the afterburner's sound plays on: its own, else the engine's.
    const burner = sound.burner_voice orelse engine;
    if (sound.burner_voice) |own| driver.set3DSampleVolume(sound.voices_3d[own].sample, math.ftol(scale * burner_volume));
    const burning = player.afterburner or player.reverse_thrust;
    switch (effects.engine) {
        .idle => if (!burning) {
            const row = sounds.engines[engineRow(player.type)];
            const rate = row.rate + math.ftol(@as(f32, @floatFromInt(row.rate_by_throttle)) * player.throttle);
            driver.set3DSamplePlaybackRate(sound.voices_3d[engine].sample, @intCast(@max(rate, 0)));
            const loud = row.volume + math.ftol(@as(f32, @floatFromInt(row.volume_by_throttle)) * player.throttle);
            driver.set3DSampleVolume(sound.voices_3d[engine].sample, math.ftol(@as(f32, @floatFromInt(loud)) * scale));
            if (sound.burner_voice) |own| if (!sound.voices_3d[own].isFree()) sound.end3D(own);
        } else {
            effects.engine_changed_at = frame_start;
            effects.engine = .burning;
            sound.end3D(burner);
            const class: Class = if (sound.burner_voice != null) .player_burners else .player_engines;
            _ = play(sound, scene, null, null, @intCast(all.player), .burner01, 0, class);
        },
        .burning => if (burning) {
            const since: f32 = @floatFromInt(frame_start - effects.engine_changed_at);
            const grown: f32 = @floatFromInt(@min(math.round(since * burner_growth) + burner_start, burner_most));
            const sample = sound.voices_3d[burner].sample;
            driver.set3DSampleVolume(sample, math.ftol((grown + burner_base) * scale));
            driver.set3DSamplePlaybackRate(sample, if (player.reverse_thrust) reverse_rate else @intCast(burner_rate - math.ftol(grown * burner_pitch_step)));
        } else if (sound.burner_voice == null) {
            effects.engine_changed_at = -1;
            _ = play(sound, scene, null, null, @intCast(all.player), engineSound(player.type), 0, .player_engines);
            effects.engine = .idle;
        } else {
            effects.engine = .cooling;
            effects.engine_changed_at = frame_start;
        },
        .cooling => {
            const since = frame_start - effects.engine_changed_at;
            if (since > cooling_ticks) {
                sound.end3D(burner);
                effects.engine_changed_at = -1;
                effects.engine = .idle;
            } else if (burning) {
                effects.engine = .idle;
            } else {
                const left = math.ftol((1 - @as(f32, @floatFromInt(since)) * cooling_step) * hog_snd.loudest);
                driver.set3DSampleVolume(sound.voices_3d[burner].sample, math.ftol(@as(f32, @floatFromInt(left)) * scale));
            }
        },
        _ => {},
    }
    if (scene.view == .director) {
        driver.set3DSampleVolume(sound.voices_3d[engine].sample, 0);
        if (sound.burner_voice) |own| driver.set3DSampleVolume(sound.voices_3d[own].sample, 0);
    }
    flybys(sound, scene);
}

/// The ships heard flying past the camera: each fighter close by, moving at a speed and not toward
/// where the camera looks, once in `flyby_gap` ticks, or `own_flyby_gap` for the player's own
/// ship.
fn flybys(sound: *Sound, scene: Scene) void {
    const all = scene.objects;
    // The slot the player's order aims at, which the game takes for a ship's whatever its kind.
    const aimed_at: ?u16 = if (aigeneric.current(all, all.player)) |entry| entry.target.slot() else null;
    const looking = math.forward(scene.camera.orientation);
    for (all.slots[0..all.count], 0..) |*slot, index| {
        const combat = slot.combat orelse continue;
        if (combat.class != .fighter) continue;
        const own = index == all.player;
        if (own and !hearsOwnFlyby(scene.view)) continue;
        if (scene.view == .target) if (aimed_at) |at| if (at == index) continue;
        const offset = slot.drawn.position - scene.camera.position;
        if (math.dot(offset, offset) > flyby_reach_squared) continue;
        const object = &slot.object;
        if (object.flags.disabled or object.flags.hidden or object.flags.exploding) continue;
        if (!(object.throttle >= flyby_throttle)) continue;
        const gap: i32 = if (own) own_flyby_gap else flyby_gap;
        if (scene.clock.frame_start < object.flyby_at + gap) continue;
        const velocity = gameobj.vector(object.velocity);
        if (!(math.length(velocity) >= flyby_speed)) continue;
        const cosine = math.dot(velocity, looking) / @sqrt(math.dot(velocity, velocity) * math.dot(looking, looking));
        const hostile = object.side == .hostile;
        if (cosine > (if (hostile) hostile_flyby_cosine else friendly_flyby_cosine)) continue;
        // In a multiplayer game every ship sounds as a friendly one; OpenReliant has none.
        const which: sounds.Sound = if (hostile) .pass01 else .pass02;
        if (play(sound, scene, null, null, @intCast(index), which, 1, .flyby) != null) object.flyby_at = scene.clock.frame_start;
    }
}

/// `sound3d_pause` (`0x0049E2F0`) and `sound3d_resume` (`0x0049E330`): every 3D voice playing
/// stops where it is, or goes on.
pub fn pause(sound: *Sound, paused: bool) void {
    const driver = sound.driver orelse return;
    for (sound.voices_3d[0..sound.voice_3d_count]) |voice| {
        if (voice.isFree()) continue;
        if (paused) driver.stop3DSample(voice.sample) else driver.resume3DSample(voice.sample);
    }
}

test {
    std.testing.refAllDecls(@This());
}

const testing = struct {
    /// A bank as large as `smp3d.fat`'s entries reach, each sound a short PCM one.
    const bank_bytes = hog_snd.testing.bank(80);

    /// A sound on OpenReliant's Miles with its provider's 32 voices open, and the effects set up.
    fn open(driver: mss.Driver, sound: *Sound) !void {
        sound.init(driver, 4, null);
        sound.open3D(try fat.Bank.parse(&bank_bytes));
    }

    fn scene(mission: *gameobj.testing.Mission) Scene {
        return .{
            .objects = mission.objects,
            .camera = .{ .position = @splat(0), .orientation = math.identity },
            .view = .chase,
            .clock = &mission.clock,
            .random = &mission.random,
        };
    }
};

test init {
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: Sound = undefined;
    try testing.open(driver, &sound);
    // OpenReliant's provider has 32 voices, so each takes its class from the third row.
    try std.testing.expectEqual(mss.max_3d_samples, sound.voice_3d_count);
    try std.testing.expectEqual(sounds.classes[2][0], sound.effects.classes[0]);
    try std.testing.expectEqual(Class.player_engines, sound.effects.classes[sound.engine_voice.?]);
    try std.testing.expectEqual(Class.player_burners, sound.effects.classes[sound.burner_voice.?]);
}

test "Sound.frame plays what the frame gathered" {
    var mixer: mss.Mixer = .init(22050);
    var sound: Sound = undefined;
    try testing.open(mixer.driver(), &sound);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const bank = try fat.Bank.parse(&testing.bank_bytes);
    sound.buffered[1] = .{ 0.5, 0.25 };
    sound.frame(bank, testing.scene(&mission));
    // The gathered sound is played and forgotten.
    try std.testing.expectEqual([2]f32{ 0, 0 }, sound.buffered[1]);
}

test play {
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: Sound = undefined;
    try testing.open(driver, &sound);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const scene = testing.scene(&mission);

    // An explosion close by takes one of the explosions' voices and plays.
    const v = play(&sound, scene, .{ 0, 0, 1000 }, null, -1, .explosion01, 1, .explosions).?;
    try std.testing.expectEqual(Class.explosions, sound.effects.classes[v]);
    try std.testing.expectEqual(Follows.point, sound.voices_3d[v].follows);
    try std.testing.expectEqual(mss.Status.playing, driver.sample3DStatus(sound.voices_3d[v].sample));
    // Past its maximum distance it is not started.
    try std.testing.expectEqual(null, play(&sound, scene, .{ 0, 0, 1e7 }, null, -1, .explosion01, 1, .explosions));

    // Once the explosions' voices are all taken, one not reserved takes it, and then a free one of
    // another class, borrowed.
    for (sound.voices_3d[0..sound.voice_3d_count], sound.effects.classes[0..sound.voice_3d_count]) |*voice, class| {
        if (class == .explosions or class == .not_reserved) voice.owner = 0;
    }
    const borrowed = play(&sound, scene, .{ 0, 0, 1000 }, null, -1, .explosion01, 1, .explosions).?;
    try std.testing.expect(sound.voices_3d[borrowed].borrowed);
    try std.testing.expect(sound.effects.classes[borrowed] != .guaranteed);
}

test MissileSound {
    const missiles = @import("missiles.zig");
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: Sound = undefined;
    try testing.open(driver, &sound);
    var armed: missiles.testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    sound.objects = armed.mission.objects;
    const scene = testing.scene(&armed.mission);
    const player = try armed.add(.friendly, @splat(0));
    missiles.launch(armed.mission.world(), player, 0, .none);
    const missile = armed.missile(0);
    const placed = struct {
        fn at(on: *mss.Mixer, voice: hog_snd.Voice3D) mss.Vector {
            return on.samples_3d[@intFromEnum(voice.sample)].state.placing.position;
        }
    }.at;

    // Following, the voice is the missile's, carries farther, and moves with it.
    const v = play(&sound, scene, null, null, 0, .missile01, 1, .guaranteed).?;
    try std.testing.expectEqual(v, missile.slot.object.sound_voice.index());
    const reach = mixer.samples_3d[@intFromEnum(sound.voices_3d[v].sample)].state.placing.min_distance;
    try std.testing.expectApproxEqAbs(sounds.definitions[@intFromEnum(sounds.Sound.missile01)].min_distance * followed_missile_reach * hog_snd.distance_scale, reach, 1e-6);
    missile.slot.drawn.position = .{ 0, 0, 5000 };
    sound.update3D(scene);
    try std.testing.expectApproxEqAbs(5000 * hog_snd.distance_scale, placed(&mixer, sound.voices_3d[v])[2], 1e-6);
    // Ended, the missile has no voice.
    sound.end3D(v);
    try std.testing.expectEqual(null, missile.slot.object.sound_voice.index());

    // Staying, the missile has no voice, and the sound keeps where it started.
    sound.missile_sound = .stays;
    const still = play(&sound, scene, null, null, 0, .missile01, 1, .guaranteed).?;
    try std.testing.expectEqual(null, missile.slot.object.sound_voice.index());
    const started = placed(&mixer, sound.voices_3d[still]);
    missile.slot.drawn.position = .{ 0, 0, 20000 };
    sound.update3D(scene);
    try std.testing.expectEqual(started, placed(&mixer, sound.voices_3d[still]));
}

test engineSound {
    try std.testing.expectEqual(sounds.Sound.pship01, engineSound(.predator));
    try std.testing.expectEqual(sounds.Sound.pship03, engineSound(@enumFromInt(0xF4 + 2)));
    try std.testing.expectEqual(sounds.Sound.pship07, engineSound(.kamov));
    try std.testing.expectEqual(sounds.Sound.pship01, engineSound(@enumFromInt(40)));
}

test engineUpdate {
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: Sound = undefined;
    try testing.open(driver, &sound);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, .{ 0, 0, 0 });
    const scene = testing.scene(&mission);
    try std.testing.expect(play(&sound, scene, null, null, player, engineSound(.predator), 0, .player_engines) != null);

    // Idle, the throttle pitches the engine.
    const object = &mission.slot(player).object;
    object.throttle = 1;
    engineUpdate(&sound, scene);
    try std.testing.expectEqual(EngineState.idle, sound.effects.engine);
    // The afterburner starts its own sound, which grows while it burns.
    object.afterburner = true;
    engineUpdate(&sound, scene);
    try std.testing.expectEqual(EngineState.burning, sound.effects.engine);
    try std.testing.expectEqual(@intFromEnum(sounds.Sound.burner01), sound.voices_3d[sound.burner_voice.?].sound);
    // Let go, it fades over 25 ticks.
    object.afterburner = false;
    engineUpdate(&sound, scene);
    try std.testing.expectEqual(EngineState.cooling, sound.effects.engine);
    mission.clock.frame_start += 26;
    engineUpdate(&sound, scene);
    try std.testing.expectEqual(EngineState.idle, sound.effects.engine);
    try std.testing.expect(sound.voices_3d[sound.burner_voice.?].isFree());
}

test hearsOwnFlyby {
    try std.testing.expect(hearsOwnFlyby(.chase));
    try std.testing.expect(hearsOwnFlyby(.target));
    try std.testing.expect(!hearsOwnFlyby(.cockpit_rear));
    try std.testing.expect(!hearsOwnFlyby(.external));
    try std.testing.expect(!hearsOwnFlyby(._unknown_15));
}

test "a fighter flying past the camera is heard" {
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var sound: Sound = undefined;
    try testing.open(driver, &sound);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, .{ 0, 0, 0 });
    const other = try mission.add(.predator, .{ 0, 0, 2000 });
    mission.slot(player).drawn.position = .{ 0, 0, -50000 };
    const scene = testing.scene(&mission);
    try std.testing.expect(play(&sound, scene, null, null, player, engineSound(.predator), 0, .player_engines) != null);

    // Close by, at speed, and going the other way from where the camera looks.
    const object = &mission.slot(other).object;
    mission.slot(other).drawn.position = .{ 0, 0, 2000 };
    object.throttle = 1;
    object.velocity = .{ .x = 0, .y = 0, .z = -300 };
    object.side = .hostile;
    mission.clock.frame_start = 1000;
    engineUpdate(&sound, scene);
    try std.testing.expectEqual(1000, object.flyby_at);
    // Not again for 500 ticks.
    object.flyby_at = 900;
    engineUpdate(&sound, scene);
    try std.testing.expectEqual(900, object.flyby_at);
}
