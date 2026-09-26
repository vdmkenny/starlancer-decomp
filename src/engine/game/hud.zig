//! `C:\lancer\game\hud.cpp`: the head-up display drawn over the view. `hud_draw` (`0x004843B0`)
//! draws it once a frame; `mission_run` puts it in `sr + 0x88` and Surrender calls it while it
//! renders. [`hud.md`](../../../docs/engine/hud.md) describes the file.
//!
//! Ported so far: `hud_draw`'s order (`draw`), where an element stands, its text, the readouts,
//! the clock, the status lights with the devices' charges, the jump prompt, the player's target
//! with the keys that pick it (`targetKeys`, `drawTarget`), the eject marker, the scanner, the
//! ship status indicator in both its modes, the targeting cluster, the radar's rings and ranges,
//! the windows, their frames and how they open and close ([`hud/windows.zig`](hud/windows.zig)),
//! and what window 7, the power distribution ([`hud/power.zig`](hud/power.zig)), and windows 3
//! and 8, the target display ([`hud/target_display.zig`](hud/target_display.zig)), show. Not yet:
//! the rest of `hud_draw`, whose other elements [`hud.md`](../../../docs/engine/hud.md) lists, and
//! what the other windows show.
//!
//! **Improvement.** The game draws the display with the processor, whichever renderer is running:
//! `hud_text` hands its line to `VFX_string_draw`, out of `vfx.dll`, which blits each glyph into a
//! pane a pixel at a time. OpenReliant draws a glyph as a textured rectangle through the device
//! instead, so on the GPU the display costs the processor nothing and scales without blurring. What
//! it draws is the same: a glyph's bytes index the font's own palette, as they do for
//! `VFX_character_draw`, and index 0 is left clear. The state is the engine's own, an overlay-layer
//! depth and its alpha blend. The software device draws the rectangles too, and `--original` draws
//! the same way, since OpenReliant draws the display larger on a larger window (`scaleFor`), where
//! the game blitted it at its own size.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const fnt = @import("../../formats/fnt.zig");
const math = @import("../surrender/math.zig");
const spr = @import("../../formats/spr.zig");
const tga = @import("../../formats/tga.zig");
const bigfile = @import("bigfile.zig");
const camera = @import("camera.zig");
const gameobj = @import("gameobj.zig");
const hog_snd = @import("hog_snd.zig");
const input = @import("../input.zig");
const language = @import("language.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const srd3d = @import("../surrender/srd3d/srd3d.zig");
const device = @import("../surrender/srd3d/device.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const xtrabits = @import("xtrabits.zig");
const guns = @import("guns.zig");
const objects = @import("objects.zig");
const libcmt = @import("../libcmt.zig");
const collision = @import("collision.zig");
const sound3d = @import("sound3d.zig");
const main = @import("main.zig");
const Clock = main.Clock;
const Vector = math.Vector;

pub const windows = @import("hud/windows.zig");
pub const chase = @import("hud/chase.zig");
pub const damage = @import("hud/damage.zig");
pub const gunnery = @import("hud/gunnery.zig");
pub const missile_display = @import("hud/missile_display.zig");
const missile_lock = @import("main/lock.zig");
pub const power = @import("hud/power.zig");
pub const target_display = @import("hud/target_display.zig");
pub const wing_status = @import("hud/wing_status.zig");

test {
    _ = chase;
    _ = damage;
    _ = gunnery;
    _ = missile_display;
    _ = windows;
    _ = power;
    _ = target_display;
    _ = wing_status;
}

/// The display's sounds (`hud_beep`), samples 15 to 20 of `bank_stdsmp` (the table at
/// `0x00501C78`, each at a volume of 60).
pub const Beep = enum(u3) {
    /// Most of the display's keys: a countermeasure spent.
    done = 0,
    /// A window opening, and closing.
    opens = 1,
    closes = 2,
    /// A key that finds nothing to do: no countermeasure left.
    refused = 3,
    /// A device turning on, and off.
    on = 4,
    off = 5,

    /// The first of them in `bank_stdsmp`, and how loud they play (`0x00501C78`).
    const first_sample = 15;
    const volume = 60;
};

/// `hud_beep` (`0x0048CE70`): the display's sound `which`, in the middle, in the four cockpit views
/// only (`camera.View.fromCockpit`), `view` being this frame's.
pub fn playBeep(sound: *hog_snd.Sound, view: camera.View, which: Beep) void {
    if (!view.fromCockpit()) return;
    const bank = sound.stdsmp orelse return;
    _ = sound.play(bank, Beep.first_sample + @as(usize, @intFromEnum(which)), Beep.volume, hog_snd.once, hog_snd.centre, hog_snd.own_pitch);
}

/// `playBeep` in `world`, where there is one and anything is heard in it.
pub fn beep(world: ?gameobj.World, which: Beep) void {
    const heard = world orelse return;
    const hearing = heard.hearing orelse return;
    playBeep(hearing.sound, heard.view, which);
}

/// The display's sounds asked for where no world is at hand, which `draw` plays later in the same
/// frame: the windows' as they open and close (`windows.Windows`).
pub const Beeps = struct {
    queued: [capacity]Beep = undefined,
    count: u8 = 0,

    /// As many as a frame asks for; past them a sound is left out.
    const capacity = 8;

    pub fn add(beeps: *Beeps, which: Beep) void {
        if (beeps.count == capacity) return;
        beeps.queued[beeps.count] = which;
        beeps.count += 1;
    }

    /// Each in turn (`playBeep`), where `sound` hears them, and none left after.
    pub fn play(beeps: *Beeps, sound: ?*hog_snd.Sound, view: camera.View) void {
        if (sound) |heard| for (beeps.queued[0..beeps.count]) |which| playBeep(heard, view, which);
        beeps.count = 0;
    }

    pub fn slice(beeps: *const Beeps) []const Beep {
        return beeps.queued[0..beeps.count];
    }
};

/// The enemy lock's warning: `stdsmp`'s first sound on voice 1, looped, at `Beep.volume`.
const lock_warning_voice = 1;
const lock_warning_sample = 0;

/// What `hud_place` takes off the screen's size before working a place out, and what it adds back
/// afterwards. An element therefore keeps its place at any resolution.
const inset: i32 = 0x21;
const margin: i32 = 0x10;

/// The screen OpenReliant draws the display for: 1024 by 768, a mode the hardware renderers run in
/// and the size of the retail game's own screenshots. At that size `scaleFor` is 1 and OpenReliant
/// draws the display as the game does. The game's window starts at 640 by 480 (`0x004A85BC`),
/// where the same offsets in pixels stand further in from the edges.
pub const base_screen: [2]u32 = .{ 1024, 768 };

/// **Improvement.** How much larger than its own art the display is drawn in a window of `screen`.
/// The game drew its shapes and its glyphs at their own size whatever the window's, so on a screen
/// several times the one it was drawn for they come out a fraction of the size they had.
/// OpenReliant draws them as large against the window as they stood against `base_screen`, by
/// whichever side has room for less so that the display keeps its shape. Drawing at 1 is what the
/// game does.
pub fn scaleFor(screen: [2]u32) f32 {
    var least: f32 = std.math.floatMax(f32);
    for (screen, base_screen) |size, base| {
        least = @min(least, @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(base)));
    }
    return least;
}

/// Where an element stands, for a fraction of the screen across and down and an offset in pixels
/// (`hud_place`, `0x00482E90`), drawn `scale` times its own size. `screen` is the window's size,
/// which the engine keeps at `sr + 0x1666` and `sr + 0x166A`.
///
/// The fraction is of the window itself, as the game takes it, so the display reaches the edges of
/// a window of any shape. What the display measures in its own pixels, the inset and the margin
/// and the offset, is what `scale` multiplies. At a scale of 1 this is the game's own arithmetic.
pub fn place(screen: [2]u32, offset: [2]i32, across: f32, down: f32, scale: f32) [2]i32 {
    var at: [2]i32 = undefined;
    for (&at, screen, offset, [2]f32{ across, down }) |*out, size, from, fraction| {
        const span = @as(f32, @floatFromInt(size)) - @as(f32, inset) * scale;
        out.* = round(span * fraction) + pixels(margin + from, scale);
    }
    return at;
}

/// `n` of the display's own pixels in the screen's, for a display drawn `scale` times its size,
/// rounded as `sr_round` rounds. At a scale of 1 they are as many.
pub fn pixels(n: i32, scale: f32) i32 {
    return round(@as(f32, @floatFromInt(n)) * scale);
}

/// `point` moved by an offset the display measures in its own pixels (`pixels`).
pub fn scaled(point: [2]i32, offset: [2]i32, scale: f32) [2]i32 {
    var at: [2]i32 = undefined;
    for (&at, point, offset) |*out, from, by| out.* = from + pixels(by, scale);
    return at;
}

test pixels {
    try std.testing.expectEqual(7, pixels(7, 1));
    try std.testing.expectEqual(-14, pixels(-7, 2));
    // Halves round to the even neighbour.
    try std.testing.expectEqual(4, pixels(3, 1.5));
    try std.testing.expectEqual(8, pixels(5, 1.5));
    try std.testing.expectEqual([2]i32{ 100 - 8, 20 }, scaled(.{ 100, 20 }, .{ -4, 0 }, 2));
}

/// How far apart the items of the display's grid stand, and where its first one does
/// (`hud_grid_place`, `0x00482F00`).
pub const grid_across: i32 = 0x30;
pub const grid_down: i32 = 0x26;
pub const grid_offset: [2]i32 = .{ -156, 0 };

/// Where the item of `index` stands in the grid: from half-way across the screen, two to a row.
/// The grid is measured in the display's own pixels, so `scale` carries it too.
pub fn gridPlace(screen: [2]u32, index: i32, scale: f32) [2]i32 {
    var at = place(screen, grid_offset, 0.5, 0, scale);
    at[0] += pixels(@rem(index, 2) * grid_across, scale);
    at[1] += pixels(@divTrunc(index, 2) * grid_down, scale);
    return at;
}

/// A float turned into an integer as `sr_round` (`0x004C3330`) does.
pub const round = math.round;

/// A point of the screen in pixels, unrounded.
pub const Point = @Vector(2, f32);

/// `point` in whole pixels.
fn pointOf(point: [2]i32) Point {
    return .{ @floatFromInt(point[0]), @floatFromInt(point[1]) };
}

/// `point` rounded to whole pixels as `sr_round` rounds.
fn whole(point: Point) Point {
    return .{ math.roundEven(point[0]), math.roundEven(point[1]) };
}

/// The character codes `font_open` caches the widths of. A glyph of a higher code is never drawn.
pub const cached_codes = fnt.engine_limit;

/// A font as the display draws with it (`font_open`, `0x00480D70`): the font, and the width of
/// every code it caches, which is every code below `cached_codes` that the font has a glyph for.
pub const Opened = struct {
    font: fnt.Font,
    widths: [cached_codes]u16,
    /// What a font with no palette of its own, as `smlfont.fnt`, is drawn with: VFX's global
    /// palette, which `hud_draw` makes of the display's set. Its bytes index the palette of the
    /// pane it is drawn into.
    global: ?*const [spr.palette_size]u8,
    /// How the glyphs' bytes become colours.
    paint: Paint = .palette,
    /// What the GPU draws each code with, made as each is first drawn.
    images: [cached_codes]?srtexture.Image = @splat(null),

    pub const Paint = enum {
        /// Through the font's palette, or else VFX's global one, as the display's text is.
        palette,
        /// As levels of one colour, as the pause menu's text is. Its bytes are coverage levels
        /// that `menu_text_remap` sends to entries 1 to 15 of VFX's palette, which
        /// `hud_palette_ramp` sets to the colour times level / 15; level 0 is clear. A glyph is
        /// drawn in grey at level / 15 and tinted with the colour, which comes to the same.
        ///
        /// **Fix.** Level 16, which a few pixels of the menu's fonts use, reads past the game's
        /// table into another variable's byte (`audio_saved_effects`); OpenReliant draws it as 15.
        ramp,
    };

    /// Takes the widths out of `font`, as `font_open` does with `VFX_character_width`, and keeps
    /// `global` for a font with no palette.
    pub fn open(font: fnt.Font, global: ?*const [spr.palette_size]u8) Opened {
        var opened: Opened = .{ .font = font, .widths = @splat(0), .global = global };
        const codes = @min(font.header.count, cached_codes);
        for (0..codes) |code| {
            const glyph = font.glyph(code) orelse continue;
            opened.widths[code] = @truncate(glyph.width);
        }
        return opened;
    }

    /// `font` opened to be drawn as levels of one colour, as the pause menu's fonts are.
    pub fn ramp(font: fnt.Font) Opened {
        var opened: Opened = .open(font, null);
        opened.paint = .ramp;
        return opened;
    }

    /// Frees the glyphs the GPU was given.
    pub fn deinit(opened: *Opened, gpa: Allocator) void {
        for (&opened.images) |*image| if (image.*) |made| {
            made.deinit(gpa);
            image.* = null;
        };
    }

    /// How wide `text` is drawn, the sum of its codes' cached widths (`font_text_width`,
    /// `0x00480E10`). A code the font does not reach counts as nothing.
    pub fn textWidth(opened: Opened, text: []const u8) u32 {
        var width: u32 = 0;
        for (text) |code| {
            if (code < cached_codes) width += opened.widths[code];
        }
        return width;
    }
};

/// Where a line of text stands from the place it is drawn at (`hud_text`, `0x00480E40`), as the
/// pause menu's items give it too (`hudoptions.menu.Item.Style`, three bits).
pub const Align = enum(u3) {
    left = 0,
    centre = 1,
    right = 2,
    _,
};

/// The sprite set the display's shapes come from: `HUDHARD.SPR` for the hardware renderers and
/// `HUDSOFT.SPR` for the software one.
pub const hardware_shapes = "HUDHARD.SPR";
pub const software_shapes = "HUDSOFT.SPR";

/// The block of the display's set that `hud_draw` makes VFX's global palette of every frame
/// under the hardware renderers (`0x00428410`), at the brightness `0x00569718` holds, which
/// `hud_init` sets to 1 and nothing changes. `VFX_shape_draw` draws a shape whose entry names no
/// palette with the global one, and no entry of a shipped set names one: so every shape of the
/// display is drawn with this block's palette, those after the set's second palette block
/// included, and the ships' schematics too. Nothing in the display makes another block the
/// global palette.
pub const global_palette_block = 0x77;

/// VFX's global palette as `hud_draw` sets it from the display's set, or null for a set whose
/// block there is no palette.
pub fn globalPalette(set: spr.Sprite) ?*const [spr.palette_size]u8 {
    if (global_palette_block >= set.count()) return null;
    return switch (set.block(global_palette_block)) {
        .palette => |found| found,
        else => null,
    };
}

test globalPalette {
    // A set whose every entry but the last is empty, the last a palette of 6-bit levels.
    const count = global_palette_block + 1;
    const palette_at = @sizeOf(spr.Header) + count * @sizeOf(spr.DirectoryEntry);
    var bytes: [palette_at + spr.palette_size]u8 = undefined;
    const header: spr.Header = .{ .version = spr.magic.*, .shape_count = count };
    @memcpy(bytes[0..@sizeOf(spr.Header)], std.mem.asBytes(&header));
    for (0..count) |i| {
        const entry: spr.DirectoryEntry = .{ .offset = palette_at, .reserved = 0 };
        @memcpy(bytes[@sizeOf(spr.Header) + i * @sizeOf(spr.DirectoryEntry) ..][0..@sizeOf(spr.DirectoryEntry)], std.mem.asBytes(&entry));
    }
    for (bytes[palette_at..], 0..) |*level, i| level.* = @intCast(i % 64);
    const global = globalPalette(try .parse(&bytes)).?;
    try std.testing.expectEqual(@intFromPtr(&bytes[palette_at]), @intFromPtr(global));

    // Every line is drawn in its entry's colour, 6-bit levels widened; white without a palette.
    const art: Art = .{ .set = undefined, .images = &.{}, .global = global };
    const entry = art.paletteColour(1);
    try std.testing.expectEqual(@as(f32, @floatFromInt(spr.expandLevel(3))) / 255, entry[0]);
    try std.testing.expectEqual(@as(f32, @floatFromInt(spr.expandLevel(5))) / 255, entry[2]);
    try std.testing.expectEqual(1, entry[3]);
    const bare: Art = .{ .set = undefined, .images = &.{} };
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 1 }, bare.paletteColour(1));

    // A set too short to hold the block has none.
    const empty = comptime std.mem.toBytes(spr.Header{ .version = spr.magic.*, .shape_count = 0 });
    try std.testing.expectEqual(null, globalPalette(try .parse(&empty)));
}

/// A set of the display's shapes, with an image made of each as it is first drawn. Every entry of
/// a shipped set names no palette, so VFX draws each shape with its global palette, which
/// `hud_draw` makes of the display's own set; a set given none takes the nearest palette at or
/// before a shape, as the tools show them.
pub const Art = struct {
    set: spr.Sprite,
    images: []?srtexture.Image,
    /// The palette every shape is drawn with: VFX's global palette.
    global: ?*const [spr.palette_size]u8 = null,

    pub fn init(gpa: Allocator, set: spr.Sprite, global: ?*const [spr.palette_size]u8) Allocator.Error!Art {
        const images = try gpa.alloc(?srtexture.Image, set.count());
        @memset(images, null);
        return .{ .set = set, .images = images, .global = global };
    }

    pub fn deinit(art: *Art, gpa: Allocator) void {
        for (art.images) |held| if (held) |made| made.deinit(gpa);
        gpa.free(art.images);
    }

    /// Entry `index` of the palette every shape is drawn with, the colour `VFX_line_draw` draws a
    /// line of that index in; white for a set with none.
    pub fn paletteColour(art: Art, index: u8) [4]f32 {
        const palette = art.global orelse return .{ 1, 1, 1, 1 };
        var colour: [4]f32 = .{ 0, 0, 0, 1 };
        for (colour[0..3], palette[@as(usize, index) * 3 ..][0..3]) |*channel, level| {
            channel.* = @as(f32, @floatFromInt(spr.expandLevel(level))) / 255;
        }
        return colour;
    }

    pub fn shape(art: Art, index: usize) ?spr.Shape {
        if (index >= art.set.count()) return null;
        return switch (art.set.block(index)) {
            .shape => |found| found,
            else => null,
        };
    }

    /// The image of the shape at `index`, made the first time it is drawn. Index 0 of a shape is
    /// clear, as it is wherever the sprites are drawn.
    fn image(art: *Art, gpa: Allocator, index: usize) (spr.Error || Allocator.Error)!?*srtexture.Image {
        if (index >= art.images.len) return null;
        if (art.images[index]) |*made| return made;
        const found = art.shape(index) orelse return null;
        const palette = art.global orelse art.set.paletteFor(index) orelse return null;
        var expanded: [spr.palette_size]u8 = undefined;
        spr.expandPalette(palette, &expanded);

        const indices = try found.decode(gpa);
        defer gpa.free(indices);
        const rgba = try gpa.alloc(u8, indices.len * 4);
        errdefer gpa.free(rgba);
        for (indices, 0..) |at, pixel| {
            const entry = expanded[@as(usize, at) * 3 ..][0..3];
            for (0..3) |channel| rgba[pixel * 4 + channel] = entry[channel];
            rgba[pixel * 4 + 3] = if (at == 0) 0 else 255;
        }
        art.images[index] = try srtexture.Image.single(gpa, found.width(), found.height(), rgba);
        return &art.images[index].?;
    }
};

/// Draws the shape at `index` with its anchor at `at`, `scale` times its own size. A shape's
/// bounds are in a frame whose origin is that anchor, so they say where it hangs from the point.
pub fn drawShape(
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    index: usize,
    at: [2]i32,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!void {
    return drawShapeWith(art, gpa, target, index, at, colour, scale, .{});
}

/// How a shape is drawn besides as it stands.
pub const Draw = struct {
    /// Flipped within its own bounds, which keep their place.
    mirror: Mirror = .{},
    /// Only what falls inside a rectangle of the screen, as a VFX pane clips what is drawn into
    /// it.
    clip: ?Clip = null,
    /// Shaken a row at a time (`hud_blit`), as the display draws what it shakes while the player
    /// is hit; null for drawn still.
    shake: ?Shake = null,
};

/// How the display shakes while the player is hit (`hud_blit`, `0x0048C6E0`): each row of a shape
/// moves right by `rowShift` of the camera's shake, `hit_shake`, or for a shape flipped both ways
/// of the interference itself, drawing from `random`.
pub const Shake = struct {
    hit_shake: f32,
    interference: f32,
    random: *libcmt.Rand,

    /// How far the next row of a shape flipped as `mirror` says moves.
    fn row(shake: Shake, mirror: Mirror) i32 {
        const amount = if (mirror.across and mirror.down) shake.interference else shake.hit_shake;
        return rowShift(amount, shake.random);
    }
};

/// How far a shake of `amount` moves a row, in the display's own pixels: nothing while it is not
/// above zero, and otherwise a random share of `10 * amount`, rounded as `sr_round` rounds.
pub fn rowShift(amount: f32, random: ?*libcmt.Rand) i32 {
    if (!(amount > 0)) return 0;
    const source = random orelse return 0;
    return math.round(source.fraction() * row_reach * amount);
}

/// How far a shake of 1 moves a row at most (`0x004DC520`).
const row_reach = 10;

/// The display's interference as the player's ship is hit (`hud_interference`, `0x00588700`):
/// while it lasts the display shakes (`Shake`) and, in the view ahead, the screen's flash shows red
/// at it (`main.flash`).
pub const Interference = struct {
    level: f32 = 0,
    /// The tick it last faded at (`0x00588728`), and last sounded at (`0x00587CD0`).
    faded_at: i32 = 0,
    sounded_at: i32 = 0,

    /// What a hit sets it to, how far it fades a tick (`0x004DC4D0`), the buffered sound it plays
    /// at the player's ship at that loudness, and the least ticks between two, to which a random
    /// share of as many more is added.
    const hit_level: f32 = 0.3;
    const fade_per_tick: f32 = 0.005;
    const sound = 12;
    const loudness: f32 = 10000;
    const sound_gap = 15;

    /// `hud_interference_start` (`0x00494890`), as `object_damage` and `object_armor_damage` hit
    /// the player's ship: the interference at `hit_level`, and its sound at the ship once more than
    /// `sound_gap` ticks and a random share of as many more have passed since the last.
    pub fn start(interference: *Interference, world: gameobj.World) void {
        const frame_start = world.clock.frame_start;
        const gap = @rem(world.random.rand(), sound_gap) + sound_gap;
        if (gap < frame_start - interference.sounded_at) {
            interference.sounded_at = frame_start;
            if (world.hearing) |hearing| {
                const ship = &world.objects.slots[world.objects.player];
                hearing.sound.bufferAt(sound, ship.drawn.position, hearing.camera.*, loudness);
            }
        }
        interference.level = hit_level;
    }

    /// `hud_interference_fade` (`0x004948F0`), once a frame at `frame_start`: `fade_per_tick` less
    /// for each tick since it last faded, to nothing.
    pub fn fade(interference: *Interference, frame_start: i32) void {
        const ticks: f32 = @floatFromInt(frame_start - interference.faded_at);
        interference.level = @max(interference.level - ticks * fade_per_tick, 0);
        interference.faded_at = frame_start;
    }

    /// How the display shakes this frame, `hit_shake` the camera's shake: not at all while the
    /// interference is out.
    pub fn shake(interference: Interference, hit_shake: f32, random: *libcmt.Rand) ?Shake {
        if (!(interference.level > 0)) return null;
        return .{ .hit_shake = hit_shake, .interference = interference.level, .random = random };
    }
};

/// Which ways `VFX_shape_draw_mirrored` flips a shape, the two low bits of its mode: 1 across, 2
/// down, 3 both. Its bit 4, drawing through a remap table, the display does not use with it.
pub const Mirror = packed struct(u2) {
    across: bool = false,
    down: bool = false,

    /// The flips of a mode as the display's tables give it.
    pub fn of(mode: u2) Mirror {
        return @bitCast(mode);
    }
};

/// A rectangle of the screen in its pixels: its left and top edges inside it, its right and
/// bottom ones not.
pub const Clip = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    /// What lies inside both.
    pub fn intersect(a: Clip, b: Clip) Clip {
        return .{
            .left = @max(a.left, b.left),
            .top = @max(a.top, b.top),
            .right = @min(a.right, b.right),
            .bottom = @min(a.bottom, b.bottom),
        };
    }

    /// Whether it holds no pixel at all.
    pub fn empty(clip: Clip) bool {
        return clip.left >= clip.right or clip.top >= clip.bottom;
    }

    /// Where an edge `n` of the display's own pixels past `from` falls on the screen, for a display
    /// drawn `scale` times its size, unrounded.
    pub fn edge(from: f32, n: i32, scale: f32) f32 {
        return from + @as(f32, @floatFromInt(n)) * scale;
    }
};

test Clip {
    const a: Clip = .{ .left = 0, .top = 10, .right = 100, .bottom = 50 };
    const b: Clip = .{ .left = 20, .top = 0, .right = 200, .bottom = 40 };
    try std.testing.expectEqual(Clip{ .left = 20, .top = 10, .right = 100, .bottom = 40 }, a.intersect(b));
    try std.testing.expect(!a.intersect(b).empty());
    try std.testing.expect(a.intersect(.{ .left = 100, .top = 0, .right = 200, .bottom = 40 }).empty());
    try std.testing.expectEqual(16, Clip.edge(10, 3, 2));
}

/// Draws the shape at `index` as `drawShape` does, mirrored or clipped as `how` says.
pub fn drawShapeWith(
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    index: usize,
    at: [2]i32,
    colour: [4]f32,
    scale: f32,
    how: Draw,
) (spr.Error || Allocator.Error)!void {
    const found = art.shape(index) orelse return;
    const image = try art.image(gpa, index) orelse return;
    const corner: [2]f32 = .{
        @as(f32, @floatFromInt(at[0])) + @as(f32, @floatFromInt(found.header.x1)) * scale,
        @as(f32, @floatFromInt(at[1])) + @as(f32, @floatFromInt(found.header.y1)) * scale,
    };
    drawImage(target, image, corner, colour, scale, how);
}

/// Draws `image` with its top left corner at `corner` on the screen, `scale` times its own size,
/// mirrored, clipped or shaken as `how` says: shaken, a row at a time, each moved right by the
/// shake's `Shake.row`.
pub fn drawImage(target: device.Device, image: *srtexture.Image, corner: [2]f32, colour: [4]f32, scale: f32, how: Draw) void {
    const width = @as(f32, @floatFromInt(image.width())) * scale;
    const height = @as(f32, @floatFromInt(image.height())) * scale;
    const u: [2]f32 = if (how.mirror.across) .{ 1, 0 } else .{ 0, 1 };
    const v: [2]f32 = if (how.mirror.down) .{ 1, 0 } else .{ 0, 1 };
    const tint = device.pack(colour);
    const shake = how.shake orelse {
        drawPart(target, image, .{ .left = corner[0], .top = corner[1], .right = corner[0] + width, .bottom = corner[1] + height }, u, v, tint, how.clip);
        return;
    };
    const rows = image.height();
    const per_row = (v[1] - v[0]) / @as(f32, @floatFromInt(rows));
    for (0..rows) |row| {
        const down: f32 = @floatFromInt(row);
        const left = corner[0] + @as(f32, @floatFromInt(shake.row(how.mirror))) * scale;
        const top = corner[1] + down * scale;
        const along: [2]f32 = .{ v[0] + per_row * down, v[0] + per_row * (down + 1) };
        drawPart(target, image, .{ .left = left, .top = top, .right = left + width, .bottom = top + scale }, u, along, tint, how.clip);
    }
}

/// The states the display draws with: over the scene, blended by what it covers, textured by
/// `texture` where there is one.
fn overlayState(texture: ?*srtexture.Image) device.State {
    return .{
        .texture = texture,
        .depth = srd3d.depth(.overlay, .alpha),
        .blend = srd3d.factors(.alpha),
    };
}

/// Draws the part of `image` between texture coordinates `u` and `v` over the rectangle `edges`
/// of the screen, cut to `clip`.
fn drawPart(target: device.Device, image: *srtexture.Image, edges: Clip, u_in: [2]f32, v_in: [2]f32, tint: u32, clip: ?Clip) void {
    var kept = edges;
    var u = u_in;
    var v = v_in;
    if (clip) |cut| {
        kept = edges.intersect(cut);
        if (kept.empty()) return;
        // Each texture coordinate follows its edge in, in the image's own proportion.
        for ([2]f32{ kept.left, kept.right }, [2]f32{ kept.top, kept.bottom }, 0..) |x, y, end| {
            u[end] = u_in[0] + (u_in[1] - u_in[0]) * (x - edges.left) / (edges.right - edges.left);
            v[end] = v_in[0] + (v_in[1] - v_in[0]) * (y - edges.top) / (edges.bottom - edges.top);
        }
    }
    const corners = [4]device.Vertex{
        .{ .x = kept.left, .y = kept.top, .z = 1, .rhw = 1, .diffuse = tint, .u = u[0], .v = v[0] },
        .{ .x = kept.right, .y = kept.top, .z = 1, .rhw = 1, .diffuse = tint, .u = u[1], .v = v[0] },
        .{ .x = kept.right, .y = kept.bottom, .z = 1, .rhw = 1, .diffuse = tint, .u = u[1], .v = v[1] },
        .{ .x = kept.left, .y = kept.bottom, .z = 1, .rhw = 1, .diffuse = tint, .u = u[0], .v = v[1] },
    };
    target.draw(overlayState(image), .fan, &corners, null);
}

/// A glyph as the GPU draws it: the font's palette, or the global one, looked up for each of its
/// bytes, with index 0 left clear. Made the first time the glyph is drawn and kept for the rest of
/// the run.
fn glyphImage(opened: *Opened, gpa: Allocator, code: u8) Allocator.Error!?*srtexture.Image {
    if (opened.images[code]) |*made| return made;
    const glyph = opened.font.glyph(code) orelse return null;
    const palette = switch (opened.paint) {
        .palette => opened.font.palette orelse opened.global orelse return null,
        .ramp => null,
    };
    if (glyph.width == 0 or opened.font.header.height == 0) return null;

    const rgba = try gpa.alloc(u8, glyph.pixels.len * 4);
    errdefer gpa.free(rgba);
    for (glyph.pixels, 0..) |index, at| {
        const pixel = rgba[at * 4 ..][0..4];
        if (palette) |colours| {
            // The palette holds 6-bit levels, as the sprites' does.
            for (pixel[0..3], colours[@as(usize, index) * 3 ..][0..3]) |*channel, level| channel.* = spr.expandLevel(level);
        } else {
            @memset(pixel[0..3], rampLevel(index));
        }
        pixel[3] = if (index == 0) 0 else 255;
    }
    opened.images[code] = try srtexture.Image.single(gpa, glyph.width, opened.font.header.height, rgba);
    return &opened.images[code].?;
}

/// Coverage `level` of a ramp font as a grey, 0 to 255 for the levels 0 to 15.
fn rampLevel(level: u8) u8 {
    return @intCast(@as(u32, @min(level, ramp_top)) * 255 / ramp_top);
}

/// The top of the ramp `hud_palette_ramp` sets: entries 1 to 15.
const ramp_top = 15;

/// Draws `text` at `at`, tinted by `colour`, `scale` times the font's own size, and returns where
/// the line ends. `hud_text` aligns the line first; the glyphs then follow one another by their
/// own widths, as `VFX_string_draw` moves along by what each glyph returns.
pub fn drawText(
    opened: *Opened,
    gpa: Allocator,
    target: device.Device,
    at: [2]i32,
    text: []const u8,
    colour: [4]f32,
    alignment: Align,
    scale: f32,
) Allocator.Error!i32 {
    if (text.len == 0) return at[0];
    var x: f32 = @floatFromInt(textLeft(opened.*, at[0], text, alignment, scale));
    const top: f32 = @floatFromInt(at[1]);
    const height = @as(f32, @floatFromInt(opened.font.header.height)) * scale;
    const tint = device.pack(colour);
    for (text) |code| {
        const width = @as(f32, @floatFromInt(opened.widths[code])) * scale;
        defer x += width;
        const image = try glyphImage(opened, gpa, code) orelse continue;
        drawPart(target, image, .{ .left = x, .top = top, .right = x + width, .bottom = top + height }, .{ 0, 1 }, .{ 0, 1 }, tint, null);
    }
    return @intFromFloat(x);
}

/// Where a line of `text` starts, for a line drawn at `x` with `alignment` and `scale`: `hud_text`
/// takes half its width off a centred line and the whole of it off one to the right. The width is
/// in the display's own pixels, so `scale` carries it too.
pub fn textLeft(opened: Opened, x: i32, text: []const u8, alignment: Align, scale: f32) i32 {
    const width: i32 = @intCast(opened.textWidth(text));
    const shift: i32 = switch (alignment) {
        .centre => width >> 1,
        .right => width,
        else => return x,
    };
    return x - pixels(shift, scale);
}

test place {
    // Half of the way across is the middle of the screen, which is what the inset and the margin
    // between them come to: (640 - 0x21) / 2 rounded is 304, and 0x10 on top is 320.
    try std.testing.expectEqual([2]i32{ 320, 240 }, place(.{ 640, 480 }, .{ 0, 0 }, 0.5, 0.5, 1));
    try std.testing.expectEqual([2]i32{ 960, 540 }, place(.{ 1920, 1080 }, .{ 0, 0 }, 0.5, 0.5, 1));
    // The offset is added as it stands, and a fraction of nothing leaves only the margin.
    try std.testing.expectEqual([2]i32{ 6, 116 }, place(.{ 640, 480 }, .{ -10, 100 }, 0, 0, 1));
    // The whole way across stops a margin and an inset short of the far edge.
    try std.testing.expectEqual([2]i32{ 1903, 1063 }, place(.{ 1920, 1080 }, .{ 0, 0 }, 1, 1, 1));
}

test "a scaled element keeps its share of the window" {
    // Drawn twice its own size, what the display measures in its own pixels doubles: the margin,
    // the offset and the inset. The fraction of the window does not.
    try std.testing.expectEqual([2]i32{ 12, 232 }, place(.{ 640, 480 }, .{ -10, 100 }, 0, 0, 2));
    // Half of the way across stays within a pixel or so of the middle of the window: the inset
    // grows with the display, which moves the middle by half of it.
    try std.testing.expectEqual([2]i32{ 319, 239 }, place(.{ 640, 480 }, .{ 0, 0 }, 0.5, 0.5, 2));
    try std.testing.expectEqual([2]i32{ 1278, 718 }, place(.{ 2560, 1440 }, .{ 0, 0 }, 0.5, 0.5, 3));
    // The whole way across keeps the margin and the inset, both grown with the display.
    try std.testing.expectEqual([2]i32{ 2509, 1389 }, place(.{ 2560, 1440 }, .{ 0, 0 }, 1, 1, 3));
}

test scaleFor {
    // The screen the display is drawn for leaves it at its own size.
    try std.testing.expectEqual(1, scaleFor(base_screen));
    // Wider than it is tall: the side with room for less wins.
    try std.testing.expectEqual(1.875, scaleFor(.{ 2560, 1440 }));
    try std.testing.expectEqual(2, scaleFor(.{ 2048, 1536 }));
    // A window smaller than the screen it was drawn for draws it smaller, so that it still fits.
    try std.testing.expectEqual(0.625, scaleFor(.{ 640, 480 }));
}

test gridPlace {
    const first = gridPlace(.{ 640, 480 }, 0, 1);
    // From half-way across, less the grid's own offset.
    try std.testing.expectEqual(place(.{ 640, 480 }, grid_offset, 0.5, 0, 1), first);
    // Two to a row: the next stands a column across, the one after a row down.
    try std.testing.expectEqual([2]i32{ first[0] + grid_across, first[1] }, gridPlace(.{ 640, 480 }, 1, 1));
    try std.testing.expectEqual([2]i32{ first[0], first[1] + grid_down }, gridPlace(.{ 640, 480 }, 2, 1));
    try std.testing.expectEqual([2]i32{ first[0] + grid_across, first[1] + grid_down }, gridPlace(.{ 640, 480 }, 3, 1));
    // Scaled, the grid's own spacing grows with it.
    const larger = gridPlace(.{ 640, 480 }, 3, 2);
    const larger_first = gridPlace(.{ 640, 480 }, 0, 2);
    try std.testing.expectEqual([2]i32{ larger_first[0] + grid_across * 2, larger_first[1] + grid_down * 2 }, larger);
}

test Opened {
    const font = try fnt.Font.parse(comptime fnt.testing.font(false));
    const opened: Opened = .open(font, null);

    // Every code the font draws has its width cached, and the rest count as nothing.
    var drawn: usize = 0;
    for (0..cached_codes) |code| {
        const glyph = font.glyph(code) orelse {
            try std.testing.expectEqual(0, opened.widths[code]);
            continue;
        };
        drawn += 1;
        try std.testing.expectEqual(@as(u16, @truncate(glyph.width)), opened.widths[code]);
    }
    try std.testing.expect(drawn > 0);

    // A line is as wide as its codes together, and an empty one is nothing.
    try std.testing.expectEqual(0, opened.textWidth(""));
    const code: u8 = @intCast(for (0..cached_codes) |c| {
        if (opened.widths[c] > 0) break c;
    } else unreachable);
    const twice = [2]u8{ code, code };
    try std.testing.expectEqual(@as(u32, opened.widths[code]) * 2, opened.textWidth(&twice));
}

test textLeft {
    const opened: Opened = .open(try fnt.Font.parse(comptime fnt.testing.font(false)), null);
    const code: u8 = @intCast(for (0..cached_codes) |c| {
        if (opened.widths[c] > 0) break c;
    } else unreachable);
    const text = [2]u8{ code, code };
    const width: i32 = @intCast(opened.textWidth(&text));

    try std.testing.expectEqual(100, textLeft(opened, 100, &text, .left, 1));
    try std.testing.expectEqual(100 - (width >> 1), textLeft(opened, 100, &text, .centre, 1));
    try std.testing.expectEqual(100 - width, textLeft(opened, 100, &text, .right, 1));
    // Drawn larger, the line is wider, so a centred one starts further back.
    try std.testing.expectEqual(100 - width * 2, textLeft(opened, 100, &text, .right, 2));
}

test "a ramp font's glyphs are levels of grey" {
    // Level 0 clear, 15 white, and 16, which the game reads past its table for, white too.
    try std.testing.expectEqual(0, rampLevel(0));
    try std.testing.expectEqual(17, rampLevel(1));
    try std.testing.expectEqual(255, rampLevel(15));
    try std.testing.expectEqual(255, rampLevel(16));

    const gpa = std.testing.allocator;
    var opened: Opened = .ramp(try fnt.Font.parse(comptime fnt.testing.font(true)));
    defer opened.deinit(gpa);
    const code: u8 = @intCast(for (0..cached_codes) |c| {
        if (opened.widths[c] > 0) break c;
    } else unreachable);
    const image = (try glyphImage(&opened, gpa, code)).?;
    const glyph = opened.font.glyph(code).?;
    for (glyph.pixels, 0..) |level, at| {
        const pixel = image.levels[0].rgba[at * 4 ..][0..4];
        try std.testing.expectEqual(rampLevel(level), pixel[0]);
        try std.testing.expectEqual(pixel[0], pixel[2]);
        try std.testing.expectEqual(@as(u8, if (level == 0) 0 else 255), pixel[3]);
    }
}

test drawText {
    const gpa = std.testing.allocator;
    var opened: Opened = .open(try fnt.Font.parse(comptime fnt.testing.font(true)), null);
    defer opened.deinit(gpa);

    // A device that keeps what it was asked to draw.
    var recorder: device.testing.Recorder = .{ .gpa = gpa };
    defer recorder.deinit();

    // The fixture's code 1 is the only one with a glyph; code 0 has none and draws nothing.
    const text = [_]u8{ 1, 0, 1 };
    const ended = try drawText(&opened, gpa, recorder.interface(), .{ 10, 20 }, &text, .{ 1, 1, 1, 1 }, .left, 1);
    try std.testing.expectEqual(2, recorder.draws.items.len);
    for (recorder.draws.items) |made| {
        try std.testing.expectEqual(device.Primitive.fan, made.primitive);
        try std.testing.expectEqual(4, made.count);
    }

    // The first glyph stands where the line does, and the second follows the first's width along,
    // the code with no glyph having moved nothing.
    const width: f32 = @floatFromInt(opened.widths[1]);
    try std.testing.expectEqual(10, recorder.drawn(0)[0].x);
    try std.testing.expectEqual(20, recorder.drawn(0)[0].y);
    try std.testing.expectEqual(10 + width, recorder.drawn(1)[0].x);
    try std.testing.expectEqual(@as(i32, @intFromFloat(10 + width * 2)), ended);

    // Each is as tall as the font and as wide as the glyph, and drawn over the scene.
    const height: f32 = @floatFromInt(opened.font.header.height);
    try std.testing.expectEqual(10 + width, recorder.drawn(0)[2].x);
    try std.testing.expectEqual(20 + height, recorder.drawn(0)[2].y);
    const state = recorder.draws.items[0].state;
    try std.testing.expect(!state.depth.testing);
    try std.testing.expect(!state.depth.writing);
    try std.testing.expectEqual(srd3d.factors(.alpha), state.blend);
    try std.testing.expectEqual(overlayState(state.texture), state);

    // Drawn twice the size, a glyph covers twice as much and the line is twice as long.
    recorder.clear();
    _ = try drawText(&opened, gpa, recorder.interface(), .{ 0, 0 }, text[0..1], .{ 1, 1, 1, 1 }, .left, 2);
    try std.testing.expectEqual(width * 2, recorder.drawn(0)[2].x);
    try std.testing.expectEqual(height * 2, recorder.drawn(0)[2].y);
}

/// What `hud_init` loads for the display to draw with.
pub const Resources = struct {
    art: Art,
    /// `blufont.fnt` (`0x00595490`), which every line of the display's own text is written in: the
    /// readouts, the clock, the cluster's figures, the view's name and the windows. `0x004A2AF0`
    /// opens it for the hardware renderers, and `soft_blufont.fnt`, the same letters, for the
    /// software one; OpenReliant draws the hardware display.
    font: Opened,
    /// The fonts the target's ranges are written in.
    target_fonts: TargetFonts,
    /// The power ball's tables, and the image it is drawn into.
    ball: *power.Ball,

    pub const font_name = "BLUFONT.FNT";

    /// Loads what the display draws with from the resources' archive: `shapes`, the display's
    /// set, with its global palette; the fonts, which `0x004A2AF0` opens; and the power ball,
    /// which `hud_init` works out.
    pub fn load(gpa: Allocator, archive: bigfile.Hog, shapes: spr.Sprite) !Resources {
        const global = globalPalette(shapes);
        return .{
            .art = try .init(gpa, shapes, global),
            .font = try openFont(gpa, archive, font_name, global),
            .target_fonts = .{
                .small = try openFont(gpa, archive, TargetFonts.small_name, global),
                .new = try openFont(gpa, archive, TargetFonts.new_name, global),
            },
            .ball = try .create(gpa, try tga.decode(gpa, try archive.readFile(gpa, power.picture_name))),
        };
    }

    fn openFont(gpa: Allocator, archive: bigfile.Hog, name: []const u8, global: ?*const [spr.palette_size]u8) !Opened {
        return .open(try fnt.Font.parse(try archive.readFile(gpa, name)), global);
    }
};

/// A ship's schematic, the ship status indicator's picture of it, and what its images are made in.
pub const Schematic = struct {
    art: *Art,
    gpa: Allocator,
};

/// What `hud_draw` reads of the game for a frame.
pub const Frame = struct {
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    /// The scene as it is drawn this frame; null before the first.
    sight: ?Sight,
    all: *create.Objects,
    player: *const input.Player,
    clock: *const Clock,
    /// Last frame's view (`camera_view_last`), and the cockpit's mode.
    last_view: camera.View,
    mode: camera.CockpitMode,
    strings: *const language.Language,
    /// The camera's shake, which shakes the power ball too, and the C runtime's `rand`, which the
    /// ball draws from.
    hit_shake: f32,
    random: *libcmt.Rand,
    /// What the mission has ready for JUMP DRIVE.
    ready: *Readiness,
    /// Whether the `Scanner` command has the player look for an object.
    scanning: bool = false,
    edge_line: EdgeLine,
    multiplayer: bool = false,
    /// The view this frame (`camera_view`), and the sound the locked tone plays through; none
    /// where nothing is heard.
    view: camera.View = .cockpit,
    sound: ?*hog_snd.Sound = null,
};

/// `hud_draw` (`0x004843B0`): the display for a frame, in its order. First it takes the player's
/// target, plays or ends the missile lock's tone (`missile_lock.Lock.sound`) and runs the devices'
/// charges, in every view. In the view ahead from the cockpit it
/// then draws the jump prompt, the target, the eject marker, the scanner and the status lights;
/// in the others the view's name. Then, in the view ahead, the instruments: the readouts, the
/// ship status indicator, the targeting cluster, the radar, the reticle and the clock. Last, in
/// every view, the windows move on, and in the view ahead are drawn.
pub fn draw(state: *State, resources: *Resources, frame: Frame) (spr.Error || Allocator.Error)!void {
    const slot = &frame.all.slots[frame.all.player];
    const live = &slot.object;
    const frame_duration = frame.clock.frame_duration;
    const scale = scaleFor(frame.screen);
    const colour: [4]f32 = .{ 1, 1, 1, 1 };
    const art = &resources.art;
    const ahead = instrumented(frame.last_view);
    state.followTarget(frame.all, frame.multiplayer);
    if (frame.sound) |sound| state.lock.sound(sound, frame.view);
    state.runCharges(live, frame_duration, frame.multiplayer);
    try state.caption.draw(&resources.font, frame.gpa, frame.target, frame.screen, frame.all.mission_number, frame.strings.*, frame.clock.game_ticks, colour, scale);
    // Where the lead cursor stands, which the reticle closes on, whether the enemy lock's light
    // shows, and how the display shakes (`hud_blit`).
    var lead: ?[2]i32 = null;
    var lock_lit = false;
    const shake = state.interference.shake(frame.hit_shake, frame.random);
    if (ahead) {
        try state.drawJumpPrompt(frame.ready, art, frame.gpa, frame.target, frame.screen, frame_duration, colour, scale);
        if (frame.sight) |sight| {
            const scene: TargetScene = .{ .sight = sight, .all = frame.all, .mode = frame.mode };
            lead = try drawTarget(state, art, &resources.target_fonts, frame.gpa, frame.target, scene, frame.edge_line, colour, scale);
        }
        try state.drawEjectMarker(art, frame.gpa, frame.target, frame.screen, frame_duration, colour, scale);
        try state.drawScanner(frame.scanning, frame.clock.game_ticks, art, frame.gpa, frame.target, frame.screen, colour, scale);
        const lit = state.lit(live, frame.player.matching_speed, frame.multiplayer, frame_duration);
        try state.drawLights(art, frame.gpa, frame.target, frame.screen, lit, frame_duration, colour, scale, shake);
        lock_lit = lit.enemy_lock;
    }
    if (frame.sound) |sound| state.warnOfLock(sound, lock_lit, live.missile_homing != 0);
    try drawViewName(&resources.font, frame.gpa, frame.target, frame.screen, frame.last_view, frame.strings.*, colour, scale);
    if (ahead) try state.drawInstruments(resources, frame, lead, colour, scale);
    const contents: windows.Contents = .{
        .gunnery = .{ .slot = slot, .wire_frame = state.wire_frame },
        .damage = .{ .object = live },
        .missiles = .{ .ring = &state.missiles },
        .power = .{ .ball = resources.ball, .object = live, .hit_shake = frame.hit_shake, .random = frame.random },
        .target_display = .{ .state = state, .all = frame.all },
        .wing_status = .{ .all = frame.all },
    };
    const pen: windows.Pen = .{ .art = art, .font = &resources.font, .strings = frame.strings, .gpa = frame.gpa, .target = frame.target, .colour = colour, .shake = shake };
    try state.windows.frame(pen, frame.screen, frame.last_view, frame_duration, contents, scale);
    state.windows.beeps.play(frame.sound, frame.view);
}

/// The first gun of the group the ship has chosen (`GunMode.group`), which blind fire and the
/// charge arc look at, or null for none.
fn groupLead(slot: *const create.Slot) ?guns.GunType {
    return slot.groupLead(slot.object.gun_mode.group);
}

/// What blind fire does for the ship of `slot` this frame: nothing where it is not carried or not
/// on, or where every group of guns fires on a ship of more than one; and no aiming where the
/// chosen group is led by a Nova Cannon.
pub fn blindFire(state: *const State, slot: *const create.Slot) BlindFire {
    if (!state.blind_fire_fitted or !state.blind_fire) return .off;
    const groups = if (slot.combat) |combat| combat.gun_groups else 0;
    if (slot.object.gun_mode.all and groups != 1) return .off;
    return if (groupLead(slot) == .nova_cannon) .excluded else .on;
}

/// Whether the charge arc shows the Nova Cannon's charge: on a Phoenix firing one group, which the
/// cannon leads.
pub fn novaShown(slot: *const create.Slot) bool {
    const object = &slot.object;
    if (!object.type.carriesNova()) return false;
    return !object.gun_mode.all and groupLead(slot) == .nova_cannon;
}

test "blind fire, and the charge arc for the Nova Cannon" {
    const barrel = struct {
        fn of(kind: guns.GunType) guns.Fitted {
            return .{ .turret = .{ .fixed = .{ .muzzle = undefined, .type = kind } } };
        }
    }.of;
    var fitted = [_]guns.Fitted{ barrel(.pulse_cannon), barrel(.nova_cannon) };
    const table: [guns.max_groups]guns.Group = table: {
        var groups = guns.no_groups;
        groups[0] = .{ .first = 0 };
        groups[1] = .{ .first = 1 };
        break :table groups;
    };
    const combat = std.mem.zeroInit(create.ShipCombat, .{ .gun_groups = 2 });
    var slot: create.Slot = .{ .object = std.mem.zeroes(gameobj.GameObject), .combat = &combat, .guns = &fitted, .gun_groups = &table };
    var state: State = .{};

    // Blind fire aims where the ship carries it and has it on.
    try std.testing.expectEqual(BlindFire.off, blindFire(&state, &slot));
    state.blind_fire_fitted = true;
    try std.testing.expectEqual(BlindFire.on, blindFire(&state, &slot));
    state.blind_fire = false;
    try std.testing.expectEqual(BlindFire.off, blindFire(&state, &slot));
    state.blind_fire = true;
    // Not with every group of two firing, and not for a group the Nova Cannon leads.
    slot.object.gun_mode.all = true;
    try std.testing.expectEqual(BlindFire.off, blindFire(&state, &slot));
    slot.object.gun_mode.all = false;
    slot.object.gun_mode.group = 1;
    try std.testing.expectEqual(BlindFire.excluded, blindFire(&state, &slot));

    // The charge arc shows the cannon's charge on a Phoenix firing the cannon's group alone.
    try std.testing.expect(!novaShown(&slot));
    slot.object.type = .phoenix;
    try std.testing.expect(novaShown(&slot));
    slot.object.gun_mode.all = true;
    try std.testing.expect(!novaShown(&slot));
    slot.object.gun_mode.all = false;
    slot.object.gun_mode.group = 0;
    try std.testing.expect(!novaShown(&slot));
}

/// The readouts `hud_draw` puts in a row across the top of the screen, each a shape with a number
/// centred under it. All three stand half of the way across, at the offsets it hands `hud_place`.
pub const Readout = enum {
    /// The seconds of afterburner fuel left, `afterburner_fuel` being in ticks, under a ship with
    /// its engines burning.
    fuel,
    /// The pilot's kills over the campaign, `skull_count` (`0x00562DF4`, `input.Player.Kills`),
    /// under a skull and crossbones.
    skull,
    /// The countermeasures left, the object's `countermeasures`, under a coil. `ShowHudIcon` can
    /// flash it (`State.shows`).
    coil,

    /// Where a readout stands and what it draws there.
    pub const Spec = struct {
        /// The offset `hud_draw` hands `hud_place`, and the fraction of the screen.
        offset: [2]i32,
        across: f32,
        down: f32,
        /// The shape of the display's set drawn at that point.
        shape: u16,
        /// Where the shape hangs from it, which two of the three shift along.
        shape_offset: [2]i32 = .{ 0, 0 },
        /// Where the number is centred from the point: `0x1E` below it, and across by as much
        /// as its shape is shifted, near enough to stand under it.
        text_offset: [2]i32,
    };

    pub fn spec(readout: Readout) Spec {
        return switch (readout) {
            .fuel => .{ .offset = .{ 0x39, 0 }, .across = 0.5, .down = 0, .shape = 0xCD, .text_offset = .{ 0x10, 0x1E } },
            .skull => .{ .offset = .{ 0x5F, 0 }, .across = 0.5, .down = 0, .shape = 0xD0, .shape_offset = .{ -4, 0 }, .text_offset = .{ 0x0B, 0x1E } },
            .coil => .{ .offset = .{ 0x98, 0 }, .across = 0.5, .down = 0, .shape = 0xCF, .shape_offset = .{ -0x1A, 0 }, .text_offset = .{ -9, 0x1E } },
        };
    }

    /// Draws the readout for a window of `screen`, showing `value`.
    pub fn draw(
        readout: Readout,
        art: *Art,
        opened: *Opened,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        value: i32,
        colour: [4]f32,
        scale: f32,
        shake: ?Shake,
    ) (spr.Error || Allocator.Error)!void {
        const at = readout.spec();
        const point = place(screen, at.offset, at.across, at.down, scale);
        try drawShapeWith(art, gpa, target, at.shape, scaled(point, at.shape_offset, scale), colour, scale, .{ .shake = shake });

        var buffer: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return;
        _ = try drawText(opened, gpa, target, scaled(point, at.text_offset, scale), text, colour, .centre, scale);
    }
};

test Readout {
    // The three stand in a row across the top, half of the way across and rising to the right.
    var last: i32 = 0;
    for ([_]Readout{ .fuel, .skull, .coil }) |readout| {
        const at = readout.spec();
        try std.testing.expectEqual(0.5, at.across);
        try std.testing.expectEqual(0, at.down);
        try std.testing.expect(at.offset[0] > last);
        last = at.offset[0];
        const point = place(.{ 640, 480 }, at.offset, at.across, at.down, 1);
        try std.testing.expectEqual([2]i32{ 320 + at.offset[0], 16 }, point);
    }
    // An offset the display measures in its own pixels grows with it.
    try std.testing.expectEqual([2]i32{ 100 - 8, 20 }, scaled(.{ 100, 20 }, .{ -4, 0 }, 2));
    try std.testing.expectEqual([2]i32{ 100 + 0x10, 20 + 0x1E }, scaled(.{ 100, 20 }, Readout.fuel.spec().text_offset, 1));
    // Each number stands under its own shape: the coil's shape and number both lie left of the
    // point, its number 9 left.
    try std.testing.expectEqual(-9, Readout.coil.spec().text_offset[0]);
    try std.testing.expectEqual(0x0B, Readout.skull.spec().text_offset[0]);
}

/// Whether the display's instruments are drawn: `hud_draw` leaves out the jump prompt, the radar,
/// the eject marker, the scanner, the status lights and everything from the readouts to the clock
/// unless last frame's view was 0, the one ahead from the cockpit, in whichever cockpit mode, the
/// chase view among them. The rest of the views get the view's name in their place.
pub fn instrumented(last_view: camera.View) bool {
    return last_view == .cockpit;
}

/// How far down `hud_draw` draws the view's name, centred half of the way across the screen. It
/// measures both from the screen's edge rather than placing the text with `hud_place`.
pub const view_name_down: i32 = 10;

/// Whether `hud_draw` names `last_view` at the top of the screen: every view but the one ahead
/// from the cockpit, and but the fly-by and the two views after it (`0x24` to `0x26`).
pub fn namesView(last_view: camera.View) bool {
    return switch (last_view) {
        .cockpit, .flyby, ._unknown_37, ._unknown_38 => false,
        else => true,
    };
}

/// Draws the name of `last_view` where `hud_draw` does, the view table's string for it out of
/// `strings`. A view past the table, or a string past `strings`, draws nothing; the game stops
/// with a fatal error for either.
pub fn drawViewName(
    opened: *Opened,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    last_view: camera.View,
    strings: language.Language,
    colour: [4]f32,
    scale: f32,
) Allocator.Error!void {
    if (!namesView(last_view)) return;
    const text = strings.string(last_view.name() orelse return) orelse return;
    const at: [2]i32 = .{ @intCast(screen[0] >> 1), pixels(view_name_down, scale) };
    _ = try drawText(opened, gpa, target, at, text, colour, .centre, scale);
}

/// The launch's caption (`hud_draw`, `0x00484601`): while it is on, the date of the mission being
/// flown, typed out at the foot of the screen a letter more each time `letter_ticks` of the game's
/// ticks have passed, with a cursor after it until the whole date shows. The Reliant's launch puts
/// it on as the player's ship drops out (`launch.reliant`), and off as the launch ends. It shows in
/// every view.
pub const Caption = struct {
    /// `launch_caption_on` (`0x00569934`).
    on: bool = false,
    /// `launch_caption_due` (`0x0057BF44`): the game's tick past which the next letter shows.
    due: u32 = 0,
    /// `launch_caption_shown` (`0x005799E0`): how many of the date's letters show, one past them
    /// all once it is whole.
    shown: usize = 0,

    /// How often a letter more shows, in the game's ticks (`0x00484665`).
    const letter_ticks = 8;
    /// Where the date stands, in the display's own pixels: from the screen's left, and up from its
    /// foot (`0x004846CE`, `0x004846C9`).
    const left = 50;
    const up = 30;
    /// The cursor after the typed letters (`0x004E86E0`).
    const cursor = "_";

    pub fn start(caption: *Caption, game_ticks: u32) void {
        caption.* = .{ .on = true, .due = game_ticks };
    }

    pub fn stop(caption: *Caption) void {
        caption.on = false;
    }

    /// Types on through `text` at `game_ticks`: what shows of it, and whether the cursor does.
    pub fn typed(caption: *Caption, text: []const u8, game_ticks: u32) struct { []const u8, bool } {
        if (game_ticks > caption.due) {
            caption.due = game_ticks + letter_ticks;
            if (caption.shown < text.len + 1) caption.shown += 1;
        }
        return .{ text[0..@min(caption.shown, text.len)], caption.shown < text.len + 1 };
    }

    /// Draws the caption where `hud_draw` does, where it is on: the date of mission `mission` out of
    /// `strings`, typed on at `game_ticks`.
    pub fn draw(
        caption: *Caption,
        opened: *Opened,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        mission: u16,
        strings: language.Language,
        game_ticks: u32,
        colour: [4]f32,
        scale: f32,
    ) Allocator.Error!void {
        if (!caption.on) return;
        const text = strings.string(date(mission) orelse return) orelse return;
        const shows, const typing = caption.typed(text, game_ticks);
        const at: [2]i32 = .{ pixels(left, scale), @as(i32, @intCast(screen[1])) - pixels(up, scale) };
        const end = try drawText(opened, gpa, target, at, shows, colour, .left, scale);
        if (typing) _ = try drawText(opened, gpa, target, .{ end, at[1] }, cursor, colour, .left, scale);
    }

    /// The language string of mission `mission`'s date (`mission_dates`, `0x005023D6`): the table
    /// holds the dates of missions 1 to 28, one after another from `first_date`, and nothing for
    /// mission 0 or those after.
    pub fn date(mission: u16) ?u16 {
        if (mission == 0 or mission >= dated_missions) return null;
        return first_date + mission - 1;
    }

    const first_date = 978;
    const dated_missions = 29;
};

/// The objectives of the mission being flown (`mission_objectives`, `0x00504120`): ten a mission,
/// each named by a language string from the executable's table (`objectives.rows`) and in a
/// state its script sets (`SetObjective`), which the objectives window shows
/// ([#98](https://github.com/vdmkenny/openreliant/issues/98)).
pub const Objectives = struct {
    /// The mission's row of the table, null for a mission the table has none for.
    row: ?usize = null,
    states: [per_mission]Status = @splat(.hidden),
    /// `objectives_shown` (`0x0056997E`): the objective the window shows.
    shown: i16 = 0,

    pub const per_mission = 10;

    /// How the window shows an objective. **Unknown:** what else sets an objective hidden than a
    /// mission's script.
    pub const Status = enum(i16) {
        /// Not shown: paging through the window passes it over.
        hidden = 0,
        /// Shown as an objective.
        listed = 1,
        /// Shown as the current objective.
        current = 2,
        _,
    };

    /// The table's rows past the missions' own: mission 25's second part.
    const second_part_row = 35;

    /// The table's row for mission `mission`, or its second part's: missions 1 to 35 in turn, then
    /// mission 25's second part (`hud_window_draw`, `0x00486CDE`). Null for the rest.
    pub fn rowOf(mission: u16, second_part: bool) ?usize {
        if (mission == create.kamov_mission and second_part) return second_part_row;
        if (mission == 0 or mission > second_part_row) return null;
        return mission - 1;
    }

    /// `objectives_reset` (`0x00499180`), as `hud_init` readies the display for mission `mission`,
    /// and its second part where `second_part`: the first objective is the current one, and
    /// each other that has a name is listed; the window shows the first (`0x00483AC0`).
    pub fn reset(objectives: *Objectives, mission: u16, second_part: bool) void {
        objectives.* = .{ .row = rowOf(mission, second_part) };
        const row = objectives.row orelse return;
        for (&objectives.states, objectives_table.rows[row], 0..) |*state, name, n| {
            state.* = if (n == 0) .current else if (name != null) .listed else .hidden;
        }
    }

    /// The first of the objectives in the current state, which PRIMARY TARGET opens the window on
    /// (`frame_controls`, `0x00414E57`); null for none.
    pub fn current(objectives: *const Objectives) ?i16 {
        for (objectives.states, 0..) |state, n| {
            if (state == .current) return @intCast(n);
        }
        return null;
    }

    /// `cmd_SetObjective` (`0x00459870`): objective `objective` of the mission takes state
    /// `state`, and one made current is the one the window shows. An objective past the ten, or a
    /// mission the table has no row for, changes nothing.
    ///
    /// **Fix:** the game writes an objective past the ten into the next mission's, and mission 0's
    /// before the table.
    pub fn set(objectives: *Objectives, objective: u32, state: Status) void {
        if (objectives.row == null or objective >= per_mission) return;
        objectives.states[objective] = state;
        if (state == .current) objectives.shown = @intCast(objective);
    }
};

/// The table of the objectives' names.
pub const objectives_table = @import("hud/objectives.zig");

/// Where `hud_draw` centres the mission's clock: half of the way across, at the foot of the screen
/// and `130` up.
pub const clock_offset: [2]i32 = .{ 0, -130 };
pub const clock_across: f32 = 0.5;
pub const clock_down: f32 = 1;

/// Draws the mission's clock as `hud_draw` does: the minutes and the seconds, each of two figures,
/// centred at its place. The game shows the time played, or the mission's own countdown where it
/// runs one.
pub fn drawClock(
    opened: *Opened,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    minutes: u16,
    seconds: u16,
    colour: [4]f32,
    scale: f32,
) Allocator.Error!void {
    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}", .{ minutes, seconds }) catch return;
    const at = place(screen, clock_offset, clock_across, clock_down, scale);
    _ = try drawText(opened, gpa, target, at, text, colour, .centre, scale);
}

test drawClock {
    // The clock stands at the foot of the screen, 130 of the display's own pixels up.
    const at = place(.{ 640, 480 }, clock_offset, clock_across, clock_down, 1);
    try std.testing.expectEqual([2]i32{ 320, 480 - 33 + 16 - 130 }, at);
    // Drawn larger, it keeps to the foot and rises by as much more.
    const larger = place(.{ 640, 480 }, clock_offset, clock_across, clock_down, 2);
    try std.testing.expectEqual(480 - 66 + 32 - 260, larger[1]);

    // The figures are padded to two as "%02d:%02d" does.
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("09:06", try std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}", .{ @as(u16, 9), @as(u16, 6) }));
}

test Caption {
    var caption: Caption = .{};
    caption.start(100);
    // A letter more each time eight ticks have passed, the cursor after them until all show.
    try std.testing.expectEqualDeep(.{ "", true }, caption.typed("June", 100));
    try std.testing.expectEqualDeep(.{ "J", true }, caption.typed("June", 101));
    try std.testing.expectEqualDeep(.{ "J", true }, caption.typed("June", 109));
    try std.testing.expectEqualDeep(.{ "Ju", true }, caption.typed("June", 110));
    for (0..3) |n| _ = caption.typed("June", @intCast(120 + 10 * n));
    try std.testing.expectEqualDeep(.{ "June", false }, caption.typed("June", 150));
    // Missions 1 to 28 have dates, in order.
    try std.testing.expectEqual(978, Caption.date(1));
    try std.testing.expectEqual(1005, Caption.date(28));
    try std.testing.expectEqual(null, Caption.date(0));
    try std.testing.expectEqual(null, Caption.date(29));
}

test Objectives {
    var objectives: Objectives = .{};
    // Mission 1 lists its two objectives, the first current.
    objectives.reset(1, false);
    try std.testing.expectEqual(.current, objectives.states[0]);
    try std.testing.expectEqual(.listed, objectives.states[1]);
    try std.testing.expectEqual(.hidden, objectives.states[2]);
    // Its script makes the second current, which the window then shows.
    objectives.set(1, .current);
    try std.testing.expectEqual(1, objectives.shown);
    objectives.set(0, .hidden);
    try std.testing.expectEqual(1, objectives.shown);
    // Past the ten, nothing changes.
    objectives.set(10, .listed);
    // Mission 25's second part has a row of its own; mission 0 none.
    try std.testing.expectEqual(35, Objectives.rowOf(25, true));
    try std.testing.expectEqual(24, Objectives.rowOf(25, false));
    try std.testing.expectEqual(null, Objectives.rowOf(0, false));
    objectives.reset(0, false);
    objectives.set(0, .listed);
    try std.testing.expectEqual(.hidden, objectives.states[0]);
}

test namesView {
    try std.testing.expect(!namesView(.cockpit));
    try std.testing.expect(namesView(.cockpit_rear));
    try std.testing.expect(namesView(.external));
    try std.testing.expect(namesView(.chase));
    try std.testing.expect(!namesView(.flyby));
    try std.testing.expect(!namesView(._unknown_38));
    try std.testing.expect(namesView(@enumFromInt(0x27)));
}

test instrumented {
    // The view ahead from the cockpit has the instruments; the others do not, the cockpit's own
    // side and rear views among them.
    try std.testing.expect(instrumented(.cockpit));
    try std.testing.expect(!instrumented(.cockpit_left));
    try std.testing.expect(!instrumented(.chase));
    try std.testing.expect(!instrumented(.external));
    try std.testing.expect(!instrumented(.flyby));
}

// --- The status lights -----------------------------------------------------------------------

/// The status lights `hud_draw` packs into the display's grid, in the order it draws them, each
/// valued by its shape. A light takes the next place only while its condition holds, so the ones
/// after a light that is out close up. A flashing light keeps its place while it is dark.
pub const Light = enum(u16) {
    /// MATCH SPEED holds the ship to its target's speed: `matching_speed`.
    match_speed = 0xCC,
    /// Blind fire, which aims the guns at whatever stands in the middle of the display: the ship
    /// carries it, TOGGLE BLINDFIRE has it on, and the guns are not all firing (`GunMode.all`).
    blind_fire = 0xCB,
    /// Smart targeting, which makes any ship the player fires on the target: SMART TARGET has it
    /// on.
    smart_targeting = 0xC5,
    /// The lock warning, a ship in a gun sight: `State.enemy_lock`, with no missile homing on the
    /// ship yet. It flashes, and a warning sound loops while it is shown.
    enemy_lock = 0xC3,
    /// A missile homes on the ship: its `missile_homing`. It flashes twice as fast as the lock
    /// warning, on the same count.
    missile_incoming = 0xC4,
    /// The ECM is on, with its charge as a bar under it.
    ecm = 0xC6,
    /// The ship carries a cloak, on or off, with its charge as a bar under it. Never in a
    /// multiplayer game.
    cloak = 0xC7,
    /// The spectral shields are on, with their charge as a bar under them.
    spectral_shields = 0xCA,
    /// Reverse thrust burns: the object's `reverse_thrust`.
    reverse_thrust = 0xC8,

    /// The device whose charge the light's bar shows, for the three that have one.
    pub fn charged(light: Light) ?Device {
        return switch (light) {
            .ecm => .ecm,
            .cloak => .cloak,
            .spectral_shields => .spectral_shields,
            else => null,
        };
    }
};

test "Light.charged" {
    // Each device's light shows its charge; the rest have no bar.
    inline for (comptime std.enums.values(Device)) |kind| {
        try std.testing.expectEqual(kind, @field(Light, @tagName(kind)).charged().?);
    }
    try std.testing.expectEqual(null, Light.enemy_lock.charged());
    try std.testing.expectEqual(null, Light.reverse_thrust.charged());
}

/// Which lights' conditions hold, a bit a light, named and ordered as `Light` has them.
pub const Lit = packed struct(u9) {
    match_speed: bool = false,
    blind_fire: bool = false,
    smart_targeting: bool = false,
    enemy_lock: bool = false,
    missile_incoming: bool = false,
    ecm: bool = false,
    cloak: bool = false,
    spectral_shields: bool = false,
    reverse_thrust: bool = false,

    comptime {
        for (@typeInfo(Lit).@"struct".fields, std.enums.values(Light)) |field, light| {
            assert(std.mem.eql(u8, field.name, @tagName(light)));
        }
    }
};

/// How the display flashes a shape: lit for the first `on` ticks of every `period`.
pub const Flash = struct {
    on: i32,
    period: i32,

    /// The pace of `ShowHudIcon`'s icons, the lock warning, the jump prompt and the eject marker.
    pub const slow: Flash = .{ .on = 50, .period = 100 };
    /// The pace of the missile warning.
    pub const fast: Flash = .{ .on = 25, .period = 50 };

    /// Moves `ticks` on by a frame of `frame_duration` and says whether the shape is drawn in it.
    /// Past the period the count starts again from nothing, on a dark frame.
    pub fn step(flash: Flash, ticks: *i32, frame_duration: i32) bool {
        ticks.* += frame_duration;
        if (ticks.* < flash.on) return true;
        if (ticks.* > flash.period) ticks.* = 0;
        return false;
    }
};

/// The display's elements `ShowHudIcon` (mission command `0x5B`, `0x0045A1F0`) can light or flash
/// through `hud_icon_lit`, numbered as the command numbers them.
pub const Icon = enum(u5) {
    enemy_lock = 0,
    missile_incoming = 1,
    ecm = 2,
    /// The countermeasures readout, which is drawn anyway unless the icon flashes it.
    countermeasures = 3,
    smart_targeting = 4,
    /// The eject marker.
    ejected = 5,
    _,
};

/// What `ShowHudIcon` sets an icon to: "0 - off, 1 - on, 2 - flash".
pub const IconState = enum(u32) {
    off = 0,
    on = 1,
    flash = 2,
    _,
};

/// The icons `ShowHudIcon` sets (`0x00566558`), which `hud_init` turns off. The table holds
/// twenty; the display reads the six `Icon` names.
pub const Icons = struct {
    pub const count = 20;

    /// An icon's state and the count its flash is at.
    pub const Slot = extern struct {
        state: IconState = .off,
        ticks: i32 = 0,

        comptime {
            // Twenty of them run from `0x00566558` up to `ecm_charge` (`0x005665F8`).
            assert(@offsetOf(Slot, "ticks") == 4);
            assert(@sizeOf(Slot) == 8);
            assert(0x00566558 + count * @sizeOf(Slot) == 0x005665F8);
        }
    };

    slots: [count]Slot = @splat(.{}),

    /// Sets an icon as `ShowHudIcon` does, its flash starting from the beginning.
    ///
    /// **Improvement.** The game writes past the table for an icon of 20 or more; OpenReliant
    /// leaves such an icon alone.
    pub fn show(icons: *Icons, icon: Icon, state: IconState) void {
        const at = @intFromEnum(icon);
        if (at >= count) return;
        icons.slots[at] = .{ .state = state };
    }

    /// Whether `icon` is lit in a frame of `frame_duration` (`hud_icon_lit`, `0x00482F50`): always
    /// when on, and when flashing for the first 50 ticks of every 100. Unlike the display's other
    /// flashes, one that runs past 100 carries what it ran over into the next and is lit.
    pub fn lit(icons: *Icons, icon: Icon, frame_duration: i32) bool {
        const at = @intFromEnum(icon);
        if (at >= count) return false;
        const slot = &icons.slots[at];
        switch (slot.state) {
            .on => return true,
            .flash => {
                slot.ticks += frame_duration;
                if (slot.ticks < Flash.slow.on) return true;
                if (slot.ticks > Flash.slow.period) {
                    slot.ticks -= Flash.slow.period;
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }
};

/// A device a ship may carry that runs off a charge, which its light shows as a bar.
pub const Device = enum {
    ecm,
    cloak,
    spectral_shields,

    pub const Spec = struct {
        /// The charge when full, in ticks, where `hud_init` starts it.
        full: i32,
        /// What it spends of the charge a tick while it is on. It charges at one a tick while off.
        drain: i32,
        /// The bar's length for a tick of charge, in the display's own pixels, and how far below
        /// the light's point it runs.
        bar_scale: f32,
        bar_down: i32,
    };

    /// Twenty seconds of ECM, a hundred of the cloak and ten of the spectral shields, each bar
    /// about 32 pixels long when full.
    pub fn spec(kind: Device) Spec {
        return switch (kind) {
            .ecm => .{ .full = 2000, .drain = 1, .bar_scale = 1.0 / 62.0, .bar_down = 0x23 },
            .cloak => .{ .full = 10000, .drain = 1, .bar_scale = 1.0 / 312.0, .bar_down = 0x20 },
            .spectral_shields => .{ .full = 6000, .drain = 6, .bar_scale = 1.0 / 187.0, .bar_down = 0x20 },
        };
    }
};

/// Whether the ship carries a device, and whether it is on: `ecm_state` (`0x0057BF4C`),
/// `cloak_state` (`0x00566638`) and `spectral_shields_state` (`0x0057BF20`).
pub const Setting = enum(i32) {
    absent = -1,
    off = 0,
    on = 1,
    _,
};

/// A device's setting and its charge in ticks: `ecm_charge` (`0x005665F8`), `cloak_charge`
/// (`0x0056663C`) and `spectral_shields_charge` (`0x00566620`).
pub const Charge = struct {
    setting: Setting = .off,
    ticks: i32,

    /// Carried, off and full, as `hud_init` leaves each device.
    pub fn full(kind: Device) Charge {
        return .{ .ticks = kind.spec().full };
    }

    /// `hud_draw`'s work on the charge for a frame of `frame_duration`: while the device is off it
    /// charges up to full, and while it is on it drains. Says whether it has just run dry, which
    /// leaves the charge at nothing for the device to be turned off.
    pub fn run(charge: *Charge, kind: Device, frame_duration: i32) bool {
        const at = kind.spec();
        switch (charge.setting) {
            .off => charge.ticks = @min(charge.ticks + frame_duration, at.full),
            .on => {
                charge.ticks -= frame_duration * at.drain;
                if (charge.ticks < 0) {
                    charge.ticks = 0;
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    /// The bar's length in the display's own pixels: the charge times the bar's scale, rounded as
    /// `0x004C3330` does, and nothing for less than nothing.
    pub fn bar(charge: Charge, kind: Device) i32 {
        const length = @as(f32, @floatFromInt(charge.ticks)) * kind.spec().bar_scale;
        return if (length < 0) 0 else round(length);
    }
};

/// The colour the charge bars are drawn in: `hud_colour(0xE7, 0x68, 0x00)` (`0x0048D780`).
pub const bar_colour: [4]f32 = .{ 0xE7.0 / 255.0, 0x68.0 / 255.0, 0, 1 };

/// Whether the mission has a jump or a warp ready for JUMP DRIVE: `jump_ready` (`0x0052A3F0`) and
/// `warp_ready` (`0x0052A3F4`). The mission sets one to `newly`, the prompt moves it on to
/// `shown`, and JUMP DRIVE (`player_jump`, `0x00412B20`) clears it as it posts the event.
pub const Ready = enum(i32) {
    no = 0,
    newly = 1,
    shown = 2,
    _,
};

/// The display's own state: `hud.cpp`'s globals, as `hud_init` sets them when it sets the display
/// up. The mission's start then fits the devices to the player's ship.
pub const State = struct {
    devices: std.EnumArray(Device, Charge) = .init(.{
        .ecm = .full(.ecm),
        .cloak = .full(.cloak),
        .spectral_shields = .full(.spectral_shields),
    }),
    /// `blind_fire_fitted` (`0x00566F8C`): whether the ship carries blind fire.
    blind_fire_fitted: bool = false,
    /// The gunnery display's wire frame of the player's ship (`0x005883C0`), which the mission's
    /// start picks for its type (`main.fitDevices`); null for a ship it has none for.
    wire_frame: ?u16 = null,
    /// `blind_fire` (`0x00579990`), which TOGGLE BLINDFIRE flips.
    blind_fire: bool = true,
    /// `smart_targeting` (`0x0056996C`), which SMART TARGET flips.
    smart_targeting: bool = false,
    /// `enemy_lock` (`0x00579988`): whether an enemy has a missile lock on the player.
    /// `mission_frame` sets it each frame when a ship whose order is Fight, against the player,
    /// has its missile ready (`aifight.FightState.missile_ready`).
    enemy_lock: bool = false,
    /// The voice the enemy lock's warning plays on (`enemy_lock_voice`, `0x0057BF50`) while it
    /// plays (`warnOfLock`).
    lock_warning: ?u8 = null,
    /// The display's interference as the player's ship is hit.
    interference: Interference = .{},
    /// The date the player's launch types out.
    caption: Caption = .{},
    /// The mission's objectives.
    objectives: Objectives = .{},
    /// `target_under_reticle` (`0x00566550`): whether the reticle was drawn bright, a target under
    /// it or blind fire aiming at it, which the chase view's sight shows (`chase.Chase`).
    reticle_bright: bool = false,
    /// The chase view's pointer to the target this frame, where `drawTarget` has found it out of
    /// sight in the chase view; null where it doesn't show.
    chase_pointer: ?chase.Pointer = null,
    /// How the chase view's pointer to the player's nav point is rolled this frame, where
    /// `drawTarget` has found one in the chase view; null where it doesn't show.
    chase_nav_roll: ?f32 = null,
    /// `player_ejected` (`0x00579986`), which the Eject Player order sets.
    ejected: bool = false,
    icons: Icons = .{},
    /// The count the lock and missile warnings flash by (`0x0057BC44`), which the two share.
    warning_ticks: i32 = 0,
    /// The count the eject marker flashes by (`0x00569938`), which the Eject Player order starts
    /// again.
    eject_ticks: i32 = 0,
    /// The count the jump prompt flashes by (`0x00566790`).
    prompt_ticks: i32 = 0,
    /// The scanner's frame (`0x0057BC34`), 0 to 4, and the tick it next moves on at
    /// (`0x005667B0`).
    scanner_frame: u8 = 0,
    scanner_next: u32 = 0,
    /// Where blind fire's sight stands (`0x00566628`, `0x0056662C`), which `hud_init` puts at
    /// the middle of the screen; null until OpenReliant first draws it there.
    sight: ?[2]i32 = null,
    /// Where the lead cursor last stood in the scene (`hud_lead_point`, `0x0057C260`), which blind
    /// fire aims the player's shots at (`guns.shoot`).
    lead_point: Vector = @splat(0),
    /// The radar's rings (`0x0057BC50`).
    radar_rings: u16 = Radar.first_rings,
    /// The radar's range (`radar_range`, `0x0057BE00`), 0 the closest.
    radar_range: u2 = Radar.first_range,
    /// The rings moving to a new range's, or null while they are still.
    radar_zoom: ?Radar.Zoom = null,
    /// The display's windows (`0x00501D30`).
    windows: windows.Windows = .{},
    /// The player's target as the display has it (`0x005799E8`, an order's entry of which only
    /// the target's index and component are set): the target of the player's Player Control
    /// order, which `followTarget` and `targetChanged` copy.
    shown: aigeneric.Target = .none,
    /// The object the display draws as the target (`0x00569940`): the shown one, while the player
    /// can aim at it.
    target: ?u16 = null,
    /// What each form of the target display last showed, which it closes with.
    target_pictures: target_display.Pictures = .{},
    /// The quadrants of the player's ship, and of its target, whose armour hits have worn since
    /// the ship status indicator last drew each (`ship_status_hits`, `0x00563160`, and
    /// `target_status_hits`, `0x005635D4`).
    ship_hits: Hits = .initEmpty(),
    target_hits: Hits = .initEmpty(),
    /// The object that stood under the reticle as the targeting keys were last read
    /// (`0x00566664`), which TARGET UNDER RETICULE takes.
    under_reticle: ?u16 = null,
    /// The player's missile lock (`main.cpp`'s), whose count dims the target's brackets and
    /// shortens the lead cursor's line by `lock_shortening` for each short of 100.
    lock: missile_lock.Lock = .{},
    /// The missile display's ring of the player's missiles.
    missiles: missile_display.Ring = .{},
    /// Whether the cloak's charge has run dry since the player's ship last uncloaked for it
    /// (`uncloakSpent`).
    cloak_spent: bool = false,

    /// `hud_draw`'s work on the devices' charges for a frame, which it does in every view: a
    /// device that runs dry is turned off. The cloak's charge runs only outside a multiplayer
    /// game.
    ///
    /// The game uncloaks the ship here as the cloak's charge runs dry (`input.setCloak`). The
    /// display has no world to reach the ship through, so OpenReliant marks the cloak spent and the
    /// next frame's orders uncloak it (`uncloakSpent`), a frame later.
    pub fn runCharges(state: *State, object: *gameobj.GameObject, frame_duration: i32, multiplayer: bool) void {
        if (state.devices.getPtr(.ecm).run(.ecm, frame_duration)) input.setEcm(state, object, false);
        if (!multiplayer and state.devices.getPtr(.cloak).run(.cloak, frame_duration)) state.cloak_spent = true;
        if (state.devices.getPtr(.spectral_shields).run(.spectral_shields, frame_duration)) {
            input.setSpectralShields(state, object, false);
        }
    }

    /// Uncloaks the player's ship once the cloak's charge has run dry (`runCharges`).
    pub fn uncloakSpent(state: *State, world: gameobj.World) void {
        if (!state.cloak_spent) return;
        state.cloak_spent = false;
        input.setCloak(world, false);
    }

    /// `hud_draw`'s warning with the enemy lock's light, `showing` this frame: while it shows, the
    /// warning plays on voice 1, started again whenever that voice has finished or was stopped.
    /// Once it is out and no missile homes on the ship (`homing`), a warning still playing ends.
    ///
    /// **Fix:** the game does this only in the view ahead, as it draws the lights, so a warning
    /// playing as the view changes loops until the player looks ahead again. OpenReliant runs it in
    /// every view, the light counting as out in the others.
    pub fn warnOfLock(state: *State, sound: *hog_snd.Sound, showing: bool, homing: bool) void {
        if (showing) {
            if (!sound.voiceIdle(lock_warning_voice)) return;
            const bank = sound.stdsmp orelse return;
            sound.playOn(lock_warning_voice, bank, lock_warning_sample, Beep.volume, hog_snd.forever, hog_snd.centre, hog_snd.own_pitch);
            state.lock_warning = lock_warning_voice;
        } else if (state.lock_warning) |voice| {
            if (homing or sound.voiceIdle(lock_warning_voice)) return;
            sound.endVoice(voice);
            state.lock_warning = null;
        }
    }

    /// Which lights' conditions hold for the player's `object`, tested as `hud_draw` tests them,
    /// in its order: an icon's flash moves on only when `hud_draw` asks for it. `matching` is
    /// `matching_speed`.
    pub fn lit(state: *State, object: *const gameobj.GameObject, matching: bool, multiplayer: bool, frame_duration: i32) Lit {
        const homing = object.missile_homing != 0;
        var found: Lit = .{};
        found.match_speed = matching;
        found.blind_fire = state.blind_fire_fitted and state.blind_fire and !object.gun_mode.all;
        found.smart_targeting = state.smart_targeting or state.icons.lit(.smart_targeting, frame_duration);
        found.enemy_lock = (state.enemy_lock and !homing) or state.icons.lit(.enemy_lock, frame_duration);
        found.missile_incoming = homing or state.icons.lit(.missile_incoming, frame_duration);
        found.ecm = state.devices.get(.ecm).setting == .on or state.icons.lit(.ecm, frame_duration);
        found.cloak = !multiplayer and state.devices.get(.cloak).setting != .absent;
        found.spectral_shields = state.devices.get(.spectral_shields).setting == .on;
        found.reverse_thrust = object.reverse_thrust;
        return found;
    }

    /// What `hud_draw` does first each frame: shows the target of the player's orders, the Player
    /// Control order's below the current one or else the current one's.
    pub fn followTarget(state: *State, all: *const create.Objects, multiplayer: bool) void {
        const slot = &all.slots[all.player];
        const count: usize = @intCast(@max(slot.object.order_count, 1));
        var entry = slot.orders[0];
        for (slot.orders[1..count]) |deeper| {
            if (deeper.order == .player_control) {
                entry = deeper;
                break;
            }
        }
        state.show(all, entry.target, multiplayer);
    }

    /// `0x0048C580`: follows a change of the player's target. The display shows the target of the
    /// player's Player Control order, and brings up the form of the target display that shows it,
    /// held open, closing the other; with no target it closes both.
    pub fn targetChanged(state: *State, all: *create.Objects, multiplayer: bool) void {
        const entry = ai.playerControlEntry(all) orelse return;
        state.show(all, entry.target, multiplayer);
        const index = state.shown.slot() orelse {
            state.windows.close(.target);
            state.windows.close(.big_target);
            return;
        };
        const window = targetWindow(&all.slots[index]);
        if (state.bringUp(window, multiplayer)) state.windows.status.getPtr(window).held = true;
    }

    /// Shows `target`'s index and component, and draws its object while the player can aim at it,
    /// a friendly one cloaked too outside a multiplayer game. What the display shows is always a
    /// ship (`shown`), whatever kind `target` names.
    fn show(state: *State, all: *const create.Objects, target: aigeneric.Target, multiplayer: bool) void {
        state.shown.index = target.index;
        state.shown.component = target.component;
        const shown_ship = state.shown.slot();
        const friendly = if (shown_ship) |index| index < all.slots.len and all.slots[index].object.side == .friendly else false;
        const allowed: gameobj.GameObject.Flags = .{ .cloaked = friendly and !multiplayer };
        state.target = if (ai.targetValid(all, state.shown, allowed)) shown_ship else null;
    }

    /// Opens `window`, one of the target display's forms, closing the other if it is up. Returns
    /// whether `window` is up.
    pub fn bringUp(state: *State, window: windows.Window, multiplayer: bool) bool {
        state.windows.close(if (window == .target) .big_target else .target);
        return state.windows.open(window, multiplayer);
    }

    /// Whether `hud_draw` draws `readout` in a frame of `frame_duration`: the countermeasures only
    /// while their icon is not flashing them dark.
    pub fn shows(state: *State, readout: Readout, frame_duration: i32) bool {
        return switch (readout) {
            .coil => state.icons.slots[@intFromEnum(Icon.countermeasures)].state == .off or
                state.icons.lit(.countermeasures, frame_duration),
            else => true,
        };
    }

    /// Draws the lights `lit` has, each in the next place of the grid, the warnings flashing and
    /// the devices' charges as bars under their lights.
    pub fn drawLights(
        state: *State,
        art: *Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        shown: Lit,
        frame_duration: i32,
        colour: [4]f32,
        scale: f32,
        shake: ?Shake,
    ) (spr.Error || Allocator.Error)!void {
        var index: i32 = 0;
        inline for (comptime std.enums.values(Light)) |light| {
            if (@field(shown, @tagName(light))) {
                const at = gridPlace(screen, index, scale);
                index += 1;
                const drawn = switch (light) {
                    .enemy_lock => Flash.slow.step(&state.warning_ticks, frame_duration),
                    .missile_incoming => Flash.fast.step(&state.warning_ticks, frame_duration),
                    else => true,
                };
                // Every light shakes but reverse thrust's.
                const how: Draw = .{ .shake = if (light == .reverse_thrust) null else shake };
                if (drawn) try drawShapeWith(art, gpa, target, @intFromEnum(light), at, colour, scale, how);
                if (comptime light.charged()) |kind| {
                    drawBar(target, at, kind.spec().bar_down, state.devices.get(kind).bar(kind), scale);
                }
            }
        }
    }

    /// The prompt for JUMP DRIVE (`hud_jump_prompt`, `0x00482FA0`): the shape it draws in a frame
    /// of `frame_duration`, if any. A warp the mission has ready comes before a jump. The frame one
    /// becomes ready the prompt starts its flash and draws nothing.
    pub fn jumpPrompt(state: *State, ready: *Readiness, frame_duration: i32) ?u16 {
        const which: *Ready, const shape: u16 = if (ready.warp != .no)
            .{ &ready.warp, JumpPrompt.warp_shape }
        else
            .{ &ready.jump, JumpPrompt.jump_shape };
        switch (which.*) {
            .newly => {
                state.prompt_ticks = 0;
                which.* = .shown;
                return null;
            },
            .shown => return if (Flash.slow.step(&state.prompt_ticks, frame_duration)) shape else null,
            else => return null,
        }
    }

    /// Draws the jump prompt, flashing above the middle of the screen.
    pub fn drawJumpPrompt(
        state: *State,
        ready: *Readiness,
        art: *Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        frame_duration: i32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        const shape = state.jumpPrompt(ready, frame_duration) orelse return;
        try drawShape(art, gpa, target, shape, place(screen, JumpPrompt.offset, 0.5, 0.5, scale), colour, scale);
    }

    /// The eject marker (`hud_eject_marker`, `0x004830B0`): the pilot rising out of the ship,
    /// flashing under the middle of the screen once the player has ejected, or while its icon is
    /// lit.
    pub fn drawEjectMarker(
        state: *State,
        art: *Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        frame_duration: i32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        if (!state.ejected and !state.icons.lit(.ejected, frame_duration)) return;
        const at = scaled(place(screen, marker_offset, 0.5, 0.5, scale), eject_drop, scale);
        if (Flash.slow.step(&state.eject_ticks, frame_duration)) {
            try drawShape(art, gpa, target, eject_shape, at, colour, scale);
        }
    }

    /// The scanner (`hud_scanner`, `0x00489250`): while the `Scanner` mission command has the
    /// player look for an object, a hand and the rings it sends out, drawn over the middle of the
    /// screen in five frames.
    pub fn drawScanner(
        state: *State,
        scanning: bool,
        game_ticks: u32,
        art: *Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        if (!scanning) return;
        const at = place(screen, marker_offset, 0.5, 0.5, scale);
        try drawShape(art, gpa, target, scanner_shape + state.scannerFrame(game_ticks), at, colour, scale);
    }

    /// What `hud_draw` draws only in the view ahead from the cockpit, after the view's name.
    fn drawInstruments(state: *State, resources: *Resources, frame: Frame, lead: ?[2]i32, colour: [4]f32, scale: f32) (spr.Error || Allocator.Error)!void {
        const frame_duration = frame.clock.frame_duration;
        const shake = state.interference.shake(frame.hit_shake, frame.random);
        const slot = &frame.all.slots[frame.all.player];
        const live = &slot.object;
        const flight = slot.flight orelse return;
        const combat = slot.combat orelse return;
        const art = &resources.art;
        for (std.enums.values(Readout)) |readout| {
            if (!state.shows(readout, frame_duration)) continue;
            const value: i32 = switch (readout) {
                .fuel => @divTrunc(live.afterburner_fuel, main.ticks_per_second),
                .skull => frame.player.kills.count,
                .coil => live.countermeasures,
            };
            try readout.draw(art, &resources.font, frame.gpa, frame.target, frame.screen, value, colour, scale, shake);
        }
        const status = ShipStatus.ofPlayer(slot, &state.ship_hits, frame.player.shield_reserves);
        try ShipStatus.draw(status, .player, art, frame.gpa, frame.target, place(frame.screen, ShipStatus.offset, ShipStatus.across, ShipStatus.down, scale), scale, null, colour, shake);
        try drawCluster(art, &resources.font, frame.gpa, frame.target, frame.screen, .{
            .throttle = live.throttle,
            .speed = live.speed,
            .max_speed = flight.max_speed,
            .charge = live.gun_charge,
            .full_charge = combat.gun_energy,
            .nova = if (novaShown(slot)) live.nova_charge else null,
        }, colour, scale, shake);
        try drawRadar(art, frame.gpa, frame.target, frame.screen, state, frame.all, colour, scale, shake);
        stepRadarZoom(state, frame.clock.game_ticks);
        const aims = try drawReticle(state, art, frame.gpa, frame.target, frame.screen, frame.mode, lead, blindFire(state, slot), frame_duration, colour, scale, shake);
        live.blind_fire_aim = @intFromBool(aims);
        try drawClock(&resources.font, frame.gpa, frame.target, frame.screen, frame.clock.play.minutes, frame.clock.play.seconds, colour, scale);
    }

    /// The scanner's frame at `game_ticks`: the next, going round, once `game_ticks` is past the
    /// tick it waits for, which is then 25 on.
    pub fn scannerFrame(state: *State, game_ticks: u32) u8 {
        if (state.scanner_next < game_ticks) {
            state.scanner_next = game_ticks + scanner_step;
            state.scanner_frame = if (state.scanner_frame >= scanner_frames - 1) 0 else state.scanner_frame + 1;
        }
        return state.scanner_frame;
    }
};

/// What the mission has ready for JUMP DRIVE: the first two of the game's variables a script sets
/// (`vm.Variables`).
pub const Readiness = extern struct {
    jump: Ready = .no,
    warp: Ready = .no,
};

/// Where the jump prompt stands, from the middle of the screen, and its two shapes.
pub const JumpPrompt = struct {
    pub const offset: [2]i32 = .{ -16, -90 };
    pub const warp_shape: u16 = 0xC9;
    pub const jump_shape: u16 = 0xCE;
};

/// Where the eject marker and the scanner stand, from the middle of the screen; the marker hangs
/// `eject_drop` below (`hud_eject_marker`, `0x004830B0`).
pub const marker_offset: [2]i32 = .{ -16, -100 };
pub const eject_drop: [2]i32 = .{ 0, 0x26 };
pub const eject_shape: u16 = 0xC2;
pub const scanner_shape: u16 = 0xD1;
pub const scanner_frames = 5;
pub const scanner_step = 25;

/// How far apart two points of the screen are.
fn distance(a: Point, b: Point) f32 {
    return @sqrt(@reduce(.Add, (b - a) * (b - a)));
}

/// A charge's bar: a line of the display's pixels `down` below the light's point, from one right
/// of it to `length` further.
fn drawBar(target: device.Device, at: [2]i32, down: i32, length: i32, scale: f32) void {
    const left = @as(f32, @floatFromInt(at[0])) + scale;
    const top = @as(f32, @floatFromInt(at[1])) + @as(f32, @floatFromInt(down)) * scale;
    drawLine(target, .{ left, top }, .{ left + @as(f32, @floatFromInt(length)) * scale, top }, bar_colour, scale);
}

/// Draws a line from the pixel at `from` to the pixel at `to`, both ends included, as
/// `VFX_line_draw` draws one, its pixels `width` across for a display drawn larger.
pub fn drawLine(target: device.Device, from: Point, to: Point, colour: [4]f32, width: f32) void {
    const half: Point = @splat(width / 2);
    // The line runs between the pixels' middles, and reaches half a pixel past each.
    const start = from + half;
    const end = to + half;
    const length = distance(start, end);
    const along: Point = if (length > 0) (end - start) / @as(Point, @splat(length)) * half else .{ half[0], 0 };
    const across: Point = .{ -along[1], along[0] };
    const tint = device.pack(colour);
    var corners: [4]device.Vertex = undefined;
    for (&corners, [4]Point{ start - along - across, end + along - across, end + along + across, start - along + across }) |*corner, at| {
        corner.* = .{ .x = at[0], .y = at[1], .z = 1, .rhw = 1, .diffuse = tint };
    }
    target.draw(overlayState(null), .fan, &corners, null);
}

/// How far the object at `index` is from the player's ship, in whole kilometres of a thousand of
/// its units, the distance rounded first: the range the target is shown with.
pub fn kilometres(all: *const create.Objects, index: u16) i32 {
    const apart = math.distance(all.slots[all.player].drawn.position, all.slots[index].drawn.position);
    return @divTrunc(round(apart), 1000);
}

/// A range as the display writes it, `%dk`.
pub fn rangeText(buffer: *[16]u8, km: i32) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}k", .{km}) catch "";
}

/// How much shorter each unit the missile lock's count is short of 100 makes the lead cursor's
/// line, in the display's pixels (`0x004DC928`).
pub const lock_shortening: f32 = 0.28;

/// How far MATCH SPEED follows a target (`0x00501CB4`), and the targeting keys reach from the
/// player's ship: twice as far.
pub const pick_range: f32 = 330_000;
pub const pick_reach: f32 = 2 * pick_range;

/// The form of the target display that shows the object of `slot`: the large one where its
/// type's combat stats ask for it, the small one otherwise and for an object without them.
pub fn targetWindow(slot: *const create.Slot) windows.Window {
    const combat = slot.combat orelse return .target;
    return if (combat.display == .large) .big_target else .target;
}

test "targetWindow and State.bringUp" {
    var slot: create.Slot = .{ .object = std.mem.zeroes(gameobj.GameObject) };
    try std.testing.expectEqual(windows.Window.target, targetWindow(&slot));
    const large = std.mem.zeroInit(create.ShipCombat, .{ .display = .large });
    slot.combat = &large;
    try std.testing.expectEqual(windows.Window.big_target, targetWindow(&slot));

    // Bringing one form up closes the other.
    var state: State = .{};
    try std.testing.expect(state.bringUp(.target, false));
    try std.testing.expect(state.windows.up(.target));
    try std.testing.expect(state.bringUp(.big_target, false));
    try std.testing.expect(!state.windows.up(.target));
    try std.testing.expect(state.windows.up(.big_target));
}

/// The camera and its projection, as Surrender last drew the scene with them (`sr + 0x30`, and
/// the screen's size and projection from `sr + 0x1666`): what the display finds where objects
/// stand on the screen by.
pub const Sight = struct {
    place: math.Place,
    projection: srapi.Projection,

    /// A point of the world in the camera's frame.
    pub fn view(sight: Sight, point: Vector) Vector {
        return sight.place.inverse(point);
    }

    /// Where a point in the camera's frame falls on the screen, rounded to a pixel.
    pub fn pixel(sight: Sight, point: Vector) [2]i32 {
        const at = sight.projection.project(point);
        return .{ round(at[0]), round(at[1]) };
    }

    /// The screen's last pixel across and down.
    pub fn last(sight: Sight) [2]i32 {
        const screen = sight.projection.screen;
        return .{ @as(i32, @intCast(screen[0])) - 1, @as(i32, @intCast(screen[1])) - 1 };
    }

    /// Whether a pixel is on the screen.
    pub fn onScreen(sight: Sight, at: [2]i32) bool {
        const edge = sight.last();
        return at[0] >= 0 and at[0] <= edge[0] and at[1] >= 0 and at[1] <= edge[1];
    }

    /// The middle of the screen, half its size rounded.
    pub fn middle(sight: Sight) [2]i32 {
        const screen = sight.projection.screen;
        return .{ round(@as(f32, @floatFromInt(screen[0])) * 0.5), round(@as(f32, @floatFromInt(screen[1])) * 0.5) };
    }
};

/// How near the middle of the screen, either way, an object stands for `hud_target_keys` to take
/// it as under the reticle, in the display's own pixels.
pub const reticle_reach: i32 = 0x20;

/// The first object other than the player's ship that stands in front of the camera within
/// `reticle_reach` of the middle of the screen, drawn `scale` times its size.
pub fn underReticle(all: *const create.Objects, sight: Sight, scale: f32) ?u16 {
    const middle = sight.middle();
    const reach = pixels(reticle_reach, scale);
    for (all.slots[0..all.count], 0..) |*slot, index| {
        if (index == all.player or !slot.object.type.hasStats()) continue;
        const seen = sight.view(slot.drawn.position);
        if (!(seen[2] > 0)) continue;
        const at = sight.pixel(seen);
        if (@abs(at[0] - middle[0]) < reach and @abs(at[1] - middle[1]) < reach) return @intCast(index);
    }
    return null;
}

/// What the targeting keys read and change besides the display's own state.
pub const Keys = struct {
    devices: *input.Devices,
    player: *input.Player,
    all: *create.Objects,
    /// The scene as it was last drawn, which finds the object under the reticle; null before the
    /// first frame.
    sight: ?Sight,
    /// Last frame's view (`camera_view_last`).
    last_view: camera.View,
    /// How much larger than its own art the display is drawn (`scaleFor`).
    scale: f32,
    multiplayer: bool,
    /// The world the keys' sounds are heard in; null where nothing is heard.
    world: ?gameobj.World = null,
};

/// `hud_target_keys` (`0x0048B6B0`), which `frame_controls` runs after the camera's keys. It
/// first finds the object under the reticle, then reads, in its order:
///
/// - TARGET TORPEDO steps the player's target to the next hostile Russian torpedo, Kamov or
///   Scimitar within `pick_reach`, and leaves it be if there is none.
/// - TARGET NEAREST ENEMY and TARGET NEAREST FRIENDLY, from the cockpit ahead or the chase view
///   while the player's order is Player Control, take the nearest hostile ship neither exploding
///   nor cloaked, or friendly ship not exploding, within `pick_reach`.
/// - SMART TARGET flips smart targeting.
/// - The next and previous enemy and friendly target keys, while the player's order is Player
///   Control, first bring up the target display for a target the player can aim at if neither
///   of its forms is up; otherwise they step the target (`input.cycleTarget`).
/// - The next and previous subtarget keys step the target's component
///   (`input.cycleSubtarget`).
/// - TARGET UNDER RETICULE takes the object under the reticle as the target of the player's
///   current order, and brings up its form of the target display.
/// - MISSILE WINDOW opens the missile window held and, pressed again once it is open, closes it.
/// - Outside a multiplayer game, ROTATE MISSILES CLOCKWISE and ANTICLOCKWISE open it held too and
///   turn the missile ring (`missile_display.Ring.turn`): where it turns, `MISSILESELECT` sounds at
///   the player's ship and the display beeps, and where it cannot, the display refuses; then Betty
///   says the armed missile's name.
///
/// All but the nearest and the subtarget keys, and SMART TARGET, stop MATCH SPEED; PREVIOUS
/// FRIENDLY TARGET does not. Each key sounds the display's `done` where it does what it is for and
/// `refused` where it finds nothing: TARGET TORPEDO without the player's controls, a nearest key
/// finding no ship, a step key finding no target, a subtarget key with no target listing
/// components that is not friendly, TARGET UNDER RETICULE with nothing there to aim at. SMART
/// TARGET sounds `on` or `off`, MISSILE WINDOW `done`.
///
/// Not yet ported: the radio's menu while its window is open, and what the game does while
/// `0x00529FB8` is set, which leaves out every key after the search under the reticle.
pub fn targetKeys(state: *State, keys: Keys) void {
    const all = keys.all;
    const devices = keys.devices;
    state.under_reticle = if (keys.sight) |sight| underReticle(all, sight, keys.scale) else null;

    if (devices.active(.target_torpedo, true)) {
        if (ai.playerControlEntry(all)) |entry| {
            beep(keys.world, .done);
            if (input.seekTarget(all, &entry.target, .next, .torpedo)) state.targetChanged(all, keys.multiplayer);
        } else beep(keys.world, .refused);
    }
    const current = &all.slots[all.player].orders[0];
    const controlled = current.order == .player_control;
    const looking = keys.last_view == .cockpit or keys.last_view == .chase;
    for (nearest_keys) |key| {
        if (!devices.active(key.action, true) or !looking or !controlled) continue;
        if (nearest(all, key.side)) |index| {
            beep(keys.world, .done);
            input.setPlayerTarget(state, all, @intCast(index), -1, keys.multiplayer);
        } else beep(keys.world, .refused);
    }
    if (devices.active(.smart_target, true)) {
        state.smart_targeting = !state.smart_targeting;
        beep(keys.world, if (state.smart_targeting) .on else .off);
    }
    for (step_keys) |key| {
        if (!devices.active(key.action, true) or !controlled) continue;
        if (key.stops_matching) keys.player.matching_speed = false;
        const found = switch (key.steps) {
            .target => |among| pickTarget(state, all, key.step, among, key.holds, keys.multiplayer),
            .subtarget => subtarget: {
                input.cycleSubtarget(state, all, key.step, keys.multiplayer);
                break :subtarget listsComponents(all, current.target);
            },
        };
        beep(keys.world, if (found) .done else .refused);
    }
    if (devices.active(.target_under_reticule, true)) {
        const under: aigeneric.Target = if (state.under_reticle) |index| .at(index, null) else .none;
        const aimed = if (ai.targetValid(all, under, .{})) state.under_reticle else null;
        if (aimed) |index| {
            beep(keys.world, .done);
            if (controlled) {
                current.target.index = under.index;
                current.target.component = aigeneric.Target.whole;
                _ = state.bringUp(targetWindow(&all.slots[index]), keys.multiplayer);
            }
        } else beep(keys.world, .refused);
    }

    const missiles = state.windows.status.getPtr(.missiles);
    if (devices.active(.missile_window, true)) {
        beep(keys.world, .done);
        switch (missiles.phase) {
            .shut => if (state.windows.open(.missiles, keys.multiplayer)) {
                missiles.held = true;
            },
            .open => {
                missiles.held = false;
                state.windows.close(.missiles);
            },
            .opening, .closing => {},
        }
    }
    if (keys.multiplayer) return;
    for (ring_keys) |key| {
        if (!devices.active(key.action, true)) continue;
        if (state.windows.open(.missiles, keys.multiplayer)) missiles.held = true;
        const turned = state.missiles.turn(key.turn);
        const world = keys.world orelse continue;
        if (turned) sound3d.playIn(world, null, null, all.player, .missileselect, 1, .not_reserved);
        beep(keys.world, if (turned) .done else .refused);
        if (world.hearing) |hearing| state.missiles.sayName(hearing.sound);
    }
}

/// The keys that turn the missile ring, and which way each does.
const ring_keys = [_]struct { action: input.controls.Action, turn: missile_display.Turn }{
    .{ .action = .rotate_missiles_clockwise, .turn = .clockwise },
    .{ .action = .rotate_missiles_anticlockwise, .turn = .anticlockwise },
};

/// The nearest target keys, and the side each looks for.
const nearest_keys = [_]struct { action: input.controls.Action, side: gameobj.Side(i32) }{
    .{ .action = .target_nearest_enemy, .side = .hostile },
    .{ .action = .target_nearest_friendly, .side = .friendly },
};

/// The keys that step the target or its component, in the order `hud_target_keys` reads them:
/// which way each steps, and what through.
const step_keys = [_]StepKey{
    .{ .action = .next_enemy_target, .step = .next, .steps = .{ .target = .hostile }, .holds = true },
    .{ .action = .previous_enemy_target, .step = .previous, .steps = .{ .target = .hostile } },
    .{ .action = .next_subtarget, .step = .next, .steps = .subtarget },
    .{ .action = .previous_subtarget, .step = .previous, .steps = .subtarget },
    .{ .action = .next_friendly_target, .step = .next, .steps = .{ .target = .friendly } },
    .{ .action = .previous_friendly_target, .step = .previous, .steps = .{ .target = .friendly }, .stops_matching = false },
};

const StepKey = struct {
    action: input.controls.Action,
    step: input.Step,
    steps: union(enum) { target: input.Among, subtarget },
    /// Whether the target display it brings up is held open.
    holds: bool = false,
    /// Whether it stops MATCH SPEED.
    stops_matching: bool = true,
};

/// A next or previous target key: with neither form of the target display up and a target the
/// player can aim at, it brings up the target's form, held open for NEXT ENEMY TARGET alone;
/// otherwise it steps the target. Returns whether it brought the display up or found a target.
fn pickTarget(state: *State, all: *create.Objects, step: input.Step, among: input.Among, hold: bool, multiplayer: bool) bool {
    const current = all.slots[all.player].orders[0].target;
    const shut = state.windows.status.get(.target).phase == .shut and state.windows.status.get(.big_target).phase == .shut;
    if (shut and ai.targetValid(all, current, .{})) {
        const window = targetWindow(&all.slots[@intCast(current.index)]);
        if (state.windows.open(window, multiplayer) and hold) state.windows.status.getPtr(window).held = true;
        return true;
    }
    return input.cycleTarget(state, all, step, among, multiplayer);
}

/// Whether the player's `target` lists components and isn't friendly, which a subtarget key needs
/// to find one.
fn listsComponents(all: *const create.Objects, target: aigeneric.Target) bool {
    const index = target.slot() orelse return false;
    const object = &all.slots[index].object;
    return object.flags.components and object.side != .friendly;
}

/// The nearest ship to the player's on `side` within `pick_reach`, for the nearest target keys:
/// neither exploding nor, for a hostile one, cloaked.
fn nearest(all: *const create.Objects, side: gameobj.Side(i32)) ?usize {
    const from = all.slots[all.player].drawn.position;
    var best = pick_reach;
    var found: ?usize = null;
    for (all.slots[0..all.count], 0..) |*slot, index| {
        const object = &slot.object;
        if (index == all.player or object.type == .stand_in or object.side != side) continue;
        if (object.flags.exploding or (side == .hostile and object.flags.cloaked)) continue;
        const apart = math.distance(from, slot.drawn.position);
        if (apart < best) {
            best = apart;
            found = index;
        }
    }
    return found;
}

/// A mission of a player on Player Control, for the targeting's tests.
const TargetingTest = struct {
    mission: gameobj.testing.Mission,
    devices: input.Devices = .{},
    state: State = .{},

    fn init(test_: *TargetingTest) !void {
        test_.* = .{ .mission = undefined };
        try test_.mission.init(std.testing.allocator);
        const player = try test_.mission.add(.predator, @splat(0));
        try std.testing.expect(try aigeneric.push(test_.mission.orders(), player, .player_control, .none));
    }

    fn deinit(test_: *TargetingTest) void {
        test_.mission.deinit();
    }

    /// A ship of `ship_type` at `at` that the player can aim at.
    fn add(test_: *TargetingTest, ship_type: gameobj.Type, at: Vector) !u16 {
        const index = try test_.mission.add(ship_type, at);
        test_.mission.slot(index).object.flags.targetable = true;
        return index;
    }

    fn keys(test_: *TargetingTest, sight: ?Sight) Keys {
        return .{
            .devices = &test_.devices,
            .player = &test_.mission.player,
            .all = test_.mission.objects,
            .sight = sight,
            .last_view = .cockpit,
            .scale = 1,
            .multiplayer = false,
        };
    }

    /// Presses `action`'s key, with its modifier, for one reading of the targeting keys.
    fn tap(test_: *TargetingTest, action: input.controls.Action, sight: ?Sight) void {
        const keyboard = &test_.devices.keyboard;
        const bound = input.controls.binding(action);
        const modifier: ?u8 = switch (bound.modifier) {
            .shift => input.scan.left_shift,
            .control => input.scan.left_control,
            .alt => input.scan.left_alt,
            else => null,
        };
        keyboard.down[bound.key] = true;
        if (modifier) |held| keyboard.down[held] = true;
        targetKeys(&test_.state, test_.keys(sight));
        keyboard.down[bound.key] = false;
        if (modifier) |held| keyboard.down[held] = false;
        keyboard.read();
    }

    fn phase(test_: *TargetingTest, window: windows.Window) windows.Phase {
        return test_.state.windows.status.get(window).phase;
    }
};

/// A camera at the origin looking along Z at a screen of 640 by 480.
fn testSight() Sight {
    return .{ .place = .{}, .projection = .init(640, 480, .{ 0, 0, 1, 1 }, .{ 1, 1 }) };
}

test Sight {
    const sight = testSight();
    try std.testing.expectEqual([2]i32{ 639, 479 }, sight.last());
    try std.testing.expect(sight.onScreen(.{ 0, 0 }));
    try std.testing.expect(sight.onScreen(.{ 639, 479 }));
    try std.testing.expect(!sight.onScreen(.{ 640, 0 }));
    try std.testing.expect(!sight.onScreen(.{ -1, 5 }));
    try std.testing.expectEqual([2]i32{ 320, 240 }, sight.middle());
    // Straight ahead falls on the middle.
    try std.testing.expectEqual(sight.middle(), sight.pixel(sight.view(.{ 0, 0, 1000 })));
}

test "the display follows the player's target" {
    var t: TargetingTest = undefined;
    try t.init();
    defer t.deinit();
    const all = t.mission.objects;
    const sabre = try t.add(.sabre, .{ 0, 0, 5000 });
    const reliant = try t.add(.reliant, .{ 0, 0, 90000 });

    // With no target, nothing is drawn.
    t.state.followTarget(all, false);
    try std.testing.expectEqual(null, t.state.target);

    // A fighter comes up in the target display's small form, held open.
    input.setPlayerTarget(&t.state, all, @intCast(sabre), -1, false);
    try std.testing.expectEqual(sabre, t.state.target.?);
    try std.testing.expectEqual(.opening, t.phase(.target));
    try std.testing.expect(t.state.windows.status.get(.target).held);

    // A capital ship in the large one, which closes the small.
    input.setPlayerTarget(&t.state, all, @intCast(reliant), -1, false);
    try std.testing.expectEqual(.closing, t.phase(.target));
    try std.testing.expectEqual(.opening, t.phase(.big_target));

    // A friendly ship cloaked is drawn, outside a multiplayer game.
    all.slots[reliant].object.flags.cloaked = true;
    t.state.followTarget(all, false);
    try std.testing.expectEqual(reliant, t.state.target.?);
    t.state.followTarget(all, true);
    try std.testing.expectEqual(null, t.state.target);

    // One the player can no longer aim at is still shown, but not drawn; none closes the display.
    all.slots[reliant].object.flags.cloaked = false;
    all.slots[reliant].object.flags.exploding = true;
    t.state.followTarget(all, false);
    try std.testing.expectEqual(@as(i32, reliant), t.state.shown.index);
    try std.testing.expectEqual(null, t.state.target);
    input.setPlayerTarget(&t.state, all, -1, -1, false);
    try std.testing.expectEqual(.closing, t.phase(.big_target));
}

test targetKeys {
    var t: TargetingTest = undefined;
    try t.init();
    defer t.deinit();
    const all = t.mission.objects;
    const near = try t.add(.sabre, .{ 3000, 0, 5000 });
    const ahead = try t.add(.sabre, .{ 0, 0, 20000 });
    const friend = try t.add(.reliant, .{ 0, 40000, 0 });
    _ = try t.add(.sabre, .{ 0, 0, 700000 });
    const bomber = try t.add(.kamov, .{ 0, 0, -50000 });
    const current = &all.slots[all.player].orders[0].target;

    // The nearest enemy, from the cockpit.
    t.tap(.target_nearest_enemy, null);
    try std.testing.expectEqual(@as(i32, near), current.index);
    try std.testing.expectEqual(.opening, t.phase(.target));

    // With the display up, the next enemy target steps on, past the friend, the Kamov and the
    // Sabre out of reach, and round; and stops MATCH SPEED.
    t.mission.player.matching_speed = true;
    t.tap(.next_enemy_target, null);
    try std.testing.expectEqual(@as(i32, ahead), current.index);
    try std.testing.expect(!t.mission.player.matching_speed);
    t.tap(.next_enemy_target, null);
    try std.testing.expectEqual(@as(i32, bomber), current.index);
    t.tap(.previous_enemy_target, null);
    try std.testing.expectEqual(@as(i32, ahead), current.index);

    // With it shut, the key brings it up rather than stepping.
    t.state.windows = .{};
    t.tap(.next_enemy_target, null);
    try std.testing.expectEqual(@as(i32, ahead), current.index);
    try std.testing.expectEqual(.opening, t.phase(.target));

    // The nearest friend comes up in the large form.
    t.tap(.target_nearest_friendly, null);
    try std.testing.expectEqual(@as(i32, friend), current.index);
    try std.testing.expectEqual(.opening, t.phase(.big_target));

    // TARGET TORPEDO finds the Kamov.
    t.tap(.target_torpedo, null);
    try std.testing.expectEqual(@as(i32, bomber), current.index);

    // The Sabre dead ahead stands under the reticle; the near one stands off to the side.
    t.tap(.target_under_reticule, testSight());
    try std.testing.expectEqual(ahead, t.state.under_reticle.?);
    try std.testing.expectEqual(@as(i32, ahead), current.index);

    // Stepping from a lone target that the player cannot aim at leaves none.
    for ([_]u16{ near, ahead, bomber }) |index| all.slots[index].object.flags.exploding = true;
    t.tap(.next_enemy_target, null);
    try std.testing.expectEqual(-1, current.index);
    try std.testing.expectEqual(null, t.state.target);
}

test Flash {
    // The slow flash is lit for its first 50 ticks, dark to 100, and past that starts again dark.
    var ticks: i32 = 0;
    try std.testing.expect(Flash.slow.step(&ticks, 49));
    try std.testing.expect(!Flash.slow.step(&ticks, 1));
    try std.testing.expect(!Flash.slow.step(&ticks, 50));
    try std.testing.expectEqual(100, ticks);
    try std.testing.expect(!Flash.slow.step(&ticks, 1));
    try std.testing.expectEqual(0, ticks);
    try std.testing.expect(Flash.slow.step(&ticks, 1));
    // The fast one runs at twice the pace.
    ticks = 24;
    try std.testing.expect(!Flash.fast.step(&ticks, 1));
}

test Icons {
    var icons: Icons = .{};
    // Off, an icon is dark; on, it is lit and its count stands still.
    try std.testing.expect(!icons.lit(.ecm, 10));
    icons.show(.ecm, .on);
    try std.testing.expect(icons.lit(.ecm, 10));
    try std.testing.expectEqual(0, icons.slots[2].ticks);
    // Flashing, it is lit to 50 and dark to 100, and what runs past 100 carries over, lit.
    icons.show(.ecm, .flash);
    try std.testing.expect(icons.lit(.ecm, 49));
    try std.testing.expect(!icons.lit(.ecm, 1));
    try std.testing.expect(icons.lit(.ecm, 60));
    try std.testing.expectEqual(10, icons.slots[2].ticks);
    // Setting it again starts the flash over.
    icons.show(.ecm, .flash);
    try std.testing.expectEqual(0, icons.slots[2].ticks);
    // Past the table, an icon is left alone.
    icons.show(@enumFromInt(25), .on);
    try std.testing.expect(!icons.lit(@enumFromInt(25), 1));
}

test Charge {
    // Each device starts carried, off and full, and its bar is then about 32 pixels long.
    for (std.enums.values(Device)) |kind| {
        const charge: Charge = .full(kind);
        try std.testing.expectEqual(.off, charge.setting);
        try std.testing.expectEqual(32, charge.bar(kind));
    }
    // On, the spectral shields spend six ticks a tick, so ten seconds run them dry.
    var shields: Charge = .full(.spectral_shields);
    shields.setting = .on;
    try std.testing.expect(!shields.run(.spectral_shields, 999));
    try std.testing.expectEqual(6, shields.ticks);
    try std.testing.expect(shields.run(.spectral_shields, 2));
    try std.testing.expectEqual(0, shields.ticks);
    try std.testing.expectEqual(0, shields.bar(.spectral_shields));
    // Off, a device charges a tick a tick and stops at full.
    shields.setting = .off;
    try std.testing.expect(!shields.run(.spectral_shields, 7000));
    try std.testing.expectEqual(6000, shields.ticks);
    // A device the ship does not carry neither charges nor drains.
    var absent: Charge = .{ .setting = .absent, .ticks = 5 };
    try std.testing.expect(!absent.run(.ecm, 100));
    try std.testing.expectEqual(5, absent.ticks);
}

test "the lights hold as hud_draw tests them" {
    var state: State = .{};
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    // A ship that carries every device but has none on shows only its cloak.
    try std.testing.expectEqual(Lit{ .cloak = true }, state.lit(&object, false, false, 1));
    // ... and not even that in a multiplayer game.
    try std.testing.expectEqual(Lit{}, state.lit(&object, false, true, 1));

    // Blind fire, carried and on, shows while the guns are not all firing.
    state.blind_fire_fitted = true;
    try std.testing.expect(state.lit(&object, false, true, 1).blind_fire);
    object.gun_mode.all = true;
    try std.testing.expect(!state.lit(&object, false, true, 1).blind_fire);

    // A missile homing on the ship takes the lock warning's place.
    state.enemy_lock = true;
    try std.testing.expect(state.lit(&object, false, true, 1).enemy_lock);
    object.missile_homing = 1;
    const both = state.lit(&object, false, true, 1);
    try std.testing.expect(!both.enemy_lock and both.missile_incoming);

    // The spectral shields show only while on; an icon lights the ECM's light without it.
    state.devices.getPtr(.spectral_shields).setting = .on;
    try std.testing.expect(state.lit(&object, false, true, 1).spectral_shields);
    try std.testing.expect(!state.lit(&object, false, true, 1).ecm);
    state.icons.show(.ecm, .on);
    try std.testing.expect(state.lit(&object, false, true, 1).ecm);
}

test "an icon flashes only as it is asked for" {
    // `hud_draw` asks for the smart targeting icon only while smart targeting is off.
    var state: State = .{};
    const object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    state.icons.show(.smart_targeting, .flash);
    state.smart_targeting = true;
    _ = state.lit(&object, false, false, 30);
    try std.testing.expectEqual(0, state.icons.slots[4].ticks);
    state.smart_targeting = false;
    _ = state.lit(&object, false, false, 30);
    try std.testing.expectEqual(30, state.icons.slots[4].ticks);
}

test "the countermeasures readout flashes with its icon" {
    var state: State = .{};
    try std.testing.expect(state.shows(.coil, 10));
    state.icons.show(.countermeasures, .flash);
    try std.testing.expect(state.shows(.coil, 49));
    try std.testing.expect(!state.shows(.coil, 1));
    // The other readouts have no icon.
    try std.testing.expect(state.shows(.fuel, 1));
}

test "the jump prompt waits a frame, and a warp comes first" {
    var state: State = .{ .prompt_ticks = 70 };
    var ready: Readiness = .{ .jump = .newly, .warp = .newly };
    // The first frame starts the warp's flash and draws nothing; the jump waits its turn.
    try std.testing.expectEqual(null, state.jumpPrompt(&ready, 10));
    try std.testing.expectEqual(.shown, ready.warp);
    try std.testing.expectEqual(.newly, ready.jump);
    try std.testing.expectEqual(0, state.prompt_ticks);
    // Then the warp's shape flashes.
    try std.testing.expectEqual(JumpPrompt.warp_shape, state.jumpPrompt(&ready, 10));
    try std.testing.expectEqual(null, state.jumpPrompt(&ready, 40));
    // With the warp taken, the jump comes up.
    ready.warp = .no;
    try std.testing.expectEqual(null, state.jumpPrompt(&ready, 10));
    try std.testing.expectEqual(JumpPrompt.jump_shape, state.jumpPrompt(&ready, 10));
}

test "the scanner moves on once 25 ticks have passed" {
    var state: State = .{};
    // It moves on at the first tick past the one it waits for, so a frame lasts 26 ticks.
    var frames: [7]u8 = undefined;
    for (&frames, 0..) |*frame, step| frame.* = state.scannerFrame(@intCast(1 + step * (scanner_step + 1)));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 0, 1, 2 }, &frames);
    try std.testing.expectEqual(2, state.scannerFrame(state.scanner_next));
    try std.testing.expectEqual(3, state.scannerFrame(state.scanner_next + 1));
}

/// The quadrants of a ship whose armour hits have worn since the ship status indicator last drew
/// it (`object_armor_damage`): `ship_status_hits` (`0x00563160`) for the player's own ship and
/// `target_status_hits` (`0x005635D4`) for its target.
pub const Hits = std.EnumSet(collision.Quadrant);

/// The ship status indicator (`hud_ship_status`, `0x00489350`): a ship's schematic, with the
/// quadrants hits have worn flashing on it, and round it its shields and its armour as two rings of
/// four arcs, the shields outside. Mode 0 draws the player's own ship, which `hud_draw` places 0.3
/// of the way across, at the foot of the screen, 2 right and 44 up; mode 1 the target, in the
/// target display's small form ([`hud/target_display.zig`](hud/target_display.zig)), turned to
/// face the player: its arcs mirrored across, left for right.
pub const ShipStatus = struct {
    pub const offset: [2]i32 = .{ 2, -44 };
    pub const across: f32 = 0.3;
    pub const down: f32 = 1;

    /// Whose ship `hud_ship_status` draws, its mode.
    pub const Mode = enum(u1) { player = 0, target = 1 };

    /// One arc of a ring: where it hangs from the point, and the shape a level of 0 would be, each
    /// level above it drawing the shape one before. Five shapes an arc.
    pub const Arc = struct { offset: [2]i32, base: u16 };

    /// Where a mode draws each part from the indicator's point: the schematic, the hits on it, and
    /// the shields' and the armour's arcs, each in the order of the quadrants
    /// (`collision.Quadrant`): left, right, fore and aft.
    pub const Layout = struct {
        schematic: [2]i32,
        hits: [2]i32,
        shields: [4]Arc,
        armor: [4]Arc,
    };

    pub const layouts: std.EnumArray(Mode, Layout) = .init(.{
        .player = .{
            .schematic = .{ -0x22, -0x1B },
            .hits = .{ -0x22, -0x1B },
            .shields = .{
                .{ .offset = .{ -0x2D, -0x14 }, .base = 0xAD },
                .{ .offset = .{ 0x1F, -0x14 }, .base = 0xA3 },
                .{ .offset = .{ -0x17, -0x1F }, .base = 0x9E },
                .{ .offset = .{ -0x22, 0x19 }, .base = 0xA8 },
            },
            .armor = .{
                .{ .offset = .{ -0x27, -0x12 }, .base = 0x99 },
                .{ .offset = .{ 0x1B, -0x12 }, .base = 0x8F },
                .{ .offset = .{ -0x15, -0x1C }, .base = 0x8A },
                .{ .offset = .{ -0x1D, 0x16 }, .base = 0x94 },
            },
        },
        .target = .{
            .schematic = .{ -0x1C, -0x1A },
            .hits = .{ -0x1E, -0x1B },
            .shields = .{
                .{ .offset = .{ -0x26, -0x14 }, .base = 0xA3 },
                .{ .offset = .{ 0x23, -0x14 }, .base = 0xAD },
                .{ .offset = .{ -0x18, -0x1F }, .base = 0x9E },
                .{ .offset = .{ -0x13, 0x19 }, .base = 0xA8 },
            },
            .armor = .{
                .{ .offset = .{ -0x20, -0x12 }, .base = 0x8F },
                .{ .offset = .{ 0x1F, -0x12 }, .base = 0x99 },
                .{ .offset = .{ -0x15, -0x1C }, .base = 0x8A },
                .{ .offset = .{ -0xF, 0x16 }, .base = 0x94 },
            },
        },
    });

    /// The arcs for what SHIELD BALANCING has shifted beyond the fore and aft shields
    /// (`gameobj.ShieldReserves`), outside the top arc and the foot arc. `hud_ship_status` draws
    /// them for the player's own ship only, each by its reserve as `level` works it out.
    pub const reserve_arcs = struct {
        pub const fore: Arc = .{ .offset = .{ -0x1A, -0x24 }, .base = 0xB2 };
        pub const aft: Arc = .{ .offset = .{ -0x26, 0x1D }, .base = 0xB7 };
    };

    /// What `hud_ship_status` draws of a ship, worked out from it whole, so that the target display
    /// can close with it.
    pub const Shown = struct {
        /// The ship's schematic, where its type has one and the mode draws it.
        schematic: ?Schematic = null,
        /// Whether the schematic and the hits on it are drawn mirrored across.
        mirrored: bool = false,
        /// The quadrants that flash on the schematic, shapes 1 to 4 of it.
        hits: Hits = .initEmpty(),
        /// The arcs' levels, or null for a type with none.
        rings: ?Rings = null,
        /// For the player's own ship, the levels of what SHIELD BALANCING shifted fore and aft.
        reserves: ?[2]i32 = null,
    };

    /// The levels of the arcs of the two rings, in the quadrants' order.
    pub const Rings = struct {
        shields: [4]i32,
        armor: [4]i32,
    };

    /// How much of an arc is drawn: the quadrant's value over the ship's shield power, for a
    /// shield, or its armour class, for the armour, cut down to a whole number as the runtime's
    /// `__ftol` does (`math.ftol`), less one, in the game's 32-bit arithmetic. An arc of 0 or less
    /// is not drawn. A ship with none of either has no arcs of it; the game divides by nothing
    /// regardless.
    pub fn level(value: f32, per_arc: i32) i32 {
        if (per_arc == 0) return 0;
        const share = value / @as(f32, @floatFromInt(per_arc));
        return math.ftol(share) -% 1;
    }

    /// The rings of the ship of `slot`, or null for a comms relay or a deathmatch beacon, which
    /// have none. The armour of an invulnerable ship shows at least two arcs of its five, each
    /// level `(2 * level + 6) / 3`.
    pub fn rings(slot: *const create.Slot) ?Rings {
        const object = &slot.object;
        if (object.type == .comms_relay or object.type == .dm_beacon) return null;
        const combat = slot.combat orelse return null;
        var found: Rings = undefined;
        const invulnerable = object.invulnerable == .full or object.invulnerable == .player_can_hit;
        for (&found.shields, &found.armor, object.shields.values(), object.armor.values()) |*shield, *armor, has, left| {
            shield.* = level(has, combat.shield_power);
            armor.* = level(left, combat.armor_class);
            if (invulnerable) armor.* = @divTrunc(2 *% armor.* +% 6, 3);
        }
        return found;
    }

    /// Mode 0 for the player's ship of `slot`: its schematic, the hits taken out of `hits` for a
    /// type the target display shows in its small form, its rings, and what SHIELD BALANCING has
    /// shifted. **Not ported:** in mission 25, a Kamov's schematic drawn mirrored.
    pub fn ofPlayer(slot: *const create.Slot, hits: *Hits, reserves: gameobj.ShieldReserves) Shown {
        var shown: Shown = .{ .rings = rings(slot) };
        if (slot.combat) |combat| if (shown.rings) |_| {
            shown.reserves = .{ level(reserves.fore, combat.shield_power), level(reserves.aft, combat.shield_power) };
        };
        const loaded = slot.type orelse return shown;
        shown.schematic = loaded.schematic orelse return shown;
        const small = if (slot.combat) |combat| combat.display == .small else false;
        if (small) shown.hits = take(hits);
        return shown;
    }

    /// Mode 1 for the target of `slot`: for a type the target display shows in its small form, its
    /// schematic, turned to face the player unless the type is hostile, and the hits taken out of
    /// `hits`, which a comms relay or a deathmatch beacon turned about leaves; then its rings.
    pub fn ofTarget(slot: *const create.Slot, hits: *Hits) Shown {
        var shown: Shown = .{ .rings = rings(slot) };
        const combat = slot.combat orelse return shown;
        if (combat.display != .small) return shown;
        const loaded = slot.type orelse return shown;
        shown.schematic = loaded.schematic orelse return shown;
        shown.mirrored = combat.side != .hostile;
        if (!shown.mirrored or shown.rings != null) shown.hits = take(hits);
        return shown;
    }

    fn take(hits: *Hits) Hits {
        defer hits.* = .initEmpty();
        return hits.*;
    }

    /// Draws what `shown` holds in `mode`, from `point`, `size` times the display's own size and
    /// cut to `clip`; the schematic and its hits shaken as `shake` says, the arcs still.
    ///
    /// **Fix:** while shaken, the game draws the player's own schematic two pixels left and two
    /// down of where it draws it still, apart from its hits. OpenReliant keeps it in place.
    pub fn draw(
        shown: Shown,
        mode: Mode,
        art: *Art,
        gpa: Allocator,
        target: device.Device,
        point: [2]i32,
        size: f32,
        clip: ?Clip,
        colour: [4]f32,
        shake: ?Shake,
    ) (spr.Error || Allocator.Error)!void {
        const layout = layouts.get(mode);
        if (shown.schematic) |schematic| {
            const how: Draw = .{ .mirror = .{ .across = shown.mirrored }, .clip = clip, .shake = shake };
            try drawShapeWith(schematic.art, schematic.gpa, target, 0, scaled(point, layout.schematic, size), colour, size, how);
            var hits = shown.hits.iterator();
            while (hits.next()) |quadrant| {
                try drawShapeWith(schematic.art, schematic.gpa, target, @as(usize, @intFromEnum(quadrant)) + 1, scaled(point, layout.hits, size), colour, size, how);
            }
        }
        const found = shown.rings orelse return;
        const how: Draw = .{ .mirror = .{ .across = mode == .target }, .clip = clip };
        for (layout.shields, found.shields) |arc, drawn| try drawArc(art, gpa, target, arc, drawn, point, colour, size, how);
        if (shown.reserves) |shifted| {
            try drawArc(art, gpa, target, reserve_arcs.fore, shifted[0], point, colour, size, how);
            try drawArc(art, gpa, target, reserve_arcs.aft, shifted[1], point, colour, size, how);
        }
        for (layout.armor, found.armor) |arc, drawn| try drawArc(art, gpa, target, arc, drawn, point, colour, size, how);
    }

    /// An arc drawn `drawn` shapes from its base, if any of it is.
    fn drawArc(art: *Art, gpa: Allocator, target: device.Device, arc: Arc, drawn: i32, point: [2]i32, colour: [4]f32, size: f32, how: Draw) (spr.Error || Allocator.Error)!void {
        if (drawn <= 0) return;
        const shape = @as(i32, arc.base) - drawn;
        if (shape < 0) return;
        try drawShapeWith(art, gpa, target, @intCast(shape), scaled(point, arc.offset, size), colour, size, how);
    }
};

test ShipStatus {
    // A ship is created with 6 times its shield power, less one, in each quadrant: four arcs of
    // the five, which is what a quadrant keeps until its shield charges the rest of the way.
    try std.testing.expectEqual(4, ShipStatus.level(6 * 3 - 1, 3));
    try std.testing.expectEqual(5, ShipStatus.level(6 * 3, 3));
    // Down to under twice the power, none are left.
    try std.testing.expectEqual(0, ShipStatus.level(5, 3));
    // The runtime cuts toward zero rather than rounding, and past an `int` keeps the low half of
    // the 64-bit whole number, as `__ftol` does.
    try std.testing.expectEqual(1, ShipStatus.level(2.99 * 3, 3));
    try std.testing.expectEqual(0, ShipStatus.level(10, 0));
    try std.testing.expectEqual(-1294967297, ShipStatus.level(3e9, 1));

    // In both modes, the armour's arcs are shapes 0x85 to 0x98 and the shields' 0x99 to 0xAC,
    // five an arc, each arc's following on from the last's.
    for (std.enums.values(ShipStatus.Mode)) |mode| {
        const layout = ShipStatus.layouts.get(mode);
        var shapes: [8 * 5]u16 = undefined;
        var at: usize = 0;
        for (layout.armor ++ layout.shields) |arc| {
            for (1..6) |l| {
                shapes[at] = arc.base - @as(u16, @intCast(l));
                at += 1;
            }
        }
        std.mem.sort(u16, &shapes, {}, std.sort.asc(u16));
        for (shapes, 0..) |shape, i| try std.testing.expectEqual(0x85 + i, shape);
    }
    // The target faces the player: its left arcs are the player's right ones, on its left.
    const player = ShipStatus.layouts.get(.player);
    const target = ShipStatus.layouts.get(.target);
    try std.testing.expectEqual(player.shields[1].base, target.shields[0].base);
    try std.testing.expect(target.shields[0].offset[0] < 0 and target.armor[0].offset[0] < 0);

    // The shifted shields' arcs follow on from those: a full reserve, five times the shield
    // power, draws four of the five, 0xAE to 0xB1 fore and 0xB3 to 0xB6 aft.
    try std.testing.expectEqual(4, ShipStatus.level(5 * 3, 3));
    try std.testing.expectEqual(0xAE, ShipStatus.reserve_arcs.fore.base - 4);
    try std.testing.expectEqual(0xB3, ShipStatus.reserve_arcs.aft.base - 4);
}

test "the rings follow the shields and the armour" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const index = try mission.add(.sabre, @splat(0));
    const slot = mission.slot(index);
    const combat = slot.combat.?;
    slot.object.shields = .all(combat.fullShields());
    slot.object.armor = .all(combat.fullArmor());
    slot.object.armor.left = @floatFromInt(combat.armor_class * 2);
    var found = ShipStatus.rings(slot).?;
    try std.testing.expectEqual([4]i32{ 5, 5, 5, 5 }, found.shields);
    try std.testing.expectEqual([4]i32{ 1, 5, 5, 5 }, found.armor);
    // Invulnerable, its armour shows at least two arcs.
    slot.object.armor.left = 0;
    slot.object.invulnerable = .full;
    found = ShipStatus.rings(slot).?;
    try std.testing.expectEqual(1, found.armor[0]);
    try std.testing.expectEqual(5, found.armor[1]);
    // A comms relay has no rings, and so nothing shifted for mode 0 to show.
    slot.object.type = .comms_relay;
    try std.testing.expectEqual(null, ShipStatus.rings(slot));
    var own_hits: Hits = .initEmpty();
    const shield_power: f32 = @floatFromInt(combat.shield_power);
    try std.testing.expectEqual(null, ShipStatus.ofPlayer(slot, &own_hits, .{ .fore = 5 * shield_power }).reserves);

    // Mode 0 shows what SHIELD BALANCING shifted as levels of the shield power.
    slot.object.type = .sabre;
    own_hits.insert(.aft);
    const player = ShipStatus.ofPlayer(slot, &own_hits, .{ .fore = 5 * shield_power, .aft = 0 });
    try std.testing.expectEqual([2]i32{ 4, -1 }, player.reserves.?);
    try std.testing.expect(player.rings != null);
    // With no schematic loaded, the hits stay for the next time.
    try std.testing.expectEqual(null, player.schematic);
    try std.testing.expect(own_hits.contains(.aft));

    // Mode 1 takes the hits and leaves none behind, for a hostile target of the small form.
    var hits: Hits = .initEmpty();
    hits.insert(.fore);
    const without = ShipStatus.ofTarget(slot, &hits);
    // With no schematic, the hits stay for the next time.
    try std.testing.expectEqual(null, without.schematic);
    try std.testing.expect(hits.contains(.fore));
}

// --- The targeting cluster -------------------------------------------------------------------

/// The targeting cluster about the middle of the screen, which `hud_draw` draws in view 0 after
/// the ship status indicator: an arc either side, the left one for the speed and the right one
/// for the guns' charge, each lit from the foot up to its level; a marker on the left arc for the
/// speed the ship makes and another for the speed its throttle asks, each with its figure; and
/// the reticle at the middle.
pub const Cluster = struct {
    /// The left arc; the right one is the same shape drawn mirrored.
    pub const arc_shape: u16 = 0x7F;
    /// How far either arc stands from the middle: this share of the screen's width (`apart`),
    /// which `hud_draw` holds at `0x004DC8F4` for the left arc and negated at `0x004DC8F8` for the
    /// right. The arcs part as the screen widens.
    pub const spread: f32 = 0.15625;

    /// How far either arc stands from the middle of a screen `width` across: `spread` of it, cut
    /// down to a whole number as `__ftol` does.
    pub fn apart(width: i32) i32 {
        return math.ftol(@as(f32, @floatFromInt(width)) * spread);
    }
    /// How far above the middle the arcs' tops stand.
    pub const up: i32 = 0x4A;
    /// How far left of its place the right arc is drawn, near the arc's own width.
    pub const mirror_shift: i32 = 0x43;
    /// The centre of the circle the markers ride, from the left arc's point, and how far out
    /// across and down they ride from it.
    pub const circle: [2]i32 = .{ 100, 80 };
    pub const reach: [2]f32 = .{ 124, 94 };
    /// A marker's angle, in degrees: 310 at nothing, less 100 at full.
    pub const empty_angle: f32 = 310;
    pub const sweep: f32 = 100;
    pub const marker_shape: u16 = 0xEA;
    /// Where a marker's figure stands from the marker, ending there.
    pub const figure_offset: [2]i32 = .{ -10, -8 };
    /// The throttle's marker shows while the throttle differs from the speed by more than this,
    /// three times over, and as bright as that, to full.
    pub const throttle_shown: f32 = 0.1;
    pub const throttle_fade: f32 = 3;

    /// An arc's fill: the lit shape below the level and the unlit one above it, both drawn at
    /// `offset` from the arc's point, into two panes a pixel above and left of it, `pane_width`
    /// wide and down to `pane_bottom` below the arcs' top.
    pub const Fill = struct { lit: u16, unlit: u16, offset: [2]i32 };
    pub const speed_fill: Fill = .{ .lit = 0xB8, .unlit = 0xB9, .offset = .{ -10, 0 } };
    pub const charge_fill: Fill = .{ .lit = 0xF9, .unlit = 0xF8, .offset = .{ 14, 0 } };
    pub const pane_width: i32 = 0x42;
    pub const pane_bottom: i32 = 0x8A;
    /// The charge arc's height in pixels, all of it lit when the guns are full.
    pub const charge_height: f32 = 0x8A;

    /// What the cluster shows: the object's throttle and speed, its type's top speed, and its
    /// guns' charge against the most it holds.
    pub const Gauges = struct {
        throttle: f32,
        speed: f32,
        max_speed: f32,
        charge: f32,
        full_charge: f32,
        /// The Nova Cannon's charge (`GameObject.nova_charge`), which the charge arc shows in
        /// place of the guns' on a Phoenix firing a group the cannon leads (`novaShown`).
        nova: ?f32 = null,

        /// How far down from the arcs' top the charge arc is unlit: for the Nova Cannon, as far
        /// as it has charged.
        pub fn unlit(gauges: Gauges) i32 {
            if (gauges.nova) |nova| return round(nova * charge_height);
            return chargeLevel(gauges.charge, gauges.full_charge);
        }
    };

    /// Where a marker for `share` of the arc stands from the circle's centre, in the display's
    /// own pixels, rounded as `0x004C3330` does.
    pub fn markerOffset(share: f32) [2]i32 {
        const angle = (empty_angle - share * sweep) * std.math.rad_per_deg;
        return .{ round(@sin(angle) * reach[0]), round(@cos(angle) * reach[1]) };
    }

    /// How far down from the arcs' top the charge arc is unlit: all of it for no charge, none
    /// for a full one. A ship whose guns hold nothing has it all unlit; the game divides by the
    /// nothing regardless.
    pub fn chargeLevel(charge: f32, full: f32) i32 {
        if (full <= 0) return @intFromFloat(charge_height);
        return @as(i32, @intFromFloat(charge_height)) - round(charge * charge_height / full);
    }

    /// The throttle and the speed as shares of the arc: the throttle's size to 1, and the speed
    /// over the top speed to 1.
    pub fn shares(gauges: Gauges) [2]f32 {
        const throttle = @min(@abs(gauges.throttle), 1);
        const speed = if (gauges.max_speed > 0) @min(gauges.speed / gauges.max_speed, 1) else 0;
        return .{ throttle, speed };
    }
};

/// Draws the targeting cluster's arcs and markers as `hud_draw` does, from its right arc to the
/// charge's fill.
pub fn drawCluster(
    art: *Art,
    opened: *Opened,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    gauges: Cluster.Gauges,
    colour: [4]f32,
    scale: f32,
    shake: ?Shake,
) (spr.Error || Allocator.Error)!void {
    const width: i32 = @intCast(screen[0]);
    const height: i32 = @intCast(screen[1]);
    const apart = Cluster.apart(width);
    const top = (height >> 1) - pixels(Cluster.up, scale);
    const left: [2]i32 = .{ (width >> 1) - apart, top };
    const right: [2]i32 = .{ (width >> 1) + apart - pixels(Cluster.mirror_shift, scale), top };
    try drawShapeWith(art, gpa, target, Cluster.arc_shape, right, colour, scale, .{ .mirror = .{ .across = true }, .shake = shake });
    try drawShapeWith(art, gpa, target, Cluster.arc_shape, left, colour, scale, .{ .shake = shake });

    const centre = scaled(left, Cluster.circle, scale);
    const throttle, const speed = Cluster.shares(gauges);
    var buffer: [16]u8 = undefined;

    // The throttle's marker, dimmed as it nears the speed: `hud_draw` makes the global palette
    // that much darker for it.
    const brightness = @min(@abs(throttle - speed) * Cluster.throttle_fade, 1);
    if (brightness > Cluster.throttle_shown) {
        const dim: [4]f32 = .{ colour[0] * brightness, colour[1] * brightness, colour[2] * brightness, colour[3] };
        const marker = scaled(centre, Cluster.markerOffset(throttle), scale);
        try drawShape(art, gpa, target, Cluster.marker_shape, marker, dim, scale);
        const asked = std.fmt.bufPrint(&buffer, "{d}", .{round(gauges.max_speed * gauges.throttle)}) catch return;
        _ = try drawText(opened, gpa, target, scaled(marker, Cluster.figure_offset, scale), asked, dim, .right, scale);
    }

    const offset = Cluster.markerOffset(speed);
    const marker = scaled(centre, offset, scale);
    try drawShape(art, gpa, target, Cluster.marker_shape, marker, colour, scale);
    const made = std.fmt.bufPrint(&buffer, "{d}", .{round(gauges.speed)}) catch return;
    _ = try drawText(opened, gpa, target, scaled(marker, Cluster.figure_offset, scale), made, colour, .right, scale);

    // The speed's fill is lit below its marker, the charge's below its level.
    try drawFill(art, gpa, target, Cluster.speed_fill, left, offset[1] + Cluster.circle[1], colour, scale);
    try drawFill(art, gpa, target, Cluster.charge_fill, right, gauges.unlit(), colour, scale);
}

/// An arc's fill for `level` pixels down from the arcs' top: the lit shape into the pane from
/// a pixel above the level to the foot, then the unlit one into the pane from a pixel above the
/// top to the level, so the row they share is unlit.
fn drawFill(
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    fill: Cluster.Fill,
    arc: [2]i32,
    level: i32,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!void {
    const at = scaled(arc, fill.offset, scale);
    const x: f32 = @floatFromInt(at[0]);
    const y: f32 = @floatFromInt(at[1]);
    const edge = Clip.edge;
    const pane_left = x - scale;
    const pane_right = edge(x, Cluster.pane_width - 1, scale);
    try drawShapeWith(art, gpa, target, fill.lit, at, colour, scale, .{ .clip = .{
        .left = pane_left,
        .top = edge(y, level - 1, scale),
        .right = pane_right,
        .bottom = edge(y, Cluster.pane_bottom, scale),
    } });
    try drawShapeWith(art, gpa, target, fill.unlit, at, colour, scale, .{ .clip = .{
        .left = pane_left,
        .top = y - scale,
        .right = pane_right,
        .bottom = edge(y, level, scale),
    } });
}

/// The reticle at the middle of the screen, and blind fire's sight: the same shape brighter, which
/// jumps onto a target near the middle while blind fire aims the guns at it and glides back.
pub const reticle_shape: u16 = 0xD7;
pub const sight_shape: u16 = 0xD8;
/// How near the middle a target stands for the reticle to be drawn bright: within `0x10` either
/// way.
pub const under_reticle: i32 = 0x10;
/// How near the middle blind fire takes a target: within `0x46` across and `0x32` down.
pub const blind_fire_reach: [2]i32 = .{ 0x46, 0x32 };
/// How near the middle the sight comes to rest, gliding a pixel a tick.
pub const sight_rest: i32 = 2;

/// What blind fire does about a target near the middle.
pub const BlindFire = enum {
    /// The ship does not carry it, it is off, or every group of guns fires on a ship of more
    /// than one.
    off,
    /// It aims the guns at the target.
    on,
    /// It is on, but the chosen group's first gun is of type 11, which it does not aim.
    excluded,
};

/// Draws the reticle as `hud_draw` does in view 0, for a target standing at `target_at` on the
/// screen, if one does, and says whether blind fire aims at it, which the game keeps as the
/// object's `blind_fire_aim`. The chase view draws neither the reticle nor the sight.
pub fn drawReticle(
    state: *State,
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    mode: camera.CockpitMode,
    target_at: ?[2]i32,
    blind_fire: BlindFire,
    frame_duration: i32,
    colour: [4]f32,
    scale: f32,
    shake: ?Shake,
) (spr.Error || Allocator.Error)!bool {
    const how: Draw = .{ .shake = shake };
    const middle: [2]i32 = .{ @as(i32, @intCast(screen[0])) >> 1, @as(i32, @intCast(screen[1])) >> 1 };
    const drawn = mode != .chase;
    if (drawn) try drawShapeWith(art, gpa, target, reticle_shape, middle, colour, scale, how);
    const found = target_at orelse {
        if (drawn) try drawShapeWith(art, gpa, target, reticle_shape, middle, colour, scale, how);
        state.reticle_bright = false;
        return false;
    };
    const near = pixels(under_reticle, scale);
    var bright = found[0] > middle[0] - near and found[0] < middle[0] + near and
        found[1] > middle[1] - near and found[1] < middle[1] + near;
    const reach: [2]i32 = .{ pixels(blind_fire_reach[0], scale), pixels(blind_fire_reach[1], scale) };
    const apart: [2]i32 = .{ found[0] - middle[0], found[1] - middle[1] };
    var at = middle;
    var aims = false;
    const within = @abs(apart[0]) < reach[0] and @abs(apart[1]) < reach[1];
    if (within and blind_fire == .on) {
        at = found;
        state.sight = found;
        aims = true;
        bright = true;
    } else if (!(within and blind_fire == .excluded)) {
        var sight = state.sight orelse middle;
        const rest = pixels(sight_rest, scale);
        const glide = pixels(frame_duration, scale);
        for (0..2) |axis| {
            if (sight[axis] < middle[axis] - rest) {
                sight[axis] += glide;
                at[axis] = sight[axis];
            } else if (sight[axis] > middle[axis] + rest) {
                sight[axis] -= glide;
                at[axis] = sight[axis];
            }
        }
        state.sight = sight;
    }
    if (drawn) try drawShapeWith(art, gpa, target, if (bright) sight_shape else reticle_shape, at, colour, scale, how);
    state.reticle_bright = bright;
    return aims;
}

/// What the display draws the target with, besides its shapes: `smlfont.fnt`, for the range by
/// the marker at the screen's edge, and `newfont.fnt`, for the range by the brackets.
pub const TargetFonts = struct {
    small: Opened,
    new: Opened,

    pub const small_name = "SMLFONT.FNT";
    pub const new_name = "NEWFONT.FNT";
};

/// What the display draws the target in: the scene as it is drawn this frame, the objects, and
/// the cockpit's mode.
pub const TargetScene = struct {
    sight: Sight,
    all: *const create.Objects,
    mode: camera.CockpitMode,
};

/// **Improvement.** Where the line starts that places the marker for a target out of sight on the
/// screen's edge (`drawTarget`). The game clips a line out to the edge from the arrow's tip across,
/// but from the tip of one of the arrow's wings across again for down: a slip that starts the line
/// as far down the screen as the middle is across, so the marker stands lower on the side edges
/// than the target lies, and the more the wider the window. OpenReliant starts the line at the
/// arrow's tip; `--original` starts it where the game does.
pub const EdgeLine = enum { from_tip, original };

/// What the display draws one way for a hostile target and another for the rest.
pub fn Sided(comptime T: type) type {
    return struct {
        hostile: T,
        other: T,

        pub fn of(sided: @This(), hostile: bool) T {
            return if (hostile) sided.hostile else sided.other;
        }
    };
}

/// The shapes of the target's brackets, the first of four for the corners: top left, top right,
/// bottom left and bottom right.
pub const brackets_shape: Sided(u16) = .{ .hostile = 0x126, .other = 0x122 };
/// The least the brackets stand apart either way, in the display's own pixels (`0x004DC624`).
pub const least_brackets: f32 = 15;
/// Where the range stands from the bottom right bracket, ending there (`0x004DC620`).
pub const range_offset: [2]i32 = .{ 10, 9 };
/// The lead cursor's shape, and how far from its middle its line starts toward the target, in
/// the display's own pixels (`0x004DC56C`).
pub const lead_shape: u16 = 0x12F;
pub const lead_gap: f32 = 5;
/// The palette entries the arrow for a target out of sight is drawn in, the hostile one also the
/// lead cursor's line's: red, and green.
pub const line_colour: Sided(u8) = .{ .hostile = 0x26, .other = 0x62 };
/// The palette entry the pointer to the player's nav point is drawn in (`hud_target`,
/// `0x00489D9A`).
pub const nav_colour: u8 = 0x2F;
/// How far from the middle of the screen the arrow's tip and its base stand, and how far either
/// side of its base its wings reach, in the display's own pixels (`0x004DC724`, `0x004DC788`,
/// `0x004DC424`).
pub const arrow_tip: f32 = 32;
pub const arrow_back: f32 = 10;
pub const arrow_wing: f32 = 4;

/// The marker at the screen's edge for a target out of sight: its shapes, the first of four,
/// one for each edge.
pub const Edge = enum(u2) {
    bottom = 0,
    left = 1,
    right = 2,
    top = 3,

    pub const shape: Sided(u16) = .{ .hostile = 0x16C, .other = 0x170 };

    /// Where the shape and the range stand from where the line meets the edge, in the display's
    /// own pixels, and how the range is aligned; at the top and on the left the game places the
    /// shape at a set distance from the edge, which comes to the same.
    pub const Spec = struct { shape: [2]i32, text: [2]i32, alignment: Align };

    pub fn spec(edge: Edge) Spec {
        return switch (edge) {
            .top => .{ .shape = .{ 0, 12 }, .text = .{ -2, 11 }, .alignment = .centre },
            .left => .{ .shape = .{ 8, 0 }, .text = .{ 9, -6 }, .alignment = .left },
            .right => .{ .shape = .{ -6, 0 }, .text = .{ -8, -6 }, .alignment = .right },
            .bottom => .{ .shape = .{ 0, -4 }, .text = .{ -2, -16 }, .alignment = .centre },
        };
    }

    /// The edge a point on the screen's last row or column lies on, the top taking a corner of
    /// its own and the right taking any point that is on no other.
    pub fn of(at: [2]i32, last: [2]i32) Edge {
        if (at[1] == 0) return .top;
        if (at[1] >= last[1]) return .bottom;
        return if (at[0] == 0) .left else .right;
    }
};

/// `0x00489BC0`: which way on the screen the target at `at` lies from the ship at `ship`: the
/// offset to it in the ship's frame, across and down, made a unit. A target straight ahead or
/// behind, which leaves no way, is pointed at from below; the game divides by nothing there.
pub fn pointerDirection(ship: math.Place, at: Vector) [2]f32 {
    const offset = ship.inverse(at);
    const length = @sqrt(offset[0] * offset[0] + offset[1] * offset[1]);
    if (!(length > 0)) return .{ 0, 1 };
    return .{ offset[0] / length, offset[1] / length };
}

/// `0x00489C70`, which `hud_draw` runs in view 0 between the jump prompt and the eject marker:
/// draws the player's target, and returns where the lead cursor stands (`hud_target_x`,
/// `hud_target_y`), the point the reticle closes on, if it is drawn.
///
/// A target whose node (`ai.targetPart`) stands off the screen or behind the camera gets an arrow
/// from the middle of the screen pointing its way, red for a hostile one and green for the rest,
/// or in the chase view the pointer in the scene (`State.chase_pointer`, `chase.Chase`), and a
/// marker where a line its way leaves the screen, with the range in kilometres. One on the
/// screen gets four brackets at the corners of its box, the component's for a subtarget, as the
/// camera sees it, with the range under them; and, if it lists no components and is not friendly,
/// the lead cursor where to aim with the guns (`ai.leadAim`), which it keeps (`State.lead_point`),
/// and a line from it toward the target, in red.
///
/// First, where the player's ship points to a nav point (`GameObject.nav_point`), it draws the
/// same arrow its way in `nav_colour`, whether the nav point is in sight or not, or in the chase
/// view turns its pointer in the scene (`State.chase_nav_roll`).
///
/// Not yet ported: the corners it marks on the object the radio's window names (`0x0048B0F0`);
/// the players' names over their ships in a multiplayer game.
pub fn drawTarget(
    state: *State,
    art: *Art,
    fonts: *TargetFonts,
    gpa: Allocator,
    target: device.Device,
    scene: TargetScene,
    edge_line: EdgeLine,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!?[2]i32 {
    state.chase_pointer = null;
    state.chase_nav_roll = null;
    const all = scene.all;
    const sight = scene.sight;
    const ship = &all.slots[all.player];
    if (ship.object.nav_point.index()) |nav| if (nav < all.slots.len) {
        const way = pointerDirection(ship.drawn, all.slots[nav].drawn.position);
        if (scene.mode == .chase) {
            state.chase_nav_roll = chase.Pointer.rollToward(way);
        } else {
            drawArrow(target, sight, way, art.paletteColour(nav_colour), scale);
        }
    };
    const index = state.target orelse return null;
    const struck = &all.slots[index];
    const hostile = struck.object.side == .hostile;
    var buffer: [16]u8 = undefined;
    const range = rangeText(&buffer, kilometres(all, index));

    const part = ai.targetPart(all, state.shown);
    const node: math.Place = if (part) |found| found.drawn() else struck.drawn;
    const seen = sight.view(node.position);
    if (!sight.onScreen(sight.pixel(seen)) or seen[2] < 0) {
        const way = pointerDirection(ship.drawn, node.position);
        if (scene.mode == .chase) state.chase_pointer = .toward(way, hostile);
        try drawOffScreen(art, &fonts.small, gpa, target, sight, way, hostile, range, scene.mode, edge_line, colour, scale);
        return null;
    }
    if (!(seen[2] > 0)) return null;

    // The node's box, the component's for a subtarget, as the camera sees it.
    const box = if (part) |found| partBox(found) else [2]Vector{ gameobj.vector(struck.object.bounds_min), gameobj.vector(struck.object.bounds_max) };
    var low: Point = @splat(box_seed);
    var high: Point = @splat(-box_seed);
    for (0..8) |n| {
        const on: Point = sight.projection.project(sight.view(node.point(math.Corner.of(n).in(box))));
        low = @min(low, on);
        high = @max(high, on);
    }
    high = @max(high, low + @as(Point, @splat(least_brackets * scale)));

    // The brackets dim as a missile's lock builds, and go at a tenth.
    const brightness = @min(@as(f32, @floatFromInt(state.lock.count)) * lock_dimming, 1);
    if (brightness > least_bright) {
        const dim: [4]f32 = .{ colour[0] * brightness, colour[1] * brightness, colour[2] * brightness, colour[3] };
        const first = brackets_shape.of(hostile);
        const ends = [2]Point{ low, high };
        for (0..4) |n| {
            const corner: math.Corner = .of(n);
            const at: [2]i32 = .{ round(ends[corner.x][0]), round(ends[corner.y][1]) };
            try drawShape(art, gpa, target, first + n, at, dim, scale);
        }
    }
    const offset = pointOf(range_offset) * @as(Point, @splat(scale));
    _ = try drawText(&fonts.new, gpa, target, .{ round(high[0]) + round(offset[0]), round(high[1] + offset[1]) }, range, colour, .right, scale);

    if (struck.object.flags.components or struck.object.side == .friendly) return null;
    const lead = ai.leadAim(all, all.player, state.shown, 1) orelse return null;
    state.lead_point = lead;
    const aim: Point = sight.projection.project(sight.view(lead));
    const cursor: [2]i32 = .{ round(aim[0]), round(aim[1]) };
    try drawShape(art, gpa, target, lead_shape, cursor, colour, scale);
    const toward: Point = sight.projection.project(sight.view(struck.drawn.position));
    if (leadLine(aim, toward, state.lock.count, scale)) |line| {
        drawLine(target, whole(line[0]), whole(line[1]), art.paletteColour(line_colour.hostile), scale);
    }
    return cursor;
}

/// The box of the mesh a part draws at its level: none, at its origin, for a part with no mesh,
/// which the game never has a subtarget of.
fn partBox(part: *const objects.Model.Part) [2]Vector {
    const levels = part.object.levels;
    if (part.object.level >= levels.len) return .{ @splat(0), @splat(0) };
    return levels[part.object.level].mesh.bounds;
}

/// What `drawTarget` seeds the target's box on the screen with, its low corner at this across and
/// down and its high one at as much less (numbers in its code).
const box_seed: f32 = 100_000;

/// How much of their brightness the brackets keep for each unit of the missile lock's count, which
/// makes them whole at `missile_lock.idle_count` (`0x004DC730`), and the least they are drawn at
/// (`0x004DC420`).
const lock_dimming: f32 = 0.01;
const least_bright: f32 = 0.1;

comptime {
    assert(lock_dimming == 1.0 / @as(f32, missile_lock.idle_count));
}

/// The lead cursor's line: from `lead_gap` out of the cursor at `aim`, along the axis on which
/// the target at `toward` lies farther, to the target, shorter by `lock_shortening` for each unit
/// the lock's count is short of 100. None for a target within the gap on that axis, or a line
/// shortened away.
pub fn leadLine(aim: Point, toward: Point, lock: i32, scale: f32) ?[2]Point {
    const gap = lead_gap * scale;
    const at: [2]f32 = aim;
    const to: [2]f32 = toward;
    const apart: [2]f32 = aim - toward;
    const major: usize = if (@abs(apart[1]) <= @abs(apart[0])) 0 else 1;
    const minor = 1 - major;
    var start: [2]f32 = undefined;
    if (to[major] > at[major] + gap) {
        start[major] = at[major] + gap;
    } else if (to[major] < at[major] - gap) {
        start[major] = at[major] - gap;
    } else return null;
    start[minor] = (start[major] - to[major]) * apart[minor] / apart[major] + to[minor];
    const from: Point = start;
    const length = distance(from, toward);
    const shortening = @as(f32, @floatFromInt(missile_lock.idle_count - lock)) * lock_shortening * scale;
    if (!(shortening < length)) return null;
    return .{ from, from + (toward - from) * @as(Point, @splat((length - shortening) / length)) };
}

/// The arrow from the middle of the screen toward what lies `toward` from the player's ship: its tip
/// `arrow_tip` out, and its wings `arrow_wing` either side of a point `arrow_back` nearer.
const Arrow = struct {
    tip: [2]i32,
    wings: [2][2]i32,

    fn toward(sight: Sight, way: [2]f32, scale: f32) Arrow {
        const middle = sight.middle();
        const across: [2]f32 = .{ -way[1], way[0] };
        var arrow: Arrow = undefined;
        for (0..2) |axis| {
            const out = round(way[axis] * arrow_tip * scale);
            const base = out - round(way[axis] * arrow_back * scale);
            const wing = round(across[axis] * arrow_wing * scale);
            arrow.tip[axis] = middle[axis] + out;
            arrow.wings[0][axis] = middle[axis] + base + wing;
            arrow.wings[1][axis] = middle[axis] + base - wing;
        }
        return arrow;
    }
};

/// Draws the arrow `toward` in `colour`: from its tip to each wing, and across the wings.
fn drawArrow(target: device.Device, sight: Sight, toward: [2]f32, colour: [4]f32, scale: f32) void {
    const arrow: Arrow = .toward(sight, toward, scale);
    const tip = arrow.tip;
    const wings = arrow.wings;
    for ([3][2][2]i32{ .{ tip, wings[0] }, .{ tip, wings[1] }, .{ wings[1], wings[0] } }) |ends| {
        drawLine(target, pointOf(ends[0]), pointOf(ends[1]), colour, scale);
    }
}

/// The arrow and the marker at the screen's edge for a target out of sight, which lies `toward`
/// from the player's ship. The chase view draws no arrow.
fn drawOffScreen(
    art: *Art,
    font: *Opened,
    gpa: Allocator,
    target: device.Device,
    sight: Sight,
    toward: [2]f32,
    hostile: bool,
    range: []const u8,
    mode: camera.CockpitMode,
    edge_line: EdgeLine,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!void {
    if (mode != .chase) drawArrow(target, sight, toward, art.paletteColour(line_colour.of(hostile)), scale);

    const arrow: Arrow = .toward(sight, toward, scale);
    const last = sight.last();
    var from: [2]i32 = switch (edge_line) {
        .from_tip => arrow.tip,
        .original => .{ arrow.tip[0], arrow.wings[0][0] },
    };
    var to: [2]i32 = undefined;
    for (&to, sight.middle(), last, toward) |*c, m, most, way| c.* = m + round(@as(f32, @floatFromInt(most)) * way);
    _ = xtrabits.clipLine(last, &from, &to);
    const edge: Edge = .of(to, last);
    const spec = edge.spec();
    try drawShape(art, gpa, target, Edge.shape.of(hostile) + @intFromEnum(edge), scaled(to, spec.shape, scale), colour, scale);
    _ = try drawText(font, gpa, target, scaled(to, spec.text, scale), range, colour, spec.alignment, scale);
}

/// The radar (`hud_radar`, `0x00488BD0`): its rings, the shape `hud_init` starts on and the
/// range key steps through, stand from a point placed half of the way across, at the foot of the
/// screen, 1 right and 51 up, with a contact for each object in range (`Contacts`). Not yet
/// ported: the contact for the object the radio's window names (line `0xFD`, shape `0xE6`,
/// [#99](https://github.com/vdmkenny/openreliant/issues/99)).
pub const Radar = struct {
    pub const offset: [2]i32 = .{ 1, -51 };
    pub const across: f32 = 0.5;
    pub const down: f32 = 1;
    /// Where the rings hang from the point.
    pub const rings_offset: [2]i32 = .{ -0x42, -0x20 };
    /// The rings `hud_init` starts on (`0x0057BC50`), the widest range's.
    pub const first_rings: u16 = 0x16B;
    /// The range `hud_init` starts on (`radar_range`, `0x0057BE00`), the widest.
    pub const first_range: u2 = 2;
    /// The rings each range comes to rest on, 0 the closest: one ring with the wedge of the view
    /// ahead, two, and three. The shapes between are the steps between them.
    pub const range_rings = [3]u16{ 0x161, 0x166, 0x16B };
    /// The ticks `hud_radar_zoom` keeps its next step ahead of `game_ticks`.
    pub const zoom_ticks: u32 = 50;

    /// How far each range reaches (`0x00501CA8`), and the share of a unit of the world a display
    /// pixel stands for at it (`0x00501CB8`), 0 the closest. The ranges' scales run wider than
    /// their reach.
    pub const Range = struct { reach: f32, per_unit: f32 };
    pub const ranges = [3]Range{
        .{ .reach = 90_000, .per_unit = 1.0 / 150_000.0 },
        .{ .reach = 150_000, .per_unit = 1.0 / 230_000.0 },
        .{ .reach = 230_000, .per_unit = 1.0 / 330_000.0 },
    };
    /// What the scale is multiplied by across, for the height and ahead, in the order of the
    /// ship's frame's axes (`0x004DC924`, `0x004DC584`, `0x004DC920`).
    pub const spread: Vector = .{ 66, 30, 43 };

    /// What the radar shows an object as: its line's palette entry and the shape at its dot, for
    /// the player's target (`0xFF`, `0x130`), a hostile ship (`0x26`, `0xE5`) and the rest
    /// (`0x62`, `0xE4`); or, for the display's nav point, a cross of four pixels.
    pub const Look = enum {
        other,
        hostile,
        target,
        nav_point,

        pub fn line(look: Look) u8 {
            return switch (look) {
                .target => 0xFF,
                .hostile => 0x26,
                .other, .nav_point => 0x62,
            };
        }

        pub fn shape(look: Look) u16 {
            return switch (look) {
                .target => 0x130,
                .hostile => 0xE5,
                .other, .nav_point => 0xE4,
            };
        }
    };

    /// An object on the radar: where its dot stands from the radar's point, in the display's own
    /// pixels, across and up the screen as far as it lies ahead, and lowered by its height; how far
    /// it stands below the rings' plane, which its line runs up to it from the dot, or down from
    /// the dot for one above it; and how it shows.
    pub const Contact = struct {
        at: [2]i32,
        height: i32,
        look: Look,

        /// Which side of the rings' plane `hud_radar` draws it on: level with the plane or below
        /// it, before the rings; above it, after them. OpenReliant draws the nav point after them;
        /// the game, before or after them by whatever an earlier frame left in its entry of the
        /// list.
        pub fn plane(contact: Contact) Plane {
            return if (contact.look == .nav_point or contact.height < 0) .above else .below;
        }
    };

    /// The two sides of the rings' plane.
    pub const Plane = enum { below, above };

    /// The objects `hud_radar` shows, in their slots' order: the display's nav point, and every
    /// object but the display's own ship that is targetable and neither exploding, disabled,
    /// ejected nor a cloaked hostile; each within the range's reach of the display's ship.
    pub const Contacts = struct {
        all: *const create.Objects,
        reach: f32,
        /// The range's scale times `spread`, which `hud_radar` works out once.
        factors: Vector,
        at: usize = 0,

        pub fn of(all: *const create.Objects, range: u2) Contacts {
            const chosen = ranges[range];
            return .{ .all = all, .reach = chosen.reach, .factors = @as(Vector, @splat(chosen.per_unit)) * spread };
        }

        pub fn next(it: *Contacts) ?Contact {
            const all = it.all;
            const own = &all.slots[all.player];
            while (it.at < all.count) {
                const index = it.at;
                it.at += 1;
                const slot = &all.slots[index];
                const nav_point = own.object.nav_point == gameobj.Slot.of(@intCast(index));
                if (!nav_point and !shown(all, index)) continue;
                const apart = slot.drawn.position - own.drawn.position;
                if (!(math.length(apart) < it.reach)) continue;
                const placed = own.drawn.inverse(slot.drawn.position) * it.factors;
                const height = round(placed[1]);
                const at: [2]i32 = .{ round(placed[0]), round(-placed[2]) + height };
                const look: Look = if (nav_point)
                    .nav_point
                else if (index == own.orders[0].target.index)
                    .target
                else if (slot.object.side == .hostile)
                    .hostile
                else
                    .other;
                return .{ .at = at, .height = height, .look = look };
            }
            return null;
        }

        fn shown(all: *const create.Objects, index: usize) bool {
            if (index == all.player) return false;
            const flags = all.slots[index].object.flags;
            if (!flags.targetable or flags.exploding or flags.disabled or flags.ejected) return false;
            return !(flags.cloaked and all.slots[index].object.side == .hostile);
        }
    };

    /// The rings moving to a new range's: the shape they stop at (`radar_zoom_rings`,
    /// `0x005799B4`), whether they step down toward it (`radar_zoom_down`, `0x005656AC`), and the
    /// tick the step waits to be short of (`radar_zoom_next`, `0x005656A0`). `radar_zooming`
    /// (`0x00569714`) is set while they move.
    pub const Zoom = struct {
        to: u16,
        down: bool,
        next: u32,
    };
};

/// RADAR RANGES (`frame_controls`, `0x00414060`): in the view ahead from the cockpit, with the
/// rings still, the radar moves to its next range, round from the widest to the closest, and its
/// rings start moving to that range's. Returns whether it moved.
pub fn nextRadarRange(state: *State, view: camera.View, game_ticks: u32) bool {
    if (view != .cockpit or state.radar_zoom != null) return false;
    state.radar_range = if (state.radar_range >= Radar.ranges.len - 1) 0 else state.radar_range + 1;
    state.radar_zoom = .{
        .to = Radar.range_rings[state.radar_range],
        .down = state.radar_range == 0,
        .next = game_ticks + Radar.zoom_ticks,
    };
    return true;
}

/// `hud_radar_zoom` (`0x004892F0`), which `hud_draw` runs after the radar: while the rings are
/// moving, a step toward the range's. It steps while `game_ticks` is short of the tick it keeps
/// `zoom_ticks` ahead, and puts that tick ahead again as it steps, so the rings step once each
/// frame the radar is drawn.
pub fn stepRadarZoom(state: *State, game_ticks: u32) void {
    const zoom = &(state.radar_zoom orelse return);
    if (@as(i32, @bitCast(zoom.next)) <= @as(i32, @bitCast(game_ticks))) return;
    zoom.next = game_ticks +% Radar.zoom_ticks;
    if (zoom.down) state.radar_rings -= 1 else state.radar_rings += 1;
    if (state.radar_rings == zoom.to) state.radar_zoom = null;
}

/// Draws the radar's rings for a window of `screen`.
pub fn drawRadar(
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    state: *const State,
    all: *const create.Objects,
    colour: [4]f32,
    scale: f32,
    shake: ?Shake,
) (spr.Error || Allocator.Error)!void {
    const point = place(screen, Radar.offset, Radar.across, Radar.down, scale);
    try drawContacts(art, gpa, target, screen, point, all, state.radar_range, .below, colour, scale);
    try drawShapeWith(art, gpa, target, state.radar_rings, scaled(point, Radar.rings_offset, scale), colour, scale, .{ .shake = shake });
    try drawContacts(art, gpa, target, screen, point, all, state.radar_range, .above, colour, scale);
}

/// The contacts on one side of the rings' plane (`Radar.Contact.plane`): each line a pixel right
/// of the dot, from the dot to the plane, and the dot's shape 2 right of it, the dot kept off the
/// screen's last row; the nav point a cross of four pixels round its dot in the display's white.
fn drawContacts(
    art: *Art,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    point: [2]i32,
    all: *const create.Objects,
    range: u2,
    plane: Radar.Plane,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!void {
    const bottom = @as(i32, @intCast(screen[1])) - 2;
    var contacts: Radar.Contacts = .of(all, range);
    while (contacts.next()) |contact| {
        if (contact.plane() != plane) continue;
        var dot = scaled(point, contact.at, scale);
        dot[1] = std.math.clamp(dot[1], 0, bottom);
        if (contact.look == .nav_point) {
            const white: [4]f32 = .{ 1, 1, 1, colour[3] };
            for ([4][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ -1, 0 }, .{ 1, 0 } }) |by| {
                const pixel = pointOf(scaled(dot, by, scale));
                drawLine(target, pixel, pixel, white, scale);
            }
            continue;
        }
        if (contact.height != 0) {
            // The line's far end, a pixel short of the plane.
            const toward: i32 = if (contact.height > 0) -1 else 1;
            const reach = -contact.height - toward;
            const column = scaled(dot, .{ 1, 0 }, scale);
            drawLine(target, pointOf(column), pointOf(scaled(column, .{ 0, reach }, scale)), art.paletteColour(contact.look.line()), scale);
        }
        try drawShape(art, gpa, target, contact.look.shape(), scaled(dot, .{ 2, 0 }, scale), colour, scale);
    }
}

test leadLine {
    // From five pixels out of the cursor, along the axis the target lies farther on, to the
    // target.
    const line = leadLine(.{ 100, 100 }, .{ 200, 150 }, missile_lock.idle_count, 1).?;
    try std.testing.expectEqual(Point{ 105, 102.5 }, line[0]);
    try std.testing.expectEqual(Point{ 200, 150 }, line[1]);
    // Farther down than across, it leaves by the top or the bottom.
    const steep = leadLine(.{ 100, 100 }, .{ 110, 0 }, missile_lock.idle_count, 1).?;
    try std.testing.expectEqual(95, steep[0][1]);
    // Within the gap there is none.
    try std.testing.expectEqual(null, leadLine(.{ 100, 100 }, .{ 103, 101 }, missile_lock.idle_count, 1));
    // A lock building shortens it at the target's end, to nothing.
    const shortened = leadLine(.{ 100, 100 }, .{ 200, 100 }, 50, 1).?;
    try std.testing.expectApproxEqAbs(200 - 50 * lock_shortening, shortened[1][0], 1e-3);
    try std.testing.expectEqual(null, leadLine(.{ 100, 100 }, .{ 110, 100 }, 0, 1));
}

test Edge {
    const last: [2]i32 = .{ 639, 479 };
    try std.testing.expectEqual(Edge.top, Edge.of(.{ 0, 0 }, last));
    try std.testing.expectEqual(Edge.bottom, Edge.of(.{ 300, 479 }, last));
    try std.testing.expectEqual(Edge.left, Edge.of(.{ 0, 200 }, last));
    try std.testing.expectEqual(Edge.right, Edge.of(.{ 639, 200 }, last));
    // Each edge's shape stands inside the screen from where the line meets it.
    try std.testing.expect(Edge.top.spec().shape[1] > 0 and Edge.bottom.spec().shape[1] < 0);
    try std.testing.expect(Edge.left.spec().shape[0] > 0 and Edge.right.spec().shape[0] < 0);
}

test pointerDirection {
    // A target to the right and below the nose, in the ship's own frame, however it is turned.
    const turned: math.Place = .{ .orientation = math.rotation(.z, std.math.pi / 2.0) };
    const way = pointerDirection(turned, math.transform(turned.orientation, .{ 3, 4, -10 }));
    try std.testing.expectApproxEqAbs(0.6, way[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.8, way[1], 1e-6);
    // Straight behind, it points down.
    try std.testing.expectEqual([2]f32{ 0, 1 }, pointerDirection(.{}, .{ 0, 0, -10 }));
}

/// What `drawTarget`'s tests draw with: no shapes, a font, and a device that keeps what it draws.
const TargetDrawing = struct {
    recorder: device.testing.Recorder,
    art: Art,
    fonts: TargetFonts,

    fn init(drawing: *TargetDrawing, gpa: Allocator) !void {
        const empty = comptime std.mem.toBytes(spr.Header{ .version = spr.magic.*, .shape_count = 0 });
        const font = try fnt.Font.parse(comptime fnt.testing.font(true));
        drawing.* = .{
            .recorder = .{ .gpa = gpa },
            .art = try .init(gpa, try .parse(&empty), null),
            .fonts = .{ .small = .open(font, null), .new = .open(font, null) },
        };
    }

    fn deinit(drawing: *TargetDrawing, gpa: Allocator) void {
        drawing.recorder.deinit();
        drawing.art.deinit(gpa);
        drawing.fonts.small.deinit(gpa);
        drawing.fonts.new.deinit(gpa);
    }

    /// Draws `state`'s target in `scene`, and says where the lead cursor stands.
    fn draw(drawing: *TargetDrawing, gpa: Allocator, state: *State, scene: TargetScene) !?[2]i32 {
        return drawTarget(state, &drawing.art, &drawing.fonts, gpa, drawing.recorder.interface(), scene, .from_tip, .{ 1, 1, 1, 1 }, 1);
    }

    /// How many lines it has drawn, which are what it draws untextured.
    fn lines(drawing: *const TargetDrawing) usize {
        var count: usize = 0;
        for (drawing.recorder.draws.items) |made| count += @intFromBool(made.state.texture == null);
        return count;
    }
};

test "a target out of sight gets an arrow and a marker" {
    var t: TargetingTest = undefined;
    try t.init();
    defer t.deinit();
    const all = t.mission.objects;
    const behind = try t.add(.sabre, .{ 0, 0, -5000 });
    input.setPlayerTarget(&t.state, all, @intCast(behind), -1, false);
    const gpa = std.testing.allocator;
    var drawing: TargetDrawing = undefined;
    try drawing.init(gpa);
    defer drawing.deinit(gpa);

    // From the cockpit, three lines of the arrow, and no lead cursor.
    const scene: TargetScene = .{ .sight = testSight(), .all = all, .mode = .cockpit };
    try std.testing.expectEqual(null, try drawing.draw(gpa, &t.state, scene));
    try std.testing.expectEqual(3, drawing.lines());
    // The chase view draws none.
    drawing.recorder.clear();
    var from_behind = scene;
    from_behind.mode = .chase;
    _ = try drawing.draw(gpa, &t.state, from_behind);
    try std.testing.expectEqual(0, drawing.lines());
}

test "a hostile target ahead gets the lead cursor, whose point blind fire aims at" {
    var t: TargetingTest = undefined;
    try t.init();
    defer t.deinit();
    const all = t.mission.objects;
    // The player's guns lead a target up to 100 ticks of flight away.
    const laser = &all.gun_stats.types[guns.GunType.laser_cannon.number()];
    laser.speed = 100;
    laser.lifetime = 400;
    const ahead = try t.add(.sabre, .{ 0, 0, 5000 });
    all.slots[ahead].object.side = .hostile;
    all.slots[ahead].object.speed = 20;
    input.setPlayerTarget(&t.state, all, @intCast(ahead), -1, false);
    const gpa = std.testing.allocator;
    var drawing: TargetDrawing = undefined;
    try drawing.init(gpa);
    defer drawing.deinit(gpa);

    const scene: TargetScene = .{ .sight = testSight(), .all = all, .mode = .cockpit };
    try std.testing.expect(try drawing.draw(gpa, &t.state, scene) != null);
    try std.testing.expectEqual(ai.leadAim(all, all.player, t.state.shown, 1).?, t.state.lead_point);
}

test "the radar's contacts" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.predator, @splat(0));
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .player_control, .none));
    // Ahead and a little below, the target; to the right and above, a hostile ship; a friend;
    // and a hostile ship out of reach of the widest range.
    const target = try mission.add(.sabre, .{ 0, 11000, 99000 });
    const hostile = try mission.add(.sabre, .{ 33000, -22000, 0 });
    const friend = try mission.add(.predator, .{ 0, 0, -66000 });
    _ = try mission.add(.sabre, .{ 0, 0, 300000 });
    for ([_]u16{ target, hostile, friend, 4 }) |index| mission.slot(index).object.flags.targetable = true;
    mission.slot(player).orders[0].target = .{ .kind = .ship, .index = @intCast(target), .component = -1 };

    var contacts: Radar.Contacts = .of(all, 2);
    const ahead = contacts.next().?;
    try std.testing.expectEqual(Radar.Look.target, ahead.look);
    // Ahead is up the screen: 99000 over 330000 of 43 pixels, lowered by its height, 1 below.
    try std.testing.expectEqual(1, ahead.height);
    try std.testing.expectEqual([2]i32{ 0, -13 + 1 }, ahead.at);
    const right = contacts.next().?;
    try std.testing.expectEqual(Radar.Look.hostile, right.look);
    try std.testing.expectEqual(-2, right.height);
    try std.testing.expectEqual(7, right.at[0]);
    const behind = contacts.next().?;
    try std.testing.expectEqual(Radar.Look.other, behind.look);
    try std.testing.expectEqual(9, behind.at[1]);
    try std.testing.expectEqual(null, contacts.next());

    // The closest range reaches less far, past the target, and draws closer at its own scale.
    contacts = .of(all, 0);
    try std.testing.expectEqual(Radar.Contact{ .at = .{ 15, -4 }, .height = -4, .look = .hostile }, contacts.next().?);
    try std.testing.expectEqual(Radar.Look.other, contacts.next().?.look);
    try std.testing.expectEqual(null, contacts.next());
    // A cloaked hostile, or anything exploding, is not shown.
    mission.slot(target).object.flags.cloaked = true;
    mission.slot(friend).object.flags.exploding = true;
    contacts = .of(all, 2);
    try std.testing.expectEqual(Radar.Look.hostile, contacts.next().?.look);
    try std.testing.expectEqual(null, contacts.next());
}

test nextRadarRange {
    var state: State = .{};
    // From the widest range the key comes round to the closest, whose rings are one; the rings
    // step there a shape a frame.
    try std.testing.expect(nextRadarRange(&state, .cockpit, 1000));
    try std.testing.expectEqual(0, state.radar_range);
    for (0..9) |_| stepRadarZoom(&state, 1000);
    try std.testing.expectEqual(0x162, state.radar_rings);
    // While they move, the key does nothing.
    try std.testing.expect(!nextRadarRange(&state, .cockpit, 1000));
    try std.testing.expectEqual(0, state.radar_range);
    stepRadarZoom(&state, 1000);
    try std.testing.expectEqual(0x161, state.radar_rings);
    try std.testing.expectEqual(null, state.radar_zoom);
    // The next range steps up to two rings; outside the view ahead the key does nothing.
    try std.testing.expect(!nextRadarRange(&state, .cockpit_rear, 1000));
    try std.testing.expectEqual(0, state.radar_range);
    try std.testing.expect(nextRadarRange(&state, .cockpit, 1000));
    for (0..5) |_| stepRadarZoom(&state, 1000);
    try std.testing.expectEqual(0x166, state.radar_rings);
    try std.testing.expectEqual(null, state.radar_zoom);
}

test Cluster {
    // At nothing a marker rides the foot of the left arc, left of the circle's centre and below
    // it; at full it rides near the top.
    const empty = Cluster.markerOffset(0);
    try std.testing.expect(empty[0] < 0 and empty[1] > 0);
    const full = Cluster.markerOffset(1);
    try std.testing.expect(full[0] < 0 and full[1] < 0);
    try std.testing.expectEqual([2]i32{ -95, 60 }, empty);
    // Full guns light the whole charge arc; none light nothing of it.
    try std.testing.expectEqual(0, Cluster.chargeLevel(50, 50));
    try std.testing.expectEqual(0x8A, Cluster.chargeLevel(0, 50));
    try std.testing.expectEqual(0x8A / 2, Cluster.chargeLevel(25, 50));
    try std.testing.expectEqual(0x8A, Cluster.chargeLevel(10, 0));
    // The throttle counts by its size, the speed by its share of the top speed, each to 1.
    try std.testing.expectEqual([2]f32{ 1, 0.5 }, Cluster.shares(.{ .throttle = -1.5, .speed = 50, .max_speed = 100, .charge = 0, .full_charge = 0 }));
    try std.testing.expectEqual([2]f32{ 0.25, 1 }, Cluster.shares(.{ .throttle = 0.25, .speed = 300, .max_speed = 100, .charge = 0, .full_charge = 0 }));
}

test "the arcs part as the screen widens" {
    // At 640 across the arcs stand 100 either side of the middle; at 1024, 160; at 1366, 213,
    // the fraction cut off.
    try std.testing.expectEqual(100, Cluster.apart(640));
    try std.testing.expectEqual(160, Cluster.apart(1024));
    try std.testing.expectEqual(213, Cluster.apart(1366));
}

test "the sight glides back to the middle" {
    var state: State = .{ .sight = .{ 300, 250 } };
    const screen: [2]u32 = .{ 640, 480 };
    // With a target off the reach of blind fire, the sight moves a pixel a tick toward the
    // middle, and rests within two of it.
    var recorder: device.testing.Recorder = .{ .gpa = std.testing.allocator };
    defer recorder.deinit();
    const target = recorder.interface();
    var art: Art = .{ .set = undefined, .images = &.{} };
    const aims = try drawReticle(&state, &art, std.testing.allocator, target, screen, .chase, .{ 600, 400 }, .on, 10, .{ 1, 1, 1, 1 }, 1, null);
    try std.testing.expect(!aims);
    try std.testing.expectEqual([2]i32{ 310, 240 }, state.sight.?);
    // Within its reach, blind fire takes the target.
    try std.testing.expect(try drawReticle(&state, &art, std.testing.allocator, target, screen, .chase, .{ 350, 260 }, .on, 10, .{ 1, 1, 1, 1 }, 1, null));
    try std.testing.expectEqual([2]i32{ 350, 260 }, state.sight.?);
    // A gun it does not aim leaves the sight where it is.
    _ = try drawReticle(&state, &art, std.testing.allocator, target, screen, .chase, .{ 350, 260 }, .excluded, 10, .{ 1, 1, 1, 1 }, 1, null);
    try std.testing.expectEqual([2]i32{ 350, 260 }, state.sight.?);
}

/// A sound player of `voices` voices, with `stdsmp` of `count` sounds.
const TestSound = struct {
    mixer: @import("../mss.zig").Mixer,
    sound: hog_snd.Sound,

    fn init(test_sound: *TestSound, voices: u8, stdsmp: []const u8) !void {
        test_sound.mixer = .init(22050);
        test_sound.sound.init(test_sound.mixer.driver(), voices, null);
        test_sound.sound.stdsmp = try @import("../../formats/fat.zig").Bank.parse(stdsmp);
    }

    fn playing(test_sound: *TestSound) bool {
        for (0..test_sound.sound.voice_count) |v| {
            if (test_sound.sound.voicePlaying(@intCast(v))) return true;
        }
        return false;
    }
};

test Beeps {
    var heard: TestSound = undefined;
    const bank = comptime hog_snd.testing.bank(Beep.first_sample + std.enums.values(Beep).len);
    try heard.init(4, &bank);
    var beeps: Beeps = .{};

    // Outside the cockpit's views nothing is heard, and the sounds asked for are let go.
    beeps.add(.opens);
    beeps.play(&heard.sound, .chase);
    try std.testing.expect(!heard.playing());
    try std.testing.expectEqual(0, beeps.slice().len);
    // From the cockpit they are.
    beeps.add(.opens);
    beeps.play(&heard.sound, .cockpit_left);
    try std.testing.expect(heard.playing());

    // Past as many as a frame asks for, a sound is left out.
    for (0..Beeps.capacity + 1) |_| beeps.add(.done);
    try std.testing.expectEqual(Beeps.capacity, beeps.slice().len);
}

test "the enemy lock's warning" {
    var heard: TestSound = undefined;
    const bank = comptime hog_snd.testing.bank(1);
    try heard.init(2, &bank);
    const sound = &heard.sound;
    var state: State = .{};

    // With the light, the warning plays on its voice.
    state.warnOfLock(sound, true, false);
    try std.testing.expect(sound.voicePlaying(lock_warning_voice));
    try std.testing.expectEqual(lock_warning_voice, state.lock_warning.?);
    // A missile homing keeps it going as the light goes out; without one it ends.
    state.warnOfLock(sound, false, true);
    try std.testing.expect(sound.voicePlaying(lock_warning_voice));
    state.warnOfLock(sound, false, false);
    try std.testing.expect(!sound.voicePlaying(lock_warning_voice));
    try std.testing.expectEqual(null, state.lock_warning);
}

test Interference {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const world = mission.world();
    var interference: Interference = .{};

    // Still, the display doesn't shake; a hit shakes it.
    try std.testing.expectEqual(null, interference.shake(1, &mission.random));
    mission.clock.frame_start = 100;
    interference.start(world);
    try std.testing.expectEqual(Interference.hit_level, interference.level);
    try std.testing.expect(interference.shake(1, &mission.random) != null);
    // It fades by `fade_per_tick` a tick since it last faded, to nothing.
    interference.faded_at = 100;
    interference.fade(120);
    try std.testing.expectApproxEqAbs(Interference.hit_level - 20 * Interference.fade_per_tick, interference.level, 1e-6);
    interference.fade(1000);
    try std.testing.expectEqual(0, interference.level);
}

test rowShift {
    var random: libcmt.Rand = .{};
    try std.testing.expectEqual(0, rowShift(0, &random));
    try std.testing.expectEqual(0, rowShift(1, null));
    for (0..20) |_| {
        const shift = rowShift(2, &random);
        try std.testing.expect(shift >= 0 and shift <= 2 * row_reach);
    }
}

test "a shaken image is drawn a row at a time" {
    var recorder: device.testing.Recorder = .{ .gpa = std.testing.allocator };
    defer recorder.deinit();
    const into = recorder.interface();
    const texels = [_]u8{0xFF} ** (2 * 3 * 4);
    var level = [_]srtexture.Level{.{ .width = 2, .height = 3, .rgba = &texels }};
    var image: srtexture.Image = .{ .levels = &level };
    var random: libcmt.Rand = .{};

    drawImage(into, &image, .{ 0, 0 }, .{ 1, 1, 1, 1 }, 1, .{});
    try std.testing.expectEqual(1, recorder.draws.items.len);
    const shake: Shake = .{ .hit_shake = 1, .interference = 0.3, .random = &random };
    drawImage(into, &image, .{ 0, 0 }, .{ 1, 1, 1, 1 }, 1, .{ .shake = shake });
    try std.testing.expectEqual(1 + 3, recorder.draws.items.len);
}

test "an image cut to a clip keeps the part of it inside" {
    var recorder: device.testing.Recorder = .{ .gpa = std.testing.allocator };
    defer recorder.deinit();
    const into = recorder.interface();
    const texels = [_]u8{0xFF} ** (4 * 2 * 4);
    var level = [_]srtexture.Level{.{ .width = 4, .height = 2, .rgba = &texels }};
    var image: srtexture.Image = .{ .levels = &level };

    // Its right half cut away: the texture's right edge moves to its middle.
    drawImage(into, &image, .{ 10, 20 }, .{ 1, 1, 1, 1 }, 1, .{ .clip = .{ .left = 0, .top = 0, .right = 12, .bottom = 100 } });
    const corners = recorder.last();
    try std.testing.expectEqual(12, corners[1].x);
    try std.testing.expectEqual(0.5, corners[1].u);
    try std.testing.expectEqual(1, corners[2].v);
    // Wholly outside, nothing is drawn.
    recorder.clear();
    drawImage(into, &image, .{ 10, 20 }, .{ 1, 1, 1, 1 }, 1, .{ .clip = .{ .left = 50, .top = 0, .right = 60, .bottom = 100 } });
    try std.testing.expectEqual(0, recorder.draws.items.len);
}
