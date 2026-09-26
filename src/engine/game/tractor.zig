//! `C:\lancer\game\tractor.cpp`: the tractors by which a ship takes another aboard (`tractors`,
//! `0x0051D10C`): two beams from the ship to what it takes, a bubble glowing round it and a green
//! light on it. The file's asserting code is `tractor_create` (`0x0041D090`). **Unverified:** that
//! the code before it from `tractors_init` (`0x0041BB90`), after `launch.cpp`'s, is the file's too:
//! the tractors' other routines, and Scoop Up (order 107), by which a nanny ship or the enemy's
//! Antanov picks up an ejected pilot's pod. [`ejection.md`](../../../docs/engine/ejection.md)
//! describes the pickup.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const create = @import("create.zig");
const events = @import("mission/events.zig");
const gameobj = @import("gameobj.zig");
const guns = @import("guns.zig");
const matmanager = @import("matmanager.zig");
const objects = @import("objects.zig");
const particles = @import("particles.zig");
const shield = @import("shield.zig");
const sound3d = @import("sound3d.zig");
const table = @import("table.zig");
const xtrabits = @import("xtrabits.zig");

// --- The tractors -------------------------------------------------------------------------------

/// The tractors in use (`tractors`, `0x0051D10C`), and the texture their beams are drawn over
/// (`tractor_texture`, `0x0051D120`).
pub const Tractors = struct {
    gpa: Allocator,
    slots: [capacity]?*Tractor = @splat(null),
    image: *srtexture.Image,

    pub const capacity = 5;

    /// `tractors_init` (`0x0041BB90`), as a mission loads: none in use, and `laser2`.
    pub fn init(gpa: Allocator, textures: *srtexture.Table) matmanager.Error!Tractors {
        return .{ .gpa = gpa, .image = try matmanager.textureRequire(textures, "laser2") };
    }

    /// `tractors_free` (`0x0041BBC0`), as a mission ends: every tractor let go.
    pub fn reset(tractors: *Tractors) void {
        for (0..capacity) |index| tractors.free(index);
    }

    pub fn deinit(tractors: *Tractors) void {
        tractors.reset();
    }

    /// `tractor_create` (`0x0041D090`): the first tractor free, for a ship to take in the object in
    /// slot `pod`, with its light; null where all are in use or it can't be made.
    fn take(tractors: *Tractors, pod: u16) ?usize {
        const index = table.firstFreeIndex(*Tractor, &tractors.slots) orelse return null;
        const tractor = tractors.gpa.create(Tractor) catch return null;
        tractor.* = .{ .pod = pod };
        tractors.slots[index] = tractor;
        return index;
    }

    /// `tractor_free` (`0x0041D1A0`): tractor `index` let go, with its beams and its bubble.
    fn free(tractors: *Tractors, index: usize) void {
        const tractor = tractors.slots[index] orelse return;
        for (tractor.beams) |held| if (held) |beam| beam.destroy(tractors.gpa);
        if (tractor.bubble) |bubble| bubble.destroy(tractors.gpa);
        tractors.gpa.destroy(tractor);
        tractors.slots[index] = null;
    }

    /// OpenReliant's: what each tractor shows this frame goes into `scene`, where its ship and its
    /// pod are drawn: its beams, aimed at the pod (`tractor_beam_aim`) where Scoop Up aims them and
    /// otherwise hanging from their part as they were last aimed, its light on the pod, and its
    /// bubble round it. The game adds them to the scene as Scoop Up runs.
    pub fn draw(tractors: *Tractors, gpa: Allocator, scene: *srcore.Scene, all: *create.Objects) Allocator.Error!void {
        for (tractors.slots) |held| {
            const tractor = held orelse continue;
            if (!tractor.shown) continue;
            tractor.shown = false;
            const pod = all.slots[tractor.pod].drawn;
            for (tractor.beams) |made| if (made) |beam| {
                const model = if (all.slots[beam.ship].model) |*live| live else continue;
                const part = model.rootChild(beam.part) orelse continue;
                if (tractor.aimed) beam.aim(part.drawn(), pod.position) else beam.hang(part.drawn());
                try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &beam.object }, .world);
            };
            tractor.light.kind.point.position = pod.position;
            try xtrabits.sceneAdd(gpa, scene, .{ .light = &tractor.light }, .world);
            if (tractor.bubble) |bubble| {
                bubble.object.position = pod.position;
                bubble.object.orientation = pod.orientation;
                try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &bubble.object }, .world);
            }
        }
    }
};

/// How far a tractor's light reaches at its full (`0x0041D177`, `0x0041C373`, `0x004DC43C`).
const light_reach: f32 = 10000;

/// A tractor (0x10 bytes): two beams, a bubble and a light, and the object they hold.
pub const Tractor = struct {
    beams: [2]?*Beam = .{ null, null },
    bubble: ?*Bubble = null,
    /// `Tractor Light`: a green point light on the pod, which reaches every object.
    light: srlight.Light = .{
        .mask = 0,
        .intensity = 1,
        .colour = .{ 0, 1, 0 },
        .kind = .{ .point = .{ .position = @splat(0), .range = light_reach } },
    },
    pod: u16,
    /// OpenReliant's: whether Scoop Up showed it this frame, which the game does by adding its
    /// beams, its light and its bubble to the scene, and whether it aimed the beams.
    shown: bool = false,
    aimed: bool = false,

    /// Shown this frame, its light reaching `reach`, its beams aimed at the pod or not.
    fn show(tractor: *Tractor, reach: f32, beams: Aiming) void {
        tractor.light.kind.point.range = reach;
        tractor.shown = true;
        tractor.aimed = beams == .aimed;
    }

    const Aiming = enum { aimed, held };

    fn fadeBeams(tractor: *Tractor, alpha: f32) void {
        for (tractor.beams) |held| if (held) |beam| beam.fade(alpha);
    }
};

/// How wide a beam is either side of its axis, how many ribbons cross on it, how long they are
/// made, and the span of the texture across each quad (`0x004DC48C`, `0x0041CC9B`, `0x0041CD39`).
const beam_half: f32 = 50;
const beam_ribbons = 3;
const beam_length: f32 = 400;
const beam_span: [2][2]f32 = .{ .{ 0.04, 0.04 }, .{ 0.99, 0.99 } };
const beam_quads = 1 + beam_ribbons;
const beam_corners = beam_quads * guns.blade_corners;

/// A tractor's beam (`tractor_beam_mesh`, `0x0041CBC0`, "TractorBeam_Mesh"): a square across its
/// emitter and three ribbons crossing on its axis, a star's blades (`guns.blade`), over `laser2`,
/// added by the alpha of its own colours; never culled, nor tested against the view. The game
/// hangs it from the part it comes from.
pub const Beam = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    colours: [beam_corners][4]f32 = @splat(@splat(0)),
    /// The ship it comes from, the part it hangs from, and where on the part it stands.
    ship: u16,
    part: usize,
    point: Vector,
    /// How it is turned in the part's frame, as it was last aimed.
    turn: math.Matrix = math.identity,

    /// The game draws the square in one group of polygons and the ribbons in another, of the same
    /// material; OpenReliant draws them in one.
    pub fn create(gpa: Allocator, image: *srtexture.Image, ship: u16, part: usize, point: Vector) Allocator.Error!*Beam {
        var corners: [beam_corners]Vector = undefined;
        corners[0..guns.blade_corners].* = .{
            .{ -beam_half, -beam_half, 0 }, .{ beam_half, -beam_half, 0 },
            .{ beam_half, beam_half, 0 },   .{ -beam_half, beam_half, 0 },
        };
        for (0..beam_ribbons) |ribbon| {
            corners[(1 + ribbon) * guns.blade_corners ..][0..guns.blade_corners].* = guns.blade(ribbon, beam_ribbons, beam_half, .{ 0, beam_length });
        }
        var faces: [beam_quads][guns.blade_corners]u16 = undefined;
        var uv: [beam_corners][2]f32 = undefined;
        for (&faces, 0..) |*face, quad| {
            face.* = guns.quadFace(quad);
            uv[quad * guns.blade_corners ..][0..guns.blade_corners].* = guns.bladeCorners(beam_span);
        }
        const material: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add_alpha });
        const beam = try gpa.create(Beam);
        errdefer gpa.destroy(beam);
        beam.* = .{
            .mesh = try guns.meshOf(guns.blade_corners, gpa, &corners, &faces, &uv, material, image),
            .level = undefined,
            .object = undefined,
            .ship = ship,
            .part = part,
            .point = point,
        };
        beam.level = .{.{ .mesh = &beam.mesh, .until = std.math.inf(f32) }};
        beam.object = .{
            .flags = .{ .not_culled = true, .always_drawn = true, .unbounded = true, .owns_mesh = true, .baked_object = true },
            .position = @splat(0),
            .radius = beam.mesh.radius,
            .levels = &beam.level,
            .baked = &beam.colours,
        };
        return beam;
    }

    pub fn destroy(beam: *Beam, gpa: Allocator) void {
        beam.mesh.deinit(gpa);
        gpa.destroy(beam);
    }

    /// `tractor_beam_fade` (`0x0041CED0`): the beam as solid as `alpha`, from nothing to whole:
    /// each quad clear at its near corners and green, that solid, at its far ones.
    pub fn fade(beam: *Beam, alpha: f32) void {
        const solid = std.math.clamp(alpha, 0, 1);
        for (&beam.colours, 0..) |*colour, corner| switch (corner % guns.blade_corners) {
            1, 2 => colour.* = .{ 0, 1, 0, solid },
            else => colour[3] = 0,
        };
    }

    /// `tractor_beam_aim` (`0x0041CE00`): the beam from its point on a part standing at `part`,
    /// turned to `pod` and reaching it: the ribbons' far corners as far out as the pod is.
    pub fn aim(beam: *Beam, part: math.Place, pod: Vector) void {
        const from = (math.Place{ .position = beam.point }).within(part).position;
        const orientation = math.lookAt(pod - from);
        beam.turn = math.product(math.transpose(part.orientation), orientation);
        beam.object.position = from;
        beam.object.orientation = orientation;
        const reach = math.distance(pod, from);
        for (1..beam_quads) |ribbon| {
            for (beam.mesh.positions[ribbon * guns.blade_corners + 1 ..][0..2]) |*far| far[2] = reach;
        }
        srapi.findBoundingBox(&beam.mesh);
        beam.object.radius = beam.mesh.radius;
    }

    /// The beam hanging from its point on a part standing at `part`, turned and as long as it was
    /// last aimed.
    fn hang(beam: *Beam, part: math.Place) void {
        const place = (math.Place{ .position = beam.point, .orientation = beam.turn }).within(part);
        beam.object.position = place.position;
        beam.object.orientation = place.orientation;
    }
};

/// How much wider than the pod the bubble round it is (`0x004DC4E0`).
const bubble_scale: f32 = 1.5;

/// How far round the bubble's waves each vertex stands from the one before, how fast they run and
/// how bright their crests are at the bubble's full (`0x004DC4C0`, `0x004DC3D8`, `0x004DC474`).
const wave_step: f32 = 0.3;
const wave_rate: f32 = 3;
const crest: f32 = 0.05;

/// The bubble round what a tractor holds (`shield_bubble_object`, `0x0049E370`, "Shield mesh"): the
/// shields' finest sphere with colours of its own, its texture laid on by each vertex's `x` and
/// `y`, never culled.
///
/// **Improvement:** in the smooth shield style it is drawn on the shields' finer sphere, as a
/// shield's bubble is up close, so its outline is round. Its glow is worked out on the game's
/// sphere's vertices, and the finer sphere's take their colours from between them
/// (`shield.Grid.sample`), so its waves run as the game's do. The original style, which
/// `--original` sets, keeps the game's sphere.
pub const Bubble = struct {
    object: srapiext.MeshObject,
    level: [1]srapiext.Level,
    /// The grid of the sphere it is drawn on.
    grid: shield.Grid,
    /// Its glow on the game's sphere's vertices.
    waves: [shield.game_grid.vertices()][4]f32 = @splat(@splat(0)),
    colours: [][4]f32,
    uv: [][2]f32,

    fn create(gpa: Allocator, shields: *const shield.Shields, scale: f32) Allocator.Error!*Bubble {
        const sphere = shields.finest();
        const mesh = sphere.mesh;
        const colours = try gpa.alloc([4]f32, mesh.positions.len);
        errdefer gpa.free(colours);
        @memset(colours, @splat(0));
        const uv = try gpa.alloc([2]f32, mesh.positions.len);
        errdefer gpa.free(uv);
        for (uv, mesh.positions) |*coordinates, position| coordinates.* = .{ position[0], position[1] };
        const bubble = try gpa.create(Bubble);
        bubble.* = .{
            .object = undefined,
            .level = .{.{ .mesh = mesh, .until = std.math.inf(f32) }},
            .grid = sphere.grid,
            .colours = colours,
            .uv = uv,
        };
        bubble.object = .{
            .flags = .{ .not_culled = true, .baked_object = true, .own_first = true },
            .position = @splat(0),
            .scale = scale,
            .radius = 1,
            .levels = &bubble.level,
            .baked = colours,
            .own_uv = .{ uv, null },
        };
        return bubble;
    }

    fn destroy(bubble: *Bubble, gpa: Allocator) void {
        gpa.free(bubble.colours);
        gpa.free(bubble.uv);
        gpa.destroy(bubble);
    }

    /// `tractor_bubble_glow` (`0x0041CF80`): green waves running round the bubble at `time`, their
    /// crests `brightness` of `crest`, from nothing to whole.
    fn glow(bubble: *Bubble, brightness: f32, time: f32) void {
        const bright = std.math.clamp(brightness, 0, 1);
        for (&bubble.waves, 0..) |*colour, vertex| {
            const wave = @sin(@as(f32, @floatFromInt(vertex)) * wave_step + time * wave_rate);
            colour.* = .{ 0, (wave + 1) * bright * crest, 0, 1 };
        }
        for (bubble.colours, 0..) |*colour, index| colour.* = bubble.grid.sample(shield.game_grid, &bubble.waves, index);
    }
};

// --- Scoop Up -----------------------------------------------------------------------------------

/// What Scoop Up keeps in its ship's order state.
pub const State = extern struct {
    /// Its tractor's place among the tractors, or -1 for none.
    tractor: i32,
    stage: Stage,
    /// When the stage began.
    since: i32,
    /// The pod it takes in, which nothing reads: the order's target is.
    pod: i32,
    /// When it last ran, which a stage that moves the pod moves it by.
    updated: i32,
    /// How far behind the first the second beam comes on, as a share of the time.
    lag: f32,
    _unknown_18: [0x90 - 0x18]u8,

    comptime {
        assert(@offsetOf(State, "stage") == 0x4);
        assert(@offsetOf(State, "since") == 0x8);
        assert(@offsetOf(State, "pod") == 0xC);
        assert(@offsetOf(State, "updated") == 0x10);
        assert(@offsetOf(State, "lag") == 0x14);
        assert(@sizeOf(State) == 0x90);
    }

    /// Its tractor's place, where it has one.
    fn held(state: State) ?usize {
        return if (state.tractor < 0) null else @intCast(state.tractor);
    }

    /// How far through its stage it is at tick `now`, for a stage that lasts a while.
    fn through(state: State, now: i32) f32 {
        return particles.through(now, state.since, state.stage.ticks());
    }
};

/// Scoop Up's stages.
pub const Stage = enum(i32) {
    /// Claiming the pod, which another ship may be taking in already.
    claiming = 0,
    /// Flying to it, until the ship comes to rest near it.
    approaching = 1,
    /// Making the beams and the bubble, and opening the doors.
    opening = 2,
    /// The beams and the bubble coming on, for a second; then the pod is held still.
    locking = 3,
    /// Drawing the pod to the doors.
    pulling = 4,
    /// Drawing it in; then the doors close.
    stowing = 5,
    /// The beams, the bubble and the light going out, for half a second.
    fading = 6,
    /// Waiting two and a half seconds.
    waiting = 7,
    /// Done: the pod is aboard.
    done = 8,
    _,

    /// How long it lasts, in ticks, for a stage that lasts a while (`0x004E3E1C`).
    fn ticks(stage: Stage) i32 {
        return switch (stage) {
            .locking => 100,
            .fading => 50,
            .waiting => 250,
            else => 0,
        };
    }

    /// Whether the ship steers at the pod through it: until the pod is held still, which the game
    /// tells by the stage's number.
    fn steers(stage: Stage) bool {
        return @intFromEnum(stage) < @intFromEnum(Stage.pulling);
    }
};

/// `order_scoop_up_init` (`0x0041BBF0`): the ship takes a tractor for the pod, its target, and
/// neither collides with the other from now on.
///
/// **Fix:** the game takes a tractor without checking one is free, and reads past the five where
/// none is; OpenReliant has the ship pick the pod up without beams, bubble or light.
pub fn scoopUpInit(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const pod = targetOf(slot) orelse return;
    const state = &slot.state.scoop_up;
    state.stage = .claiming;
    state.since = 0;
    state.pod = pod;
    const taken = if (ctx.world.tractors) |tractors| tractors.take(pod) else null;
    state.tractor = if (taken) |place| @intCast(place) else -1;
    all.slots[pod].object.passes_through[0] = .of(index);
    slot.object.passes_through[0] = .of(pod);
}

/// `order_scoop_up_exit` (`0x0041BC70`): the pod is let go, and the tractor.
pub fn scoopUpExit(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    if (targetOf(slot)) |pod| all.slots[pod].object.flags.tractored = false;
    const tractors = ctx.world.tractors orelse return;
    if (slot.state.scoop_up.held()) |place| tractors.free(place);
}

/// How near the pod the ship must point at it, by how fast it turns, and how nearly it must point
/// at it there (`0x004DC400`, `0x004DC484`).
const turning_room: f32 = 6;
const facing: f32 = 0.7;

/// Beyond how far from the pod the ship flies at full throttle, and at `slow_throttle`; nearer,
/// it stops (`0x004DC444`, `0x004DC43C`, `0x0041BECA`).
const full_beyond: f32 = 20000;
const slow_beyond: f32 = 10000;
const slow_throttle: f32 = 0.4;

/// How still the ship must be to begin: its inputs and its throttle, and its rates of turn
/// (`0x004DC53C`, `0x004DC4AC`).
const still_inputs: f32 = 0.025;
const still_rates: f32 = 0.02;

/// The most the second beam lags the first coming on, as a share of the time (`0x004DC3F8`).
const lag_most: f32 = 0.2;

/// Where the pod is drawn to first: `pull_out` out from the door, at a second's speed from
/// `pull_slowest` there to `pull_fastest` `pull_ramp` away and beyond, until within `pulled`
/// (`0x0041C43E`, `0x0041C4B8`, `0x004DC580`, `0x004DC5AC`, `0x004DC4A8`).
const pull_out: f32 = 6300;
const pull_slowest: f32 = 900;
const pull_fastest: f32 = 1800;
const pull_ramp: f32 = 3000;
const pulled: f32 = 500;

/// Where it is drawn in to, out from a nanny ship's door and an Antanov's, at a second's
/// `stow_speed`, until within `stowed` (`0x0041C6AC`, `0x0041C6B9`, `0x0041C722`, `0x004DC544`).
const stow_nanny: f32 = 3000;
const stow_antanov: f32 = 3400;
const stow_speed: f32 = 900;
const stowed: f32 = 300;

/// A tick, in seconds (`0x004DC518`).
const tick_seconds: f32 = 0.01;

/// The share of the time by which the bubble comes to its full, and goes out (`0x004DC408`).
const bubble_turn: f32 = 0.5;

/// `order_scoop_up` (`0x0041BCC0`): a nanny ship or the enemy's Antanov takes in the pod, its
/// target. It claims the pod, flies to it and comes to rest; makes its beams from the tractor
/// points of its hull and its bubble round the pod, opens its doors, heard (`dooropen`), and brings
/// the beams, the bubble and the light on over a second, the second beam a little behind the first;
/// holds the pod still and draws it to `pull_out` off its door, then in; closes its doors, heard
/// (`doorclos`), as the beams, no longer aimed, the bubble and the light go out; and after a while
/// has the pod aboard, its ObjectScooped event posted (`events.scooped`), and the pod gone from the
/// mission. Should the pod be gone first, it closes its doors and gives up.
///
/// Not ported: a multiplayer game's wait for every player, as the beams are made and before the
/// pod is gone ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
pub fn scoopUp(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.scoop_up;
    const now = ctx.clock.frame_start;
    const seconds = @as(f32, @floatFromInt(now - state.updated)) * tick_seconds;
    state.updated = now;
    const pod_index = targetOf(slot) orelse return;
    const pod = &all.slots[pod_index];
    const tractor: ?*Tractor = if (world.tractors) |tractors| if (state.held()) |place| tractors.slots[place] else null else null;
    if (pod.object.type == .stand_in or pod.object.flags.exploding) {
        closeDoors(world, slot);
        _ = aigeneric.pop(ctx, index);
        return;
    }
    if (state.stage.steers()) _ = ai.steer(world, index, pod.drawn.position, ai.full_limit, ai.no_ease, .{});
    switch (state.stage) {
        .claiming => {
            if (pod.object.flags.tractored) {
                _ = aigeneric.pop(ctx, index);
                return;
            }
            pod.object.flags.tractored = true;
            state.stage = .approaching;
        },
        .approaching => approach(slot, pod.drawn.position, state),
        .opening => {
            object.letGo();
            if (tractor) |held| makeBeams(world, index, pod_index, held);
            playDoors(slot, .open);
            doorSound(world, slot, .dooropen);
            state.lag = world.random.fraction() * lag_most;
            state.stage = .locking;
            state.since = now;
        },
        .locking => {
            const t = state.through(now);
            if (t < 1) {
                if (tractor) |held| {
                    if (held.beams[0]) |first| first.fade(t);
                    if (state.lag < t) if (held.beams[1]) |second| second.fade((t - state.lag) / (1 - state.lag));
                    if (held.bubble) |bubble| bubble.glow(if (t >= bubble_turn) 1 else t / bubble_turn, t);
                }
            } else {
                pod.object.flags.frozen = true;
                state.stage = .pulling;
                state.since = now;
            }
            // The game sets the light's reach by the share of the time and then to its full, so it
            // shines at its full from the first.
            if (tractor) |held| held.show(light_reach, .aimed);
        },
        .pulling, .stowing => {
            const door = doorPlace(slot) orelse return;
            const pulling = state.stage == .pulling;
            const out = if (pulling) pull_out else if (object.type == .nanny) stow_nanny else stow_antanov;
            const to = door.position + math.forward(door.orientation) * @as(Vector, @splat(out));
            // Where the pod was placed, which the game's frame has it at; OpenReliant draws it on
            // between the ticks (`create.Slot.glide`).
            const was = gameobj.vector(pod.object.root.position);
            const reach = math.distance(to, was);
            const speed = if (pulling) @min(math.lerp(pull_slowest, pull_fastest, reach / pull_ramp), pull_fastest) else stow_speed;
            const way = math.normalize(to - was);
            objects.setPosition(&pod.object, &pod.drawn, was + way * @as(Vector, @splat(speed * seconds)));
            pod.glide = way * @as(Vector, @splat(speed * tick_seconds));
            if (tractor) |held| {
                if (held.bubble) |bubble| bubble.glow(1, @as(f32, @floatFromInt(now - state.since)) * tick_seconds);
                held.show(light_reach, .aimed);
            }
            if (pulling and reach < pulled) {
                state.stage = .stowing;
                state.since = now;
            } else if (!pulling and reach < stowed) {
                state.stage = .fading;
                state.since = now;
                closeDoors(world, slot);
            }
        },
        .fading => {
            const t = state.through(now);
            if (tractor) |held| {
                held.fadeBeams(1 - t);
                if (held.bubble) |bubble| bubble.glow(if (t >= bubble_turn) 0 else (bubble_turn - t) / bubble_turn, t);
                held.show((1 - t) * light_reach, .held);
            }
            if (t >= 1) {
                state.stage = .waiting;
                state.since = now;
            }
        },
        .waiting => if (state.through(now) >= 1) {
            state.stage = .done;
            state.since = now;
        },
        .done => {
            _ = aigeneric.pop(ctx, index);
            events.scooped(world, index, pod_index);
            create.retire(ctx, pod_index);
        },
        _ => {},
    }
}

/// Scoop Up's approach: the ship in `slot` flies at the pod at `pod`, at full throttle while far
/// off, slower nearer and not at all nearer still, and holds still where it isn't pointing at the
/// pod near it; once it is at rest, its stage moves on.
fn approach(slot: *create.Slot, pod: Vector, state: *State) void {
    const object = &slot.object;
    const flight = slot.flight orelse return;
    const to = pod - slot.drawn.position;
    const reach = math.length(to);
    if (reach < flight.speed_per_pitch_rate * turning_room and ai.noseCosine(slot.drawn.orientation, to) < facing) {
        object.throttle = 0;
        return;
    }
    object.throttle = if (reach > full_beyond) ai.full_throttle else if (reach > slow_beyond) slow_throttle else 0;
    const inputs = [_]f32{ object.yaw_input, object.pitch_input, object.roll_input, object.throttle };
    const rates = [_]f32{ object.yaw_rate, object.pitch_rate, object.roll_rate };
    for (inputs) |input| if (@abs(input) > still_inputs) return;
    for (rates) |rate| if (@abs(rate) > still_rates) return;
    state.stage = .opening;
}

/// The ship its order in `slot` aims at, where it names one.
fn targetOf(slot: *const create.Slot) ?u16 {
    return (slot.current() orelse return null).target.ship();
}

/// The part a nanny ship's or an Antanov's beams come from, and the part its door point is on.
fn hullName(ship: gameobj.Type) []const u8 {
    return if (ship == .nanny) "Nanny" else "Antanov";
}

fn doorName(ship: gameobj.Type) []const u8 {
    return if (ship == .nanny) "nan_door3" else "Antanov";
}

/// The ship in slot `index` makes the beams of `tractor`, at the first two of its hull's tractor
/// points (`shp.PointList.Kind.tractor`), and its bubble round the pod in slot `pod`.
fn makeBeams(world: gameobj.World, index: u16, pod: u16, tractor: *Tractor) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const tractors = world.tractors orelse return;
    const model = if (slot.model) |*live| live else return;
    const hull = model.partNamed(hullName(slot.object.type)) orelse return;
    const points = (hull.data() orelse return).pointList(.tractor) orelse return;
    for (&tractor.beams, points.points[0..@min(points.points.len, tractor.beams.len)]) |*beam, point| {
        beam.* = Beam.create(tractors.gpa, tractors.image, index, hull.index, gameobj.vector(point.position)) catch null;
    }
    const shields = world.shields orelse return;
    tractor.bubble = Bubble.create(tractors.gpa, shields, all.slots[pod].object.radius * bubble_scale) catch null;
}

/// Where the ship in `slot` takes the pod in, as last drawn: its door point, in the world, turned
/// as the part it is on.
fn doorPlace(slot: *create.Slot) ?math.Place {
    const model = if (slot.model) |*live| live else return null;
    const part = model.partNamed(doorName(slot.object.type)) orelse return null;
    const points = (part.data() orelse return null).pointList(.door) orelse return null;
    if (points.points.len == 0) return null;
    return (math.Place{ .position = gameobj.vector(points.points[0].position) }).within(part.part().drawn());
}

/// Which way the doors go.
const Doors = enum { open, close };

/// The clip the doors play, forward to open and back from where they are to close.
const door_clip = "opendoor";
const opening: f32 = 1;
const closing: f32 = -1;

/// The ship in `slot` plays its doors' clip: a nanny ship's first door, the root's second child,
/// and an Antanov's first two.
fn playDoors(slot: *create.Slot, way: Doors) void {
    const model = if (slot.model) |*live| live else return;
    const doors: []const usize = switch (slot.object.type) {
        .nanny => &.{1},
        .antanov => &.{ 1, 2 },
        else => &.{},
    };
    for (doors) |door| {
        const part = model.rootChild(door) orelse continue;
        switch (way) {
            .open => model.playNamed(door, door_clip, 0, null, opening),
            .close => model.playNamed(door, door_clip, part.animation.time, null, closing),
        }
    }
}

/// `which` heard from the root's second child of the ship in `slot`, facing out along it.
fn doorSound(world: gameobj.World, slot: *create.Slot, which: sound3d.sounds.Sound) void {
    const model = if (slot.model) |*live| live else return;
    const door = (model.rootChild(1) orelse return).drawn();
    sound3d.playIn(world, door.position, math.forward(door.orientation), -1, which, 1, .not_reserved);
}

/// The ship in `slot` closes its doors, heard.
fn closeDoors(world: gameobj.World, slot: *create.Slot) void {
    playDoors(slot, .close);
    doorSound(world, slot, .doorclos);
}

test {
    std.testing.refAllDecls(@This());
}

pub const testing = struct {
    /// The tractors over a table holding nothing but their texture.
    pub const Built = struct {
        textures: *@import("../surrender/surrenderlib/srtexture.zig").testing.Textures,
        tractors: Tractors,

        pub fn init(gpa: Allocator) !Built {
            const textures = try @import("../surrender/surrenderlib/srtexture.zig").testing.Textures.init(gpa, &.{"laser2"});
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .tractors = try .init(gpa, &textures.table) };
        }

        pub fn deinit(built: *Built, gpa: Allocator) void {
            built.tractors.deinit();
            built.textures.deinit(gpa);
        }
    };
};

test Tractors {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const tractors = &built.tractors;
    // Five can be in use at once, each with its green light at its full.
    for (0..Tractors.capacity) |n| try std.testing.expectEqual(n, tractors.take(@intCast(n)).?);
    try std.testing.expectEqual(null, tractors.take(9));
    try std.testing.expectEqual(light_reach, tractors.slots[0].?.light.kind.point.range);
    // One let go frees its place, with its beams.
    tractors.slots[2].?.beams[0] = try Beam.create(gpa, tractors.image, 0, 0, @splat(0));
    tractors.free(2);
    try std.testing.expectEqual(2, tractors.take(7).?);
    tractors.reset();
    for (tractors.slots) |slot| try std.testing.expectEqual(null, slot);
}

test "Tractors.draw" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const pod = try mission.add(.predator, .{ 0, 0, 300 });
    const tractors = &built.tractors;
    const tractor = tractors.slots[tractors.take(pod).?].?;
    // A beam from a ship with no model to hang it from, which is left out.
    tractor.beams[0] = try Beam.create(gpa, tractors.image, pod, 0, @splat(0));
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);

    // Not shown this frame, it draws nothing.
    try tractors.draw(gpa, &scene, mission.objects);
    try std.testing.expectEqual(0, scene.lights.items.len);
    // Shown, its light stands on the pod, for the one frame.
    tractor.show(light_reach, .held);
    try tractors.draw(gpa, &scene, mission.objects);
    try std.testing.expectEqual(1, scene.lights.items.len);
    try std.testing.expectEqual([3]f32{ 0, 0, 300 }, scene.lights.items[0].kind.point.position);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
    try std.testing.expect(!tractor.shown);
    scene.clear();
    try tractors.draw(gpa, &scene, mission.objects);
    try std.testing.expectEqual(0, scene.lights.items.len);
}

test Beam {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const beam = try Beam.create(gpa, built.tractors.image, 3, 1, .{ 0, 10, 0 });
    defer beam.destroy(gpa);
    // A square across the emitter and three ribbons along its axis.
    try std.testing.expectEqual(beam_corners, beam.mesh.positions.len);
    try std.testing.expectEqual(beam_length, beam.mesh.positions[guns.blade_corners + 1][2]);

    // Faded, each quad is clear at its near corners and green at its far ones.
    beam.fade(1.5);
    try std.testing.expectEqual([4]f32{ 0, 1, 0, 1 }, beam.colours[1]);
    try std.testing.expectEqual(0, beam.colours[0][3]);
    beam.fade(0.25);
    try std.testing.expectEqual(0.25, beam.colours[6][3]);

    // Aimed from a part turned a quarter about Y, it reaches the pod.
    const part: math.Place = .{ .position = .{ 100, 0, 0 }, .orientation = math.rotation(.y, std.math.pi / 2.0) };
    const pod: Vector = .{ 100, 10, 1000 };
    beam.aim(part, pod);
    try std.testing.expectApproxEqAbs(10, beam.object.position[1], 1e-4);
    const along = math.forward(beam.object.orientation);
    try std.testing.expect(math.dot(along, math.normalize(pod - beam.object.position)) > 0.9999);
    try std.testing.expectApproxEqAbs(math.distance(pod, beam.object.position), beam.mesh.positions[5][2], 1e-2);
    // Hanging, it keeps its turn on the part as the part moves.
    const moved: math.Place = .{ .position = part.position + Vector{ 0, 0, 50 }, .orientation = part.orientation };
    beam.hang(moved);
    try std.testing.expect(math.dot(math.forward(beam.object.orientation), along) > 0.9999);
    try std.testing.expectApproxEqAbs(50, beam.object.position[2] - (math.Place{ .position = beam.point }).within(part).position[2], 1e-3);
}

test Bubble {
    const gpa = std.testing.allocator;
    var shields: shield.testing.Built = try .init(gpa);
    defer shields.deinit(gpa);
    const bubble = try Bubble.create(gpa, &shields.shields, 300);
    defer bubble.destroy(gpa);
    try std.testing.expectEqual(shield.game_grid.vertices(), bubble.colours.len);
    // The finest sphere, as wide as asked, its texture laid on by each vertex's x and y.
    try std.testing.expectEqual(300, bubble.object.scale);
    const vertex = shields.shields.meshes[0].positions[4];
    try std.testing.expectEqual([2]f32{ vertex[0], vertex[1] }, bubble.uv[4]);
    // Its waves are green and solid, no brighter than their crest, and out when it is.
    bubble.glow(1, 0.5);
    for (bubble.colours) |colour| {
        try std.testing.expect(colour[1] >= 0 and colour[1] <= 2 * crest);
        try std.testing.expectEqual(0, colour[0]);
        try std.testing.expectEqual(1, colour[3]);
    }
    bubble.glow(-1, 0.5);
    for (bubble.colours) |colour| try std.testing.expectEqual(0, colour[1]);

    // In the smooth style it is drawn on the finer sphere, its waves as the game's: its poles glow
    // as the game's do.
    var smooth: shield.Shields = try .create(gpa, &shields.textures.table, .high, true, .smooth);
    defer smooth.deinit(gpa);
    const round = try Bubble.create(gpa, &smooth, 300);
    defer round.destroy(gpa);
    try std.testing.expect(round.colours.len > bubble.colours.len);
    bubble.glow(1, 0.5);
    round.glow(1, 0.5);
    try std.testing.expectEqual(bubble.colours[0], round.colours[0]);
    try std.testing.expectEqual(bubble.colours[bubble.colours.len - 1], round.colours[round.colours.len - 1]);
}

test scoopUp {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const pod = try mission.add(.predator, @splat(0));
    const nanny = try mission.addOther(.{ 0, 0, -30000 });
    var ctx = mission.orders();
    ctx.world.tractors = &built.tractors;
    const slot = mission.slot(nanny);
    const state = &slot.state.scoop_up;

    // It takes a tractor, and neither it nor the pod collides with the other.
    try std.testing.expect(try aigeneric.pushShip(ctx, nanny, .scoop_up, pod, aigeneric.Target.whole));
    aigeneric.objectOrders(ctx, nanny);
    try std.testing.expectEqual(0, state.held().?);
    try std.testing.expectEqual(gameobj.Slot.of(nanny), mission.slot(pod).object.passes_through[0]);
    try std.testing.expectEqual(gameobj.Slot.of(pod), slot.object.passes_through[0]);
    // It claims the pod, and flies at it, far off, at full throttle.
    try std.testing.expect(mission.slot(pod).object.flags.tractored);
    try std.testing.expectEqual(.approaching, state.stage);
    scoopUp(ctx, nanny);
    try std.testing.expectEqual(ai.full_throttle, slot.object.throttle);

    // Another ship finds the pod claimed, and gives up.
    const other = try mission.addOther(.{ 0, 0, 30000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, other, .scoop_up, pod, aigeneric.Target.whole));
    aigeneric.objectOrders(ctx, other);
    try std.testing.expectEqual(0, mission.slot(other).object.order_count);

    // Near and at rest, it opens up, and its beams come on over a second, the pod then held still.
    objects.setPosition(&slot.object, &slot.drawn, .{ 0, 0, -5000 });
    scoopUp(ctx, nanny);
    try std.testing.expectEqual(.opening, state.stage);
    mission.clock.frame_start = 10;
    scoopUp(ctx, nanny);
    try std.testing.expectEqual(.locking, state.stage);
    try std.testing.expect(state.lag >= 0 and state.lag <= lag_most);
    mission.clock.frame_start = 60;
    scoopUp(ctx, nanny);
    try std.testing.expect(built.tractors.slots[0].?.shown and built.tractors.slots[0].?.aimed);
    mission.clock.frame_start = 110;
    scoopUp(ctx, nanny);
    try std.testing.expectEqual(.pulling, state.stage);
    try std.testing.expect(mission.slot(pod).object.flags.frozen);

    // Going out, its light dims and its beams hang as they were.
    state.stage = .fading;
    state.since = 200;
    mission.clock.frame_start = 225;
    scoopUp(ctx, nanny);
    try std.testing.expectApproxEqAbs(light_reach / 2, built.tractors.slots[0].?.light.kind.point.range, 1e-2);
    try std.testing.expect(!built.tractors.slots[0].?.aimed);
    mission.clock.frame_start = 250;
    scoopUp(ctx, nanny);
    try std.testing.expectEqual(.waiting, state.stage);
    mission.clock.frame_start = 500;
    scoopUp(ctx, nanny);
    try std.testing.expectEqual(.done, state.stage);
    // Done, the pod is aboard, gone from the mission, and the tractor let go.
    scoopUp(ctx, nanny);
    try std.testing.expectEqual(.stand_in, mission.slot(pod).object.type);
    try std.testing.expectEqual(null, built.tractors.slots[0]);
    try std.testing.expect(!mission.slot(pod).object.flags.tractored);
}

test "Scoop Up gives up on a pod gone first" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const pod = try mission.add(.predator, @splat(0));
    const nanny = try mission.addOther(.{ 0, 0, -30000 });
    var ctx = mission.orders();
    ctx.world.tractors = &built.tractors;
    try std.testing.expect(try aigeneric.pushShip(ctx, nanny, .scoop_up, pod, aigeneric.Target.whole));
    aigeneric.objectOrders(ctx, nanny);
    mission.slot(pod).object.flags.exploding = true;
    scoopUp(ctx, nanny);
    try std.testing.expectEqual(0, mission.slot(nanny).object.order_count);
    try std.testing.expectEqual(null, built.tractors.slots[0]);
}
