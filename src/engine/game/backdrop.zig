//! The space backdrop: the star fields, the dust, the sun and its flares, and the lights every
//! mission starts with. `backdrop_create` (`0x004A4E70`) builds them once, `backdrop_place`
//! (`0x004A5A00`) aims them from a mission's markers and `backdrop_frame` (`0x004A5CD0`) adds them
//! to the scene each frame. The binary does not name the file; its code lies between
//! `srofiles.cpp`'s and `timer.cpp`'s. [`nebula.zig`](nebula.zig) has the sky dome and the nebula.
//!
//! OpenReliant builds the hardware renderers' backdrop. **Unknown:** what sets bit 2 of
//! `sr + 0x38`, with which `backdrop_create` has the star fields blend by `add_alpha` instead of
//! adding; OpenReliant leaves it clear. Not yet ported: `backdrop_place`, which needs the mission's
//! markers, and the objects `backdrop_frame` turns and makes glow at the end.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tga = @import("../../formats/tga.zig");
const libcmt = @import("../libcmt.zig");
const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srstars = @import("../surrender/surrenderlib/srstars.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const camera = @import("camera.zig");
const matmanager = @import("matmanager.zig");
const xtrabits = @import("xtrabits.zig");
const Vector = math.Vector;

pub const rings = @import("backdrop/rings.zig");

/// The star map, in `resource.hog`: grey pixels on black, one star each.
pub const star_map_name = "space.tga";

/// The star map's side, in pixels. It spans half the sky, half a degree to a pixel.
pub const star_map_size = 360;

/// Radians to a star-map pixel, and to a unit of the field angles below: half a degree.
pub const half_degree: f32 = std.math.pi / 360.0;

/// A field is a 36-pixel square of the map, 18 degrees across.
pub const field_size = 36;
pub const fields_per_side = star_map_size / field_size;
pub const field_count = fields_per_side * fields_per_side;

/// Field `row`, `column`'s axis: the polar angle, from `+Y`, follows the map's rows and the
/// azimuth, from `+X` toward `+Z`, its columns, so the fields cover the half of the sky where `z`
/// is positive.
pub fn fieldAxis(row: usize, column: usize) [3]f32 {
    const polar = @as(f32, @floatFromInt(row * field_size + field_size / 2)) * half_degree;
    const azimuth = @as(f32, @floatFromInt(column * field_size + field_size / 2)) * half_degree;
    return .{ @cos(azimuth) * @sin(polar), @cos(polar), @sin(azimuth) * @sin(polar) };
}

/// The dust: motes in a cube around the camera, grey at half brightness, placed at random
/// (`backdrop_create`: `0x004A51BC`, `0x004A51DF` and `0x004A51E9`).
pub const dust_count = 200;
pub const dust_cube_mask = 0x1FFF;
pub const dust_grey: f32 = 0.5;

/// Toward the sun, where no marker says otherwise: the key lights' direction.
pub const sun_direction: Vector = math.normalize(.{ 1, -0.5, 0.2 });

/// The fill lights' direction, where no marker says otherwise.
pub const fill_direction: Vector = math.normalize(.{ -1, 0.5, 0 });

/// How far toward the sun its sprites lie (`backdrop_create`, `0x004A5554`).
pub const sun_distance: f32 = 1000;

/// The six lights (`light_key_01` and the rest), each named after its mask. Models whose objects
/// list components take the first three and the last; the rest take the last four
/// (`objects.lightMask`).
pub const LightRole = enum { key_01, fill_02, ambient_04, key_08, fill_10, ambient_20 };
pub const Lights = std.EnumArray(LightRole, srlight.Light);

/// The fill lights' colour until `nebula_select` gives them the nebula's.
pub const default_fill: [3]f32 = .{ 0, 0.5, 1 };

/// The lights as `backdrop_create` makes them.
pub fn initialLights() Lights {
    const key: [3]f32 = .{ 1, 1, 0.8 };
    return .init(.{
        .key_01 = .{ .mask = 0x01, .intensity = 1, .colour = key, .kind = .{ .directional = sun_direction }, .shadowed = true },
        .fill_02 = .{ .mask = 0x02, .intensity = 1, .colour = default_fill, .kind = .{ .directional = fill_direction } },
        .ambient_04 = .{ .mask = 0x04, .intensity = 1, .colour = @splat(0.04), .kind = .ambient },
        .key_08 = .{ .mask = 0x08, .intensity = 1, .colour = key, .kind = .{ .directional = sun_direction }, .shadowed = true },
        .fill_10 = .{ .mask = 0x10, .intensity = 0.7, .colour = default_fill, .kind = .{ .directional = fill_direction } },
        .ambient_20 = .{ .mask = 0x20, .intensity = 1, .colour = @splat(0.09), .kind = .ambient },
    });
}

/// A sprite's half width and half height, in the camera's units, against its texture's width and
/// height in pixels times its depth (`backdrop_frame`, `0x004DCA0C`); the sprite pipeline draws it
/// that far to each side of its centre. On screen it reaches its texture's size times the view's
/// scale over 768, in pixels, each way, whatever the distance.
pub const sprite_scale: f32 = 1.0 / 768.0;

/// The sun's sprites, each textured, coloured grey and added on the background layer toward the
/// sun.
pub const SunLayer = enum {
    sunlayer1,
    sunlayer2,
    sunlayer3,

    pub fn texture(layer: SunLayer) []const u8 {
        return @tagName(layer);
    }

    /// Its place among the sun's sprite sets.
    pub fn sprite(layer: SunLayer) usize {
        return switch (layer) {
            .sunlayer1 => 0,
            .sunlayer3 => 1,
            .sunlayer2 => 8,
        };
    }

    /// Its size against a lens flare's.
    pub fn size(layer: SunLayer) f32 {
        return switch (layer) {
            .sunlayer1 => 0.5,
            .sunlayer2, .sunlayer3 => 2,
        };
    }

    /// Whether what isn't round in its texture is kept where OpenReliant draws it again finer
    /// (`Sun.smooth`): `sunlayer1`'s ragged rim and `sunlayer2`'s rays.
    pub fn detail(layer: SunLayer) rings.Detail {
        return switch (layer) {
            .sunlayer1, .sunlayer2 => .kept,
            .sunlayer3 => .round,
        };
    }

    /// Its grey, for the flares' brightness (`backdrop_frame`). `sunlayer2` and `sunlayer3` take
    /// theirs while the brightness is above 0 and keep it otherwise. `sunlayer2` is white from
    /// `layer2_white` on, and in proportion below it. `sunlayer3` takes `layer3_bright_share` of
    /// the brightness from `layer3_bright` on, and below it `layer3_dim_share` of it over
    /// `layer3_dim_least`.
    pub fn grey(layer: SunLayer, brightness: f32) f32 {
        return switch (layer) {
            .sunlayer1 => 1,
            .sunlayer2 => if (brightness >= layer2_white) 1 else brightness / layer2_white,
            .sunlayer3 => if (brightness >= layer3_bright) brightness * layer3_bright_share else brightness * layer3_dim_share + layer3_dim_least,
        };
    }

    /// The brightness from which `sunlayer2` is white (`0x004DC408`). Below it the game doubles
    /// the brightness, which dividing by it matches exactly.
    const layer2_white: f32 = 0.5;
    /// The brightness from which `sunlayer3` takes its bright share of it (`0x004DC410`,
    /// `0x004DC4C0`), and below which its dim share over its least (`0x004DC450`, `0x004DC420`).
    const layer3_bright: f32 = 0.8;
    const layer3_bright_share: f32 = 0.3;
    const layer3_dim_share: f32 = 0.15;
    const layer3_dim_least: f32 = 0.1;
};

/// The most of the sun that shows: its distance in pixels from the nearest edge of the screen is
/// kept to this.
pub const max_visibility: f32 = 10;

/// How much of the sun shows (`backdrop_frame`): its distance in pixels from the nearest edge of
/// the screen, at most `most`, and 0 when it is off the screen. The driver then lessens it for each
/// triangle of an object flagged `sun_occluder` that covers the sun's point. It is worked out after
/// the sprites are placed, so each frame uses the last frame's.
pub fn sunVisibility(point: [2]f32, width: f32, height: f32, most: f32) f32 {
    var visibility = most;
    if (point[0] < visibility) visibility = point[0];
    if (point[1] < visibility) visibility = point[1];
    if (width - point[0] < visibility) visibility = width - point[0];
    if (height - point[1] < visibility) visibility = height - point[1];
    return if (visibility < 0) 0 else visibility;
}

/// The flares' brightness (`backdrop_frame`), for the sun's visibility and `offset`, its distance
/// from the middle of the view in view units: position over depth. It is `flare_least` with none
/// of the sun showing and `flare_per_visibility` more for each pixel of it that shows, and falls
/// away as the sun leaves the middle.
pub fn flareBrightness(visibility: f32, offset: f32) f32 {
    return (visibility * flare_per_visibility + flare_least) * (1 - @min(offset, 1));
}

/// `0x004DC474` and `0x004DC408`.
const flare_per_visibility: f32 = 0.05;
const flare_least: f32 = 0.5;

/// The lens flares, textured, coloured by the flares' brightness and added on the overlay layer:
/// each at `along` times the sun's offset from the middle of the view, so on the line through the
/// sun and the middle, past it when negative.
pub const Flare = struct { texture: []const u8, along: f32 };
pub const flares = [6]Flare{
    .{ .texture = "sunflare2", .along = 0.5 },
    .{ .texture = "sunflare1", .along = 0.33 },
    .{ .texture = "sunflare3", .along = 0.2 },
    .{ .texture = "sunflare2", .along = -0.2 },
    .{ .texture = "sunflare3", .along = -0.6 },
    .{ .texture = "sunflare4", .along = -0.5 },
};

/// Whether a view shows the lens flares: every view but the cockpit's ahead, and that one too in
/// the chase mode while any of the sun shows.
pub fn flaresShown(view: camera.View, cockpit_mode: camera.CockpitMode, visibility: f32) bool {
    return view != .cockpit or (cockpit_mode == .chase and visibility > 0);
}

/// The sun's sprite sets (`sun_sprites`, `0x00595A04`): `sunlayer1`, `sunlayer3`, the six flares,
/// then `sunlayer2`.
pub const sun_sprite_count = 9;
const first_flare = 2;

/// How the sun and the lens flares are drawn.
pub const Sun = enum {
    /// **Improvement:** their textures each drawn again, eight times finer, from the rings it is
    /// made of (`rings.redraw`), so that they stay round and crisp however large they are drawn;
    /// and the sun's glow and the flares dimming as the sun's disc goes behind what hides it, over
    /// as far as `sunlayer1` reaches on the screen (`Backdrop.reach`, `glow`).
    smooth,
    /// From their small 16-bit textures, as the game draws them, dimming over `max_visibility`
    /// pixels of the screen and the glow going out at once.
    original,

    /// How much of `sunlayer3`'s grey shows at `visibility`, in the game's measure: all of it
    /// above `least_glow` and none below, as the game has it, or dimming with the visibility to
    /// none.
    pub fn glow(sun: Sun, visibility: f32) f32 {
        return switch (sun) {
            .smooth => visibility / max_visibility,
            .original => if (visibility > least_glow) 1 else 0,
        };
    }
};

/// The least visibility `sunlayer3` shows at in the game (`0x004DC408`).
const least_glow: f32 = 0.5;

/// The textures the sun and the lens flares draw: the three layers and the four flares.
const sun_textures = 7;

/// A texture drawn again finer, and the name of the one it was drawn from.
const Redrawn = struct {
    name: []const u8,
    image: srtexture.Image,
};

/// The backdrop as `backdrop_create` builds it: the star fields (`star_fields`, `0x00595A30`), the
/// dust (`space_dust`, `0x00595A28`), the lights, the sun's direction and its sprites.
pub const Backdrop = struct {
    fields: [field_count]srstars.Field,
    dust: srstars.Field,
    lights: Lights,
    /// Toward the sun, `sun_distance` long (`sun_direction`, `0x00595BE0`).
    sun_direction: Vector,
    sun: [sun_sprite_count]srapiext.SpriteSet,
    /// Each sun set's one sprite.
    sprites: [sun_sprite_count][1]srapiext.Sprite,
    /// Each sun set's texture's width and height in texels, which size its sprite: the game's
    /// texture's, whatever the set draws.
    texels: [sun_sprite_count][2]f32,
    /// How the sun and the flares are drawn.
    style: Sun,
    /// The sun's textures drawn again (`Sun.smooth`), made in `gpa`.
    redrawn: [sun_textures]Redrawn,
    redrawn_count: usize,
    /// Every field's stars, field after field.
    stars: []srstars.Star,
    motes: [dust_count]srstars.Star,

    /// Builds the backdrop (`backdrop_create`) from the star map, the sun's textures and `rand`,
    /// the flares sorting as if at `near`, the near plane, and the sun drawn as `sun` says.
    pub fn create(gpa: Allocator, textures: *srtexture.Table, map: tga.Image, rand: *libcmt.Rand, near: f32, sun: Sun) (matmanager.Error || error{WrongSize})!*Backdrop {
        if (map.width != star_map_size or map.height != star_map_size) return error.WrongSize;
        const backdrop = try gpa.create(Backdrop);
        errdefer gpa.destroy(backdrop);
        backdrop.style = sun;
        backdrop.redrawn_count = 0;
        errdefer for (backdrop.redrawn[0..backdrop.redrawn_count]) |made| rings.free(gpa, made.image);

        var count: usize = 0;
        for (0..star_map_size) |y| {
            for (0..star_map_size) |x| count += @intFromBool(!std.mem.allEqual(u8, &map.pixel(x, y), 0));
        }
        backdrop.stars = try gpa.alloc(srstars.Star, count);
        errdefer gpa.free(backdrop.stars);
        var at: usize = 0;
        for (0..fields_per_side) |row| {
            for (0..fields_per_side) |column| {
                const first = at;
                for (0..field_size) |y| {
                    for (0..field_size) |x| {
                        const pixel = map.pixel(column * field_size + x, row * field_size + y);
                        if (std.mem.allEqual(u8, &pixel, 0)) continue;
                        // The pixel's row gives `x`, its column `y`. Its bytes go in as the file
                        // stores them, blue first; the driver takes the first for red.
                        backdrop.stars[at] = .{
                            .position = .{ offsetSine(y), offsetSine(x), 1 },
                            .colour = .{ channel(pixel[2]), channel(pixel[1]), channel(pixel[0]) },
                        };
                        at += 1;
                    }
                }
                backdrop.fields[row * fields_per_side + column] = .{
                    .kind = .sky,
                    .orientation = math.lookAt(fieldAxis(row, column)),
                    .stars = backdrop.stars[first..at],
                };
            }
        }

        for (&backdrop.motes) |*mote| {
            var position: [3]f32 = undefined;
            for (&position) |*axis| axis.* = rand.fraction() * @as(f32, dust_cube_mask);
            mote.* = .{ .position = position, .colour = @splat(dust_grey) };
        }
        backdrop.dust = .{ .kind = .dust, .stars = &backdrop.motes, .cube_mask = dust_cube_mask };
        backdrop.lights = initialLights();
        backdrop.sun_direction = sun_direction * @as(Vector, @splat(sun_distance));

        for (&backdrop.sun, &backdrop.sprites) |*set, *sprite| {
            sprite.* = .{.{}};
            set.* = .{ .flags = .{ ._unknown_6 = 1 }, .sprites = sprite };
        }
        for ([_]SunLayer{ .sunlayer1, .sunlayer2, .sunlayer3 }) |layer| {
            const set = &backdrop.sun[layer.sprite()];
            const image = try matmanager.textureRequire(textures, layer.texture());
            backdrop.texels[layer.sprite()] = texelsOf(image);
            set.surface = .glow(try backdrop.drawn(gpa, image, layer.texture(), layer.detail(), sun));
            set.sprites[0].offset = backdrop.sun_direction;
        }
        for (flares, backdrop.sun[first_flare..][0..flares.len], backdrop.texels[first_flare..][0..flares.len]) |flare, *set, *texels| {
            const image = try matmanager.textureRequire(textures, flare.texture);
            texels.* = texelsOf(image);
            set.surface = .glow(try backdrop.drawn(gpa, image, flare.texture, .round, sun));
            set.sprites[0].bias = near;
        }
        return backdrop;
    }

    pub fn destroy(backdrop: *Backdrop, gpa: Allocator) void {
        for (backdrop.redrawn[0..backdrop.redrawn_count]) |made| rings.free(gpa, made.image);
        gpa.free(backdrop.stars);
        gpa.destroy(backdrop);
    }

    /// The image a sun set draws of the texture `name`, `image`: drawn again finer, once for every
    /// set that draws it, or the texture itself as the game draws it.
    fn drawn(backdrop: *Backdrop, gpa: Allocator, image: *srtexture.Image, name: []const u8, detail: rings.Detail, sun: Sun) Allocator.Error!*srtexture.Image {
        if (sun == .original) return image;
        for (backdrop.redrawn[0..backdrop.redrawn_count]) |*made| {
            if (std.mem.eql(u8, made.name, name)) return &made.image;
        }
        const made = &backdrop.redrawn[backdrop.redrawn_count];
        made.* = .{ .name = name, .image = try rings.redraw(gpa, image, detail) };
        backdrop.redrawn_count += 1;
        return &made.image;
    }

    /// The most of the sun's visibility, in the screen's pixels: `max_visibility`, as the game
    /// measures it, or for `Sun.smooth` as far as `sunlayer1` reaches on the screen, so that the
    /// sun dims as its disc goes behind what hides it, at any size of screen.
    fn reach(backdrop: *const Backdrop, projection: srapi.Projection) f32 {
        return switch (backdrop.style) {
            .smooth => backdrop.texels[SunLayer.sunlayer1.sprite()][0] * SunLayer.sunlayer1.size() * sprite_scale * projection.scale[0],
            .original => max_visibility,
        };
    }

    /// Has the dust's streaks cut shorter, or not (`srstars.Field.shortened`), as the player's
    /// ship jumps in.
    pub fn shortenDust(backdrop: *Backdrop, shortened: bool) void {
        backdrop.dust.shortened = shortened;
    }

    /// Makes every star field take this frame as its last, so a cut draws no streaks
    /// (`backdrop_reset_streaks`, `0x004A5C80`).
    pub fn resetStreaks(backdrop: *Backdrop) void {
        for (&backdrop.fields) |*field| field.flags.fresh = true;
        backdrop.dust.flags.fresh = true;
    }

    /// Adds the lights, the star fields, the dust, the sun and the lens flares to the scene
    /// (`backdrop_frame`), placing the flares, sizing the sprites and finding the sun's point and
    /// visibility for the frame.
    pub fn frame(backdrop: *Backdrop, gpa: Allocator, scene: *srcore.Scene, context: *srapi.Context, view: camera.View, cockpit_mode: camera.CockpitMode) Allocator.Error!void {
        for (&backdrop.lights.values) |*light| try xtrabits.sceneAdd(gpa, scene, .{ .light = light }, .background);
        // Toward the sun, in the camera's frame.
        const toward = context.turn(backdrop.sun_direction);
        for (&backdrop.fields) |*field| try xtrabits.sceneAdd(gpa, scene, .{ .stars = field }, .background);
        try xtrabits.sceneAdd(gpa, scene, .{ .stars = &backdrop.dust }, .background);

        const projection = context.projection;
        const most = backdrop.reach(projection);
        // How much of the sun showed last frame, in the game's measure.
        const visibility = context.sun_visibility / most * max_visibility;
        const sun1 = &backdrop.sun[SunLayer.sunlayer1.sprite()];
        const sun2 = &backdrop.sun[SunLayer.sunlayer2.sprite()];
        const sun3 = &backdrop.sun[SunLayer.sunlayer3.sprite()];
        if (toward[2] == 0) {
            context.sun_visibility = 0;
        } else {
            const across = toward[0] / toward[2];
            const down = toward[1] / toward[2];
            context.sun = .{ across * projection.scale[0] + projection.centre[0], down * projection.scale[1] + projection.centre[1] };
            const offset = @sqrt(across * across + down * down);
            const glow = backdrop.style.glow(visibility);
            if (glow > 0) try xtrabits.sceneAdd(gpa, scene, .{ .sprites = sun3 }, .background);
            const brightness = flareBrightness(visibility, offset);
            sun1.sprites[0].colour = @splat(SunLayer.sunlayer1.grey(brightness));
            if (brightness > 0) {
                if (context.hardware) {
                    sun2.sprites[0].colour = @splat(SunLayer.sunlayer2.grey(brightness));
                    sun3.sprites[0].colour = @splat(SunLayer.sunlayer3.grey(brightness) * glow);
                    try xtrabits.sceneAdd(gpa, scene, .{ .sprites = sun2 }, .background);
                }
                const sets = backdrop.sun[first_flare..][0..flares.len];
                for (flares, sets) |flare, *set| {
                    set.sprites[0].offset = .{ toward[0] * flare.along, toward[1] * flare.along, toward[2] };
                }
                if (flaresShown(view, cockpit_mode, visibility)) {
                    for (sets) |*set| {
                        const sprite = &set.sprites[0];
                        sprite.offset = math.transform(context.camera.orientation, sprite.offset);
                        sprite.colour = @splat(brightness);
                        try xtrabits.sceneAdd(gpa, scene, .{ .sprites = set }, .overlay);
                    }
                }
            }
            context.sun_visibility = sunVisibility(context.sun, @floatFromInt(projection.screen[0]), @floatFromInt(projection.screen[1]), most);
        }
        try xtrabits.sceneAdd(gpa, scene, .{ .sprites = sun1 }, .background);

        // Each sprite as far to each side as its texture is wide and high, times its depth.
        const sized: usize = if (context.hardware) sun_sprite_count else sun_sprite_count - 1;
        for (backdrop.sun[0..sized], backdrop.texels[0..sized]) |*set, texels| {
            set.position = context.camera.position;
            const sprite = &set.sprites[0];
            const depth = context.turn(sprite.offset)[2];
            if (depth > 0) sprite.half_size = .{ texels[0] * depth * sprite_scale, texels[1] * depth * sprite_scale };
        }
        for ([_]SunLayer{ .sunlayer2, .sunlayer1, .sunlayer3 }) |layer| {
            const sprite = &backdrop.sun[layer.sprite()].sprites[0];
            sprite.half_size = .{ sprite.half_size[0] * layer.size(), sprite.half_size[1] * layer.size() };
        }
    }
};

fn offsetSine(pixel: usize) f32 {
    const offset: f32 = @floatFromInt(@as(i32, @intCast(pixel)) - field_size / 2);
    return @sin(offset * half_degree);
}

fn channel(byte: u8) f32 {
    return @as(f32, @floatFromInt(byte)) * (1.0 / 255.0);
}

/// A texture's width and height in texels.
fn texelsOf(image: *const srtexture.Image) [2]f32 {
    return .{ @floatFromInt(image.width()), @floatFromInt(image.height()) };
}

test fieldAxis {
    // The first field is 9 degrees from +Y, toward +X and +Z; the middle ones straddle the horizon.
    const first = fieldAxis(0, 0);
    try std.testing.expectApproxEqAbs(@cos(9 * std.math.pi / 180.0), first[1], 1e-6);
    for (0..fields_per_side) |row| {
        for (0..fields_per_side) |column| try std.testing.expect(fieldAxis(row, column)[2] > 0);
    }
}

test SunLayer {
    try std.testing.expectEqualStrings("sunlayer3", SunLayer.sunlayer3.texture());
    try std.testing.expectEqual(8, SunLayer.sunlayer2.sprite());
    try std.testing.expectEqual(0.5, SunLayer.sunlayer1.size());
    try std.testing.expectEqual(1, SunLayer.sunlayer2.grey(0.75));
    try std.testing.expectApproxEqAbs(0.19, SunLayer.sunlayer3.grey(0.6), 1e-6);
    try std.testing.expectApproxEqAbs(0.27, SunLayer.sunlayer3.grey(0.9), 1e-6);
}

test sunVisibility {
    try std.testing.expectEqual(max_visibility, sunVisibility(.{ 320, 240 }, 640, 480, max_visibility));
    try std.testing.expectEqual(4, sunVisibility(.{ 636, 240 }, 640, 480, max_visibility));
    try std.testing.expectEqual(0, sunVisibility(.{ -20, 240 }, 640, 480, max_visibility));
    try std.testing.expectEqual(40, sunVisibility(.{ 320, 240 }, 640, 480, 40));
}

test Sun {
    // The game's glow goes out at once; OpenReliant's dims to none.
    try std.testing.expectEqual(1, Sun.original.glow(0.6));
    try std.testing.expectEqual(0, Sun.original.glow(0.4));
    try std.testing.expectEqual(1, Sun.smooth.glow(max_visibility));
    try std.testing.expectApproxEqAbs(0.05, Sun.smooth.glow(0.5), 1e-6);
    try std.testing.expectEqual(0, Sun.smooth.glow(0));
}

test flareBrightness {
    // Brightest with the sun in the middle of the view, gone a view unit away.
    try std.testing.expectEqual(1, flareBrightness(max_visibility, 0));
    try std.testing.expectEqual(0.25, flareBrightness(max_visibility, 0.75));
    try std.testing.expectEqual(0, flareBrightness(max_visibility, 2));
}

test flaresShown {
    try std.testing.expect(flaresShown(.chase, .open, 0));
    try std.testing.expect(!flaresShown(.cockpit, .open, max_visibility));
    try std.testing.expect(!flaresShown(.cockpit, .chase, 0));
    try std.testing.expect(flaresShown(.cockpit, .chase, 1));
}

test initialLights {
    // Each class of model takes four of the six.
    const lights = initialLights();
    const with_components: u32 = 0x18;
    const without: u32 = 0x03;
    var reaching_with: usize = 0;
    var reaching_without: usize = 0;
    for (lights.values) |light| {
        reaching_with += @intFromBool(light.reaches(with_components));
        reaching_without += @intFromBool(light.reaches(without));
    }
    try std.testing.expectEqual(4, reaching_with);
    try std.testing.expectEqual(4, reaching_without);
    try std.testing.expectEqual(0.7, lights.get(.fill_10).intensity);
}

/// A texture table holding the sun's textures and the nebulae's, each 8 by 4.
pub const testing = struct {
    /// The backdrop's own textures, for a table of test textures.
    pub const names: []const []const u8 = &.{ "sunlayer1", "sunlayer2", "sunlayer3", "sunflare1", "sunflare2", "sunflare3", "sunflare4", "neb01", "neb06" };
};

test Backdrop {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, testing.names);
    defer textures.deinit(gpa);

    const rgb = try gpa.alloc(u8, star_map_size * star_map_size * 3);
    defer gpa.free(rgb);
    @memset(rgb, 0);
    // A star at the centre of the first field; one below and to the right of the last's centre,
    // tinted blue.
    rgb[(18 * star_map_size + 18) * 3 ..][0..3].* = .{ 90, 90, 90 };
    rgb[((star_map_size - 16) * star_map_size + star_map_size - 12) * 3 ..][0..3].* = .{ 0, 0, 255 };
    const map: tga.Image = .{ .width = star_map_size, .height = star_map_size, .rgb = rgb };

    var rand: libcmt.Rand = .{};
    const backdrop = try Backdrop.create(gpa, &textures.table, map, &rand, 100, .original);
    defer backdrop.destroy(gpa);
    try std.testing.expectEqual(1, backdrop.fields[0].stars.len);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 1 }), backdrop.fields[0].stars[0].position);
    // The pixel's row gives `x`, its column `y`; its blue goes first.
    const tinted = backdrop.fields[field_count - 1].stars[0];
    try std.testing.expectApproxEqAbs(@sin(2 * half_degree), tinted.position[0], 1e-6);
    try std.testing.expectApproxEqAbs(@sin(6 * half_degree), tinted.position[1], 1e-6);
    try std.testing.expectEqual([3]f32{ 1, 0, 0 }, tinted.colour);
    for (backdrop.motes) |mote| {
        const position: [3]f32 = mote.position;
        for (position) |p| try std.testing.expect(p >= 0 and p <= dust_cube_mask);
    }
    try std.testing.expectEqual(100, backdrop.sun[first_flare].sprites[0].bias);

    const wrong: tga.Image = .{ .width = 1, .height = 1, .rgb = rgb[0..3] };
    try std.testing.expectError(error.WrongSize, Backdrop.create(gpa, &textures.table, wrong, &rand, 100, .original));
}

test "Backdrop.frame" {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, testing.names);
    defer textures.deinit(gpa);
    const rgb = try gpa.alloc(u8, star_map_size * star_map_size * 3);
    defer gpa.free(rgb);
    @memset(rgb, 0);
    var rand: libcmt.Rand = .{};
    const backdrop = try Backdrop.create(gpa, &textures.table, .{ .width = star_map_size, .height = star_map_size, .rgb = rgb }, &rand, 100, .original);
    defer backdrop.destroy(gpa);

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    // Looking straight at the sun, with all of it showing last frame.
    var context: srapi.Context = .{
        .camera = .{ .position = .{ 10, 20, 30 }, .orientation = math.lookAt(sun_direction) },
        .projection = .init(640, 480, srapi.full_screen, .{ 0.6, 0.8 }),
        .sun_visibility = max_visibility,
    };
    try backdrop.frame(gpa, &scene, &context, .chase, .open);
    try std.testing.expectEqual(6, scene.lights.items.len);
    // The fields, the dust, `sunlayer3`, `sunlayer2` and `sunlayer1`; the flares on the overlay.
    try std.testing.expectEqual(field_count + 4, scene.layers.get(.background).items.len);
    try std.testing.expectEqual(flares.len, scene.layers.get(.overlay).items.len);
    try std.testing.expectApproxEqAbs(320, context.sun[0], 1e-2);
    try std.testing.expectEqual(max_visibility, context.sun_visibility);
    // An 8-pixel-wide texture at depth 1000 reaches 8 * 1000 / 768 to each side, halved for
    // `sunlayer1`.
    const sun1 = backdrop.sun[SunLayer.sunlayer1.sprite()];
    try std.testing.expectApproxEqAbs(8.0 * 1000.0 / 768.0 * 0.5, sun1.sprites[0].half_size[0], 1e-2);
    try std.testing.expectEqual(context.camera.position, sun1.position);

    // From the cockpit the flares stay off the overlay.
    scene.clear();
    try backdrop.frame(gpa, &scene, &context, .cockpit, .open);
    try std.testing.expectEqual(0, scene.layers.get(.overlay).items.len);
}
